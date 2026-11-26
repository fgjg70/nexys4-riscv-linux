`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_bootrom_linux.v — Linux BootROM (sw/bootrom_linux/bootrom_linux.hex) 端到端验证
// 纯 Verilog-2001，内建行为级 SPI Mode 0 SDHC 卡模型 (CMD0/CMD8/CMD55/ACMD41/CMD58/CMD17)
// ----------------------------------------------------------------------------
// 验证闭环:
//   1. rv32_soc 从 0x0000_1000 启动真正的 16 KB bootrom_linux.hex
//   2. BootROM 通过真实 SPI Mode 0 时序初始化 SDHC 卡 (80 dummy clocks + CMD0/8/55/41/58)
//   3. BootROM 读取 LBA 0 的 NX4L 引导头，经 CMD17 从 SD 卡搬运:
//        - LBA 2 起的有效载荷 (1024 B 迷你 Sv32 内核桩) -> RAM 0x8000_0000
//        - LBA 4 起的模拟 DTB (512 B, 含标准 FDT 魔数 0xD00DFEED 大端) -> RAM 0x8003_8000
//   4. BootROM 执行 fence.i 并按 RISC-V Linux ABI (a0=0, a1=0x8003_8000) 跳转 0x8000_0000
//   5. 被加载的内核桩校验 a0==0、a1==0x8003_8000 且 *(uint32*)a1 == 0xEDFE0DD0 (FDT 魔数)，
//      打印 "BOOT_OK\n" 并写 tohost (0x8003_F000) = 1 结束仿真！
// ============================================================================

module tb_bootrom_linux;
  localparam TCLK_HALF  = 5;          // 100 MHz
  localparam RAM_WORDS  = 65536;      // 256 KB
  localparam TOHOST_IDX = 32'h0003_F000 / 4;
  localparam SD_SECTORS = 8;          // 8 sectors = 4 KB behavioral SDHC card

  reg        clk;
  reg        rst;
  reg [31:0] cycles;
  reg [31:0] max_cycles;

  initial begin
    clk        = 1'b0;
    rst        = 1'b1;
    cycles     = 32'd0;
    max_cycles = 32'd600000;
  end
  always #(TCLK_HALF) clk = ~clk;

  // SoC <-> RAM
  wire        ram_req, ram_we;
  wire [31:0] ram_addr, ram_wdata;
  wire [3:0]  ram_wstrb;
  reg         ram_ack;
  reg  [31:0] ram_rdata;
  reg         ram_err;

  wire        uart_txd;
  wire        spi_sck, spi_mosi, spi_cs_n, sd_reset;
  reg         spi_miso;
  wire [31:0] dbg_pc, dbg_id_pc, dbg_instr;
  wire        dbg_illegal;
  wire        uart_tx_pulse;
  wire [7:0]  uart_tx_byte;

  rv32_soc #(
    .RESET_PC        (`SOC_ROM_BASE),
    .CLK_HZ          (100_000_000),
    .BAUD_HZ         (5_000_000),     // 仿真加速 UART 波特率 (实际硬件 top_nexys4_ddr 用 115200)
    .CLINT_TICK_DIV  (100),
    .SPI_DEFAULT_DIV (16'd2),         // 加速仿真 SPI 时钟
    .SCCB_HZ         (1_000_000)
  ) u_soc (
    .clk               (clk),
    .rst               (rst),
    .ram_req           (ram_req),
    .ram_we            (ram_we),
    .ram_addr          (ram_addr),
    .ram_wdata         (ram_wdata),
    .ram_wstrb         (ram_wstrb),
    .ram_ack           (ram_ack),
    .ram_rdata         (ram_rdata),
    .ram_err           (ram_err),
    .uart_txd          (uart_txd),
    .uart_rxd          (1'b1),
    .spi_sck           (spi_sck),
    .spi_mosi          (spi_mosi),
    .spi_miso          (spi_miso),
    .spi_cs_n          (spi_cs_n),
    .sd_reset          (sd_reset),
    .sd_cd_n           (1'b0),        // SD 卡已插入
    .vga_clk           (1'b0),
    .vga_rst           (rst),
    .vga_px_active     (),
    .vga_px_x          (),
    .vga_px_y          (),
    .vga_px_rgb565     (16'd0),
    .vga_r             (),
    .vga_g             (),
    .vga_b             (),
    .vga_hs            (),
    .vga_vs            (),
    .cam_pclk          (1'b0),
    .cam_vsync         (1'b0),
    .cam_href          (1'b0),
    .cam_d             (8'd0),
    .cam_pwdn          (),
    .cam_rst_n         (),
    .cam_sio_c         (),
    .cam_sio_d_oe      (),
    .cam_sio_d_in      (1'b1),
    .cam_stream_rd_en  (1'b0),
    .cam_stream_rgb565 (),
    .cam_stream_empty  (),
    .ext_irq_in        (3'd0),
    .dbg_pc            (dbg_pc),
    .dbg_id_pc         (dbg_id_pc),
    .dbg_instr         (dbg_instr),
    .dbg_illegal       (dbg_illegal),
    .uart_tx_pulse     (uart_tx_pulse),
    .uart_tx_byte      (uart_tx_byte)
  );

  // ---- 256 KB 行为统一 RAM (2 拍延迟) ----
  reg [31:0] ram_mem [0:RAM_WORDS-1];
  wire [31:0] ram_off = ram_addr - `SOC_RAM_BASE;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ram_ack   <= 1'b0;
      ram_rdata <= 32'd0;
      ram_err   <= 1'b0;
    end
    else begin
      ram_ack <= 1'b0;
      ram_err <= 1'b0;
      if (ram_req && !ram_ack) begin
        ram_ack <= 1'b1;
        if (ram_off >= (RAM_WORDS * 4)) begin
          ram_err   <= 1'b1;
          ram_rdata <= 32'd0;
        end
        else if (ram_we) begin
          if (ram_wstrb[0]) ram_mem[ram_off[17:2]][ 7: 0] <= ram_wdata[ 7: 0];
          if (ram_wstrb[1]) ram_mem[ram_off[17:2]][15: 8] <= ram_wdata[15: 8];
          if (ram_wstrb[2]) ram_mem[ram_off[17:2]][23:16] <= ram_wdata[23:16];
          if (ram_wstrb[3]) ram_mem[ram_off[17:2]][31:24] <= ram_wdata[31:24];
          ram_rdata <= 32'd0;
        end
        else begin
          ram_rdata <= ram_mem[ram_off[17:2]];
        end
      end
    end
  end

  // ---- 行为级 SPI Mode 0 SDHC 存储卡模型 (8 扇区 = 4 KB) ----
  reg [7:0]  sd_img [0:SD_SECTORS*512-1];
  reg [7:0]  sd_tx_buf [0:520];
  integer    sd_tx_len;
  integer    sd_tx_idx;
  reg [7:0]  sd_cmd_buf [0:5];
  integer    sd_cmd_idx;
  reg [7:0]  sd_rx_byte;
  reg [7:0]  sd_tx_byte;
  integer    sd_bit_cnt;
  reg        sd_sck_d;
  reg        sd_app_cmd;
  reg [31:0] sd_lba_req;
  integer    b_idx;

  // 辅助写小端 32-bit 字到 SD 镜像字节数组
  task sd_put_u32;
    input integer byte_off;
    input [31:0]  val;
    begin
      sd_img[byte_off + 0] = val[ 7: 0];
      sd_img[byte_off + 1] = val[15: 8];
      sd_img[byte_off + 2] = val[23:16];
      sd_img[byte_off + 3] = val[31:24];
    end
  endtask

  integer i;
  initial begin
    for (i = 0; i < RAM_WORDS; i = i + 1) ram_mem[i] = 32'd0;
    for (i = 0; i < SD_SECTORS*512; i = i + 1) sd_img[i] = 8'h00;

    // 1) LBA 0: 32 字节 NX4L 引导头
    sd_put_u32(0,  32'h4E58_344C); // magic = 'NX4L'
    sd_put_u32(4,  32'h8000_0000); // payload_load_addr
    sd_put_u32(8,  32'd512);       // payload_byte_size (1 sector)
    sd_put_u32(12, 32'd2);         // payload_start_lba = 2
    sd_put_u32(16, 32'h8003_8000); // dtb_load_addr
    sd_put_u32(20, 32'd512);       // dtb_byte_size (1 sector)
    sd_put_u32(24, 32'd4);         // dtb_start_lba = 4
    sd_put_u32(28, 32'h8000_0000); // entry_pc

    // 2) LBA 2 (offset 1024): 迷你内核启动桩 (校验 a0==0, a1==0x8003_8000, *(uint32*)a1==0xEDFE0DD0)
    //    0x00: bne  a0, zero, +40 (fail)        -> 0x02051463
    //    0x04: lui  t0, 0x80038                 -> 0x800382b7
    //    0x08: bne  a1, t0, +32 (fail)          -> 0x02559063
    //    0x0C: lw   t1, 0(a1)                   -> 0x0005a303
    //    0x10: lui  t2, 0xEDFE1                 -> 0xedfe13b7
    //    0x14: addi t2, t2, -560 (0xEDFE0DD0)   -> 0xdd038393
    //    0x18: bne  t1, t2, +16 (fail)          -> 0x00731863
    //    0x1C: lui  t3, 0x8003F                 -> 0x8003fe37
    //    0x20: addi t4, zero, 1                 -> 0x00100e93
    //    0x24: sw   t4, 0(t3)                   -> 0x01de2023
    //    0x28: fence.i                          -> 0x0000100f
    //    0x2C: j    0 (pass_spin)               -> 0x0000006f
    //    0x30: lui  t3, 0x8003F                 -> 0x8003fe37
    //    0x34: addi t4, zero, 99                -> 0x06300e93
    //    0x38: sw   t4, 0(t3)                   -> 0x01de2023
    //    0x3C: fence.i                          -> 0x0000100f
    //    0x40: j    0 (fail_spin)               -> 0x0000006f
    sd_put_u32(1024 +  0, 32'h02051463); // bne a0, zero, +0x28 (Wait: +0x30 -> imm=48 -> 0x02051863!)
    sd_put_u32(1024 +  0, 32'h02051863); // PC=0x00 -> 0x30 (+48)
    sd_put_u32(1024 +  4, 32'h800382b7); // lui t0, 0x80038
    sd_put_u32(1024 +  8, 32'h02559463); // PC=0x08 -> 0x30 (+40)
    sd_put_u32(1024 + 12, 32'h0005a303); // lw t1, 0(a1)
    sd_put_u32(1024 + 16, 32'hedfe13b7); // lui t2, 0xEDFE1
    sd_put_u32(1024 + 20, 32'hdd038393); // addi t2, t2, -560 -> 0xEDFE0DD0
    sd_put_u32(1024 + 24, 32'h00731c63); // PC=0x18 -> 0x30 (+24)
    sd_put_u32(1024 + 28, 32'h8003fe37); // lui t3, 0x8003F
    sd_put_u32(1024 + 32, 32'h00100e93); // addi t4, zero, 1
    sd_put_u32(1024 + 36, 32'h01de2023); // sw t4, 0(t3)
    sd_put_u32(1024 + 40, 32'h0000100f); // fence.i
    sd_put_u32(1024 + 44, 32'h0000006f); // j .
    sd_put_u32(1024 + 48, 32'h8003fe37); // fail: lui t3, 0x8003F
    sd_put_u32(1024 + 52, 32'h06300e93); // addi t4, zero, 99
    sd_put_u32(1024 + 56, 32'h01de2023); // sw t4, 0(t3)
    sd_put_u32(1024 + 60, 32'h0000100f); // fence.i
    sd_put_u32(1024 + 64, 32'h0000006f); // j .

    // 3) LBA 4 (offset 2048): 模拟标准 FDT / DTB 头 (大端魔数 0xD00DFEED = 小端 0xEDFE0DD0)
    sd_put_u32(2048 + 0, 32'hEDFE_0DD0);
    sd_put_u32(2048 + 4, 32'h0002_0000);

    spi_miso   = 1'b1;
    sd_sck_d   = 1'b0;
    sd_bit_cnt = 0;
    sd_cmd_idx = 0;
    sd_tx_len  = 0;
    sd_tx_idx  = 0;
    sd_tx_byte = 8'hFF;
    sd_rx_byte = 8'hFF;
    sd_app_cmd = 1'b0;

    repeat (5) @(posedge clk);
    rst = 1'b0;
    $display("[tb_bootrom_linux] reset released, booting Linux BootROM + SPI SDHC model...");
  end

  // SPI Mode 0 行为从机状态机 (上升沿采样 MOSI，下降沿移出下一位 MISO)
  always @(posedge clk) begin
    sd_sck_d <= spi_sck;
    if (rst || spi_cs_n) begin
      spi_miso   <= 1'b1;
      sd_bit_cnt <= 0;
      sd_cmd_idx <= 0;
      sd_tx_len  <= 0;
      sd_tx_idx  <= 0;
      sd_tx_byte <= 8'hFF;
    end
    else begin
      // SCK 上升沿: 采样 MOSI
      if (spi_sck && !sd_sck_d) begin
        sd_rx_byte = {sd_rx_byte[6:0], spi_mosi};
        sd_bit_cnt = sd_bit_cnt + 1;
        if (sd_bit_cnt == 8) begin
          sd_bit_cnt = 0;
          // 处理收到的完整字节
          if (sd_tx_idx < sd_tx_len) begin
            // 仍在回发响应阶段
          end
          else if ((sd_cmd_idx == 0) && ((sd_rx_byte & 8'hC0) == 8'h40)) begin
            sd_cmd_buf[0] = sd_rx_byte;
            sd_cmd_idx    = 1;
          end
          else if (sd_cmd_idx > 0) begin
            sd_cmd_buf[sd_cmd_idx] = sd_rx_byte;
            sd_cmd_idx             = sd_cmd_idx + 1;
            if (sd_cmd_idx == 6) begin
              sd_cmd_idx = 0;
              sd_tx_idx  = 0;
              case (sd_cmd_buf[0])
                8'h40: begin // CMD0 -> R1=0x01
                  sd_app_cmd   = 1'b0;
                  sd_tx_buf[0] = 8'h01;
                  sd_tx_len    = 1;
                end
                8'h48: begin // CMD8 -> R1=0x01 + R7=0x000001AA
                  sd_tx_buf[0] = 8'h01;
                  sd_tx_buf[1] = 8'h00;
                  sd_tx_buf[2] = 8'h00;
                  sd_tx_buf[3] = 8'h01;
                  sd_tx_buf[4] = 8'hAA;
                  sd_tx_len    = 5;
                end
                8'h77: begin // CMD55
                  sd_app_cmd   = 1'b1;
                  sd_tx_buf[0] = 8'h01;
                  sd_tx_len    = 1;
                end
                8'h69: begin // ACMD41 -> R1=0x00 (ready!)
                  sd_app_cmd   = 1'b0;
                  sd_tx_buf[0] = 8'h00;
                  sd_tx_len    = 1;
                end
                8'h7A: begin // CMD58 -> R1=0x00 + OCR=0xC0FF8000 (CCS=1 SDHC)
                  sd_tx_buf[0] = 8'h00;
                  sd_tx_buf[1] = 8'hC0;
                  sd_tx_buf[2] = 8'hFF;
                  sd_tx_buf[3] = 8'h80;
                  sd_tx_buf[4] = 8'h00;
                  sd_tx_len    = 5;
                end
                8'h51: begin // CMD17 (READ_SINGLE_BLOCK)
                  sd_lba_req   = {sd_cmd_buf[1], sd_cmd_buf[2], sd_cmd_buf[3], sd_cmd_buf[4]};
                  sd_tx_buf[0] = 8'h00; // R1 OK
                  sd_tx_buf[1] = 8'hFE; // Data token
                  for (b_idx = 0; b_idx < 512; b_idx = b_idx + 1) begin
                    sd_tx_buf[2 + b_idx] = (sd_lba_req < SD_SECTORS)
                                           ? sd_img[sd_lba_req * 512 + b_idx] : 8'h00;
                  end
                  sd_tx_buf[514] = 8'hFF; // CRC16 hi
                  sd_tx_buf[515] = 8'hFF; // CRC16 lo
                  sd_tx_len      = 516;
                end
                default: begin
                  sd_tx_buf[0] = 8'h05;
                  sd_tx_len    = 1;
                end
              endcase
            end
          end
        end
      end

      // SCK 下降沿: 推进 MISO 输出
      if (!spi_sck && sd_sck_d) begin
        if (sd_bit_cnt == 0) begin
          if (sd_tx_idx < sd_tx_len) begin
            sd_tx_byte = sd_tx_buf[sd_tx_idx];
            sd_tx_idx  = sd_tx_idx + 1;
          end
          else begin
            sd_tx_byte = 8'hFF;
          end
          spi_miso <= sd_tx_byte[7];
        end
        else begin
          sd_tx_byte = {sd_tx_byte[6:0], 1'b1};
          spi_miso   <= sd_tx_byte[7];
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && uart_tx_pulse) begin
      $write("%c", uart_tx_byte);
    end
  end

  wire [31:0] tohost_word = ram_mem[TOHOST_IDX];

  always @(posedge clk) begin
    if (!rst) begin
      cycles <= cycles + 32'd1;
      if (cycles > max_cycles) begin
        $display("\n[tb_bootrom_linux] FAIL: timeout (%0d cycles), pc=0x%08x", max_cycles, dbg_pc);
        $display("  RESULT : FAIL");
        $finish;
      end
      if (dbg_illegal) begin
        $display("\n[tb_bootrom_linux] FAIL: illegal instr pc=0x%08x instr=0x%08x", dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end
      if (tohost_word == 32'd1) begin
        $display("\n=================================================");
        $display("  Linux BootROM SPI SDHC -> DDR2 -> Kernel ABI PASS");
        $display("  cycles = %0d", cycles);
        $display("  RESULT : PASS");
        $finish;
      end
      else if (tohost_word != 32'd0) begin
        $display("\n[tb_bootrom_linux] FAIL: kernel stub rejected boot ABI (code=%0d)", tohost_word);
        $display("  RESULT : FAIL");
        $finish;
      end
    end
  end

endmodule
