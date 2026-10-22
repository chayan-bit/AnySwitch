// Chunk store: a game's read-only RomFS as one file of deduplicated, zstd-compressed chunks, read with random access (built by dm/tools/romstore/romstore.py).
// Every file is cut into content-defined chunks; identical chunks are stored once, each as its own zstd frame (content checksum on, no dictionary ID),
// compressed with the store's one dictionary. The file system calls in hle_fs.c read through it when DM_ROMFS names a store file instead of a directory.
//
// Format version 1, little-endian, one file:
//   [header, 128 bytes][pack: the chunk frames][index, at header.index_off, running to the end of the file]
// The index is these arrays back to back, each padded to 8 bytes:
//   dirs[n_dirs]       romstore_dir: dir 0 is the root; a dir's subdirectories are dirs[dir_first, +dir_count) and its files files[file_first, +file_count), each run sorted by name (strcmp)
//   files[n_files]     romstore_file
//   ref_end[n_refs]    u64, the end offset within its file of each chunk reference; a file's references are [ref_first, +ref_count), ascending, the last one equal to the file size
//   ref_chunk[n_refs]  u32, the chunk of each reference
//   chunks[n_chunks]   romstore_chunk: the frame's offset in the file and size, and the chunk's raw size
//   dict[dict_size]    the zstd dictionary (none when dict_size is 0)
//   names              NUL-terminated names; the name fields are byte offsets into it (the root's name is "")
// header.index_sha256 is the SHA-256 of header bytes [0, 56) followed by the whole index; romstore_open checks it and the index's consistency.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define ROMSTORE_MAGIC "DMRSTORE"
#define ROMSTORE_VERSION 1
typedef struct {
    char magic[8];
    uint32_t version, header_size;          // ROMSTORE_VERSION, sizeof(romstore_header)
    uint64_t index_off, index_size;
    uint32_t n_dirs, n_files, n_refs, n_chunks;
    uint32_t dict_size, max_chunk;          // max_chunk: the largest raw chunk size
    uint8_t index_sha256[32];
    uint8_t reserved[40];
} romstore_header;
typedef struct { uint32_t name, parent, dir_first, dir_count, file_first, file_count; } romstore_dir;
typedef struct { uint32_t name, parent, ref_first, ref_count; uint64_t size; } romstore_file;
typedef struct { uint64_t off; uint32_t csize, rsize; } romstore_chunk;
_Static_assert(sizeof(romstore_header) == 128 && sizeof(romstore_dir) == 24 && sizeof(romstore_file) == 24 && sizeof(romstore_chunk) == 16, "romstore layout");

typedef struct romstore romstore;
typedef struct { uint64_t reads, bytes, chunks, cache_hits, cache_misses, cache_bytes, cache_peak; } romstore_stats;

// Opens and checks a store; cache_bytes bounds the cache of decompressed chunks kept for reads that cover only part of a chunk.
// NULL on failure, with the reason in err.
romstore *romstore_open(const char *path, size_t cache_bytes, char *err, size_t errlen);
void romstore_close(romstore *s);
// path: components separated by '/', relative to the root ("" or "/" is the root); "." and ".." are not resolved here.
// 1 = found (*idx is a dir index when *is_dir, else a file index); 0 = not found, errno ENOENT (or ENOTDIR when a file is used as a directory).
int romstore_lookup(const romstore *s, const char *path, uint32_t *idx, int *is_dir);
uint64_t romstore_file_size(const romstore *s, uint32_t file);
// Reads up to n bytes from offset off of a file; short only at the end of the file. -1 with errno EIO on a read error or corrupt data (logged). Thread-safe.
ssize_t romstore_read(romstore *s, uint32_t file, uint64_t off, void *buf, size_t n);
// A directory's entries: its subdirectories, then its files.
uint32_t romstore_dir_entries(const romstore *s, uint32_t dir);
const char *romstore_dir_entry(const romstore *s, uint32_t dir, uint32_t i, int *is_dir, uint64_t *size);
int romstore_fd(const romstore *s);
void romstore_get_stats(romstore *s, romstore_stats *out);
