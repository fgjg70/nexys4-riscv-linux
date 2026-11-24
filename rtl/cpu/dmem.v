`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// dmem.v — 数据存储器（寄存读 + 字节写使能，纯 Verilog-2001）
// ============================================================================

module dmem #(
  parameter [31:0] BASE  = `DMEM_BASE,
  parameter        BYTES = `DMEM_BYTES
)(
  input  wire        clk,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  input  wire        we,
  output reg  [31:0] rdata
);

  localparam WORDS = BYTES / 4;
  localparam AW    = $clog2(WORDS);

  reg [31:0] mem [0:WORDS-1];
  integer i;
`ifndef SYNTHESIS
  reg [8*256-1:0] dinit_file;
`endif

  initial begin
    for (i = 0; i < WORDS; i = i + 1) begin
      mem[i] = 32'h0;
    end

`ifdef SYNTHESIS
`ifdef DMEM_INIT_FILE
    $readmemh(`DMEM_INIT_FILE, mem);
`endif
`else
    if ($value$plusargs("dmem=%s", dinit_file)) begin
      $readmemh(dinit_file, mem);
      $display("[dmem] loaded image: %0s", dinit_file);
    end
`endif
  end

  always @(posedge clk) begin
    if (we) begin
      if (wstrb[0]) mem[addr[AW+1:2]][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[addr[AW+1:2]][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[addr[AW+1:2]][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[addr[AW+1:2]][31:24] <= wdata[31:24];
    end
    rdata <= mem[addr[AW+1:2]];
  end

endmodule
