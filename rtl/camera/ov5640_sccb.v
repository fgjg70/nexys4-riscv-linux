`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// ov5640_sccb.v — OV5640 专属 16-bit 寄存器地址 SCCB 主控制器 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 区别于旧 OV7670 的 8-bit 寄存器地址，OV5640 必须使用 16-bit 寄存器地址:
//   - 写事务: START -> 0x78 -> reg_addr[15:8] -> reg_addr[7:0] -> wdata -> STOP
//   - 读事务: START -> 0x78 -> reg_addr[15:8] -> reg_addr[7:0] -> STOP
//             -> START -> 0x79 -> rdata(NACK) -> STOP
// 输出开漏使能 sio_d_oe (1=拉低, 0=释放高阻)，顶层接三态 pad。
// ============================================================================

module ov5640_sccb #(
  parameter CLK_HZ  = 50_000_000,
  parameter SCCB_HZ = 100_000,
  parameter [6:0] DEV_ADDR = 7'h3C      // OV5640 7-bit I2C 地址 (写 0x78 / 读 0x79)
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        start_wr,
  input  wire        start_rd,
  input  wire [15:0] reg_addr,
  input  wire [7:0]  wdata,

  output reg         busy,
  output reg         nack_err,
  output reg  [7:0]  rdata,

  output reg         sio_c,
  output reg         sio_d_oe,          // 1=拉低 SIOD, 0=高阻释放
  input  wire        sio_d_in
);

  // 每位 4 个四分之一拍 (Q0:SCL=0改数据, Q1:SCL=1稳定, Q2:SCL=1采样, Q3:SCL=0保持)
  localparam integer Q_CYCLES = (CLK_HZ / (SCCB_HZ * 4));
  localparam [15:0]  Q_DIV    = (Q_CYCLES > 2) ? (Q_CYCLES - 1) : 16'd1;

  localparam [3:0]
    S_IDLE       = 4'd0,
    S_START1     = 4'd1,
    S_TX_BYTE    = 4'd2,
    S_TX_ACK     = 4'd3,
    S_STOP1      = 4'd4,
    S_GAP        = 4'd5,
    S_START2     = 4'd6,
    S_RX_BYTE    = 4'd7,
    S_RX_NACK    = 4'd8,
    S_STOP2      = 4'd9;

  reg [3:0]  state;
  reg [15:0] div_cnt;
  reg [1:0]  q_step;
  reg [2:0]  bit_idx;
  reg [1:0]  byte_idx;      // 0=DEV_WR, 1=ADDR_HI, 2=ADDR_LO, 3=WDATA (或 PHASE2 DEV_RD)
  reg        is_read;
  reg        phase2;
  reg [15:0] addr_r;
  reg [7:0]  wdata_r;
  reg [7:0]  sh_tx;
  reg [7:0]  sh_rx;
  (* ASYNC_REG = "TRUE" *) reg siod_s1;
  (* ASYNC_REG = "TRUE" *) reg siod_s2;

  wire tick = (div_cnt == 16'd0);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state    <= S_IDLE;
      busy     <= 1'b0;
      nack_err <= 1'b0;
      rdata    <= 8'd0;
      sio_c    <= 1'b1;
      sio_d_oe <= 1'b0;
      div_cnt  <= 16'd0;
      q_step   <= 2'd0;
      bit_idx  <= 3'd0;
      byte_idx <= 2'd0;
      is_read  <= 1'b0;
      phase2   <= 1'b0;
      addr_r   <= 16'd0;
      wdata_r  <= 8'd0;
      sh_tx    <= 8'd0;
      sh_rx    <= 8'd0;
      siod_s1  <= 1'b1;
      siod_s2  <= 1'b1;
    end
    else begin
      siod_s1 <= sio_d_in;
      siod_s2 <= siod_s1;
      if (state == S_IDLE) begin
        sio_c    <= 1'b1;
        sio_d_oe <= 1'b0;
        if (start_wr || start_rd) begin
          busy     <= 1'b1;
          nack_err <= 1'b0;
          is_read  <= start_rd && !start_wr;
          phase2   <= 1'b0;
          addr_r   <= reg_addr;
          wdata_r  <= wdata;
          byte_idx <= 2'd0;
          sh_tx    <= {DEV_ADDR, 1'b0}; // 0x78
          q_step   <= 2'd0;
          div_cnt  <= Q_DIV;
          state    <= S_START1;
        end
      end
      else if (!tick) begin
        div_cnt <= div_cnt - 16'd1;
      end
      else begin
        div_cnt <= Q_DIV;

        case (state)
          // START: SCL=1 期间 SDA 由高拉低，随后 SCL 拉低
          S_START1, S_START2: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b1; sio_d_oe <= 1'b0; q_step <= 2'd1; end
              2'd1: begin sio_c <= 1'b1; sio_d_oe <= 1'b1; q_step <= 2'd2; end
              2'd2: begin sio_c <= 1'b0; sio_d_oe <= 1'b1; q_step <= 2'd0;
                          bit_idx <= 3'd7; state <= S_TX_BYTE; end
              default: q_step <= 2'd0;
            endcase
          end

          S_TX_BYTE: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b0; sio_d_oe <= ~sh_tx[7]; q_step <= 2'd1; end
              2'd1: begin sio_c <= 1'b1; q_step <= 2'd2; end
              2'd2: begin sio_c <= 1'b1; q_step <= 2'd3; end
              2'd3: begin
                sio_c  <= 1'b0;
                q_step <= 2'd0;
                if (bit_idx == 3'd0) begin
                  state <= S_TX_ACK;
                end
                else begin
                  bit_idx <= bit_idx - 3'd1;
                  sh_tx   <= {sh_tx[6:0], 1'b0};
                end
              end
            endcase
          end

          S_TX_ACK: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b0; sio_d_oe <= 1'b0; q_step <= 2'd1; end
              2'd1: begin sio_c <= 1'b1; q_step <= 2'd2; end
              2'd2: begin
                if (siod_s2) nack_err <= 1'b1;
                q_step <= 2'd3;
              end
              2'd3: begin
                sio_c  <= 1'b0;
                q_step <= 2'd0;
                if (phase2) begin
                  bit_idx <= 3'd7;
                  state   <= S_RX_BYTE;
                end
                else if (byte_idx == 2'd0) begin
                  byte_idx <= 2'd1;
                  sh_tx    <= addr_r[15:8];
                  bit_idx  <= 3'd7;
                  state    <= S_TX_BYTE;
                end
                else if (byte_idx == 2'd1) begin
                  byte_idx <= 2'd2;
                  sh_tx    <= addr_r[7:0];
                  bit_idx  <= 3'd7;
                  state    <= S_TX_BYTE;
                end
                else if ((byte_idx == 2'd2) && !is_read) begin
                  byte_idx <= 2'd3;
                  sh_tx    <= wdata_r;
                  bit_idx  <= 3'd7;
                  state    <= S_TX_BYTE;
                end
                else begin
                  state <= S_STOP1;
                end
              end
            endcase
          end

          S_RX_BYTE: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b0; sio_d_oe <= 1'b0; q_step <= 2'd1; end
              2'd1: begin sio_c <= 1'b1; q_step <= 2'd2; end
              2'd2: begin
                sh_rx  <= {sh_rx[6:0], siod_s2};
                q_step <= 2'd3;
              end
              2'd3: begin
                sio_c  <= 1'b0;
                q_step <= 2'd0;
                if (bit_idx == 3'd0) begin
                  rdata <= sh_rx;
                  state <= S_RX_NACK;
                end
                else begin
                  bit_idx <= bit_idx - 3'd1;
                end
              end
            endcase
          end

          S_RX_NACK: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b0; sio_d_oe <= 1'b0; q_step <= 2'd1; end // NACK=高
              2'd1: begin sio_c <= 1'b1; q_step <= 2'd2; end
              2'd2: begin sio_c <= 1'b1; q_step <= 2'd3; end
              2'd3: begin sio_c <= 1'b0; q_step <= 2'd0; state <= S_STOP2; end
            endcase
          end

          S_STOP1, S_STOP2: begin
            case (q_step)
              2'd0: begin sio_c <= 1'b0; sio_d_oe <= 1'b1; q_step <= 2'd1; end
              2'd1: begin sio_c <= 1'b1; sio_d_oe <= 1'b1; q_step <= 2'd2; end
              2'd2: begin sio_c <= 1'b1; sio_d_oe <= 1'b0; q_step <= 2'd3; end
              2'd3: begin
                q_step <= 2'd0;
                if ((state == S_STOP1) && is_read && !phase2) begin
                  phase2 <= 1'b1;
                  sh_tx  <= {DEV_ADDR, 1'b1}; // 0x79
                  state  <= S_GAP;
                end
                else begin
                  busy  <= 1'b0;
                  state <= S_IDLE;
                end
              end
            endcase
          end

          S_GAP: begin
            sio_c    <= 1'b1;
            sio_d_oe <= 1'b0;
            state    <= S_START2;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

endmodule
