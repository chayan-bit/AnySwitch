// Chunk store reader (format in romstore.h). The index is mapped read-only and checked once at open; a read binary-searches the file's chunk list,
// preads each run of chunks that lie back to back in the pack with one call, and decompresses whole chunks straight into the caller's buffer.
// A chunk the read covers only in part is decompressed into a bounded LRU cache and copied from there, so small reads inside one chunk do not decompress it again.
// Thread-safety: the index is immutable; each thread has its own decompression context and read buffer; the cache has one mutex.
#include "romstore.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"

#define RLOG(...) do { fprintf(stderr, "[dm] romstore: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define RUN_MAX (1u << 20)   // the most compressed bytes one pread fetches for a run of whole chunks
#define CACHE_BUCKETS 4096

typedef struct cent { struct cent *hnext, *prev, *next; uint32_t chunk, size; uint8_t data[]; } cent;
struct romstore {
    int fd; void *map; size_t maplen;
    romstore_header h;
    const romstore_dir *dirs; const romstore_file *files; const uint64_t *ref_end; const uint32_t *ref_chunk; const romstore_chunk *chunks;
    const char *names; uint64_t names_size;
    ZSTD_DDict *ddict; size_t scratch;      // scratch: per-thread read buffer size
    pthread_mutex_t lock; cent *tab[CACHE_BUCKETS], *head, *tail; size_t cache_cap, cache_bytes, cache_peak;
    _Atomic uint64_t reads, bytes, nchunks, hits, misses;
};

// ---------- open ----------
static size_t pad8(size_t n) { return (n + 7) & ~(size_t)7; }
static int fail(char *err, size_t n, const char *why, const char *path) { snprintf(err, n, "%s: %s", path, why); return 0; }
static int check_index(romstore *s, char *err, size_t en, const char *path) {
    const romstore_header *h = &s->h;
    for (uint32_t i = 0; i < h->n_dirs; i++) {
        const romstore_dir *d = &s->dirs[i];
        if (d->name >= s->names_size || (uint64_t)d->dir_first + d->dir_count > h->n_dirs || (uint64_t)d->file_first + d->file_count > h->n_files || (d->dir_count && d->dir_first <= i))
            return fail(err, en, "index: a directory entry is out of range", path);
    }
    if (!h->n_dirs) return fail(err, en, "index: no root directory", path);
    for (uint32_t i = 0; i < h->n_files; i++) {
        const romstore_file *f = &s->files[i];
        if (f->name >= s->names_size || (uint64_t)f->ref_first + f->ref_count > h->n_refs) return fail(err, en, "index: a file entry is out of range", path);
        uint64_t at = 0;
        for (uint32_t k = f->ref_first; k < f->ref_first + f->ref_count; k++) {
            uint32_t c = s->ref_chunk[k];
            if (c >= h->n_chunks || s->ref_end[k] - at != s->chunks[c].rsize || !s->chunks[c].rsize) return fail(err, en, "index: a file's chunk list does not add up", path);
            at = s->ref_end[k];
        }
        if (at != f->size) return fail(err, en, "index: a file's chunks do not cover its size", path);
    }
    size_t bound = ZSTD_COMPRESSBOUND(h->max_chunk);
    for (uint32_t c = 0; c < h->n_chunks; c++) {
        const romstore_chunk *k = &s->chunks[c];
        if (k->rsize > h->max_chunk || k->csize > bound || k->off < h->header_size || k->off + k->csize > h->index_off) return fail(err, en, "index: a chunk is out of range", path);
    }
    return 1;
}
romstore *romstore_open(const char *path, size_t cache_bytes, char *err, size_t en) {
    romstore *s = calloc(1, sizeof *s); if (!s) { fail(err, en, "out of memory", path); return NULL; }
    s->fd = open(path, O_RDONLY | O_CLOEXEC); struct stat st;
    if (s->fd < 0 || fstat(s->fd, &st)) { fail(err, en, strerror(errno), path); goto bad; }
    romstore_header *h = &s->h;
    if (pread(s->fd, h, sizeof *h, 0) != sizeof *h || memcmp(h->magic, ROMSTORE_MAGIC, 8)) { fail(err, en, "not a chunk store", path); goto bad; }
    if (h->version != ROMSTORE_VERSION || h->header_size != sizeof *h) { fail(err, en, "unsupported chunk store version", path); goto bad; }
    if (h->index_off < h->header_size || h->index_off % 8 || h->index_size > (uint64_t)st.st_size || h->index_off != (uint64_t)st.st_size - h->index_size || h->max_chunk > (16u << 20)) { fail(err, en, "header does not match the file size", path); goto bad; }
    uint64_t fixed = pad8((size_t)h->n_dirs * sizeof(romstore_dir)) + pad8((size_t)h->n_files * sizeof(romstore_file)) + (uint64_t)h->n_refs * 8 + pad8((size_t)h->n_refs * 4)
                   + (uint64_t)h->n_chunks * sizeof(romstore_chunk) + pad8(h->dict_size);
    if (fixed >= h->index_size) { fail(err, en, "index too small for its counts", path); goto bad; }
    long pg = sysconf(_SC_PAGESIZE); uint64_t moff = h->index_off & ~(uint64_t)(pg - 1), skip = h->index_off - moff;
    s->maplen = (size_t)(skip + h->index_size);
    s->map = mmap(NULL, s->maplen, PROT_READ, MAP_SHARED, s->fd, (off_t)moff);
    if (s->map == MAP_FAILED) { s->map = NULL; fail(err, en, strerror(errno), path); goto bad; }
    const uint8_t *p = (const uint8_t *)s->map + skip;
    uint8_t sha[32]; CC_SHA256_CTX c; CC_SHA256_Init(&c); CC_SHA256_Update(&c, h, 56);
    for (uint64_t o = 0; o < h->index_size; o += 1u << 30) CC_SHA256_Update(&c, p + o, (CC_LONG)(h->index_size - o < (1u << 30) ? h->index_size - o : (1u << 30)));
    CC_SHA256_Final(sha, &c);
    if (memcmp(sha, h->index_sha256, 32)) { fail(err, en, "index checksum mismatch (damaged or incomplete copy)", path); goto bad; }
    s->dirs = (const void *)p; p += pad8((size_t)h->n_dirs * sizeof(romstore_dir));
    s->files = (const void *)p; p += pad8((size_t)h->n_files * sizeof(romstore_file));
    s->ref_end = (const void *)p; p += (size_t)h->n_refs * 8;
    s->ref_chunk = (const void *)p; p += pad8((size_t)h->n_refs * 4);
    s->chunks = (const void *)p; p += (size_t)h->n_chunks * sizeof(romstore_chunk);
    const uint8_t *dict = p; p += pad8(h->dict_size);
    s->names = (const char *)p; s->names_size = h->index_size - fixed;
    if (s->names[s->names_size - 1]) { fail(err, en, "index: names are not terminated", path); goto bad; }
    if (!check_index(s, err, en, path)) goto bad;
    if (h->dict_size && !(s->ddict = ZSTD_createDDict(dict, h->dict_size))) { fail(err, en, "bad dictionary", path); goto bad; }
    s->scratch = ZSTD_COMPRESSBOUND(h->max_chunk); if (s->scratch < RUN_MAX) s->scratch = RUN_MAX;
    pthread_mutex_init(&s->lock, NULL); s->cache_cap = cache_bytes;
    return s;
bad:
    romstore_close(s); return NULL;
}
void romstore_close(romstore *s) {
    if (!s) return;
    for (cent *e = s->head, *n; e; e = n) { n = e->next; free(e); }
    ZSTD_freeDDict(s->ddict);
    if (s->map) munmap(s->map, s->maplen);
    if (s->fd >= 0) close(s->fd);
    free(s);
}
int romstore_fd(const romstore *s) { return s->fd; }

// ---------- names ----------
static const char *nm(const romstore *s, uint32_t off) { return s->names + off; }
static int find_dir(const romstore *s, const romstore_dir *d, const char *name, size_t len, uint32_t *out) {
    uint32_t lo = d->dir_first, hi = d->dir_first + d->dir_count;
    while (lo < hi) { uint32_t m = lo + (hi - lo) / 2; const char *x = nm(s, s->dirs[m].name); int r = strncmp(x, name, len); if (!r) r = (uint8_t)x[len];
        if (!r) { *out = m; return 1; } if (r < 0) lo = m + 1; else hi = m; }
    return 0;
}
static int find_file(const romstore *s, const romstore_dir *d, const char *name, size_t len, uint32_t *out) {
    uint32_t lo = d->file_first, hi = d->file_first + d->file_count;
    while (lo < hi) { uint32_t m = lo + (hi - lo) / 2; const char *x = nm(s, s->files[m].name); int r = strncmp(x, name, len); if (!r) r = (uint8_t)x[len];
        if (!r) { *out = m; return 1; } if (r < 0) lo = m + 1; else hi = m; }
    return 0;
}
int romstore_lookup(const romstore *s, const char *path, uint32_t *idx, int *is_dir) {
    uint32_t dir = 0;
    for (;;) {
        while (*path == '/') path++;
        if (!*path) { *idx = dir; *is_dir = 1; return 1; }
        const char *end = strchr(path, '/'); size_t len = end ? (size_t)(end - path) : strlen(path);
        const char *next = path + len; while (*next == '/') next++;
        uint32_t x;
        if (find_dir(s, &s->dirs[dir], path, len, &x)) { dir = x; path = next; continue; }
        if (find_file(s, &s->dirs[dir], path, len, &x)) {
            if (*next) { errno = ENOTDIR; return 0; }
            *idx = x; *is_dir = 0; return 1;
        }
        errno = ENOENT; return 0;
    }
}
uint64_t romstore_file_size(const romstore *s, uint32_t file) { return s->files[file].size; }
uint32_t romstore_dir_entries(const romstore *s, uint32_t dir) { return s->dirs[dir].dir_count + s->dirs[dir].file_count; }
const char *romstore_dir_entry(const romstore *s, uint32_t dir, uint32_t i, int *is_dir, uint64_t *size) {
    const romstore_dir *d = &s->dirs[dir];
    if (i < d->dir_count) { *is_dir = 1; *size = 0; return nm(s, s->dirs[d->dir_first + i].name); }
    const romstore_file *f = &s->files[d->file_first + i - d->dir_count]; *is_dir = 0; *size = f->size; return nm(s, f->name);
}

// ---------- per-thread state ----------
typedef struct { ZSTD_DCtx *dctx; uint8_t *buf; size_t cap; } tls_t;
static pthread_key_t g_key; static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void tls_free(void *p) { tls_t *t = p; ZSTD_freeDCtx(t->dctx); free(t->buf); free(t); }
static void tls_init(void) { pthread_key_create(&g_key, tls_free); }
static tls_t *tls_get(size_t need) {
    pthread_once(&g_once, tls_init);
    tls_t *t = pthread_getspecific(g_key);
    if (!t) { if (!(t = calloc(1, sizeof *t)) || !(t->dctx = ZSTD_createDCtx())) { free(t); return NULL; } pthread_setspecific(g_key, t); }
    if (t->cap < need) { uint8_t *b = realloc(t->buf, need); if (!b) return NULL; t->buf = b; t->cap = need; }
    return t;
}

// ---------- reading ----------
static int pread_all(int fd, void *b, size_t n, uint64_t off) {
    for (size_t got = 0; got < n;) {
        ssize_t r = pread(fd, (uint8_t *)b + got, n - got, (off_t)(off + got));
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) { if (!r) errno = EIO; return 0; }
        got += r;
    }
    return 1;
}
static int decode(romstore *s, tls_t *t, uint32_t c, const uint8_t *src, uint8_t *dst) {
    size_t r = ZSTD_decompress_usingDDict(t->dctx, dst, s->chunks[c].rsize, src, s->chunks[c].csize, s->ddict);
    if (ZSTD_isError(r) || r != s->chunks[c].rsize) { RLOG("[RED] chunk %u (pack offset %llu) does not decode: %s", c, (unsigned long long)s->chunks[c].off, ZSTD_isError(r) ? ZSTD_getErrorName(r) : "wrong size"); errno = EIO; return 0; }
    atomic_fetch_add_explicit(&s->nchunks, 1, memory_order_relaxed);
    return 1;
}
static cent **bucket(romstore *s, uint32_t c) { return &s->tab[(c * 2654435761u) % CACHE_BUCKETS]; }
static void lru_unlink(romstore *s, cent *e) { if (e->prev) e->prev->next = e->next; else s->head = e->next; if (e->next) e->next->prev = e->prev; else s->tail = e->prev; }
static void lru_front(romstore *s, cent *e) { e->prev = NULL; e->next = s->head; if (s->head) s->head->prev = e; s->head = e; if (!s->tail) s->tail = e; }
static cent *cache_find(romstore *s, uint32_t c) { for (cent *e = *bucket(s, c); e; e = e->hnext) if (e->chunk == c) return e; return NULL; }
// Copies bytes [lo, hi) of chunk c to dst through the cache
static int read_partial(romstore *s, uint32_t c, uint32_t lo, uint32_t hi, uint8_t *dst) {
    pthread_mutex_lock(&s->lock);
    cent *e = cache_find(s, c);
    if (e) { lru_unlink(s, e); lru_front(s, e); memcpy(dst, e->data + lo, hi - lo); pthread_mutex_unlock(&s->lock); atomic_fetch_add_explicit(&s->hits, 1, memory_order_relaxed); return 1; }
    pthread_mutex_unlock(&s->lock);
    atomic_fetch_add_explicit(&s->misses, 1, memory_order_relaxed);
    const romstore_chunk *k = &s->chunks[c]; tls_t *t = tls_get(s->scratch);
    cent *n = malloc(sizeof *n + k->rsize);
    if (!t || !n) { free(n); errno = ENOMEM; return 0; }
    if (!pread_all(s->fd, t->buf, k->csize, k->off) || !decode(s, t, c, t->buf, n->data)) { int er = errno; free(n); errno = er; return 0; }
    n->chunk = c; n->size = k->rsize;
    memcpy(dst, n->data + lo, hi - lo);
    pthread_mutex_lock(&s->lock);
    if (cache_find(s, c) || n->size > s->cache_cap) free(n);   // another thread cached it meanwhile, or it can never fit
    else {
        cent **b = bucket(s, c); n->hnext = *b; *b = n; lru_front(s, n); s->cache_bytes += n->size;
        while (s->cache_bytes > s->cache_cap) {
            cent *v = s->tail; lru_unlink(s, v); s->cache_bytes -= v->size;
            for (cent **pp = bucket(s, v->chunk); *pp; pp = &(*pp)->hnext) if (*pp == v) { *pp = v->hnext; break; }
            free(v);
        }
        if (s->cache_bytes > s->cache_peak) s->cache_peak = s->cache_bytes;
    }
    pthread_mutex_unlock(&s->lock);
    return 1;
}
ssize_t romstore_read(romstore *s, uint32_t file, uint64_t off, void *buf, size_t n) {
    const romstore_file *f = &s->files[file];
    if (off >= f->size || !n) return 0;
    if (n > f->size - off) n = (size_t)(f->size - off);
    const uint64_t *end = s->ref_end + f->ref_first; const uint32_t *chunk = s->ref_chunk + f->ref_first; uint32_t nr = f->ref_count;
    uint32_t lo = 0, hi = nr;                                    // first reference that ends after off
    while (lo < hi) { uint32_t m = lo + (hi - lo) / 2; if (end[m] <= off) lo = m + 1; else hi = m; }
    uint8_t *out = buf; uint64_t pos = off, stop = off + n; uint32_t k = lo;
    while (pos < stop) {
        uint64_t cs = k ? end[k - 1] : 0, ce = end[k]; uint32_t c = chunk[k];
        if (pos != cs || stop < ce) {                            // part of a chunk: through the cache
            uint64_t e = stop < ce ? stop : ce;
            if (!read_partial(s, c, (uint32_t)(pos - cs), (uint32_t)(e - cs), out + (pos - off))) return -1;
            pos = e; k++; continue;
        }
        // whole chunks: extend the run while the next chunk is whole and follows in the pack, then one pread and decode each into place
        uint32_t k0 = k; uint64_t p0 = s->chunks[c].off, plen = s->chunks[c].csize; k++;
        while (k < nr && end[k] <= stop) {
            const romstore_chunk *x = &s->chunks[chunk[k]];
            if (x->off != p0 + plen || plen + x->csize > RUN_MAX) break;
            plen += x->csize; k++;
        }
        tls_t *t = tls_get(plen > s->scratch ? plen : s->scratch);
        if (!t) { errno = ENOMEM; return -1; }
        if (!pread_all(s->fd, t->buf, plen, p0)) { RLOG("[RED] pread of %llu bytes at %llu failed errno=%d", (unsigned long long)plen, (unsigned long long)p0, errno); errno = EIO; return -1; }
        for (uint32_t j = k0; j < k; j++) {
            const romstore_chunk *x = &s->chunks[chunk[j]];
            if (!decode(s, t, chunk[j], t->buf + (x->off - p0), out + ((j ? end[j - 1] : 0) - off))) return -1;
        }
        pos = end[k - 1];
    }
    atomic_fetch_add_explicit(&s->reads, 1, memory_order_relaxed); atomic_fetch_add_explicit(&s->bytes, n, memory_order_relaxed);
    return (ssize_t)n;
}
void romstore_get_stats(romstore *s, romstore_stats *o) {
    o->reads = s->reads; o->bytes = s->bytes; o->chunks = s->nchunks; o->cache_hits = s->hits; o->cache_misses = s->misses;
    pthread_mutex_lock(&s->lock); o->cache_bytes = s->cache_bytes; o->cache_peak = s->cache_peak; pthread_mutex_unlock(&s->lock);
}
