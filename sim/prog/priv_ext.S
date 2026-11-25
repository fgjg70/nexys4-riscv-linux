# =============================================================================
# priv_ext.S — Stage 1A M-mode 特权扩展回归自校验 (tb_core)
# -----------------------------------------------------------------------------
# 覆盖:
#   1) Zicntr: mcycle/cycle, time, minstret/instret 递增 + mcountinhibit 暂停 + 写回
#   2) 严格非法 CSR: 读未实现 CSR (0x3FF) / 写只读 CSR (mhartid, cycle) 必须触发 mcause=2
#      且 csrr 读只读 CSR (rs1=x0) 必须合法不陷入
#   3) FENCE.I: 冲刷 BTB + 取指流水线并准确从 PC+4 继续
#   4) 指令地址非对齐异常 (IALIGN=32): JALR 跳至 2 字节对齐地址 -> mcause=0, mtval=目标, rd 不改写
#   5) mstatus.MPP WARL 保持 2'b11, mimpid/misa 读值正确
# =============================================================================

    .text
    li   s1, handler
    csrw mtvec, s1
    li   s2, 0                  # 陷阱计数
    li   s3, 0                  # 陷阱内自检失败码

    # -------- 1. MISA / MIMPID / MSTATUS.MPP --------
    csrr t0, misa
    li   t1, 0x40001101         # RV32IMA
    bne  t0, t1, fail1

    csrr t0, mimpid
    li   t1, 0x00010000
    bne  t0, t1, fail1

    csrr t0, mstatus
    li   t1, 0x1800             # MPP = 2'b11
    and  t0, t0, t1
    bne  t0, t1, fail1

    # -------- 2. Zicntr: mcycle / minstret / time 递增 & mcountinhibit --------
    csrr t0, mcycle
    nop
    nop
    nop
    csrr t1, mcycle
    bltu t1, t0, fail2
    beq  t1, t0, fail2

    csrr t0, minstret
    nop
    nop
    csrr t1, minstret
    bltu t1, t0, fail2
    beq  t1, t0, fail2

    csrr t0, time
    nop
    nop
    csrr t1, time
    beq  t1, t0, fail2

    # 暂停 mcycle & minstret (bit0=CY, bit2=IR -> 0x5)
    li   t0, 5
    csrw mcountinhibit, t0
    li   t1, 0x1234
    csrw mcycle, t1
    csrw minstret, t1
    nop
    nop
    nop
    csrr t2, mcycle
    bne  t2, t1, fail2          # 暂停期间 mcycle 不得递增
    csrr t2, minstret
    bne  t2, t1, fail2          # 暂停期间 minstret 不得递增
    csrw mcountinhibit, zero    # 恢复计数
    nop
    nop
    csrr t2, cycle              # 用户只读镜像 cycle 必须 > 0x1234
    bltu t2, t1, fail2
    beq  t2, t1, fail2

    # -------- 3. 严格非法 CSR 检测 --------
    # 3a: 读只读 CSR (mhartid, rs1=x0) 合法
    csrr t0, mhartid
    bne  t0, zero, fail3

    # 3b: 读未实现 CSR (0x3FF) -> mcause=2
    li   s0, 2
    csrr t0, 0x3FF
    li   t1, 1
    bne  s2, t1, fail3

    # 3c: csrw 写只读 CSR (mhartid = 0xF14) -> mcause=2
    li   s0, 2
    csrw mhartid, zero
    li   t1, 2
    bne  s2, t1, fail3

    # 3d: csrrs 写只读 CSR (cycle = 0xC00, rs1=t3 即使值为 0 仍构成写意图!) -> mcause=2
    li   t3, 0
    li   s0, 2
    csrrs t0, cycle, t3
    li   t1, 3
    bne  s2, t1, fail3

    # -------- 4. FENCE.I 冲刷流水线与 BTB --------
    li   t4, 0
    li   t5, 5
fi_loop:
    addi t4, t4, 1
    blt  t4, t5, fi_loop        # 训练 BTB
    fence.i                     # 应清空 BTB 并精确从下一条继续
    addi t4, t4, 10
    li   t5, 15
    bne  t4, t5, fail4

    # -------- 5. 指令地址非对齐异常 (JALR 跳向 +2) --------
    li   s0, 0                  # 期望 mcause = 0 (CAUSE_INSN_MISALIGN)
    li   t2, 0x55AA55AA         # 目标 rd 初值: 异常时不得被改写
    auipc t0, 0
    addi  t0, t0, 2             # 非 4 字节对齐目标
    mv    s4, t0                # 期望 mtval = t0
    jalr  t2, t0, 0             # 必须触发 CAUSE_INSN_MISALIGN
    li   t1, 4
    bne  s2, t1, fail5
    li   t1, 0x55AA55AA
    bne  t2, t1, fail5          # 触发异常的 JALR 不得写 rd
    csrr t1, mtval
    bne  t1, s4, fail5          # mtval 必须等于非对齐目标地址

    # -------- 6. 陷阱内自检必须全过 --------
    bne  s3, zero, fail6

    # -------- 全部通过 --------
    li   a0, 0x90002000
    li   a1, 1
    sw   a1, 0(a0)
    j    done

handler:
    csrr t6, mcause
    bne  t6, s0, h_fail
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    addi s2, s2, 1
    mret

h_fail:
    li   s3, 1
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

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
fail4:
    li   a0, 0x90002000
    li   a1, 5
    sw   a1, 0(a0)
    j    done
fail5:
    li   a0, 0x90002000
    li   a1, 6
    sw   a1, 0(a0)
    j    done
fail6:
    li   a0, 0x90002000
    li   a1, 7
    sw   a1, 0(a0)
    j    done

done:
    j    done
