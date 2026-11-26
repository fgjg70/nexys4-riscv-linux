`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// rv32_soc.v — Nexys 4 DDR 统一主存 Linux-Ready SoC 顶层（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 组成:
//   - rv32_cpu       : 单发射 RV32IMA + Zicsr + Zicntr + Zifencei + WFI
//   - icache / dcache: 4 KB VIPT 安全缓存 (BRAM 推断 + FENCE.I 清洗 + MMIO 旁路)
//   - soc_bus        : D-Cache/I-Cache 统一总线仲裁与地址译码
//   - bootrom        : 16 KB 片上引导 ROM (0x0000_1000 -> 0x8000_0000)
//   - clint          : 标准 SiFive CLINT (0x0200_0000)
//   - plic           : 标准最小 RISC-V PLIC (0x0C00_0000, Source 1..7)
//   - uart_16550     : 标准 NS16550A 串口 (0x1000_0000, PLIC Source 1)
//   - spi_master     : SPI Mode 0 microSD (0x1000_1000, PLIC Source 2)
//   - vga_ctrl       : 640×480@60Hz 12-bit VGA (0x1000_2000, PLIC Source 3)
//   - ov5640_capture : JA+JB Pmod OV5640 SCCB/DVP (0x1000_3000, PLIC Source 4)
// 外部主存口 (ram_*): 仿真接多拍行为 RAM，Nexys 4 DDR 实板接 MIG 7 Series DDR2 桥。
// ============================================================================

module rv32_soc #(
  parameter [31:0] RESET_PC        = `SOC_ROM_BASE,
  parameter        CLK_HZ          = 75_000_000,
  parameter        BAUD_HZ         = 115_200,
  parameter        CLINT_TICK_DIV  = 1,
  parameter [15:0] SPI_DEFAULT_DIV = 16'd188,     // ~200 kHz @ 75 MHz 满足 SD 初始化
  parameter        SCCB_HZ         = 100_000
)(
  input  wire        clk,
  input  wire        rst,

  // 外部统一主存接口 (0x8000_0000 .. 0x87FF_FFFF, 128 MB DDR2 窗口)
  output wire        ram_req,
  output wire        ram_we,
  output wire [31:0] ram_addr,
  output wire [31:0] ram_wdata,
  output wire [3:0]  ram_wstrb,
  input  wire        ram_ack,
  input  wire [31:0] ram_rdata,
  input  wire        ram_err,

  // 串口物理引脚 (PLIC Source 1)
  output wire        uart_txd,
  input  wire        uart_rxd,

  // SPI microSD 物理引脚 (PLIC Source 2)
  output wire        spi_sck,
  output wire        spi_mosi,
  input  wire        spi_miso,
  output wire        spi_cs_n,
  output wire        sd_reset,
  input  wire        sd_cd_n,

  // 12-bit RGB444 VGA 物理引脚与像素时钟域 (PLIC Source 3)
  input  wire        vga_clk,
  input  wire        vga_rst,
  output wire        vga_px_active,
  output wire [9:0]  vga_px_x,
  output wire [9:0]  vga_px_y,
  input  wire [15:0] vga_px_rgb565,
  output wire [3:0]  vga_r,
  output wire [3:0]  vga_g,
  output wire [3:0]  vga_b,
  output wire        vga_hs,
  output wire        vga_vs,

  // JA+JB Pmod OV5640 摄像头物理引脚 (PLIC Source 4)
  input  wire        cam_pclk,
  input  wire        cam_vsync,
  input  wire        cam_href,
  input  wire [7:0]  cam_d,
  output wire        cam_pwdn,
  output wire        cam_rst_n,
  output wire        cam_sio_c,
  output wire        cam_sio_d_oe,
  input  wire        cam_sio_d_in,
  input  wire        cam_stream_rd_en,
  output wire [15:0] cam_stream_rgb565,
  output wire        cam_stream_empty,

  // 预留外部中断输入 (PLIC Source 5..7)
  input  wire [2:0]  ext_irq_in,

  // 调试与仿真观测输出
  output wire [31:0] dbg_pc,
  output wire [31:0] dbg_id_pc,
  output wire [31:0] dbg_instr,
  output wire        dbg_illegal,
  output wire        uart_tx_pulse,
  output wire [7:0]  uart_tx_byte
);

  // CPU <-> I-Cache
  wire        ibus_req, ibus_kill, ibus_valid, ibus_fault, ibus_page_fault;
  wire [31:0] ibus_addr, ibus_rdata;

  // CPU <-> D-Cache
  wire        dbus_re, dbus_we, dbus_is_amo, dbus_stall, dbus_fault, dbus_page_fault;
  wire [31:0] dbus_addr, dbus_wdata, dbus_rdata;
  wire [3:0]  dbus_wstrb;
  wire        dbus_l0_en;
  wire [31:0] dbus_l0_addr;
  wire        dbus_fast_hit;
  wire [31:0] dbus_fast_rdata;

  // FENCE.I / SFENCE.VMA / Sv32 MMU 握手
  wire        fencei_req, fencei_done, icache_flush;
  wire        sfence_req, satp_flush, sfence_done;
  wire [31:0] sfence_vaddr;
  wire [1:0]  mmu_priv, mmu_mpp;
  wire [31:0] mmu_satp;
  wire        mmu_i_xlate_en, mmu_sum, mmu_mxr, mmu_mprv;

  // Sv32 MMU <-> I-Cache / D-Cache
  wire [31:0] ic_va, itlb_miss_va;
  wire        i_xlate_en, i_utlb_hit, i_utlb_perm_ok, i_utlb_super;
  wire [19:0] i_utlb_ppn_raw, i_utlb_ppn;
  wire        itlb_miss_req, itlb_miss_kill, itlb_serving;
  wire        itlb_resp_valid, itlb_resp_pf, itlb_resp_af;

  wire        d_xlate_en, d_utlb_hit, d_utlb_perm_ok, l0_utlb_ok;
  wire [19:0] d_utlb_ppn, l0_utlb_ppn;
  wire        dtlb_miss_req, dtlb_miss_we, dtlb_miss_amo;
  wire [31:0] dtlb_miss_va, dtlb_resp_pa;
  wire        dtlb_resp_valid, dtlb_resp_pf, dtlb_resp_af;

  wire        ptw_req, ptw_ack, ptw_err;
  wire [31:0] ptw_addr, ptw_rdata;

  // Cache <-> soc_bus
  wire        dc_req, dc_we, dc_ack, dc_err;
  wire [31:0] dc_addr, dc_wdata, dc_rdata;
  wire [3:0]  dc_wstrb;

  wire        ic_req, ic_we, ic_ack, ic_err;
  wire [31:0] ic_addr, ic_wdata, ic_rdata;
  wire [3:0]  ic_wstrb;

  // soc_bus <-> 从外设
  wire        rom_req, rom_ack;
  wire [31:0] rom_addr, rom_rdata;

  wire        clint_req, clint_we, clint_ack;
  wire [31:0] clint_addr, clint_wdata, clint_rdata;
  wire [3:0]  clint_wstrb;

  wire        plic_req, plic_we, plic_ack;
  wire [31:0] plic_addr, plic_wdata, plic_rdata;
  wire [3:0]  plic_wstrb;

  wire        uart_req, uart_we, uart_ack;
  wire [31:0] uart_addr, uart_wdata, uart_rdata;
  wire [3:0]  uart_wstrb;

  wire        spi_req, spi_we, spi_ack;
  wire [31:0] spi_addr, spi_wdata, spi_rdata;
  wire [3:0]  spi_wstrb;

  wire        vga_req, vga_we, vga_ack;
  wire [31:0] vga_addr, vga_wdata, vga_rdata;
  wire [3:0]  vga_wstrb;

  wire        cam_req, cam_we, cam_ack;
  wire [31:0] cam_addr, cam_wdata, cam_rdata;
  wire [3:0]  cam_wstrb;

  // 中断与实时时间
  wire [63:0] mtime_val;
  wire        irq_sw, irq_timer, irq_ext, irq_sext;
  wire        uart_irq, spi_irq, vga_irq, cam_irq;

  rv32_cpu #(
    .ENABLE_SU    (1),
    .RESET_PC     (RESET_PC),
    .MTVEC_RESET  (32'h8000_0100),
    .BTB_IDX_BITS (7),
    .BTB_PC_TOP   (32)
  ) u_cpu (
    .clk             (clk),
    .rst             (rst),
    .ibus_req        (ibus_req),
    .ibus_addr       (ibus_addr),
    .ibus_kill       (ibus_kill),
    .ibus_rdata      (ibus_rdata),
    .ibus_valid      (ibus_valid),
    .ibus_fault      (ibus_fault),
    .ibus_page_fault (ibus_page_fault),
    .dbus_re         (dbus_re),
    .dbus_we         (dbus_we),
    .dbus_is_amo     (dbus_is_amo),
    .dbus_addr       (dbus_addr),
    .dbus_wdata      (dbus_wdata),
    .dbus_wstrb      (dbus_wstrb),
    .dbus_rdata      (dbus_rdata),
    .dbus_stall      (dbus_stall),
    .dbus_fault      (dbus_fault),
    .dbus_page_fault (dbus_page_fault),
    .dbus_l0_en      (dbus_l0_en),
    .dbus_l0_addr    (dbus_l0_addr),
    .dbus_fast_hit   (dbus_fast_hit),
    .dbus_fast_rdata (dbus_fast_rdata),
    .fencei_req      (fencei_req),
    .fencei_done     (fencei_done),
    .sfence_req      (sfence_req),
    .sfence_vaddr    (sfence_vaddr),
    .satp_flush      (satp_flush),
    .sfence_done     (sfence_done),
    .mmu_priv        (mmu_priv),
    .mmu_satp        (mmu_satp),
    .mmu_i_xlate_en  (mmu_i_xlate_en),
    .mmu_sum         (mmu_sum),
    .mmu_mxr         (mmu_mxr),
    .mmu_mprv        (mmu_mprv),
    .mmu_mpp         (mmu_mpp),
    .mtime_i         (mtime_val),
    .irq_sw          (irq_sw),
    .irq_timer       (irq_timer),
    .irq_ext         (irq_ext),
    .irq_sext        (irq_sext),
    .dbg_pc          (dbg_pc),
    .dbg_id_pc       (dbg_id_pc),
    .dbg_instr       (dbg_instr),
    .dbg_illegal     (dbg_illegal),
    .dbg_raddr       (5'd0),
    .dbg_rdata       (),
    .dbg_mem_we      (),
    .dbg_mem_addr    (),
    .dbg_mem_wdata   (),
    .dbg_stall       (),
    .dbg_redirect    ()
  );

  sv32_mmu #(
    .ITLB_ENTRIES (8),
    .DTLB_ENTRIES (8),
    .ITLB_IDX_W   (3),
    .DTLB_IDX_W   (3)
  ) u_mmu (
    .clk             (clk),
    .rst             (rst),
    .mmu_priv        (mmu_priv),
    .mmu_satp        (mmu_satp),
    .mmu_i_xlate_en  (mmu_i_xlate_en),
    .mmu_sum         (mmu_sum),
    .mmu_mxr         (mmu_mxr),
    .mmu_mprv        (mmu_mprv),
    .mmu_mpp         (mmu_mpp),
    .sfence_req      (sfence_req),
    .sfence_vaddr    (sfence_vaddr),
    .satp_flush      (satp_flush),
    .sfence_done     (sfence_done),
    .ic_va           (ic_va),
    .i_xlate_en      (i_xlate_en),
    .i_utlb_hit      (i_utlb_hit),
    .i_utlb_perm_ok  (i_utlb_perm_ok),
    .i_utlb_super    (i_utlb_super),
    .i_utlb_ppn_raw  (i_utlb_ppn_raw),
    .i_utlb_ppn      (i_utlb_ppn),
    .itlb_miss_req   (itlb_miss_req),
    .itlb_miss_va    (itlb_miss_va),
    .itlb_miss_kill  (itlb_miss_kill),
    .itlb_serving    (itlb_serving),
    .itlb_resp_valid (itlb_resp_valid),
    .itlb_resp_pf    (itlb_resp_pf),
    .itlb_resp_af    (itlb_resp_af),
    .dc_va           (dbus_addr),
    .dc_we           (dbus_we),
    .dc_is_amo       (dbus_is_amo),
    .d_xlate_en      (d_xlate_en),
    .d_utlb_hit      (d_utlb_hit),
    .d_utlb_perm_ok  (d_utlb_perm_ok),
    .d_utlb_ppn      (d_utlb_ppn),
    .l0_va           (dbus_l0_addr),
    .l0_utlb_ok      (l0_utlb_ok),
    .l0_utlb_ppn     (l0_utlb_ppn),
    .dtlb_miss_req   (dtlb_miss_req),
    .dtlb_miss_va    (dtlb_miss_va),
    .dtlb_miss_we    (dtlb_miss_we),
    .dtlb_miss_amo   (dtlb_miss_amo),
    .dtlb_resp_valid (dtlb_resp_valid),
    .dtlb_resp_pa    (dtlb_resp_pa),
    .dtlb_resp_pf    (dtlb_resp_pf),
    .dtlb_resp_af    (dtlb_resp_af),
    .ptw_req         (ptw_req),
    .ptw_addr        (ptw_addr),
    .ptw_ack         (ptw_ack),
    .ptw_rdata       (ptw_rdata),
    .ptw_err         (ptw_err)
  );

  icache u_icache (
    .clk             (clk),
    .rst             (rst),
    .flush_all       (icache_flush),
    .ibus_req        (ibus_req),
    .ibus_addr       (ibus_addr),
    .ibus_kill       (ibus_kill),
    .ibus_rdata      (ibus_rdata),
    .ibus_valid      (ibus_valid),
    .ibus_fault      (ibus_fault),
    .ibus_page_fault (ibus_page_fault),
    .ic_va           (ic_va),
    .i_xlate_en      (i_xlate_en),
    .i_utlb_hit      (i_utlb_hit),
    .i_utlb_perm_ok  (i_utlb_perm_ok),
    .i_utlb_super    (i_utlb_super),
    .i_utlb_ppn_raw  (i_utlb_ppn_raw),
    .i_utlb_ppn      (i_utlb_ppn),
    .itlb_miss_req   (itlb_miss_req),
    .itlb_miss_va    (itlb_miss_va),
    .itlb_miss_kill  (itlb_miss_kill),
    .itlb_serving    (itlb_serving),
    .itlb_resp_valid (itlb_resp_valid),
    .itlb_resp_pf    (itlb_resp_pf),
    .itlb_resp_af    (itlb_resp_af),
    .mem_req         (ic_req),
    .mem_we          (ic_we),
    .mem_addr        (ic_addr),
    .mem_wdata       (ic_wdata),
    .mem_wstrb       (ic_wstrb),
    .mem_ack         (ic_ack),
    .mem_rdata       (ic_rdata),
    .mem_err         (ic_err)
  );

  dcache u_dcache (
    .clk             (clk),
    .rst             (rst),
    .dbus_re         (dbus_re),
    .dbus_we         (dbus_we),
    .dbus_is_amo     (dbus_is_amo),
    .dbus_addr       (dbus_addr),
    .dbus_wdata      (dbus_wdata),
    .dbus_wstrb      (dbus_wstrb),
    .dbus_rdata      (dbus_rdata),
    .dbus_stall      (dbus_stall),
    .dbus_fault      (dbus_fault),
    .dbus_page_fault (dbus_page_fault),
    .dbus_l0_en      (dbus_l0_en),
    .dbus_l0_addr    (dbus_l0_addr),
    .dbus_fast_hit   (dbus_fast_hit),
    .dbus_fast_rdata (dbus_fast_rdata),
    .fencei_req      (fencei_req),
    .sfence_req      (sfence_req),
    .fencei_done     (fencei_done),
    .icache_flush    (icache_flush),
    .d_xlate_en      (d_xlate_en),
    .d_utlb_hit      (d_utlb_hit),
    .d_utlb_perm_ok  (d_utlb_perm_ok),
    .d_utlb_ppn      (d_utlb_ppn),
    .l0_utlb_ok      (l0_utlb_ok),
    .l0_utlb_ppn     (l0_utlb_ppn),
    .dtlb_miss_req   (dtlb_miss_req),
    .dtlb_miss_va    (dtlb_miss_va),
    .dtlb_miss_we    (dtlb_miss_we),
    .dtlb_miss_amo   (dtlb_miss_amo),
    .dtlb_resp_valid (dtlb_resp_valid),
    .dtlb_resp_pa    (dtlb_resp_pa),
    .dtlb_resp_pf    (dtlb_resp_pf),
    .dtlb_resp_af    (dtlb_resp_af),
    .ptw_req         (ptw_req),
    .ptw_addr        (ptw_addr),
    .ptw_ack         (ptw_ack),
    .ptw_rdata       (ptw_rdata),
    .ptw_err         (ptw_err),
    .mem_req         (dc_req),
    .mem_we          (dc_we),
    .mem_addr        (dc_addr),
    .mem_wdata       (dc_wdata),
    .mem_wstrb       (dc_wstrb),
    .mem_ack         (dc_ack),
    .mem_rdata       (dc_rdata),
    .mem_err         (dc_err)
  );

  soc_bus u_bus (
    .clk         (clk),
    .rst         (rst),
    .m0_req      (dc_req),
    .m0_we       (dc_we),
    .m0_addr     (dc_addr),
    .m0_wdata    (dc_wdata),
    .m0_wstrb    (dc_wstrb),
    .m0_ack      (dc_ack),
    .m0_rdata    (dc_rdata),
    .m0_err      (dc_err),
    .m1_req      (ic_req),
    .m1_we       (ic_we),
    .m1_addr     (ic_addr),
    .m1_wdata    (ic_wdata),
    .m1_wstrb    (ic_wstrb),
    .m1_ack      (ic_ack),
    .m1_rdata    (ic_rdata),
    .m1_err      (ic_err),
    .rom_req     (rom_req),
    .rom_addr    (rom_addr),
    .rom_ack     (rom_ack),
    .rom_rdata   (rom_rdata),
    .clint_req   (clint_req),
    .clint_we    (clint_we),
    .clint_addr  (clint_addr),
    .clint_wdata (clint_wdata),
    .clint_wstrb (clint_wstrb),
    .clint_ack   (clint_ack),
    .clint_rdata (clint_rdata),
    .plic_req    (plic_req),
    .plic_we     (plic_we),
    .plic_addr   (plic_addr),
    .plic_wdata  (plic_wdata),
    .plic_wstrb  (plic_wstrb),
    .plic_ack    (plic_ack),
    .plic_rdata  (plic_rdata),
    .uart_req    (uart_req),
    .uart_we     (uart_we),
    .uart_addr   (uart_addr),
    .uart_wdata  (uart_wdata),
    .uart_wstrb  (uart_wstrb),
    .uart_ack    (uart_ack),
    .uart_rdata  (uart_rdata),
    .spi_req     (spi_req),
    .spi_we      (spi_we),
    .spi_addr    (spi_addr),
    .spi_wdata   (spi_wdata),
    .spi_wstrb   (spi_wstrb),
    .spi_ack     (spi_ack),
    .spi_rdata   (spi_rdata),
    .vga_req     (vga_req),
    .vga_we      (vga_we),
    .vga_addr    (vga_addr),
    .vga_wdata   (vga_wdata),
    .vga_wstrb   (vga_wstrb),
    .vga_ack     (vga_ack),
    .vga_rdata   (vga_rdata),
    .cam_req     (cam_req),
    .cam_we      (cam_we),
    .cam_addr    (cam_addr),
    .cam_wdata   (cam_wdata),
    .cam_wstrb   (cam_wstrb),
    .cam_ack     (cam_ack),
    .cam_rdata   (cam_rdata),
    .ram_req     (ram_req),
    .ram_we      (ram_we),
    .ram_addr    (ram_addr),
    .ram_wdata   (ram_wdata),
    .ram_wstrb   (ram_wstrb),
    .ram_ack     (ram_ack),
    .ram_rdata   (ram_rdata),
    .ram_err     (ram_err)
  );

  bootrom #(.BASE(`SOC_ROM_BASE), .BYTES(16384)) u_bootrom (
    .clk   (clk),
    .rst   (rst),
    .req   (rom_req),
    .addr  (rom_addr),
    .ack   (rom_ack),
    .rdata (rom_rdata)
  );

  clint #(.TICK_DIV(CLINT_TICK_DIV)) u_clint (
    .clk       (clk),
    .rst       (rst),
    .req       (clint_req),
    .we        (clint_we),
    .addr      (clint_addr),
    .wdata     (clint_wdata),
    .wstrb     (clint_wstrb),
    .ack       (clint_ack),
    .rdata     (clint_rdata),
    .mtime_o   (mtime_val),
    .irq_sw    (irq_sw),
    .irq_timer (irq_timer)
  );

  plic u_plic (
    .clk      (clk),
    .rst      (rst),
    .req      (plic_req),
    .we       (plic_we),
    .addr     (plic_addr),
    .wdata    (plic_wdata),
    .wstrb    (plic_wstrb),
    .ack      (plic_ack),
    .rdata    (plic_rdata),
    .irq_src  ({ext_irq_in, cam_irq, vga_irq, spi_irq, uart_irq}),
    .irq_ext  (irq_ext),
    .irq_sext (irq_sext)
  );

  uart_16550 #(.CLK_HZ(CLK_HZ), .BAUD_HZ(BAUD_HZ)) u_uart (
    .clk           (clk),
    .rst           (rst),
    .req           (uart_req),
    .we            (uart_we),
    .addr          (uart_addr),
    .wdata         (uart_wdata),
    .wstrb         (uart_wstrb),
    .ack           (uart_ack),
    .rdata         (uart_rdata),
    .uart_txd      (uart_txd),
    .uart_rxd      (uart_rxd),
    .irq_o         (uart_irq),
    .tx_push_pulse (uart_tx_pulse),
    .tx_push_byte  (uart_tx_byte)
  );

  spi_master #(.DEFAULT_DIV(SPI_DEFAULT_DIV)) u_spi (
    .clk      (clk),
    .rst      (rst),
    .req      (spi_req),
    .we       (spi_we),
    .addr     (spi_addr),
    .wdata    (spi_wdata),
    .wstrb    (spi_wstrb),
    .ack      (spi_ack),
    .rdata    (spi_rdata),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .spi_cs_n (spi_cs_n),
    .sd_reset (sd_reset),
    .sd_cd_n  (sd_cd_n),
    .irq_o    (spi_irq)
  );

  vga_ctrl u_vga (
    .sys_clk   (clk),
    .sys_rst   (rst),
    .req       (vga_req),
    .we        (vga_we),
    .addr      (vga_addr),
    .wdata     (vga_wdata),
    .wstrb     (vga_wstrb),
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

  ov5640_capture #(
    .CLK_HZ  (CLK_HZ),
    .SCCB_HZ (SCCB_HZ)
  ) u_cam (
    .sys_clk       (clk),
    .sys_rst       (rst),
    .req           (cam_req),
    .we            (cam_we),
    .addr          (cam_addr),
    .wdata         (cam_wdata),
    .wstrb         (cam_wstrb),
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
    .sio_d_in      (cam_sio_d_in),
    .stream_rd_en  (cam_stream_rd_en),
    .stream_rgb565 (cam_stream_rgb565),
    .stream_empty  (cam_stream_empty)
  );

endmodule
