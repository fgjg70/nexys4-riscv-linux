`timescale 1ns/1ps

// ============================================================================
// async_fifo.v — 纯 Verilog-2001 格雷码双时钟异步 FIFO (零厂商原语)
// ----------------------------------------------------------------------------
// 用于 OV5640 cam_pclk -> sys_clk/vga_clk 像素跨时钟域采集。
// 默认 DEPTH = 1024 × 16-bit (独立无复位同步读写块 -> 100% 推断为 1 块 RAMB18E1)。
// ============================================================================

module async_fifo #(
  parameter DATA_W = 16,
  parameter ADDR_W = 10
)(
  // 写时钟域 (例如 cam_pclk)
  input  wire              wr_clk,
  input  wire              wr_rst,
  input  wire              wr_en,
  input  wire [DATA_W-1:0] wr_data,
  output wire              wr_full,

  // 读时钟域 (例如 sys_clk / vga_clk)
  input  wire              rd_clk,
  input  wire              rd_rst,
  input  wire              rd_en,
  output reg  [DATA_W-1:0] rd_data,
  output wire              rd_empty
);

  localparam DEPTH = (1 << ADDR_W);

  (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

  // 写指针 (二进制 + 格雷码)
  reg  [ADDR_W:0] wr_bin;
  reg  [ADDR_W:0] wr_gray;
  reg  [ADDR_W:0] rd_gray_sync1, rd_gray_sync2;

  // 读指针 (二进制 + 格雷码)
  reg  [ADDR_W:0] rd_bin;
  reg  [ADDR_W:0] rd_gray;
  reg  [ADDR_W:0] wr_gray_sync1, wr_gray_sync2;

  wire do_wr = wr_en && !wr_full;
  wire do_rd = rd_en && !rd_empty;

  wire [ADDR_W:0] wr_bin_next  = wr_bin + {{ADDR_W{1'b0}}, do_wr};
  wire [ADDR_W:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;

  wire [ADDR_W:0] rd_bin_next  = rd_bin + {{ADDR_W{1'b0}}, do_rd};
  wire [ADDR_W:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

  // 满判据: 最高两位相反，其余各位相等
  assign wr_full  = (wr_gray == {~rd_gray_sync2[ADDR_W:ADDR_W-1], rd_gray_sync2[ADDR_W-2:0]});
  // 空判据: 全部位相等
  assign rd_empty = (rd_gray == wr_gray_sync2);

  integer k;
  initial begin
    rd_data = {DATA_W{1'b0}};
    for (k = 0; k < DEPTH; k = k + 1) mem[k] = {DATA_W{1'b0}};
  end

  // ---- 独立无异步复位 BRAM 读写块 (严格满足 Vivado 简单双口 RAMB18 推断) ----
  always @(posedge wr_clk) begin
    if (do_wr) mem[wr_bin[ADDR_W-1:0]] <= wr_data;
  end

  always @(posedge rd_clk) begin
    if (do_rd) rd_data <= mem[rd_bin[ADDR_W-1:0]];
  end

  // ---- 写时钟域指针与同步 ----
  always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
      wr_bin        <= {(ADDR_W+1){1'b0}};
      wr_gray       <= {(ADDR_W+1){1'b0}};
      rd_gray_sync1 <= {(ADDR_W+1){1'b0}};
      rd_gray_sync2 <= {(ADDR_W+1){1'b0}};
    end
    else begin
      wr_bin        <= wr_bin_next;
      wr_gray       <= wr_gray_next;
      rd_gray_sync1 <= rd_gray;
      rd_gray_sync2 <= rd_gray_sync1;
    end
  end

  // ---- 读时钟域指针与同步 ----
  always @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
      rd_bin        <= {(ADDR_W+1){1'b0}};
      rd_gray       <= {(ADDR_W+1){1'b0}};
      wr_gray_sync1 <= {(ADDR_W+1){1'b0}};
      wr_gray_sync2 <= {(ADDR_W+1){1'b0}};
    end
    else begin
      rd_bin        <= rd_bin_next;
      rd_gray       <= rd_gray_next;
      wr_gray_sync1 <= wr_gray;
      wr_gray_sync2 <= wr_gray_sync1;
    end
  end

endmodule
