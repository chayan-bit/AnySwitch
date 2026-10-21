// hle_nvn.c symbols that nvn_mtl.m calls, for the unit tests that #include nvn_mtl.m and do not link hle_nvn.c (they keep their own stubs for the rest, e.g. prog_key)
// No sparse virtual pool exists here, so the sparse paths are never taken; host memory is always readable
#include <stdatomic.h>
#include <stdint.h>
uint64_t nvn_new_serial(void) { static _Atomic uint64_t n; return ++n; }
int nvn_host_readable(uint64_t a, uint64_t n) { (void)a; (void)n; return 1; }
int nvn_sparse_pool(const void *pool) { (void)pool; return 0; }
uint64_t nvn_sparse_gen(void) { return 0; }
uint64_t nvn_sparse_copy(const void *pool, void *dst, uint64_t a, uint64_t n) { (void)pool; (void)dst; (void)a; (void)n; return 0; }
int nvn_sparse_since(const void *pool, uint64_t a, uint64_t n, uint64_t gen, uint64_t stamp) { (void)pool; (void)a; (void)n; (void)gen; (void)stamp; return 0; }
void nvn_sparse_protect(const void *pool, uint64_t a, uint64_t n) { (void)pool; (void)a; (void)n; }
int nvn_sparse_mapped(const void *pool, uint64_t a, uint64_t n) { (void)pool; (void)a; (void)n; return 0; }
