/* ============================================================================
 * sw/soc_test/start.S — rv32_soc 统一主存启动桩与通用 M-mode 陷阱入口
 * ============================================================================ */
    .section .text.init, "ax"
    .global _start
    .global trap_entry

_start:
    la   sp, _stack_top
    la   t0, trap_entry
    csrw mtvec, t0

    /* 清零 .bss */
    la   t0, __bss_start
    la   t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

3:
    j    3b

    .align 2
trap_entry:
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   t0,  4(sp)
    sw   t1,  8(sp)
    sw   t2, 12(sp)
    sw   t3, 16(sp)
    sw   t4, 20(sp)
    sw   t5, 24(sp)
    sw   t6, 28(sp)
    sw   a0, 32(sp)
    sw   a1, 36(sp)
    sw   a2, 40(sp)
    sw   a3, 44(sp)
    sw   a4, 48(sp)
    sw   a5, 52(sp)
    sw   a6, 56(sp)
    sw   a7, 60(sp)

    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call c_trap_handler
    /* c_trap_handler 返回新的 mepc (异常时跳过 +4，中断时保持原 mepc) */
    csrw mepc, a0

    lw   ra,  0(sp)
    lw   t0,  4(sp)
    lw   t1,  8(sp)
    lw   t2, 12(sp)
    lw   t3, 16(sp)
    lw   t4, 20(sp)
    lw   t5, 24(sp)
    lw   t6, 28(sp)
    lw   a0, 32(sp)
    lw   a1, 36(sp)
    lw   a2, 40(sp)
    lw   a3, 44(sp)
    lw   a4, 48(sp)
    lw   a5, 52(sp)
    lw   a6, 56(sp)
    lw   a7, 60(sp)
    addi sp, sp, 64
    mret
