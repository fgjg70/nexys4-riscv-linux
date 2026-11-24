`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// ex_mem_reg.v — EX/MEM 流水寄存器（纯 Verilog-2001，flush 仅冲陷阱与错路 X0）
// ============================================================================

module ex_mem_reg (
  input  wire               clk,
  input  wire               rst,
  input  wire               stall,
  input  wire               flush,

  input  wire [`CTRL_W-1:0] ctrl_in,
  input  wire [31:0]        alu_out_in,
  input  wire [31:0]        store_data_in,
  input  wire [31:0]        pc_plus4_in,
  input  wire [4:0]         rd_addr_in,

  output reg  [`CTRL_W-1:0] ctrl,
  output reg  [31:0]        alu_out,
  output reg  [31:0]        store_data,
  output reg  [31:0]        pc_plus4,
  output reg  [4:0]         rd_addr
);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ctrl       <= `CTRL_NOP;
      alu_out    <= 32'd0;
      store_data <= 32'd0;
      pc_plus4   <= 32'd0;
      rd_addr    <= 5'd0;
    end
    else if (flush) begin
      ctrl       <= `CTRL_NOP;
      alu_out    <= 32'd0;
      store_data <= 32'd0;
      pc_plus4   <= 32'd0;
      rd_addr    <= 5'd0;
    end
    else if (!stall) begin
      ctrl       <= ctrl_in;
      alu_out    <= alu_out_in;
      store_data <= store_data_in;
      pc_plus4   <= pc_plus4_in;
      rd_addr    <= rd_addr_in;
    end
  end

endmodule
