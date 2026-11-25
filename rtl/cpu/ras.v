`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// ras.v — 循环返回地址栈 (Circular Return Address Stack, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// Round 1 审计升级:
//   1) 默认深度扩至 16 项并改为循环栈指针 (深层 Linux 调用栈覆盖最旧帧而不停止预测)；
//   2) 修复同拍 push_en && pop_en (RISC-V Table 2.1 协程切换 jalr rd=x1, rs1=x5)
//      原实现误减 sp 的缺陷：现精确原地覆写栈顶并保持指针与计数不变。
// ============================================================================

module ras #(
  parameter DEPTH = 16
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

  localparam PTR_W = $clog2(DEPTH);
  localparam CNT_W = $clog2(DEPTH + 1);
  localparam [CNT_W-1:0] MAX_CNT = DEPTH;

  reg [31:0]      stk [0:DEPTH-1];
  reg [PTR_W-1:0] tos;          // 指向下一次 push 槽位，栈顶位于 tos - 1
  reg [CNT_W-1:0] cnt;          // 有效深度 (0..DEPTH)
  integer i;

  wire [PTR_W-1:0] top_idx = tos - {{(PTR_W-1){1'b0}}, 1'b1};
  assign empty = (cnt == {CNT_W{1'b0}});
  assign top   = stk[top_idx];

  initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
      stk[i] = 32'd0;
    end
    tos = {PTR_W{1'b0}};
    cnt = {CNT_W{1'b0}};
  end

  always @(posedge clk) begin
    if (rst || flush_all) begin
      tos <= {PTR_W{1'b0}};
      cnt <= {CNT_W{1'b0}};
    end
    else begin
      case ({push_en, pop_en})
        2'b11: begin
          // RISC-V Spec Table 2.1: 同时 pop 与 push -> 原地替换栈顶，深度不变
          if (!empty) begin
            stk[top_idx] <= push_pc;
          end
          else begin
            stk[tos] <= push_pc;
            tos      <= tos + {{(PTR_W-1){1'b0}}, 1'b1};
            cnt      <= {{(CNT_W-1){1'b0}}, 1'b1};
          end
        end
        2'b10: begin
          // 循环压栈: 满时覆写最旧槽位，保持最近 DEPTH 层返回地址永远精确
          stk[tos] <= push_pc;
          tos      <= tos + {{(PTR_W-1){1'b0}}, 1'b1};
          if (cnt != MAX_CNT) cnt <= cnt + {{(CNT_W-1){1'b0}}, 1'b1};
        end
        2'b01: begin
          if (!empty) begin
            tos <= top_idx;
            cnt <= cnt - {{(CNT_W-1){1'b0}}, 1'b1};
          end
        end
        default: ;
      endcase
    end
  end

endmodule
