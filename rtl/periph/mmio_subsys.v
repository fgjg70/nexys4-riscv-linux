`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// mmio_subsys.v — 基线 MMIO 外设子系统 (GPIO / 64 位周期计时 / UART / mtime)
// 纯 Verilog-2001；后续路线 A 将升级为标准 CLINT + PLIC + NS16550A UART。
// ============================================================================

module mmio_subsys #(
  parameter CLK_HZ  = 50_000_000,
  parameter BAUD_HZ = 115_200
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        we,
  input  wire        re,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg  [31:0] rdata,

  output reg  [31:0] gpio_out,
  input  wire [31:0] gpio_in,
  output wire        uart_txd,
  input  wire        uart_rxd,

  output wire [31:0] tx_byte_count,
  output wire [31:0] rx_byte_count,

  output reg         mark,
  output reg         done,
  output reg  [31:0] result,

  output wire        irq_timer
);

  localparam [15:0] BAUD_DIV = CLK_HZ / BAUD_HZ;

  wire sel_gpio_out    = (addr == `MMIO_GPIO_OUT);
  wire sel_gpio_in     = (addr == `MMIO_GPIO_IN);
  wire sel_cyc_lo      = (addr == `MMIO_CYCLE_LO);
  wire sel_cyc_hi      = (addr == `MMIO_CYCLE_HI);
  wire sel_uart_tx     = (addr == `MMIO_UART_TX);
  wire sel_uart_stat   = (addr == `MMIO_UART_STAT);
  wire sel_uart_rx     = (addr == `MMIO_UART_RX);
  wire sel_uart_rstat  = (addr == `MMIO_UART_RSTAT);
  wire sel_mark        = (addr == `MMIO_MARK);
  wire sel_result      = (addr == `MMIO_RESULT);
  wire sel_mtimecmp_lo = (addr == `MMIO_MTIMECMP_LO);
  wire sel_mtimecmp_hi = (addr == `MMIO_MTIMECMP_HI);
  wire sel_mtime_lo    = (addr == `MMIO_MTIME_LO);
  wire sel_mtime_hi    = (addr == `MMIO_MTIME_HI);

  wire wr_gpio_out     = we && sel_gpio_out;
  wire wr_uart_tx      = we && sel_uart_tx;
  wire wr_mtimecmp_lo  = we && sel_mtimecmp_lo;
  wire wr_mtimecmp_hi  = we && sel_mtimecmp_hi;

  // 跑分观测寄存器
  always @(posedge clk) begin
    if (rst) begin
      mark   <= 1'b0;
      done   <= 1'b0;
      result <= 32'd0;
    end
    else begin
      mark <= 1'b0;
      if (we && sel_mark) mark <= 1'b1;
      if (we && sel_result) begin
        result <= wdata;
        done   <= 1'b1;
      end
    end
  end

  // GPIO 输出
  always @(posedge clk) begin
    if (rst)              gpio_out <= 32'h0;
    else if (wr_gpio_out) gpio_out <= wdata;
  end

  // 64 位自由运行周期计数器 (= mtime)
  reg [63:0] cycle_cnt;
  always @(posedge clk) begin
    if (rst) cycle_cnt <= 64'd0;
    else     cycle_cnt <= cycle_cnt + 64'd1;
  end

  // 定时器 mtimecmp -> irq_timer
  reg [63:0] mtimecmp;
  always @(posedge clk) begin
    if (rst) begin
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
    end
    else begin
      if (wr_mtimecmp_lo) mtimecmp[31:0]  <= wdata;
      if (wr_mtimecmp_hi) mtimecmp[63:32] <= wdata;
    end
  end

  reg irq_timer_r;
  always @(posedge clk) begin
    if (rst) irq_timer_r <= 1'b0;
    else     irq_timer_r <= (cycle_cnt >= mtimecmp);
  end
  assign irq_timer = irq_timer_r;

  // UART 发送 (10-bit 8N1)
  reg [9:0]  tx_frame;
  reg [3:0]  tx_idx;
  reg [15:0] tx_cnt;
  reg        tx_busy;
  reg        tx_line;

  always @(posedge clk) begin
    if (rst) begin
      tx_busy  <= 1'b0;
      tx_idx   <= 4'd0;
      tx_cnt   <= 16'd0;
      tx_frame <= 10'h3FF;
      tx_line  <= 1'b1;
    end
    else if (!tx_busy) begin
      tx_line <= 1'b1;
      if (wr_uart_tx) begin
        tx_frame <= {1'b1, wdata[7:0], 1'b0};
        tx_busy  <= 1'b1;
        tx_idx   <= 4'd0;
        tx_cnt   <= 16'd0;
      end
    end
    else begin
      tx_line <= tx_frame[tx_idx];
      if (tx_cnt == (BAUD_DIV - 16'd1)) begin
        tx_cnt <= 16'd0;
        if (tx_idx == 4'd9) tx_busy <= 1'b0;
        else                tx_idx  <= tx_idx + 4'd1;
      end
      else begin
        tx_cnt <= tx_cnt + 16'd1;
      end
    end
  end
  assign uart_txd = tx_line;

  reg [31:0] tx_cnt_bytes;
  always @(posedge clk) begin
    if (rst)             tx_cnt_bytes <= 32'd0;
    else if (wr_uart_tx) tx_cnt_bytes <= tx_cnt_bytes + 32'd1;
  end
  assign tx_byte_count = tx_cnt_bytes;

  // UART 接收
  localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

  reg [2:0]  rxd_sync;
  reg [1:0]  rx_state;
  reg [15:0] rx_div;
  reg [3:0]  rx_bit;
  reg [7:0]  rx_sh, rx_byte;
  reg        rx_rdy;
  reg        rx_done;

  always @(posedge clk) begin
    if (rst) begin
      rxd_sync <= 3'b111;
      rx_state <= RX_IDLE;
      rx_div   <= 16'd0;
      rx_bit   <= 4'd0;
      rx_sh    <= 8'd0;
      rx_byte  <= 8'd0;
      rx_rdy   <= 1'b0;
      rx_done  <= 1'b0;
    end
    else begin
      rxd_sync <= {rxd_sync[1:0], uart_rxd};
      rx_done  <= 1'b0;
      if (rx_rdy && re && sel_uart_rx) rx_rdy <= 1'b0;

      case (rx_state)
        RX_IDLE: begin
          if (rxd_sync[2:1] == 2'b10) begin
            rx_state <= RX_START;
            rx_div   <= 16'd0;
          end
        end
        RX_START: begin
          if (rx_div == (BAUD_DIV >> 1)) begin
            rx_div <= 16'd0;
            if (rxd_sync[2] == 1'b0) begin
              rx_state <= RX_DATA;
              rx_bit   <= 4'd0;
            end
            else begin
              rx_state <= RX_IDLE;
            end
          end
          else begin
            rx_div <= rx_div + 16'd1;
          end
        end
        RX_DATA: begin
          if (rx_div == (BAUD_DIV - 16'd1)) begin
            rx_div <= 16'd0;
            rx_sh  <= {rxd_sync[2], rx_sh[7:1]};
            if (rx_bit == 4'd7) rx_state <= RX_STOP;
            else                rx_bit   <= rx_bit + 4'd1;
          end
          else begin
            rx_div <= rx_div + 16'd1;
          end
        end
        RX_STOP: begin
          if (rx_div == (BAUD_DIV - 16'd1)) begin
            rx_div   <= 16'd0;
            rx_state <= RX_IDLE;
            rx_byte  <= rx_sh;
            rx_rdy   <= 1'b1;
            rx_done  <= 1'b1;
          end
          else begin
            rx_div <= rx_div + 16'd1;
          end
        end
        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  reg [31:0] rx_cnt_bytes;
  always @(posedge clk) begin
    if (rst)          rx_cnt_bytes <= 32'd0;
    else if (rx_done) rx_cnt_bytes <= rx_cnt_bytes + 32'd1;
  end
  assign rx_byte_count = rx_cnt_bytes;

  // 组合读回
  always @(*) begin
    rdata = 32'h0;
    if      (sel_gpio_in)     rdata = gpio_in;
    else if (sel_cyc_lo)      rdata = cycle_cnt[31:0];
    else if (sel_cyc_hi)      rdata = cycle_cnt[63:32];
    else if (sel_uart_stat)   rdata = {31'b0, tx_busy};
    else if (sel_uart_rx)     rdata = {24'b0, rx_byte};
    else if (sel_uart_rstat)  rdata = {31'b0, rx_rdy};
    else if (sel_result)      rdata = result;
    else if (sel_mtimecmp_lo) rdata = mtimecmp[31:0];
    else if (sel_mtimecmp_hi) rdata = mtimecmp[63:32];
    else if (sel_mtime_lo)    rdata = cycle_cnt[31:0];
    else if (sel_mtime_hi)    rdata = cycle_cnt[63:32];
  end

endmodule
