`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// imem.v — 指令存储器（默认寄存读/BRAM，纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 后续路线 A 接入 DDR2 后将缩容为片上 BootROM。
// ============================================================================

module imem #(
  parameter [31:0] BASE  = `IMEM_BASE,
  parameter        BYTES = `IMEM_BYTES
)(
  input  wire        clk,
  input  wire [31:0] addr,
  output wire [31:0] rdata
);

  localparam WORDS = BYTES / 4;
  localparam AW    = $clog2(WORDS);

  reg [31:0] mem [0:WORDS-1];
  integer i;
`ifndef SYNTHESIS
  reg [8*256-1:0] init_file;
`endif

  initial begin
    for (i = 0; i < WORDS; i = i + 1) begin
      mem[i] = `INSTR_NOP;
    end

`ifdef SYNTHESIS
`ifdef IMEM_INIT_FILE
    $readmemh(`IMEM_INIT_FILE, mem);
`endif
`else
    if ($value$plusargs("imem=%s", init_file)) begin
      $readmemh(init_file, mem);
      $display("[imem] loaded program: %0s", init_file);
    end
    else begin
      $display("[imem] no +imem=<file> given, instruction memory stays all-NOP");
    end
`endif
  end

`ifdef IMEM_COMB_READ
  assign rdata = mem[addr[AW+1:2]];
`else
  reg [31:0] rdata_r;
  always @(posedge clk) begin
    rdata_r <= mem[addr[AW+1:2]];
  end
  assign rdata = rdata_r;
`endif

endmodule
