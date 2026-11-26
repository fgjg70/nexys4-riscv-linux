`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// dcache.v — 8 KB 2 路 VIPT 回写 L1D + 256 B 物理标签 L0D + Sv32 一致性 PTW 读口
// 纯 Verilog-2001，面向 Nexys 4 DDR 100 MHz 时序收敛与标准 Sv32 Linux v6.x
// ----------------------------------------------------------------------------
// Phase D2 Sv32 扩展:
//   1) 全部 L1D Tag 与 L0D Tag 均为物理标签 PA[31:12] / PA[31:8]，索引 VA[11:2]
//      严格位于 4 KB 页内，VIPT 零虚拟别名且完整保留 Sv32 下 0 拍 L0D Load-Use 加速；
//   2) 微型 DTLB 缺失时暂停 CPU 请求 (cpu_dtlb_pend=1)，复用 L1D 通道服务 sv32_mmu
//      硬件 PTW 的物理页表读请求 (ptw_req)，天然命中回写 L1D 脏行 (100% PTE 一致性)；
//   3) DTLB/PTW 完成后经 S_REPLAY / S_REPLAY_HIT 恢复原访存，权限违例/缺页精确拉高
//      dbus_page_fault (Cause 13/15)，物理总线错拉高 dbus_fault (Cause 5/7)。
// ============================================================================

module dcache #(
  parameter [31:0] RAM_BASE = `SOC_RAM_BASE,
  parameter [31:0] RAM_MASK = `SOC_RAM_MASK,
  parameter        L0_BITS  = 6             // 64 字 = 256 B (单级 RAM64M 零 bank mux 甜点)
)(
  input  wire        clk,
  input  wire        rst,

  // CPU 数据总线接口 (MEM 拍发起虚拟地址 VA，WB 拍返回数据/停顿/访问错/缺页错)
  input  wire        dbus_re,
  input  wire        dbus_we,
  input  wire        dbus_is_amo,
  input  wire [31:0] dbus_addr,
  input  wire [31:0] dbus_wdata,
  input  wire [3:0]  dbus_wstrb,
  output reg  [31:0] dbus_rdata,
  output wire        dbus_stall,
  output wire        dbus_fault,
  output wire        dbus_page_fault,

  // L0D 0 拍异步快读口 (dbus_l0_addr 直连 ex_mem_alu_out FF，dbus_l0_en 保证处于 S_IDLE 单字对齐读)
  input  wire        dbus_l0_en,
  input  wire [31:0] dbus_l0_addr,
  output wire        dbus_fast_hit,
  output wire [31:0] dbus_fast_rdata,

  // FENCE.I / SFENCE.VMA 一致性握手
  input  wire        fencei_req,
  input  wire        sfence_req,
  output reg         fencei_done,
  output reg         icache_flush,

  // Sv32 MMU 数据侧微型 DTLB 与缺失握手口
  input  wire        d_xlate_en,
  input  wire        d_utlb_hit,
  input  wire        d_utlb_perm_ok,
  input  wire [19:0] d_utlb_ppn,
  input  wire        l0_utlb_ok,
  input  wire [19:0] l0_utlb_ppn,

  output wire        dtlb_miss_req,
  output wire [31:0] dtlb_miss_va,
  output wire        dtlb_miss_we,
  output wire        dtlb_miss_amo,
  input  wire        dtlb_resp_valid,
  input  wire [31:0] dtlb_resp_pa,
  input  wire        dtlb_resp_pf,
  input  wire        dtlb_resp_af,

  // Sv32 硬件 PTW 一致性只读口 (物理地址, 可命中回写 L1D 脏行)
  input  wire        ptw_req,
  input  wire [31:0] ptw_addr,
  output wire        ptw_ack,
  output wire [31:0] ptw_rdata,
  output wire        ptw_err,

  // 下游统一内存总线主口 (32-bit 物理字事务)
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

  localparam [3:0]
    S_IDLE       = 4'd0,
    S_WB         = 4'd1,
    S_REFILL     = 4'd2,
    S_UNCACHED   = 4'd3,
    S_RESP       = 4'd4,
    S_FLUSH_SCAN = 4'd5,
    S_FLUSH_WB   = 4'd6,
    S_FLUSH_DONE = 4'd7,
    S_REPLAY     = 4'd8,
    S_REPLAY_HIT = 4'd9,
    S_PTW_LK     = 4'd10;

  // ---- 8 KB 2 路 VIPT 物理标签 L1D 存储阵列 ----
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

  // ---- 256 B 物理标签 0 拍直写 L0D ----
  reg  [L0_N-1:0]                     l0_valid;
  (* ram_style = "distributed" *) reg [L0_TAG_W-1:0] l0_tag  [0:L0_N-1];
  (* ram_style = "distributed" *) reg [31:0]         l0_data [0:L0_N-1];

  reg  [3:0]  state;

  // 当前在途缓存事务 (CPU 或 PTW)
  reg         q_valid;
  reg         q_is_ptw;
  reg         q_we;
  reg         q_is_amo;
  reg  [31:0] q_addr;          // 物理地址 (若 q_dtlb_miss=1 则暂存 VA)
  reg  [31:0] q_wdata;
  reg  [3:0]  q_wstrb;
  reg         q_hit0_r;
  reg         q_hit1_r;
  reg         q_l0_hit_r;
  reg         q_cacheable_r;
  reg         q_dtlb_miss;
  reg         q_dtlb_pf;

  // 暂停等待 DTLB/PTW 翻译的 CPU 请求保存寄存器 + PTW 地址打拍寄存器
  reg         cpu_dtlb_pend;
  reg  [31:0] cpu_va_r;
  reg  [31:0] cpu_pa_r;
  reg  [31:0] ptw_addr_r;
  reg         cpu_we_r;
  reg         cpu_amo_r;
  reg  [31:0] cpu_wdata_r;
  reg  [3:0]  cpu_wstrb_r;

  // 纯 FF 直出控制响应 (维持 100 MHz 主频)
  reg         dbus_stall_r;
  reg         dbus_fault_r;
  reg         dbus_pf_r;

  // PTW 寄存响应脉冲 (彻底隔断 D-Cache BRAM -> MMU PTW 组合路径)
  reg         ptw_ack_r;
  reg  [31:0] ptw_rdata_r;
  reg         ptw_err_r;

  reg         repl_way_q;
  reg         vld_q;
  reg         drt_q;
  reg  [19:0] tag_q;

  // 旁路覆盖 (背靠背同物理字 Store->Load / L0D 命中保底 / 缺失填充回传)
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

  assign dbus_stall      = dbus_stall_r;
  assign dbus_fault      = dbus_fault_r;
  assign dbus_page_fault = dbus_pf_r;

  assign dtlb_miss_req   = cpu_dtlb_pend;
  assign dtlb_miss_va    = cpu_va_r;
  assign dtlb_miss_we    = cpu_we_r;
  assign dtlb_miss_amo   = cpu_amo_r;

  assign ptw_ack         = ptw_ack_r;
  assign ptw_rdata       = ptw_rdata_r;
  assign ptw_err         = ptw_err_r;

  wire        q_l1_hit  = q_valid && (q_hit0_r || q_hit1_r);
  wire        q_hit_way = q_hit1_r;
  wire        q_hit     = q_valid && (q_hit0_r || q_hit1_r || q_l0_hit_r);
  wire        q_miss    = (state == S_IDLE) && q_valid && !q_hit;
  wire        store_hit = (state == S_IDLE) && !q_is_ptw && q_l1_hit && q_we;

  wire [31:0] l1_data_q     = q_hit1_r ? data_ram1_q : data_ram0_q;
  wire [31:0] data_q        = use_fwd_q ? fwd_data_q : l1_data_q;
  wire [31:0] store_merged  = merge_bytes(data_q, q_wdata, q_wstrb);
  wire [31:0] refill_merged = merge_bytes(mem_rdata, q_wdata, q_wstrb);
  wire [31:0] wb_data_q     = (state == S_WB)
                              ? (repl_way_q ? data_ram1_q : data_ram0_q)
                              : (flush_way  ? data_ram1_q : data_ram0_q);

  wire [6:0]  q_idx   = q_addr[11:5];
  wire [2:0]  q_wrd   = q_addr[4:2];
  wire [19:0] q_tag   = q_addr[31:12];

  // ---- 统一查找多路复用: CPU MEM / S_PTW_LK / S_REPLAY (三者严格互斥, 全部由纯 FF 选通!) ----
  // 时序关键优化: S_IDLE 中接受 ptw_req 仅打拍进 S_PTW_LK，绝不把 in_req -> ptw_accept 串入
  // lk_idx -> tag_ram0/1 (彻底砍掉 ~5.0 ns 路径，且 S_IDLE 的 store_hit 在进 S_PTW_LK 前已写盘!)
  wire        in_req       = dbus_re || dbus_we;
  wire        d_tlb_ok     = !d_xlate_en || (d_utlb_hit && d_utlb_perm_ok);
  wire [19:0] d_pa_hi      = d_xlate_en ? d_utlb_ppn : dbus_addr[31:12];
  wire [31:0] cpu_in_pa    = {d_pa_hi, dbus_addr[11:0]};

  wire        idle_free    = (state == S_IDLE) && !q_miss && !(q_valid && q_is_ptw);
  wire        dtlb_fin_now = idle_free && cpu_dtlb_pend && dtlb_resp_valid;
  wire        ptw_accept   = idle_free && !dtlb_fin_now && ptw_req && !ptw_ack_r &&
                             (cpu_dtlb_pend || (!q_valid && !in_req && !fencei_req));
  wire        cpu_accept   = (idle_free && !cpu_dtlb_pend && !(fencei_req && !in_req) && in_req) ||
                             ((state == S_RESP) && in_req);
  wire        is_replay    = (state == S_REPLAY);
  wire        is_ptw_lk    = (state == S_PTW_LK);

  wire [31:0] lk_pa        = is_replay ? cpu_pa_r :
                             is_ptw_lk ? ptw_addr_r : cpu_in_pa;
  wire [6:0]  lk_idx       = lk_pa[11:5];
  wire [9:0]  lk_word      = lk_pa[11:2];
  wire [19:0] lk_tag       = lk_pa[31:12];
  wire        lk_tlb_ok    = is_replay || is_ptw_lk || d_tlb_ok;
  wire        lk_cacheable = ((lk_pa & RAM_MASK) == RAM_BASE);
  wire        lk_hit0      = lk_tlb_ok && lk_cacheable && valid0[lk_idx] && (tag_ram0[lk_idx] == lk_tag);
  wire        lk_hit1      = lk_tlb_ok && lk_cacheable && valid1[lk_idx] && (tag_ram1[lk_idx] == lk_tag);
  wire        same_word_fwd = store_hit && cpu_accept && lk_tlb_ok &&
                              (lk_pa[31:2] == q_addr[31:2]);

  // 同组紧邻访问的精确 LRU / 脏位前递
  wire        same_set_hit_idle = (state == S_IDLE) && q_l1_hit && (lk_idx == q_idx);
  wire        same_set_st_idle  = store_hit && (lk_idx == q_idx);
  wire        eff_drt0          = (same_set_st_idle && !q_hit_way) ? 1'b1 : dirty0[lk_idx];
  wire        eff_drt1          = (same_set_st_idle &&  q_hit_way) ? 1'b1 : dirty1[lk_idx];
  wire        eff_lru           = same_set_hit_idle ? ~q_hit_way : lru_arr[lk_idx];
  wire        vic_way           = !valid0[lk_idx] ? 1'b0 : (!valid1[lk_idx] ? 1'b1 : eff_lru);
  wire        vic_vld           = vic_way ? valid1[lk_idx] : valid0[lk_idx];
  wire        vic_drt           = vic_way ? eff_drt1       : eff_drt0;
  wire [19:0] vic_tag           = vic_way ? tag_ram1[lk_idx] : tag_ram0[lk_idx];

  // ---- 256 B 物理标签 L0D 异步 0 拍读 (与微型 DTLB 并行收敛，Sv32 下零虚拟别名) ----
  wire [L0_BITS-1:0]  l0_ridx  = dbus_l0_addr[L0_BITS+1:2];
  wire [19:0]         l0_pa_hi = d_xlate_en ? l0_utlb_ppn : dbus_l0_addr[31:12];
  wire [L0_TAG_W-1:0] l0_rtag  = {l0_pa_hi, dbus_l0_addr[11:L0_BITS+2]};
  wire [L0_BITS-1:0]  l0_widx  = q_addr[L0_BITS+1:2];
  wire [L0_TAG_W-1:0] l0_wtag  = q_addr[31:L0_BITS+2];
  wire [31:0]         l0_rdata = l0_data[l0_ridx];
  wire                l0_st_haz = store_hit && (l0_ridx == l0_widx);
  (* keep = "true" *) wire l0_ctrl_ok = (state == S_IDLE) && !dbus_stall_r && !cpu_dtlb_pend &&
                                        !q_is_ptw && !fencei_req && !sfence_req &&
                                        dbus_l0_en && !l0_st_haz && l0_valid[l0_ridx] &&
                                        (!d_xlate_en || l0_utlb_ok);
  (* keep = "true" *) wire l0_tag_eq  = (l0_tag[l0_ridx] == l0_rtag);
  wire                l0_rd_hit = l0_ctrl_ok && l0_tag_eq;

  assign dbus_fast_hit   = l0_rd_hit;
  assign dbus_fast_rdata = l0_rdata;

  // ---- 256 B 物理标签 L0D WB 确认提交写 (绝不由 PTW 或出错访存污染) ----
  wire                l0_commit_ok =
      ((state == S_IDLE) && !q_is_ptw && q_hit && q_cacheable_r && (q_we || !q_l0_hit_r)) ||
      ((state == S_RESP) && !q_is_ptw && q_cacheable_r && !resp_err);
  wire                l0_inval_err = (state == S_RESP) && !q_is_ptw && q_cacheable_r && resp_err;
  wire [31:0]         l0_commit_wdata = (state == S_IDLE)
                                        ? (q_we ? store_merged : data_q)
                                        : resp_rdata;

  // ---- 2 路 Data BRAM 驱动 (独立无异步复位块 -> 2×RAMB36E1) ----
  wire dc_lookup_en = cpu_accept || is_ptw_lk || is_replay;
  wire dc_wb_rd_en  = ((state == S_WB) || (state == S_FLUSH_WB)) && wb_read_wait;

  wire        replay_st_hit = (state == S_REPLAY_HIT) && q_we;
  wire        dc_data_we0   = ((store_hit || replay_st_hit) && !q_hit_way) ||
                              ((state == S_REFILL) && mem_ack && !repl_way_q);
  wire        dc_data_we1   = ((store_hit || replay_st_hit) &&  q_hit_way) ||
                              ((state == S_REFILL) && mem_ack &&  repl_way_q);
  wire [9:0]  dc_data_waddr = ((state == S_IDLE) || (state == S_REPLAY_HIT))
                              ? q_addr[11:2] : {q_idx, word_cnt};
  wire [31:0] dc_data_wdata = ((state == S_IDLE) || (state == S_REPLAY_HIT)) ? store_merged :
                              (((word_cnt == q_wrd) && q_we) ? refill_merged : mem_rdata);

  wire        dc_data_re    = (dc_lookup_en && !same_word_fwd) || dc_wb_rd_en;
  wire [9:0]  dc_data_raddr = (state == S_WB)       ? {q_idx, word_cnt} :
                              (state == S_FLUSH_WB) ? {flush_idx, word_cnt} :
                                                      lk_word;

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
    if (!rst && !fencei_req && !sfence_req && l0_commit_ok) begin
      l0_tag[l0_widx]  <= l0_wtag;
      l0_data[l0_widx] <= l0_commit_wdata;
    end
  end

  // 组合输出控制 (dbus_stall / dbus_fault / dbus_page_fault 已全部寄存为纯 FF)
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
      q_is_ptw      <= 1'b0;
      q_we          <= 1'b0;
      q_is_amo      <= 1'b0;
      q_addr        <= 32'd0;
      q_wdata       <= 32'd0;
      q_wstrb       <= 4'b0000;
      q_hit0_r      <= 1'b0;
      q_hit1_r      <= 1'b0;
      q_l0_hit_r    <= 1'b0;
      q_cacheable_r <= 1'b0;
      q_dtlb_miss   <= 1'b0;
      q_dtlb_pf     <= 1'b0;
      cpu_dtlb_pend <= 1'b0;
      cpu_va_r      <= 32'd0;
      cpu_pa_r      <= 32'd0;
      ptw_addr_r    <= 32'd0;
      cpu_we_r      <= 1'b0;
      cpu_amo_r     <= 1'b0;
      cpu_wdata_r   <= 32'd0;
      cpu_wstrb_r   <= 4'b0000;
      dbus_stall_r  <= 1'b0;
      dbus_fault_r  <= 1'b0;
      dbus_pf_r     <= 1'b0;
      ptw_ack_r     <= 1'b0;
      ptw_rdata_r   <= 32'd0;
      ptw_err_r     <= 1'b0;
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
      // PTW 单拍应答脉冲默认清零
      ptw_ack_r <= 1'b0;
      ptw_err_r <= 1'b0;

      // L0D 有效位维护: FENCE.I / SFENCE.VMA 单拍全清，出错失效，WB 确认提交置位
      if (fencei_req || sfence_req) begin
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

          // 1) PTW 1 拍命中 L1D: 直接打拍返回 ptw_ack_r/ptw_rdata_r
          if (q_valid && q_is_ptw && q_l1_hit) begin
            ptw_ack_r    <= 1'b1;
            ptw_rdata_r  <= data_q;
            ptw_err_r    <= 1'b0;
            q_valid      <= 1'b0;
            q_is_ptw     <= 1'b0;
            dbus_stall_r <= cpu_dtlb_pend;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
          end
          // 2) 当前事务缺失 (DTLB 缺失/权限错 或 L1D/MMIO 缺失)
          else if (q_miss) begin
            word_cnt     <= 3'd0;
            rf_err       <= 1'b0;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;

            if (!q_is_ptw && q_dtlb_pf) begin
              // 微型 DTLB 命中但权限不足 -> 立即经 S_RESP 报缺页异常 (Cause 13/15)
              q_valid       <= 1'b0;
              q_dtlb_miss   <= 1'b0;
              q_dtlb_pf     <= 1'b0;
              q_cacheable_r <= 1'b0;
              resp_rdata    <= 32'd0;
              resp_err      <= 1'b1;
              dbus_stall_r  <= 1'b0;
              dbus_pf_r     <= 1'b1;
              state         <= S_RESP;
            end
            else if (!q_is_ptw && q_dtlb_miss) begin
              // 微型 DTLB 缺失 -> 挂起 CPU 请求，释放 L1D 通道供 PTW 一致性读页表
              cpu_dtlb_pend <= 1'b1;
              cpu_va_r      <= q_addr;
              cpu_we_r      <= q_we;
              cpu_amo_r     <= q_is_amo;
              cpu_wdata_r   <= q_wdata;
              cpu_wstrb_r   <= q_wstrb;
              q_valid       <= 1'b0;
              q_dtlb_miss   <= 1'b0;
              q_dtlb_pf     <= 1'b0;
              dbus_stall_r  <= 1'b1;
            end
            else begin
              dbus_stall_r <= 1'b1;
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
          end
          // 3) 挂起的 CPU DTLB 翻译完成
          else if (cpu_dtlb_pend && dtlb_resp_valid) begin
            cpu_dtlb_pend <= 1'b0;
            q_valid       <= 1'b0;
            q_is_ptw      <= 1'b0;
            if (dtlb_resp_pf || dtlb_resp_af) begin
              q_cacheable_r <= 1'b0;
              resp_rdata    <= 32'd0;
              resp_err      <= 1'b1;
              dbus_stall_r  <= 1'b0;
              dbus_fault_r  <= dtlb_resp_af;
              dbus_pf_r     <= dtlb_resp_pf;
              state         <= S_RESP;
            end
            else begin
              cpu_pa_r     <= dtlb_resp_pa;
              dbus_stall_r <= 1'b1;
              dbus_fault_r <= 1'b0;
              dbus_pf_r    <= 1'b0;
              state        <= S_REPLAY;
            end
          end
          // 4) 接受硬件 PTW 一致性物理读请求 -> 打一拍进入 S_PTW_LK (隔离 tag_ram 关键路径)
          else if (ptw_accept) begin
            ptw_addr_r   <= ptw_addr;
            q_valid      <= 1'b0;
            q_is_ptw     <= 1'b1;
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
            state        <= S_PTW_LK;
          end
          // 5) 仍在等待 DTLB 响应且无 PTW 读请求: 保持停顿
          else if (cpu_dtlb_pend) begin
            q_valid      <= 1'b0;
            q_is_ptw     <= 1'b0;
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
          end
          // 6) FENCE.I 清洗 D-Cache 脏行
          else if (fencei_req && !in_req) begin
            q_valid      <= 1'b0;
            q_is_ptw     <= 1'b0;
            dbus_stall_r <= 1'b0;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
            flush_slot   <= 8'd0;
            state        <= S_FLUSH_SCAN;
          end
          // 7) 正常接受 CPU 访存请求
          else begin
            q_valid      <= in_req;
            q_is_ptw     <= 1'b0;
            q_we         <= dbus_we;
            q_is_amo     <= dbus_is_amo;
            q_addr       <= d_tlb_ok ? cpu_in_pa : dbus_addr;
            q_wdata      <= dbus_wdata;
            q_wstrb      <= dbus_wstrb;
            q_dtlb_miss  <= in_req && !d_tlb_ok;
            q_dtlb_pf    <= in_req && d_xlate_en && d_utlb_hit && !d_utlb_perm_ok;
            dbus_stall_r <= in_req && !(lk_hit0 || lk_hit1 || l0_rd_hit);
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
            if (in_req) begin
              q_hit0_r      <= lk_hit0;
              q_hit1_r      <= lk_hit1;
              q_l0_hit_r    <= l0_rd_hit;
              q_cacheable_r <= lk_cacheable;
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

        S_PTW_LK: begin
          // 使用已寄存物理地址 ptw_addr_r 查找 L1D (无任何上游 CPU 控制路径依赖)
          q_valid       <= 1'b1;
          q_is_ptw      <= 1'b1;
          q_we          <= 1'b0;
          q_is_amo      <= 1'b0;
          q_addr        <= ptw_addr_r;
          q_wdata       <= 32'd0;
          q_wstrb       <= 4'b0000;
          q_dtlb_miss   <= 1'b0;
          q_dtlb_pf     <= 1'b0;
          q_hit0_r      <= lk_hit0;
          q_hit1_r      <= lk_hit1;
          q_l0_hit_r    <= 1'b0;
          q_cacheable_r <= lk_cacheable;
          repl_way_q    <= vic_way;
          vld_q         <= vic_vld;
          drt_q         <= vic_drt;
          tag_q         <= vic_tag;
          use_fwd_q     <= 1'b0;
          word_cnt      <= 3'd0;
          rf_err        <= 1'b0;
          dbus_stall_r  <= 1'b1;
          dbus_fault_r  <= 1'b0;
          dbus_pf_r     <= 1'b0;

          if (lk_hit0 || lk_hit1) begin
            state <= S_IDLE;
          end
          else if (!lk_cacheable) begin
            state <= S_UNCACHED;
          end
          else if (vic_vld && vic_drt) begin
            wb_read_wait <= 1'b1;
            state        <= S_WB;
          end
          else begin
            state <= S_REFILL;
          end
        end

        S_REPLAY: begin
          // 使用翻译后的物理地址 cpu_pa_r 查找 L1D
          q_valid       <= 1'b1;
          q_is_ptw      <= 1'b0;
          q_we          <= cpu_we_r;
          q_is_amo      <= cpu_amo_r;
          q_addr        <= cpu_pa_r;
          q_wdata       <= cpu_wdata_r;
          q_wstrb       <= cpu_wstrb_r;
          q_dtlb_miss   <= 1'b0;
          q_dtlb_pf     <= 1'b0;
          q_hit0_r      <= lk_hit0;
          q_hit1_r      <= lk_hit1;
          q_l0_hit_r    <= 1'b0;
          q_cacheable_r <= lk_cacheable;
          repl_way_q    <= vic_way;
          vld_q         <= vic_vld;
          drt_q         <= vic_drt;
          tag_q         <= vic_tag;
          use_fwd_q     <= 1'b0;
          word_cnt      <= 3'd0;
          rf_err        <= 1'b0;
          dbus_stall_r  <= 1'b1;
          dbus_fault_r  <= 1'b0;
          dbus_pf_r     <= 1'b0;

          if (lk_hit0 || lk_hit1) begin
            state <= S_REPLAY_HIT;
          end
          else if (!lk_cacheable) begin
            state <= S_UNCACHED;
          end
          else if (vic_vld && vic_drt) begin
            wb_read_wait <= 1'b1;
            state        <= S_WB;
          end
          else begin
            state <= S_REFILL;
          end
        end

        S_REPLAY_HIT: begin
          // BRAM 数据刚读出: 完成写合并/标脏并经 S_RESP 释放 CPU
          lru_arr[q_idx] <= ~q_hit_way;
          if (q_we) begin
            if (!q_hit_way) dirty0[q_idx] <= 1'b1;
            else            dirty1[q_idx] <= 1'b1;
            resp_rdata <= store_merged;
          end
          else begin
            resp_rdata <= l1_data_q;
          end
          resp_err     <= 1'b0;
          dbus_stall_r <= 1'b0;
          dbus_fault_r <= 1'b0;
          dbus_pf_r    <= 1'b0;
          state        <= S_RESP;
        end

        S_WB: begin
          dbus_stall_r <= 1'b1;
          dbus_fault_r <= 1'b0;
          dbus_pf_r    <= 1'b0;
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

              if (q_is_ptw) begin
                // PTW 缺失填充完成: 直接打拍回送 ptw_ack_r 并返回 S_IDLE
                ptw_ack_r    <= 1'b1;
                ptw_rdata_r  <= (q_wrd == 3'd7) ? mem_rdata : resp_rdata;
                ptw_err_r    <= mem_err || rf_err;
                q_valid      <= 1'b0;
                q_is_ptw     <= 1'b0;
                dbus_stall_r <= cpu_dtlb_pend;
                dbus_fault_r <= 1'b0;
                dbus_pf_r    <= 1'b0;
                state        <= S_IDLE;
              end
              else begin
                resp_err     <= mem_err || rf_err;
                dbus_stall_r <= 1'b0;
                dbus_fault_r <= mem_err || rf_err;
                dbus_pf_r    <= 1'b0;
                state        <= S_RESP;
              end
            end
            else begin
              word_cnt     <= word_cnt + 3'd1;
              dbus_stall_r <= 1'b1;
              dbus_fault_r <= 1'b0;
              dbus_pf_r    <= 1'b0;
            end
          end
          else begin
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
          end
        end

        S_UNCACHED: begin
          if (mem_ack) begin
            if (q_is_ptw) begin
              ptw_ack_r    <= 1'b1;
              ptw_rdata_r  <= mem_rdata;
              ptw_err_r    <= mem_err;
              q_valid      <= 1'b0;
              q_is_ptw     <= 1'b0;
              dbus_stall_r <= cpu_dtlb_pend;
              dbus_fault_r <= 1'b0;
              dbus_pf_r    <= 1'b0;
              state        <= S_IDLE;
            end
            else begin
              resp_rdata   <= mem_rdata;
              use_fwd_q    <= 1'b1;
              fwd_data_q   <= mem_rdata;
              resp_err     <= mem_err;
              dbus_stall_r <= 1'b0;
              dbus_fault_r <= mem_err;
              dbus_pf_r    <= 1'b0;
              state        <= S_RESP;
            end
          end
          else begin
            dbus_stall_r <= 1'b1;
            dbus_fault_r <= 1'b0;
            dbus_pf_r    <= 1'b0;
          end
        end

        S_RESP: begin
          state        <= S_IDLE;
          q_valid      <= in_req;
          q_is_ptw     <= 1'b0;
          q_we         <= dbus_we;
          q_is_amo     <= dbus_is_amo;
          q_addr       <= d_tlb_ok ? cpu_in_pa : dbus_addr;
          q_wdata      <= dbus_wdata;
          q_wstrb      <= dbus_wstrb;
          q_dtlb_miss  <= in_req && !d_tlb_ok;
          q_dtlb_pf    <= in_req && d_xlate_en && d_utlb_hit && !d_utlb_perm_ok;
          dbus_stall_r <= in_req && !(lk_hit0 || lk_hit1);
          dbus_fault_r <= 1'b0;
          dbus_pf_r    <= 1'b0;
          if (in_req) begin
            q_hit0_r      <= lk_hit0;
            q_hit1_r      <= lk_hit1;
            q_l0_hit_r    <= 1'b0;
            q_cacheable_r <= lk_cacheable;
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
          dbus_pf_r    <= 1'b0;
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
          dbus_pf_r    <= 1'b0;
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
          q_is_ptw     <= 1'b0;
          dbus_stall_r <= 1'b0;
          dbus_fault_r <= 1'b0;
          dbus_pf_r    <= 1'b0;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
