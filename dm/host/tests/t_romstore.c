// Chunk store reader unit test (takes about a second): writes a small synthetic store (the format of romstore.h, with zstd frames and a raw-content dictionary),
// then checks romstore.c directly and through the file system calls of hle_fs.c (included, like t_fs.c):
//   (1) every file reads back exactly, whole and at random offsets and lengths, including reads that run past the end;
//   (2) path lookup, directory listing, entry types and "." / ".." in guest paths;
//   (3) concurrent readers with a tiny cache (eviction under contention);
//   (4) hle_fs: open / read / size / close of store files, writes refused, directories listed from the index;
//   (5) a damaged index, header or chunk is refused, never read as data.
// Expected bytes come from the generator, not from the reader under test.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hle_fs.c"
#include "../romstore.c"
#include <CommonCrypto/CommonDigest.h>

struct dm_flags g_flag; uint64_t g_t0_ns; uint64_t now_ns(void) { return 0; }
void dm_guest_write_prepare(void *a, size_t n) { (void)a; (void)n; }
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); } else printf("  ✓ "); printf(__VA_ARGS__); printf("\n"); } while (0)

// ---------- the synthetic tree ----------
// dirs (breadth-first): 0 root {a, b; big.bin, top.bin, z.txt}, 1 a {deep; one.bin, two.bin}, 2 b {}, 3 deep {x.bin}
static const romstore_dir DIRS[4] = {{0, 0, 1, 2, 0, 3}, {0, 0, 3, 1, 3, 2}, {0, 0, 0, 0, 5, 0}, {0, 1, 0, 0, 5, 1}};
static const char *DIR_NAME[4] = {"", "a", "b", "deep"};
static const char *FILE_NAME[6] = {"big.bin", "top.bin", "z.txt", "one.bin", "two.bin", "x.bin"};
static const uint32_t FILE_PARENT[6] = {0, 0, 0, 1, 1, 3};
static const char *FILE_PATH[6] = {"/big.bin", "/top.bin", "/z.txt", "/a/one.bin", "/a/two.bin", "/a/deep/x.bin"};
static const size_t FILE_SIZE[6] = {2600000, 300001, 0, 70000, 70000, 5};
static uint8_t *g_data[6];
static uint64_t rnd(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
static void make_data(void) {
    uint64_t s = 88172645463325252ull;
    for (int i = 0; i < 6; i++) {
        g_data[i] = malloc(FILE_SIZE[i] + 1);
        for (size_t k = 0; k < FILE_SIZE[i]; k++) g_data[i][k] = (k / 64) % 3 ? (uint8_t)("tile map entry "[k % 15]) : (uint8_t)rnd(&s);   // part text, part noise
    }
    memcpy(g_data[4], g_data[3], FILE_SIZE[3]);   // two.bin = one.bin: its chunks are stored once
    memcpy(g_data[1] + 1000, g_data[0] + 5000, 60000);   // a stretch shared between big.bin and top.bin (same chunk boundaries below)
}
// chunk cuts: cycling sizes, so chunks of every size and alignment occur; max 16384
static const uint32_t CUTS[] = {1000, 4096, 777, 16384, 3, 9000};

typedef struct { const uint8_t *p; uint32_t n; } uchunk;
static int write_store(const char *path, const uint8_t *dict, size_t dict_size, size_t *n_unique_out) {
    uchunk *uq = calloc(4096, sizeof *uq); uint32_t nu = 0;
    uint64_t *ref_end = calloc(4096, 8); uint32_t *ref_chunk = calloc(4096, 4), nr = 0;
    romstore_file files[6];
    for (int i = 0; i < 6; i++) {
        files[i] = (romstore_file){0, FILE_PARENT[i], nr, 0, FILE_SIZE[i]};
        for (size_t o = 0, k = 0; o < FILE_SIZE[i]; k++) {
            uint32_t n = CUTS[k % 6]; if (n > FILE_SIZE[i] - o) n = (uint32_t)(FILE_SIZE[i] - o);
            uint32_t c = 0; while (c < nu && (uq[c].n != n || memcmp(uq[c].p, g_data[i] + o, n))) c++;
            if (c == nu) uq[nu++] = (uchunk){g_data[i] + o, n};
            o += n; ref_end[nr] = o; ref_chunk[nr++] = c; files[i].ref_count++;
        }
    }
    *n_unique_out = nu;
    FILE *f = fopen(path, "wb"); if (!f) return 0;
    romstore_header h = {0}; fwrite(&h, sizeof h, 1, f);
    ZSTD_CCtx *cc = ZSTD_createCCtx(); ZSTD_CDict *cd = dict_size ? ZSTD_createCDict(dict, dict_size, 3) : NULL;
    ZSTD_CCtx_setParameter(cc, ZSTD_c_checksumFlag, 1); ZSTD_CCtx_setParameter(cc, ZSTD_c_dictIDFlag, 0); ZSTD_CCtx_setParameter(cc, ZSTD_c_contentSizeFlag, 0);
    if (cd) ZSTD_CCtx_refCDict(cc, cd);
    romstore_chunk *ch = calloc(nu, sizeof *ch); uint64_t pos = sizeof h; uint8_t *frame = malloc(ZSTD_compressBound(16384));
    for (int pass = 0; pass < 2; pass++)                                   // pack order: odd chunks first, then even ones, so runs break up
        for (uint32_t c = pass ? 0 : 1; c < nu; c += 2) {
            size_t z = ZSTD_compress2(cc, frame, ZSTD_compressBound(16384), uq[c].p, uq[c].n);
            if (ZSTD_isError(z)) return 0;
            ch[c] = (romstore_chunk){pos, (uint32_t)z, uq[c].n}; fwrite(frame, 1, z, f); pos += z;
        }
    while (pos % 16) { fputc(0, f); pos++; }
    // index
    char names[256]; size_t nl = 0; romstore_dir dirs[4]; memcpy(dirs, DIRS, sizeof dirs);
    for (int i = 0; i < 4; i++) { dirs[i].name = (uint32_t)nl; nl += strlen(DIR_NAME[i]) + 1; memcpy(names + dirs[i].name, DIR_NAME[i], strlen(DIR_NAME[i]) + 1); }
    for (int i = 0; i < 6; i++) { files[i].name = (uint32_t)nl; nl += strlen(FILE_NAME[i]) + 1; memcpy(names + files[i].name, FILE_NAME[i], strlen(FILE_NAME[i]) + 1); }
    static const uint8_t zero[8];
    uint8_t *ix = NULL; size_t isz = 0; FILE *m = open_memstream((char **)&ix, &isz);
    #define PUT(p, n) do { fwrite(p, 1, n, m); fwrite(zero, 1, (8 - (n) % 8) % 8, m); } while (0)
    PUT(dirs, sizeof dirs); PUT(files, sizeof files); PUT(ref_end, nr * 8); PUT(ref_chunk, nr * 4); PUT(ch, nu * sizeof *ch); PUT(dict, dict_size); fwrite(names, 1, nl, m);
    fclose(m);
    memcpy(h.magic, ROMSTORE_MAGIC, 8); h.version = ROMSTORE_VERSION; h.header_size = sizeof h; h.index_off = pos; h.index_size = isz;
    h.n_dirs = 4; h.n_files = 6; h.n_refs = nr; h.n_chunks = nu; h.dict_size = (uint32_t)dict_size; h.max_chunk = 16384;
    CC_SHA256_CTX s; CC_SHA256_Init(&s); CC_SHA256_Update(&s, &h, 56); CC_SHA256_Update(&s, ix, (CC_LONG)isz); CC_SHA256_Final(h.index_sha256, &s);
    fwrite(ix, 1, isz, f); fseek(f, 0, SEEK_SET); fwrite(&h, sizeof h, 1, f); fclose(f);
    free(ix); free(frame); free(ch); ZSTD_freeCDict(cd); ZSTD_freeCCtx(cc); free(uq); free(ref_end); free(ref_chunk);
    return 1;
}

static int read_matches(romstore *s, uint32_t fi, uint64_t off, size_t n, uint8_t *buf) {
    size_t want = off >= FILE_SIZE[fi] ? 0 : (off + n > FILE_SIZE[fi] ? FILE_SIZE[fi] - off : n);
    ssize_t r = romstore_read(s, fi, off, buf, n);
    return r == (ssize_t)want && (!want || !memcmp(buf, g_data[fi] + off, want));
}
typedef struct { romstore *s; uint64_t seed; int bad; } worker_arg;
static void *worker(void *p) {
    worker_arg *a = p; uint8_t *buf = malloc(3u << 20);
    for (int k = 0; k < 3000; k++) { uint32_t fi = (uint32_t)(rnd(&a->seed) % 6); size_t sz = FILE_SIZE[fi] ? FILE_SIZE[fi] : 1;
        uint64_t off = rnd(&a->seed) % sz; size_t n = 1 + rnd(&a->seed) % (k % 4 ? 20000 : 2000000);
        if (!read_matches(a->s, fi, off, n, buf)) a->bad++; }
    free(buf); return NULL;
}

int main(void) {
    char dir[1024], path[1100], bad[1100]; const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/t_romstore.XXXXXX", tmp ? tmp : "/private/tmp"); if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    snprintf(path, sizeof path, "%s/game.dmstore", dir); snprintf(bad, sizeof bad, "%s/bad.dmstore", dir);
    make_data(); size_t nu;
    CHECK(write_store(path, g_data[1], 4096, &nu), "write a synthetic store (%zu unique chunks, raw-content dictionary)", nu);
    char err[1300]; romstore *s = romstore_open(path, 1u << 20, err, sizeof err);
    CHECK(s != NULL, "open and check it%s%s", s ? "" : ": ", s ? "" : err);
    if (!s) return 1;
    uint8_t *buf = malloc(3u << 20);

    printf("(1) reads\n");
    int ok = 1; for (uint32_t i = 0; i < 6; i++) ok &= read_matches(s, i, 0, 3u << 20, buf);
    CHECK(ok, "every file reads back whole in one call (2.6 MB spans several pread runs)");
    ok = 1; uint64_t sd = 7;
    for (int k = 0; k < 20000; k++) { uint32_t fi = (uint32_t)(rnd(&sd) % 6); size_t sz = FILE_SIZE[fi] ? FILE_SIZE[fi] : 1; ok &= read_matches(s, fi, rnd(&sd) % sz, 1 + rnd(&sd) % (k % 3 ? 40 : 70000), buf); }
    CHECK(ok, "20000 random reads (tiny and chunk-crossing) match");
    CHECK(read_matches(s, 1, FILE_SIZE[1] - 10, 100, buf) && romstore_read(s, 1, FILE_SIZE[1], buf, 10) == 0 && romstore_read(s, 1, FILE_SIZE[1] + 5, buf, 10) == 0, "a read past the end is short, at or after the end it is empty");
    CHECK(romstore_read(s, 2, 0, buf, 10) == 0 && romstore_file_size(s, 2) == 0, "an empty file reads nothing");
    romstore_stats q; romstore_get_stats(s, &q);
    CHECK(q.cache_hits > 0 && q.cache_misses > 0 && q.cache_peak <= (1u << 20), "partial reads go through the cache: %llu hits, %llu misses, peak %llu bytes within the 1 MiB bound",
          (unsigned long long)q.cache_hits, (unsigned long long)q.cache_misses, (unsigned long long)q.cache_peak);

    printf("(2) names\n");
    uint32_t idx; int is_dir;
    ok = 1; for (uint32_t i = 0; i < 6; i++) ok &= romstore_lookup(s, FILE_PATH[i], &idx, &is_dir) && !is_dir && idx == i;
    CHECK(ok, "every file is found by its path");
    CHECK(romstore_lookup(s, "", &idx, &is_dir) && is_dir && idx == 0 && romstore_lookup(s, "//a//deep/", &idx, &is_dir) && is_dir && idx == 3, "the root and a directory (repeated slashes)");
    errno = 0; CHECK(!romstore_lookup(s, "/a/nope", &idx, &is_dir) && errno == ENOENT, "a missing name is ENOENT");
    errno = 0; CHECK(!romstore_lookup(s, "/a/one.bin/x", &idx, &is_dir) && errno == ENOTDIR, "a file used as a directory is ENOTDIR");
    CHECK(!romstore_lookup(s, "/A/one.bin", &idx, &is_dir) && !romstore_lookup(s, "/a/one.bi", &idx, &is_dir) && !romstore_lookup(s, "/a/one.binx", &idx, &is_dir), "names match exactly (case, prefixes)");

    printf("(3) concurrent readers, small cache\n");
    romstore *s2 = romstore_open(path, 40000, err, sizeof err);
    worker_arg wa[4]; pthread_t th[4];
    for (int i = 0; i < 4; i++) { wa[i] = (worker_arg){s2, 1234567ull * (i + 1), 0}; pthread_create(&th[i], NULL, worker, &wa[i]); }
    int nbad = 0; for (int i = 0; i < 4; i++) { pthread_join(th[i], NULL); nbad += wa[i].bad; }
    romstore_get_stats(s2, &q);
    CHECK(!nbad && q.cache_peak <= 40000, "4 threads x 3000 random reads all match (%d bad), cache peak %llu <= 40000 bytes", nbad, (unsigned long long)q.cache_peak);
    romstore_close(s2);

    printf("(4) through hle_fs\n");
    setenv("DM_ROMFS", path, 1); setenv("DM_ROMSTORE_CACHE_MB", "1", 1);
    CHECK(h_fs_MountRom("data", NULL, 0) == RES_OK, "MountRom mounts the store named by DM_ROMFS");
    uint64_t h = 0; size_t got = 0; int64_t size = 0;
    CHECK(h_fs_OpenFile(&h, "data:/a/deep/x.bin", MODE_READ) == RES_OK && h, "OpenFile of a store file");
    CHECK(h_fs_GetFileSize(&size, h) == RES_OK && size == 5, "GetFileSize from the index (%lld)", (long long)size);
    CHECK(h_fs_ReadFile(&got, h, 1, buf, 100) == RES_OK && got == 4 && !memcmp(buf, g_data[5] + 1, 4), "ReadFile is short at the end of the file");
    CHECK(h_fs_ReadFileExact(h, 0, buf, 5) == RES_OK && h_fs_ReadFileExact(h, 0, buf, 6) == RES_FAIL, "the exact-read overload fails a short read");
    CHECK(h_fs_ReadFile(&got, h, -1, buf, 1) != RES_OK, "a negative offset fails");
    CHECK(h_fs_WriteFile(h, 0, "x", 1, NULL) != RES_OK && h_fs_SetFileSize(h, 0) != RES_OK, "a store handle cannot be written or resized");
    CHECK(h_fs_GetFileOpenMode(h) == MODE_READ, "the open mode is kept");
    h_fs_CloseFile(h);
    CHECK(h_fs_OpenFile(&h, "data:/a/./deep/../two.bin", MODE_READ) == RES_OK && h_fs_ReadFile(&got, h, 0, buf, 3u << 20) == RES_OK && got == 70000 && !memcmp(buf, g_data[4], 70000), "a path with . and .. resolves and reads the deduplicated file");
    h_fs_CloseFile(h);
    CHECK(h_fs_OpenFile(&h, "data:/a/one.bin", MODE_WRITE) == RES_FAIL, "opening for write fails");
    CHECK(h_fs_OpenFile(&h, "data:/a", MODE_READ) == RES_PATH_NOT_FOUND && h_fs_OpenFile(&h, "data:/nope", MODE_READ) == RES_PATH_NOT_FOUND && h_fs_OpenFile(&h, "data:/../x", MODE_READ) == RES_PATH_NOT_FOUND,
          "a directory, a missing file and a path above the root are not found");
    CHECK(h_fs_CreateFile("data:/new", 1) != RES_OK && h_fs_DeleteFile("data:/z.txt") != RES_OK && h_fs_CreateDirectory("data:/c") != RES_OK, "create and delete fail on the store");
    int32_t type = -1; CHECK(h_fs_GetEntryType(&type, "data:/a") == RES_OK && type == ENT_DIR && h_fs_GetEntryType(&type, "data:/top.bin") == RES_OK && type == ENT_FILE && h_fs_GetEntryType(&type, "data:/zz") == RES_PATH_NOT_FOUND, "GetEntryType");
    uint64_t dh; DirectoryEntry ents[8]; int64_t cnt = 0, total = 0;
    CHECK(h_fs_OpenDirectory(&dh, "data:/", DIRMODE_DIR | DIRMODE_FILE) == RES_OK && h_fs_DirCount(&total, dh) == RES_OK && total == 5, "the root has 5 entries (%lld)", (long long)total);
    int64_t n1 = 0; h_fs_ReadDirectory(&n1, ents, dh, 3); h_fs_ReadDirectory(&cnt, ents + 3, dh, 8);
    CHECK(n1 == 3 && cnt == 2 && !strcmp(ents[0].name, "a") && ents[0].type == ENT_DIR && !strcmp(ents[3].name, "top.bin") && ents[3].size == (int64_t)FILE_SIZE[1] && ents[3].type == ENT_FILE, "ReadDirectory pages through it with names, types and sizes");
    h_fs_CloseDirectory(dh);
    CHECK(h_fs_OpenDirectory(&dh, "data:/a", DIRMODE_FILE) == RES_OK && h_fs_DirCount(&total, dh) == RES_OK && total == 2 && h_fs_ReadDirectory(&cnt, ents, dh, 8) == RES_OK && cnt == 2 && !strcmp(ents[1].name, "two.bin"), "the files-only filter");
    h_fs_CloseDirectory(dh);
    CHECK(h_fs_OpenDirectory(&dh, "data:/top.bin", DIRMODE_FILE) == RES_PATH_NOT_FOUND, "a file is not a directory");

    printf("(5) damage\n");
    FILE *f = fopen(path, "rb"); fseek(f, 0, SEEK_END); long fl = ftell(f); fseek(f, 0, SEEK_SET); uint8_t *img = malloc(fl); fread(img, 1, fl, f); fclose(f);
    romstore_header hh; memcpy(&hh, img, sizeof hh);
    #define TRY(desc, mutate, expect) do { uint8_t *c = malloc(fl); memcpy(c, img, fl); mutate; FILE *o = fopen(bad, "wb"); fwrite(c, 1, fl, o); fclose(o); free(c); \
        romstore *x = romstore_open(bad, 1 << 20, err, sizeof err); CHECK(!x && strstr(err, expect), "%s: refused (%s)", desc, x ? "opened" : err); romstore_close(x); } while (0)
    TRY("a flipped index byte", c[hh.index_off + 3] ^= 1, "checksum");
    TRY("a changed header count", ((romstore_header *)c)->n_refs--, "checksum");
    TRY("another format version", ((romstore_header *)c)->version = 2, "version");
    TRY("bad magic", c[0] = 'X', "not a chunk store");
    { uint8_t *c = img; FILE *o = fopen(bad, "wb"); fwrite(c, 1, fl - 1, o); fclose(o);
      romstore *x = romstore_open(bad, 1 << 20, err, sizeof err); CHECK(!x, "a truncated copy is refused (%s)", x ? "opened" : err); romstore_close(x); }
    { uint8_t *c = malloc(fl); memcpy(c, img, fl); c[sizeof hh + 20] ^= 0x40; FILE *o = fopen(bad, "wb"); fwrite(c, 1, fl, o); fclose(o); free(c);
      romstore *x = romstore_open(bad, 1 << 20, err, sizeof err); int fails_read = 0;
      for (uint32_t i = 0; x && i < 6; i++) { errno = 0; ssize_t r = romstore_read(x, i, 0, buf, 3u << 20); if (r < 0 && errno == EIO) fails_read++; else if (r >= 0 && memcmp(buf, g_data[i], (size_t)r)) fails_read += 100; }
      CHECK(x && fails_read > 0 && fails_read < 100, "a damaged chunk fails the reads that need it with EIO and never returns wrong bytes"); romstore_close(x); }
    romstore_close(s); free(img); free(buf);
    printf("t_romstore: %d/%d passed\n", checks - fails, checks);
    return fails != 0;
}
