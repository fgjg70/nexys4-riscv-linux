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

  wire eq  = (rs1 == rs2);
  wire lt  = ($signed(rs1) < $signed(rs2));
  wire ltu = (rs1 < rs2);

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
