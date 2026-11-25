`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// ov5640_capture.v — JA+JB Pmod OV5640 摄像头 MMIO + cam_pclk 异步 FIFO 采集
// 纯 Verilog-2001，在真实 cam_pclk 时钟域直接采样 D[7:0]/HREF/VSYNC，
// 打包 16-bit RGB565 经 async_fifo 跨时钟域送往系统总线或 VGA 帧缓冲。
// ----------------------------------------------------------------------------
// 基址 0x1000_3000 (PLIC Source 4 = 帧完成中断):
//   +0x00 CTRL    : [0]=SCCB_WR(自清), [1]=SCCB_RD(自清), [2]=CAM_PWDN,
//                   [3]=CAM_RST_N(默认1), [4]=CAP_EN, [5]=FRAME_IRQ_EN
//   +0x04 STAT    : [0]=SCCB_BUSY, [1]=SCCB_NACK, [2]=FRAME_IRQ(W1C),
//                   [3]=FIFO_EMPTY, [4]=FIFO_FULL
//   +0x08 SCCB_OP : [15:0]=16-bit 寄存器地址, [23:16]=写数据
//   +0x0C SCCB_RD : [7:0]=SCCB 读回数据
//   +0x10 PIXEL   : 读弹出一个 16-bit RGB565 像素 (供 CPU 轮询或调试抓帧)
//   +0x14 FRAMES  : [31:0] 已采集完整帧计数
// ============================================================================

module ov5640_capture #(
  parameter CLK_HZ  = 50_000_000,
  parameter SCCB_HZ = 100_000
)(
  input  wire        sys_clk,
  input  wire        sys_rst,

  // MMIO 总线口
  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg         ack,
  output reg  [31:0] rdata,
  output wire        irq_o,

  // OV5640 DVP 物理输入 (JA+JB Pmod)
  input  wire        cam_pclk,
  input  wire        cam_vsync,
  input  wire        cam_href,
  input  wire [7:0]  cam_d,
  output reg         cam_pwdn,
  output reg         cam_rst_n,

  // OV5640 SCCB 开漏引脚
  output wire        sio_c,
  output wire        sio_d_oe,
  input  wire        sio_d_in,

  // 可选硬件像素流输出 (供 VGA 实时通路或 DDR2 DMA 读取)
  input  wire        stream_rd_en,
  output wire [15:0] stream_rgb565,
  output wire        stream_empty
);

  // ---- MMIO 控制与 SCCB 实例 ----
  reg        sccb_wr_pulse;
  reg        sccb_rd_pulse;
  reg [15:0] sccb_addr_r;
  reg [7:0]  sccb_wdata_r;
  reg        cap_en;
  reg        irq_en;
  reg        frame_irq;
  reg [31:0] frame_cnt;

  wire       sccb_busy;
  wire       sccb_nack;
  wire [7:0] sccb_rdata;

  ov5640_sccb #(
    .CLK_HZ  (CLK_HZ),
    .SCCB_HZ (SCCB_HZ)
  ) u_sccb (
    .clk      (sys_clk),
    .rst      (sys_rst),
    .start_wr (sccb_wr_pulse),
    .start_rd (sccb_rd_pulse),
    .reg_addr (sccb_addr_r),
    .wdata    (sccb_wdata_r),
    .busy     (sccb_busy),
    .nack_err (sccb_nack),
    .rdata    (sccb_rdata),
    .sio_c    (sio_c),
    .sio_d_oe (sio_d_oe),
    .sio_d_in (sio_d_in)
  );

  // ---- cam_pclk 域 DVP RGB565 打包 ----
  reg        cap_en_p1, cap_en_p2;
  reg        vs_d1;
  reg        byte_hi_vld;
  reg [7:0]  byte_hi;
  reg        px_wr_en;
  reg [15:0] px_wr_data;
  reg        frame_tgl_pclk;

  wire       fifo_full;
  wire       fifo_empty;
  wire [15:0] fifo_rdata;

  // 在 cam_pclk 域复位同步
  reg        pclk_rst_s1, pclk_rst_s2;
  always @(posedge cam_pclk or posedge sys_rst) begin
    if (sys_rst) begin
      pclk_rst_s1 <= 1'b1;
      pclk_rst_s2 <= 1'b1;
    end
    else begin
      pclk_rst_s1 <= 1'b0;
      pclk_rst_s2 <= pclk_rst_s1;
    end
  end
  wire pclk_rst = pclk_rst_s2;

  always @(posedge cam_pclk or posedge pclk_rst) begin
    if (pclk_rst) begin
      cap_en_p1      <= 1'b0;
      cap_en_p2      <= 1'b0;
      vs_d1          <= 1'b0;
      byte_hi_vld    <= 1'b0;
      byte_hi        <= 8'd0;
      px_wr_en       <= 1'b0;
      px_wr_data     <= 16'd0;
      frame_tgl_pclk <= 1'b0;
    end
    else begin
      cap_en_p1 <= cap_en;
      cap_en_p2 <= cap_en_p1;
      vs_d1     <= cam_vsync;
      px_wr_en  <= 1'b0;

      // VSYNC 上升沿标志帧界，同步翻转 frame_tgl_pclk 通知 sys_clk
      if (cam_vsync && !vs_d1) begin
        byte_hi_vld <= 1'b0;
        if (cap_en_p2) frame_tgl_pclk <= ~frame_tgl_pclk;
      end
      else if (cap_en_p2 && cam_href && !cam_vsync) begin
        if (!byte_hi_vld) begin
          byte_hi     <= cam_d;
          byte_hi_vld <= 1'b1;
        end
        else begin
          px_wr_data  <= {byte_hi, cam_d};
          px_wr_en    <= 1'b1;
          byte_hi_vld <= 1'b0;
        end
      end
      else if (!cam_href) begin
        byte_hi_vld <= 1'b0;
      end
    end
  end

  wire [4:0] off        = addr[4:0];
  reg        px_rd_pend;
  wire       do_req     = req && !ack && !px_rd_pend;
  wire       cpu_px_pop = do_req && !we && (off == 5'h10) && !fifo_empty;

  async_fifo #(.DATA_W(16), .ADDR_W(10)) u_px_fifo (
    .wr_clk   (cam_pclk),
    .wr_rst   (pclk_rst),
    .wr_en    (px_wr_en),
    .wr_data  (px_wr_data),
    .wr_full  (fifo_full),
    .rd_clk   (sys_clk),
    .rd_rst   (sys_rst),
    .rd_en    (stream_rd_en || cpu_px_pop),
    .rd_data  (fifo_rdata),
    .rd_empty (fifo_empty)
  );

  assign stream_rgb565 = fifo_rdata;
  assign stream_empty  = fifo_empty;

  // 帧完成翻转同步回 sys_clk
  reg fr_s1, fr_s2, fr_s3;
  wire frame_pulse_sys = fr_s2 ^ fr_s3;
  assign irq_o = irq_en && frame_irq;

  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) begin
      ack           <= 1'b0;
      rdata         <= 32'd0;
      px_rd_pend    <= 1'b0;
      sccb_wr_pulse <= 1'b0;
      sccb_rd_pulse <= 1'b0;
      sccb_addr_r   <= 16'd0;
      sccb_wdata_r  <= 8'd0;
      cam_pwdn      <= 1'b0;
      cam_rst_n     <= 1'b1;
      cap_en        <= 1'b0;
      irq_en        <= 1'b0;
      frame_irq     <= 1'b0;
      frame_cnt     <= 32'd0;
      fr_s1         <= 1'b0;
      fr_s2         <= 1'b0;
      fr_s3         <= 1'b0;
    end
    else begin
      ack           <= 1'b0;
      sccb_wr_pulse <= 1'b0;
      sccb_rd_pulse <= 1'b0;

      fr_s1 <= frame_tgl_pclk;
      fr_s2 <= fr_s1;
      fr_s3 <= fr_s2;

      if (frame_pulse_sys) begin
        frame_irq <= 1'b1;
        frame_cnt <= frame_cnt + 32'd1;
      end

      // 异步 BRAM FIFO 同步读第 2 拍: 返回刚弹出的 RGB565 像素 ([16]=1 表示有效)
      if (px_rd_pend) begin
        px_rd_pend <= 1'b0;
        ack        <= 1'b1;
        rdata      <= {15'd0, 1'b1, fifo_rdata};
      end
      else if (do_req) begin
        if (we) begin
          ack   <= 1'b1;
          rdata <= 32'd0;
          case (off)
            5'h00: begin
              if (wdata[0] && !sccb_busy) sccb_wr_pulse <= 1'b1;
              if (wdata[1] && !sccb_busy) sccb_rd_pulse <= 1'b1;
              cam_pwdn  <= wdata[2];
              cam_rst_n <= wdata[3];
              cap_en    <= wdata[4];
              irq_en    <= wdata[5];
            end
            5'h04: if (wdata[2]) frame_irq <= 1'b0;
            5'h08: begin
              sccb_addr_r  <= wdata[15:0];
              sccb_wdata_r <= wdata[23:16];
            end
            default: ;
          endcase
        end
        else if (off == 5'h10) begin
          if (!fifo_empty) begin
            px_rd_pend <= 1'b1;
          end
          else begin
            ack   <= 1'b1;
            rdata <= 32'd0;    // [16]=0 表示 FIFO 为空
          end
        end
        else begin
          ack <= 1'b1;
          case (off)
            5'h00:   rdata <= {26'd0, irq_en, cap_en, cam_rst_n, cam_pwdn, 2'b00};
            5'h04:   rdata <= {27'd0, fifo_full, fifo_empty, frame_irq, sccb_nack, sccb_busy};
            5'h08:   rdata <= {8'd0, sccb_wdata_r, sccb_addr_r};
            5'h0C:   rdata <= {24'd0, sccb_rdata};
            5'h14:   rdata <= frame_cnt;
            default: rdata <= 32'd0;
          endcase
        end
      end
    end
  end

endmodule
