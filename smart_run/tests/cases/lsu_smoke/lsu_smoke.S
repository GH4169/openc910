    .option norvc
    .option norelax
    .text
    .globl _start
_start:
    la      t0, trap
    csrw    mtvec, t0

    li      t0, 0x70013          # MCOR: invalidate caches and predictors
    csrs    0x7c2, t0
    li      t0, 0x7              # MHCR: I-cache, D-cache, write allocate
    csrs    0x7c1, t0

    la      s0, test_data
    li      t0, 0x0123456789abcdef
    li      t1, 0xfedcba9876543210
    li      t2, 0x13579bdf2468ace0

cold_load:
    ld      t3, 0(s0)
    xor     t3, t3, t0
    bnez    t3, fail
    fence   rw, rw

    # Keep the warm address dependent on the cold result. Give the linefill
    # time to finish even if the front end speculates across the branch.
    .rept 24
    addi    t3, t3, 1
    .endr
    addi    t3, t3, -24
    add     s1, s0, t3

warm_load:
    ld      t4, 8(s1)
    xor     t4, t4, t1
    bnez    t4, fail
    add     s1, s0, t4

store_and_load:
    sd      t2, 8(s1)
    ld      t5, 8(s1)
    bne     t5, t2, fail
    fence   rw, rw

load_after_fence:
    ld      t6, 8(s0)
    bne     t6, t2, fail

    .globl lsu_test_pass
lsu_test_pass:
    j       lsu_test_pass

trap:
    csrr    t0, mcause
fail:
    .globl lsu_test_fail
lsu_test_fail:
    j       lsu_test_fail

    .data
    .balign 64
test_data:
    .dword  0x0123456789abcdef
    .dword  0xfedcba9876543210
