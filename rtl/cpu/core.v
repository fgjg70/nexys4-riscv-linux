`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// core.v — RV32IMA 单发射五级流水线处理器 (IF / ID / EX / MEM / WB)
// 纯 Verilog-2001，零厂商原语，目标平台 Nexys 4 DDR (XC7A100T-1CSG324C)
// ----------------------------------------------------------------------------
// - 4 级流水寄存器 (IMEM 输出寄存器充当 IF/ID + ID/EX + EX/MEM + MEM/WB) => 5 级
// - 两级流水 gshare 分支预测 (512-BTB + 8192-PHT) + C-10 ID 段前递预选 + C-11/C-15 寄存重定向
// - C-2 固定 2 拍 load-use 气泡 (load 不进前递, regfile 写优先旁路补最后一棒)
// - RV32A 默认开启 (LR/SC 真预约 + Trap/MRET 清除预约), 定义 A_DIS 可关闭
// - RV32M 除法默认基-2, 定义 DIV_RADIX4 可切换 16 步基-4
// ============================================================================

module core (
  input  wire        clk,
  input  wire        rst,

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
  output wire        dbg_redirect,

  // 外部 MMIO 总线
  output wire        ext_we,
  output wire        ext_re,
  output wire [31:0] ext_addr,
  output wire [31:0] ext_wdata,
  output wire [3:0]  ext_wstrb,
  input  wire [31:0] ext_rdata,

  // 定时器中断请求 (电平 -> mip.MTIP)
  input  wire        irq_timer
);

  localparam XLEN = `RV32_XLEN;

  // ==========================================================================
  // 互连信号声明
  // ==========================================================================
  // IF
  wire [31:0] pc, pc_plus4, pc_target, imem_rdata;
  (* max_fanout = 16 *) wire pc_src;
  (* max_fanout = 16 *) wire redirect, redirect_raw;
  wire        lsu_stall;
  wire        amo_write_phase;
  wire [31:0] amo_old;
  wire        amo_is_lr, amo_is_sc, amo_sc_ok;
  wire        id_ex_bubble;

  // 分支预测
  wire        pred_hit, pred_taken, btb_upd_en, is_ctrl_flow;
  wire [31:0] pred_target, actual_target;
  wire        pred_is_ret;
  wire        ex_is_call, ex_is_ret, ex_is_cond;
  (* max_fanout = 16 *) wire actual_taken;
  wire        pred_ok;
  wire [31:0] btb_pred_target;
  wire [15:0] btb_align_err;

  // IF/ID (组合别名: IMEM 寄存输出充当 IF/ID)
  wire [31:0] if_pc, if_pc_plus4, if_instr;
  wire        if_pred_taken;
  wire [31:0] if_pred_target;

  // ID
  wire [`CTRL_W-1:0] id_ctrl_raw;
  reg  [`CTRL_W-1:0] id_ctrl;
  wire               id_en;
  wire [31:0]        id_imm, id_rs1_data, id_rs2_data;
  wire [4:0]         id_rs1, id_rs2, id_rd;

  // ID/EX
  wire [`CTRL_W-1:0] id_ex_ctrl;
  wire               id_ex_valid;
  wire [31:0]        id_ex_instr;
  wire [31:0]        id_ex_pc, id_ex_pc_plus4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  wire [4:0]         id_ex_rs1, id_ex_rs2, id_ex_rd;
  wire               id_ex_pred_taken;
  wire [31:0]        id_ex_pred_target;
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
  wire               md_busy_raw;
  wire               ex_taken;

  // Zicsr / 陷阱 (M-mode)
  wire [31:0] csr_rdata, csr_wdata, csr_src;
  wire        csr_we, is_csr;
  wire        exc_req, irq_take, trap_req, trap_enter, trap_redir;
  wire        mret_req_int;
  (* max_fanout = 16 *) wire any_redir;
  wire [4:0]  trap_cause, irq_cause;
  wire [3:0]  exc_cause;
  wire [31:0] trap_vector, mret_pc, trap_tval;
  wire        irq_pending, mret_taken, is_mret;

  // EX/MEM
  wire [`CTRL_W-1:0] ex_mem_ctrl;
  wire [31:0]        ex_mem_alu_out, ex_mem_store_data, ex_mem_pc_plus4;
  wire [4:0]         ex_mem_rd;

  // MEM
  wire [31:0] dmem_addr, dmem_wdata, dmem_rdata, mem_load_data;
  wire [3:0]  dmem_wstrb;
  wire        dmem_we;
  wire        sel_dmem;
  wire        dmem_we_g;
  wire [31:0] dmem_rdata_g;
  reg         sel_dmem_r;
  reg  [31:0] ext_rdata_r;

  // MEM/WB
  wire [`CTRL_W-1:0] mem_wb_ctrl;
  wire [31:0]        mem_wb_alu_out, mem_wb_load_data, mem_wb_pc_plus4;
  wire [4:0]         mem_wb_rd;
  (* max_fanout = 16 *) wire [1:0] mem_wb_wb_src = mem_wb_ctrl[`CTRL_WB_SRC];

  // WB
  reg  [31:0] wb_data;
  wire [4:0]  wb_rd;
  wire        wb_reg_write;

  // 流水线控制
  wire        pipe_stall, if_id_flush, hold_mem;
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
  // IF 段
  // ==========================================================================
  wire fetch_hold;
  wire boot_done;
`ifdef IMEM_COMB_READ
  assign fetch_hold = pipe_stall;
  assign boot_done  = 1'b1;
`else
  reg boot_done_r;
  always @(posedge clk or posedge rst) begin
    if (rst) boot_done_r <= 1'b0;
    else     boot_done_r <= 1'b1;
  end
  assign boot_done  = boot_done_r;
  assign fetch_hold = pipe_stall || !boot_done;
`endif

  pc #(.XLEN(XLEN), .RESET_PC(`PC_RESET)) u_pc (
    .clk       (clk),
    .rst       (rst),
    .stall     (fetch_hold),
    .flush     (pc_flush),
    .flush_pc  (pc_flush_pc),
    .pc_src    (pc_src),
    .pc_target (pc_target),
    .pc        (pc),
    .pc_plus4  (pc_plus4)
  );

  wire [31:0] pc_next = pc_flush   ? pc_flush_pc
                      : fetch_hold ? pc
                      : (pc_src ? pc_target : pc_plus4);
`ifdef IMEM_COMB_READ
  wire [31:0] imem_addr = pc;
`else
  wire [31:0] imem_addr = pc_next;
`endif

  wire [31:0] p2_pc_ns = pc_flush ? pc_flush_pc : (pc_src ? pc_target : pc_plus4);
  wire        p2_hold  = fetch_hold && !pc_flush;

  imem #(.BASE(`IMEM_BASE), .BYTES(`IMEM_BYTES)) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  assign if_id_flush = any_redir;

  // ==========================================================================
  // 分支预测 (C-1 两级流水 gshare)
  // ==========================================================================
  btb #(.IDX_BITS(9), .PC_TOP(14), .PC_BASE(`IMEM_BASE)) u_btb (
    .clk           (clk),
    .rst           (rst),
    .pred_pc       (32'd0),
    .pred_hit      (),
    .pred_taken    (),
    .pred_target   (),
    .pred_is_ret   (),
    .p2_pc         (p2_pc_ns),
    .p2_hold       (p2_hold),
    .p2_pc_pht     (pc_next),
    .q_hit         (pred_hit),
    .q_taken       (pred_taken),
    .q_target      (btb_pred_target),
    .q_is_ret      (pred_is_ret),
    .upd_en        (btb_upd_en),
    .upd_pc        (id_ex_pc),
    .upd_taken     (actual_taken),
    .upd_target    (ex_pc_target),
    .upd_is_ret    (ex_is_ret),
    .upd_is_cond   (ex_is_cond),
    .align_err_cnt (btb_align_err)
  );

  assign ex_is_cond = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR);

`ifdef RAS_EN
  wire [31:0] ras_top;
  wire        ras_empty;
  wire ex_is_call_w = btb_upd_en
                   && ((id_ex_ctrl[`CTRL_PC_SEL] == `PC_J) || (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR))
                   && ((id_ex_rd == 5'd1) || (id_ex_rd == 5'd5));
  wire ex_is_ret_w  = btb_upd_en
                   && (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR)
                   && ((id_ex_rs1 == 5'd1) || (id_ex_rs1 == 5'd5))
                   && (id_ex_rd == 5'd0);
  assign ex_is_call  = ex_is_call_w;
  assign ex_is_ret   = ex_is_ret_w;

  ras #(.DEPTH(8)) u_ras (
    .clk     (clk),
    .rst     (rst),
    .push_en (ex_is_call),
    .push_pc (id_ex_pc_plus4),
    .pop_en  (ex_is_ret),
    .top     (ras_top),
    .empty   (ras_empty)
  );

  assign pred_target = (pred_is_ret && !ras_empty) ? ras_top : btb_pred_target;
`else
  assign ex_is_call  = 1'b0;
  assign ex_is_ret   = 1'b0;
  assign pred_target = btb_pred_target;
`endif

  assign is_ctrl_flow = (id_ex_ctrl[`CTRL_PC_SEL] != `PC_NEXT);
  assign btb_upd_en   = is_ctrl_flow && !hold_mem && !rst && !redir_kill;

  assign if_pc          = pc;
  assign if_pc_plus4    = pc_plus4;
  assign if_instr       = imem_rdata;
  assign if_pred_taken  = pred_taken;
  assign if_pred_target = pred_target;
  assign id_en          = boot_done;

  // ==========================================================================
  // ID 段
  // ==========================================================================
  assign id_rs1 = if_instr[19:15];
  assign id_rs2 = if_instr[24:20];
  assign id_rd  = if_instr[11:7];

  control_unit #(.XLEN(XLEN)) u_ctrl (
    .instr (if_instr),
    .ctrl  (id_ctrl_raw)
  );

  always @(*) begin
    id_ctrl = id_en ? id_ctrl_raw : `CTRL_NOP;
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
    .ctrl           (id_ex_ctrl),
    .valid          (id_ex_valid),
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
    .pred_target    (id_ex_pred_target)
  );

  // ==========================================================================
  // EX 段
  // ==========================================================================
  wire [31:0] ex_mem_fwd_data = (ex_mem_ctrl[`CTRL_WB_SRC] == `WB_PC4) ? ex_mem_pc_plus4
                                                                       : ex_mem_alu_out;

`ifndef A_DIS
  wire [31:0] amo_wb_value = amo_is_sc ? {31'b0, ~amo_sc_ok} : amo_old;
`else
  wire [31:0] amo_wb_value = 32'd0;
`endif

  wire [31:0] fwd_wb_data =
        (mem_wb_wb_src != `WB_MEM)   ? ((mem_wb_wb_src == `WB_PC4) ? mem_wb_pc_plus4
                                                                   : mem_wb_alu_out)
      : mem_wb_ctrl[`CTRL_MEM_READ]  ? mem_wb_load_data
      :                                amo_wb_value;

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

  wire       is_muldiv_eff = is_muldiv && !redir_kill;
  wire       md_start      = is_muldiv_eff && !md_served;
  wire       md_done       = md_served && !md_busy_raw;
  wire [4:0] md_op_eff     = md_served ? md_op_r : `ALU_ADD;
  assign     md_busy       = md_start || (md_served && !md_done);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      md_a_r    <= 32'd0;
      md_b_r    <= 32'd0;
      md_op_r   <= `ALU_ADD;
      md_served <= 1'b0;
    end
    else begin
      if (md_start) begin
        md_a_r  <= ex_rs1;
        md_b_r  <= ex_rs2;
        md_op_r <= id_ex_ctrl[`CTRL_ALU_OP];
      end
      md_served <= md_start | (md_served & ~md_done);
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

  assign ex_result = is_muldiv                ? md_result
                   : is_csr                   ? csr_rdata
                   : id_ex_ctrl[`CTRL_AMO_EN] ? ex_amo_addr
                   :                            ex_alu_out;

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

  assign actual_target = actual_taken ? ex_pc_target : id_ex_pc_plus4;

  wire ex_tgt_match = (id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) ? ex_jr_match
                                                           : (ex_pc_target == id_ex_pred_target);
  assign pred_ok      = (actual_taken == id_ex_pred_taken) &&
                        (!actual_taken || ex_tgt_match);
  assign redirect_raw = !pred_ok && !redir_kill;

  // ==========================================================================
  // Zicsr 与陷阱 (M-mode)
  // ==========================================================================
  csr_file u_csr (
    .clk         (clk),
    .rst         (rst),
    .raddr       (id_ex_ctrl[`CTRL_CSR_ADDR]),
    .rdata       (csr_rdata),
    .we          (csr_we),
    .waddr       (id_ex_ctrl[`CTRL_CSR_ADDR]),
    .wdata       (csr_wdata),
    .trap_req    (trap_req),
    .trap_cause  (trap_cause),
    .trap_pc     (id_ex_pc),
    .trap_tval   (trap_tval),
    .trap_enter  (trap_enter),
    .trap_vector (trap_vector),
    .mret_req    (mret_req_int),
    .mret_taken  (mret_taken),
    .mret_pc     (mret_pc),
    .irq_timer   (irq_timer),
    .irq_ext     (1'b0),
    .irq_pending (irq_pending),
    .irq_cause   (irq_cause)
  );

  assign is_csr    = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_CSR);
  assign csr_src   = id_ex_ctrl[`CTRL_CSR_SRC_IMM] ? {27'b0, id_ex_ctrl[`CTRL_CSR_UIMM]} : ex_rs1;
  assign csr_wdata = (id_ex_ctrl[`CTRL_CSR_CMD] == 2'b01) ? csr_src
                   : (id_ex_ctrl[`CTRL_CSR_CMD] == 2'b10) ? (csr_rdata |  csr_src)
                   :                                        (csr_rdata & ~csr_src);
  assign csr_we    = is_csr && !hold_mem && !exc_req && !redir_kill &&
                     ((id_ex_ctrl[`CTRL_CSR_CMD] == 2'b01) || (csr_src != 32'd0));

  assign is_mret      = (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_MRET);
  assign mret_req_int = is_mret && !hold_mem && !redir_kill;

  wire amo_misalign = id_ex_ctrl[`CTRL_AMO_EN] && (ex_amo_addr[1:0] != 2'b00);
  assign exc_req    = !hold_mem && !redir_kill && (
                        id_ex_ctrl[`CTRL_ILLEGAL] ||
                        (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_ECALL) ||
                        (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_EBREAK) ||
                        amo_misalign);
  assign exc_cause  = id_ex_ctrl[`CTRL_ILLEGAL]                  ? `CAUSE_ILLEGAL
                    : (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_ECALL)   ? `CAUSE_ECALL_M
                    : (id_ex_ctrl[`CTRL_SYS_OP] == `SYS_EBREAK)  ? `CAUSE_BREAKPOINT
                    : (id_ex_ctrl[`CTRL_AMO_OP] == `AMO_LR)      ? `CAUSE_LOAD_MISALIGN
                    :                                              `CAUSE_STORE_MISALIGN;

  assign irq_take   = irq_pending && !hold_mem && !exc_req && !is_mret && id_ex_valid && !redir_kill;
  assign trap_req   = exc_req || irq_take;
  assign trap_cause = exc_req ? {1'b0, exc_cause} : irq_cause;
  assign trap_tval  = id_ex_ctrl[`CTRL_ILLEGAL] ? id_ex_instr
                    : amo_misalign              ? ex_amo_addr
                    :                             32'd0;

  // ==========================================================================
  // C-11 / C-15 寄存重定向
  // ==========================================================================
  assign br_redir     = redirect;
  assign br_redir_eff = br_redir && !trap_redir && !redir_kill;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      br_redir_r  <= 1'b0;
`ifndef SYNTHESIS
      br_redir_r2 <= 1'b0;
`endif
      br_tgt_r    <= 32'd0;
    end
    else begin
      br_redir_r  <= br_redir_eff;
`ifndef SYNTHESIS
      br_redir_r2 <= br_redir_r;
`endif
      br_tgt_r    <= actual_target;
    end
  end

  assign redir_kill  = br_redir_r;
  assign redir_flush = br_redir_eff || br_redir_r;
  assign trap_redir  = trap_enter || mret_taken;
  assign any_redir   = redir_flush || trap_redir;
  assign id_ex_flush = trap_redir || br_redir_r;

  assign pc_flush    = trap_redir || br_redir_r;
  assign pc_flush_pc = trap_enter ? trap_vector
                     : mret_taken ? mret_pc
                     :              br_tgt_r;
  assign pc_src      = pred_taken;
  assign pc_target   = pred_target;

  // ==========================================================================
  // 冒险单元 & C-10/C-14 ID 预选寄存
  // ==========================================================================
  hazard_unit u_hazard (
    .id_ex_mem_read   (id_ex_ctrl[`CTRL_MEM_READ]  && !redir_kill),
    .id_ex_reg_write  (id_ex_ctrl[`CTRL_REG_WRITE] && !redir_kill),
    .id_ex_rd         (redir_kill ? 5'd0 : id_ex_rd),
    .ex_mem_reg_write (ex_mem_ctrl[`CTRL_REG_WRITE]),
    .ex_mem_mem_read  (ex_mem_ctrl[`CTRL_MEM_READ]),
    .ex_mem_rd        (ex_mem_rd),
    .if_id_rs1        (id_rs1),
    .if_id_rs2        (id_rs2),
    .lsu_stall        (lsu_stall),
    .ex_busy          (md_busy),
    .redirect_raw     (redirect_raw),
    .fwd_a_pre        (fwd_a_pre),
    .fwd_b_pre        (fwd_b_pre),
    .pipe_stall       (pipe_stall),
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
  // EX/MEM
  // ==========================================================================
  ex_mem_reg u_ex_mem (
    .clk           (clk),
    .rst           (rst),
    .stall         (hold_mem),
    .flush         (trap_enter || br_redir_r),
    .ctrl_in       (id_ex_ctrl),
    .alu_out_in    (ex_result),
    .store_data_in (ex_rs2),
    .pc_plus4_in   (id_ex_pc_plus4),
    .rd_addr_in    (id_ex_rd),
    .ctrl          (ex_mem_ctrl),
    .alu_out       (ex_mem_alu_out),
    .store_data    (ex_mem_store_data),
    .pc_plus4      (ex_mem_pc_plus4),
    .rd_addr       (ex_mem_rd)
  );

  // ==========================================================================
  // MEM 段 (LSU + RV32A + DMEM/MMIO 译码)
  // ==========================================================================
  wire [31:0] amo_newdata;
`ifndef A_DIS
  wire [31:0] amo_new_comb;
`endif

  load_store_unit u_lsu (
    .clk             (clk),
    .rst             (rst),
    .req_read        (ex_mem_ctrl[`CTRL_MEM_READ]),
    .req_write       (ex_mem_ctrl[`CTRL_MEM_WRITE]),
    .req_size        (ex_mem_ctrl[`CTRL_MEM_SIZE]),
    .req_unsigned    (ex_mem_ctrl[`CTRL_MEM_UNSIGNED]),
    .req_addr        (ex_mem_alu_out),
    .req_wdata       (ex_mem_store_data),
    .dmem_addr       (dmem_addr),
    .dmem_wdata      (dmem_wdata),
    .dmem_wstrb      (dmem_wstrb),
    .dmem_we         (dmem_we),
    .dmem_rdata      (dmem_rdata_g),
    .load_data       (mem_load_data),
    .lsu_stall       (lsu_stall),
    .amo_en          (ex_mem_ctrl[`CTRL_AMO_EN]),
    .amo_newdata     (amo_newdata),
    .amo_lr          (amo_is_lr),
    .amo_sc          (amo_is_sc),
    .res_clear       (trap_enter || mret_taken),
    .amo_write_phase (amo_write_phase),
    .amo_old_out     (amo_old),
    .amo_sc_ok       (amo_sc_ok)
  );

`ifndef A_DIS
  reg [31:0] amo_rs2;
  reg [31:0] ex_rs2_d;
  reg        amo_en_d;
  reg [4:0]  amo_op_r;

  always @(posedge clk or posedge rst) begin
    if (rst) ex_rs2_d <= 32'd0;
    else     ex_rs2_d <= ex_rs2;
  end

  always @(posedge clk or posedge rst) begin
    if (rst) amo_en_d <= 1'b0;
    else     amo_en_d <= id_ex_ctrl[`CTRL_AMO_EN];
  end

  always @(posedge clk or posedge rst) begin
    if (rst)           amo_rs2 <= 32'd0;
    else if (amo_en_d) amo_rs2 <= ex_rs2_d;
  end

  always @(posedge clk or posedge rst) begin
    if (rst)                          amo_op_r <= 5'd0;
    else if (id_ex_ctrl[`CTRL_AMO_EN]) amo_op_r <= id_ex_ctrl[`CTRL_AMO_OP];
  end

  assign amo_is_lr = (amo_op_r == `AMO_LR);
  assign amo_is_sc = (amo_op_r == `AMO_SC);

  wire [4:0] amo_alu_op =
        (amo_op_r == `AMO_SWAP) ? `ALU_AMO_SWAP :
        (amo_op_r == `AMO_ADD)  ? `ALU_AMO_ADD  :
        (amo_op_r == `AMO_XOR)  ? `ALU_AMO_XOR  :
        (amo_op_r == `AMO_AND)  ? `ALU_AMO_AND  :
        (amo_op_r == `AMO_OR)   ? `ALU_AMO_OR   :
        (amo_op_r == `AMO_MIN)  ? `ALU_AMO_MIN  :
        (amo_op_r == `AMO_MAX)  ? `ALU_AMO_MAX  :
        (amo_op_r == `AMO_MINU) ? `ALU_AMO_MINU :
        (amo_op_r == `AMO_MAXU) ? `ALU_AMO_MAXU :
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

  assign sel_dmem  = (dmem_addr >= `DMEM_BASE) && (dmem_addr < (`DMEM_BASE + `DMEM_BYTES));
  assign dmem_we_g = dmem_we && sel_dmem;

  always @(posedge clk) begin
    ext_rdata_r <= ext_rdata;
    sel_dmem_r  <= sel_dmem;
  end
  assign dmem_rdata_g = sel_dmem_r ? dmem_rdata : ext_rdata_r;

  assign ext_we    = dmem_we && !sel_dmem && (dmem_wstrb != 4'b0000);
  assign ext_re    = ex_mem_ctrl[`CTRL_MEM_READ] && !sel_dmem;
  assign ext_addr  = dmem_addr;
  assign ext_wdata = dmem_wdata;
  assign ext_wstrb = dmem_wstrb;

  dmem #(.BASE(`DMEM_BASE), .BYTES(`DMEM_BYTES)) u_dmem (
    .clk   (clk),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .wstrb (dmem_wstrb),
    .we    (dmem_we_g),
    .rdata (dmem_rdata)
  );

  // ==========================================================================
  // MEM/WB 与 WB 段
  // ==========================================================================
  mem_wb_reg u_mem_wb (
    .clk          (clk),
    .rst          (rst),
    .stall        (hold_mem),
    .ctrl_in      (ex_mem_ctrl),
    .alu_out_in   (ex_mem_alu_out),
`ifdef LOAD_RESULT_REG
    .load_data_in (mem_load_data),
`else
    .load_data_in (32'h0),
`endif
    .pc_plus4_in  (ex_mem_pc_plus4),
    .rd_addr_in   (ex_mem_rd),
    .ctrl         (mem_wb_ctrl),
    .alu_out      (mem_wb_alu_out),
    .load_data    (mem_wb_load_data),
    .pc_plus4     (mem_wb_pc_plus4),
    .rd_addr      (mem_wb_rd)
  );

  always @(*) begin
    case (mem_wb_wb_src)
`ifdef LOAD_RESULT_REG
      `WB_MEM: wb_data = mem_wb_load_data;
`else
      `WB_MEM: wb_data = mem_load_data;
`endif
      `WB_PC4: wb_data = mem_wb_pc_plus4;
      default: wb_data = mem_wb_alu_out;
    endcase
  end

  assign wb_reg_write = mem_wb_ctrl[`CTRL_REG_WRITE] && (mem_wb_rd != 5'd0);
  assign wb_rd        = mem_wb_rd;

  // ==========================================================================
  // 调试观测与仿真自检断言 (纯 Verilog-2001)
  // ==========================================================================
  assign dbg_pc        = pc;
  assign dbg_id_pc     = if_pc;
  assign dbg_instr     = if_instr;
  assign dbg_mem_we    = dmem_we && (dmem_wstrb != 4'b0000);
  assign dbg_mem_addr  = dmem_addr;
  assign dbg_mem_wdata = dmem_wdata;
  assign dbg_stall     = pipe_stall;
  assign dbg_redirect  = redirect;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      dbg_illegal <= 1'b0;
    end
    else if (id_ex_ctrl[`CTRL_ILLEGAL] && !pipe_stall && !redir_flush && !trap_enter) begin
      dbg_illegal <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (!rst && pc_flush && (pc_flush_pc[1:0] != 2'b00)) begin
      $display("ERROR: instruction address misaligned: target=%h", pc_flush_pc);
      $finish;
    end
    if (!rst && id_ex_valid && (id_ex_pred_target[1:0] != 2'b00)) begin
      $display("ERROR: C-14 predicted target not word-aligned: %h", id_ex_pred_target);
      $finish;
    end
    if (!rst && trap_enter && !id_ex_valid) begin
      $display("ERROR: trap_enter on invalid EX instruction (R-01): pc=0x%08x cause=0x%02x",
               id_ex_pc, trap_cause);
      $finish;
    end
    if (!rst && redir_kill &&
        (csr_we || exc_req || irq_take || mret_req_int || btb_upd_en || br_redir_eff)) begin
      $display("ERROR: C-15 wrong-path X0 had side effect in EX (csr=%b exc=%b irq=%b mret=%b btb=%b redir=%b pc=0x%08x)",
               csr_we, exc_req, irq_take, mret_req_int, btb_upd_en, br_redir_eff, id_ex_pc);
      $finish;
    end
    if (!rst && br_redir_r2 && (ex_mem_ctrl != `CTRL_NOP)) begin
      $display("ERROR: C-15 wrong-path instruction reached MEM (ex_mem_ctrl != 0)");
      $finish;
    end
    if (!rst && (btb_align_err != 16'd0)) begin
      $display("ERROR: C-1 BTB/BHT alignment self-check failed (count=%0d)", btb_align_err);
      $finish;
    end
    if (!rst && md_start && md_busy_raw) begin
      $display("ERROR: C-12c muldiv not idle at operand-latch cycle");
      $finish;
    end
  end
`endif

endmodule
