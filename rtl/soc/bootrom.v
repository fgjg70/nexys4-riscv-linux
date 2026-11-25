`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// bootrom.v — 16 KB 片上只读 BootROM (0x0000_1000 .. 0x0000_4FFF, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 默认预置 2 条最小引导指令: lui t0, 0x80000 ; jr t0 (直接跳往 DDR2 0x8000_0000)。
// 仿真可通过 +rom=<hex> 覆盖；综合可通过 ROM_INIT_FILE 装入正式 Bootloader + DTB。
// ============================================================================

module bootrom #(
  parameter [31:0] BASE  = `SOC_ROM_BASE,
  parameter        BYTES = 16384
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        req,
  input  wire [31:0] addr,
  output reg         ack,
  output reg  [31:0] rdata
);

  localparam WORDS = BYTES / 4;
  localparam AW    = $clog2(WORDS);

  (* ram_style = "block" *) reg [31:0] mem [0:WORDS-1];
  wire [31:0] rel_addr = addr - BASE;
  wire        do_req   = req && !ack;

  integer i;
`ifndef SYNTHESIS
  reg [8*256-1:0] rom_file;
`endif

  initial begin
    for (i = 0; i < WORDS; i = i + 1) begin
      mem[i] = `INSTR_NOP;
    end
    // 默认引导跳转桩: 0x0000_1000 -> 0x8000_0000 (DDR2 主存入口)
    mem[0] = 32'h8000_02B7; // lui  t0, 0x80000
    mem[1] = 32'h0002_8067; // jalr x0, 0(t0)

`ifdef SYNTHESIS
`ifdef ROM_INIT_FILE
    $readmemh(`ROM_INIT_FILE, mem);
`endif
`else
    if ($value$plusargs("rom=%s", rom_file)) begin
      $readmemh(rom_file, mem);
      $display("[bootrom] loaded image: %0s", rom_file);
    end
`endif
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack   <= 1'b0;
      rdata <= `INSTR_NOP;
    end
    else begin
      ack <= do_req;
      if (do_req) begin
        rdata <= mem[rel_addr[AW+1:2]];
      end
    end
  end

endmodule
