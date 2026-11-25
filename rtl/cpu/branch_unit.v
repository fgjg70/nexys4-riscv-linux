`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// branch_unit.v — 条件分支判定单元（纯 Verilog-2001）
// ============================================================================

module branch_unit #(
  parameter XLEN = 32
)(
  input  wire [XLEN-1:0] rs1,
  input  wire [XLEN-1:0] rs2,
  input  wire [2:0]      branch_type,

  output reg             taken
);

  // 复用单组 32-bit 无符号比较器 + 符号位修正，减少 CARRY4 进位链与 ex_rs1/ex_rs2 负载
  wire eq  = (rs1 == rs2);
  wire ltu = (rs1 < rs2);
  wire lt  = (rs1[XLEN-1] ^ rs2[XLEN-1]) ? rs1[XLEN-1] : ltu;

  always @(*) begin
    case (branch_type)
      `BR_EQ:  taken = eq;
      `BR_NE:  taken = ~eq;
      `BR_LT:  taken = lt;
      `BR_GE:  taken = ~lt;
      `BR_LTU: taken = ltu;
      `BR_GEU: taken = ~ltu;
      default: taken = 1'b0;
    endcase
  end

endmodule
