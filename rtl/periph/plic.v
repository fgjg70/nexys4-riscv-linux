`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// plic.v — 标准双上下文 RISC-V PLIC (Context 0 = M-mode, Context 1 = S-mode)
// 纯 Verilog-2001，兼容 OpenSBI + Linux irq-sifive-plic
// ----------------------------------------------------------------------------
// 支持 7 路外部中断源 (ID 1..7, ID 0 保留为无中断):
//   Source 1: NS16550A UART
//   Source 2: SPI / microSD
//   Source 3: VGA VSYNC
//   Source 4: OV5640 摄像头帧中断
//   Source 5..7: 预留外部中断
// 寄存器映射 (基址 0x0C00_0000):
//   +0x000004 .. +0x00001C : Source 1..7 优先级 (3-bit, 0..7)
//   +0x001000              : Pending 位图 (只读, bit i = source i)
//   +0x002000              : Context 0 (M-mode) Enable 位图 (bit 1..7)
//   +0x002080              : Context 1 (S-mode) Enable 位图 (bit 1..7)
//   +0x200000              : Context 0 优先级阈值 (3-bit)
//   +0x200004              : Context 0 Claim (读) / Complete (写)
//   +0x201000              : Context 1 优先级阈值 (3-bit)
//   +0x201004              : Context 1 Claim (读) / Complete (写)
// ============================================================================

module plic (
  input  wire        clk,
  input  wire        rst,

  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg         ack,
  output reg  [31:0] rdata,

  // 7 路高电平有效外部中断源 (bit 0 对应 Source 1 .. bit 6 对应 Source 7)
  input  wire [6:0]  irq_src,
  output reg         irq_ext,   // Context 0 -> M-mode MEIP
  output reg         irq_sext   // Context 1 -> S-mode SEIP
);

  reg [2:0] prio [1:7];
  reg [7:1] enable0;
  reg [7:1] enable1;
  reg [7:1] claimed;
  reg [2:0] threshold0;
  reg [2:0] threshold1;

  wire [7:1] pending = irq_src & ~claimed;

  // ---- Context 0 (M-mode) 3 级平衡二叉锦标赛树仲裁 ----
  wire [2:0] c0p1 = (pending[1] && enable0[1] && (prio[1] > threshold0)) ? prio[1] : 3'd0;
  wire [2:0] c0p2 = (pending[2] && enable0[2] && (prio[2] > threshold0)) ? prio[2] : 3'd0;
  wire [2:0] c0p3 = (pending[3] && enable0[3] && (prio[3] > threshold0)) ? prio[3] : 3'd0;
  wire [2:0] c0p4 = (pending[4] && enable0[4] && (prio[4] > threshold0)) ? prio[4] : 3'd0;
  wire [2:0] c0p5 = (pending[5] && enable0[5] && (prio[5] > threshold0)) ? prio[5] : 3'd0;
  wire [2:0] c0p6 = (pending[6] && enable0[6] && (prio[6] > threshold0)) ? prio[6] : 3'd0;
  wire [2:0] c0p7 = (pending[7] && enable0[7] && (prio[7] > threshold0)) ? prio[7] : 3'd0;

  wire       c0w12  = (c0p1 >= c0p2);
  wire [2:0] c0q12  = c0w12 ? c0p1 : c0p2;
  wire [2:0] c0id12 = c0w12 ? ((c0p1 != 3'd0) ? 3'd1 : 3'd0) : 3'd2;

  wire       c0w34  = (c0p3 >= c0p4);
  wire [2:0] c0q34  = c0w34 ? c0p3 : c0p4;
  wire [2:0] c0id34 = c0w34 ? ((c0p3 != 3'd0) ? 3'd3 : 3'd0) : 3'd4;

  wire       c0w56  = (c0p5 >= c0p6);
  wire [2:0] c0q56  = c0w56 ? c0p5 : c0p6;
  wire [2:0] c0id56 = c0w56 ? ((c0p5 != 3'd0) ? 3'd5 : 3'd0) : 3'd6;

  wire [2:0] c0id7  = (c0p7 != 3'd0) ? 3'd7 : 3'd0;

  wire       c0w14  = (c0q12 >= c0q34);
  wire [2:0] c0q14  = c0w14 ? c0q12 : c0q34;
  wire [2:0] c0id14 = c0w14 ? c0id12 : c0id34;

  wire       c0w57  = (c0q56 >= c0p7);
  wire [2:0] c0q57  = c0w57 ? c0q56 : c0p7;
  wire [2:0] c0id57 = c0w57 ? c0id56 : c0id7;

  wire [2:0] best_id0 = (c0q14 >= c0q57) ? c0id14 : c0id57;

  // ---- Context 1 (S-mode) 3 级平衡二叉锦标赛树仲裁 ----
  wire [2:0] c1p1 = (pending[1] && enable1[1] && (prio[1] > threshold1)) ? prio[1] : 3'd0;
  wire [2:0] c1p2 = (pending[2] && enable1[2] && (prio[2] > threshold1)) ? prio[2] : 3'd0;
  wire [2:0] c1p3 = (pending[3] && enable1[3] && (prio[3] > threshold1)) ? prio[3] : 3'd0;
  wire [2:0] c1p4 = (pending[4] && enable1[4] && (prio[4] > threshold1)) ? prio[4] : 3'd0;
  wire [2:0] c1p5 = (pending[5] && enable1[5] && (prio[5] > threshold1)) ? prio[5] : 3'd0;
  wire [2:0] c1p6 = (pending[6] && enable1[6] && (prio[6] > threshold1)) ? prio[6] : 3'd0;
  wire [2:0] c1p7 = (pending[7] && enable1[7] && (prio[7] > threshold1)) ? prio[7] : 3'd0;

  wire       c1w12  = (c1p1 >= c1p2);
  wire [2:0] c1q12  = c1w12 ? c1p1 : c1p2;
  wire [2:0] c1id12 = c1w12 ? ((c1p1 != 3'd0) ? 3'd1 : 3'd0) : 3'd2;

  wire       c1w34  = (c1p3 >= c1p4);
  wire [2:0] c1q34  = c1w34 ? c1p3 : c1p4;
  wire [2:0] c1id34 = c1w34 ? ((c1p3 != 3'd0) ? 3'd3 : 3'd0) : 3'd4;

  wire       c1w56  = (c1p5 >= c1p6);
  wire [2:0] c1q56  = c1w56 ? c1p5 : c1p6;
  wire [2:0] c1id56 = c1w56 ? ((c1p5 != 3'd0) ? 3'd5 : 3'd0) : 3'd6;

  wire [2:0] c1id7  = (c1p7 != 3'd0) ? 3'd7 : 3'd0;

  wire       c1w14  = (c1q12 >= c1q34);
  wire [2:0] c1q14  = c1w14 ? c1q12 : c1q34;
  wire [2:0] c1id14 = c1w14 ? c1id12 : c1id34;

  wire       c1w57  = (c1q56 >= c1p7);
  wire [2:0] c1q57  = c1w57 ? c1q56 : c1p7;
  wire [2:0] c1id57 = c1w57 ? c1id56 : c1id7;

  wire [2:0] best_id1 = (c1q14 >= c1q57) ? c1id14 : c1id57;

  wire [21:0] off    = addr[21:0];
  wire        do_req = req && !ack;

  integer i;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack        <= 1'b0;
      rdata      <= 32'd0;
      irq_ext    <= 1'b0;
      irq_sext   <= 1'b0;
      enable0    <= 7'd0;
      enable1    <= 7'd0;
      claimed    <= 7'd0;
      threshold0 <= 3'd0;
      threshold1 <= 3'd0;
      for (i = 1; i <= 7; i = i + 1) prio[i] <= 3'd0;
    end
    else begin
      ack      <= do_req;
      // 寄存两路中断输出，切断外设 -> PLIC 优先级树 -> CPU 陷阱向量的组合关键路径
      irq_ext  <= (best_id0 != 3'd0);
      irq_sext <= (best_id1 != 3'd0);
      if (do_req) begin
        if (we) begin
          rdata <= 32'd0;
          if ((off >= 22'h000004) && (off <= 22'h00001C) && (off[1:0] == 2'b00)) begin
            prio[off[4:2]] <= wdata[2:0];
          end
          else if (off == 22'h002000) begin
            enable0 <= wdata[7:1];
          end
          else if (off == 22'h002080) begin
            enable1 <= wdata[7:1];
          end
          else if (off == 22'h200000) begin
            threshold0 <= wdata[2:0];
          end
          else if (off == 22'h201000) begin
            threshold1 <= wdata[2:0];
          end
          else if (off == 22'h200004) begin
            // Context 0 Complete
            if ((wdata[2:0] >= 3'd1) && (wdata[2:0] <= 3'd7) && (wdata[31:3] == 29'd0)) begin
              claimed[wdata[2:0]] <= 1'b0;
            end
          end
          else if (off == 22'h201004) begin
            // Context 1 Complete
            if ((wdata[2:0] >= 3'd1) && (wdata[2:0] <= 3'd7) && (wdata[31:3] == 29'd0)) begin
              claimed[wdata[2:0]] <= 1'b0;
            end
          end
        end
        else begin
          if ((off >= 22'h000004) && (off <= 22'h00001C) && (off[1:0] == 2'b00)) begin
            rdata <= {29'd0, prio[off[4:2]]};
          end
          else if (off == 22'h001000) begin
            rdata <= {24'd0, pending, 1'b0};
          end
          else if (off == 22'h002000) begin
            rdata <= {24'd0, enable0, 1'b0};
          end
          else if (off == 22'h002080) begin
            rdata <= {24'd0, enable1, 1'b0};
          end
          else if (off == 22'h200000) begin
            rdata <= {29'd0, threshold0};
          end
          else if (off == 22'h201000) begin
            rdata <= {29'd0, threshold1};
          end
          else if (off == 22'h200004) begin
            // Context 0 Claim
            rdata <= {29'd0, best_id0};
            if (best_id0 != 3'd0) begin
              claimed[best_id0] <= 1'b1;
            end
          end
          else if (off == 22'h201004) begin
            // Context 1 Claim
            rdata <= {29'd0, best_id1};
            if (best_id1 != 3'd0) begin
              claimed[best_id1] <= 1'b1;
            end
          end
          else begin
            rdata <= 32'd0;
          end
        end
      end
    end
  end

endmodule
