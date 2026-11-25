`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// soc_bus.v — 2 主 (D-Cache / I-Cache) 多从统一总线仲裁与地址译码器
// 纯 Verilog-2001，标准 32-bit req/ack/err 事务握手，杜绝组合环路。
// ----------------------------------------------------------------------------
// 地址空间分配 (与 rv32_defs.vh 对齐):
//   0x0000_1000 .. 0x0000_4FFF : BootROM (16 KB, 只读, 写返回 err=1)
//   0x0200_0000 .. 0x0200_FFFF : CLINT
//   0x0C00_0000 .. 0x0C3F_FFFF : PLIC
//   0x1000_0000 .. 0x1000_0FFF : NS16550A UART
//   0x8000_0000 .. 0x87FF_FFFF : 128 MB 统一主存 (仿真接行为 RAM, 上板接 MIG DDR2)
//   其余任意未映射地址         : 单拍返回 ack=1, err=1 (触发 CPU 精确访问异常)
// ============================================================================

module soc_bus (
  input  wire        clk,
  input  wire        rst,

  // Master 0: D-Cache (高优先级，避免数据通道反压流水线)
  input  wire        m0_req,
  input  wire        m0_we,
  input  wire [31:0] m0_addr,
  input  wire [31:0] m0_wdata,
  input  wire [3:0]  m0_wstrb,
  output wire        m0_ack,
  output wire [31:0] m0_rdata,
  output wire        m0_err,

  // Master 1: I-Cache
  input  wire        m1_req,
  input  wire        m1_we,
  input  wire [31:0] m1_addr,
  input  wire [31:0] m1_wdata,
  input  wire [3:0]  m1_wstrb,
  output wire        m1_ack,
  output wire [31:0] m1_rdata,
  output wire        m1_err,

  // Slave 0: BootROM
  output wire        rom_req,
  output wire [31:0] rom_addr,
  input  wire        rom_ack,
  input  wire [31:0] rom_rdata,

  // Slave 1: CLINT
  output wire        clint_req,
  output wire        clint_we,
  output wire [31:0] clint_addr,
  output wire [31:0] clint_wdata,
  output wire [3:0]  clint_wstrb,
  input  wire        clint_ack,
  input  wire [31:0] clint_rdata,

  // Slave 2: PLIC
  output wire        plic_req,
  output wire        plic_we,
  output wire [31:0] plic_addr,
  output wire [31:0] plic_wdata,
  output wire [3:0]  plic_wstrb,
  input  wire        plic_ack,
  input  wire [31:0] plic_rdata,

  // Slave 3: NS16550A UART
  output wire        uart_req,
  output wire        uart_we,
  output wire [31:0] uart_addr,
  output wire [31:0] uart_wdata,
  output wire [3:0]  uart_wstrb,
  input  wire        uart_ack,
  input  wire [31:0] uart_rdata,

  // Slave 4: 统一主存 (DDR2 / RAM)
  output wire        ram_req,
  output wire        ram_we,
  output wire [31:0] ram_addr,
  output wire [31:0] ram_wdata,
  output wire [3:0]  ram_wstrb,
  input  wire        ram_ack,
  input  wire [31:0] ram_rdata,
  input  wire        ram_err
);

  // 事务锁定仲裁: 一旦发起请求就锁定当前主设备直到收到从设备 ack
  reg  busy;
  reg  owner;    // 0 = m0 (D-Cache), 1 = m1 (I-Cache)

  wire grant_m0 = busy ? (owner == 1'b0) : m0_req;
  wire grant_m1 = busy ? (owner == 1'b1) : (!m0_req && m1_req);

  wire        bus_req   = grant_m0 ? m0_req   : (grant_m1 ? m1_req   : 1'b0);
  wire        bus_we    = grant_m0 ? m0_we    : m1_we;
  wire [31:0] bus_addr  = grant_m0 ? m0_addr  : m1_addr;
  wire [31:0] bus_wdata = grant_m0 ? m0_wdata : m1_wdata;
  wire [3:0]  bus_wstrb = grant_m0 ? m0_wstrb : m1_wstrb;

  // 地址空间译码
  wire sel_rom   = (bus_addr >= `SOC_ROM_BASE) && (bus_addr < (`SOC_ROM_BASE + 32'h0000_4000));
  wire sel_clint = (bus_addr[31:16] == 16'h0200);
  wire sel_plic  = (bus_addr[31:22] == 10'b0000_1100_00); // 0x0C00_0000 .. 0x0C3F_FFFF
  wire sel_uart  = (bus_addr[31:12] == 20'h10000);        // 0x1000_0000 .. 0x1000_0FFF
  wire sel_ram   = ((bus_addr & `SOC_RAM_MASK) == `SOC_RAM_BASE);

  wire rom_wr_err = bus_req && sel_rom && bus_we;
  wire unmapped   = bus_req && !(sel_rom || sel_clint || sel_plic || sel_uart || sel_ram);

  assign rom_req     = bus_req && sel_rom && !bus_we;
  assign rom_addr    = bus_addr;

  assign clint_req   = bus_req && sel_clint;
  assign clint_we    = bus_we;
  assign clint_addr  = bus_addr;
  assign clint_wdata = bus_wdata;
  assign clint_wstrb = bus_wstrb;

  assign plic_req    = bus_req && sel_plic;
  assign plic_we     = bus_we;
  assign plic_addr   = bus_addr;
  assign plic_wdata  = bus_wdata;
  assign plic_wstrb  = bus_wstrb;

  assign uart_req    = bus_req && sel_uart;
  assign uart_we     = bus_we;
  assign uart_addr   = bus_addr;
  assign uart_wdata  = bus_wdata;
  assign uart_wstrb  = bus_wstrb;

  assign ram_req     = bus_req && sel_ram;
  assign ram_we      = bus_we;
  assign ram_addr    = bus_addr;
  assign ram_wdata   = bus_wdata;
  assign ram_wstrb   = bus_wstrb;

  // 非法/未映射地址单拍寄存错误应答 (保证与正常从设备时序同构，无组合环)
  reg err_ack_r;
  always @(posedge clk or posedge rst) begin
    if (rst) err_ack_r <= 1'b0;
    else     err_ack_r <= (rom_wr_err || unmapped) && !err_ack_r;
  end

  wire        bus_ack   = rom_ack | clint_ack | plic_ack | uart_ack | ram_ack | err_ack_r;
  wire [31:0] bus_rdata = rom_ack   ? rom_rdata   :
                          clint_ack ? clint_rdata :
                          plic_ack  ? plic_rdata  :
                          uart_ack  ? uart_rdata  :
                          ram_ack   ? ram_rdata   : 32'd0;
  wire        bus_err   = err_ack_r || (ram_ack && ram_err);

  assign m0_ack   = grant_m0 && bus_ack;
  assign m0_rdata = bus_rdata;
  assign m0_err   = grant_m0 && bus_err;

  assign m1_ack   = grant_m1 && bus_ack;
  assign m1_rdata = bus_rdata;
  assign m1_err   = grant_m1 && bus_err;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      busy  <= 1'b0;
      owner <= 1'b0;
    end
    else begin
      if (!busy) begin
        if ((m0_req || m1_req) && !bus_ack) begin
          busy  <= 1'b1;
          owner <= m0_req ? 1'b0 : 1'b1;
        end
      end
      else begin
        if (bus_ack) begin
          busy <= 1'b0;
        end
      end
    end
  end

endmodule
