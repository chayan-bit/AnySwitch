// Helper of romstore.py (the chunk store builder) and its check, in C for speed:
//   romstore_tool scan <avg chunk size> < paths        cuts each file (NUL-separated paths on stdin) into content-defined chunks and writes one 40-byte record
//                                                      per chunk to stdout: u32 file number, u32 length, SHA-256
//   romstore_tool verify <store> <RomFS dir> [threads]  reads every file of the directory back through the host's reader (dm/host/romstore.c): whole-file SHA-256,
//                                                      then random reads (offsets, lengths across chunk ends, short reads at the end of the file) compared byte for byte;
//                                                      also checks that the store holds exactly the directory's files and directories. Exit status 0 only when all match
// Chunking is FastCDC (Xia et al., USENIX ATC 2016) with normalized chunking level 2: a gear rolling hash, no cut before avg/4, the stricter mask up to avg,
// the looser one after it, and a forced cut at 4 * avg. Build: make -C dm/tools/romstore.
#include "romstore.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

// ---------- scan ----------
static uint64_t G[256];
static size_t cut(const uint8_t *p, size_t n, uint32_t avg) {
    size_t mn = avg / 4, mx = (size_t)avg * 4;
    if (n <= mn) return n;
    if (n > mx) n = mx;
    int bits = __builtin_ctz(avg);
    uint64_t ms = ~0ULL << (64 - (bits + 2)), ml = ~0ULL << (64 - (bits - 2)), h = 0;
    size_t i = mn, mid = avg < n ? avg : n;
    for (; i < mid; i++) { h = (h << 1) + G[p[i]]; if (!(h & ms)) return i + 1; }
    for (; i < n; i++) { h = (h << 1) + G[p[i]]; if (!(h & ml)) return i + 1; }
    return n;
}
static const uint8_t *map_file(const char *path, size_t *n) {
    int fd = open(path, O_RDONLY); struct stat st;
    if (fd < 0 || fstat(fd, &st)) { fprintf(stderr, "romstore_tool: %s: %s\n", path, strerror(errno)); exit(1); }
    *n = (size_t)st.st_size; const uint8_t *p = (const uint8_t *)"";
    if (*n && (p = mmap(NULL, *n, PROT_READ, MAP_PRIVATE, fd, 0)) == MAP_FAILED) { fprintf(stderr, "romstore_tool: mmap %s: %s\n", path, strerror(errno)); exit(1); }
    close(fd); return p;
}
static int scan(uint32_t avg) {
    if (avg < 256 || avg & (avg - 1)) { fprintf(stderr, "romstore_tool: the average chunk size must be a power of two >= 256\n"); return 2; }
    uint64_t s = 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 256; i++) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; G[i] = s; }
    char *line = NULL; size_t cap = 0; ssize_t len; uint32_t fi = 0; uint64_t bytes = 0;
    while ((len = getdelim(&line, &cap, '\0', stdin)) > 0) {
        if (line[len - 1] == '\0') len--;
        line[len] = 0; size_t n; const uint8_t *p = map_file(line, &n);
        madvise((void *)p, n, MADV_SEQUENTIAL);
        for (size_t o = 0, c; o < n; o += c) {
            c = cut(p + o, n - o, avg); uint32_t c32 = (uint32_t)c; uint8_t d[32]; CC_SHA256(p + o, c32, d);
            if (fwrite(&fi, 4, 1, stdout) != 1 || fwrite(&c32, 4, 1, stdout) != 1 || fwrite(d, 32, 1, stdout) != 1) { perror("romstore_tool: write"); return 1; }
        }
        if (n) munmap((void *)p, n);
        bytes += n; if (++fi % 1000 == 0) fprintf(stderr, "scan %u files %.2f GB\n", fi, bytes / 1e9);
    }
    free(line);
    if (fflush(stdout)) { perror("romstore_tool: write"); return 1; }
    fprintf(stderr, "scan %u files %.2f GB done\n", fi, bytes / 1e9);
    return 0;
}

// ---------- verify ----------
typedef struct { char *phys, *guest; } vfile;
static vfile *g_files; static size_t g_nfiles, g_ndirs; static romstore *g_st;
static _Atomic size_t g_next, g_done, g_bad; static _Atomic uint64_t g_bytes, g_rand;
static void bad(const char *what, const char *path) { atomic_fetch_add(&g_bad, 1); fprintf(stderr, "MISMATCH %s: %s\n", what, path); }
// The guest name of a host entry: .dm-case-N names (case collisions, see dm/host/hle_fs.c) carry it in an extended attribute
static void guest_name(const char *phys_path, const char *name, char *out, size_t n) {
    if (!strncmp(name, ".dm-case-", 9)) { ssize_t k = getxattr(phys_path, "org.d2rmobile.guest-name", out, n - 1, 0, XATTR_NOFOLLOW); if (k >= 0) { out[k] = 0; return; } }
    snprintf(out, n, "%s", name);
}
static uint64_t rnd(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
static void verify_file(const vfile *f, uint8_t *buf, size_t bufn, uint64_t seed) {
    uint32_t idx; int is_dir;
    if (!romstore_lookup(g_st, f->guest, &idx, &is_dir) || is_dir) { bad("not in the store", f->guest); return; }
    size_t n; const uint8_t *p = map_file(f->phys, &n);
    if (romstore_file_size(g_st, idx) != n) { bad("size", f->guest); goto out; }
    uint8_t want[32], got[32]; CC_SHA256_CTX c; CC_SHA256(p, (CC_LONG)n, want); CC_SHA256_Init(&c);
    for (uint64_t o = 0; o < n;) {                                      // whole file, in buffer-sized reads
        ssize_t r = romstore_read(g_st, idx, o, buf, bufn);
        if (r <= 0) { bad("read failed", f->guest); goto out; }
        CC_SHA256_Update(&c, buf, (CC_LONG)r); o += r;
    }
    CC_SHA256_Final(got, &c);
    if (memcmp(want, got, 32)) { bad("SHA-256", f->guest); goto out; }
    uint64_t s = seed | 1;
    for (int k = 0; k < 8 && n; k++) {                                 // random reads: anywhere, small and large, and some running past the end of the file
        uint64_t off = rnd(&s) % n, len = 1 + rnd(&s) % (k < 4 ? 512 : 200000);
        if (k == 7) off = n - 1 - rnd(&s) % (n < 4096 ? n : 4096);
        if (len > bufn) len = bufn;
        size_t expect = off + len > n ? n - off : len;
        ssize_t r = romstore_read(g_st, idx, off, buf, len);
        if (r != (ssize_t)expect || memcmp(buf, p + off, expect)) { bad("random read", f->guest); goto out; }
        atomic_fetch_add(&g_rand, 1);
    }
    if (romstore_read(g_st, idx, n, buf, 16) != 0) bad("read at the end of the file", f->guest);
    atomic_fetch_add(&g_bytes, n);
out:
    if (n) munmap((void *)p, n);
}
static void *verify_worker(void *arg) {
    size_t bufn = 8u << 20; uint8_t *buf = malloc(bufn); if (!buf) { perror("malloc"); exit(1); }
    for (size_t i; (i = atomic_fetch_add(&g_next, 1)) < g_nfiles;) {
        verify_file(&g_files[i], buf, bufn, 0x9E3779B97F4A7C15ULL * (i + 1));
        size_t d = atomic_fetch_add(&g_done, 1) + 1;
        if (d % 1000 == 0) fprintf(stderr, "verify %zu/%zu files %.2f GB, %zu mismatches\n", d, g_nfiles, g_bytes / 1e9, (size_t)g_bad);
    }
    free(buf); (void)arg; return NULL;
}
static void store_count(uint32_t dir, char *path, size_t len, size_t *dirs, size_t *files) {   // directories and files under dir, walked through the index
    uint32_t ne = romstore_dir_entries(g_st, dir);
    for (uint32_t i = 0; i < ne; i++) {
        int is_dir; uint64_t sz; const char *name = romstore_dir_entry(g_st, dir, i, &is_dir, &sz);
        if (!is_dir) { (*files)++; continue; }
        (*dirs)++; int k = snprintf(path + len, 4096 - len, "/%s", name); uint32_t child; int d2;
        if (k > 0 && len + k < 4096 && romstore_lookup(g_st, path, &child, &d2) && d2) store_count(child, path, len + k, dirs, files);
        else bad("store directory not found by its own path", path);
        path[len] = 0;
    }
}
static int verify(const char *store, const char *root, int threads) {
    char err[1200]; struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    if (!(g_st = romstore_open(store, 32u << 20, err, sizeof err))) { fprintf(stderr, "romstore_tool: %s\n", err); return 1; }
    clock_gettime(CLOCK_MONOTONIC, &t1); fprintf(stderr, "opened and checked the index in %.1f ms\n", (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
    char *paths[] = {(char *)root, NULL}; FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, NULL);
    if (!fts) { perror(root); return 1; }
    size_t cap = 65536; g_files = malloc(cap * sizeof *g_files);
    // guest paths relative to the root; the directory part comes from the parent's guest path, kept per depth
    static char gpath[64][2048]; FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_info == FTS_DP) continue;
        if (e->fts_level == 0) { gpath[0][0] = 0; continue; }
        if (e->fts_level >= 64) { fprintf(stderr, "romstore_tool: too deep: %s\n", e->fts_path); return 1; }
        char g[1024]; guest_name(e->fts_accpath, e->fts_name, g, sizeof g);
        snprintf(gpath[e->fts_level], sizeof gpath[0], "%s/%s", gpath[e->fts_level - 1], g);
        if (e->fts_info == FTS_D) { g_ndirs++;
            uint32_t idx; int is_dir; if (!romstore_lookup(g_st, gpath[e->fts_level], &idx, &is_dir) || !is_dir) bad("directory not in the store", gpath[e->fts_level]);
            continue; }
        if (e->fts_info != FTS_F) { fprintf(stderr, "romstore_tool: not a regular file: %s\n", e->fts_path); return 1; }
        if (g_nfiles == cap && !(g_files = realloc(g_files, (cap *= 2) * sizeof *g_files))) { perror("realloc"); return 1; }
        g_files[g_nfiles].phys = strdup(e->fts_path); g_files[g_nfiles].guest = strdup(gpath[e->fts_level]); g_nfiles++;
    }
    fts_close(fts);
    // the store must hold nothing more: count its directories and files
    size_t sfiles = 0, sdirs = 0; char sp[4096] = ""; store_count(0, sp, 0, &sdirs, &sfiles);
    pthread_t th[16]; if (threads < 1) threads = 1; if (threads > 16) threads = 16;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < threads; i++) pthread_create(&th[i], NULL, verify_worker, NULL);
    for (int i = 0; i < threads; i++) pthread_join(th[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1); double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    romstore_stats q; romstore_get_stats(g_st, &q);
    printf("files %zu (store %zu), directories %zu (store %zu), %.3f GB read back in %.1f s (%.0f MB/s with %d threads), %llu random reads, %zu mismatches\n",
           g_nfiles, sfiles, g_ndirs, sdirs, g_bytes / 1e9, sec, g_bytes / 1e6 / sec, threads, (unsigned long long)g_rand, (size_t)g_bad);
    printf("reader: %llu reads, %llu chunks decompressed, cache %llu hits / %llu misses, peak %.1f MiB\n", (unsigned long long)q.reads, (unsigned long long)q.chunks,
           (unsigned long long)q.cache_hits, (unsigned long long)q.cache_misses, q.cache_peak / 1048576.0);
    return g_bad || sfiles != g_nfiles || sdirs != g_ndirs;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "scan")) return scan((uint32_t)strtoul(argv[2], NULL, 0));
    if ((argc == 4 || argc == 5) && !strcmp(argv[1], "verify")) return verify(argv[2], argv[3], argc == 5 ? atoi(argv[4]) : 2);
    fprintf(stderr, "usage: romstore_tool scan <avg chunk size> < NUL-separated paths > records\n       romstore_tool verify <store> <RomFS dir> [threads]\n");
    return 2;
}
