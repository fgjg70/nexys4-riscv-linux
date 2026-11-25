`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// uart_16550.v — 标准 NS16550A 兼容串口 (32-bit 对齐 reg-shift=2, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// Round 1 审计加固 (完全对齐 Linux serial8250 驱动规范):
//   - 实现标准 thre_ip 锁存: 读 IIR 返回 THRE(0xC2) 或写 THR 时自动清中断，杜绝 THRE 风暴；
//   - 新增 LSR[1] Overrun Error (OE) 标志 (RX FIFO 满溢出置位，读 LSR 清除)；
//   - 外部 rx_s1/rx_s2 标注 (* ASYNC_REG = "TRUE" *)；
//   - 收发位周期计数器收敛为 21-bit，消除 32-bit ROM 综合告警并节省逻辑面积。
// ============================================================================

module uart_16550 #(
  parameter CLK_HZ  = 50_000_000,
  parameter BAUD_HZ = 115_200
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [31:0] wdata,
  input  wire [3:0]  wstrb,
  output reg         ack,
  output reg  [31:0] rdata,

  output reg         uart_txd,
  input  wire        uart_rxd,
  output wire        irq_o,

  // 仿真观测辅助输出 (与软件无关，不影响综合)
  output reg         tx_push_pulse,
  output reg  [7:0]  tx_push_byte
);

  localparam [20:0] DEFAULT_BIT_CYCLES = (CLK_HZ / BAUD_HZ);

  // 控制/状态寄存器
  reg [7:0] ier;
  reg [7:0] lcr;
  reg [7:0] mcr;
  reg [7:0] scr;
  reg [7:0] dll;
  reg [7:0] dlm;
  reg       thre_ip;    // 标准 NS16550A THRE 中断挂起锁存
  reg       lsr_oe;     // LSR[1] RX Overrun Error (读 LSR 清零)

  wire dlab     = lcr[7];
  wire loop_en  = mcr[4];

  // 16 字节 TX / RX FIFO
  reg [7:0] tx_fifo [0:15];
  reg [3:0] tx_head, tx_tail;
  reg [4:0] tx_cnt;

  reg [7:0] rx_fifo [0:15];
  reg [3:0] rx_head, rx_tail;
  reg [4:0] rx_cnt;

  wire tx_empty = (tx_cnt == 5'd0);
  wire tx_full  = (tx_cnt == 5'd16);
  wire rx_empty = (rx_cnt == 5'd0);
  wire rx_full  = (rx_cnt == 5'd16);

  // 波特率分频: 最大 65535 * 16 = 1,048,560 < 2^20，21-bit 留足 1.5 倍采样余量
  wire [15:0] div_reg    = {dlm, dll};
  wire [20:0] bit_cycles = (div_reg == 16'd0) ? DEFAULT_BIT_CYCLES
                         : {1'b0, div_reg, 4'b0000};
  wire [20:0] bit_reload = (bit_cycles > 21'd1) ? (bit_cycles - 21'd1) : 21'd0;

  // ---- TX 移位器 ----
  reg        tx_busy;
  reg [9:0]  tx_sh;
  reg [3:0]  tx_bits;
  reg [20:0] tx_cnt_cyc;

  // ---- RX 移位器 (2 级 ASYNC_REG 同步 + 支持 MCR[4] 内部环回) ----
  wire rxd_mux = loop_en ? uart_txd : uart_rxd;
  (* ASYNC_REG = "TRUE" *) reg rx_s1;
  (* ASYNC_REG = "TRUE" *) reg rx_s2;
  reg        rx_busy;
  reg [3:0]  rx_bits;
  reg [7:0]  rx_sh;
  reg [20:0] rx_cnt_cyc;
  reg        rx_done_pulse;
  reg [7:0]  rx_done_byte;

  // 中断逻辑 (优先级: RX Data Available > THRE)
  wire rx_irq_req = ier[0] && !rx_empty;
  wire tx_irq_req = ier[1] && thre_ip && tx_empty;
  assign irq_o    = rx_irq_req || tx_irq_req;

  wire [7:0] iir_val = rx_irq_req ? 8'hC4    // FIFOs enabled + Received Data Available
                     : tx_irq_req ? 8'hC2    // FIFOs enabled + THR Empty
                     :              8'hC1;   // FIFOs enabled + No interrupt pending
  wire [7:0] lsr_val = {1'b0, (tx_empty && !tx_busy), tx_empty, 3'b000, lsr_oe, !rx_empty};

  wire [2:0] reg_sel = addr[4:2];
  wire       do_req  = req && !ack;

  // 读写事件解码
  wire cpu_tx_push  = do_req && we  && !dlab && (reg_sel == 3'd0) && !tx_full;
  wire cpu_rx_pop   = do_req && !we && !dlab && (reg_sel == 3'd0) && !rx_empty;
  wire cpu_tx_clear = do_req && we  && (reg_sel == 3'd2) && wdata[2];
  wire cpu_rx_clear = do_req && we  && (reg_sel == 3'd2) && wdata[1];
  wire cpu_iir_read = do_req && !we && (reg_sel == 3'd2);
  wire cpu_lsr_read = do_req && !we && (reg_sel == 3'd5);
  wire cpu_ier_wr   = do_req && we  && !dlab && (reg_sel == 3'd1);

  wire tx_pop_now   = !tx_busy && !tx_empty && !cpu_tx_clear;
  wire rx_push_now  = rx_done_pulse && !rx_full && !cpu_rx_clear;
  wire rx_ovf_now   = rx_done_pulse &&  rx_full && !cpu_rx_clear;

  integer i;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack           <= 1'b0;
      rdata         <= 32'd0;
      ier           <= 8'd0;
      lcr           <= 8'h03;  // 8N1
      mcr           <= 8'd0;
      scr           <= 8'd0;
      dll           <= 8'd0;
      dlm           <= 8'd0;
      thre_ip       <= 1'b1;   // 复位时 TX FIFO 为空，使能 IER[1] 即刻触发 THRE
      lsr_oe        <= 1'b0;
      tx_head       <= 4'd0;
      tx_tail       <= 4'd0;
      tx_cnt        <= 5'd0;
      rx_head       <= 4'd0;
      rx_tail       <= 4'd0;
      rx_cnt        <= 5'd0;
      uart_txd      <= 1'b1;
      tx_busy       <= 1'b0;
      tx_sh         <= 10'h3FF;
      tx_bits       <= 4'd0;
      tx_cnt_cyc    <= 21'd0;
      rx_s1         <= 1'b1;
      rx_s2         <= 1'b1;
      rx_busy       <= 1'b0;
      rx_bits       <= 4'd0;
      rx_sh         <= 8'd0;
      rx_cnt_cyc    <= 21'd0;
      rx_done_pulse <= 1'b0;
      rx_done_byte  <= 8'd0;
      tx_push_pulse <= 1'b0;
      tx_push_byte  <= 8'd0;
      for (i = 0; i < 16; i = i + 1) begin
        tx_fifo[i] <= 8'd0;
        rx_fifo[i] <= 8'd0;
      end
    end
    else begin
      ack           <= do_req;
      tx_push_pulse <= cpu_tx_push;
      if (cpu_tx_push) tx_push_byte <= wdata[7:0];

      // ---- LSR Overrun 标志维护 ----
      if (rx_ovf_now)        lsr_oe <= 1'b1;
      else if (cpu_lsr_read) lsr_oe <= 1'b0;

      // ---- 标准 NS16550A THRE 中断挂起锁存维护 ----
      if (cpu_tx_push) begin
        thre_ip <= 1'b0;
      end
      else if (cpu_tx_clear || (tx_pop_now && (tx_cnt == 5'd1)) ||
               (cpu_ier_wr && wdata[1] && !ier[1] && tx_empty)) begin
        thre_ip <= 1'b1;
      end
      else if (cpu_iir_read && !rx_irq_req && tx_irq_req) begin
        thre_ip <= 1'b0;
      end

      // ---- CPU 寄存器读写 ----
      if (do_req) begin
        if (we) begin
          rdata <= 32'd0;
          case (reg_sel)
            3'd0: if (dlab) dll <= wdata[7:0];
            3'd1: if (dlab) dlm <= wdata[7:0];
                  else      ier <= {4'd0, wdata[3:0]};
            3'd2: ; // FCR 由 cpu_tx_clear / cpu_rx_clear 处理
            3'd3: lcr <= wdata[7:0];
            3'd4: mcr <= wdata[7:0];
            3'd7: scr <= wdata[7:0];
            default: ;
          endcase
        end
        else begin
          case (reg_sel)
            3'd0: rdata <= {24'd0, dlab ? dll : (rx_empty ? 8'd0 : rx_fifo[rx_head])};
            3'd1: rdata <= {24'd0, dlab ? dlm : ier};
            3'd2: rdata <= {24'd0, iir_val};
            3'd3: rdata <= {24'd0, lcr};
            3'd4: rdata <= {24'd0, mcr};
            3'd5: rdata <= {24'd0, lsr_val};
            3'd6: rdata <= {24'd0, 8'hB0};
            3'd7: rdata <= {24'd0, scr};
            default: rdata <= 32'd0;
          endcase
        end
      end

      // ---- TX FIFO 维护 ----
      if (cpu_tx_clear) begin
        tx_head <= 4'd0;
        tx_tail <= 4'd0;
        tx_cnt  <= 5'd0;
      end
      else begin
        if (cpu_tx_push) begin
          tx_fifo[tx_tail] <= wdata[7:0];
          tx_tail          <= tx_tail + 4'd1;
        end
        if (tx_pop_now) begin
          tx_head <= tx_head + 4'd1;
        end
        case ({cpu_tx_push, tx_pop_now})
          2'b10: tx_cnt <= tx_cnt + 5'd1;
          2'b01: tx_cnt <= tx_cnt - 5'd1;
          default: ;
        endcase
      end

      // ---- TX 串行发送状态机 ----
      if (tx_pop_now) begin
        tx_busy    <= 1'b1;
        tx_sh      <= {1'b1, tx_fifo[tx_head], 1'b0};
        tx_bits    <= 4'd10;
        tx_cnt_cyc <= bit_reload;
        uart_txd   <= 1'b0; // 立即拉低起始位
      end
      else if (tx_busy) begin
        if (tx_cnt_cyc == 21'd0) begin
          if (tx_bits == 4'd1) begin
            tx_busy  <= 1'b0;
            uart_txd <= 1'b1;
          end
          else begin
            tx_sh      <= {1'b1, tx_sh[9:1]};
            uart_txd   <= tx_sh[1];
            tx_bits    <= tx_bits - 4'd1;
            tx_cnt_cyc <= bit_reload;
          end
        end
        else begin
          tx_cnt_cyc <= tx_cnt_cyc - 21'd1;
        end
      end

      // ---- RX 同步与串行接收状态机 ----
      rx_s1         <= rxd_mux;
      rx_s2         <= rx_s1;
      rx_done_pulse <= 1'b0;

      if (!rx_busy) begin
        if (rx_s2 == 1'b0) begin
          rx_busy    <= 1'b1;
          rx_bits    <= 4'd0;
          rx_cnt_cyc <= {1'b0, bit_cycles[20:1]} + bit_cycles; // 1.5 位后采样 bit 0 中心
        end
      end
      else begin
        if (rx_cnt_cyc == 21'd0) begin
          if (rx_bits < 4'd8) begin
            rx_sh      <= {rx_s2, rx_sh[7:1]};
            rx_bits    <= rx_bits + 4'd1;
            rx_cnt_cyc <= bit_reload;
          end
          else begin
            rx_busy       <= 1'b0;
            rx_done_pulse <= 1'b1;
            rx_done_byte  <= rx_sh;
          end
        end
        else begin
          rx_cnt_cyc <= rx_cnt_cyc - 21'd1;
        end
      end

      // ---- RX FIFO 维护 ----
      if (cpu_rx_clear) begin
        rx_head <= 4'd0;
        rx_tail <= 4'd0;
        rx_cnt  <= 5'd0;
      end
      else begin
        if (rx_push_now) begin
          rx_fifo[rx_tail] <= rx_done_byte;
          rx_tail          <= rx_tail + 4'd1;
        end
        if (cpu_rx_pop) begin
          rx_head <= rx_head + 4'd1;
        end
        case ({rx_push_now, cpu_rx_pop})
          2'b10: rx_cnt <= rx_cnt + 5'd1;
          2'b01: rx_cnt <= rx_cnt - 5'd1;
          default: ;
        endcase
      end
    end
  end

endmodule
