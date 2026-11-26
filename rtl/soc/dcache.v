`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// dcache.v — 8 KB 2 路 VIPT 回写 L1D + 256 B 0 拍并行直写 LUTRAM L0D (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// Round 3 容量与延迟协同升级:
//   1) L1D 容量翻倍至 8 KB 2 路组相联 (128 组 × 2 路 × 32 B，每路 4 KB 严格落于
//      4 KB 页内，路线 B 接 Sv32 DTLB 天然 VIPT 无别名；2×RAMB36E1 + 1-bit LRU)；
//   2) 内建 256 B (64 × 32-bit，单级原生 RAM64M 零片间 mux) 简单双口分布式 RAM 并行直写 L0D:
//        * 读口在 MEM 拍异步 0 拍直出 dbus_fast_hit / dbus_fast_rdata，CPU 在 MEM 拍
//          完成字节提取并打入 mem_wb_load_data FF，Load-Use 从 2 拍砍为 1 拍 (dist=2 零气泡)；
//        * 写口仅在 WB 确认无异常提交时同步更新 L0D (无脏行、无驱逐、无推测污染)；
//        * 背靠背同槽 Store->Load (6-bit 索引冲突检测) 自动退回 L1D store_merged 旁路；
//        * FENCE.I 单拍全清 L0D；L0D 缺失零额外延迟无缝退回并行查找的 1 拍 BRAM L1D。
// ============================================================================

module dcache #(
  parameter [31:0] RAM_BASE = `SOC_RAM_BASE,
  parameter [31:0] RAM_MASK = `SOC_RAM_MASK,
  parameter        L0_BITS  = 6             // 64 字 = 256 B (单级 RAM64M 零 bank mux 甜点)
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
  output wire        dbus_stall,
  output wire        dbus_fault,

  // L0D 0 拍异步快读口 (dbus_l0_addr 直连 ex_mem_alu_out FF，dbus_l0_en 保证处于 S_IDLE 单字对齐读)
  input  wire        dbus_l0_en,
  input  wire [31:0] dbus_l0_addr,
  output wire        dbus_fast_hit,
  output wire [31:0] dbus_fast_rdata,

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

  localparam SETS     = 128;
  localparam L0_N     = (1 << L0_BITS);
  localparam L0_TAG_W = 32 - L0_BITS - 2;

  localparam [2:0]
    S_IDLE       = 3'd0,
    S_WB         = 3'd1,
    S_REFILL     = 3'd2,
    S_UNCACHED   = 3'd3,
    S_RESP       = 3'd4,
    S_FLUSH_SCAN = 3'd5,
    S_FLUSH_WB   = 3'd6,
    S_FLUSH_DONE = 3'd7;

  // ---- 8 KB 2 路 VIPT L1D 存储阵列 ----
  reg  [SETS-1:0] valid0;
  reg  [SETS-1:0] valid1;
  reg  [SETS-1:0] dirty0;
  reg  [SETS-1:0] dirty1;
  reg  [SETS-1:0] lru_arr;
  (* ram_style = "distributed" *) reg [19:0] tag_ram0  [0:SETS-1];
  (* ram_style = "distributed" *) reg [19:0] tag_ram1  [0:SETS-1];
  (* ram_style = "block" *)       reg [31:0] data_ram0 [0:1023];
  (* ram_style = "block" *)       reg [31:0] data_ram1 [0:1023];

  reg  [31:0] data_ram0_q;
  reg  [31:0] data_ram1_q;

  // ---- 512 B 简单双口分布式 RAM 并行直写 L0D ----
  reg  [L0_N-1:0]                     l0_valid;
  (* ram_style = "distributed" *) reg [L0_TAG_W-1:0] l0_tag  [0:L0_N-1];
  (* ram_style = "distributed" *) reg [31:0]         l0_data [0:L0_N-1];

  reg  [2:0]  state;

  // 锁存的上一拍 MEM 请求 (当前位于 WB 段)
  reg         q_valid;
  reg         q_we;
  reg  [31:0] q_addr;
  reg  [31:0] q_wdata;
  reg  [3:0]  q_wstrb;
  reg         q_hit0_r;
  reg         q_hit1_r;
  reg         q_l0_hit_r;
  reg         q_cacheable_r;
  // Round 4 100 MHz 时序优化: dbus_stall / dbus_fault 纯 FF 直出 (0.46ns FDCE)，
  // 彻底消除 q_valid -> q_miss -> dbus_stall 2 级 LUT4 链 (~2.0 ns)
  reg         dbus_stall_r;
  reg         dbus_fault_r;
  reg         repl_way_q;
  reg         vld_q;
  reg         drt_q;
  reg  [19:0] tag_q;

  // 旁路覆盖 (背靠背同字 Store->Load / L0D 命中保底 / 缺失填充回传)
  reg         use_fwd_q;
  reg  [31:0] fwd_data_q;

  // 缺失回写 / 填充 / 清洗状态寄存器
  reg  [2:0]  word_cnt;
  reg  [7:0]  flush_slot;
  reg         wb_read_wait;
  reg  [31:0] resp_rdata;
  reg         resp_err;
  reg         rf_err;

  wire        flush_way = flush_slot[7];
  wire [6:0]  flush_idx = flush_slot[6:0];

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

  assign dbus_stall = dbus_stall_r;
  assign dbus_fault = dbus_fault_r;

  wire        q_l1_hit  = q_valid && (q_hit0_r || q_hit1_r);
  wire        q_hit_way = q_hit1_r;
  wire        q_hit     = q_valid && (q_hit0_r || q_hit1_r || q_l0_hit_r);
  wire        q_miss    = (state == S_IDLE) && dbus_stall_r;
  wire        store_hit = (state == S_IDLE) && q_l1_hit && q_we;

  wire [31:0] l1_data_q     = q_hit1_r ? data_ram1_q : data_ram0_q;
  wire [31:0] data_q        = use_fwd_q ? fwd_data_q : l1_data_q;
  wire [31:0] store_merged  = merge_bytes(data_q, q_wdata, q_wstrb);
  wire [31:0] refill_merged = merge_bytes(mem_rdata, q_wdata, q_wstrb);
  wire [31:0] wb_data_q     = (state == S_WB)
                              ? (repl_way_q ? data_ram1_q : data_ram0_q)
                              : (flush_way  ? data_ram1_q : data_ram0_q);

  wire [6:0]  in_idx  = dbus_addr[11:5];
  wire [9:0]  in_word = dbus_addr[11:2];
  wire [19:0] in_tag  = dbus_addr[31:12];
  wire [6:0]  q_idx   = q_addr[11:5];
  wire [2:0]  q_wrd   = q_addr[4:2];
  wire [19:0] q_tag   = q_addr[31:12];

  wire        in_req       = dbus_re || dbus_we;
  wire        in_cacheable = ((dbus_addr & RAM_MASK) == RAM_BASE);
  wire        in_hit0      = in_cacheable && valid0[in_idx] && (tag_ram0[in_idx] == in_tag);
  wire        in_hit1      = in_cacheable && valid1[in_idx] && (tag_ram1[in_idx] == in_tag);
  wire        same_word_fwd = store_hit && in_req && (dbus_addr[31:2] == q_addr[31:2]);

  // 同组紧邻访问的精确 LRU / 脏位前递 (避免 S_IDLE 同拍命中写脏/改 LRU 后紧跟同组缺失选错受害路)
  wire        same_set_hit_idle = (state == S_IDLE) && q_l1_hit && (in_idx == q_idx);
  wire        same_set_st_idle  = store_hit && (in_idx == q_idx);
  wire        eff_drt0          = (same_set_st_idle && !q_hit_way) ? 1'b1 : dirty0[in_idx];
  wire        eff_drt1          = (same_set_st_idle &&  q_hit_way) ? 1'b1 : dirty1[in_idx];
  wire        eff_lru           = same_set_hit_idle ? ~q_hit_way : lru_arr[in_idx];
  wire        vic_way           = !valid0[in_idx] ? 1'b0 : (!valid1[in_idx] ? 1'b1 : eff_lru);
  wire        vic_vld           = vic_way ? valid1[in_idx] : valid0[in_idx];
  wire        vic_drt           = vic_way ? eff_drt1       : eff_drt0;
  wire [19:0] vic_tag           = vic_way ? tag_ram1[in_idx] : tag_ram0[in_idx];

  // ---- 256 B L0D 异步 0 拍读 (直连 ex_mem_alu_out FF，零 LSU mux，单级 RAM64M;
  //      (* keep *) 锁定 l0_ctrl_ok 与 l0_tag_eq 并行收敛，使 l0_rd_hit 末级仅单 LUT2!) ----
  wire [L0_BITS-1:0]  l0_ridx  = dbus_l0_addr[L0_BITS+1:2];
  wire [L0_TAG_W-1:0] l0_rtag  = dbus_l0_addr[31:L0_BITS+2];
  wire [L0_BITS-1:0]  l0_widx  = q_addr[L0_BITS+1:2];
  wire [L0_TAG_W-1:0] l0_wtag  = q_addr[31:L0_BITS+2];
  wire [31:0]         l0_rdata = l0_data[l0_ridx];
  wire                l0_st_haz = store_hit && (l0_ridx == l0_widx);
  (* keep = "true" *) wire l0_ctrl_ok = (state == S_IDLE) && !q_miss && !fencei_req &&
                                        dbus_l0_en && !l0_st_haz && l0_valid[l0_ridx];
  (* keep = "true" *) wire l0_tag_eq  = (l0_tag[l0_ridx] == l0_rtag);
  wire                l0_rd_hit = l0_ctrl_ok && l0_tag_eq;

  assign dbus_fast_hit   = l0_rd_hit;
  assign dbus_fast_rdata = l0_rdata;

  // ---- 256 B L0D WB 确认提交写 ----
  wire                l0_commit_ok =
      ((state == S_IDLE) && q_hit && q_cacheable_r && (q_we || !q_l0_hit_r)) ||
      ((state == S_RESP) && q_cacheable_r && !resp_err);
  wire                l0_inval_err = (state == S_RESP) && q_cacheable_r && resp_err;
  wire [31:0]         l0_commit_wdata = (state == S_IDLE)
                                        ? (q_we ? store_merged : data_q)
                                        : resp_rdata;

  // ---- 2 路 Data BRAM 驱动 (独立无异步复位块 -> 2×RAMB36E1) ----
  wire dc_lookup_en =
      ((state == S_IDLE) && !q_miss && !(fencei_req && !in_req) && in_req) ||
      ((state == S_RESP) && in_req);
  wire dc_wb_rd_en =
      ((state == S_WB) || (state == S_FLUSH_WB)) && wb_read_wait;

  wire        dc_data_we0   = (store_hit && !q_hit_way) ||
                              ((state == S_REFILL) && mem_ack && !repl_way_q);
  wire        dc_data_we1   = (store_hit &&  q_hit_way) ||
                              ((state == S_REFILL) && mem_ack &&  repl_way_q);
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
    if (dc_data_we0)
      data_ram0[dc_data_waddr] <= dc_data_wdata;
    if (dc_data_re)
      data_ram0_q <= data_ram0[dc_data_raddr];
  end

  always @(posedge clk) begin
    if (dc_data_we1)
      data_ram1[dc_data_waddr] <= dc_data_wdata;
    if (dc_data_re)
      data_ram1_q <= data_ram1[dc_data_raddr];
  end

  always @(posedge clk) begin
    if (dc_tag_we && !repl_way_q) tag_ram0[q_idx] <= q_tag;
    if (dc_tag_we &&  repl_way_q) tag_ram1[q_idx] <= q_tag;
  end

  always @(posedge clk) begin
    if (!rst && !fencei_req && l0_commit_ok) begin
      l0_tag[l0_widx]  <= l0_wtag;
      l0_data[l0_widx] <= l0_commit_wdata;
    end
  end

  // 组合输出控制 (dbus_stall / dbus_fault 已寄存为纯 FF)
  always @(*) begin
    dbus_rdata   = data_q;
    fencei_done  = 1'b0;
    icache_flush = 1'b0;
    mem_req      = 1'b0;
    mem_we       = 1'b0;
    mem_addr     = 32'd0;
    mem_wdata    = 32'd0;
    mem_wstrb    = 4'b0000;

    case (state)
      S_IDLE: begin
        dbus_rdata = data_q;
      end

      S_WB: begin
        if (!wb_read_wait) begin
          mem_req   = 1'b1;
          mem_we    = 1'b1;
          mem_addr  = {tag_q, q_idx, word_cnt, 2'b00};
          mem_wdata = wb_data_q;
          mem_wstrb = 4'b1111;
        end
      end

      S_REFILL: begin
        mem_req    = 1'b1;
        mem_we     = 1'b0;
        mem_addr   = {q_addr[31:5], word_cnt, 2'b00};
      end

      S_UNCACHED: begin
        mem_req    = 1'b1;
        mem_we     = q_we;
        mem_addr   = {q_addr[31:2], 2'b00};
        mem_wdata  = q_wdata;
        mem_wstrb  = q_we ? q_wstrb : 4'b0000;
      end

      S_RESP: begin
        dbus_rdata = resp_rdata;
      end

      S_FLUSH_SCAN: ;

      S_FLUSH_WB: begin
        if (!wb_read_wait) begin
          mem_req   = 1'b1;
          mem_we    = 1'b1;
          mem_addr  = {tag_q, flush_idx, word_cnt, 2'b00};
          mem_wdata = wb_data_q;
          mem_wstrb = 4'b1111;
        end
      end

      S_FLUSH_DONE: begin
        fencei_done  = 1'b1;
        icache_flush = 1'b1;
      end

      default: ;
    endcase
  end

  integer i;
  initial begin
    valid0      = {SETS{1'b0}};
    valid1      = {SETS{1'b0}};
    dirty0      = {SETS{1'b0}};
    dirty1      = {SETS{1'b0}};
    lru_arr     = {SETS{1'b0}};
    l0_valid    = {L0_N{1'b0}};
    data_ram0_q = 32'd0;
    data_ram1_q = 32'd0;
    for (i = 0; i < SETS; i = i + 1) begin
      tag_ram0[i] = 20'd0;
      tag_ram1[i] = 20'd0;
    end
    for (i = 0; i < 1024; i = i + 1) begin
      data_ram0[i] = 32'd0;
      data_ram1[i] = 32'd0;
    end
    for (i = 0; i < L0_N; i = i + 1) begin
      l0_tag[i]  = {L0_TAG_W{1'b0}};
      l0_data[i] = 32'd0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state         <= S_IDLE;
      valid0        <= {SETS{1'b0}};
      valid1        <= {SETS{1'b0}};
      dirty0        <= {SETS{1'b0}};
      dirty1        <= {SETS{1'b0}};
      lru_arr       <= {SETS{1'b0}};
      l0_valid      <= {L0_N{1'b0}};
      q_valid       <= 1'b0;
      q_we          <= 1'b0;
      q_addr        <= 32'd0;
      q_wdata       <= 32'd0;
      q_wstrb       <= 4'b0000;
      q_hit0_r      <= 1'b0;
      q_hit1_r      <= 1'b0;
      q_l0_hit_r    <= 1'b0;
      q_cacheable_r <= 1'b0;
      dbus_stall_r  <= 1'b0;
      dbus_fault_r  <= 1'b0;
      repl_way_q    <= 1'b0;
      vld_q         <= 1'b0;
      drt_q         <= 1'b0;
      tag_q         <= 20'd0;
      use_fwd_q     <= 1'b0;
      fwd_data_q    <= 32'd0;
      word_cnt      <= 3'd0;
      flush_slot    <= 8'd0;
      wb_read_wait  <= 1'b0;
      resp_rdata    <= 32'd0;
      resp_err      <= 1'b0;
      rf_err        <= 1'b0;
    end
    else begin
      // L0D 有效位维护: FENCE.I 单拍全清，出错失效，WB 确认提交置位
      if (fencei_req) begin
        l0_valid <= {L0_N{1'b0}};
      end
      else if (l0_inval_err) begin
        l0_valid[l0_widx] <= 1'b0;
      end
      else if (l0_commit_ok) begin
        l0_valid[l0_widx] <= 1'b1;
      end

      case (state)
        S_IDLE: begin
          if (q_l1_hit) begin
            lru_arr[q_idx] <= ~q_hit_way;
          end
          if (store_hit) begin
            if (!q_hit_way) dirty0[q_idx] <= 1'b1;
            else            dirty1[q_idx] <= 1'b1;
          end

          if (q_miss) begin
            word_cnt     <= 3'd0;
            rf_err       <= 1'b0;
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
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
            q_valid      <= 1'b0;
            dbus_stall_r <= 1'b0;
            dbus_fault_r <= 1'b0;
            flush_slot   <= 8'd0;
            state        <= S_FLUSH_SCAN;
          end
          else begin
            q_valid      <= in_req;
            q_we         <= dbus_we;
            q_addr       <= dbus_addr;
            q_wdata      <= dbus_wdata;
            q_wstrb      <= dbus_wstrb;
            dbus_stall_r <= in_req && !(in_hit0 || in_hit1 || l0_rd_hit);
            dbus_fault_r <= 1'b0;
            if (in_req) begin
              q_hit0_r      <= in_hit0;
              q_hit1_r      <= in_hit1;
              q_l0_hit_r    <= l0_rd_hit;
              q_cacheable_r <= in_cacheable;
              repl_way_q    <= vic_way;
              vld_q         <= vic_vld;
              drt_q         <= vic_drt;
              tag_q         <= vic_tag;
              use_fwd_q     <= same_word_fwd || l0_rd_hit;
              if (same_word_fwd)  fwd_data_q <= store_merged;
              else if (l0_rd_hit) fwd_data_q <= l0_rdata;
            end
          end
        end

        S_WB: begin
          dbus_stall_r <= 1'b1;
          dbus_fault_r <= 1'b0;
          if (wb_read_wait) begin
            wb_read_wait <= 1'b0;
          end
          else if (mem_ack) begin
            if (word_cnt == 3'd7) begin
              if (!repl_way_q) dirty0[q_idx] <= 1'b0;
              else             dirty1[q_idx] <= 1'b0;
              word_cnt <= 3'd0;
              state    <= S_REFILL;
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
                if (!repl_way_q) begin
                  valid0[q_idx] <= 1'b1;
                  dirty0[q_idx] <= q_we;
                end
                else begin
                  valid1[q_idx] <= 1'b1;
                  dirty1[q_idx] <= q_we;
                end
                lru_arr[q_idx] <= ~repl_way_q;
              end
              else begin
                if (!repl_way_q) begin
                  valid0[q_idx] <= 1'b0;
                  dirty0[q_idx] <= 1'b0;
                end
                else begin
                  valid1[q_idx] <= 1'b0;
                  dirty1[q_idx] <= 1'b0;
                end
              end
              resp_err     <= mem_err || rf_err;
              dbus_stall_r <= 1'b0;
              dbus_fault_r <= mem_err || rf_err;
              state        <= S_RESP;
            end
            else begin
              word_cnt     <= word_cnt + 3'd1;
              dbus_stall_r <= 1'b1;
              dbus_fault_r <= 1'b0;
            end
          end
          else begin
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
          end
        end

        S_UNCACHED: begin
          if (mem_ack) begin
            resp_rdata   <= mem_rdata;
            use_fwd_q    <= 1'b1;
            fwd_data_q   <= mem_rdata;
            resp_err     <= mem_err;
            dbus_stall_r <= 1'b0;
            dbus_fault_r <= mem_err;
            state        <= S_RESP;
          end
          else begin
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
          end
        end

        S_RESP: begin
          state        <= S_IDLE;
          q_valid      <= in_req;
          q_we         <= dbus_we;
          q_addr       <= dbus_addr;
          q_wdata      <= dbus_wdata;
          q_wstrb      <= dbus_wstrb;
          dbus_stall_r <= in_req && !(in_hit0 || in_hit1);
          dbus_fault_r <= 1'b0;
          if (in_req) begin
            q_hit0_r      <= in_hit0;
            q_hit1_r      <= in_hit1;
            q_l0_hit_r    <= 1'b0;
            q_cacheable_r <= in_cacheable;
            repl_way_q    <= vic_way;
            vld_q         <= vic_vld;
            drt_q         <= vic_drt;
            tag_q         <= vic_tag;
            use_fwd_q     <= 1'b0;
          end
        end

        S_FLUSH_SCAN: begin
          dbus_stall_r <= 1'b0;
          dbus_fault_r <= 1'b0;
          if (flush_way ? (valid1[flush_idx] && dirty1[flush_idx])
                        : (valid0[flush_idx] && dirty0[flush_idx])) begin
            tag_q        <= flush_way ? tag_ram1[flush_idx] : tag_ram0[flush_idx];
            word_cnt     <= 3'd0;
            wb_read_wait <= 1'b1;
            state        <= S_FLUSH_WB;
          end
          else if (flush_slot == 8'd255) begin
            state <= S_FLUSH_DONE;
          end
          else begin
            flush_slot <= flush_slot + 8'd1;
          end
        end

        S_FLUSH_WB: begin
          dbus_stall_r <= 1'b0;
          dbus_fault_r <= 1'b0;
          if (wb_read_wait) begin
            wb_read_wait <= 1'b0;
          end
          else if (mem_ack) begin
            if (word_cnt == 3'd7) begin
              if (!flush_way) dirty0[flush_idx] <= 1'b0;
              else            dirty1[flush_idx] <= 1'b0;
              if (flush_slot == 8'd255) begin
                state <= S_FLUSH_DONE;
              end
              else begin
                flush_slot <= flush_slot + 8'd1;
                state      <= S_FLUSH_SCAN;
              end
            end
            else begin
              word_cnt     <= word_cnt + 3'd1;
              wb_read_wait <= 1'b1;
            end
          end
        end

        S_FLUSH_DONE: begin
          state        <= S_IDLE;
          q_valid      <= 1'b0;
          dbus_stall_r <= 1'b0;
          dbus_fault_r <= 1'b0;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
