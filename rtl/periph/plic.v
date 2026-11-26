`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// plic.v — 标准最小 RISC-V PLIC (Platform-Level Interrupt Controller, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 兼容 Linux irq-sifive-plic，支持 7 路外部中断源 (ID 1..7, ID 0 保留为无中断):
//   Source 1: NS16550A UART
//   Source 2: SPI / microSD (预留)
//   Source 3: VGA VSYNC (预留)
//   Source 4: OV5640 摄像头帧中断 (预留)
// 寄存器映射 (基址 0x0C00_0000, Context 0 = M-mode Hart 0):
//   +0x000004 .. +0x00001C : Source 1..7 优先级 (3-bit, 0..7)
//   +0x001000              : Pending 位图 (只读, bit i = source i)
//   +0x002000              : Context 0 Enable 位图 (bit 1..7 可读写)
//   +0x200000              : Context 0 优先级阈值 (3-bit)
//   +0x200004              : Context 0 Claim (读) / Complete (写)
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
  output reg         irq_ext
);

  reg [2:0] prio [1:7];
  reg [7:1] enable;
  reg [7:1] claimed;
  reg [2:0] threshold;

  wire [7:1] pending = irq_src & ~claimed;

  // 3 级平衡二叉锦标赛树仲裁 (替代 7 级串行比较链，逻辑级数 15 -> 5):
  // 在所有 pending & enable 且 prio > threshold 的中断源中选择优先级最高者 (同优先级 ID 较小者胜)
  wire [2:0] cp1 = (pending[1] && enable[1] && (prio[1] > threshold)) ? prio[1] : 3'd0;
  wire [2:0] cp2 = (pending[2] && enable[2] && (prio[2] > threshold)) ? prio[2] : 3'd0;
  wire [2:0] cp3 = (pending[3] && enable[3] && (prio[3] > threshold)) ? prio[3] : 3'd0;
  wire [2:0] cp4 = (pending[4] && enable[4] && (prio[4] > threshold)) ? prio[4] : 3'd0;
  wire [2:0] cp5 = (pending[5] && enable[5] && (prio[5] > threshold)) ? prio[5] : 3'd0;
  wire [2:0] cp6 = (pending[6] && enable[6] && (prio[6] > threshold)) ? prio[6] : 3'd0;
  wire [2:0] cp7 = (pending[7] && enable[7] && (prio[7] > threshold)) ? prio[7] : 3'd0;

  wire       w12  = (cp1 >= cp2);
  wire [2:0] p12  = w12 ? cp1 : cp2;
  wire [2:0] id12 = w12 ? ((cp1 != 3'd0) ? 3'd1 : 3'd0) : 3'd2;

  wire       w34  = (cp3 >= cp4);
  wire [2:0] p34  = w34 ? cp3 : cp4;
  wire [2:0] id34 = w34 ? ((cp3 != 3'd0) ? 3'd3 : 3'd0) : 3'd4;

  wire       w56  = (cp5 >= cp6);
  wire [2:0] p56  = w56 ? cp5 : cp6;
  wire [2:0] id56 = w56 ? ((cp5 != 3'd0) ? 3'd5 : 3'd0) : 3'd6;

  wire [2:0] id7  = (cp7 != 3'd0) ? 3'd7 : 3'd0;

  wire       w14  = (p12 >= p34);
  wire [2:0] p14  = w14 ? p12 : p34;
  wire [2:0] id14 = w14 ? id12 : id34;

  wire       w57  = (p56 >= cp7);
  wire [2:0] p57  = w57 ? p56 : cp7;
  wire [2:0] id57 = w57 ? id56 : id7;

  wire [2:0] best_id = (p14 >= p57) ? id14 : id57;

  wire [21:0] off    = addr[21:0];
  wire        do_req = req && !ack;

  integer i;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack       <= 1'b0;
      rdata     <= 32'd0;
      irq_ext   <= 1'b0;
      enable    <= 7'd0;
      claimed   <= 7'd0;
      threshold <= 3'd0;
      for (i = 1; i <= 7; i = i + 1) prio[i] <= 3'd0;
    end
    else begin
      ack     <= do_req;
      // 寄存中断输出，彻底切断外设 -> PLIC 优先级链 -> CPU 陷阱向量的组合关键路径
      irq_ext <= (best_id != 3'd0);
      if (do_req) begin
        if (we) begin
          rdata <= 32'd0;
          if ((off >= 22'h000004) && (off <= 22'h00001C) && (off[1:0] == 2'b00)) begin
            prio[off[4:2]] <= wdata[2:0];
          end
          else if (off == 22'h002000) begin
            enable <= wdata[7:1];
          end
          else if (off == 22'h200000) begin
            threshold <= wdata[2:0];
          end
          else if (off == 22'h200004) begin
            // Complete: 释放已认领中断源
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
            rdata <= {24'd0, enable, 1'b0};
          end
          else if (off == 22'h200000) begin
            rdata <= {29'd0, threshold};
          end
          else if (off == 22'h200004) begin
            // Claim: 返回最高优先级挂起源 ID 并标记 claimed
            rdata <= {29'd0, best_id};
            if (best_id != 3'd0) begin
              claimed[best_id] <= 1'b1;
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
