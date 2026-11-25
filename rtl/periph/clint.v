`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// clint.v — 标准 SiFive 兼容 CLINT (Core-Local Interruptor, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 寄存器映射 (基址 0x0200_0000):
//   +0x0000 : msip        (bit 0: Hart 0 机器软件中断, R/W)
//   +0x4000 : mtimecmp_lo (Hart 0 定时器比较值低 32 位, 复位为 0xFFFF_FFFF)
//   +0x4004 : mtimecmp_hi (Hart 0 定时器比较值高 32 位, 复位为 0xFFFF_FFFF)
//   +0xBFF8 : mtime_lo    (64 位实时计数器低 32 位, R/W)
//   +0xBFFC : mtime_hi    (64 位实时计数器高 32 位, R/W)
// 直接兼容 Linux timer-clint / OpenSBI。
// ============================================================================

module clint #(
  parameter TICK_DIV = 1    // mtime 分频因子 (1=每拍自增; 上板可设 10 得 10 MHz @ 100 MHz)
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg         ack,
  output reg  [31:0] rdata,

  output wire [63:0] mtime_o,
  output wire        irq_sw,
  output reg         irq_timer
);

  reg        msip;
  reg [63:0] mtime;
  reg [63:0] mtimecmp;
  reg [15:0] div_cnt;

  wire [15:0] off = addr[15:0];
  wire        do_req = req && !ack;

  assign mtime_o = mtime;
  assign irq_sw  = msip;

  function [31:0] apply_strb;
    input [31:0] cur;
    input [31:0] nw;
    input [3:0]  st;
    begin
      apply_strb[ 7: 0] = st[0] ? nw[ 7: 0] : cur[ 7: 0];
      apply_strb[15: 8] = st[1] ? nw[15: 8] : cur[15: 8];
      apply_strb[23:16] = st[2] ? nw[23:16] : cur[23:16];
      apply_strb[31:24] = st[3] ? nw[31:24] : cur[31:24];
    end
  endfunction

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack       <= 1'b0;
      rdata     <= 32'd0;
      irq_timer <= 1'b0;
      msip      <= 1'b0;
      mtime     <= 64'd0;
      mtimecmp  <= 64'hFFFF_FFFF_FFFF_FFFF;
      div_cnt   <= 16'd0;
    end
    else begin
      ack       <= do_req;
      // 寄存 64-bit 比较结果，切断 CLINT 比较器 -> CPU 陷阱向量的组合关键路径
      irq_timer <= (mtime >= mtimecmp);

      // 64 位实时计数器推进
      if (TICK_DIV <= 1) begin
        mtime <= mtime + 64'd1;
      end
      else if (div_cnt == (TICK_DIV - 1)) begin
        div_cnt <= 16'd0;
        mtime   <= mtime + 64'd1;
      end
      else begin
        div_cnt <= div_cnt + 16'd1;
      end

      if (do_req) begin
        if (we) begin
          case (off)
            16'h0000: if (wstrb[0]) msip <= wdata[0];
            16'h4000: mtimecmp[31:0]  <= apply_strb(mtimecmp[31:0],  wdata, wstrb);
            16'h4004: mtimecmp[63:32] <= apply_strb(mtimecmp[63:32], wdata, wstrb);
            16'hBFF8: mtime[31:0]     <= apply_strb(mtime[31:0],     wdata, wstrb);
            16'hBFFC: mtime[63:32]    <= apply_strb(mtime[63:32],    wdata, wstrb);
            default: ;
          endcase
          rdata <= 32'd0;
        end
        else begin
          case (off)
            16'h0000: rdata <= {31'd0, msip};
            16'h4000: rdata <= mtimecmp[31:0];
            16'h4004: rdata <= mtimecmp[63:32];
            16'hBFF8: rdata <= mtime[31:0];
            16'hBFFC: rdata <= mtime[63:32];
            default:  rdata <= 32'd0;
          endcase
        end
      end
    end
  end

endmodule
