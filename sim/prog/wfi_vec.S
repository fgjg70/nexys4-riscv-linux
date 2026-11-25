# =============================================================================
# wfi_vec.S — WFI 唤醒语义 + 向量化 mtvec (mode=1) 中断分发自校验 (tb_soc)
# -----------------------------------------------------------------------------
# 覆盖:
#   1) 向量化 mtvec (base | 1):
#      - 同步异常 (ECALL) 跳 base + 0
#      - 定时器中断 (IRQ 7) 跳 base + 4*7 = base + 28
#   2) WFI 在 mstatus.MIE=0 但 mie.MTIE=1 时停顿至 mtime >= mtimecmp 后直接
#      从下一条指令继续执行 (不陷入，符合 RISC-V Priv Spec §3.3.3)
#   3) WFI 在 mstatus.MIE=1 且 mie.MTIE=1 时停顿至中断到达，进入向量槽 7，
#      且 mepc 精确等于 WFI 之后下一条指令的地址 (wfi_pc + 4)
#   4) 收尾满足 tb_soc 协议: gpio_out=0x5A5A5A5A, UART 环回 "OK\n", tohost=1
# =============================================================================

    .text
    # 跳到主程序，紧随其后放 4 字节对齐的向量表 (base = vec_table)
    j    start

    .align 2
vec_table:
    j    exc_handler            # +0  (0): 同步异常
    j    bad_vec                # +4  (1)
    j    bad_vec                # +8  (2)
    j    bad_vec                # +12 (3): MSI
    j    bad_vec                # +16 (4)
    j    bad_vec                # +20 (5)
    j    bad_vec                # +24 (6)
    j    tmr_handler            # +28 (7): MTI (定时器中断向量槽!)
    j    bad_vec                # +32 (8)
    j    bad_vec                # +36 (9)
    j    bad_vec                # +40 (10)
    j    bad_vec                # +44 (11): MEI

start:
    li   s1, vec_table
    ori  s1, s1, 1              # mode = 1 (Vectored)
    csrw mtvec, s1

    li   s2, 0                  # exc 进入次数
    li   s3, 0                  # tmr 进入次数
    li   s4, 0                  # 异常/中断失败标记
    li   s5, 0                  # 捕获到的 tmr mepc

    # -------- 1. 向量模式下同步异常仍跳槽 0 --------
    ecall
    li   t0, 1
    bne  s2, t0, fail1
    bne  s4, zero, fail1

    # -------- 2. WFI (MIE=0, MTIE=1): 停顿等待定时到期后直接继续，不进陷阱 --------
    li   t0, 0x80               # MTIE = bit 7
    csrw mie, t0
    csrci mstatus, 8            # MIE = 0

    li   t0, 0xA0000030         # MTIME_LO
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    addi t1, t1, 120            # 120 拍后到期
    li   t0, 0xA0000028         # MTIMECMP_LO
    sw   t1, 0(t0)
    sw   t2, 4(t0)

    wfi                         # 停顿至 mtime >= mtimecmp

    # 确认醒来时 mtime 已 >= mtimecmp，且没有进中断 (s3 仍为 0)
    li   t0, 0xA0000030
    lw   t3, 0(t0)
    bltu t3, t1, fail2
    bne  s3, zero, fail2

    # 推远 mtimecmp 先清中断电平
    li   t4, 0x100000
    add  t3, t3, t4
    li   t0, 0xA0000028
    sw   t3, 0(t0)
    sw   t2, 4(t0)

    # -------- 3. WFI (MIE=1, MTIE=1): 唤醒后跳向量槽 7 且 mepc == wfi_after --------
    li   t0, 0xA0000030
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    addi t1, t1, 120
    li   t0, 0xA0000028
    sw   t1, 0(t0)
    sw   t2, 4(t0)

    csrsi mstatus, 8            # MIE = 1
    wfi
wfi_after:
    nop
    li   t0, 1
    bne  s3, t0, fail3
    bne  s4, zero, fail3
    li   t0, wfi_after
    bne  s5, t0, fail3          # 规范 §3.3.3: mepc 必须指向 WFI 后一条指令!

    # -------- 4. tb_soc 收尾协议 (GPIO + UART 环回 "OK\n") --------
    li   t0, 0xA0000000
    li   t1, 0x5A5A5A5A
    sw   t1, 0(t0)

    li   s1, 0x90001010
    li   t1, 0x4F
    jal  ra, loopback
    li   t1, 0x4B
    jal  ra, loopback
    li   t1, 0x0A
    jal  ra, loopback

    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

exc_handler:
    csrr t6, mcause
    li   t5, 11                 # ECALL_M
    bne  t6, t5, exc_bad
    addi s2, s2, 1
    j    exc_ret
exc_bad:
    li   s4, 1
exc_ret:
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

tmr_handler:
    csrr t6, mcause
    li   t5, 0x80000007
    bne  t6, t5, tmr_bad
    csrr s5, mepc
    addi s3, s3, 1
    j    tmr_clr
tmr_bad:
    li   s4, 2
tmr_clr:
    li   t0, 0xA0000030
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    li   t3, 0x200000
    add  t1, t1, t3
    sltu t4, t1, t3
    add  t2, t2, t4
    li   t0, 0xA0000028
    sw   t1, 0(t0)
    sw   t2, 4(t0)
    mret

bad_vec:
    li   s4, 9
    mret

putc:
    li   t0, 0xA0000014
putc_poll:
    lw   t5, 0(t0)
    bne  t5, zero, putc_poll
    li   t0, 0xA0000010
    sw   t1, 0(t0)
    ret

loopback:
    mv   s0, ra
    jal  ra, putc
    li   t0, 0xA000001C
lb_poll:
    lw   t5, 0(t0)
    beq  t5, zero, lb_poll
    li   t0, 0xA0000018
    lw   t6, 0(t0)
    sw   t6, 0(s1)
    addi s1, s1, 4
    mv   ra, s0
    ret

fail1:
    li   a0, 0x90002000
    li   a1, 2
    sw   a1, 0(a0)
    j    done
fail2:
    li   a0, 0x90002000
    li   a1, 3
    sw   a1, 0(a0)
    j    done
fail3:
    li   a0, 0x90002000
    li   a1, 4
    sw   a1, 0(a0)
    j    done

done:
    j    done
