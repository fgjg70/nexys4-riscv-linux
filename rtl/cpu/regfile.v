`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// regfile.v — 整数寄存器堆 (2 读 1 写, 写优先旁路, x0 恒零, 纯 Verilog-2001)
// ============================================================================

module regfile #(
  parameter XLEN     = 32,
  parameter NUM_REGS = 32
)(
  input  wire                        clk,

  input  wire                        we,
  input  wire [$clog2(NUM_REGS)-1:0] waddr,
  input  wire [XLEN-1:0]             wdata,

  input  wire [$clog2(NUM_REGS)-1:0] raddr1,
  input  wire [$clog2(NUM_REGS)-1:0] raddr2,
  output wire [XLEN-1:0]             rdata1,
  output wire [XLEN-1:0]             rdata2,

  input  wire [$clog2(NUM_REGS)-1:0] dbg_raddr,
  output wire [XLEN-1:0]             dbg_rdata
);

  localparam AW = $clog2(NUM_REGS);

  reg [XLEN-1:0] mem [0:NUM_REGS-1];
  integer i;

  initial begin
    for (i = 0; i < NUM_REGS; i = i + 1) begin
      mem[i] = {XLEN{1'b0}};
    end
  end

  always @(posedge clk) begin
    if (we && (waddr != {AW{1'b0}})) begin
      mem[waddr] <= wdata;
    end
  end

  // 组合读 + 同拍写优先旁路 (覆盖距离 3 RAW)
  assign rdata1    = (raddr1 == {AW{1'b0}}) ? {XLEN{1'b0}} :
                     ((we && (waddr == raddr1)) ? wdata : mem[raddr1]);
  assign rdata2    = (raddr2 == {AW{1'b0}}) ? {XLEN{1'b0}} :
                     ((we && (waddr == raddr2)) ? wdata : mem[raddr2]);
  assign dbg_rdata = mem[dbg_raddr];

endmodule
