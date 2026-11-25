`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// spi_master.v — 标准 SPI Mode 0 主控制器 (面向 Nexys 4 DDR microSD, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 基址 0x1000_1000 (PLIC Source 2):
//   +0x00 DATA : 写启动 8-bit 全双工收发; 读返回最近接收字节
//   +0x04 STAT : [0]=BUSY, [1]=SD_CD_N(0=插卡), [2]=DONE_IRQ(W1C)
//   +0x08 CTRL : [0]=CS_N(复位=1), [1]=SD_RESET(Nexys4 低有效上电,复位=0), [2]=IRQ_EN
//   +0x0C DIV  : [15:0] SCK 半周期分频系数 (默认 125 -> 200 kHz @ 50 MHz 满足 SD 初始化)
// ============================================================================

module spi_master #(
  parameter [15:0] DEFAULT_DIV = 16'd125
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

  // microSD 物理引脚 (SPI 模式: CMD=MOSI, DAT0=MISO, DAT3=CS_N)
  output reg         spi_sck,
  output reg         spi_mosi,
  input  wire        spi_miso,
  output reg         spi_cs_n,
  output reg         sd_reset,
  input  wire        sd_cd_n,

  output wire        irq_o
);

  reg        busy;
  reg        irq_en;
  reg        irq_pend;
  reg [15:0] div_reg;
  reg [15:0] div_cnt;
  reg [2:0]  bit_cnt;
  reg        phase;       // 0=前半拍(SCK=0), 1=后半拍(SCK=1)
  reg [7:0]  tx_sh;
  reg [7:0]  rx_sh;
  reg [7:0]  rx_data;

  wire [3:0] off    = addr[3:0];
  wire       do_req = req && !ack;

  assign irq_o = irq_en && irq_pend;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ack      <= 1'b0;
      rdata    <= 32'd0;
      busy     <= 1'b0;
      irq_en   <= 1'b0;
      irq_pend <= 1'b0;
      div_reg  <= DEFAULT_DIV;
      div_cnt  <= 16'd0;
      bit_cnt  <= 3'd0;
      phase    <= 1'b0;
      tx_sh    <= 8'hFF;
      rx_sh    <= 8'hFF;
      rx_data  <= 8'hFF;
      spi_sck  <= 1'b0;
      spi_mosi <= 1'b1;
      spi_cs_n <= 1'b1;
      sd_reset <= 1'b0;   // Nexys 4 DDR SD_RESET 低有效使能卡槽供电
    end
    else begin
      ack <= do_req;

      if (do_req) begin
        if (we) begin
          rdata <= 32'd0;
          case (off)
            4'h0: begin
              if (!busy) begin
                busy     <= 1'b1;
                tx_sh    <= {wdata[6:0], 1'b1};
                spi_mosi <= wdata[7];
                spi_sck  <= 1'b0;
                bit_cnt  <= 3'd7;
                phase    <= 1'b0;
                div_cnt  <= (div_reg == 16'd0) ? 16'd0 : (div_reg - 16'd1);
              end
            end
            4'h4: begin
              if (wdata[2]) irq_pend <= 1'b0;
            end
            4'h8: begin
              spi_cs_n <= wdata[0];
              sd_reset <= wdata[1];
              irq_en   <= wdata[2];
            end
            4'hC: begin
              div_reg <= wdata[15:0];
            end
            default: ;
          endcase
        end
        else begin
          case (off)
            4'h0:    rdata <= {24'd0, rx_data};
            4'h4:    rdata <= {29'd0, irq_pend, sd_cd_n, busy};
            4'h8:    rdata <= {29'd0, irq_en, sd_reset, spi_cs_n};
            4'hC:    rdata <= {16'd0, div_reg};
            default: rdata <= 32'd0;
          endcase
        end
      end

      // SPI Mode 0 移位状态机 (上升沿采样 MISO，下降沿切换 MOSI)
      if (busy) begin
        if (div_cnt == 16'd0) begin
          div_cnt <= (div_reg == 16'd0) ? 16'd0 : (div_reg - 16'd1);
          if (!phase) begin
            // SCK 上升沿: 采样 MISO
            spi_sck <= 1'b1;
            rx_sh   <= {rx_sh[6:0], spi_miso};
            phase   <= 1'b1;
          end
          else begin
            // SCK 下降沿: 推下一位或结束
            spi_sck <= 1'b0;
            phase   <= 1'b0;
            if (bit_cnt == 3'd0) begin
              busy     <= 1'b0;
              rx_data  <= rx_sh;
              irq_pend <= 1'b1;
              spi_mosi <= 1'b1;
            end
            else begin
              bit_cnt  <= bit_cnt - 3'd1;
              spi_mosi <= tx_sh[7];
              tx_sh    <= {tx_sh[6:0], 1'b1};
            end
          end
        end
        else begin
          div_cnt <= div_cnt - 16'd1;
        end
      end
    end
  end

endmodule
