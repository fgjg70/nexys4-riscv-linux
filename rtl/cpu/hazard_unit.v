`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// hazard_unit.v — 冒险处理单元 (ID 段前递预选 + 2 拍 load-use + 重定向门控)
// 纯 Verilog-2001
// ============================================================================

module hazard_unit (
  input  wire       id_ex_mem_read,
  input  wire       id_ex_reg_write,
  input  wire [4:0] id_ex_rd,

  input  wire       ex_mem_reg_write,
  input  wire       ex_mem_mem_read,
  input  wire [4:0] ex_mem_rd,

  input  wire [4:0] if_id_rs1,
  input  wire [4:0] if_id_rs2,

  input  wire       lsu_stall,
  input  wire       ex_busy,
  input  wire       redirect_raw,

  output reg  [1:0] fwd_a_pre,
  output reg  [1:0] fwd_b_pre,
  output wire       pipe_stall,
  output wire       id_ex_bubble,
  output wire       hold_mem,
  output wire       redirect
);

  // load-use: 2 拍气泡 (C-2: load 数据不走前递, 靠 regfile 写优先旁路补最后一棒)
  reg load_use_ex, load_use_mem, load_use;
  always @(*) begin
    load_use_ex  = id_ex_mem_read && (id_ex_rd != 5'd0) &&
                   ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
    load_use_mem = ex_mem_mem_read && ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                   ((ex_mem_rd == if_id_rs1) || (ex_mem_rd == if_id_rs2));
    load_use     = load_use_ex || load_use_mem;
  end

  assign pipe_stall   = load_use || lsu_stall || ex_busy;
  assign id_ex_bubble = load_use && !(lsu_stall || ex_busy);
  assign hold_mem     = lsu_stall || ex_busy;
  assign redirect     = redirect_raw && !(lsu_stall || ex_busy || load_use_ex);

  // ID 段前递预选 (C-10): 随 ID/EX 打一拍进入 EX 驱动前递 mux
  reg pre_ex_a, pre_wb_a, pre_ex_b, pre_wb_b;
  always @(*) begin
    pre_ex_a = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs1);
    pre_wb_a = ex_mem_reg_write && !ex_mem_mem_read &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs1);
    pre_ex_b = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs2);
    pre_wb_b = ex_mem_reg_write && !ex_mem_mem_read &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs2);

    fwd_a_pre = pre_ex_a ? `FWD_EX_MEM : (pre_wb_a ? `FWD_MEM_WB : `FWD_REG);
    fwd_b_pre = pre_ex_b ? `FWD_EX_MEM : (pre_wb_b ? `FWD_MEM_WB : `FWD_REG);
  end

endmodule
