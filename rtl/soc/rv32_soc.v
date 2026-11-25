`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// rv32_soc.v — 路线 A1 统一主存 Linux-Ready SoC 顶层（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 组成:
//   - rv32_cpu   : 单发射 RV32IMA + Zicsr + Zicntr + Zifencei + WFI (复位入口 0x0000_1000)
//   - icache     : 4 KB VIPT 安全直接映射指令缓存 (支持 FENCE.I 单拍失效)
//   - dcache     : 4 KB VIPT 安全回写数据缓存 + MMIO 旁路 + FENCE.I 脏行清洗
//   - soc_bus    : D-Cache/I-Cache 统一总线仲裁与地址译码
//   - bootrom    : 16 KB 片上引导 ROM (0x0000_1000 -> 0x8000_0000)
//   - clint      : 标准 SiFive CLINT (0x0200_0000)
//   - plic       : 标准最小 RISC-V PLIC (0x0C00_0000)
//   - uart_16550 : 标准 NS16550A 串口 (0x1000_0000, IRQ -> PLIC Source 1)
// 外部主存口 (ram_*): 仿真接多拍行为 RAM，Nexys 4 DDR 实板接 MIG 7 Series DDR2 桥。
// ============================================================================

module rv32_soc #(
  parameter [31:0] RESET_PC       = `SOC_ROM_BASE,
  parameter        CLK_HZ         = 50_000_000,
  parameter        BAUD_HZ        = 115_200,
  parameter        CLINT_TICK_DIV = 1
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

  // 串口物理引脚
  output wire        uart_txd,
  input  wire        uart_rxd,

  // 预留外部中断输入 (Source 2..7: SPI-SD, VGA VSYNC, OV5640 VSYNC 等)
  input  wire [5:0]  ext_irq_in,

  // 调试与仿真观测输出
  output wire [31:0] dbg_pc,
  output wire [31:0] dbg_id_pc,
  output wire [31:0] dbg_instr,
  output wire        dbg_illegal,
  output wire        uart_tx_pulse,
  output wire [7:0]  uart_tx_byte
);

  // CPU <-> I-Cache
  wire        ibus_req, ibus_kill, ibus_valid, ibus_fault;
  wire [31:0] ibus_addr, ibus_rdata;

  // CPU <-> D-Cache
  wire        dbus_re, dbus_we, dbus_stall, dbus_fault;
  wire [31:0] dbus_addr, dbus_wdata, dbus_rdata;
  wire [3:0]  dbus_wstrb;

  // FENCE.I 握手
  wire        fencei_req, fencei_done, icache_flush;

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

  // 中断与实时时间
  wire [63:0] mtime_val;
  wire        irq_sw, irq_timer, irq_ext, uart_irq;

  rv32_cpu #(
    .RESET_PC     (RESET_PC),
    .MTVEC_RESET  (32'h8000_0100),
    .BTB_IDX_BITS (9),
    .BTB_PC_TOP   (32)
  ) u_cpu (
    .clk           (clk),
    .rst           (rst),
    .ibus_req      (ibus_req),
    .ibus_addr     (ibus_addr),
    .ibus_kill     (ibus_kill),
    .ibus_rdata    (ibus_rdata),
    .ibus_valid    (ibus_valid),
    .ibus_fault    (ibus_fault),
    .dbus_re       (dbus_re),
    .dbus_we       (dbus_we),
    .dbus_addr     (dbus_addr),
    .dbus_wdata    (dbus_wdata),
    .dbus_wstrb    (dbus_wstrb),
    .dbus_rdata    (dbus_rdata),
    .dbus_stall    (dbus_stall),
    .dbus_fault    (dbus_fault),
    .fencei_req    (fencei_req),
    .fencei_done   (fencei_done),
    .mtime_i       (mtime_val),
    .irq_sw        (irq_sw),
    .irq_timer     (irq_timer),
    .irq_ext       (irq_ext),
    .dbg_pc        (dbg_pc),
    .dbg_id_pc     (dbg_id_pc),
    .dbg_instr     (dbg_instr),
    .dbg_illegal   (dbg_illegal),
    .dbg_raddr     (5'd0),
    .dbg_rdata     (),
    .dbg_mem_we    (),
    .dbg_mem_addr  (),
    .dbg_mem_wdata (),
    .dbg_stall     (),
    .dbg_redirect  ()
  );

  icache u_icache (
    .clk        (clk),
    .rst        (rst),
    .flush_all  (icache_flush),
    .ibus_req   (ibus_req),
    .ibus_addr  (ibus_addr),
    .ibus_kill  (ibus_kill),
    .ibus_rdata (ibus_rdata),
    .ibus_valid (ibus_valid),
    .ibus_fault (ibus_fault),
    .mem_req    (ic_req),
    .mem_we     (ic_we),
    .mem_addr   (ic_addr),
    .mem_wdata  (ic_wdata),
    .mem_wstrb  (ic_wstrb),
    .mem_ack    (ic_ack),
    .mem_rdata  (ic_rdata),
    .mem_err    (ic_err)
  );

  dcache u_dcache (
    .clk          (clk),
    .rst          (rst),
    .dbus_re      (dbus_re),
    .dbus_we      (dbus_we),
    .dbus_addr    (dbus_addr),
    .dbus_wdata   (dbus_wdata),
    .dbus_wstrb   (dbus_wstrb),
    .dbus_rdata   (dbus_rdata),
    .dbus_stall   (dbus_stall),
    .dbus_fault   (dbus_fault),
    .fencei_req   (fencei_req),
    .fencei_done  (fencei_done),
    .icache_flush (icache_flush),
    .mem_req      (dc_req),
    .mem_we       (dc_we),
    .mem_addr     (dc_addr),
    .mem_wdata    (dc_wdata),
    .mem_wstrb    (dc_wstrb),
    .mem_ack      (dc_ack),
    .mem_rdata    (dc_rdata),
    .mem_err      (dc_err)
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
    .clk     (clk),
    .rst     (rst),
    .req     (plic_req),
    .we      (plic_we),
    .addr    (plic_addr),
    .wdata   (plic_wdata),
    .wstrb   (plic_wstrb),
    .ack     (plic_ack),
    .rdata   (plic_rdata),
    .irq_src ({ext_irq_in, uart_irq}),
    .irq_ext (irq_ext)
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

endmodule
