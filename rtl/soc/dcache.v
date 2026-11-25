`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// dcache.v — 4 KB 直接映射 VIPT 安全回写数据缓存 + MMIO 旁路 + FENCE.I 清洗
// 纯 Verilog-2001，128 行 × 32 字节 (index = addr[11:5] 严格落在 4 KB 页内)
// ----------------------------------------------------------------------------
// 特性:
//   - data_ram (1024×32b) 独立无复位 posedge clk 块 -> 100% 推断为 1 块 RAMB36E1；
//   - tag_ram (128×20b) 采用分布式 RAM 并在 MEM 拍预计算 q_hit_r，使 WB 拍
//     dbus_stall 仅 1 级 LUT (消除 BRAM Tag 读出+比较导致的 6 ns 关键路径瓶颈)；
//   - DDR2 主存区 (RAM_BASE/RAM_MASK) 走 Write-Back / Write-Allocate 缓存，命中 1 拍零停顿；
//   - 背靠背同地址 Store -> Load/Store 走字节合并直通旁路，零停顿无读旧值风险；
//   - BootROM / CLINT / PLIC / UART / SPI / VGA / OV5640 及未映射区走非缓存直连旁路；
//   - FENCE.I (fencei_req) 扫描并回写全部脏行后同步拉高 icache_flush 与 fencei_done。
// ============================================================================

module dcache #(
  parameter [31:0] RAM_BASE = `SOC_RAM_BASE,
  parameter [31:0] RAM_MASK = `SOC_RAM_MASK
)(
  input  wire        clk,
  input  wire        rst,

  // CPU 数据总线接口 (MEM 拍发起，WB 拍返回数据/停顿/故障)
  input  wire        dbus_re,
  input  wire        dbus_we,
  input  wire [31:0] dbus_addr,
  input  wire [31:0] dbus_wdata,
  input  wire [3:0]  dbus_wstrb,
  output reg  [31:0] dbus_rdata,
  output reg         dbus_stall,
  output reg         dbus_fault,

  // FENCE.I 一致性清洗握手
  input  wire        fencei_req,
  output reg         fencei_done,
  output reg         icache_flush,

  // 下游统一内存总线主口 (32-bit 字事务)
  output reg         mem_req,
  output reg         mem_we,
  output reg  [31:0] mem_addr,
  output reg  [31:0] mem_wdata,
  output reg  [3:0]  mem_wstrb,
  input  wire        mem_ack,
  input  wire [31:0] mem_rdata,
  input  wire        mem_err
);

  localparam SETS = 128;
  localparam [2:0]
    S_IDLE       = 3'd0,
    S_WB         = 3'd1,
    S_REFILL     = 3'd2,
    S_UNCACHED   = 3'd3,
    S_RESP       = 3'd4,
    S_FLUSH_SCAN = 3'd5,
    S_FLUSH_WB   = 3'd6,
    S_FLUSH_DONE = 3'd7;

  // 存储阵列: 128-bit valid/dirty FF + 128×20b 分布式 Tag RAM + 1024×32b Data BRAM
  reg  [SETS-1:0] valid_arr;
  reg  [SETS-1:0] dirty_arr;
  (* ram_style = "distributed" *) reg [19:0] tag_ram  [0:SETS-1];
  (* ram_style = "block" *)       reg [31:0] data_ram [0:1023];

  reg  [31:0] data_ram_q;
  reg  [19:0] tag_q;

  reg  [2:0]  state;

  // 锁存的上一拍 MEM 请求 (当前位于 WB 段)
  reg         q_valid;
  reg         q_we;
  reg  [31:0] q_addr;
  reg  [31:0] q_wdata;
  reg  [3:0]  q_wstrb;
  reg         q_hit_r;
  reg         q_cacheable_r;
  reg         vld_q;
  reg         drt_q;

  // 旁路覆盖 (背靠背同字 Store->Load / 缺失填充回传 / 拆字尾拍保持)
  reg         use_fwd_q;
  reg  [31:0] fwd_data_q;

  // 缺失回写 / 填充 / 清洗状态寄存器
  reg  [2:0]  word_cnt;
  reg  [6:0]  flush_idx;
  reg         wb_read_wait;
  reg  [31:0] resp_rdata;
  reg         resp_err;
  reg         rf_err;

  function [31:0] merge_bytes;
    input [31:0] old_w;
    input [31:0] new_w;
    input [3:0]  strb;
    begin
      merge_bytes[ 7: 0] = strb[0] ? new_w[ 7: 0] : old_w[ 7: 0];
      merge_bytes[15: 8] = strb[1] ? new_w[15: 8] : old_w[15: 8];
      merge_bytes[23:16] = strb[2] ? new_w[23:16] : old_w[23:16];
      merge_bytes[31:24] = strb[3] ? new_w[31:24] : old_w[31:24];
    end
  endfunction

  wire [31:0] data_q = use_fwd_q ? fwd_data_q : data_ram_q;

  // 1 级触发器直接判命中/缺失 -> 彻底消除 dbus_stall 前端的 Tag 比较器延迟!
  wire q_hit     = q_valid && q_hit_r;
  wire q_miss    = q_valid && !q_hit_r;
  wire store_hit = (state == S_IDLE) && q_hit && q_we;

  wire [31:0] store_merged  = merge_bytes(data_q, q_wdata, q_wstrb);
  wire [31:0] refill_merged = merge_bytes(mem_rdata, q_wdata, q_wstrb);

  wire [6:0]  in_idx  = dbus_addr[11:5];
  wire [9:0]  in_word = dbus_addr[11:2];
  wire [6:0]  q_idx   = q_addr[11:5];
  wire [2:0]  q_wrd   = q_addr[4:2];
  wire [19:0] q_tag   = q_addr[31:12];

  wire        in_req       = dbus_re || dbus_we;
  wire        in_cacheable = ((dbus_addr & RAM_MASK) == RAM_BASE);
  wire [19:0] in_tag_val   = tag_ram[in_idx];
  wire        in_tag_hit   = in_cacheable && valid_arr[in_idx] && (in_tag_val == dbus_addr[31:12]);
  wire        same_word_fwd = store_hit && in_req && (dbus_addr[31:2] == q_addr[31:2]);

  // ---- 统一单读写口 Data BRAM 驱动 (独立无异步复位块 -> Vivado RAMB36E1) ----
  wire dc_lookup_en =
      ((state == S_IDLE) && !q_miss && !(fencei_req && !in_req) && in_req) ||
      ((state == S_RESP) && in_req);
  wire dc_wb_rd_en =
      ((state == S_WB) || (state == S_FLUSH_WB)) && wb_read_wait;

  wire        dc_data_we    = store_hit || ((state == S_REFILL) && mem_ack);
  wire [9:0]  dc_data_waddr = (state == S_IDLE) ? q_addr[11:2] : {q_idx, word_cnt};
  wire [31:0] dc_data_wdata = (state == S_IDLE) ? store_merged :
                              (((word_cnt == q_wrd) && q_we) ? refill_merged : mem_rdata);

  wire        dc_data_re    = (dc_lookup_en && !same_word_fwd) || dc_wb_rd_en;
  wire [9:0]  dc_data_raddr = (state == S_WB)       ? {q_idx, word_cnt} :
                              (state == S_FLUSH_WB) ? {flush_idx, word_cnt} :
                                                      in_word;

  wire        dc_tag_we     = (state == S_REFILL) && mem_ack && (word_cnt == 3'd7) &&
                              !(mem_err || rf_err);

  always @(posedge clk) begin
    if (dc_data_we)
      data_ram[dc_data_waddr] <= dc_data_wdata;
    if (dc_data_re)
      data_ram_q <= data_ram[dc_data_raddr];
  end

  always @(posedge clk) begin
    if (dc_tag_we)
      tag_ram[q_idx] <= q_tag;
  end

  // 组合输出控制
  always @(*) begin
    dbus_stall   = 1'b0;
    dbus_rdata   = data_q;
    dbus_fault   = 1'b0;
    fencei_done  = 1'b0;
    icache_flush = 1'b0;
    mem_req      = 1'b0;
    mem_we       = 1'b0;
    mem_addr     = 32'd0;
    mem_wdata    = 32'd0;
    mem_wstrb    = 4'b0000;

    case (state)
      S_IDLE: begin
        if (q_miss) begin
          dbus_stall = 1'b1;
        end
        else begin
          dbus_stall = 1'b0;
          dbus_rdata = data_q;
          dbus_fault = 1'b0;
        end
      end

      S_WB: begin
        dbus_stall = 1'b1;
        if (!wb_read_wait) begin
          mem_req   = 1'b1;
          mem_we    = 1'b1;
          mem_addr  = {tag_q, q_idx, word_cnt, 2'b00};
          mem_wdata = data_ram_q;
          mem_wstrb = 4'b1111;
        end
      end

      S_REFILL: begin
        dbus_stall = 1'b1;
        mem_req    = 1'b1;
        mem_we     = 1'b0;
        mem_addr   = {q_addr[31:5], word_cnt, 2'b00};
      end

      S_UNCACHED: begin
        dbus_stall = 1'b1;
        mem_req    = 1'b1;
        mem_we     = q_we;
        mem_addr   = {q_addr[31:2], 2'b00};
        mem_wdata  = q_wdata;
        mem_wstrb  = q_we ? q_wstrb : 4'b0000;
      end

      S_RESP: begin
        dbus_stall = 1'b0;
        dbus_rdata = resp_rdata;
        dbus_fault = resp_err;
      end

      S_FLUSH_SCAN: begin
        dbus_stall = 1'b0;
      end

      S_FLUSH_WB: begin
        dbus_stall = 1'b0;
        if (!wb_read_wait) begin
          mem_req   = 1'b1;
          mem_we    = 1'b1;
          mem_addr  = {tag_q, flush_idx, word_cnt, 2'b00};
          mem_wdata = data_ram_q;
          mem_wstrb = 4'b1111;
        end
      end

      S_FLUSH_DONE: begin
        dbus_stall   = 1'b0;
        fencei_done  = 1'b1;
        icache_flush = 1'b1;
      end

      default: ;
    endcase
  end

  integer i;
  initial begin
    valid_arr  = {SETS{1'b0}};
    dirty_arr  = {SETS{1'b0}};
    data_ram_q = 32'd0;
    for (i = 0; i < SETS; i = i + 1) tag_ram[i] = 20'd0;
    for (i = 0; i < 1024; i = i + 1) data_ram[i] = 32'd0;
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state         <= S_IDLE;
      valid_arr     <= {SETS{1'b0}};
      dirty_arr     <= {SETS{1'b0}};
      q_valid       <= 1'b0;
      q_we          <= 1'b0;
      q_addr        <= 32'd0;
      q_wdata       <= 32'd0;
      q_wstrb       <= 4'b0000;
      q_hit_r       <= 1'b0;
      q_cacheable_r <= 1'b0;
      vld_q         <= 1'b0;
      drt_q         <= 1'b0;
      tag_q         <= 20'd0;
      use_fwd_q     <= 1'b0;
      fwd_data_q    <= 32'd0;
      word_cnt      <= 3'd0;
      flush_idx     <= 7'd0;
      wb_read_wait  <= 1'b0;
      resp_rdata    <= 32'd0;
      resp_err      <= 1'b0;
      rf_err        <= 1'b0;
    end
    else begin
      case (state)
        S_IDLE: begin
          if (store_hit) begin
            dirty_arr[q_idx] <= 1'b1;
          end

          if (q_miss) begin
            word_cnt <= 3'd0;
            rf_err   <= 1'b0;
            if (!q_cacheable_r) begin
              state <= S_UNCACHED;
            end
            else if (vld_q && drt_q) begin
              wb_read_wait <= 1'b1;
              state        <= S_WB;
            end
            else begin
              state <= S_REFILL;
            end
          end
          else if (fencei_req && !in_req) begin
            q_valid   <= 1'b0;
            flush_idx <= 7'd0;
            state     <= S_FLUSH_SCAN;
          end
          else begin
            q_valid <= in_req;
            q_we    <= dbus_we;
            q_addr  <= dbus_addr;
            q_wdata <= dbus_wdata;
            q_wstrb <= dbus_wstrb;
            if (in_req) begin
              q_hit_r       <= in_tag_hit;
              q_cacheable_r <= in_cacheable;
              vld_q         <= valid_arr[in_idx];
              drt_q         <= (store_hit && (in_idx == q_idx)) ? 1'b1 : dirty_arr[in_idx];
              tag_q         <= in_tag_val;
              use_fwd_q     <= same_word_fwd;
              if (same_word_fwd) fwd_data_q <= store_merged;
            end
          end
        end

        S_WB: begin
          if (wb_read_wait) begin
            wb_read_wait <= 1'b0;
          end
          else if (mem_ack) begin
            if (word_cnt == 3'd7) begin
              dirty_arr[q_idx] <= 1'b0;
              word_cnt         <= 3'd0;
              state            <= S_REFILL;
            end
            else begin
              word_cnt     <= word_cnt + 3'd1;
              wb_read_wait <= 1'b1;
            end
          end
        end

        S_REFILL: begin
          if (mem_ack) begin
            if ((word_cnt == q_wrd) && q_we) begin
              resp_rdata <= refill_merged;
              use_fwd_q  <= 1'b1;
              fwd_data_q <= refill_merged;
            end
            else if (word_cnt == q_wrd) begin
              resp_rdata <= mem_rdata;
              use_fwd_q  <= 1'b1;
              fwd_data_q <= mem_rdata;
            end

            if (mem_err) rf_err <= 1'b1;

            if (word_cnt == 3'd7) begin
              if (!(mem_err || rf_err)) begin
                valid_arr[q_idx] <= 1'b1;
                dirty_arr[q_idx] <= q_we;
              end
              else begin
                // 填充失败时显式失效该槽，防止被中途覆写 data_ram 的旧清洁行伪命中
                valid_arr[q_idx] <= 1'b0;
                dirty_arr[q_idx] <= 1'b0;
              end
              resp_err <= mem_err || rf_err;
              state    <= S_RESP;
            end
            else begin
              word_cnt <= word_cnt + 3'd1;
            end
          end
        end

        S_UNCACHED: begin
          if (mem_ack) begin
            resp_rdata <= mem_rdata;
            use_fwd_q  <= 1'b1;
            fwd_data_q <= mem_rdata;
            resp_err   <= mem_err;
            state      <= S_RESP;
          end
        end

        S_RESP: begin
          state   <= S_IDLE;
          q_valid <= in_req;
          q_we    <= dbus_we;
          q_addr  <= dbus_addr;
          q_wdata <= dbus_wdata;
          q_wstrb <= dbus_wstrb;
          if (in_req) begin
            q_hit_r       <= in_tag_hit;
            q_cacheable_r <= in_cacheable;
            vld_q         <= valid_arr[in_idx];
            drt_q         <= dirty_arr[in_idx];
            tag_q         <= in_tag_val;
            use_fwd_q     <= 1'b0;
          end
        end

        S_FLUSH_SCAN: begin
          if (valid_arr[flush_idx] && dirty_arr[flush_idx]) begin
            tag_q        <= tag_ram[flush_idx];
            word_cnt     <= 3'd0;
            wb_read_wait <= 1'b1;
            state        <= S_FLUSH_WB;
          end
          else if (flush_idx == 7'd127) begin
            state <= S_FLUSH_DONE;
          end
          else begin
            flush_idx <= flush_idx + 7'd1;
          end
        end

        S_FLUSH_WB: begin
          if (wb_read_wait) begin
            wb_read_wait <= 1'b0;
          end
          else if (mem_ack) begin
            if (word_cnt == 3'd7) begin
              dirty_arr[flush_idx] <= 1'b0;
              if (flush_idx == 7'd127) begin
                state <= S_FLUSH_DONE;
              end
              else begin
                flush_idx <= flush_idx + 7'd1;
                state     <= S_FLUSH_SCAN;
              end
            end
            else begin
              word_cnt     <= word_cnt + 3'd1;
              wb_read_wait <= 1'b1;
            end
          end
        end

        S_FLUSH_DONE: begin
          state   <= S_IDLE;
          q_valid <= 1'b0;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
