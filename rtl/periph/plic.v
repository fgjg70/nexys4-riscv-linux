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

  // 组合仲裁: 在所有 pending & enable 且 prio > threshold 的中断源中，
  // 选择优先级最高者 (同优先级时 ID 较小者胜出, 符合 RISC-V PLIC 规范)
  reg [2:0] best_id;
  reg [2:0] best_prio;
  integer k;
  always @(*) begin
    best_id   = 3'd0;
    best_prio = threshold;
    for (k = 1; k <= 7; k = k + 1) begin
      if (pending[k] && enable[k] && (prio[k] > best_prio)) begin
        best_id   = k[2:0];
        best_prio = prio[k];
      end
    end
  end

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
