`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// top_nexys4_ddr.v — Digilent Nexys 4 DDR (xc7a100tcsg324-1) 实板顶层 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 时钟架构 (Round 4 100 MHz SoC + 128-bit 异步 FIFO DDR2 解耦):
//   - 板载 100 MHz (E3) -> clk_wiz_0 (VCO=1200 MHz 精确整数分频):
//       * clk_200m (200 MHz) -> MIG 7 Series DDR2 sys_clk_i & 参考时钟
//       * clk_100m (100 MHz) -> rv32_soc CPU/Cache/外设主时钟 (+33.3% 实板主频!)
//       * clk_25m  (25 MHz)  -> VGA 640×480@60Hz 像素时钟
//       * clk_24m  (24 MHz)  -> OV5640 外部 XCLK
//   - MIG 7 Series (MT47H64M16HR-25E, 300 MHz DDR2, 4:1 PHY) 输出 ui_clk = 75 MHz:
//       * mig_ddr2_bridge 在 128-bit 宽边界以双异步 FIFO 解耦 clk_100m <-> ui_clk，
//         128-bit 读行缓冲与 Posted Write 队列驻留 100 MHz 侧，兼顾 100 MHz 主频与高带宽。
// LED 诊断:
//   - LED[0]    : DDR2 init_calib_complete
//   - LED[1]    : MMCM clk_wiz_0 locked
//   - LED[2]    : clk_100m 心跳闪烁 (~1.5 Hz)
//   - LED[14:3] : SW[0]=0 时显示 dbg_pc[15:4]，SW[0]=1 时显示 dbg_pc[27:16]
//   - LED[15]   : dbg_illegal 未捕获非法指令锁存告警
// ============================================================================

module top_nexys4_ddr (
  input  wire        CLK100MHZ,
  input  wire        CPU_RESETN,

  input  wire [7:0]  SW,
  output wire [15:0] LED,

  // USB-UART (NS16550A)
  input  wire        UART_TXD_IN,
  output wire        UART_RXD_OUT,

  // microSD (SPI Mode 0)
  output wire        SD_RESET,
  input  wire        SD_CD,
  output wire        SD_SCK,
  output wire        SD_CMD,
  inout  wire [3:0]  SD_DAT,

  // 12-bit RGB444 VGA
  output wire [3:0]  VGA_R,
  output wire [3:0]  VGA_G,
  output wire [3:0]  VGA_B,
  output wire        VGA_HS,
  output wire        VGA_VS,

  // 双 Pmod (JA+JB) OV5640 摄像头
  input  wire [7:0]  CAM_D,
  input  wire        CAM_VSYNC,
  input  wire        CAM_HREF,
  input  wire        CAM_PCLK,
  output wire        CAM_XCLK,
  output wire        CAM_SIOC,
  inout  wire        CAM_SIOD,
  output wire        CAM_RST_N,
  output wire        CAM_PWDN,

  // 板载 128 MB DDR2 (MT47H64M16HR-25E, 接 MIG 7 Series)
  inout  wire [15:0] ddr2_dq,
  inout  wire [1:0]  ddr2_dqs_n,
  inout  wire [1:0]  ddr2_dqs_p,
  output wire [12:0] ddr2_addr,
  output wire [2:0]  ddr2_ba,
  output wire        ddr2_ras_n,
  output wire        ddr2_cas_n,
  output wire        ddr2_we_n,
  output wire [0:0]  ddr2_ck_p,
  output wire [0:0]  ddr2_ck_n,
  output wire [0:0]  ddr2_cke,
  output wire [0:0]  ddr2_cs_n,
  output wire [1:0]  ddr2_dm,
  output wire [0:0]  ddr2_odt
);

  // ---- 时钟生成 IP (Vivado Clocking Wizard) ----
  wire clk_200m;
  wire clk_100m;
  wire clk_25m;
  wire clk_24m;
  wire mmcm_locked;

  clk_wiz_0 u_clk_wiz (
    .clk_in1  (CLK100MHZ),
    .resetn   (CPU_RESETN),
    .clk_200m (clk_200m),
    .clk_25m  (clk_25m),
    .clk_24m  (clk_24m),
    .clk_100m (clk_100m),
    .locked   (mmcm_locked)
  );

`ifdef SYNTHESIS
  // Xilinx 7-Series 推荐时钟转发原语: 避免全局时钟网线直接下布线至普通 IOB 引脚
  ODDR #(
    .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
    .INIT         (1'b0),
    .SRTYPE       ("SYNC")
  ) u_cam_xclk_oddr (
    .Q  (CAM_XCLK),
    .C  (clk_24m),
    .CE (1'b1),
    .D1 (1'b1),
    .D2 (1'b0),
    .R  (1'b0),
    .S  (1'b0)
  );
`else
  assign CAM_XCLK = clk_24m;
`endif

  // ---- MIG 7 Series 复位同步 (低有效 sys_rst 同步至 clk_200m) ----
  (* ASYNC_REG = "TRUE" *) reg [1:0] mig_rstn_sync;
  always @(posedge clk_200m or negedge CPU_RESETN) begin
    if (!CPU_RESETN) mig_rstn_sync <= 2'b00;
    else             mig_rstn_sync <= {mig_rstn_sync[0], mmcm_locked};
  end
  wire mig_sys_rstn = mig_rstn_sync[1];

  // ---- MIG 7 Series 128 MB DDR2 控制器 ----
  wire         ui_clk;
  wire         ui_clk_sync_rst;
  wire         init_calib_complete;

  wire [26:0]  app_addr;
  wire [2:0]   app_cmd;
  wire         app_en;
  wire         app_rdy;
  wire [127:0] app_wdf_data;
  wire [15:0]  app_wdf_mask;
  wire         app_wdf_wren;
  wire         app_wdf_end;
  wire         app_wdf_rdy;
  wire [127:0] app_rd_data;
  wire         app_rd_data_end;
  wire         app_rd_data_valid;

  mig_7series_0 u_mig_ddr2 (
    .ddr2_dq             (ddr2_dq),
    .ddr2_dqs_n          (ddr2_dqs_n),
    .ddr2_dqs_p          (ddr2_dqs_p),
    .ddr2_addr           (ddr2_addr),
    .ddr2_ba             (ddr2_ba),
    .ddr2_ras_n          (ddr2_ras_n),
    .ddr2_cas_n          (ddr2_cas_n),
    .ddr2_we_n           (ddr2_we_n),
    .ddr2_ck_p           (ddr2_ck_p),
    .ddr2_ck_n           (ddr2_ck_n),
    .ddr2_cke            (ddr2_cke),
    .ddr2_cs_n           (ddr2_cs_n),
    .ddr2_dm             (ddr2_dm),
    .ddr2_odt            (ddr2_odt),
    .sys_clk_i           (clk_200m),
    .sys_rst             (mig_sys_rstn),
    .app_addr            (app_addr),
    .app_cmd             (app_cmd),
    .app_en              (app_en),
    .app_wdf_data        (app_wdf_data),
    .app_wdf_end         (app_wdf_end),
    .app_wdf_mask        (app_wdf_mask),
    .app_wdf_wren        (app_wdf_wren),
    .app_rd_data         (app_rd_data),
    .app_rd_data_end     (app_rd_data_end),
    .app_rd_data_valid   (app_rd_data_valid),
    .app_rdy             (app_rdy),
    .app_wdf_rdy         (app_wdf_rdy),
    .app_sr_req          (1'b0),
    .app_sr_active       (),
    .app_ref_req         (1'b0),
    .app_ref_ack         (),
    .app_zq_req          (1'b0),
    .app_zq_ack          (),
    .ui_clk              (ui_clk),
    .ui_clk_sync_rst     (ui_clk_sync_rst),
    .device_temp_i       (12'd0),
    .init_calib_complete (init_calib_complete)
  );

  // ---- 各时钟域复位同步 ----
  // SoC 主时钟 (clk_100m = 100 MHz): 等待 MMCM 锁定、MIG 脱离复位且 DDR2 校准完成后释放
  wire soc_rst_raw = !CPU_RESETN || !mmcm_locked || ui_clk_sync_rst || !init_calib_complete;
  (* ASYNC_REG = "TRUE" *) reg [1:0] soc_rst_sync;
  always @(posedge clk_100m or posedge soc_rst_raw) begin
    if (soc_rst_raw) soc_rst_sync <= 2'b11;
    else             soc_rst_sync <= {soc_rst_sync[0], 1'b0};
  end
  wire soc_rst = soc_rst_sync[1];

  // VGA 像素时钟域 (25 MHz) 复位
  wire vga_rst_raw = !CPU_RESETN || !mmcm_locked;
  (* ASYNC_REG = "TRUE" *) reg [1:0] vga_rst_sync;
  always @(posedge clk_25m or posedge vga_rst_raw) begin
    if (vga_rst_raw) vga_rst_sync <= 2'b11;
    else             vga_rst_sync <= {vga_rst_sync[0], 1'b0};
  end
  wire vga_rst = vga_rst_sync[1];

  // ---- 100 MHz SoC <-> 75 MHz MIG 128-bit 异步 FIFO 解耦桥 ----
  wire        ram_req, ram_we, ram_ack, ram_err;
  wire [31:0] ram_addr, ram_wdata, ram_rdata;
  wire [3:0]  ram_wstrb;

  mig_ddr2_bridge u_mig_bridge (
    .sys_clk             (clk_100m),
    .sys_rst             (soc_rst),
    .ram_req             (ram_req),
    .ram_we              (ram_we),
    .ram_addr            (ram_addr),
    .ram_wdata           (ram_wdata),
    .ram_wstrb           (ram_wstrb),
    .ram_ack             (ram_ack),
    .ram_rdata           (ram_rdata),
    .ram_err             (ram_err),
    .mig_clk             (ui_clk),
    .mig_rst             (ui_clk_sync_rst),
    .init_calib_complete (init_calib_complete),
    .app_addr            (app_addr),
    .app_cmd             (app_cmd),
    .app_en              (app_en),
    .app_rdy             (app_rdy),
    .app_wdf_data        (app_wdf_data),
    .app_wdf_mask        (app_wdf_mask),
    .app_wdf_wren        (app_wdf_wren),
    .app_wdf_end         (app_wdf_end),
    .app_wdf_rdy         (app_wdf_rdy),
    .app_rd_data         (app_rd_data),
    .app_rd_data_valid   (app_rd_data_valid)
  );

  // ---- microSD SPI 引脚三态/固定上拉映射 ----
  wire spi_cs_n;
  wire spi_miso = SD_DAT[0];
  assign SD_DAT[0] = 1'bz;
  assign SD_DAT[1] = 1'b1;      // SPI 模式闲置拉高
  assign SD_DAT[2] = 1'b1;      // SPI 模式闲置拉高
  assign SD_DAT[3] = spi_cs_n;  // SPI CS_N

  // ---- OV5640 SCCB 双开漏三态 (对齐 AF-OV5640-U1.0, SCL/SDA 均由 XDC PULLUP 拉高) ----
  wire cam_sio_c_raw;
  wire cam_sio_d_oe;
  wire cam_sio_d_in = CAM_SIOD;
  assign CAM_SIOC   = cam_sio_c_raw ? 1'bz : 1'b0;
  assign CAM_SIOD   = cam_sio_d_oe  ? 1'b0 : 1'bz;

  // ---- RV32IMA Linux-Ready SoC 核心 ----
  wire [31:0] dbg_pc;
  wire        dbg_illegal;

  rv32_soc #(
    .RESET_PC        (`SOC_ROM_BASE),
    .CLK_HZ          (100_000_000),
    .BAUD_HZ         (115_200),
    .CLINT_TICK_DIV  (100),         // 1 MHz 标准 timebase (供 Linux/OpenSBI 使用)
    .SPI_DEFAULT_DIV (16'd250),     // 200 kHz SD 卡初始化时钟 (100M / (2*250))
    .SCCB_HZ         (100_000)
  ) u_soc (
    .clk               (clk_100m),
    .rst               (soc_rst),
    .ram_req           (ram_req),
    .ram_we            (ram_we),
    .ram_addr          (ram_addr),
    .ram_wdata         (ram_wdata),
    .ram_wstrb         (ram_wstrb),
    .ram_ack           (ram_ack),
    .ram_rdata         (ram_rdata),
    .ram_err           (ram_err),
    .uart_txd          (UART_RXD_OUT),
    .uart_rxd          (UART_TXD_IN),
    .spi_sck           (SD_SCK),
    .spi_mosi          (SD_CMD),
    .spi_miso          (spi_miso),
    .spi_cs_n          (spi_cs_n),
    .sd_reset          (SD_RESET),
    .sd_cd_n           (SD_CD),
    .vga_clk           (clk_25m),
    .vga_rst           (vga_rst),
    .vga_px_active     (),
    .vga_px_x          (),
    .vga_px_y          (),
    .vga_px_rgb565     (16'd0),
    .vga_r             (VGA_R),
    .vga_g             (VGA_G),
    .vga_b             (VGA_B),
    .vga_hs            (VGA_HS),
    .vga_vs            (VGA_VS),
    .cam_pclk          (CAM_PCLK),
    .cam_vsync         (CAM_VSYNC),
    .cam_href          (CAM_HREF),
    .cam_d             (CAM_D),
    .cam_pwdn          (CAM_PWDN),
    .cam_rst_n         (CAM_RST_N),
    .cam_sio_c         (cam_sio_c_raw),
    .cam_sio_d_oe      (cam_sio_d_oe),
    .cam_sio_d_in      (cam_sio_d_in),
    .cam_stream_rd_en  (1'b0),
    .cam_stream_rgb565 (),
    .cam_stream_empty  (),
    .ext_irq_in        (3'd0),
    .dbg_pc            (dbg_pc),
    .dbg_id_pc         (),
    .dbg_instr         (),
    .dbg_illegal       (dbg_illegal),
    .uart_tx_pulse     (),
    .uart_tx_byte      ()
  );

  // ---- 心跳与板载 LED 诊断 (clk_100m 域，~1.49 Hz) ----
  reg [25:0] hb_cnt;
  always @(posedge clk_100m or posedge soc_rst) begin
    if (soc_rst) hb_cnt <= 26'd0;
    else         hb_cnt <= hb_cnt + 26'd1;
  end

  assign LED[0]    = init_calib_complete;
  assign LED[1]    = mmcm_locked;
  assign LED[2]    = hb_cnt[25];
  assign LED[14:3] = SW[0] ? dbg_pc[27:16] : dbg_pc[15:4];
  assign LED[15]   = dbg_illegal;

endmodule
