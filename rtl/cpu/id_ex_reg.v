`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// id_ex_reg.v — ID/EX 流水寄存器（纯 Verilog-2001，优先级 flush > bubble > stall）
// Stage 1A: 新增 if_fault 传递取指访问/缺页异常至 EX 段统一仲裁。
// ============================================================================

module id_ex_reg (
  input  wire                clk,
  input  wire                rst,
  input  wire                flush,
  input  wire                stall,
  input  wire                bubble,
  input  wire                valid_in,
  input  wire                if_fault_in,
  input  wire [31:0]         instr_in,

  input  wire [`CTRL_W-1:0]  ctrl_in,
  input  wire [31:0]         pc_in,
  input  wire [31:0]         pc_plus4_in,
  input  wire [31:0]         rs1_data_in,
  input  wire [31:0]         rs2_data_in,
  input  wire [31:0]         imm_in,
  input  wire [4:0]          rs1_addr_in,
  input  wire [4:0]          rs2_addr_in,
  input  wire [4:0]          rd_addr_in,
  input  wire                pred_taken_in,
  input  wire [31:0]         pred_target_in,

  output reg  [`CTRL_W-1:0]  ctrl,
  output reg                 valid,
  output reg                 if_fault,
  output reg  [31:0]         instr,
  output reg  [31:0]         pc,
  output reg  [31:0]         pc_plus4,
  output reg  [31:0]         rs1_data,
  output reg  [31:0]         rs2_data,
  output reg  [31:0]         imm,
  output reg  [4:0]          rs1_addr,
  output reg  [4:0]          rs2_addr,
  output reg  [4:0]          rd_addr,
  output reg                 pred_taken,
  output reg  [31:0]         pred_target
);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl        <= `CTRL_NOP;
      valid       <= 1'b0;
      if_fault    <= 1'b0;
      instr       <= 32'd0;
      pc          <= 32'd0;
      pc_plus4    <= 32'd0;
      rs1_data    <= 32'd0;
      rs2_data    <= 32'd0;
      imm         <= 32'd0;
      rs1_addr    <= 5'd0;
      rs2_addr    <= 5'd0;
      rd_addr     <= 5'd0;
      pred_taken  <= 1'b0;
      pred_target <= 32'd0;
    end
    else if (flush || bubble) begin
      ctrl        <= `CTRL_NOP;
      valid       <= 1'b0;
      if_fault    <= 1'b0;
      instr       <= 32'd0;
      pc          <= 32'd0;
      pc_plus4    <= 32'd0;
      rs1_data    <= 32'd0;
      rs2_data    <= 32'd0;
      imm         <= 32'd0;
      rs1_addr    <= 5'd0;
      rs2_addr    <= 5'd0;
      rd_addr     <= 5'd0;
      pred_taken  <= 1'b0;
      pred_target <= 32'd0;
    end
    else if (!stall) begin
      ctrl        <= ctrl_in;
      valid       <= valid_in;
      if_fault    <= if_fault_in;
      instr       <= instr_in;
      pc          <= pc_in;
      pc_plus4    <= pc_plus4_in;
      rs1_data    <= rs1_data_in;
      rs2_data    <= rs2_data_in;
      imm         <= imm_in;
      rs1_addr    <= rs1_addr_in;
      rs2_addr    <= rs2_addr_in;
      rd_addr     <= rd_addr_in;
      pred_taken  <= pred_taken_in;
      pred_target <= pred_target_in;
    end
  end

endmodule
