`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// muldiv.v — RV32M 乘除法单元（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// Round 1 审计优化:
//   - 乘法: 合并原双 32×32 (8 DSP48E1) 为单组 33×33 有符号统一乘法器 (仅 4 DSP48E1，
//     DSP 占用减半，且移除 MULHSU 尾部 32 位修正加法器，保持精确 2 拍吞吐)；
//   - 除法: 默认基-2 (32 步恢复余数法); 定义 DIV_RADIX4 切换基-4 (16 步)。
// ============================================================================

module muldiv #(
  parameter XLEN = 32
)(
  input  wire            clk,
  input  wire            rst,

  input  wire [4:0]      op,
  input  wire [XLEN-1:0] a,
  input  wire [XLEN-1:0] b,

  output reg  [XLEN-1:0] result,
  output wire            busy
);

  // 统一 33×33 有符号乘法器覆盖 MUL / MULH / MULHSU / MULHU 四条指令 (4×DSP48E1)
  wire mul_a_signed = (op == `ALU_MULH) || (op == `ALU_MULHSU);
  wire mul_b_signed = (op == `ALU_MULH);
  wire signed [32:0] mul_a_ext = {mul_a_signed ? a[31] : 1'b0, a};
  wire signed [32:0] mul_b_ext = {mul_b_signed ? b[31] : 1'b0, b};

  reg signed [65:0] prod;

  always @(posedge clk) begin
    prod <= mul_a_ext * mul_b_ext;
  end

  wire is_mul_op    = (op == `ALU_MUL) || (op == `ALU_MULH) ||
                      (op == `ALU_MULHSU) || (op == `ALU_MULHU);
  wire is_div_op    = (op == `ALU_DIV) || (op == `ALU_DIVU) ||
                      (op == `ALU_REM) || (op == `ALU_REMU);
  wire is_signed_op = (op == `ALU_DIV) || (op == `ALU_REM);
  wire want_rem     = (op == `ALU_REM) || (op == `ALU_REMU);

  reg [5:0]  cnt;
  reg [31:0] dvnd, dvsr;
  reg [32:0] rem;
  reg [31:0] quo;
  reg        q_sign, r_sign;
  reg        busy_r;
  reg        done_r;
  reg [31:0] div_result;
`ifdef DIV_RADIX4
  reg [33:0] dvsr3;
`ifndef SYNTHESIS
  initial $display("[muldiv] DIV_RADIX4 ACTIVE: radix-4 divider, 16 iterations");
`endif
`endif

  wire [31:0] a_abs = (is_signed_op && a[31]) ? (~a + 32'd1) : a;
  wire [31:0] b_abs = (is_signed_op && b[31]) ? (~b + 32'd1) : b;
  wire        a_neg = is_signed_op && a[31];
  wire        b_neg = is_signed_op && b[31];

  wire div_zero = (b == 32'd0);
  wire div_ovf  = is_signed_op && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

`ifdef DIV_RADIX4
  // 基-4: 每拍处理 2 位, 35 位减法避免除数 > 2^31 时符号位回绕
  wire [33:0] rem_shift = {rem[31:0], dvnd[31:30]};
  wire [33:0] dvsr_x2   = {1'b0, dvsr, 1'b0};
  wire [34:0] rem_s1    = {1'b0, rem_shift} - {3'b0, dvsr};
  wire [34:0] rem_s2    = {1'b0, rem_shift} - {1'b0, dvsr_x2};
  wire [34:0] rem_s3    = {1'b0, rem_shift} - {1'b0, dvsr3};
  wire [1:0]  digit     = ~rem_s3[34] ? 2'd3 :
                          ~rem_s2[34] ? 2'd2 :
                          ~rem_s1[34] ? 2'd1 : 2'd0;
  wire [33:0] rem_n     = (digit == 2'd3) ? rem_s3[33:0] :
                          (digit == 2'd2) ? rem_s2[33:0] :
                          (digit == 2'd1) ? rem_s1[33:0] : rem_shift;
  wire [31:0] quo_n     = {quo[29:0], digit};
`else
  // 基-2: 32 步恢复余数法 (默认)
  wire [32:0] rem_shift = {rem[31:0], dvnd[31]};
  wire [32:0] rem_sub   = rem_shift - {1'b0, dvsr};
  wire        rem_ge    = (rem_shift >= {1'b0, dvsr});
  wire [32:0] rem_n     = rem_ge ? rem_sub : rem_shift;
  wire [31:0] quo_n     = {quo[30:0], rem_ge};
`endif

  wire [31:0] rem_final = r_sign ? (~rem_n[31:0] + 32'd1) : rem_n[31:0];
  wire [31:0] quo_final = q_sign ? (~quo_n + 32'd1) : quo_n;

  wire special = div_zero || div_ovf;
  assign busy  = busy_r
              || (is_mul_op && !done_r)
              || (is_div_op && !done_r && (special || !busy_r));

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      busy_r     <= 1'b0;
      done_r     <= 1'b0;
      cnt        <= 6'd0;
      dvnd       <= 32'd0;
      dvsr       <= 32'd0;
      rem        <= 33'd0;
      quo        <= 32'd0;
      q_sign     <= 1'b0;
      r_sign     <= 1'b0;
      div_result <= 32'd0;
`ifdef DIV_RADIX4
      dvsr3      <= 34'd0;
`endif
    end
    else begin
      done_r <= 1'b0;
      if (busy_r) begin
`ifdef DIV_RADIX4
        dvnd <= {dvnd[29:0], 2'b00};
        rem  <= rem_n[32:0];
`else
        dvnd <= {dvnd[30:0], 1'b0};
        rem  <= rem_n;
`endif
        quo  <= quo_n;
        cnt  <= cnt - 6'd1;
        if (cnt == 6'd1) begin
          div_result <= want_rem ? rem_final : quo_final;
          busy_r     <= 1'b0;
          done_r     <= 1'b1;
        end
      end
      else if (is_mul_op) begin
        if (!done_r) done_r <= 1'b1;
      end
      else if (is_div_op) begin
        if (div_zero) begin
          div_result <= want_rem ? a : 32'hFFFF_FFFF;
          done_r     <= 1'b1;
        end
        else if (div_ovf) begin
          div_result <= want_rem ? 32'd0 : 32'h8000_0000;
          done_r     <= 1'b1;
        end
        else if (!done_r) begin
          busy_r <= 1'b1;
`ifdef DIV_RADIX4
          cnt    <= 6'd16;
          dvsr3  <= {1'b0, b_abs, 1'b0} + {2'b0, b_abs};
`else
          cnt    <= 6'd32;
`endif
          dvnd   <= a_abs;
          dvsr   <= b_abs;
          rem    <= 33'd0;
          quo    <= 32'd0;
          q_sign <= a_neg ^ b_neg;
          r_sign <= a_neg;
        end
      end
    end
  end

  always @(*) begin
    if (!is_div_op) begin
      case (op)
        `ALU_MUL:    result = prod[31:0];
        `ALU_MULH,
        `ALU_MULHSU,
        `ALU_MULHU:  result = prod[63:32];
        default:     result = 32'd0;
      endcase
    end
    else begin
      result = div_result;
    end
  end

endmodule
