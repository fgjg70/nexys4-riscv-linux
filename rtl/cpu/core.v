`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// core.v — 向后兼容基线包装层 (rv32_cpu + 片上 imem/dmem + 外部 MMIO)
// 纯 Verilog-2001，保持端口与原有 tb_core / tb_soc / tb_sw 100% 兼容。
// 新 SoC (Cache + 统一 DDR2 + CLINT/PLIC/16550) 请直接例化 rtl/cpu/rv32_cpu.v。
// ============================================================================

module core (
  input  wire        clk,
  input  wire        rst,

  // 调试观测接口
  output wire [31:0] dbg_pc,
  output wire [31:0] dbg_id_pc,
  output wire [31:0] dbg_instr,
  output wire        dbg_illegal,
  input  wire [4:0]  dbg_raddr,
  output wire [31:0] dbg_rdata,

  output wire        dbg_mem_we,
  output wire [31:0] dbg_mem_addr,
  output wire [31:0] dbg_mem_wdata,

  output wire        dbg_stall,
  output wire        dbg_redirect,

  // 外部 MMIO 总线
  output wire        ext_we,
  output wire        ext_re,
  output wire [31:0] ext_addr,
  output wire [31:0] ext_wdata,
  output wire [3:0]  ext_wstrb,
  input  wire [31:0] ext_rdata,

  // 定时器中断请求 (电平 -> mip.MTIP)
  input  wire        irq_timer
);

  wire        ibus_req, ibus_kill;
  wire [31:0] ibus_addr, imem_rdata;
  wire        dbus_re, dbus_we;
  wire [31:0] dbus_addr, dbus_wdata;
  wire [3:0]  dbus_wstrb;
  wire [31:0] dmem_rdata, dmem_rdata_g;
  wire        fencei_req;

  // 本地 64 位计数为 CSR time/timeh 提供时间源 (兼容无 CLINT 时的裸机仿真)
  reg [63:0] local_mtime;
  always @(posedge clk or posedge rst) begin
    if (rst) local_mtime <= 64'd0;
    else     local_mtime <= local_mtime + 64'd1;
  end

  // DMEM / 外部 MMIO 译码 (保持与原 core.v 逐拍一致)
  wire sel_dmem  = (dbus_addr >= `DMEM_BASE) && (dbus_addr < (`DMEM_BASE + `DMEM_BYTES));
  wire dmem_we_g = dbus_we && sel_dmem;

  reg        sel_dmem_r;
  reg [31:0] ext_rdata_r;
  always @(posedge clk) begin
    ext_rdata_r <= ext_rdata;
    sel_dmem_r  <= sel_dmem;
  end
  assign dmem_rdata_g = sel_dmem_r ? dmem_rdata : ext_rdata_r;

  assign ext_we    = dbus_we && !sel_dmem && (dbus_wstrb != 4'b0000);
  assign ext_re    = dbus_re && !sel_dmem;
  assign ext_addr  = dbus_addr;
  assign ext_wdata = dbus_wdata;
  assign ext_wstrb = dbus_wstrb;

  rv32_cpu #(
    .RESET_PC     (`PC_RESET),
    .MTVEC_RESET  (32'h8000_0100),
    .BTB_IDX_BITS (9),
    .BTB_PC_TOP   (32)
  ) u_cpu (
    .clk           (clk),
    .rst           (rst),
    .ibus_req      (ibus_req),
    .ibus_addr     (ibus_addr),
    .ibus_kill     (ibus_kill),
    .ibus_rdata    (imem_rdata),
    .ibus_valid    (1'b1),
    .ibus_fault    (1'b0),
    .dbus_re       (dbus_re),
    .dbus_we       (dbus_we),
    .dbus_addr     (dbus_addr),
    .dbus_wdata    (dbus_wdata),
    .dbus_wstrb    (dbus_wstrb),
    .dbus_rdata    (dmem_rdata_g),
    .dbus_stall    (1'b0),
    .dbus_fault    (1'b0),
    .fencei_req    (fencei_req),
    .fencei_done   (1'b1),
    .mtime_i       (local_mtime),
    .irq_sw        (1'b0),
    .irq_timer     (irq_timer),
    .irq_ext       (1'b0),
    .dbg_pc        (dbg_pc),
    .dbg_id_pc     (dbg_id_pc),
    .dbg_instr     (dbg_instr),
    .dbg_illegal   (dbg_illegal),
    .dbg_raddr     (dbg_raddr),
    .dbg_rdata     (dbg_rdata),
    .dbg_mem_we    (dbg_mem_we),
    .dbg_mem_addr  (dbg_mem_addr),
    .dbg_mem_wdata (dbg_mem_wdata),
    .dbg_stall     (dbg_stall),
    .dbg_redirect  (dbg_redirect)
  );

  imem #(.BASE(`IMEM_BASE), .BYTES(`IMEM_BYTES)) u_imem (
    .clk   (clk),
    .addr  (ibus_addr),
    .rdata (imem_rdata)
  );

  dmem #(.BASE(`DMEM_BASE), .BYTES(`DMEM_BYTES)) u_dmem (
    .clk   (clk),
    .addr  (dbus_addr),
    .wdata (dbus_wdata),
    .wstrb (dbus_wstrb),
    .we    (dmem_we_g),
    .rdata (dmem_rdata)
  );

endmodule
