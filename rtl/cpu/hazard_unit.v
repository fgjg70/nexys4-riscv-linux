`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// hazard_unit.v — 冒险处理单元 (ID 段前递预选 + 2 拍 load-use + SYSTEM 精确串行化)
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
  input  wire       id_valid,

  input  wire       lsu_stall,
  input  wire       ex_busy,
  input  wire       id_sys_stall,
  input  wire       redirect_raw,

  output reg  [1:0] fwd_a_pre,
  output reg  [1:0] fwd_b_pre,
  output wire       pipe_stall,
  output wire       id_ex_bubble,
  output wire       hold_mem,
  output wire       redirect
);

  // load-use: 2 拍气泡 (C-2: load 数据不走前递, 靠 regfile 写优先旁路补最后一棒)
  // Round 2 时序优化: 5-bit 寄存器编号比对直接并行取自 if_instr，id_valid 仅在末级门控 load_use，
  // 彻底剪断 icache.q_hit -> id_rs_haz -> 5-bit 比较器 -> fetch_hold 串行关键路径。
  wire load_use_ex_raw  = id_ex_mem_read && (id_ex_rd != 5'd0) &&
                          ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
  wire load_use_mem_raw = ex_mem_mem_read && ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                          ((ex_mem_rd == if_id_rs1) || (ex_mem_rd == if_id_rs2));
  wire load_use_ex      = id_valid && load_use_ex_raw;
  wire load_use         = id_valid && (load_use_ex_raw || load_use_mem_raw);

  // id_sys_stall: 在 ID 段暂停 SYSTEM/异常指令直到在途访存离开 EX/MEM，
  // 复用气泡注入路径，既保证 WB 访存异常精确性又避免任何前递陈旧问题。
  wire id_stall = load_use || id_sys_stall;

  assign pipe_stall   = id_stall || lsu_stall || ex_busy;
  assign id_ex_bubble = id_stall && !(lsu_stall || ex_busy);
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
