`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// vga_ctrl.v — Nexys 4 DDR 640×480@60Hz 12-bit RGB444 VGA 控制器 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 基址 0x1000_2000 (PLIC Source 3 = VSYNC 中断):
//   +0x00 CTRL    : [0]=输出使能(默认1), [1]=模式(0=8色彩条自检, 1=外部RGB565像素流), [2]=VSYNC中断使能
//   +0x04 STAT    : [0]=VSYNC_IRQ(W1C), [31:16]=帧计数
//   +0x08 FB_BASE : 预留 DDR2 帧缓冲基址寄存器 (供 Stage 2 Linux fbdev / DMA 使用)
// 时序标准: VESA 640×480@60Hz (像素时钟 25 MHz, H=800, V=525, 负极性 HS/VS)。
// ============================================================================

module vga_ctrl (
  // 系统总线时钟域
  input  wire        sys_clk,
  input  wire        sys_rst,
  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg         ack,
  output reg  [31:0] rdata,
  output wire        irq_o,

  // VGA 像素时钟域 (25.0 MHz)
  input  wire        vga_clk,
  input  wire        vga_rst,

  // 外部像素流输入 (MODE=1 时由片上帧缓冲或 DDR2 DMA 提供 RGB565)
  output wire        px_active,
  output wire [9:0]  px_x,
  output wire [9:0]  px_y,
  input  wire [15:0] px_rgb565,

  // Nexys 4 DDR 物理 12-bit VGA 引脚
  output reg  [3:0]  vga_r,
  output reg  [3:0]  vga_g,
  output reg  [3:0]  vga_b,
  output reg         vga_hs,
  output reg         vga_vs
);

  // VESA 640×480@60Hz 扫描参数
  localparam [9:0] H_ACTIVE = 10'd640;
  localparam [9:0] H_FP     = 10'd16;
  localparam [9:0] H_SYNC   = 10'd96;
  localparam [9:0] H_TOTAL  = 10'd800;

  localparam [9:0] V_ACTIVE = 10'd480;
  localparam [9:0] V_FP     = 10'd10;
  localparam [9:0] V_SYNC   = 10'd2;
  localparam [9:0] V_TOTAL  = 10'd525;

  // ---- sys_clk 寄存器区 ----
  reg        reg_en;
  reg        reg_mode;     // 0 = 硬件彩条, 1 = 外部像素流
  reg        reg_irq_en;
  reg        vsync_irq;
  reg [15:0] frame_cnt;
  reg [31:0] fb_base;

  // VSYNC 跨时钟域同步 (vga_clk -> sys_clk, 显式 ASYNC_REG 防亚稳态)
  reg                          vs_tgl_vga;
  (* ASYNC_REG = "TRUE" *) reg vs_s1;
  (* ASYNC_REG = "TRUE" *) reg vs_s2;
  reg                          vs_s3;
  wire       vs_pulse_sys = vs_s2 ^ vs_s3;

  wire [3:0] off    = addr[3:0];
  wire       do_req = req && !ack;

  assign irq_o = reg_irq_en && vsync_irq;

  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) begin
      ack        <= 1'b0;
      rdata      <= 32'd0;
      reg_en     <= 1'b1;      // 上电默认输出彩条便于实板即刻验屏
      reg_mode   <= 1'b0;
      reg_irq_en <= 1'b0;
      vsync_irq  <= 1'b0;
      frame_cnt  <= 16'd0;
      fb_base    <= 32'h8100_0000;
      vs_s1      <= 1'b0;
      vs_s2      <= 1'b0;
      vs_s3      <= 1'b0;
    end
    else begin
      ack   <= do_req;
      vs_s1 <= vs_tgl_vga;
      vs_s2 <= vs_s1;
      vs_s3 <= vs_s2;

      if (vs_pulse_sys) begin
        vsync_irq <= 1'b1;
        frame_cnt <= frame_cnt + 16'd1;
      end

      if (do_req) begin
        if (we) begin
          rdata <= 32'd0;
          case (off)
            4'h0: begin
              reg_en     <= wdata[0];
              reg_mode   <= wdata[1];
              reg_irq_en <= wdata[2];
            end
            4'h4: if (wdata[0]) vsync_irq <= 1'b0;
            4'h8: fb_base <= wdata;
            default: ;
          endcase
        end
        else begin
          case (off)
            4'h0:    rdata <= {29'd0, reg_irq_en, reg_mode, reg_en};
            4'h4:    rdata <= {frame_cnt, 15'd0, vsync_irq};
            4'h8:    rdata <= fb_base;
            4'hC:    rdata <= {16'd640, 16'd480}; // 只读分辨率标识 (驱动自探测)
            default: rdata <= 32'd0;
          endcase
        end
      end
    end
  end

  // ---- vga_clk (25 MHz) 扫描发生器与像素输出 ----
  (* ASYNC_REG = "TRUE" *) reg en_s1;
  (* ASYNC_REG = "TRUE" *) reg en_s2;
  (* ASYNC_REG = "TRUE" *) reg mode_s1;
  (* ASYNC_REG = "TRUE" *) reg mode_s2;
  reg [9:0]  h_cnt;
  reg [9:0]  v_cnt;

  assign px_active = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
  assign px_x      = h_cnt;
  assign px_y      = v_cnt;

  // 8 色彩条生成 (每条宽 80 像素: 白/黄/青/绿/品红/红/蓝/黑)
  reg [11:0] bar_rgb444;
  always @(*) begin
    if      (h_cnt < 10'd80)  bar_rgb444 = 12'hFFF;
    else if (h_cnt < 10'd160) bar_rgb444 = 12'hFF0;
    else if (h_cnt < 10'd240) bar_rgb444 = 12'h0FF;
    else if (h_cnt < 10'd320) bar_rgb444 = 12'h0F0;
    else if (h_cnt < 10'd400) bar_rgb444 = 12'hF0F;
    else if (h_cnt < 10'd480) bar_rgb444 = 12'hF00;
    else if (h_cnt < 10'd560) bar_rgb444 = 12'h00F;
    else                      bar_rgb444 = 12'h000;
  end

  wire [11:0] stream_rgb444 = {px_rgb565[15:12], px_rgb565[10:7], px_rgb565[4:1]};
  wire [11:0] out_rgb444    = mode_s2 ? stream_rgb444 : bar_rgb444;

  always @(posedge vga_clk or posedge vga_rst) begin
    if (vga_rst) begin
      en_s1      <= 1'b1;
      en_s2      <= 1'b1;
      mode_s1    <= 1'b0;
      mode_s2    <= 1'b0;
      h_cnt      <= 10'd0;
      v_cnt      <= 10'd0;
      vs_tgl_vga <= 1'b0;
      vga_hs     <= 1'b1;
      vga_vs     <= 1'b1;
      vga_r      <= 4'd0;
      vga_g      <= 4'd0;
      vga_b      <= 4'd0;
    end
    else begin
      en_s1   <= reg_en;
      en_s2   <= en_s1;
      mode_s1 <= reg_mode;
      mode_s2 <= mode_s1;

      if (h_cnt == (H_TOTAL - 10'd1)) begin
        h_cnt <= 10'd0;
        if (v_cnt == (V_TOTAL - 10'd1)) begin
          v_cnt      <= 10'd0;
          vs_tgl_vga <= ~vs_tgl_vga;
        end
        else begin
          v_cnt <= v_cnt + 10'd1;
        end
      end
      else begin
        h_cnt <= h_cnt + 10'd1;
      end

      vga_hs <= !((h_cnt >= (H_ACTIVE + H_FP)) && (h_cnt < (H_ACTIVE + H_FP + H_SYNC)));
      vga_vs <= !((v_cnt >= (V_ACTIVE + V_FP)) && (v_cnt < (V_ACTIVE + V_FP + V_SYNC)));

      if (en_s2 && px_active) begin
        vga_r <= out_rgb444[11:8];
        vga_g <= out_rgb444[7:4];
        vga_b <= out_rgb444[3:0];
      end
      else begin
        vga_r <= 4'd0;
        vga_g <= 4'd0;
        vga_b <= 4'd0;
      end
    end
  end

endmodule
