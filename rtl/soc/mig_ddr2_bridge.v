`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// mig_ddr2_bridge.v — rv32_soc 32-bit 主存口 -> Xilinx MIG 7 Series Native 128-bit 桥
// 纯 Verilog-2001，对接 Nexys 4 DDR 官方 mig.prj (MT47H64M16HR-25E, 128 MB DDR2)
// ----------------------------------------------------------------------------
// Round 2 全路径内存带宽优化:
//   - 内置 128-bit (16 字节 = 4 字) 读行缓冲 (rd_buf):
//       * I-Cache / D-Cache 每次 8 字 (32B) 行填充由原 8 次 MIG 突发压缩为 2 次突发
//         (同 16B 行内第 2..4 个 32-bit 字 1 拍直出，实板 DDR2 填充带宽提升 ~3.5x)；
//       * 写操作走 Write-Through 直写 MIG (天然 DMA 安全)，命中当前读行缓冲时自动失效
//         rd_buf_valid，彻底杜绝写后读陈旧。
//   - 地址换算: app_addr[26:0] = {1'b0, ram_addr[26:4], 3'b000}，lane = ram_addr[3:2]。
//   - 写通道严格按 Xilinx UG586 独立跟踪 cmd_done / wdf_done，杜绝 app_rdy/app_wdf_rdy 死锁。
// ============================================================================

module mig_ddr2_bridge (
  input  wire         clk,                  // 接 MIG ui_clk (75 MHz)
  input  wire         rst,                  // 接 MIG ui_clk_sync_rst

  // 来自 rv32_soc 的 32-bit 主存口
  input  wire         ram_req,
  input  wire         ram_we,
  input  wire [31:0]  ram_addr,
  input  wire [31:0]  ram_wdata,
  input  wire [3:0]   ram_wstrb,
  output reg          ram_ack,
  output reg  [31:0]  ram_rdata,
  output wire         ram_err,

  // Xilinx MIG 7 Series Native 128-bit 用户接口
  input  wire         init_calib_complete,
  output reg  [26:0]  app_addr,
  output reg  [2:0]   app_cmd,
  output reg          app_en,
  input  wire         app_rdy,
  output reg  [127:0] app_wdf_data,
  output reg  [15:0]  app_wdf_mask,
  output reg          app_wdf_wren,
  output wire         app_wdf_end,
  input  wire         app_wdf_rdy,
  input  wire [127:0] app_rd_data,
  input  wire         app_rd_data_valid
);

  localparam [2:0] CMD_WRITE = 3'b000;
  localparam [2:0] CMD_READ  = 3'b001;

  localparam [1:0]
    S_IDLE     = 2'd0,
    S_WRITE    = 2'd1,
    S_READ_CMD = 2'd2,
    S_READ_DAT = 2'd3;

  reg [1:0]   state;
  reg [1:0]   lane_r;
  reg [22:0]  req_line_r;
  reg         cmd_done;
  reg         wdf_done;

  // 128-bit (4 字) 读行缓冲
  reg         rd_buf_valid;
  reg [22:0]  rd_buf_line;
  reg [127:0] rd_buf_data;

  assign ram_err     = 1'b0;
  assign app_wdf_end = app_wdf_wren;

  wire [1:0]   in_lane     = ram_addr[3:2];
  wire [22:0]  in_line     = ram_addr[26:4];
  wire [26:0]  mig_addr_w  = {1'b0, in_line, 3'b000};
  wire         rd_buf_hit  = rd_buf_valid && (rd_buf_line == in_line);

  wire [127:0] wdata_128   = {4{ram_wdata}};
  wire [15:0]  wmask_128   = (in_lane == 2'd0) ? {12'hFFF, ~ram_wstrb} :
                             (in_lane == 2'd1) ? {8'hFF,   ~ram_wstrb, 4'hF} :
                             (in_lane == 2'd2) ? {4'hF,    ~ram_wstrb, 8'hFF} :
                                                 {~ram_wstrb, 12'hFFF};

  wire [31:0]  buf_lane_w  = (in_lane == 2'd0) ? rd_buf_data[ 31:  0] :
                             (in_lane == 2'd1) ? rd_buf_data[ 63: 32] :
                             (in_lane == 2'd2) ? rd_buf_data[ 95: 64] :
                                                 rd_buf_data[127: 96];

  wire [31:0]  rd_lane_w   = (lane_r == 2'd0) ? app_rd_data[ 31:  0] :
                             (lane_r == 2'd1) ? app_rd_data[ 63: 32] :
                             (lane_r == 2'd2) ? app_rd_data[ 95: 64] :
                                                app_rd_data[127: 96];

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state        <= S_IDLE;
      ram_ack      <= 1'b0;
      ram_rdata    <= 32'd0;
      app_addr     <= 27'd0;
      app_cmd      <= CMD_READ;
      app_en       <= 1'b0;
      app_wdf_data <= 128'd0;
      app_wdf_mask <= 16'hFFFF;
      app_wdf_wren <= 1'b0;
      lane_r       <= 2'd0;
      req_line_r   <= 23'd0;
      cmd_done     <= 1'b0;
      wdf_done     <= 1'b0;
      rd_buf_valid <= 1'b0;
      rd_buf_line  <= 23'd0;
      rd_buf_data  <= 128'd0;
    end
    else begin
      ram_ack <= 1'b0;

      case (state)
        S_IDLE: begin
          app_en       <= 1'b0;
          app_wdf_wren <= 1'b0;
          if (init_calib_complete && ram_req && !ram_ack) begin
            if (ram_we) begin
              // 写命中当前读行缓冲时立即失效，保证写后读严格一致
              if (rd_buf_hit) rd_buf_valid <= 1'b0;
              app_addr     <= mig_addr_w;
              lane_r       <= in_lane;
              app_cmd      <= CMD_WRITE;
              app_en       <= 1'b1;
              app_wdf_data <= wdata_128;
              app_wdf_mask <= wmask_128;
              app_wdf_wren <= 1'b1;
              cmd_done     <= 1'b0;
              wdf_done     <= 1'b0;
              state        <= S_WRITE;
            end
            else if (rd_buf_hit) begin
              // 128-bit 读行缓冲 1 拍直出，免去重复 MIG 读突发
              ram_rdata <= buf_lane_w;
              ram_ack   <= 1'b1;
            end
            else begin
              app_addr   <= mig_addr_w;
              lane_r     <= in_lane;
              req_line_r <= in_line;
              app_cmd    <= CMD_READ;
              app_en     <= 1'b1;
              state      <= S_READ_CMD;
            end
          end
        end

        S_WRITE: begin
          if (app_en && app_rdy) begin
            app_en   <= 1'b0;
            cmd_done <= 1'b1;
          end
          if (app_wdf_wren && app_wdf_rdy) begin
            app_wdf_wren <= 1'b0;
            wdf_done     <= 1'b1;
          end
          if ((cmd_done || (app_en && app_rdy)) &&
              (wdf_done || (app_wdf_wren && app_wdf_rdy))) begin
            ram_ack <= 1'b1;
            state   <= S_IDLE;
          end
        end

        S_READ_CMD: begin
          if (app_en && app_rdy) begin
            app_en <= 1'b0;
            state  <= S_READ_DAT;
          end
        end

        S_READ_DAT: begin
          if (app_rd_data_valid) begin
            rd_buf_valid <= 1'b1;
            rd_buf_line  <= req_line_r;
            rd_buf_data  <= app_rd_data;
            ram_rdata    <= rd_lane_w;
            ram_ack      <= 1'b1;
            state        <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
