// Background slots: at most n jobs in flight at one QoS, without parking a GCD worker thread per waiting job (the program warm-up and the record-time kick, nvn_mtl.m).
// n serial queues, jobs handed out round robin. The earlier form, a semaphore taken inside a global-queue block, parked one worker per queued job: a game creates hundreds of programs
// while it loads, and those parked blocks used up the process's worker pool, so the pipeline a draw waits for (nvn_flexpso.m, also on a global queue) did not start for about a second.
// Unit test: tests/t_flexpso.m.
#pragma once
#include <dispatch/dispatch.h>
#include <stdatomic.h>

enum { BGQ_MAX = 8 };
typedef struct { dispatch_queue_t q[BGQ_MAX]; int n; _Atomic unsigned next; } nvn_bgq;

// n slots (clamped to 1..BGQ_MAX) at qos
static inline void bgq_init(nvn_bgq *b, int n, qos_class_t qos, const char *label) {
    b->n = n < 1 ? 1 : n > BGQ_MAX ? BGQ_MAX : n; atomic_init(&b->next, 0);
    dispatch_queue_attr_t a = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, qos, 0);
    for (int i = 0; i < b->n; i++) b->q[i] = dispatch_queue_create(label, a);
}
// ponytail: round robin, so a slow job holds back the jobs queued behind it on its slot while another slot may idle; a shared work list if that ever shows in the warm-up times
static inline void bgq_async(nvn_bgq *b, dispatch_block_t f) { dispatch_async(b->q[atomic_fetch_add(&b->next, 1) % (unsigned)b->n], f); }
