`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// rv32_cpu.v — 总线解耦单发射 RV32IMA + Zicsr + Zicntr + Zifencei 处理器核
// 纯 Verilog-2001，零厂商原语，面向 Nexys 4 DDR (XC7A100T-1) 路线 A -> 路线 B
// ----------------------------------------------------------------------------
// 接口契约 (高主频 1 拍命中 + 任意多拍缺失/外设等待):
//   - ibus (指令侧): N 拍送 ibus_addr (= pc_next) 与 ibus_kill (= pc_flush)；
//     N+1 拍返回 ibus_rdata + ibus_valid + ibus_fault (命中 1 拍零停顿，缺失拉低 ibus_valid)。
//   - dbus (数据侧): N 拍在 MEM 段送 dbus_re/dbus_we/dbus_addr/dbus_wdata/dbus_wstrb；
//     N+1 拍在 WB 段返回 dbus_rdata + dbus_stall + dbus_fault (命中 1 拍零停顿，缺失拉高 dbus_stall)。
//   - fencei_req / fencei_done: FENCE.I 握手，等待 D-Cache 回写与 I-Cache 失效完成后
//     同步清零 BTB/RAS 并冲刷取指流重定向到 PC+4。
// ============================================================================

module rv32_cpu #(
  parameter        ENABLE_SU    = 1,
  parameter [31:0] RESET_PC     = `PC_RESET,
  parameter [31:0] MTVEC_RESET  = 32'h8000_0100,
  parameter        BTB_IDX_BITS = 7,
  parameter        BTB_PC_TOP   = 32
)(
  input  wire        clk,
  input  wire        rst,

  // 指令总线 (接 I-Cache 或片上 imem)
  output wire        ibus_req,
  output wire [31:0] ibus_addr,
  output wire        ibus_kill,
  input  wire [31:0] ibus_rdata,
  input  wire        ibus_valid,
  input  wire        ibus_fault,
  input  wire        ibus_page_fault,

  // 数据总线 (接 D-Cache 或片上 dmem/MMIO)
  output wire        dbus_re,
  output wire        dbus_we,
  output wire        dbus_is_amo,
  output wire [31:0] dbus_addr,
  output wire [31:0] dbus_wdata,
  output wire [3:0]  dbus_wstrb,
  input  wire [31:0] dbus_rdata,
  input  wire        dbus_stall,
  input  wire        dbus_fault,
  input  wire        dbus_page_fault,
  // L0D 0 拍异步快读口 (dbus_l0_addr 直连 ex_mem_alu_out FF，跳过 LSU mux; 无 L0D 时 fast_hit 恒接 0)
  output wire        dbus_l0_en,
  output wire [31:0] dbus_l0_addr,
  input  wire        dbus_fast_hit,
  input  wire [31:0] dbus_fast_rdata,

  // FENCE.I 缓存同步握手 (无 Cache 时 fencei_done 直接恒接 1'b1)
  output wire        fencei_req,
  input  wire        fencei_done,

  // SFENCE.VMA TLB 刷新握手与 Sv32 MMU 控制输出 (无 MMU 时 sfence_done 恒接 1'b1)
  output wire        sfence_req,
  output wire [31:0] sfence_vaddr,
  output wire        satp_flush,
  input  wire        sfence_done,
  output wire [1:0]  mmu_priv,
  output wire [31:0] mmu_satp,
  output wire        mmu_i_xlate_en,
  output wire        mmu_sum,
  output wire        mmu_mxr,
  output wire        mmu_mprv,
  output wire [1:0]  mmu_mpp,

  // 实时计数器 (CLINT mtime -> CSR time/timeh) 与 M/S-mode 外部/软/定时中断
  input  wire [63:0] mtime_i,
  input  wire        irq_sw,
  input  wire        irq_timer,
  input  wire        irq_ext,
  input  wire        irq_sext,

  // 调试观测接口
  output wire [31:0] dbg_pc,
  output wire [31:0] dbg_id_pc,
  output wire [31:0] dbg_instr,
  output reg         dbg_illegal,
  input  wire [4:0]  dbg_raddr,
  output wire [31:0] dbg_rdata,
  output wire        dbg_mem_we,
  output wire [31:0] dbg_mem_addr,
  output wire [31:0] dbg_mem_wdata,
  output wire        dbg_stall,
  output wire        dbg_redirect
);

  localparam XLEN = `RV32_XLEN;

  // ==========================================================================
  // 互连信号声明
  // ==========================================================================
  // IF
  wire [31:0] pc, pc_plus4, pc_target;
  (* max_fanout = 16 *) wire pc_src;
  (* max_fanout = 16 *) wire redirect, redirect_raw;
  wire        lsu_stall;
  wire        lsu_mem_resp, lsu_in_tail;
  wire        amo_write_phase;
  wire [31:0] amo_old, amo_wb_val;
  wire        amo_is_lr, amo_is_sc, amo_sc_ok;
  wire        id_ex_bubble;

  // 分支预测
  wire        pred_hit, pred_taken, btb_upd_en, is_ctrl_flow;
  wire [31:0] pred_target, actual_target;
  wire        pred_is_ret;
  wire [1:0]  pred_ctr;
  wire        ex_is_call, ex_is_ret, ex_is_cond;
  (* max_fanout = 16 *) wire actual_taken;
  wire        pred_ok;
  wire [31:0] btb_pred_target;
  wire        btb_flush_all;

  // IF/ID
  wire [31:0] if_pc, if_pc_plus4, if_instr;
  wire        if_pred_taken;
  wire [31:0] if_pred_target;
  wire [1:0]  if_pred_ctr;
  wire        if_fault, if_pf;

  // ID
  wire [`CTRL_W-1:0] id_ctrl_raw;
  reg  [`CTRL_W-1:0] id_ctrl;
  wire               id_en;
  wire [31:0]        id_imm, id_rs1_data, id_rs2_data;
  wire [4:0]         id_rs1, id_rs2, id_rd;
  wire [4:0]         id_rs1_haz, id_rs2_haz;

  // ID/EX
  wire [`CTRL_W-1:0] id_ex_ctrl;
  wire               id_ex_valid;
  wire               id_ex_if_fault, id_ex_if_pf;
  wire [31:0]        id_ex_instr;
  wire [31:0]        id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  wire [4:0]         id_ex_rs1, id_ex_rs2, id_ex_rd;
  wire               id_ex_pred_taken;
  wire [31:0]        id_ex_pred_target;
  wire [1:0]         id_ex_pred_ctr;
  reg  [31:0]        id_ex_jr_p;

  // EX
  wire [1:0]         fwd_a_pre, fwd_b_pre;
  (* max_fanout = 16 *) reg [1:0] id_ex_fwd_a, id_ex_fwd_b;
  reg  [31:0]        ex_rs1, ex_rs2, ex_a, ex_b, ex_amo_addr;
  wire [31:0]        ex_alu_out, ex_pc_target;
  wire [31:0]        ex_result, md_result;
  wire               md_busy;
  reg                is_muldiv;
  reg  [31:0]        md_a_r, md_b_r;
  reg  [4:0]         md_op_r;
  reg                md_served;
  reg                md_held;
  reg  [31:0]        md_res_hold;
  wire               md_busy_raw;
  wire               ex_taken;

  // Zicsr / WFI / FENCE.I / SFENCE.VMA / M-S-U 特权陷阱
  wire [31:0] csr_rdata, csr_wdata, csr_src;
  wire        csr_we, is_csr, csr_wr_req, csr_illegal;
  wire        is_wfi, wfi_wake, wfi_stall;
  wire        is_fencei, fencei_stall, fencei_taken;
  wire        is_sfence, sfence_stall, sfence_taken, satp_we_taken;
  wire        exc_req, irq_take, trap_req, trap_enter, trap_redir;
  wire        mret_req_int, sret_req_int;
  (* max_fanout = 16 *) wire any_redir;
  wire [4:0]  trap_cause, irq_cause;
  wire [3:0]  exc_cause;
  wire [31:0] trap_vector, mret_pc, sret_pc, trap_tval;
  wire        irq_pending, mret_taken, sret_taken, is_mret, is_sret;
  wire        insn_misalign_fast, br_misalign_cond, insn_misalign;
  wire [1:0]  priv_o, mstatus_mpp;
  wire [31:0] satp_o;
  wire        i_xlate_en_o;
  wire        mstatus_sum, mstatus_mxr, mstatus_mprv;
  wire        mstatus_tvm, mstatus_tw, mstatus_tsr;

  assign mmu_priv       = priv_o;
  assign mmu_satp       = satp_o;
  assign mmu_i_xlate_en = i_xlate_en_o;
  assign mmu_sum        = mstatus_sum;
  assign mmu_mxr  = mstatus_mxr;
  assign mmu_mprv = mstatus_mprv;
  assign mmu_mpp  = mstatus_mpp;

  // EX/MEM
  wire               ex_mem_valid;
  wire [31:0]        ex_mem_pc;
  wire [`CTRL_W-1:0] ex_mem_ctrl;
  wire [31:0]        ex_mem_alu_out, ex_mem_store_data, ex_mem_pc_plus4;
  wire [4:0]         ex_mem_rd;

  // MEM
  wire [31:0] mem_load_data;
  wire        mem_fast_load;
  wire [31:0] mem_fast_load_data;

  // MEM/WB
  wire               mem_wb_valid;
  wire [31:0]        mem_wb_pc;
  wire [`CTRL_W-1:0] mem_wb_ctrl;
  wire [31:0]        mem_wb_alu_out, mem_wb_load_data, mem_wb_pc_plus4;
  wire               mem_wb_fast_load;
  wire [4:0]         mem_wb_rd;
  (* max_fanout = 16 *) wire [1:0] mem_wb_wb_src = mem_wb_ctrl[`CTRL_WB_SRC];
  wire               wb_is_mem;
  wire               wb_fault;
  wire [3:0]         wb_fault_cause;
  wire               mem_fault;
  wire [3:0]         mem_fault_cause;
  wire [31:0]        mem_fault_tval;
  wire               any_bus_fault = wb_fault || mem_fault;

  // WB
  reg  [31:0] wb_data;
  wire [4:0]  wb_rd;
  wire        wb_reg_write;
  wire        instret_inc;

  // 流水线控制
  (* max_fanout = 32 *) wire pipe_stall;
  wire        stall_no_l0, load_use_mem_hit;
  wire        if_id_flush, hold_mem;
  wire        br_redir, br_redir_eff;
  reg         br_redir_r;
  wire        redir_flush, pc_flush;
  wire        redir_kill, id_ex_flush;
  reg  [31:0] br_tgt_r;
  wire [31:0] pc_flush_pc;
`ifndef SYNTHESIS
  reg         br_redir_r2;
`endif

  // ==========================================================================
  // IF 段 (支持 1 拍命中 + 多拍 I-Cache 缺失 + 无竞态重定向取消)
  // ==========================================================================
  wire boot_done;
`ifdef IMEM_COMB_READ
  assign boot_done = 1'b1;
`else
  reg boot_done_r;
  always @(posedge clk or posedge rst) begin
    if (rst) boot_done_r <= 1'b0;
    else     boot_done_r <= 1'b1;
  end
  assign boot_done = boot_done_r;
`endif

  // Round 3 时序优化: pc_hold_sel 合并 fetch_hold && !pc_flush 供 u_pc.stall 与 pc_next 共用
  // (u_pc 内部 flush 优先级高于 stall，功能完全等价，将 LUT5+LUT3 压缩为单级 LUT6)
  (* max_fanout = 16 *) wire pc_hold_sel =
      (stall_no_l0 || !boot_done || !ibus_valid || (load_use_mem_hit && !mem_fast_load)) && !pc_flush;

  pc #(.XLEN(XLEN), .RESET_PC(RESET_PC)) u_pc (
    .clk       (clk),
    .rst       (rst),
    .stall     (pc_hold_sel),
    .flush     (pc_flush),
    .flush_pc  (pc_flush_pc),
    .pc_src    (pc_src),
    .pc_target (pc_target),
    .pc        (pc),
    .pc_plus4  (pc_plus4)
  );

  wire [31:0] pc_seq_pred = pc_src ? pc_target : pc_plus4;
  wire [31:0] pc_adv      = pc_flush ? pc_flush_pc : pc_seq_pred;
  wire [31:0] pc_next     = pc_hold_sel ? pc : pc_adv;

  assign ibus_req  = !rst;
`ifdef IMEM_COMB_READ
  assign ibus_addr = pc;
`else
  assign ibus_addr = pc_next;
`endif
  assign ibus_kill = pc_flush;

  assign if_id_flush = any_redir;

  // ==========================================================================
  // 分支预测 (Round 4: 128 项分布式 RAM Taken-Only BTB + 8K RAMB18E1 Bimodal + 默认 16 项 RAS)
  // ==========================================================================
  assign btb_flush_all = fencei_taken || sfence_taken || satp_we_taken;

  wire        bht_pred_en      = rst || !pc_hold_sel;
  wire [31:0] bht_pred_pc_next = rst ? RESET_PC : pc_next;

  btb #(
    .IDX_BITS (BTB_IDX_BITS),
    .PC_TOP   (BTB_PC_TOP),
    .PC_BASE  (RESET_PC),
    .PHT_BITS (13)
  ) u_btb (
    .clk          (clk),
    .rst          (rst),
    .flush_all    (btb_flush_all),
    .pred_pc      (pc),
    .pred_en      (bht_pred_en),
    .pred_pc_next (bht_pred_pc_next),
    .pred_hit     (pred_hit),
    .pred_taken   (pred_taken),
    .pred_target  (btb_pred_target),
    .pred_is_ret  (pred_is_ret),
    .pred_ctr     (pred_ctr),
    .upd_en       (btb_upd_en),
    .upd_pc       (id_ex_pc),
    .upd_taken    (actual_taken),
    .upd_target   (ex_pc_target),
    .upd_is_ret   (ex_is_ret),
    .upd_is_cond  (ex_is_cond),
    .upd_old_ctr  (id_ex_pred_ctr)
  );

  assign ex_is_cond = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR);

  // btb_upd_base 剥离条件分支专属的 br_misalign_cond，供 JAL/JALR 专属的 RAS push/pop 使用，
  // 彻底剪断 32-bit branch_unit -> ex_taken -> u_ras 关键路径 (与 btb_upd_en 逻辑 100% 等价)
  wire btb_upd_base = is_ctrl_flow && !hold_mem && !rst && !redir_kill && !any_bus_fault && !insn_misalign_fast;

`ifndef RAS_DIS
  wire [31:0] ras_top;
  wire        ras_empty;
  // RISC-V Spec Table 2.1: call/ret 严格语义 (含 rd!=rs1 协程切换同时 pop+push)
  wire ex_rd_link  = (id_ex_rd  == 5'd1) || (id_ex_rd  == 5'd5);
  wire ex_rs1_link = (id_ex_rs1 == 5'd1) || (id_ex_rs1 == 5'd5);
  wire ex_is_jal   = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_J);
  wire ex_is_jalr  = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR);

  wire ex_is_call_w = btb_upd_base && ((ex_is_jal || ex_is_jalr) && ex_rd_link);
  wire ex_is_ret_w  = btb_upd_base && ex_is_jalr && ex_rs1_link &&
                      (!ex_rd_link || (id_ex_rd != id_ex_rs1));
  assign ex_is_call  = ex_is_call_w;
  assign ex_is_ret   = ex_is_ret_w;

  ras #(.DEPTH(16)) u_ras (
    .clk       (clk),
    .rst       (rst),
    .flush_all (btb_flush_all),
    .push_en   (ex_is_call),
    .push_pc   (id_ex_pc_plus4),
    .pop_en    (ex_is_ret),
    .top       (ras_top),
    .empty     (ras_empty)
  );

  assign pred_target = (pred_is_ret && !ras_empty) ? ras_top : btb_pred_target;
`else
  assign ex_is_call  = 1'b0;
  assign ex_is_ret   = 1'b0;
  assign pred_target = btb_pred_target;
`endif

  assign is_ctrl_flow = (id_ex_ctrl[`CTRL_PC_SEL] != `PC_NEXT);
  assign btb_upd_en   = btb_upd_base && !br_misalign_cond;

  assign if_pc          = pc;
  assign if_pc_plus4    = pc_plus4;
  assign if_instr       = ibus_rdata;
  assign if_pred_taken  = pred_taken;
  assign if_pred_target = pred_target;
  assign if_pred_ctr    = pred_ctr;
  assign id_en          = boot_done && ibus_valid;
  assign if_fault       = id_en && ibus_fault;
  assign if_pf          = id_en && ibus_page_fault;

  // ==========================================================================
  // ID 段
  // ==========================================================================
  assign id_rs1 = if_instr[19:15];
  assign id_rs2 = if_instr[24:20];
  assign id_rd  = if_instr[11:7];

  // 原始源寄存器直连冒险比较器，由 id_valid 在末级门控 load_use，打破 q_hit -> 比较器串行链
  assign id_rs1_haz = id_rs1;
  assign id_rs2_haz = id_rs2;

  control_unit #(.XLEN(XLEN)) u_ctrl (
    .instr (if_instr),
    .ctrl  (id_ctrl_raw)
  );

  always @(*) begin
    id_ctrl = (id_en && !if_fault && !if_pf) ? id_ctrl_raw : `CTRL_NOP;
  end

  imm_gen #(.XLEN(XLEN)) u_imm (
    .instr   (if_instr),
    .fmt     (id_ctrl[`CTRL_IMM_FMT]),
    .imm_out (id_imm)
  );

  regfile #(.XLEN(XLEN), .NUM_REGS(32)) u_regfile (
    .clk       (clk),
    .we        (wb_reg_write),
    .waddr     (wb_rd),
    .wdata     (wb_data),
    .raddr1    (id_rs1),
    .raddr2    (id_rs2),
    .rdata1    (id_rs1_data),
    .rdata2    (id_rs2_data),
    .dbg_raddr (dbg_raddr),
    .dbg_rdata (dbg_rdata)
  );

  id_ex_reg u_id_ex (
    .clk            (clk),
    .rst            (rst),
    .flush          (id_ex_flush),
    .stall          (pipe_stall),
    .bubble         (id_ex_bubble),
    .valid_in       (id_en),
    .if_fault_in    (if_fault),
    .if_pf_in       (if_pf),
    .instr_in       (if_instr),
    .ctrl_in        (id_ctrl),
    .pc_in          (if_pc),
    .pc_plus4_in    (if_pc_plus4),
    .rs1_data_in    (id_rs1_data),
    .rs2_data_in    (id_rs2_data),
    .imm_in         (id_imm),
    .rs1_addr_in    (id_rs1),
    .rs2_addr_in    (id_rs2),
    .rd_addr_in     (id_rd),
    .pred_taken_in  (if_pred_taken),
    .pred_target_in (if_pred_target),
    .pred_ctr_in    (if_pred_ctr),
    .ctrl           (id_ex_ctrl),
    .valid          (id_ex_valid),
    .if_fault       (id_ex_if_fault),
    .if_pf          (id_ex_if_pf),
    .instr          (id_ex_instr),
    .pc             (id_ex_pc),
    .pc_plus4       (id_ex_pc_plus4),
    .rs1_data       (id_ex_rs1_data),
    .rs2_data       (id_ex_rs2_data),
    .imm            (id_ex_imm),
    .rs1_addr       (id_ex_rs1),
    .rs2_addr       (id_ex_rs2),
    .rd_addr        (id_ex_rd),
    .pred_taken     (id_ex_pred_taken),
    .pred_target    (id_ex_pred_target),
    .pred_ctr       (id_ex_pred_ctr)
  );

  // ==========================================================================
  // EX 段 (Round 2: WB_PC4 并入 ex_result; Round 3: L0D 命中由 mem_wb_load_data FF 直通前递!)
  // ==========================================================================
  wire [31:0] ex_mem_fwd_data = ex_mem_alu_out;
  wire [31:0] fwd_wb_data     = mem_wb_fast_load ? mem_wb_load_data : mem_wb_alu_out;

  always @(*) begin
    ex_rs1 = (id_ex_fwd_a == `FWD_EX_MEM) ? ex_mem_fwd_data :
             (id_ex_fwd_a == `FWD_MEM_WB) ? fwd_wb_data : id_ex_rs1_data;
    ex_rs2 = (id_ex_fwd_b == `FWD_EX_MEM) ? ex_mem_fwd_data :
             (id_ex_fwd_b == `FWD_MEM_WB) ? fwd_wb_data : id_ex_rs2_data;
    ex_a   = (id_ex_ctrl[`CTRL_ALU_A_SRC] == `ALU_A_PC)   ? id_ex_pc :
             (id_ex_ctrl[`CTRL_ALU_A_SRC] == `ALU_A_ZERO) ? 32'd0 : ex_rs1;
    ex_b   = (id_ex_ctrl[`CTRL_ALU_B_SRC] == `ALU_B_IMM)  ? id_ex_imm : ex_rs2;
    ex_amo_addr = ex_rs1;
  end

  alu #(.XLEN(XLEN)) u_alu (
    .a   (ex_a),
    .b   (ex_b),
    .op  (id_ex_ctrl[`CTRL_ALU_OP]),
    .out (ex_alu_out)
  );

  // ---- RV32M 乘除法单元 (C-12c: 操作数寄存一拍 + 一次性发射) ----
  always @(*) begin
    case (id_ex_ctrl[`CTRL_ALU_OP])
      `ALU_MUL, `ALU_MULH, `ALU_MULHSU, `ALU_MULHU,
      `ALU_DIV, `ALU_DIVU, `ALU_REM,    `ALU_REMU: is_muldiv = 1'b1;
      default:                                     is_muldiv = 1'b0;
    endcase
  end

  wire       is_muldiv_eff = is_muldiv && !redir_kill && !any_bus_fault;
  wire       md_start      = is_muldiv_eff && !md_served;
  wire       md_done       = md_served && !md_held && !md_busy_raw;
  wire [4:0] md_op_eff     = (md_served && !md_held) ? md_op_r : `ALU_ADD;
  assign     md_busy       = md_start || (md_served && !md_done && !md_held);
  wire [31:0] md_result_eff = md_held ? md_res_hold : md_result;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      md_a_r      <= 32'd0;
      md_b_r      <= 32'd0;
      md_op_r     <= `ALU_ADD;
      md_served   <= 1'b0;
      md_held     <= 1'b0;
      md_res_hold <= 32'd0;
    end
    else if (any_bus_fault) begin
      md_served <= 1'b0;
      md_held   <= 1'b0;
    end
    else begin
      if (md_start) begin
        md_a_r    <= ex_rs1;
        md_b_r    <= ex_rs2;
        md_op_r   <= id_ex_ctrl[`CTRL_ALU_OP];
        md_served <= 1'b1;
        md_held   <= 1'b0;
      end
      else if (md_done) begin
        if (lsu_stall) begin
          // 与 D-Cache 缺失/LSU 停顿重叠: 锁存结果并保持 md_served=1，防止重复发射
          md_held     <= 1'b1;
          md_res_hold <= md_result;
        end
        else begin
          md_served <= 1'b0;
          md_held   <= 1'b0;
        end
      end
      else if (md_held && !lsu_stall) begin
        md_served <= 1'b0;
        md_held   <= 1'b0;
      end
    end
  end

  muldiv #(.XLEN(XLEN)) u_muldiv (
    .clk    (clk),
    .rst    (rst),
    .op     (md_op_eff),
    .a      (md_a_r),
    .b      (md_b_r),
    .result (md_result),
    .busy   (md_busy_raw)
  );

  assign ex_result = (id_ex_ctrl[`CTRL_WB_SRC] == `WB_PC4) ? id_ex_pc_plus4
                   : is_muldiv                             ? md_result_eff
                   : is_csr                                ? csr_rdata
                   : id_ex_ctrl[`CTRL_AMO_EN]              ? ex_amo_addr
                   :                                         ex_alu_out;

  branch_unit #(.XLEN(XLEN)) u_branch (
    .rs1         (ex_rs1),
    .rs2         (ex_rs2),
    .branch_type (id_ex_ctrl[`CTRL_BRANCH_TYPE]),
    .taken       (ex_taken)
  );

  wire [31:0] ex_ctrl_operand_a = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) ? ex_rs1 : id_ex_pc;
  wire [31:0] ex_ctrl_sum       = ex_ctrl_operand_a + id_ex_imm;

  // C-14: 单链 JALR 目标预测比对
  wire [31:0] ex_jr_diff  = ex_rs1 - id_ex_jr_p;
  wire        ex_jr_match = (ex_jr_diff[31:1] == 31'd0);

  assign ex_pc_target = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR)
                        ? {ex_ctrl_sum[31:1], 1'b0}
                        : ex_ctrl_sum;

  assign actual_taken = ((id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR) && ex_taken) ||
                        (id_ex_ctrl[`CTRL_PC_SEL] == `PC_J) ||
                        (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR);

  // IALIGN=32: 若跳转生效且目标地址非 4 字节对齐，触发指令地址非对齐异常 (CAUSE=0)
  // 仅用低 2 位直接判非对齐；条件分支非对齐经 1 拍寄存 br_misalign_r 进陷阱（与 br_redir_r 同构），
  // 彻底剪断 branch_unit 32 位进位链 -> trap_enter -> pc_flush -> ibus_addr -> I-Cache 关键路径
  wire [1:0] ex_jr_lo2          = ex_rs1[1:0] + id_ex_imm[1:0];
  wire       ex_bj_mis          = id_ex_pc[1] ^ id_ex_imm[1];
  assign     insn_misalign_fast = ((id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) && ex_jr_lo2[1]) ||
                                  ((id_ex_ctrl[`CTRL_PC_SEL] == `PC_J)  && ex_bj_mis);
  assign     br_misalign_cond   = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR) && ex_taken && ex_bj_mis;
  assign     insn_misalign      = insn_misalign_fast || br_misalign_cond;

  assign actual_target = actual_taken ? ex_pc_target : id_ex_pc_plus4;

  wire ex_tgt_match = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) ? ex_jr_match
                                                           : (ex_pc_target == id_ex_pred_target);
  assign pred_ok      = (actual_taken == id_ex_pred_taken) &&
                        (!actual_taken || ex_tgt_match);
  assign redirect_raw = !pred_ok && !redir_kill && !insn_misalign && !any_bus_fault;

  // ==========================================================================
  // Zicsr / Zicntr / FENCE.I / SFENCE.VMA / WFI 与精确陷阱仲裁 (M/S/U 特权级)
  // ==========================================================================
  wire su_en = (ENABLE_SU != 0);

  assign is_csr     = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_CSR) && !redir_kill;
  assign csr_src    = id_ex_ctrl[`CTRL_CSR_SRC_IMM] ? {27'b0, id_ex_ctrl[`CTRL_CSR_UIMM]} : ex_rs1;
  assign csr_wdata  = (id_ex_ctrl[`CTRL_CSR_CMD] == 2'b01) ? csr_src
                    : (id_ex_ctrl[`CTRL_CSR_CMD] == 2'b10) ? (csr_rdata |  csr_src)
                    :                                        (csr_rdata & ~csr_src);
  // 规范 §2.8: CSRRW/I 恒写; CSRRS/C 仅在 rs1_idx!=0 (或 uimm!=0) 时构成写意图
  // 时序优化: CSR/MRET/SRET/异常指令绝不与 ex_busy_all (md_busy/wfi/fencei/sfence) 同时存在，
  // 改用 !lsu_stall 替代 !hold_mem，彻底剪断 md_held_reg -> u_muldiv -> hold_mem -> trap_redir 路径!
  assign csr_wr_req = (id_ex_ctrl[`CTRL_CSR_CMD] == 2'b01) ||
                      (id_ex_ctrl[`CTRL_CSR_SRC_IMM] ? (id_ex_ctrl[`CTRL_CSR_UIMM] != 5'd0)
                                                     : (id_ex_rs1 != 5'd0));
  assign csr_we     = is_csr && !lsu_stall && !exc_req && !csr_illegal && !any_bus_fault && !redir_kill && csr_wr_req;

  // 特权指令合法性校验 (Priv Spec v1.12 §3.1.6.5 / §3.3.2 / §3.3.3 / §4.2.1)
  wire is_mret_op     = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_MRET);
  wire is_sret_op     = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_SRET);
  wire is_wfi_op      = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_WFI);
  wire is_sfence_op   = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_SFENCE);

  wire mret_illegal   = is_mret_op   && su_en && (priv_o != `PRIV_M);
  wire sret_illegal   = is_sret_op   && (!su_en || (priv_o == `PRIV_U) || ((priv_o == `PRIV_S) && mstatus_tsr));
  wire wfi_illegal    = is_wfi_op    && su_en && ((priv_o == `PRIV_U) || ((priv_o == `PRIV_S) && mstatus_tw));
  wire sfence_illegal = is_sfence_op && (!su_en || (priv_o == `PRIV_U) || ((priv_o == `PRIV_S) && mstatus_tvm));
  wire priv_illegal   = mret_illegal || sret_illegal || wfi_illegal || sfence_illegal;

  assign is_mret      = is_mret_op && !mret_illegal;
  assign mret_req_int = is_mret && !lsu_stall && !any_bus_fault && !redir_kill;

  assign is_sret      = is_sret_op && !sret_illegal;
  assign sret_req_int = is_sret && !lsu_stall && !any_bus_fault && !redir_kill;

  // FENCE.I: 等待外部 I/D-Cache 完成冲刷后，清空 BTB/RAS 并冲刷取指流跳回 PC+4
  assign is_fencei    = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_FENCEI) && !redir_kill && !any_bus_fault;
  assign fencei_req   = is_fencei && !lsu_stall;
  assign fencei_stall = is_fencei && !fencei_done;
  assign fencei_taken = is_fencei && fencei_done && !lsu_stall;

  // SFENCE.VMA: 通知 Sv32 MMU 刷新 ITLB/DTLB，同步清空 BTB/RAS 并冲刷取指流跳回 PC+4
  assign is_sfence    = is_sfence_op && !sfence_illegal && !redir_kill && !any_bus_fault;
  assign sfence_req   = is_sfence && !lsu_stall;
  assign sfence_vaddr = ex_rs1;
  assign sfence_stall = is_sfence && !sfence_done;
  assign sfence_taken = is_sfence && sfence_done && !lsu_stall;

  // 写 satp 后串行化流水线并重定向至 PC+4；satp_we_taken 仅校验特权级/TVM (不经 csr_exists 链)
  wire satp_addr_hit   = (id_ex_ctrl[`CTRL_CSR_ADDR] == 12'h180);
  wire satp_priv_ok    = (priv_o == `PRIV_M) || ((priv_o == `PRIV_S) && !mstatus_tvm);
  assign satp_we_taken = su_en && is_csr && csr_wr_req && satp_addr_hit && satp_priv_ok &&
                         !lsu_stall && !any_bus_fault && !redir_kill;
  assign satp_flush    = su_en && is_csr && csr_wr_req && satp_addr_hit;

  // WFI: 停顿至任一使能中断挂起 (无视 mstatus.MIE/SIE)，唤醒后顺序退休使下条 PC+4 接管中断
  assign is_wfi    = is_wfi_op && !wfi_illegal && !redir_kill && !any_bus_fault;
  assign wfi_stall = is_wfi && !wfi_wake;

  // WB 段与 MEM 多拍阶段总线访存/缺页故障 (最老指令优先: wb_fault > mem_fault > exc_req > irq_take)
  // 接口契约: dcache/mmu 仅在响应拍 (dbus_stall=0) 才置高 dbus_fault / dbus_page_fault
  wire any_dbus_err      = dbus_fault || dbus_page_fault;
  wire wb_fault_is_load  = mem_wb_ctrl[`CTRL_MEM_READ] ||
                           (mem_wb_ctrl[`CTRL_AMO_EN] && (mem_wb_ctrl[`CTRL_AMO_OP] == `AMO_LR));
  wire mem_fault_is_load = ex_mem_ctrl[`CTRL_MEM_READ] ||
                           (ex_mem_ctrl[`CTRL_AMO_EN] && (ex_mem_ctrl[`CTRL_AMO_OP] == `AMO_LR));

  assign wb_is_mem       = mem_wb_valid &&
                           (mem_wb_ctrl[`CTRL_MEM_READ] || mem_wb_ctrl[`CTRL_MEM_WRITE] || mem_wb_ctrl[`CTRL_AMO_EN]);
  assign mem_fault       = any_dbus_err && lsu_mem_resp && ex_mem_valid;
  assign wb_fault        = any_dbus_err && !lsu_mem_resp && wb_is_mem;
  assign wb_fault_cause  = dbus_page_fault
                           ? (wb_fault_is_load  ? `CAUSE_LOAD_PAGE   : `CAUSE_STORE_PAGE)
                           : (wb_fault_is_load  ? `CAUSE_LOAD_ACCESS : `CAUSE_STORE_ACCESS);
  assign mem_fault_cause = dbus_page_fault
                           ? (mem_fault_is_load ? `CAUSE_LOAD_PAGE   : `CAUSE_STORE_PAGE)
                           : (mem_fault_is_load ? `CAUSE_LOAD_ACCESS : `CAUSE_STORE_ACCESS);
  assign mem_fault_tval  = lsu_in_tail ? ({ex_mem_alu_out[31:2], 2'b00} + 32'd4) : ex_mem_alu_out;

  wire amo_misalign = id_ex_ctrl[`CTRL_AMO_EN] && (ex_amo_addr[1:0] != 2'b00);
  wire ex_illegal   = id_ex_ctrl[`CTRL_ILLEGAL] || csr_illegal || priv_illegal;

  reg        ex_pend_trap_r;
  reg        ex_pend_is_ill_r;
  reg [31:0] ex_pend_pc_r;
  reg [31:0] ex_pend_tval_r;

  wire ex_mem_is_mem = ex_mem_valid &&
                       (ex_mem_ctrl[`CTRL_MEM_READ] || ex_mem_ctrl[`CTRL_MEM_WRITE] || ex_mem_ctrl[`CTRL_AMO_EN]);
  wire id_ex_is_mem  = id_ex_valid && !redir_kill &&
                       (id_ex_ctrl[`CTRL_MEM_READ] || id_ex_ctrl[`CTRL_MEM_WRITE] || id_ex_ctrl[`CTRL_AMO_EN]);

  wire [3:0] ecall_cause = (!su_en || (priv_o == `PRIV_M)) ? `CAUSE_ECALL_M
                         : (priv_o == `PRIV_S)             ? `CAUSE_ECALL_S
                         :                                   `CAUSE_ECALL_U;

  // 时序关键优化: ex_illegal (含 12-bit csr_exists/csr_illegal/priv_illegal) 全部经由
  // 1 拍寄存精确陷阱 ex_pend_trap_r 进入 trap_req，彻底剪断 csr_exists -> trap_redir ->
  // pc_next -> I-Cache/BHT 12 级 LUT 关键路径 (正常指令零额外周期，异常语义 100% 精确)!
  assign exc_req    = !lsu_stall && !redir_kill && !any_bus_fault && (
                        id_ex_if_pf ||
                        id_ex_if_fault ||
                        (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_ECALL) ||
                        (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_EBREAK) ||
                        insn_misalign_fast ||
                        amo_misalign);

  assign exc_cause  = id_ex_if_pf                                ? `CAUSE_INSN_PAGE
                    : id_ex_if_fault                             ? `CAUSE_INSN_ACCESS
                    : (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_ECALL)   ? ecall_cause
                    : (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_EBREAK)  ? `CAUSE_BREAKPOINT
                    : insn_misalign_fast                         ? `CAUSE_INSN_MISALIGN
                    : (id_ex_ctrl[`CTRL_AMO_OP] == `AMO_LR)      ? `CAUSE_LOAD_MISALIGN
                    :                                              `CAUSE_STORE_MISALIGN;

  // 异步中断: 不在 CSR/WFI/xRET/FENCE.I/SFENCE 上抢占 (消除 csr_we 与 irq_take 竞争)
  assign irq_take   = irq_pending && !hold_mem && !exc_req && !any_bus_fault &&
                      !is_csr && !is_mret && !is_sret && !is_wfi && !is_fencei && !is_sfence && !ex_mem_is_mem &&
                      !((id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR) && ex_bj_mis) &&
                      id_ex_valid && !redir_kill;

  assign trap_req   = wb_fault || mem_fault || ex_pend_trap_r || exc_req || irq_take;
  assign trap_cause = wb_fault       ? {1'b0, wb_fault_cause}
                    : mem_fault      ? {1'b0, mem_fault_cause}
                    : ex_pend_trap_r ? {1'b0, (ex_pend_is_ill_r ? `CAUSE_ILLEGAL : `CAUSE_INSN_MISALIGN)}
                    : exc_req        ? {1'b0, exc_cause}
                    :                  irq_cause;
  wire [31:0] trap_pc_sel = wb_fault       ? mem_wb_pc
                          : mem_fault      ? ex_mem_pc
                          : ex_pend_trap_r ? ex_pend_pc_r
                          :                  id_ex_pc;
  assign trap_tval  = wb_fault                       ? mem_wb_alu_out
                    : mem_fault                      ? mem_fault_tval
                    : ex_pend_trap_r                 ? ex_pend_tval_r
                    : (id_ex_if_pf || id_ex_if_fault)? id_ex_pc
                    : insn_misalign_fast             ? ex_pc_target
                    : amo_misalign                   ? ex_amo_addr
                    :                                  32'd0;

  csr_file #(
    .ENABLE_SU   (ENABLE_SU),
    .MTVEC_RESET (MTVEC_RESET)
  ) u_csr (
    .clk          (clk),
    .rst          (rst),
    .csr_op_en    (is_csr),
    .csr_wr_req   (csr_wr_req),
    .raddr        (id_ex_ctrl[`CTRL_CSR_ADDR]),
    .rdata        (csr_rdata),
    .csr_illegal  (csr_illegal),
    .we           (csr_we),
    .waddr        (id_ex_ctrl[`CTRL_CSR_ADDR]),
    .wdata        (csr_wdata),
    .trap_req     (trap_req),
    .trap_cause   (trap_cause),
    .trap_pc      (trap_pc_sel),
    .trap_tval    (trap_tval),
    .trap_enter   (trap_enter),
    .trap_vector  (trap_vector),
    .mret_req     (mret_req_int),
    .mret_taken   (mret_taken),
    .mret_pc      (mret_pc),
    .sret_req     (sret_req_int),
    .sret_taken   (sret_taken),
    .sret_pc      (sret_pc),
    .instret_inc  (instret_inc),
    .mtime_i      (mtime_i),
    .irq_sw       (irq_sw),
    .irq_timer    (irq_timer),
    .irq_ext      (irq_ext),
    .irq_sext     (irq_sext),
    .irq_pending  (irq_pending),
    .irq_cause    (irq_cause),
    .wfi_wake     (wfi_wake),
    .priv_o       (priv_o),
    .satp_o       (satp_o),
    .i_xlate_en_o (i_xlate_en_o),
    .mstatus_sum  (mstatus_sum),
    .mstatus_mxr  (mstatus_mxr),
    .mstatus_mprv (mstatus_mprv),
    .mstatus_mpp  (mstatus_mpp),
    .mstatus_tvm  (mstatus_tvm),
    .mstatus_tw   (mstatus_tw),
    .mstatus_tsr  (mstatus_tsr)
  );

  // ==========================================================================
  // C-11 / C-15 寄存重定向 + 1 拍寄存精确陷阱 (条件分支非对齐 / 访存后非法指令)
  // ==========================================================================
  assign br_redir     = redirect;
  assign br_redir_eff = br_redir && !trap_redir && !redir_kill && !any_bus_fault;
  wire   ill_defer_cond   = ex_illegal && !id_ex_if_fault && !id_ex_if_pf;
  wire   ex_pend_trap_eff = (br_misalign_cond || ill_defer_cond) &&
                            !hold_mem && !trap_redir && !redir_kill && !any_bus_fault;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      br_redir_r       <= 1'b0;
`ifndef SYNTHESIS
      br_redir_r2      <= 1'b0;
`endif
      br_tgt_r         <= 32'd0;
      ex_pend_trap_r   <= 1'b0;
      ex_pend_is_ill_r <= 1'b0;
      ex_pend_pc_r     <= 32'd0;
      ex_pend_tval_r   <= 32'd0;
    end
    else if (trap_redir) begin
      br_redir_r       <= 1'b0;
`ifndef SYNTHESIS
      br_redir_r2      <= 1'b0;
`endif
      br_tgt_r         <= 32'd0;
      ex_pend_trap_r   <= 1'b0;
      ex_pend_is_ill_r <= 1'b0;
      ex_pend_pc_r     <= 32'd0;
      ex_pend_tval_r   <= 32'd0;
    end
    else begin
      br_redir_r       <= br_redir_eff;
`ifndef SYNTHESIS
      br_redir_r2      <= br_redir_r;
`endif
      br_tgt_r         <= actual_target;
      ex_pend_trap_r   <= ex_pend_trap_eff;
      ex_pend_is_ill_r <= ill_defer_cond;
      ex_pend_pc_r     <= id_ex_pc;
      ex_pend_tval_r   <= ill_defer_cond ? id_ex_instr : ex_pc_target;
    end
  end

  assign redir_kill  = br_redir_r || ex_pend_trap_r;
  assign redir_flush = br_redir_eff || br_redir_r || ex_pend_trap_eff || ex_pend_trap_r;
  assign trap_redir  = trap_enter || mret_taken || sret_taken || fencei_taken || sfence_taken || satp_we_taken;
  assign any_redir   = redir_flush || trap_redir;
  assign id_ex_flush = trap_redir || br_redir_r;

  assign pc_flush    = trap_redir || br_redir_r;
  assign pc_flush_pc = trap_enter                                      ? trap_vector
                     : mret_taken                                      ? mret_pc
                     : sret_taken                                      ? sret_pc
                     : (fencei_taken || sfence_taken || satp_we_taken) ? id_ex_pc_plus4
                     :                                                   br_tgt_r;
  assign pc_src      = pred_taken;
  assign pc_target   = pred_target;

  // ==========================================================================
  // 冒险单元 & C-10/C-14 ID 预选寄存
  // ==========================================================================
  // 仅判 5-bit if_instr[6:2] 是否为 SYSTEM(11100) / MISC_MEM(00011) (单级 LUT5!)，
  // 任何非法操作码或非法 funct 均已由 EX 级 ill_defer_cond 1 拍寄存陷阱精确兜底，
  // 100% 保持精确异常优先级同时再砍掉 1 级 LUT6 (~0.85 ns)!
  wire id_is_sys_opc    = (if_instr[6:2] == 5'b11100) || (if_instr[6:2] == 5'b00011);
  wire id_mem_in_flight = id_ex_is_mem || ex_mem_is_mem;
  wire id_sys_stall     = id_en && id_mem_in_flight && (if_fault || if_pf || id_is_sys_opc);
  wire ex_busy_all      = md_busy || wfi_stall || fencei_stall || sfence_stall;

  hazard_unit u_hazard (
    .id_ex_mem_read   ((id_ex_ctrl[`CTRL_MEM_READ] || id_ex_ctrl[`CTRL_AMO_EN]) && !redir_kill),
    .id_ex_reg_write  (id_ex_ctrl[`CTRL_REG_WRITE] && !redir_kill),
    .id_ex_rd         (redir_kill ? 5'd0 : id_ex_rd),
    .ex_mem_reg_write (ex_mem_ctrl[`CTRL_REG_WRITE]),
    .ex_mem_mem_read  (ex_mem_ctrl[`CTRL_MEM_READ] || ex_mem_ctrl[`CTRL_AMO_EN]),
    .mem_fast_load    (mem_fast_load),
    .ex_mem_rd        (ex_mem_rd),
    .if_id_rs1        (id_rs1_haz),
    .if_id_rs2        (id_rs2_haz),
    .id_valid         (id_en && !if_fault && !if_pf),
    .lsu_stall        (lsu_stall),
    .ex_busy          (ex_busy_all),
    .id_sys_stall     (id_sys_stall),
    .redirect_raw     (redirect_raw),
    .fwd_a_pre        (fwd_a_pre),
    .fwd_b_pre        (fwd_b_pre),
    .pipe_stall       (pipe_stall),
    .stall_no_l0      (stall_no_l0),
    .load_use_mem_hit (load_use_mem_hit),
    .id_ex_bubble     (id_ex_bubble),
    .hold_mem         (hold_mem),
    .redirect         (redirect)
  );

  wire [31:0] id_jr_p = if_pred_target - id_imm;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      id_ex_fwd_a <= `FWD_REG;
      id_ex_fwd_b <= `FWD_REG;
      id_ex_jr_p  <= 32'd0;
    end
    else if (!pipe_stall) begin
      id_ex_fwd_a <= fwd_a_pre;
      id_ex_fwd_b <= fwd_b_pre;
      id_ex_jr_p  <= id_jr_p;
    end
  end

  // ==========================================================================
  // EX/MEM (遇 ex_pend_trap_eff 同步清零 ctrl_in，确保非法 CSR 绝不提交写 rd)
  // ==========================================================================
  wire ex_mem_squash = !id_ex_valid || redir_kill || ex_pend_trap_eff;

  ex_mem_reg u_ex_mem (
    .clk           (clk),
    .rst           (rst),
    .stall         (hold_mem),
    .flush         (trap_enter || br_redir_r),
    .valid_in      (!ex_mem_squash),
    .pc_in         (id_ex_pc),
    .ctrl_in       (ex_mem_squash ? `CTRL_NOP : id_ex_ctrl),
    .alu_out_in    (ex_result),
    .store_data_in (ex_rs2),
    .pc_plus4_in   (id_ex_pc_plus4),
    .rd_addr_in    (id_ex_rd),
    .valid         (ex_mem_valid),
    .pc            (ex_mem_pc),
    .ctrl          (ex_mem_ctrl),
    .alu_out       (ex_mem_alu_out),
    .store_data    (ex_mem_store_data),
    .pc_plus4      (ex_mem_pc_plus4),
    .rd_addr       (ex_mem_rd)
  );

  // ==========================================================================
  // MEM 段 (LSU + RV32A + 外部数据总线接口)
  // ==========================================================================
  wire [31:0] amo_newdata;
`ifndef A_DIS
  wire [31:0] amo_new_comb;
`endif

  assign dbus_l0_addr = ex_mem_alu_out;
  assign dbus_is_amo  = ex_mem_ctrl[`CTRL_AMO_EN] && (ex_mem_ctrl[`CTRL_AMO_OP] != `AMO_LR);

  load_store_unit u_lsu (
    .clk             (clk),
    .rst             (rst),
    .req_read        (ex_mem_ctrl[`CTRL_MEM_READ]),
    .req_write       (ex_mem_ctrl[`CTRL_MEM_WRITE]),
    .req_size        (ex_mem_ctrl[`CTRL_MEM_SIZE]),
    .req_unsigned    (ex_mem_ctrl[`CTRL_MEM_UNSIGNED]),
    .req_addr        (ex_mem_alu_out),
    .req_wdata       (ex_mem_store_data),
    .req_cancel      (any_bus_fault),
    .dmem_addr       (dbus_addr),
    .dmem_wdata      (dbus_wdata),
    .dmem_wstrb      (dbus_wstrb),
    .dmem_we         (dbus_we),
    .dmem_re         (dbus_re),
    .dmem_rdata      (dbus_rdata),
    .dbus_stall      (dbus_stall),
    .dbus_l0_en      (dbus_l0_en),
    .dbus_fast_hit   (dbus_fast_hit),
    .dbus_fast_rdata (dbus_fast_rdata),
    .load_data       (mem_load_data),
    .fast_load_hit   (mem_fast_load),
    .fast_load_data  (mem_fast_load_data),
    .lsu_stall       (lsu_stall),
    .lsu_mem_resp    (lsu_mem_resp),
    .lsu_in_tail     (lsu_in_tail),
    .amo_en          (ex_mem_ctrl[`CTRL_AMO_EN]),
    .amo_newdata     (amo_newdata),
    .amo_lr          (amo_is_lr),
    .amo_sc          (amo_is_sc),
    .res_clear       (trap_enter || mret_taken || sret_taken),
    .amo_write_phase (amo_write_phase),
    .amo_old_out     (amo_old),
    .amo_sc_ok       (amo_sc_ok),
    .amo_wb_out      (amo_wb_val)
  );

`ifndef A_DIS
  // MEM 段直接使用 ex_mem_ctrl[`CTRL_AMO_OP] 与 ex_mem_store_data，
  // 全程冻结于 hold_mem 期间，彻底隔离背靠背 AMO / LR->SC 序列。
  wire [4:0]  mem_amo_op = ex_mem_ctrl[`CTRL_AMO_OP];
  wire [31:0] amo_rs2    = ex_mem_store_data;

  assign amo_is_lr = (mem_amo_op == `AMO_LR);
  assign amo_is_sc = (mem_amo_op == `AMO_SC);

  wire [4:0] amo_alu_op =
        (mem_amo_op == `AMO_SWAP) ? `ALU_AMO_SWAP :
        (mem_amo_op == `AMO_ADD)  ? `ALU_AMO_ADD  :
        (mem_amo_op == `AMO_XOR)  ? `ALU_AMO_XOR  :
        (mem_amo_op == `AMO_AND)  ? `ALU_AMO_AND  :
        (mem_amo_op == `AMO_OR)   ? `ALU_AMO_OR   :
        (mem_amo_op == `AMO_MIN)  ? `ALU_AMO_MIN  :
        (mem_amo_op == `AMO_MAX)  ? `ALU_AMO_MAX  :
        (mem_amo_op == `AMO_MINU) ? `ALU_AMO_MINU :
        (mem_amo_op == `AMO_MAXU) ? `ALU_AMO_MAXU :
                                    `ALU_AMO_ADD;

  alu #(.XLEN(XLEN)) u_amo_alu (
    .a   (amo_old),
    .b   (amo_rs2),
    .op  (amo_alu_op),
    .out (amo_new_comb)
  );

  assign amo_newdata = !amo_write_phase ? 32'd0
                     : amo_is_lr        ? 32'd0
                     : amo_is_sc        ? (amo_sc_ok ? amo_rs2 : 32'd0)
                     :                    amo_new_comb;
`else
  assign amo_newdata = 32'd0;
  assign amo_is_lr   = 1'b0;
  assign amo_is_sc   = 1'b0;
`endif

  // ==========================================================================
  // MEM/WB 与 WB 段
  // ==========================================================================
  mem_wb_reg u_mem_wb (
    .clk          (clk),
    .rst          (rst),
    .stall        (hold_mem),
    .flush        (any_bus_fault),
    .valid_in     (ex_mem_valid),
    .pc_in        (ex_mem_pc),
    .ctrl_in      (ex_mem_ctrl),
    .alu_out_in   (ex_mem_alu_out),
    .load_data_in (mem_fast_load ? mem_fast_load_data : 32'h0),
    .fast_load_in (mem_fast_load),
    .pc_plus4_in  (ex_mem_pc_plus4),
    .rd_addr_in   (ex_mem_rd),
    .valid        (mem_wb_valid),
    .pc           (mem_wb_pc),
    .ctrl         (mem_wb_ctrl),
    .alu_out      (mem_wb_alu_out),
    .load_data    (mem_wb_load_data),
    .fast_load    (mem_wb_fast_load),
    .pc_plus4     (mem_wb_pc_plus4),
    .rd_addr      (mem_wb_rd)
  );

  always @(*) begin
    if (mem_wb_wb_src == `WB_MEM) begin
      wb_data = mem_wb_fast_load ? mem_wb_load_data : mem_load_data;
    end
    else begin
      wb_data = mem_wb_alu_out;
    end
  end

  assign wb_reg_write = mem_wb_ctrl[`CTRL_REG_WRITE] && (mem_wb_rd != 5'd0) && !hold_mem && !wb_fault;
  assign wb_rd        = mem_wb_rd;
  assign instret_inc  = mem_wb_valid && !hold_mem && !wb_fault;

  // ==========================================================================
  // 调试观测与仿真自检断言 (纯 Verilog-2001)
  // ==========================================================================
  assign dbg_pc        = pc;
  assign dbg_id_pc     = if_pc;
  assign dbg_instr     = if_instr;
  assign dbg_mem_we    = dbus_we && (dbus_wstrb != 4'b0000);
  assign dbg_mem_addr  = dbus_addr;
  assign dbg_mem_wdata = dbus_wdata;
  assign dbg_stall     = pipe_stall || !ibus_valid;
  assign dbg_redirect  = redirect;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      dbg_illegal <= 1'b0;
    end
    else if (ex_illegal && !pipe_stall && !redir_flush && !trap_enter) begin
      dbg_illegal <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (!rst && pc_flush && (pc_flush_pc[1:0] != 2'b00)) begin
      $display("ERROR: pc_flush_pc not word-aligned: target=%h", pc_flush_pc);
      $finish;
    end
    if (!rst && id_ex_valid && (id_ex_pred_target[1:0] != 2'b00)) begin
      $display("ERROR: C-14 predicted target not word-aligned: %h", id_ex_pred_target);
      $finish;
    end
    if (!rst && trap_enter && !any_bus_fault && !ex_pend_trap_r && !id_ex_valid) begin
      $display("ERROR: trap_enter on invalid EX instruction (R-01): pc=0x%08x cause=0x%02x",
               id_ex_pc, trap_cause);
      $finish;
    end
    if (!rst && redir_kill &&
        (csr_we || exc_req || irq_take || mret_req_int || sret_req_int || btb_upd_en || br_redir_eff || fencei_taken || sfence_taken || satp_we_taken)) begin
      $display("ERROR: C-15 wrong-path X0 had side effect in EX (csr=%b exc=%b irq=%b mret=%b sret=%b btb=%b redir=%b fi=%b sf=%b pc=0x%08x)",
               csr_we, exc_req, irq_take, mret_req_int, sret_req_int, btb_upd_en, br_redir_eff, fencei_taken, sfence_taken, id_ex_pc);
      $finish;
    end
    if (!rst && br_redir_r2 && (ex_mem_ctrl != `CTRL_NOP)) begin
      $display("ERROR: C-15 wrong-path instruction reached MEM (ex_mem_ctrl != 0)");
      $finish;
    end
  end
`endif

endmodule
