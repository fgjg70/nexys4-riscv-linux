`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// imm_gen.v — 立即数生成器 (I/S/B/U/J 五种格式, 纯 Verilog-2001)
// ============================================================================

module imm_gen #(
  parameter XLEN = 32
)(
  input  wire [XLEN-1:0] instr,
  input  wire [2:0]      fmt,

  output reg  [XLEN-1:0] imm_out
);

  wire [XLEN-1:0] imm_i = {{(XLEN-12){instr[31]}}, instr[31:20]};
  wire [XLEN-1:0] imm_s = {{(XLEN-12){instr[31]}}, instr[31:25], instr[11:7]};
  wire [XLEN-1:0] imm_b = {{(XLEN-13){instr[31]}}, instr[31], instr[7],
                           instr[30:25], instr[11:8], 1'b0};
  wire [XLEN-1:0] imm_u = {instr[31:12], {(XLEN-20){1'b0}}};
  wire [XLEN-1:0] imm_j = {{(XLEN-21){instr[31]}}, instr[31], instr[19:12],
                           instr[20], instr[30:21], 1'b0};

  always @(*) begin
    case (fmt)
      `IMM_I:  imm_out = imm_i;
      `IMM_S:  imm_out = imm_s;
      `IMM_B:  imm_out = imm_b;
      `IMM_U:  imm_out = imm_u;
      `IMM_J:  imm_out = imm_j;
      default: imm_out = {XLEN{1'bx}};
    endcase
  end

endmodule
