`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// mig_ddr2_bridge.v — 100 MHz SoC <-> 75 MHz MIG 7 Series 128-bit 异步 FIFO 解耦桥
// 纯 Verilog-2001，对接 Nexys 4 DDR 官方 mig.prj (MT47H64M16HR-25E, 128 MB DDR2)
// ----------------------------------------------------------------------------
// Round 4 跨时钟域与带宽协同架构:
//   1) 128-bit 宽边界双异步 FIFO 解耦 (sys_clk=100 MHz <-> mig_clk=75 MHz):
//        * 128-bit (16 B = 4 字) 读行缓冲 rd_buf 留在 100 MHz sys_clk 前端，
//          同 16 B 行内后 3 个 32-bit 字 1 拍直出 (10 ns)，零 CDC 开销；
//          32 B D-Cache 填充仅需 2 次 128-bit 跨时钟域，64 B I-Cache 仅需 4 次；
//        * u_req_fifo (16 项 × 172-bit: {is_write, app_addr[26:0], wmask[15:0], wdata[127:0]})
//          同时按程序顺序承载写请求与读请求；
//        * u_rsp_fifo (8 项 × 128-bit) 回传 MIG 读出的整行 128-bit 数据。
//   2) Posted Write (非阻塞缓冲写) + 严格写后读保序:
//        * 写请求只要 u_req_fifo 未满即在 100 MHz 侧 1 拍应答 (ram_ack)，可全速吞下
//          整行 32 B D-Cache 脏行回写 (8 字写仅 80 ns)，隐藏 100% 写 CDC 与 DDR2 写延迟；
//        * 写命中 rd_buf 时立即失效 rd_buf_valid，且后继读请求进入同一条 u_req_fifo，
//          MIG 后端严格按 FIFO 顺序先提交全部在途写再执行读，彻底杜绝写后读陈旧。
//   3) MIG 后端严格按 Xilinx UG586 独立跟踪 cmd_done / wdf_done，杜绝 app_rdy /
//      app_wdf_rdy 握手死锁；init_calib_complete 经 2-FF ASYNC_REG 同步至 sys_clk。
// ============================================================================

module mig_ddr2_bridge #(
  parameter REQ_ADDR_W = 4,   // 请求异步 FIFO 深度 = 16 (容纳 2 行完整 32 B D$ 脏行回写)
  parameter RSP_ADDR_W = 3    // 读响应异步 FIFO 深度 = 8
)(
  // ---- SoC 侧时钟域 (100 MHz) ----
  input  wire         sys_clk,
  input  wire         sys_rst,

  // 来自 rv32_soc 的 32-bit 主存口 (sys_clk 域)
  input  wire         ram_req,
  input  wire         ram_we,
  input  wire [31:0]  ram_addr,
  input  wire [31:0]  ram_wdata,
  input  wire [3:0]   ram_wstrb,
  output reg          ram_ack,
  output reg  [31:0]  ram_rdata,
  output wire         ram_err,

  // ---- MIG 侧时钟域 (ui_clk = 75 MHz) ----
  input  wire         mig_clk,
  input  wire         mig_rst,

  // Xilinx MIG 7 Series Native 128-bit 用户接口 (mig_clk 域)
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
  localparam       REQ_W     = 1 + 27 + 16 + 128; // 172 bits

  assign ram_err     = 1'b0;
  assign app_wdf_end = app_wdf_wren;

  // ==========================================================================
  // 1. init_calib_complete 跨时钟域同步 (mig_clk -> sys_clk)
  // ==========================================================================
  (* ASYNC_REG = "TRUE" *) reg [1:0] calib_sync;
  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) calib_sync <= 2'b00;
    else         calib_sync <= {calib_sync[0], init_calib_complete};
  end
  wire calib_done_sys = calib_sync[1];

  // ==========================================================================
  // 2. 双时钟 128-bit 异步 FIFO (零厂商原语，复用已验证 async_fifo.v)
  // ==========================================================================
  wire             req_wr_en;
  wire [REQ_W-1:0] req_wr_data;
  wire             req_wr_full;
  wire             req_rd_en;
  wire [REQ_W-1:0] req_rd_data;
  wire             req_rd_empty;

  async_fifo #(
    .DATA_W (REQ_W),
    .ADDR_W (REQ_ADDR_W)
  ) u_req_fifo (
    .wr_clk       (sys_clk),
    .wr_rst       (sys_rst),
    .wr_en        (req_wr_en),
    .wr_data      (req_wr_data),
    .wr_full      (req_wr_full),
    .wr_ovf_pulse (),
    .rd_clk       (mig_clk),
    .rd_rst       (mig_rst),
    .rd_en        (req_rd_en),
    .rd_data      (req_rd_data),
    .rd_empty     (req_rd_empty)
  );

  wire         rsp_wr_en;
  wire         rsp_wr_full;
  wire         rsp_rd_en;
  wire [127:0] rsp_rd_data;
  wire         rsp_rd_empty;

  async_fifo #(
    .DATA_W (128),
    .ADDR_W (RSP_ADDR_W)
  ) u_rsp_fifo (
    .wr_clk       (mig_clk),
    .wr_rst       (mig_rst),
    .wr_en        (rsp_wr_en),
    .wr_data      (app_rd_data),
    .wr_full      (rsp_wr_full),
    .wr_ovf_pulse (),
    .rd_clk       (sys_clk),
    .rd_rst       (sys_rst),
    .rd_en        (rsp_rd_en),
    .rd_data      (rsp_rd_data),
    .rd_empty     (rsp_rd_empty)
  );

  // ==========================================================================
  // 3. sys_clk (100 MHz) 前端状态机 + 128-bit 读行缓冲 + Posted Write
  // ==========================================================================
  localparam [1:0]
    S_IDLE    = 2'd0,
    S_RD_WAIT = 2'd1,
    S_RD_DONE = 2'd2;

  reg [1:0]   s_state;
  reg [1:0]   lane_r;
  reg [22:0]  req_line_r;

  // 128-bit (4 字) 读行缓冲 (工作在 100 MHz sys_clk 域)
  reg         rd_buf_valid;
  reg [22:0]  rd_buf_line;
  reg [127:0] rd_buf_data;

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

  wire [31:0]  rsp_lane_w  = (lane_r == 2'd0)  ? rsp_rd_data[ 31:  0] :
                             (lane_r == 2'd1)  ? rsp_rd_data[ 63: 32] :
                             (lane_r == 2'd2)  ? rsp_rd_data[ 95: 64] :
                                                 rsp_rd_data[127: 96];

  wire sys_can_accept = (s_state == S_IDLE) && calib_done_sys && ram_req && !ram_ack;
  wire req_push_wr    = sys_can_accept &&  ram_we && !req_wr_full;
  wire req_push_rd    = sys_can_accept && !ram_we && !rd_buf_hit && !req_wr_full;

  assign req_wr_en    = req_push_wr || req_push_rd;
  assign req_wr_data  = {ram_we, mig_addr_w, wmask_128, wdata_128};
  assign rsp_rd_en    = (s_state == S_RD_WAIT) && !rsp_rd_empty;

  always @(posedge sys_clk or posedge sys_rst) begin
    if (sys_rst) begin
      s_state      <= S_IDLE;
      ram_ack      <= 1'b0;
      ram_rdata    <= 32'd0;
      lane_r       <= 2'd0;
      req_line_r   <= 23'd0;
      rd_buf_valid <= 1'b0;
      rd_buf_line  <= 23'd0;
      rd_buf_data  <= 128'd0;
    end
    else begin
      ram_ack <= 1'b0;

      case (s_state)
        S_IDLE: begin
          if (sys_can_accept) begin
            if (ram_we) begin
              // Posted Write: 只要 u_req_fifo 未满即刻入队并 1 拍应答；命中读行缓冲时失效
              if (!req_wr_full) begin
                if (rd_buf_hit) rd_buf_valid <= 1'b0;
                ram_ack <= 1'b1;
              end
            end
            else if (rd_buf_hit) begin
              // 128-bit 读行缓冲 100 MHz 侧 1 拍直出，免去跨时钟域与重复 MIG 突发
              ram_rdata <= buf_lane_w;
              ram_ack   <= 1'b1;
            end
            else if (!req_wr_full) begin
              // 读缺失入队至同一条 u_req_fifo (严格排在全部先序写之后)
              lane_r     <= in_lane;
              req_line_r <= in_line;
              s_state    <= S_RD_WAIT;
            end
          end
        end

        S_RD_WAIT: begin
          if (!rsp_rd_empty) begin
            // rsp_rd_en=1 于本拍上升沿弹出 128-bit 数据，下拍进入 S_RD_DONE 锁存
            s_state <= S_RD_DONE;
          end
        end

        S_RD_DONE: begin
          rd_buf_valid <= 1'b1;
          rd_buf_line  <= req_line_r;
          rd_buf_data  <= rsp_rd_data;
          ram_rdata    <= rsp_lane_w;
          ram_ack      <= 1'b1;
          s_state      <= S_IDLE;
        end

        default: s_state <= S_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // 4. mig_clk (75 MHz) 后端状态机 (严格保序消费 u_req_fifo + UG586 握手)
  // ==========================================================================
  localparam [2:0]
    M_IDLE     = 3'd0,
    M_LAUNCH   = 3'd1,
    M_WRITE    = 3'd2,
    M_READ_CMD = 3'd3,
    M_READ_DAT = 3'd4;

  reg [2:0] m_state;
  reg       cmd_done;
  reg       wdf_done;

  wire         m_is_wr = req_rd_data[171];
  wire [26:0]  m_addr  = req_rd_data[170:144];
  wire [15:0]  m_wmask = req_rd_data[143:128];
  wire [127:0] m_wdata = req_rd_data[127:0];

  assign req_rd_en = (m_state == M_IDLE) && init_calib_complete && !req_rd_empty;
  assign rsp_wr_en = (m_state == M_READ_DAT) && app_rd_data_valid && !rsp_wr_full;

  always @(posedge mig_clk or posedge mig_rst) begin
    if (mig_rst) begin
      m_state      <= M_IDLE;
      app_addr     <= 27'd0;
      app_cmd      <= CMD_READ;
      app_en       <= 1'b0;
      app_wdf_data <= 128'd0;
      app_wdf_mask <= 16'hFFFF;
      app_wdf_wren <= 1'b0;
      cmd_done     <= 1'b0;
      wdf_done     <= 1'b0;
    end
    else begin
      case (m_state)
        M_IDLE: begin
          app_en       <= 1'b0;
          app_wdf_wren <= 1'b0;
          if (init_calib_complete && !req_rd_empty) begin
            // req_rd_en=1 于本拍上升沿弹出请求，下拍在 M_LAUNCH 发射至 MIG
            m_state <= M_LAUNCH;
          end
        end

        M_LAUNCH: begin
          app_addr <= m_addr;
          if (m_is_wr) begin
            app_cmd      <= CMD_WRITE;
            app_en       <= 1'b1;
            app_wdf_data <= m_wdata;
            app_wdf_mask <= m_wmask;
            app_wdf_wren <= 1'b1;
            cmd_done     <= 1'b0;
            wdf_done     <= 1'b0;
            m_state      <= M_WRITE;
          end
          else begin
            app_cmd <= CMD_READ;
            app_en  <= 1'b1;
            m_state <= M_READ_CMD;
          end
        end

        M_WRITE: begin
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
            m_state <= M_IDLE;
          end
        end

        M_READ_CMD: begin
          if (app_en && app_rdy) begin
            app_en  <= 1'b0;
            m_state <= M_READ_DAT;
          end
        end

        M_READ_DAT: begin
          if (app_rd_data_valid && !rsp_wr_full) begin
            // rsp_wr_en=1 于本拍上升沿写入 128-bit app_rd_data 到 u_rsp_fifo
            m_state <= M_IDLE;
          end
        end

        default: m_state <= M_IDLE;
      endcase
    end
  end

endmodule
