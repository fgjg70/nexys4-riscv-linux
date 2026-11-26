`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// bht.v — 8K 项单块 RAMB18E1 同步 Bimodal 方向预测表 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// Round 4 架构升级 (融合 RVComp 8K BRAM PHT 与本核零气泡流控):
//   - 容量由 512 项扩展 16 倍至 8,192 项 × 2-bit，恰好填满 1 块 RAMB18E1 (0.5 Tile)，
//     同时释放分布式 LUTRAM；
//   - 读口由 pc_next 提前一拍同步寻址，并在停顿期间由 pred_en (!pc_hold_sel) 锁定输出，
//     使 BRAM 1 拍读延迟与 pc <= pc_next 完全重合，且 2.45ns BRAM 输出完全藏在分布式 BTB
//     23-bit Tag 比较 (~3.5ns) 之下，零额外延迟、零主频损失；
//   - 由 id_ex_reg 随指令透传预测时的 2-bit pred_ctr 至 EX 段更新，杜绝 stall 污染。
// ============================================================================

module bht #(
  parameter IDX_BITS = 13
)(
  input  wire        clk,
  input  wire        rst,

  // 同步预读口 (pc_next 提前一拍寻址，pred_en = rst || !pc_hold_sel 保持与 pc 严格对齐)
  input  wire        pred_en,
  input  wire [31:0] pred_pc_next,
  output reg  [1:0]  pred_ctr,

  // EX 段更新 (仅条件分支更新，使用随指令流转的 upd_old_ctr)
  input  wire        upd_en,
  input  wire [31:0] upd_pc,
  input  wire        upd_taken,
  input  wire        upd_is_cond,
  input  wire [1:0]  upd_old_ctr
);

  localparam N = (1 << IDX_BITS);

  (* ram_style = "block" *) reg [1:0] mem [0:N-1];

  wire [IDX_BITS-1:0] rd_idx = pred_pc_next[IDX_BITS+1:2];
  wire [IDX_BITS-1:0] wr_idx = upd_pc[IDX_BITS+1:2];

  wire [1:0] ctr_new = upd_taken
                       ? ((upd_old_ctr == 2'b11) ? 2'b11 : (upd_old_ctr + 2'b01))
                       : ((upd_old_ctr == 2'b00) ? 2'b00 : (upd_old_ctr - 2'b01));

  integer i;
  initial begin
    pred_ctr = 2'b01;
    for (i = 0; i < N; i = i + 1) begin
      mem[i] = 2'b01;
    end
  end

  // 独立无异步复位块 -> 稳定推断为 1 块 RAMB18E1 简单双口 BRAM
  always @(posedge clk) begin
    if (!rst && upd_en && upd_is_cond) begin
      mem[wr_idx] <= ctr_new;
    end
    if (pred_en) begin
      pred_ctr <= mem[rd_idx];
    end
  end

endmodule
