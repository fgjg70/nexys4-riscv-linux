`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_periph_stage2.v — Stage 2 Nexys 4 DDR 全部新增外设与 MIG 桥独立压测台
// 纯 Verilog-2001，逐项覆盖:
//   1) spi_master     : SPI Mode 0 环回收发、分频、CS_N/SD_RESET、W1C 中断
//   2) vga_ctrl       : 640×480@60Hz VESA 整帧 HS/VS 时序、8 色彩条、RGB565 流模式、VSYNC CDC 中断
//   3) ov5640_sccb    : 真实 16-bit 寄存器地址 SCCB 开漏写 + 两段式读回 + ACK 校验
//   4) ov5640_capture : 真实异步 cam_pclk(33.3MHz)->sys_clk(50MHz) RGB565 打包 + async_fifo 弹出 + 帧中断
//   5) mig_ddr2_bridge: 128-bit Native MIG 随机独立 app_rdy/app_wdf_rdy 反压 + 全 4 lane + 字节掩码读写
// ============================================================================

module tb_periph_stage2;

  reg sys_clk;
  reg sys_rst;
  reg vga_clk;
  reg vga_rst;
  reg cam_pclk;

  initial begin
    sys_clk  = 1'b0;
    vga_clk  = 1'b0;
    cam_pclk = 1'b0;
  end
  always #10 sys_clk  = ~sys_clk;   // 50.0 MHz
  always #20 vga_clk  = ~vga_clk;   // 25.0 MHz
  always #15 cam_pclk = ~cam_pclk;  // 33.3 MHz (与 sys_clk 真正异步)

  integer fail_cnt;

  task check_eq;
    input [31:0] got;
    input [31:0] exp;
    input [8*48-1:0] label;
    begin
      if (got !== exp) begin
        $display("ERROR: [%0s] got=0x%08x exp=0x%08x @t=%0t", label, got, exp, $time);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  // ==========================================================================
  // 1. SPI Master (Mode 0 环回)
  // ==========================================================================
  reg         spi_req, spi_we;
  reg  [31:0] spi_addr, spi_wdata;
  wire        spi_ack;
  wire [31:0] spi_rdata;
  wire        spi_sck, spi_mosi, spi_cs_n, sd_reset, spi_irq;

  spi_master #(.DEFAULT_DIV(16'd2)) u_spi (
    .clk      (sys_clk),
    .rst      (sys_rst),
    .req      (spi_req),
    .we       (spi_we),
    .addr     (spi_addr),
    .wdata    (spi_wdata),
    .wstrb    (4'hF),
    .ack      (spi_ack),
    .rdata    (spi_rdata),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_mosi),   // 外部回环
    .spi_cs_n (spi_cs_n),
    .sd_reset (sd_reset),
    .sd_cd_n  (1'b0),
    .irq_o    (spi_irq)
  );

  task spi_mmio_wr;
    input [31:0] a;
    input [31:0] d;
    begin
      @(negedge sys_clk);
      spi_req = 1'b1; spi_we = 1'b1; spi_addr = a; spi_wdata = d;
      @(posedge sys_clk);
      while (!spi_ack) @(posedge sys_clk);
      @(negedge sys_clk);
      spi_req = 1'b0; spi_we = 1'b0;
    end
  endtask

  task spi_mmio_rd;
    input  [31:0] a;
    output [31:0] d;
    begin
      @(negedge sys_clk);
      spi_req = 1'b1; spi_we = 1'b0; spi_addr = a; spi_wdata = 32'd0;
      @(posedge sys_clk);
      while (!spi_ack) @(posedge sys_clk);
      d = spi_rdata;
      @(negedge sys_clk);
      spi_req = 1'b0;
    end
  endtask

  // ==========================================================================
  // 2. VGA Controller (640x480@60Hz)
  // ==========================================================================
  reg         vga_req, vga_we;
  reg  [31:0] vga_addr, vga_wdata;
  wire        vga_ack, vga_irq;
  wire [31:0] vga_rdata;
  wire        vga_px_active;
  wire [9:0]  vga_px_x, vga_px_y;
  reg  [15:0] vga_px_rgb565;
  wire [3:0]  vga_r, vga_g, vga_b;
  wire        vga_hs, vga_vs;

  vga_ctrl u_vga (
    .sys_clk   (sys_clk),
    .sys_rst   (sys_rst),
    .req       (vga_req),
    .we        (vga_we),
    .addr      (vga_addr),
    .wdata     (vga_wdata),
    .wstrb     (4'hF),
    .ack       (vga_ack),
    .rdata     (vga_rdata),
    .irq_o     (vga_irq),
    .vga_clk   (vga_clk),
    .vga_rst   (vga_rst),
    .px_active (vga_px_active),
    .px_x      (vga_px_x),
    .px_y      (vga_px_y),
    .px_rgb565 (vga_px_rgb565),
    .vga_r     (vga_r),
    .vga_g     (vga_g),
    .vga_b     (vga_b),
    .vga_hs    (vga_hs),
    .vga_vs    (vga_vs)
  );

  task vga_mmio_wr;
    input [31:0] a;
    input [31:0] d;
    begin
      @(negedge sys_clk);
      vga_req = 1'b1; vga_we = 1'b1; vga_addr = a; vga_wdata = d;
      @(posedge sys_clk);
      while (!vga_ack) @(posedge sys_clk);
      @(negedge sys_clk);
      vga_req = 1'b0; vga_we = 1'b0;
    end
  endtask

  task vga_mmio_rd;
    input  [31:0] a;
    output [31:0] d;
    begin
      @(negedge sys_clk);
      vga_req = 1'b1; vga_we = 1'b0; vga_addr = a; vga_wdata = 32'd0;
      @(posedge sys_clk);
      while (!vga_ack) @(posedge sys_clk);
      d = vga_rdata;
      @(negedge sys_clk);
      vga_req = 1'b0;
    end
  endtask

  // ==========================================================================
  // 3 & 4. OV5640 Capture + 16-bit SCCB + Behavioral OV5640 SCCB Slave
  // ==========================================================================
  reg         cam_req, cam_we;
  reg  [31:0] cam_addr, cam_wdata;
  wire        cam_ack, cam_irq;
  wire [31:0] cam_rdata;
  reg         cam_vsync, cam_href;
  reg  [7:0]  cam_d;
  wire        cam_pwdn, cam_rst_n;
  wire        cam_sio_c, cam_sio_d_oe;
  wire        cam_stream_empty;
  wire [15:0] cam_stream_rgb565;

  // 开漏上拉 SIOD 总线 (主从均可拉低)
  reg         slave_siod_oe;
  wire        siod_line = (cam_sio_d_oe || slave_siod_oe) ? 1'b0 : 1'b1;

  ov5640_capture #(
    .CLK_HZ  (50_000_000),
    .SCCB_HZ (1_000_000)      // 仿真加速至 1 MHz (每季度 12 拍)
  ) u_cam (
    .sys_clk       (sys_clk),
    .sys_rst       (sys_rst),
    .req           (cam_req),
    .we            (cam_we),
    .addr          (cam_addr),
    .wdata         (cam_wdata),
    .wstrb         (4'hF),
    .ack           (cam_ack),
    .rdata         (cam_rdata),
    .irq_o         (cam_irq),
    .cam_pclk      (cam_pclk),
    .cam_vsync     (cam_vsync),
    .cam_href      (cam_href),
    .cam_d         (cam_d),
    .cam_pwdn      (cam_pwdn),
    .cam_rst_n     (cam_rst_n),
    .sio_c         (cam_sio_c),
    .sio_d_oe      (cam_sio_d_oe),
    .sio_d_in      (siod_line),
    .stream_rd_en  (1'b0),
    .stream_rgb565 (cam_stream_rgb565),
    .stream_empty  (cam_stream_empty)
  );

  // 简易行为 OV5640 16-bit SCCB 从设备模型 (地址 0x3C, 内置 4 个测试寄存器)
  reg [7:0]  sccb_reg_300a; // Chip ID H = 0x56
  reg [7:0]  sccb_reg_300b; // Chip ID L = 0x40
  reg [7:0]  sccb_reg_3103; // SCCB system ctrl
  reg [15:0] sccb_ptr;
  reg [7:0]  sccb_rx_byte;
  reg [7:0]  sccb_tx_byte;
  reg [3:0]  sccb_bit_cnt;
  reg [1:0]  sccb_byte_phase; // 0=dev, 1=addr_hi, 2=addr_lo, 3=data
  reg        sccb_active;
  reg        sccb_rd_mode;
  reg        sio_c_prev, siod_prev;

  function [7:0] sccb_read_reg;
    input [15:0] a;
    begin
      case (a)
        16'h300A: sccb_read_reg = sccb_reg_300a;
        16'h300B: sccb_read_reg = sccb_reg_300b;
        16'h3103: sccb_read_reg = sccb_reg_3103;
        default:  sccb_read_reg = 8'hA5;
      endcase
    end
  endfunction

  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) begin
      slave_siod_oe   <= 1'b0;
      sccb_reg_300a   <= 8'h56;
      sccb_reg_300b   <= 8'h40;
      sccb_reg_3103   <= 8'h00;
      sccb_ptr        <= 16'd0;
      sccb_rx_byte    <= 8'd0;
      sccb_tx_byte    <= 8'd0;
      sccb_bit_cnt    <= 4'd0;
      sccb_byte_phase <= 2'd0;
      sccb_active     <= 1'b0;
      sccb_rd_mode    <= 1'b0;
      sio_c_prev      <= 1'b1;
      siod_prev       <= 1'b1;
    end
    else begin
      sio_c_prev <= cam_sio_c;
      siod_prev  <= siod_line;

      // START 条件: SCL=1 期间 SDA 下降沿
      if (cam_sio_c && sio_c_prev && siod_prev && !siod_line) begin
        sccb_active     <= 1'b1;
        sccb_bit_cnt    <= 4'd0;
        sccb_byte_phase <= 2'd0;
        sccb_rd_mode    <= 1'b0;
        slave_siod_oe   <= 1'b0;
      end
      // STOP 条件: SCL=1 期间 SDA 上升沿
      else if (cam_sio_c && sio_c_prev && !siod_prev && siod_line) begin
        sccb_active   <= 1'b0;
        slave_siod_oe <= 1'b0;
      end
      else if (sccb_active) begin
        // SCL 上升沿: 采样主发来的数据位并递增已采样位数 (1..9)
        if (cam_sio_c && !sio_c_prev) begin
          if (!sccb_rd_mode && (sccb_bit_cnt < 4'd8)) begin
            sccb_rx_byte <= {sccb_rx_byte[6:0], siod_line};
          end
          sccb_bit_cnt <= sccb_bit_cnt + 4'd1;
        end
        // SCL 下降沿: 在第 8 位后出 ACK、第 9 位后换字节、读模式第 1..7 位后推下一位
        else if (!cam_sio_c && sio_c_prev) begin
          if (sccb_bit_cnt == 4'd8) begin
            if (!sccb_rd_mode) begin
              if (sccb_byte_phase == 2'd0) begin
                if (sccb_rx_byte[7:1] == 7'h3C) begin
                  slave_siod_oe <= 1'b1;
                  if (sccb_rx_byte[0] == 1'b1) begin
                    sccb_tx_byte <= sccb_read_reg(sccb_ptr);
                  end
                end
              end
              else begin
                slave_siod_oe <= 1'b1;
                if (sccb_byte_phase == 2'd1)      sccb_ptr[15:8] <= sccb_rx_byte;
                else if (sccb_byte_phase == 2'd2) sccb_ptr[7:0]  <= sccb_rx_byte;
                else if (sccb_byte_phase == 2'd3) begin
                  if (sccb_ptr == 16'h300A) sccb_reg_300a <= sccb_rx_byte;
                  if (sccb_ptr == 16'h300B) sccb_reg_300b <= sccb_rx_byte;
                  if (sccb_ptr == 16'h3103) sccb_reg_3103 <= sccb_rx_byte;
                end
              end
            end
            else begin
              // 读模式第 8 位发完 -> 释放总线等待主 NACK
              slave_siod_oe <= 1'b0;
            end
          end
          else if (sccb_bit_cnt == 4'd9) begin
            sccb_bit_cnt <= 4'd0;
            if (!sccb_rd_mode && (sccb_byte_phase == 2'd0) && (sccb_rx_byte == 8'h79)) begin
              sccb_rd_mode  <= 1'b1;
              slave_siod_oe <= ~sccb_tx_byte[7];
              sccb_tx_byte  <= {sccb_tx_byte[6:0], 1'b0};
            end
            else if (!sccb_rd_mode) begin
              slave_siod_oe   <= 1'b0;
              sccb_byte_phase <= sccb_byte_phase + 2'd1;
            end
            else begin
              slave_siod_oe <= 1'b0;
            end
          end
          else if (sccb_rd_mode && (sccb_bit_cnt >= 4'd1) && (sccb_bit_cnt <= 4'd7)) begin
            slave_siod_oe <= ~sccb_tx_byte[7];
            sccb_tx_byte  <= {sccb_tx_byte[6:0], 1'b0};
          end
        end
      end
    end
  end

  task cam_mmio_wr;
    input [31:0] a;
    input [31:0] d;
    begin
      @(negedge sys_clk);
      cam_req = 1'b1; cam_we = 1'b1; cam_addr = a; cam_wdata = d;
      @(posedge sys_clk);
      while (!cam_ack) @(posedge sys_clk);
      @(negedge sys_clk);
      cam_req = 1'b0; cam_we = 1'b0;
    end
  endtask

  task cam_mmio_rd;
    input  [31:0] a;
    output [31:0] d;
    begin
      @(negedge sys_clk);
      cam_req = 1'b1; cam_we = 1'b0; cam_addr = a; cam_wdata = 32'd0;
      @(posedge sys_clk);
      while (!cam_ack) @(posedge sys_clk);
      d = cam_rdata;
      @(negedge sys_clk);
      cam_req = 1'b0;
    end
  endtask

  // ==========================================================================
  // 5. MIG 7 Series 128-bit Native Bridge + 带独立随机反压的行为 MIG 模型
  // ==========================================================================
  reg          br_req, br_we;
  reg  [31:0]  br_addr, br_wdata;
  reg  [3:0]   br_wstrb;
  wire         br_ack, br_err;
  wire [31:0]  br_rdata;

  reg          mig_calib;
  wire [26:0]  app_addr;
  wire [2:0]   app_cmd;
  wire         app_en;
  reg          app_rdy;
  wire [127:0] app_wdf_data;
  wire [15:0]  app_wdf_mask;
  wire         app_wdf_wren;
  wire         app_wdf_end;
  reg          app_wdf_rdy;
  reg  [127:0] app_rd_data;
  reg          app_rd_data_valid;

  mig_ddr2_bridge u_mig_br (
    .clk                 (sys_clk),
    .rst                 (sys_rst),
    .ram_req             (br_req),
    .ram_we              (br_we),
    .ram_addr            (br_addr),
    .ram_wdata           (br_wdata),
    .ram_wstrb           (br_wstrb),
    .ram_ack             (br_ack),
    .ram_rdata           (br_rdata),
    .ram_err             (br_err),
    .init_calib_complete (mig_calib),
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

  // 行为 128-bit DDR2 MIG 存储 (64 个 128-bit 突发块 = 1 KB, 独立跟踪命令与写数据 FIFO)
  reg [127:0] ddr_mem [0:63];
  reg [7:0]   lfsr;
  reg         wr_cmd_pend, wr_dat_pend;
  reg [5:0]   wr_cmd_idx;
  reg [127:0] wr_dat_buf;
  reg [15:0]  wr_msk_buf;
  reg         rd_pipe_v1, rd_pipe_v2;
  reg [5:0]   rd_pipe_a1, rd_pipe_a2;
  integer     bi, mi;

  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) begin
      lfsr              <= 8'h5A;
      app_rdy           <= 1'b0;
      app_wdf_rdy       <= 1'b0;
      app_rd_data       <= 128'd0;
      app_rd_data_valid <= 1'b0;
      wr_cmd_pend       <= 1'b0;
      wr_dat_pend       <= 1'b0;
      wr_cmd_idx        <= 6'd0;
      wr_dat_buf        <= 128'd0;
      wr_msk_buf        <= 16'hFFFF;
      rd_pipe_v1        <= 1'b0;
      rd_pipe_v2        <= 1'b0;
      rd_pipe_a1        <= 6'd0;
      rd_pipe_a2        <= 6'd0;
      for (mi = 0; mi < 64; mi = mi + 1) ddr_mem[mi] <= 128'd0;
    end
    else begin
      // 伪随机独立反压 app_rdy 与 app_wdf_rdy (强制覆盖 4 种握手先后次序)
      lfsr        <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
      app_rdy     <= lfsr[0];
      app_wdf_rdy <= lfsr[2];

      // 读流水 (2 拍延迟返回 128-bit)
      rd_pipe_v1        <= 1'b0;
      rd_pipe_v2        <= rd_pipe_v1;
      rd_pipe_a2        <= rd_pipe_a1;
      app_rd_data_valid <= rd_pipe_v2;
      if (rd_pipe_v2) app_rd_data <= ddr_mem[rd_pipe_a2];

      // 接收命令口
      if (app_en && app_rdy) begin
        if (app_cmd == 3'b001) begin
          rd_pipe_v1 <= 1'b1;
          rd_pipe_a1 <= app_addr[8:3];
        end
        else if (app_cmd == 3'b000) begin
          wr_cmd_pend <= 1'b1;
          wr_cmd_idx  <= app_addr[8:3];
        end
      end

      // 接收写数据口
      if (app_wdf_wren && app_wdf_rdy && app_wdf_end) begin
        wr_dat_pend <= 1'b1;
        wr_dat_buf  <= app_wdf_data;
        wr_msk_buf  <= app_wdf_mask;
      end

      // 命令与写数据两者都齐时按 16-bit 掩码 (0=写, 1=屏蔽) 写入 ddr_mem
      if ((wr_cmd_pend || (app_en && app_rdy && (app_cmd == 3'b000))) &&
          (wr_dat_pend || (app_wdf_wren && app_wdf_rdy && app_wdf_end))) begin : commit_wr
        reg [5:0]   c_idx;
        reg [127:0] c_dat;
        reg [15:0]  c_msk;
        c_idx = wr_cmd_pend ? wr_cmd_idx : app_addr[8:3];
        c_dat = wr_dat_pend ? wr_dat_buf : app_wdf_data;
        c_msk = wr_dat_pend ? wr_msk_buf : app_wdf_mask;
        for (bi = 0; bi < 16; bi = bi + 1) begin
          if (!c_msk[bi]) begin
            ddr_mem[c_idx][bi*8 +: 8] <= c_dat[bi*8 +: 8];
          end
        end
        wr_cmd_pend <= 1'b0;
        wr_dat_pend <= 1'b0;
      end
    end
  end

  task mig_wr;
    input [31:0] a;
    input [31:0] d;
    input [3:0]  s;
    begin
      @(negedge sys_clk);
      br_req = 1'b1; br_we = 1'b1; br_addr = a; br_wdata = d; br_wstrb = s;
      @(posedge sys_clk);
      while (!br_ack) @(posedge sys_clk);
      @(negedge sys_clk);
      br_req = 1'b0; br_we = 1'b0;
    end
  endtask

  task mig_rd;
    input  [31:0] a;
    output [31:0] d;
    begin
      @(negedge sys_clk);
      br_req = 1'b1; br_we = 1'b0; br_addr = a; br_wdata = 32'd0; br_wstrb = 4'h0;
      @(posedge sys_clk);
      while (!br_ack) @(posedge sys_clk);
      d = br_rdata;
      @(negedge sys_clk);
      br_req = 1'b0;
    end
  endtask

  // ==========================================================================
  // 主测试序列
  // ==========================================================================
  reg [31:0] rd_val;
  integer    k, px_i, hs_low_cnt, vs_low_cnt;
  reg [15:0] exp_px;

  initial begin
    fail_cnt      = 0;
    sys_rst       = 1'b1;
    vga_rst       = 1'b1;
    spi_req       = 1'b0; spi_we = 1'b0; spi_addr = 32'd0; spi_wdata = 32'd0;
    vga_req       = 1'b0; vga_we = 1'b0; vga_addr = 32'd0; vga_wdata = 32'd0;
    vga_px_rgb565 = 16'hF800; // 纯红 RGB565 -> RGB444 = 0xF00
    cam_req       = 1'b0; cam_we = 1'b0; cam_addr = 32'd0; cam_wdata = 32'd0;
    cam_vsync     = 1'b0; cam_href = 1'b0; cam_d = 8'd0;
    br_req        = 1'b0; br_we = 1'b0; br_addr = 32'd0; br_wdata = 32'd0; br_wstrb = 4'h0;
    mig_calib     = 1'b0;

    repeat (6) @(posedge sys_clk);
    sys_rst = 1'b0;
    vga_rst = 1'b0;

    // ------------------------------------------------------------------------
    // Test 1: SPI Master Mode 0 环回 + 控制引脚 + W1C IRQ
    // ------------------------------------------------------------------------
    $display("[stage2] 1/5 Testing spi_master...");
    spi_mmio_wr(32'h08, 32'b100); // CS_N=0, SD_RESET=0, IRQ_EN=1
    check_eq({31'd0, spi_cs_n}, 32'd0, "spi_cs_n_low");
    check_eq({31'd0, sd_reset}, 32'd0, "sd_reset_pwr_on");
    spi_mmio_wr(32'h0C, 32'd2);   // DIV=2

    spi_mmio_wr(32'h00, 32'hA5);
    spi_mmio_rd(32'h04, rd_val);
    while (rd_val[0]) spi_mmio_rd(32'h04, rd_val);
    check_eq({31'd0, spi_irq}, 32'd1, "spi_irq_high");
    spi_mmio_rd(32'h00, rd_val);
    check_eq(rd_val, 32'hA5, "spi_rx_A5");

    spi_mmio_wr(32'h04, 32'b100); // W1C 清除中断
    check_eq({31'd0, spi_irq}, 32'd0, "spi_irq_cleared");

    spi_mmio_wr(32'h00, 32'h3C);
    spi_mmio_rd(32'h04, rd_val);
    while (rd_val[0]) spi_mmio_rd(32'h04, rd_val);
    spi_mmio_rd(32'h00, rd_val);
    check_eq(rd_val, 32'h3C, "spi_rx_3C");

    // ------------------------------------------------------------------------
    // Test 2: VGA 640x480@60Hz VESA 整帧时序 + 8 色彩条 + RGB565 流模式 + VSYNC IRQ
    // ------------------------------------------------------------------------
    $display("[stage2] 2/5 Testing vga_ctrl (1 full VESA frame)...");
    vga_mmio_wr(32'h00, 32'b101); // EN=1, MODE=0(彩条), VSYNC_IRQ_EN=1
    vga_mmio_wr(32'h08, 32'h8200_0000);
    vga_mmio_rd(32'h08, rd_val);
    check_eq(rd_val, 32'h8200_0000, "vga_fb_base");

    // 扫描第一行核对 8 色彩条与 HS 脉宽 (96 像素)
    hs_low_cnt = 0;
    for (k = 0; k < 800; k = k + 1) begin
      @(posedge vga_clk);
      #1;
      if (vga_px_y == 10'd0) begin
        if (vga_px_x == 10'd10)  check_eq({20'd0, vga_r, vga_g, vga_b}, 32'hFFF, "vga_bar0_white");
        if (vga_px_x == 10'd100) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'hFF0, "vga_bar1_yellow");
        if (vga_px_x == 10'd180) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h0FF, "vga_bar2_cyan");
        if (vga_px_x == 10'd260) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h0F0, "vga_bar3_green");
        if (vga_px_x == 10'd340) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'hF0F, "vga_bar4_magenta");
        if (vga_px_x == 10'd420) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'hF00, "vga_bar5_red");
        if (vga_px_x == 10'd500) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h00F, "vga_bar6_blue");
        if (vga_px_x == 10'd600) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h000, "vga_bar7_black");
        if (vga_px_x == 10'd700) check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h000, "vga_hblank_zero");
      end
      if (!vga_hs) hs_low_cnt = hs_low_cnt + 1;
    end
    check_eq(hs_low_cnt, 32'd96, "vga_hs_width_96");

    // 切换 MODE=1 验证 RGB565 -> RGB444 截位通路 (0x07E0 纯绿 -> 0x0F0)
    vga_px_rgb565 = 16'h07E0;
    vga_mmio_wr(32'h00, 32'b111); // EN=1, MODE=1, IRQ_EN=1
    repeat (6) @(posedge vga_clk);
    #1;
    check_eq({20'd0, vga_r, vga_g, vga_b}, 32'h0F0, "vga_stream_rgb565_green");

    // 跑完剩余 524 行验证 VS 脉宽 (2 行 = 1600 像素) 与 VSYNC 跨时钟域中断
    vs_low_cnt = 0;
    for (k = 0; k < (524 * 800); k = k + 1) begin
      @(posedge vga_clk);
      #1;
      if (!vga_vs) vs_low_cnt = vs_low_cnt + 1;
    end
    check_eq(vs_low_cnt, 32'd1600, "vga_vs_width_2lines");

    repeat (10) @(posedge sys_clk);
    check_eq({31'd0, vga_irq}, 32'd1, "vga_vsync_irq");
    vga_mmio_rd(32'h04, rd_val);
    check_eq(rd_val[31:16], 16'd1, "vga_frame_cnt_1");
    vga_mmio_wr(32'h04, 32'd1); // W1C
    check_eq({31'd0, vga_irq}, 32'd0, "vga_irq_cleared");

    // ------------------------------------------------------------------------
    // Test 3: OV5640 16-bit 寄存器地址 SCCB 读/写验证
    // ------------------------------------------------------------------------
    $display("[stage2] 3/5 Testing ov5640_sccb (16-bit reg read & write)...");
    // 读 OV5640 芯片 ID 高字节 0x300A (应返回 0x56)
    cam_mmio_wr(32'h08, 32'h0000_300A);
    cam_mmio_wr(32'h00, 32'b001010); // CAM_RST_N=1, SCCB_RD=1
    cam_mmio_rd(32'h04, rd_val);
    while (rd_val[0]) cam_mmio_rd(32'h04, rd_val);
    check_eq({31'd0, rd_val[1]}, 32'd0, "sccb_rd_300a_ack");
    cam_mmio_rd(32'h0C, rd_val);
    check_eq(rd_val, 32'h56, "sccb_chip_id_hi");

    // 写 0x3103 = 0x11，再读回核对
    cam_mmio_wr(32'h08, 32'h0011_3103);
    cam_mmio_wr(32'h00, 32'b001001); // CAM_RST_N=1, SCCB_WR=1
    cam_mmio_rd(32'h04, rd_val);
    while (rd_val[0]) cam_mmio_rd(32'h04, rd_val);
    check_eq({31'd0, rd_val[1]}, 32'd0, "sccb_wr_3103_ack");

    cam_mmio_wr(32'h08, 32'h0000_3103);
    cam_mmio_wr(32'h00, 32'b001010); // SCCB_RD=1
    cam_mmio_rd(32'h04, rd_val);
    while (rd_val[0]) cam_mmio_rd(32'h04, rd_val);
    cam_mmio_rd(32'h0C, rd_val);
    check_eq(rd_val, 32'h11, "sccb_rd_3103_match");

    // ------------------------------------------------------------------------
    // Test 4: OV5640 异步 cam_pclk RGB565 采集 + async_fifo + 帧完成中断
    // ------------------------------------------------------------------------
    $display("[stage2] 4/5 Testing ov5640_capture + async_fifo...");
    cam_mmio_wr(32'h00, 32'b111000); // IRQ_EN=1, CAP_EN=1, CAM_RST_N=1
    repeat (6) @(posedge cam_pclk);  // 等待 cap_en 同步进 cam_pclk 域

    // 模拟 1 帧 16 像素 RGB565 数据 (高字节先、低字节后)
    @(negedge cam_pclk); cam_vsync = 1'b0; cam_href = 1'b1;
    for (px_i = 0; px_i < 16; px_i = px_i + 1) begin
      exp_px = 16'hA000 + (px_i * 16'h0111);
      cam_d = exp_px[15:8];
      @(negedge cam_pclk);
      cam_d = exp_px[7:0];
      @(negedge cam_pclk);
    end
    cam_href = 1'b0;
    repeat (3) @(negedge cam_pclk);
    // 帧界 VSYNC 脉冲
    cam_vsync = 1'b1;
    repeat (3) @(negedge cam_pclk);
    cam_vsync = 1'b0;

    repeat (10) @(posedge sys_clk);
    check_eq({31'd0, cam_irq}, 32'd1, "cam_frame_irq");
    cam_mmio_rd(32'h14, rd_val);
    check_eq(rd_val, 32'd1, "cam_frame_cnt_1");

    // 逐像素通过 MMIO +0x10 弹出，核对 2 拍 BRAM 同步读零错位、零丢帧!
    for (px_i = 0; px_i < 16; px_i = px_i + 1) begin
      exp_px = 16'hA000 + (px_i * 16'h0111);
      cam_mmio_rd(32'h10, rd_val);
      check_eq(rd_val, {15'd0, 1'b1, exp_px}, "cam_fifo_px_match");
    end
    // 空读必须返回 valid=0
    cam_mmio_rd(32'h10, rd_val);
    check_eq(rd_val, 32'd0, "cam_fifo_empty_rd");
    cam_mmio_wr(32'h04, 32'b100); // W1C
    check_eq({31'd0, cam_irq}, 32'd0, "cam_irq_cleared");

    // ------------------------------------------------------------------------
    // Test 5: MIG 7 Series 128-bit Native 桥随机反压 + 全 4 lane + 字节写掩码
    // ------------------------------------------------------------------------
    $display("[stage2] 5/5 Testing mig_ddr2_bridge (random app_rdy/wdf_rdy backpressure)...");
    mig_calib = 1'b1;
    // 写入 16 个连续 32-bit 字 (覆盖 4 个 128-bit 突发块 × 全部 4 个 lane)
    for (k = 0; k < 16; k = k + 1) begin
      mig_wr(32'h8000_0000 + (k * 4), 32'hC0DE_0000 ^ (k * 32'h0102_0304), 4'b1111);
    end
    // 部分字节掩码改写 (验证 app_wdf_mask 在各个 lane 均精确有效)
    mig_wr(32'h8000_0000, 32'h0000_5500, 4'b0010); // lane 0 byte 1 -> 0x55
    mig_wr(32'h8000_0004, 32'hAA00_0000, 4'b1000); // lane 1 byte 3 -> 0xAA
    mig_wr(32'h8000_0008, 32'h00BB_0000, 4'b0100); // lane 2 byte 2 -> 0xBB
    mig_wr(32'h8000_000C, 32'h0000_00CC, 4'b0001); // lane 3 byte 0 -> 0xCC

    // 读回校验全部 16 个字 (覆盖全部 4 个 lane 及字节掩码)
    for (k = 0; k < 16; k = k + 1) begin : verify_mig
      reg [31:0] exp_w;
      exp_w = 32'hC0DE_0000 ^ (k * 32'h0102_0304);
      if (k == 0) exp_w[15: 8] = 8'h55;
      if (k == 1) exp_w[31:24] = 8'hAA;
      if (k == 2) exp_w[23:16] = 8'hBB;
      if (k == 3) exp_w[ 7: 0] = 8'hCC;
      mig_rd(32'h8000_0000 + (k * 4), rd_val);
      check_eq(rd_val, exp_w, "mig_ddr2_word_match");
    end

    if (fail_cnt == 0) begin
      $display("=================================================");
      $display("  Stage 2 Peripherals (SPI/VGA/OV5640/MIG) PASS");
      $display("  RESULT : PASS");
    end
    else begin
      $display("  Stage 2 Peripherals FAIL (%0d errors)", fail_cnt);
      $display("  RESULT : FAIL");
    end
    $finish;
  end

endmodule
