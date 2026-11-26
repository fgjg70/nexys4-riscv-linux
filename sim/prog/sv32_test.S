# ============================================================================
# sv32_test.S — Phase D2 Sv32 完整端到端虚拟内存压力回归测试
# ----------------------------------------------------------------------------
# 覆盖项:
#   1. 回写 D-Cache 脏页表一致性 (建表后刻意不执行 fence.i, PTW 直读 D-Cache 脏行)
#   2. 4 MB 巨页 (内核代码 + NS16550A UART) + 4 KB 二级页表翻译
#   3. 共享物理页双虚址映射 (验证 VIPT 与 256 B 物理标签 L0D 零别名)
#   4. 跨 4 KB 页边界非对齐 Store/Load (0xC000_0FFE .. 0xC000_1001)
#   5. SUM=0/1、MXR=0/1、只读页 Store 与 AMOADD.W 缺页 (Cause 13/15 + stval)
#   6. 软件 A/D 位缺页按需修复 (脏 D-Cache 改 PTE + sfence.vma + 原地重试)
#   7. 动态重映射 + sfence.vma、非对齐巨页 (PPN[0]!=0)、无效页 (V=0)
#   8. U-mode 虚拟空间取指/访存 + S-mode 即使 SUM=1 取指 U 页必报 Cause 12
#   9. M-mode MPRV=1 + MPP=S 物理取指叠加 Sv32 数据翻译
# ============================================================================

.text
.org 0x80000000

_start:
    li   sp, 0x8003E000
    li   s11, 0x8003F000         # tohost 物理地址
    li   s10, 0x8003E800         # 陷阱状态记录区 (位于 4 MB 内核恒等映射内):
                                 #   [0]=last_scause, [4]=last_stval, [8]=pf_cnt,
                                 #   [12]=pf_mode (0=skip+4, 1=fix_D, 2=fix_A, 3=ret_ra),
                                 #   [16]=u_done

    # 清零 L1 页表 (0x8002_0000, 4 KB) 与 L0 页表 (0x8002_1000, 4 KB)
    # 注意: 全部写入仅留在回写 D-Cache 脏行，刻意不执行 fence.i!
    li   t0, 0x80020000
    li   t1, 0x80022000
zero_pt:
    sw   zero, 0(t0)
    addi t0, t0, 4
    blt  t0, t1, zero_pt

    # 预先在目标物理页写入初值 (用于验证重映射、MXR、A=0、RO 页)
    li   t0, 0x80033000          # PA for X-only (L0[4])
    li   t1, 0x13572468
    sw   t1, 0(t0)
    li   t0, 0x80034000          # PA for D=0 page (L0[5])
    li   t1, 0xAAAA5555
    sw   t1, 0(t0)
    li   t0, 0x80035000          # PA for A=0 page (L0[6])
    li   t1, 0x76543210
    sw   t1, 0(t0)
    li   t0, 0x80037000          # PA for RO page (L0[9])
    li   t1, 0x00000100
    sw   t1, 0(t0)

    # 拷贝 4 条 U-mode 测试指令到 PA 0x8003_6000 (映射至 VA 0xC000_7000)
    #   lw   a1, 0(a2)       (0x00062583)
    #   addi a1, a1, 1       (0x00158593)
    #   sw   a1, 0(a2)       (0x00b62023)
    #   ecall                (0x00000073)
    li   t0, 0x80036000
    li   t1, 0x00062583
    sw   t1, 0(t0)
    li   t1, 0x00158593
    sw   t1, 4(t0)
    li   t1, 0x00b62023
    sw   t1, 8(t0)
    li   t1, 0x00000073
    sw   t1, 12(t0)
    fence.i                      # 仅刷新代码区以便 I-Cache 可见 U-mode 指令

    # ------------------------------------------------------------------------
    # [Test 1] 在回写 D-Cache 中构建 Sv32 页表 (此后绝不执行 fence.i!)
    # ------------------------------------------------------------------------
    # L1[512] @ 0x8002_0800: VA 0x8000_0000 -> PA 0x8000_0000 (4 MB 巨页, V|R|W|X|A|D = 0xCF)
    #   PPN = 0x80000 -> (0x80000 << 10) | 0xCF = 0x2000_00CF
    li   t0, 0x80020800
    li   t1, 0x200000CF
    sw   t1, 0(t0)

    # L1[64] @ 0x8002_0100: VA 0x1000_0000 -> PA 0x1000_0000 (4 MB UART MMIO 巨页, V|R|W|A|D = 0xC7)
    #   PPN = 0x10000 -> (0x10000 << 10) | 0xC7 = 0x0400_00C7
    li   t0, 0x80020100
    li   t1, 0x040000C7
    sw   t1, 0(t0)

    # L1[768] @ 0x8002_0C00: VA 0xC000_0000 -> 指向 L0 页表 PA 0x8002_1000 (V=1)
    #   PPN = 0x80021 -> (0x80021 << 10) | 0x01 = 0x2000_8401
    li   t0, 0x80020C00
    li   t1, 0x20008401
    sw   t1, 0(t0)

    # L1[769] @ 0x8002_0C04: VA 0xC040_0000 -> 非对齐 4 MB 巨页 (PPN[0]=1 != 0, 必报缺页)
    #   PPN = 0x80001 -> (0x80001 << 10) | 0xC7 = 0x2000_04C7
    li   t1, 0x200004C7
    sw   t1, 4(t0)

    # 填写 L0 页表 @ 0x8002_1000:
    li   t0, 0x80021000
    # L0[0]: VA 0xC000_0000 -> PA 0x8003_0000 (V|R|W|A|D = 0xC7) => 0x2000_C0C7
    li   t1, 0x2000C0C7
    sw   t1, 0(t0)
    # L0[1]: VA 0xC000_1000 -> PA 0x8003_1000 (V|R|W|A|D = 0xC7) => 0x2000_C4C7
    li   t1, 0x2000C4C7
    sw   t1, 4(t0)
    # L0[2]: VA 0xC000_2000 -> PA 0x8003_0000 (共享物理页! V|R|W|A|D = 0xC7) => 0x2000_C0C7
    li   t1, 0x2000C0C7
    sw   t1, 8(t0)
    # L0[3]: VA 0xC000_3000 -> PA 0x8003_2000 (U-mode R/W: V|R|W|U|A|D = 0xD7) => 0x2000_C8D7
    li   t1, 0x2000C8D7
    sw   t1, 12(t0)
    # L0[4]: VA 0xC000_4000 -> PA 0x8003_3000 (X-only: V|X|A|D = 0xC9) => 0x2000_CCC9
    li   t1, 0x2000CCC9
    sw   t1, 16(t0)
    # L0[5]: VA 0xC000_5000 -> PA 0x8003_4000 (D=0 干净页: V|R|W|A = 0x47) => 0x2000_D047
    li   t1, 0x2000D047
    sw   t1, 20(t0)
    # L0[6]: VA 0xC000_6000 -> PA 0x8003_5000 (A=0 未访问页: V|R|W = 0x07) => 0x2000_D407
    li   t1, 0x2000D407
    sw   t1, 24(t0)
    # L0[7]: VA 0xC000_7000 -> PA 0x8003_6000 (U-mode 代码页: V|R|W|X|U|A|D = 0xDF) => 0x2000_D8DF
    li   t1, 0x2000D8DF
    sw   t1, 28(t0)
    # L0[8]: VA 0xC000_8000 -> V=0 无效页 (已清零)
    # L0[9]: VA 0xC000_9000 -> PA 0x8003_7000 (只读页: V|R|A|D = 0xC3) => 0x2000_DCC3
    li   t1, 0x2000DCC3
    sw   t1, 36(t0)

    # 初始化陷阱向量与委托 (委托 ECALL_U=8, InsnPF=12, LoadPF=13, StorePF=15 给 S-mode)
    li   t0, m_trap_handler
    csrw mtvec, t0
    li   t0, s_trap_handler
    csrw stvec, t0
    li   t0, 0x0000B100          # (1<<8)|(1<<12)|(1<<13)|(1<<15)
    csrw medeleg, t0
    csrw mideleg, zero

    sw   zero, 0(s10)
    sw   zero, 4(s10)
    sw   zero, 8(s10)
    sw   zero, 12(s10)
    sw   zero, 16(s10)

    # 切入 S-mode (MPP=01)
    li   t0, 0x00000800
    csrw mstatus, t0
    li   t0, s_enable_mmu
    csrw mepc, t0
    mret

s_enable_mmu:
    # 开启 Sv32: satp = (1<<31) | 0x00080020 = 0x8008_0020
    li   t0, 0x80080020
    csrw satp, t0
    sfence.vma

    # ------------------------------------------------------------------------
    # [Test 2] 4 KB 映射 + 共享物理页 L0D 零别名 + 4 MB UART MMIO 巨页
    # ------------------------------------------------------------------------
    li   t0, 0xC0000000          # L0[0] -> PA 0x8003_0000
    li   t1, 0xC0002000          # L0[2] -> PA 0x8003_0000 (共享物理页!)
    li   t2, 0xCAFE1234
    sw   t2, 0(t0)
    lw   t3, 0(t1)               # 不同虚址读回同一物理字
    bne  t3, t2, fail_1

    # 共享页反向写 + 连续读 (压测 0 拍物理标签 L0D 一致性)
    li   t2, 0xDEADBEEF
    sw   t2, 0(t1)
    lw   t3, 0(t0)               # 应立即看到 0xDEADBEEF
    bne  t3, t2, fail_2
    lw   t4, 0(t0)               # L0D 0 拍命中 + Load-Use 紧跟
    bne  t4, t2, fail_3

    # 通过翻译后的 4 MB UART MMIO 巨页打印 "VM\n"
    li   t0, 0x10000000
    li   t1, 86                  # 'V'
    sb   t1, 0(t0)
    li   t1, 77                  # 'M'
    sb   t1, 0(t0)
    li   t1, 10                  # '\n'
    sb   t1, 0(t0)

    # ------------------------------------------------------------------------
    # [Test 3] 跨 4 KB 页边界非对齐 Store/Load (0xC000_0FFE .. 0xC000_1001)
    # ------------------------------------------------------------------------
    li   t0, 0xC0000FFE
    li   t1, 0x11223344
    sw   t1, 0(t0)               # 低 16 位落页 0 (0x8003_0FFE), 高 16 位落页 1 (0x8003_1000)
    lw   t2, 0(t0)
    bne  t2, t1, fail_4
    lhu  t3, 0(t0)
    li   t4, 0x00003344
    bne  t3, t4, fail_5
    li   t0, 0xC0001000
    lhu  t3, 0(t0)
    li   t4, 0x00001122
    bne  t3, t4, fail_6

    # ------------------------------------------------------------------------
    # [Test 4] SUM / MXR / 只读页 Store & AMO 权限校验
    # ------------------------------------------------------------------------
    # 4a. SUM=0 访问 U 页 (0xC000_3000) -> 必报 Load Page Fault (13)
    sw   zero, 8(s10)
    sw   zero, 12(s10)           # mode 0 = skip+4
    li   t0, 0xC0003000
    lw   t1, 0(t0)               # 应陷入
    lw   t2, 8(s10)
    li   t3, 1
    bne  t2, t3, fail_10
    lw   t2, 0(s10)
    li   t3, 13
    bne  t2, t3, fail_11
    lw   t2, 4(s10)
    bne  t2, t0, fail_12

    # 4b. SUM=1 访问 U 页 -> 读写成功!
    li   t1, 0x00040000          # sstatus.SUM (bit 18)
    csrs sstatus, t1
    li   t2, 0x55AA66BB
    sw   t2, 0(t0)
    lw   t3, 0(t0)
    bne  t3, t2, fail_13
    csrc sstatus, t1             # 清除 SUM

    # 4c. MXR=0 读 X-only 页 (0xC000_4000) -> 必报 Load Page Fault (13)
    sw   zero, 8(s10)
    li   t0, 0xC0004000
    lw   t1, 0(t0)               # 应陷入
    lw   t2, 8(s10)
    li   t3, 1
    bne  t2, t3, fail_14
    lw   t2, 0(s10)
    li   t3, 13
    bne  t2, t3, fail_15

    # 4d. MXR=1 读 X-only 页 -> 读回 0x13572468!
    li   t1, 0x00080000          # sstatus.MXR (bit 19)
    csrs sstatus, t1
    lw   t2, 0(t0)
    li   t3, 0x13572468
    bne  t2, t3, fail_16
    csrc sstatus, t1             # 清除 MXR

    # 4e. 只读页 (0xC000_9000): Store 与 AMOADD.W 均必报 Store/AMO Page Fault (15)
    sw   zero, 8(s10)
    li   t0, 0xC0009000
    lw   t1, 0(t0)               # 读必须成功 (且填入 DTLB)
    li   t2, 0x00000100
    bne  t1, t2, fail_17
    sw   t2, 0(t0)               # 写 -> 必报 Cause 15
    lw   t3, 0(s10)
    li   t4, 15
    bne  t3, t4, fail_18
    amoadd.w t1, t2, (t0)        # AMO -> 读相即报 Cause 15!
    lw   t3, 8(s10)
    li   t4, 2
    bne  t3, t4, fail_19
    lw   t3, 0(s10)
    li   t4, 15
    bne  t3, t4, fail_20

    # ------------------------------------------------------------------------
    # [Test 5] 软件 A/D 缺页按需修复 (脏 D-Cache 修改 PTE + sfence.vma + 重试)
    # ------------------------------------------------------------------------
    # 5a. L0[5] (0xC000_5000, A=1, D=0): 先 Load 成功 (入 DTLB, D=0), 再 Store 触发 Cause 15
    sw   zero, 8(s10)
    li   t1, 1
    sw   t1, 12(s10)             # mode 1 = 修复 L0[5].D 并重试
    li   t0, 0xC0005000
    lw   t2, 0(t0)               # Load 应成功且读 0xAAAA5555
    li   t3, 0xAAAA5555
    bne  t2, t3, fail_21
    li   t4, 0x99887766
    sw   t4, 0(t0)               # 首次 Store 触发 Cause 15 -> 补 D=1 + sfence.vma -> 重试成功!
    lw   t2, 8(s10)
    li   t3, 1
    bne  t2, t3, fail_22
    lw   t2, 0(t0)
    bne  t2, t4, fail_23

    # 5b. L0[6] (0xC000_6000, A=0): Load 触发 Cause 13 -> 补 A=1 + sfence.vma -> 重试成功!
    sw   zero, 8(s10)
    li   t1, 2
    sw   t1, 12(s10)             # mode 2 = 修复 L0[6].A 并重试
    li   t0, 0xC0006000
    lw   t2, 0(t0)
    li   t3, 0x76543210
    bne  t2, t3, fail_24
    lw   t2, 8(s10)
    li   t3, 1
    bne  t2, t3, fail_25

    # ------------------------------------------------------------------------
    # [Test 6] 动态重映射 + sfence.vma + 非对齐巨页 + 无效页
    # ------------------------------------------------------------------------
    # 将 L0[0] (0xC000_0000) 从 PA 0x8003_0000 重映射到 PA 0x8003_5000 (其字 0 = 0x76543210)
    li   t0, 0x80021000
    li   t1, 0x2000D4C7          # PA 0x8003_5000, V|R|W|A|D
    sw   t1, 0(t0)
    sfence.vma
    li   t0, 0xC0000000
    lw   t2, 0(t0)
    li   t3, 0x76543210
    bne  t2, t3, fail_26

    # 非对齐 4 MB 巨页 (0xC040_0000, PPN[0]=1) -> Load Page Fault (13)
    sw   zero, 8(s10)
    sw   zero, 12(s10)           # mode 0 = skip+4
    li   t0, 0xC0400000
    lw   t2, 0(t0)
    lw   t3, 8(s10)
    li   t4, 1
    bne  t3, t4, fail_27
    lw   t3, 0(s10)
    li   t4, 13
    bne  t3, t4, fail_28

    # 无效页 V=0 (0xC000_8000) -> Load Page Fault (13)
    sw   zero, 8(s10)
    li   t0, 0xC0008000
    lw   t2, 0(t0)
    lw   t3, 8(s10)
    li   t4, 1
    bne  t3, t4, fail_29
    lw   t3, 0(s10)
    li   t4, 13
    bne  t3, t4, fail_30

    # ------------------------------------------------------------------------
    # [Test 7] S-mode 取指 U 页必报 Cause 12 (即使 SUM=1) + U-mode 虚拟执行
    # ------------------------------------------------------------------------
    sw   zero, 8(s10)
    li   t1, 3
    sw   t1, 12(s10)             # mode 3 = 指令缺页时令 sepc=ra 返回
    li   t1, 0x00040000          # 打开 SUM=1 (验证 SUM 对取指无效!)
    csrs sstatus, t1
    li   t0, 0xC0007000
    jalr ra, 0(t0)               # S-mode 取指 U 页 -> 必报 Cause 12, stval=0xC000_7000!
    csrc sstatus, t1
    lw   t2, 8(s10)
    li   t3, 1
    bne  t2, t3, fail_31
    lw   t2, 0(s10)
    li   t3, 12
    bne  t2, t3, fail_32
    lw   t2, 4(s10)
    li   t3, 0xC0007000
    bne  t2, t3, fail_33

    # 切入 U-mode 在 VA 0xC000_7000 执行 (将 VA 0xC000_3000 从 0x55AA66BB 增至 0x55AA66BC)
    li   t0, 0x00000100
    csrc sstatus, t0             # SPP = 0 (U-mode)
    li   t0, 0xC0007000
    csrw sepc, t0
    li   a2, 0xC0003000
    li   a1, 0
    sret

s_after_u_exec:
    li   t0, 0x55AA66BC
    bne  a1, t0, fail_34
    lw   t1, 16(s10)
    li   t2, 1
    bne  t1, t2, fail_35

    # ------------------------------------------------------------------------
    # [Test 8] M-mode MPRV=1 + MPP=S (物理取指 + Sv32 虚拟数据访问)
    # ------------------------------------------------------------------------
    li   a7, 1
    li   a0, 0
    ecall                        # ECALL_S -> M-mode 执行 MPRV 读测试并写 tohost=1!
    j    fail_36                 # 正常应由 M-mode 结束

# ============================================================================
# 失败码上报
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
fail_6:  li a0, 106
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
fail_17: li a0, 117
         j  do_fail
fail_18: li a0, 118
         j  do_fail
fail_19: li a0, 119
         j  do_fail
fail_20: li a0, 120
         j  do_fail
fail_21: li a0, 121
         j  do_fail
fail_22: li a0, 122
         j  do_fail
fail_23: li a0, 123
         j  do_fail
fail_24: li a0, 124
         j  do_fail
fail_25: li a0, 125
         j  do_fail
fail_26: li a0, 126
         j  do_fail
fail_27: li a0, 127
         j  do_fail
fail_28: li a0, 128
         j  do_fail
fail_29: li a0, 129
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
fail_35: li a0, 135
         j  do_fail
fail_36: li a0, 136
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
# S-mode 陷阱处理程序 (处理 Page Fault 12/13/15 与 U-mode ECALL_U 8)
# ============================================================================
.align 4
s_trap_handler:
    csrr t5, scause
    li   t6, 8                   # CAUSE_ECALL_U
    beq  t5, t6, s_u_done

    # 必须为 12 / 13 / 15 之一
    li   t6, 12
    beq  t5, t6, s_pf_common
    li   t6, 13
    beq  t5, t6, s_pf_common
    li   t6, 15
    beq  t5, t6, s_pf_common
    j    fail_s

s_pf_common:
    sw   t5, 0(s10)              # last_scause
    csrr t6, stval
    sw   t6, 4(s10)              # last_stval
    lw   t6, 8(s10)
    addi t6, t6, 1
    sw   t6, 8(s10)              # pf_cnt++

    lw   t6, 12(s10)             # pf_mode
    beqz t6, s_pf_skip
    li   t5, 1
    beq  t6, t5, s_pf_fix_d
    li   t5, 2
    beq  t6, t5, s_pf_fix_a
    li   t5, 3
    beq  t6, t5, s_pf_ret_ra
    j    fail_s

s_pf_skip:
    csrr t5, sepc
    addi t5, t5, 4
    csrw sepc, t5
    sret

s_pf_fix_d:
    # 置位 L0[5] (0x8002_1014) 的 D 位 (bit 7 = 0x80), 仅写 D-Cache + sfence.vma 后重试!
    li   t5, 0x80021014
    lw   t6, 0(t5)
    ori  t6, t6, 0x80
    sw   t6, 0(t5)
    sfence.vma
    sret                         # 原 sepc 重试 Store

s_pf_fix_a:
    # 置位 L0[6] (0x8002_1018) 的 A 位 (bit 6 = 0x40), 仅写 D-Cache + sfence.vma 后重试!
    li   t5, 0x80021018
    lw   t6, 0(t5)
    ori  t6, t6, 0x40
    sw   t6, 0(t5)
    sfence.vma
    sret                         # 原 sepc 重试 Load

s_pf_ret_ra:
    csrw sepc, ra                # 回到 jalr 的下一条指令
    sret

s_u_done:
    li   t5, 1
    sw   t5, 16(s10)
    li   t5, 0x100               # SPP = 1 (返回 S-mode)
    csrs sstatus, t5
    li   t5, s_after_u_exec
    csrw sepc, t5
    sret

# ============================================================================
# M-mode 陷阱处理程序 (Test 8: 验证 MPRV=1 + MPP=S + SUM=1)
# ============================================================================
.align 4
m_trap_handler:
    csrr t0, mcause
    li   t1, 9                   # CAUSE_ECALL_S
    bne  t0, t1, fail_m

    # 在 M-mode 下设置 MPRV=1(17) | SUM=1(18) | MPP=01(S, bit11)
    # 此时 M-mode 取指仍为物理地址，但 lw 通过 Sv32 (S-mode + SUM=1) 翻译 VA 0xC000_3000!
    li   t0, 0x00060800
    csrw mstatus, t0
    li   t1, 0xC0003000
    lw   t2, 0(t1)
    # 立即关闭 MPRV 恢复物理访存
    csrw mstatus, zero

    li   t3, 0x55AA66BC
    bne  t2, t3, fail_m

    # 全部 8 大项 Sv32 压力测试通过! 写 tohost=1 并清洗 D-Cache
    li   t0, 1
    sw   t0, 0(s11)
    fence.i
m_pass_spin:
    j    m_pass_spin
