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
  input  wire       mem_fast_load,
  input  wire [4:0] ex_mem_rd,

  input  wire [4:0] if_id_rs1,
  input  wire [4:0] if_id_rs2,
  input  wire       id_valid,

  input  wire       lsu_stall,
  input  wire       ex_busy,
  input  wire       id_sys_stall,
  input  wire       id_sys_stall_raw,
  input  wire       redirect_raw,

  output reg  [1:0] fwd_a_pre,
  output reg  [1:0] fwd_b_pre,
  output wire       pipe_stall,
  output wire       stall_pc_fast,
  output wire       id_ex_bubble,
  output wire       hold_mem,
  output wire       redirect
);

  // load-use:
  //   - 默认 BRAM L1D 路径: 2 拍气泡 (load_use_ex + load_use_mem);
  //   - Round 3 L0D 0 拍快路径命中 (mem_fast_load=1): MEM 拍即完成字节提取并锁存进
  //     mem_wb_load_data FF，WB 拍直通前递给 EX -> 距离 1 仅 1 拍气泡，距离 2 零气泡!
  wire load_use_ex_raw  = id_ex_mem_read && (id_ex_rd != 5'd0) &&
                          ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
  wire load_use_mem_cmp = ex_mem_mem_read && ex_mem_reg_write &&
                          (ex_mem_rd != 5'd0) &&
                          ((ex_mem_rd == if_id_rs1) || (ex_mem_rd == if_id_rs2));
  wire load_use_ex      = id_valid && load_use_ex_raw;
  wire load_use_mem_hit = id_valid && load_use_mem_cmp;
  wire load_use         = load_use_ex || (load_use_mem_hit && !mem_fast_load);

  // id_sys_stall: 在 ID 段暂停 SYSTEM/异常指令直到在途访存离开 EX/MEM，
  // 复用气泡注入路径，既保证 WB 访存异常精确性又避免任何前递陈旧问题。
  wire id_stall = load_use || id_sys_stall;

  // 时序恒等化简: pc_hold_sel 外部已含 !id_en (!boot_done || !ibus_valid)，
  // 由布尔恒等式 !id_en || (id_en && X) == !id_en || X，stall_pc_fast 彻底绕过
  // ibus_valid -> id_en -> id_valid -> load_use_ex 4 级串行 LUT (~2.5 ns 净收益!)
  assign stall_pc_fast = load_use_ex_raw || (load_use_mem_cmp && !mem_fast_load) ||
                         id_sys_stall_raw || lsu_stall || ex_busy;
  assign pipe_stall    = load_use || id_sys_stall || lsu_stall || ex_busy;
  assign id_ex_bubble  = id_stall && !(lsu_stall || ex_busy);
  assign hold_mem     = lsu_stall || ex_busy;
  assign redirect     = redirect_raw && !(lsu_stall || ex_busy || load_use_ex);

  // ID 段前递预选 (C-10): 随 ID/EX 打一拍进入 EX 驱动前递 mux
  reg pre_ex_a, pre_wb_a, pre_ex_b, pre_wb_b;
  always @(*) begin
    pre_ex_a = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs1);
    pre_wb_a = ex_mem_reg_write && (!ex_mem_mem_read || mem_fast_load) &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs1);
    pre_ex_b = id_ex_reg_write && !id_ex_mem_read &&
               (id_ex_rd != 5'd0) && (id_ex_rd == if_id_rs2);
    pre_wb_b = ex_mem_reg_write && (!ex_mem_mem_read || mem_fast_load) &&
               (ex_mem_rd != 5'd0) && (ex_mem_rd == if_id_rs2);

    fwd_a_pre = pre_ex_a ? `FWD_EX_MEM : (pre_wb_a ? `FWD_MEM_WB : `FWD_REG);
    fwd_b_pre = pre_ex_b ? `FWD_EX_MEM : (pre_wb_b ? `FWD_MEM_WB : `FWD_REG);
  end

endmodule
