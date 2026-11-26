`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// pc.v — 程序计数器（纯 Verilog-2001，优先级 flush > stall > pc_src）
// ============================================================================

module pc #(
  parameter              XLEN     = 32,
  parameter [XLEN-1:0]   RESET_PC = 32'h0000_0000
)(
  input  wire            clk,
  input  wire            rst,

  input  wire            stall,
  input  wire            flush,
  input  wire [XLEN-1:0] flush_pc,

  input  wire            pc_src,
  input  wire [XLEN-1:0] pc_target,

  (* max_fanout = 24 *) output reg  [XLEN-1:0] pc,
  output wire [XLEN-1:0] pc_plus4
);

  assign pc_plus4 = pc + {{(XLEN-3){1'b0}}, 3'd4};

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      pc <= RESET_PC;
    end
    else if (flush) begin
      pc <= flush_pc;
    end
    else if (!stall) begin
      pc <= pc_src ? pc_target : pc_plus4;
    end
  end

endmodule
