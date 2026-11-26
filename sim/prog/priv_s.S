# ============================================================================
# priv_s.S — Phase D1 端到端特权级 + S-CSR + 陷阱委托 + PLIC Context 1 回归测试
# ----------------------------------------------------------------------------
# 运行环境: tb_linux_soc (rv32_soc @ 0x8000_0000, BootROM 跳转至此)
# 覆盖项:
#   1. misa.S/U、medeleg/mideleg WARL、satp ASID=0、mstatus.MPP=2'b10 非法值过滤
#   2. M -> S (MRET) 切换、S-CSR 读写、ECALL_S (9) 进 M-mode
#   3. S-mode 越权 (读 mhartid / 执行 mret) 委托给 S-mode (scause=2, SPP=1)
#   4. TVM (satp + sfence.vma)、TW (wfi)、TSR (sret)、mcounteren/scounteren 陷阱
#   5. S -> U (SRET) 切换、U-mode 越权与 ECALL_U (8) 委托给 S-mode (SPP=0)
#   6. 向量化 stvec + 软件注入 SSIP (1) / M-mode 注入 STIP (5)
#   7. PLIC Context 1 (S-mode) + NS16550A UART THRE -> SEIP (9) Claim/Complete
# 结束协议: 写 tohost (0x8003_F000) = 1 (PASS) / 非 1 错误码 (FAIL) + fence.i
# ============================================================================

.text
.org 0x80000000

_start:
    # 栈与状态变量区: 0x8003_E000 (位于 256 KB RAM 内)
    li   sp, 0x8003E000
    li   s11, 0x8003F000         # tohost 地址
    li   s10, 0x8003E800         # 共享测试计数区:
                                 #   [0]=s_ill_cnt, [4]=m_ill_cnt, [8]=u_ecall_cnt,
                                 #   [12]=ssi_cnt,  [16]=sti_cnt,  [20]=sei_cnt
    sw   zero, 0(s10)
    sw   zero, 4(s10)
    sw   zero, 8(s10)
    sw   zero, 12(s10)
    sw   zero, 16(s10)
    sw   zero, 20(s10)

    # ------------------------------------------------------------------------
    # [Test 1] misa / medeleg / mideleg / satp / mstatus.MPP WARL 检查
    # ------------------------------------------------------------------------
    csrr t0, misa
    li   t1, 0x00140000          # S (bit 18) | U (bit 20)
    and  t2, t0, t1
    bne  t2, t1, fail_1

    li   t0, 0xFFFFFFFF
    csrw medeleg, t0
    csrr t1, medeleg
    li   t2, 0x0000B3FF          # ECALL_M (bit 11) 与 10/14 必须硬连 0
    bne  t1, t2, fail_2

    csrw mideleg, t0
    csrr t1, mideleg
    li   t2, 0x00000222          # 仅 SSIP(1)/STIP(5)/SEIP(9)
    bne  t1, t2, fail_3

    li   t0, 0x7FC00123          # MODE=0, ASID=0x1FF, PPN=0x123
    csrw satp, t0
    csrr t1, satp
    li   t2, 0x00000123          # ASID 硬连 0, PPN 保留
    bne  t1, t2, fail_4
    csrw satp, zero

    # 尝试写入 mstatus.MPP = 2'b10 (保留值)，应维持原合法值 (2'b11)
    li   t0, 0x00001800          # 先设为 2'b11
    csrw mstatus, t0
    li   t0, 0x00001000          # 尝试写 2'b10
    csrw mstatus, t0
    csrr t1, mstatus
    srli t1, t1, 11
    andi t1, t1, 3
    li   t2, 2
    beq  t1, t2, fail_5

    # ------------------------------------------------------------------------
    # 安装 M-mode 与 S-mode 陷阱入口并设置委托
    # ------------------------------------------------------------------------
    li   t0, m_trap_handler
    csrw mtvec, t0
    li   t0, s_trap_handler
    csrw stvec, t0

    # 委托 ECALL_U(8) 与 ILLEGAL(2) 给 S-mode; ECALL_S(9) 留给 M-mode (SBI)
    li   t0, 0x00000104          # (1<<8) | (1<<2)
    csrw medeleg, t0
    li   t0, 0x00000222          # 委托 SSIP/STIP/SEIP 给 S-mode
    csrw mideleg, t0
    csrw mcounteren, zero        # 初始禁止 S/U 读 cycle/time/instret
    csrw scounteren, zero

    # ------------------------------------------------------------------------
    # [Test 2] M-mode -> S-mode (MRET, MPP=01) + SBI ECALL_S (9)
    # ------------------------------------------------------------------------
    li   t0, 0x00000800          # MPP=01 (S), MPIE=0, MIE=0
    csrw mstatus, t0
    li   t0, s_entry
    csrw mepc, t0
    mret

s_entry:
    # 确认在 S-mode: 读写 sstatus (SUM=bit18, MXR=bit19)
    li   t0, 0x000C0000
    csrs sstatus, t0
    csrr t1, sstatus
    and  t1, t1, t0
    bne  t1, t0, fail_10
    csrc sstatus, t0

    # 发起 SBI 调用 (ECALL_S -> M-mode, a7=1 查询 SBI 魔数)
    li   a7, 1
    li   a0, 0
    ecall
    li   t0, 0x5B100001
    bne  a0, t0, fail_11

    # ------------------------------------------------------------------------
    # [Test 3] S-mode 越权 (读 mhartid / 执行 mret / 读 cycle) 委托给 S-mode
    # ------------------------------------------------------------------------
    sw   zero, 0(s10)
    csrr t0, mhartid             # 应触发非法指令 (scause=2, SPP=1)
    mret                         # 应触发非法指令 (scause=2, SPP=1)
    csrr t0, cycle               # mcounteren=0 -> 非法指令 (scause=2)
    lw   t0, 0(s10)
    li   t1, 3
    bne  t0, t1, fail_12

    # 通过 SBI(a7=2) 开启 mcounteren=7，再读 cycle 应成功 (不触发陷阱)
    li   a7, 2
    li   a0, 7
    ecall
    csrr t0, cycle               # 合法
    csrr t1, time                # 合法
    lw   t2, 0(s10)
    li   t3, 3
    bne  t2, t3, fail_13

    # ------------------------------------------------------------------------
    # [Test 4] TVM / TW / TSR 陷阱位检验
    # ------------------------------------------------------------------------
    # 通过 SBI(a7=3) 设置 mstatus.TVM=1, TW=1
    li   a7, 3
    li   a0, 0x00300000          # TVM(20) | TW(21)
    ecall
    sw   zero, 0(s10)
    csrr t0, satp                # TVM=1 -> 非法 (scause=2)
    sfence.vma                   # TVM=1 -> 非法 (scause=2)
    wfi                          # TW=1  -> 非法 (scause=2)
    lw   t0, 0(s10)
    li   t1, 3
    bne  t0, t1, fail_14

    # 通过 SBI(a7=4) 关闭 TVM/TW、打开 TSR=1 并取消 ILLEGAL 委托以测试 SRET 陷入 M-mode
    li   a7, 4
    ecall
    sw   zero, 4(s10)
    sret                         # TSR=1 -> 非法, 陷入 M-mode (mcause=2)!
    lw   t0, 4(s10)
    li   t1, 1
    bne  t0, t1, fail_15

    # 恢复 TVM=TW=TSR=0 且重新委托 ILLEGAL 给 S-mode (SBI a7=5)
    li   a7, 5
    ecall
    # 现在 S-mode 的 sfence.vma 必须合法执行
    sfence.vma
    lw   t0, 0(s10)
    li   t1, 3
    bne  t0, t1, fail_16

    # ------------------------------------------------------------------------
    # [Test 5] S-mode -> U-mode (SRET, SPP=0) + U 越权 + ECALL_U (8)
    # ------------------------------------------------------------------------
    csrw scounteren, zero
    sw   zero, 0(s10)
    sw   zero, 8(s10)
    li   t0, 0x00000100          # 清除 SPP(bit8) -> 返回 U-mode
    csrc sstatus, t0
    li   t0, u_entry
    csrw sepc, t0
    sret

u_entry:
    # U-mode 访问 S-CSR、SRET、cycle (scounteren=0) 均应触发非法指令 (scause=2, SPP=0)
    csrr t0, sstatus             # 越权 #1
    sret                         # 越权 #2
    sfence.vma                   # 越权 #3
    wfi                          # 越权 #4
    csrr t0, cycle               # scounteren=0 越权 #5

    # U-mode 系统调用 ECALL_U (scause=8, a7=1 -> 打开 scounteren=7 并返回魔数)
    li   a7, 1
    li   a0, 0
    ecall
    li   t0, 0x575CA110
    bne  a0, t0, fail_20

    # 现在 U-mode 读 cycle 应合法成功
    csrr t0, cycle

    # 发起退出 U-mode 返回 S-mode 的系统调用 (a7=99)
    li   a7, 99
    ecall
    j    fail_21                 # 绝不应执行到此处

s_after_u:
    # 校验 U-mode 恰好触发 5 次非法指令 + 2 次 ECALL_U
    lw   t0, 0(s10)
    li   t1, 5
    bne  t0, t1, fail_22
    lw   t0, 8(s10)
    li   t1, 2
    bne  t0, t1, fail_23

    # ------------------------------------------------------------------------
    # [Test 6] 向量化 stvec + 软件注入 SSIP (1) & M-mode 注入 STIP (5)
    # ------------------------------------------------------------------------
    li   t0, s_vec_table
    ori  t0, t0, 1               # MODE = 01 (Vectored)
    csrw stvec, t0

    li   t0, 0x00000222          # sie = SSIE(1) | STIE(5) | SEIE(9)
    csrw sie, t0
    li   t0, 0x00000002          # sstatus.SIE = 1
    csrs sstatus, t0

    # 6a. 在 S-mode 置位 sip.SSIP (bit 1) -> 应立即跳 s_vec_table + 4
    csrsi sip, 2
    nop
    nop
    lw   t0, 12(s10)
    li   t1, 1
    bne  t0, t1, fail_30

    # 6b. 通过 SBI(a7=6) 让 M-mode 置位 mip.STIP (bit 5) -> 应跳 s_vec_table + 20
    li   a7, 6
    ecall
    nop
    nop
    lw   t0, 16(s10)
    li   t1, 1
    bne  t0, t1, fail_31

    # ------------------------------------------------------------------------
    # [Test 7] PLIC Context 1 (S-mode) + NS16550A UART THRE -> SEIP (9)
    # ------------------------------------------------------------------------
    li   t0, 0x0C000000          # PLIC base
    li   t1, 3
    sw   t1, 4(t0)               # Source 1 (UART) priority = 3
    li   t2, 0x0C002000
    sw   zero, 0(t2)             # Context 0 (M-mode) enable = 0 (绝不触发 MEIP)
    li   t2, 0x0C002080
    li   t1, 2                   # bit 1 = Source 1
    sw   t1, 0(t2)               # Context 1 (S-mode) enable = Source 1
    li   t2, 0x0C201000
    sw   zero, 0(t2)             # Context 1 threshold = 0

    # 打开 NS16550A UART THRE 中断 (IER = 0x02 @ 0x1000_0004)
    li   t0, 0x10000000
    li   t1, 0x02
    sb   t1, 4(t0)

    # 等待 SEIP 中断完成 (PLIC 寄存 1 拍 + CPU 响应)
    li   t3, 200
wait_sei:
    lw   t0, 20(s10)
    bnez t0, sei_done
    addi t3, t3, -1
    bnez t3, wait_sei
    j    fail_32

sei_done:
    li   t1, 1
    bne  t0, t1, fail_33

    # 确认再次 Claim Context 1 返回 0 (中断已正确 Complete)
    li   t2, 0x0C201004
    lw   t0, 0(t2)
    bnez t0, fail_34

    # 全部通过! 写 tohost=1 并执行 fence.i 清洗 D-Cache
    li   t0, 1
    sw   t0, 0(s11)
    fence.i
pass_spin:
    j    pass_spin

# ============================================================================
# 失败路径 (将错误码写入 tohost 并清洗 D-Cache)
# ============================================================================
fail_1:  li a0, 101
         j  do_fail
fail_2:  li a0, 102
         j  do_fail
fail_3:  li a0, 103
         j  do_fail
fail_4:  li a0, 104
         j  do_fail
fail_5:  li a0, 105
         j  do_fail
fail_10: li a0, 110
         j  do_fail
fail_11: li a0, 111
         j  do_fail
fail_12: li a0, 112
         j  do_fail
fail_13: li a0, 113
         j  do_fail
fail_14: li a0, 114
         j  do_fail
fail_15: li a0, 115
         j  do_fail
fail_16: li a0, 116
         j  do_fail
fail_20: li a0, 120
         j  do_fail
fail_21: li a0, 121
         j  do_fail
fail_22: li a0, 122
         j  do_fail
fail_23: li a0, 123
         j  do_fail
fail_30: li a0, 130
         j  do_fail
fail_31: li a0, 131
         j  do_fail
fail_32: li a0, 132
         j  do_fail
fail_33: li a0, 133
         j  do_fail
fail_34: li a0, 134
         j  do_fail
fail_m:  li a0, 200
         j  do_fail
fail_s:  li a0, 201
         j  do_fail

do_fail:
    sw   a0, 0(s11)
    fence.i
fail_spin:
    j    fail_spin

# ============================================================================
# M-mode 陷阱处理程序 (模拟 OpenSBI 服务)
# ============================================================================
.align 4
m_trap_handler:
    csrr t0, mcause
    li   t1, 9                   # CAUSE_ECALL_S
    beq  t0, t1, m_ecall_s
    li   t1, 2                   # CAUSE_ILLEGAL (仅 Test 4 的 TSR=1 SRET 测试)
    beq  t0, t1, m_ill
    j    fail_m

m_ill:
    lw   t2, 4(s10)
    addi t2, t2, 1
    sw   t2, 4(s10)
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    mret

m_ecall_s:
    # 校验 MPP 必须为 2'b01 (来自 S-mode)
    csrr t0, mstatus
    srli t0, t0, 11
    andi t0, t0, 3
    li   t1, 1
    bne  t0, t1, fail_m

    li   t1, 1
    beq  a7, t1, sbi_magic
    li   t1, 2
    beq  a7, t1, sbi_set_mcnt
    li   t1, 3
    beq  a7, t1, sbi_set_mstatus_bits
    li   t1, 4
    beq  a7, t1, sbi_test_tsr
    li   t1, 5
    beq  a7, t1, sbi_restore_s
    li   t1, 6
    beq  a7, t1, sbi_inject_stip
    li   t1, 7
    beq  a7, t1, sbi_clear_stip
    j    fail_m

sbi_magic:
    li   a0, 0x5B100001
    j    m_ecall_ret

sbi_set_mcnt:
    csrw mcounteren, a0
    j    m_ecall_ret

sbi_set_mstatus_bits:
    csrs mstatus, a0
    j    m_ecall_ret

sbi_test_tsr:
    li   t2, 0x00300000          # 清除 TVM/TW
    csrc mstatus, t2
    li   t2, 0x00400000          # 置位 TSR (bit 22)
    csrs mstatus, t2
    li   t2, 0x00000100          # 仅委托 ECALL_U(8), 取消 ILLEGAL(2) 委托
    csrw medeleg, t2
    j    m_ecall_ret

sbi_restore_s:
    li   t2, 0x00700000          # 清除 TSR/TW/TVM
    csrc mstatus, t2
    li   t2, 0x00000104          # 恢复委托 ECALL_U(8) | ILLEGAL(2)
    csrw medeleg, t2
    j    m_ecall_ret

sbi_inject_stip:
    li   t2, 0x00000020          # mip.STIP = 1 (bit 5)
    csrs mip, t2
    j    m_ecall_ret

sbi_clear_stip:
    li   t2, 0x00000020          # mip.STIP = 0 (bit 5)
    csrc mip, t2
    j    m_ecall_ret

m_ecall_ret:
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    mret

# ============================================================================
# S-mode 直接模式陷阱处理程序 (Tests 2..5)
# ============================================================================
.align 4
s_trap_handler:
    csrr t0, scause
    li   t1, 2                   # CAUSE_ILLEGAL
    beq  t0, t1, s_ill
    li   t1, 8                   # CAUSE_ECALL_U
    beq  t0, t1, s_ecall_u
    j    fail_s

s_ill:
    lw   t2, 0(s10)
    addi t2, t2, 1
    sw   t2, 0(s10)
    csrr t2, sepc
    addi t2, t2, 4
    csrw sepc, t2
    sret

s_ecall_u:
    # 校验 sstatus.SPP 必须为 0 (来自 U-mode)
    csrr t0, sstatus
    andi t0, t0, 0x100
    bnez t0, fail_s

    lw   t2, 8(s10)
    addi t2, t2, 1
    sw   t2, 8(s10)

    li   t1, 99
    beq  a7, t1, s_u_exit
    li   t1, 1
    bne  a7, t1, fail_s

    # 开启 scounteren=7 并返回魔数给 U-mode
    li   t2, 7
    csrw scounteren, t2
    li   a0, 0x575CA110
    csrr t2, sepc
    addi t2, t2, 4
    csrw sepc, t2
    sret

s_u_exit:
    # 设 SPP=1 并将 sepc 指向 s_after_u，借 sret 回到 S-mode 主流程
    li   t2, 0x100
    csrs sstatus, t2
    li   t2, s_after_u
    csrw sepc, t2
    sret

# ============================================================================
# S-mode 向量表 (stvec = s_vec_table | 1, Tests 6..7)
# ============================================================================
.align 6
s_vec_table:
    j    s_trap_handler          # 0: 同步异常
    j    s_irq_ssi               # 1: Supervisor Software Interrupt (SSIP)
    j    fail_s                  # 2
    j    fail_s                  # 3
    j    fail_s                  # 4
    j    s_irq_sti               # 5: Supervisor Timer Interrupt (STIP)
    j    fail_s                  # 6
    j    fail_s                  # 7
    j    fail_s                  # 8
    j    s_irq_sei               # 9: Supervisor External Interrupt (SEIP)

s_irq_ssi:
    csrr t0, scause
    li   t1, 0x80000001
    bne  t0, t1, fail_s
    csrci sip, 2                 # 清除 sip.SSIP
    lw   t2, 12(s10)
    addi t2, t2, 1
    sw   t2, 12(s10)
    sret

s_irq_sti:
    csrr t0, scause
    li   t1, 0x80000005
    bne  t0, t1, fail_s
    li   a7, 7                   # 调 SBI 清除 mip.STIP (嵌套进 M-mode!)
    ecall
    lw   t2, 16(s10)
    addi t2, t2, 1
    sw   t2, 16(s10)
    sret

s_irq_sei:
    csrr t0, scause
    li   t1, 0x80000009
    bne  t0, t1, fail_s

    # PLIC Context 1 Claim (0x0C20_1004)
    li   t0, 0x0C201004
    lw   t1, 0(t0)
    li   t2, 1                   # 必为 Source 1 (NS16550A UART)
    bne  t1, t2, fail_s

    # 关闭 UART THRE 中断并打印 "PS\n"
    li   t3, 0x10000000
    sb   zero, 4(t3)             # IER = 0
    li   t2, 80                  # 'P'
    sb   t2, 0(t3)
    li   t2, 83                  # 'S'
    sb   t2, 0(t3)
    li   t2, 10                  # '\n'
    sb   t2, 0(t3)

    # PLIC Context 1 Complete
    sw   t1, 0(t0)

    lw   t2, 20(s10)
    addi t2, t2, 1
    sw   t2, 20(s10)
    sret
