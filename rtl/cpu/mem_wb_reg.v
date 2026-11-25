`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// mem_wb_reg.v — MEM/WB 流水寄存器（纯 Verilog-2001）
// Stage 1A: 携带 valid / pc / flush，支持 WB 段精确访存异常与精确 minstret。
// ============================================================================

module mem_wb_reg (
  input  wire               clk,
  input  wire               rst,
  input  wire               stall,
  input  wire               flush,

  input  wire               valid_in,
  input  wire [31:0]        pc_in,
  input  wire [`CTRL_W-1:0] ctrl_in,
  input  wire [31:0]        alu_out_in,
  input  wire [31:0]        load_data_in,
  input  wire [31:0]        pc_plus4_in,
  input  wire [4:0]         rd_addr_in,

  output reg                valid,
  output reg  [31:0]        pc,
  output reg  [`CTRL_W-1:0] ctrl,
  output reg  [31:0]        alu_out,
  output reg  [31:0]        load_data,
  output reg  [31:0]        pc_plus4,
  output reg  [4:0]         rd_addr
);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      valid     <= 1'b0;
      pc        <= 32'd0;
      ctrl      <= `CTRL_NOP;
      alu_out   <= 32'd0;
      load_data <= 32'd0;
      pc_plus4  <= 32'd0;
      rd_addr   <= 5'd0;
    end
    else if (flush) begin
      valid     <= 1'b0;
      pc        <= 32'd0;
      ctrl      <= `CTRL_NOP;
      alu_out   <= 32'd0;
      load_data <= 32'd0;
      pc_plus4  <= 32'd0;
      rd_addr   <= 5'd0;
    end
    else if (!stall) begin
      valid     <= valid_in;
      pc        <= pc_in;
      ctrl      <= ctrl_in;
      alu_out   <= alu_out_in;
      load_data <= load_data_in;
      pc_plus4  <= pc_plus4_in;
      rd_addr   <= rd_addr_in;
    end
  end

endmodule
