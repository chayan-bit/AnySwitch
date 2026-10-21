// t_gate_cost: call sites shaped like the rewriter's gate block (patch_nso.py site_gate: stp x29, x30; bl to the gate; ldp x29, x30), one per gate kind.
// The return points are exported so the test can register them with gate_register, the way the loader registers gates.tsv.
    .text
    .globl _call_tick, _call_svc, _call_tick_ret, _call_svc_ret
    .p2align 2
_call_tick:
    stp x29, x30, [sp, #-16]!
    bl _dm_gate
1:  ldp x29, x30, [sp], #16
    ret
    .p2align 2
_call_svc:
    stp x29, x30, [sp, #-16]!
    bl _dm_gate
2:  ldp x29, x30, [sp], #16
    ret
    .data
    .p2align 3
_call_tick_ret: .quad 1b
_call_svc_ret: .quad 2b

// _call_check: load known values into every register the gate must keep (x1-x17, x19-x28, v0-v31, NZCV, a non-default FPCR), go through the gate as SVC 0x10
// (which writes only x0), then store what came back into _check_dump for the C side to compare: x1..x30 at 8*i, v0..v31 at 256 + 16*i, NZCV at 768, FPCR at 776
    .text
    .globl _call_check, _call_check_ret
    .p2align 2
_call_check:
    sub sp, sp, #176
    stp x19, x20, [sp, #0]
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x9, fpcr
    str x9, [sp, #160]
    movz x9, #0xC0, lsl #16      // FPCR.RMode = toward zero
    msr fpcr, x9
    movz x9, #0xA000, lsl #16    // N and C set
    msr nzcv, x9
    movi v0.16b, #1
    movi v1.16b, #2
    movi v2.16b, #3
    movi v3.16b, #4
    movi v4.16b, #5
    movi v5.16b, #6
    movi v6.16b, #7
    movi v7.16b, #8
    movi v8.16b, #9
    movi v9.16b, #10
    movi v10.16b, #11
    movi v11.16b, #12
    movi v12.16b, #13
    movi v13.16b, #14
    movi v14.16b, #15
    movi v15.16b, #16
    movi v16.16b, #17
    movi v17.16b, #18
    movi v18.16b, #19
    movi v19.16b, #20
    movi v20.16b, #21
    movi v21.16b, #22
    movi v22.16b, #23
    movi v23.16b, #24
    movi v24.16b, #25
    movi v25.16b, #26
    movi v26.16b, #27
    movi v27.16b, #28
    movi v28.16b, #29
    movi v29.16b, #30
    movi v30.16b, #31
    movi v31.16b, #32
    mov x1, #0x1001
    mov x2, #0x1002
    mov x3, #0x1003
    mov x4, #0x1004
    mov x5, #0x1005
    mov x6, #0x1006
    mov x7, #0x1007
    mov x8, #0x1008
    mov x9, #0x1009
    mov x10, #0x100a
    mov x11, #0x100b
    mov x12, #0x100c
    mov x13, #0x100d
    mov x14, #0x100e
    mov x15, #0x100f
    mov x16, #0x1010
    mov x17, #0x1011
    mov x19, #0x1013
    mov x20, #0x1014
    mov x21, #0x1015
    mov x22, #0x1016
    mov x23, #0x1017
    mov x24, #0x1018
    mov x25, #0x1019
    mov x26, #0x101a
    mov x27, #0x101b
    mov x28, #0x101c
    stp x29, x30, [sp, #-16]!
    bl _dm_gate
3:  ldp x29, x30, [sp], #16
    adrp x0, _check_dump@PAGE
    add x0, x0, _check_dump@PAGEOFF
    stp x1, x2, [x0, #8]
    stp x3, x4, [x0, #24]
    stp x5, x6, [x0, #40]
    stp x7, x8, [x0, #56]
    stp x9, x10, [x0, #72]
    stp x11, x12, [x0, #88]
    stp x13, x14, [x0, #104]
    stp x15, x16, [x0, #120]
    stp x17, x18, [x0, #136]
    stp x19, x20, [x0, #152]
    stp x21, x22, [x0, #168]
    stp x23, x24, [x0, #184]
    stp x25, x26, [x0, #200]
    stp x27, x28, [x0, #216]
    stp x29, x30, [x0, #232]
    stp q0, q1, [x0, #256]
    stp q2, q3, [x0, #288]
    stp q4, q5, [x0, #320]
    stp q6, q7, [x0, #352]
    stp q8, q9, [x0, #384]
    stp q10, q11, [x0, #416]
    stp q12, q13, [x0, #448]
    stp q14, q15, [x0, #480]
    stp q16, q17, [x0, #512]
    stp q18, q19, [x0, #544]
    stp q20, q21, [x0, #576]
    stp q22, q23, [x0, #608]
    stp q24, q25, [x0, #640]
    stp q26, q27, [x0, #672]
    stp q28, q29, [x0, #704]
    stp q30, q31, [x0, #736]
    mrs x1, nzcv
    str x1, [x0, #768]
    mrs x1, fpcr
    str x1, [x0, #776]
    ldr x9, [sp, #160]
    msr fpcr, x9
    ldp x19, x20, [sp, #0]
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    add sp, sp, #176
    ret
    .data
    .p2align 3
_call_check_ret: .quad 3b
    .globl _check_dump
    .p2align 4
_check_dump: .space 784
