`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// alu.v — RV32IA 算术逻辑单元（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// - 支持 RV32I 基础算术/逻辑/移位/比较，以及 RV32A 原子指令新值运算；
// - 分支比较独立位于 branch_unit，不串联在 ALU 后面；
// - RV32M 编码输出 0（由 muldiv 负责），非法编码输出 x 便于仿真暴露集成错误。
// ============================================================================

module alu #(
  parameter XLEN = 32
)(
  input  wire [XLEN-1:0] a,
  input  wire [XLEN-1:0] b,
  input  wire [4:0]      op,

  output reg  [XLEN-1:0] out
);

  localparam SHAMT_W = $clog2(XLEN);

  wire [XLEN-1:0] sum      = a + b;
  wire [XLEN-1:0] diff     = a - b;
  wire [XLEN-1:0] and_out  = a & b;
  wire [XLEN-1:0] or_out   = a | b;
  wire [XLEN-1:0] xor_out  = a ^ b;
  wire [XLEN-1:0] sll_out  = a << b[SHAMT_W-1:0];
  wire [XLEN-1:0] srl_out  = a >> b[SHAMT_W-1:0];
  wire [XLEN-1:0] sra_out  = $signed(a) >>> b[SHAMT_W-1:0];
  // 复用单组 32-bit 无符号比较器 + 符号位异或修正，省去重复 CARRY4 并降低操作数扇出
  wire            sltu     = (a < b);
  wire            slt      = (a[XLEN-1] ^ b[XLEN-1]) ? a[XLEN-1] : sltu;

  // RV32A 原子新值：a = 内存旧值，b = rs2
  wire [XLEN-1:0] amo_swap = b;
  wire [XLEN-1:0] amo_add  = sum;
  wire [XLEN-1:0] amo_xor  = xor_out;
  wire [XLEN-1:0] amo_and  = and_out;
  wire [XLEN-1:0] amo_or   = or_out;
  wire [XLEN-1:0] amo_min  = slt  ? a : b;
  wire [XLEN-1:0] amo_max  = slt  ? b : a;
  wire [XLEN-1:0] amo_minu = sltu ? a : b;
  wire [XLEN-1:0] amo_maxu = sltu ? b : a;

  always @(*) begin
    case (op)
      `ALU_ADD:      out = sum;
      `ALU_SUB:      out = diff;
      `ALU_AND:      out = and_out;
      `ALU_OR:       out = or_out;
      `ALU_XOR:      out = xor_out;
      `ALU_SLL:      out = sll_out;
      `ALU_SRL:      out = srl_out;
      `ALU_SRA:      out = sra_out;
      `ALU_SLT:      out = {{(XLEN-1){1'b0}}, slt};
      `ALU_SLTU:     out = {{(XLEN-1){1'b0}}, sltu};
      `ALU_MUL, `ALU_MULH, `ALU_MULHSU, `ALU_MULHU,
      `ALU_DIV, `ALU_DIVU, `ALU_REM,    `ALU_REMU: out = {XLEN{1'b0}};
      `ALU_AMO_SWAP: out = amo_swap;
      `ALU_AMO_ADD:  out = amo_add;
      `ALU_AMO_XOR:  out = amo_xor;
      `ALU_AMO_AND:  out = amo_and;
      `ALU_AMO_OR:   out = amo_or;
      `ALU_AMO_MIN:  out = amo_min;
      `ALU_AMO_MAX:  out = amo_max;
      `ALU_AMO_MINU: out = amo_minu;
      `ALU_AMO_MAXU: out = amo_maxu;
      default:       out = {XLEN{1'bx}};
    endcase
  end

endmodule
