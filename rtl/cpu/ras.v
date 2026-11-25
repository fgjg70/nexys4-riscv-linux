`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// ras.v — 返回地址栈 (Return Address Stack, 纯 Verilog-2001)
// ============================================================================

module ras #(
  parameter DEPTH = 8
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        flush_all,

  input  wire        push_en,
  input  wire [31:0] push_pc,
  input  wire        pop_en,

  output wire [31:0] top,
  output wire        empty
);

  localparam PW = $clog2(DEPTH + 1);
  localparam [PW-1:0] FULL_SP = DEPTH;

  reg [31:0]   stk [0:DEPTH-1];
  reg [PW-1:0] sp;
  integer i;

  assign empty = (sp == {PW{1'b0}});
  assign top   = stk[sp - {{(PW-1){1'b0}}, 1'b1}];

  initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
      stk[i] = 32'd0;
    end
    sp = {PW{1'b0}};
  end

  always @(posedge clk) begin
    if (rst || flush_all) begin
      sp <= {PW{1'b0}};
    end
    else begin
      if (pop_en && (sp != {PW{1'b0}})) begin
        sp <= sp - {{(PW-1){1'b0}}, 1'b1};
        if (push_en) begin
          stk[sp - {{(PW-1){1'b0}}, 1'b1}] <= push_pc;
        end
      end
      else if (push_en && (sp != FULL_SP)) begin
        stk[sp] <= push_pc;
        sp      <= sp + {{(PW-1){1'b0}}, 1'b1};
      end
    end
  end

endmodule
