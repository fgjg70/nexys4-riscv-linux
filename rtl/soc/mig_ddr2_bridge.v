`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// mig_ddr2_bridge.v — rv32_soc 32-bit 主存口 -> Xilinx MIG 7 Series Native 128-bit 桥
// 纯 Verilog-2001，对接 Nexys 4 DDR 官方 mig.prj (MT47H64M16HR-25E, 128 MB DDR2)
// ----------------------------------------------------------------------------
// 地址换算:
//   - 128 MB DDR2 = 2^27 字节 -> ram_addr[26:0]
//   - 16-bit DQ 颗粒字地址 = ram_addr[26:1] (26 位)
//   - 4:1 PHY 比例下每次 Native 突发为 128-bit = 8×16-bit = 16 字节 (4 个 32-bit 字)
//   - app_addr[26:0] = {1'b0, ram_addr[26:4], 3'b000}，lane = ram_addr[3:2]
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

  reg [1:0] state;
  reg [1:0] lane_r;
  reg       cmd_done;
  reg       wdf_done;

  assign ram_err     = 1'b0;
  assign app_wdf_end = app_wdf_wren;

  wire [1:0]   in_lane = ram_addr[3:2];
  wire [26:0]  mig_addr_w = {1'b0, ram_addr[26:4], 3'b000};
  wire [127:0] wdata_128  = {4{ram_wdata}};
  wire [15:0]  wmask_128  = (in_lane == 2'd0) ? {12'hFFF, ~ram_wstrb} :
                            (in_lane == 2'd1) ? {8'hFF,   ~ram_wstrb, 4'hF} :
                            (in_lane == 2'd2) ? {4'hF,    ~ram_wstrb, 8'hFF} :
                                                {~ram_wstrb, 12'hFFF};

  wire [31:0] rd_lane_word = (lane_r == 2'd0) ? app_rd_data[ 31:  0] :
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
      cmd_done     <= 1'b0;
      wdf_done     <= 1'b0;
    end
    else begin
      ram_ack <= 1'b0;

      case (state)
        S_IDLE: begin
          app_en       <= 1'b0;
          app_wdf_wren <= 1'b0;
          if (init_calib_complete && ram_req && !ram_ack) begin
            app_addr <= mig_addr_w;
            lane_r   <= in_lane;
            if (ram_we) begin
              app_cmd      <= CMD_WRITE;
              app_en       <= 1'b1;
              app_wdf_data <= wdata_128;
              app_wdf_mask <= wmask_128;
              app_wdf_wren <= 1'b1;
              cmd_done     <= 1'b0;
              wdf_done     <= 1'b0;
              state        <= S_WRITE;
            end
            else begin
              app_cmd <= CMD_READ;
              app_en  <= 1'b1;
              state   <= S_READ_CMD;
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
            ram_rdata <= rd_lane_word;
            ram_ack   <= 1'b1;
            state     <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
