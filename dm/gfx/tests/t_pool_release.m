// Freed memory pools must not outlive their retirement: pools created, addressed and freed on a thread with no autorelease pool (a game thread) are all deallocated once the GPU passes their fence.
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
enum { NPOOL = 64 };
static uint8_t *g_mem[NPOOL]; static dispatch_semaphore_t g_done_sem, g_exit_sem;
static void *game_thread(void *arg) {   // no @autoreleasepool here, like a guest thread: its implicit pool is only drained at exit, which the test holds off until it has counted
    (void)arg; size_t size = (size_t)getpagesize();
    for (int i = 0; i < NPOOL; i++) {
        if (posix_memalign((void **)&g_mem[i], size, size)) abort();
        void *b; uint64_t off; mtl_pool_add(g_mem[i], size);
        if (!mtl_addr((uint64_t)g_mem[i], 1, &b, &off)) abort();   // first address: the pool enters the residency set
        if (i >= 8) mtl_pool_del(g_mem[i - 8]);   // free with others still registered, as a game does
    }
    for (int i = NPOOL - 8; i < NPOOL; i++) mtl_pool_del(g_mem[i]);
    dispatch_semaphore_signal(g_done_sem); dispatch_semaphore_wait(g_exit_sem, DISPATCH_TIME_FOREVER);
    return NULL;
}
static unsigned long dead_alive(void) { unsigned long n = 0; @autoreleasepool { pthread_mutex_lock(&g_mu); for (id b in g_dead_pools) { (void)b; n++; } pthread_mutex_unlock(&g_mu); } return n; }
int main(void) { @autoreleasepool {
    mtl_init(); g_done_sem = dispatch_semaphore_create(0); g_exit_sem = dispatch_semaphore_create(0);
    pthread_t th; if (pthread_create(&th, NULL, game_thread, NULL)) abort();
    dispatch_semaphore_wait(g_done_sem, DISPATCH_TIME_FOREVER);
    for (int k = 0; k < 4; k++) { mtl_sub_begin(); if (!mtl_wait(mtl_sub_commit(), 5000000000ull)) abort(); }   // the second begin drains what the first one's fence retired
    unsigned long alive = dead_alive();
    dispatch_semaphore_signal(g_exit_sem); pthread_join(th, NULL);
    for (int i = 0; i < NPOOL; i++) free(g_mem[i]);
    int bad = alive != 0;
    printf("t_pool_release: %d freed pools still alive after retirement (want 0)%s\n", (int)alive, bad ? " FAIL" : "");
    return bad;
} }
