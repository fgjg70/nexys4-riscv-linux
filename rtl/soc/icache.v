`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// icache.v — 8 KB 2 路组相联 VIPT 指令缓存 + Sv32 微型 ITLB 集成 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 架构特性:
//   - 64 组 × 64 B (16 字) × 2 路 = 8 KB (每路 4 KB，index = VA[11:6] 严格落在
//     4 KB 页内，与 Sv32 物理标签 PA[31:12] 天然 VIPT 无别名)；
//   - 2×data_ram (各 1024×32b -> 2×RAMB36E1) 与 2×tag_ram (各 64×21b 单级原生 RAM64M，
//     valid 位打包于 tag_ram[20] 随 tag 同步读出至 FF tag0_q/tag1_q)；
//   - Phase D2 Sv32 扩展: IF 拍按 VA[11:2] 同步预读 Data/Tag，ID 拍将已寄存的
//     req_pc_q[31:12] 送入 sv32_mmu 微型 ITLB 得到物理标签 q_ptag 并行比对；
//     微型 ITLB 缺失时进 S_TLB_WAIT 查主 ITLB/PTW，命中后保留 tag_q/data_q 原地回 S_RUN，
//     权限违例或 PTW 缺页经 S_RESP_ERR 输出精确 ibus_page_fault (Cause 12)。
// ============================================================================

module icache #(
  parameter [31:0] RAM_BASE = `SOC_RAM_BASE,
  parameter [31:0] RAM_MASK = `SOC_RAM_MASK,
  parameter [31:0] ROM_BASE = `SOC_ROM_BASE,
  parameter [31:0] ROM_MASK = 32'hFFFF_C000
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        flush_all,

  // CPU 指令总线接口
  input  wire        ibus_req,
  input  wire [31:0] ibus_addr,
  input  wire        ibus_kill,
  output reg  [31:0] ibus_rdata,
  output reg         ibus_valid,
  output reg         ibus_fault,
  output reg         ibus_page_fault,

  // Sv32 MMU 指令侧接口 (微型 ITLB 快查 + 主 ITLB/PTW 缺失握手)
  output wire [31:0] ic_va,
  input  wire        i_xlate_en,
  input  wire        i_utlb_hit,
  input  wire        i_utlb_perm_ok,
  input  wire        i_utlb_super,
  input  wire [19:0] i_utlb_ppn_raw,
  input  wire [19:0] i_utlb_ppn,
  output wire        itlb_miss_req,
  output wire [31:0] itlb_miss_va,
  output wire        itlb_miss_kill,
  input  wire        itlb_serving,
  input  wire        itlb_resp_valid,
  input  wire        itlb_resp_pf,
  input  wire        itlb_resp_af,

  // 底层统一内存总线主接口 (接 soc_bus Master 1, 物理地址)
  output reg         mem_req,
  output wire        mem_we,
  output reg  [31:0] mem_addr,
  output wire [31:0] mem_wdata,
  output wire [3:0]  mem_wstrb,
  input  wire        mem_ack,
  input  wire [31:0] mem_rdata,
  input  wire        mem_err
);

  localparam SETS = 64;
  localparam [2:0]
    S_RUN      = 3'd0,
    S_REFILL   = 3'd1,
    S_UNCACHED = 3'd2,
    S_RESP_OK  = 3'd3,
    S_RESP_ERR = 3'd4,
    S_RELOOKUP = 3'd5,
    S_FLUSH    = 3'd6,
    S_TLB_WAIT = 3'd7;

  assign mem_we    = 1'b0;
  assign mem_wdata = 32'd0;
  assign mem_wstrb = 4'b0000;

  // 2 路存储阵列: 64-bit LRU + 2×64×21b 单级 RAM64M {valid, ptag[19:0]} + 2×1024×32b Data BRAM
  reg  [SETS-1:0] lru_arr;
  (* ram_style = "distributed" *) reg [20:0] tag_ram0  [0:SETS-1];
  (* ram_style = "distributed" *) reg [20:0] tag_ram1  [0:SETS-1];
  (* ram_style = "block" *)       reg [31:0] data_ram0 [0:1023];
  (* ram_style = "block" *)       reg [31:0] data_ram1 [0:1023];

  reg  [2:0]  state;
  reg         req_valid_q;
  reg  [31:0] req_pc_q;       // 虚拟 PC (页内偏移 [11:0] 与 PA 恒等)
  reg  [20:0] tag0_q;
  reg  [20:0] tag1_q;
  reg  [31:0] data0_q;
  reg  [31:0] data1_q;

  reg  [31:0] miss_pc;        // 翻译后的物理地址 (用于 S_REFILL / S_UNCACHED 与回填物理 tag)
  reg         repl_way;
  reg  [3:0]  word_cnt;
  reg  [5:0]  flush_cnt;
  reg         flush_pend;
  reg  [31:0] miss_word_r;
  reg         refill_killed;
  reg         refill_err;
  reg         resp_is_pf;

  function is_cacheable;
    input [31:0] a;
    begin
      is_cacheable = (((a & RAM_MASK) == RAM_BASE) ||
                      ((a >= ROM_BASE) && (a < (ROM_BASE + 32'h0000_4000))));
    end
  endfunction

  assign ic_va          = req_pc_q;
  assign itlb_miss_req  = (state == S_TLB_WAIT);
  assign itlb_miss_va   = req_pc_q;
  assign itlb_miss_kill = ibus_kill || refill_killed || flush_all || flush_pend;

  (* max_fanout = 24 *) wire [5:0] in_idx = ibus_addr[11:6];
  wire [9:0]  in_word      = ibus_addr[11:2];

  wire [5:0]  q_idx        = req_pc_q[11:6];
  wire [19:0] q_ptag       = i_xlate_en ? i_utlb_ppn : req_pc_q[31:12];
  wire        i_tlb_ok     = !i_xlate_en || (i_utlb_hit && i_utlb_perm_ok);
  wire [5:0]  ms_idx       = miss_pc[11:6];

  // 并行 FF 含有效位标签比对: 将 tag[20] 有效位直接并入 21b/11b CARRY4 比较器，
  // q_way0/1 合并为单级 LUT6 (彻底消除 tag1_match->q_way1 额外 LUT2，再省 ~1.05 ns!)
  wire        q_vld0         = tag0_q[20];
  wire        q_vld1         = tag1_q[20];
  wire        tag0_vld_bare  = (tag0_q[20:0]  == {1'b1, req_pc_q[31:12]});
  wire        tag0_vld_hi    = (tag0_q[20:10] == {1'b1, i_utlb_ppn_raw[19:10]});
  wire        tag0_eq_lo4k   = (tag0_q[9:0]   == i_utlb_ppn_raw[9:0]);
  wire        tag0_eq_losup  = (tag0_q[9:0]   == req_pc_q[21:12]);
  wire        q_way0         = i_xlate_en ? (tag0_vld_hi && (i_utlb_super ? tag0_eq_losup : tag0_eq_lo4k))
                                          : tag0_vld_bare;

  wire        tag1_vld_bare  = (tag1_q[20:0]  == {1'b1, req_pc_q[31:12]});
  wire        tag1_vld_hi    = (tag1_q[20:10] == {1'b1, i_utlb_ppn_raw[19:10]});
  wire        tag1_eq_lo4k   = (tag1_q[9:0]   == i_utlb_ppn_raw[9:0]);
  wire        tag1_eq_losup  = (tag1_q[9:0]   == req_pc_q[21:12]);
  (* max_fanout = 12 *) wire q_way1 =
      i_xlate_en ? (tag1_vld_hi && (i_utlb_super ? tag1_eq_losup : tag1_eq_lo4k))
                 : tag1_vld_bare;

  wire        q_hit0         = req_valid_q && i_tlb_ok && q_way0;
  wire        q_hit1         = req_valid_q && i_tlb_ok && q_way1;
  wire        q_hit          = q_hit0 || q_hit1;
  wire        q_cacheable    = is_cacheable({q_ptag, req_pc_q[11:0]});

  wire do_lookup = !flush_all && (
      ((state == S_RUN) && (!req_valid_q || q_hit || ibus_kill)) ||
      (state == S_RESP_OK) ||
      (state == S_RESP_ERR) ||
      (state == S_RELOOKUP));

  wire       data_we    = (state == S_REFILL) && mem_ack && !flush_all && !flush_pend;
  wire       data_we0   = data_we && !repl_way;
  wire       data_we1   = data_we &&  repl_way;
  wire [9:0] data_waddr = {ms_idx, word_cnt};

  wire        flush_we      = (state == S_FLUSH);
  wire        refill_done   = (state == S_REFILL) && mem_ack && (word_cnt == 4'd15) &&
                              !flush_all && !flush_pend;
  wire        tag_inval_err = refill_done &&  (mem_err || refill_err);
  wire        tag_we_ok     = refill_done && !(mem_err || refill_err);
  wire        tag_we_line   = tag_we_ok || tag_inval_err;
  wire        tag_we0       = flush_we || (tag_we_line && !repl_way);
  wire        tag_we1       = flush_we || (tag_we_line &&  repl_way);
  wire [5:0]  tag_waddr     = flush_we ? flush_cnt : ms_idx;
  wire [20:0] tag_wdata     = (flush_we || tag_inval_err) ? 21'd0 : {1'b1, miss_pc[31:12]};

  // 2 路独立无异步复位块 -> 稳定推断为 2×RAMB36E1 (Data) + 2×单级 RAM64M ({valid, ptag})
  always @(posedge clk) begin
    if (data_we0)
      data_ram0[data_waddr] <= mem_rdata;
    if (do_lookup)
      data0_q <= data_ram0[in_word];
  end

  always @(posedge clk) begin
    if (data_we1)
      data_ram1[data_waddr] <= mem_rdata;
    if (do_lookup)
      data1_q <= data_ram1[in_word];
  end

  always @(posedge clk) begin
    if (tag_we0)
      tag_ram0[tag_waddr] <= tag_wdata;
    if (do_lookup)
      tag0_q <= tag_ram0[in_idx];
  end

  always @(posedge clk) begin
    if (tag_we1)
      tag_ram1[tag_waddr] <= tag_wdata;
    if (do_lookup)
      tag1_q <= tag_ram1[in_idx];
  end

  // 组合输出: ibus_rdata 单级 LUT5 选通
  wire        ibus_is_resp  = (state == S_RESP_OK);
  wire [31:0] ibus_run_word = q_way1 ? data1_q : data0_q;

  always @(*) begin
    ibus_valid      = 1'b0;
    ibus_rdata      = ibus_is_resp ? miss_word_r : ibus_run_word;
    ibus_fault      = 1'b0;
    ibus_page_fault = 1'b0;
    mem_req         = 1'b0;
    mem_addr        = 32'd0;

    case (state)
      S_RUN: begin
        if (q_hit && !flush_all) begin
          ibus_valid = 1'b1;
        end
      end
      S_REFILL: begin
        mem_req  = 1'b1;
        mem_addr = {miss_pc[31:6], word_cnt, 2'b00};
      end
      S_UNCACHED: begin
        mem_req  = 1'b1;
        mem_addr = {miss_pc[31:2], 2'b00};
      end
      S_RESP_OK: begin
        if (!flush_all) begin
          ibus_valid = 1'b1;
        end
      end
      S_RESP_ERR: begin
        if (!flush_all) begin
          ibus_valid      = 1'b1;
          ibus_fault      = !resp_is_pf;
          ibus_page_fault =  resp_is_pf;
        end
      end
      default: ;
    endcase
  end

  integer i;
  initial begin
    lru_arr = {SETS{1'b0}};
    tag0_q  = 21'd0;
    tag1_q  = 21'd0;
    data0_q = `INSTR_NOP;
    data1_q = `INSTR_NOP;
    for (i = 0; i < SETS; i = i + 1) begin
      tag_ram0[i] = 21'd0;
      tag_ram1[i] = 21'd0;
    end
    for (i = 0; i < 1024; i = i + 1) begin
      data_ram0[i] = `INSTR_NOP;
      data_ram1[i] = `INSTR_NOP;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state         <= S_FLUSH;
      lru_arr       <= {SETS{1'b0}};
      req_valid_q   <= 1'b0;
      req_pc_q      <= 32'd0;
      miss_pc       <= 32'd0;
      repl_way      <= 1'b0;
      word_cnt      <= 4'd0;
      flush_cnt     <= 6'd0;
      flush_pend    <= 1'b0;
      miss_word_r   <= `INSTR_NOP;
      refill_killed <= 1'b0;
      refill_err    <= 1'b0;
      resp_is_pf    <= 1'b0;
    end
    else begin
      case (state)
        S_FLUSH: begin
          req_valid_q <= 1'b0;
          flush_pend  <= 1'b0;
          if (flush_all) begin
            flush_cnt <= 6'd0;
          end
          else if (flush_cnt == 6'd63) begin
            lru_arr   <= {SETS{1'b0}};
            flush_cnt <= 6'd0;
            state     <= S_RELOOKUP;
          end
          else begin
            flush_cnt <= flush_cnt + 6'd1;
          end
        end

        S_RUN: begin
          if (flush_all) begin
            req_valid_q <= 1'b0;
            flush_cnt   <= 6'd0;
            flush_pend  <= 1'b0;
            state       <= S_FLUSH;
          end
          else if (!req_valid_q || q_hit || ibus_kill) begin
            if (q_hit && !ibus_kill) begin
              lru_arr[q_idx] <= q_hit0 ? 1'b1 : 1'b0;
            end
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
          end
          else if (i_xlate_en && i_utlb_hit && !i_utlb_perm_ok) begin
            // 微型 ITLB 命中但权限不符 -> 立即返回指令缺页异常 (Cause 12)
            resp_is_pf <= 1'b1;
            state      <= S_RESP_ERR;
          end
          else if (i_xlate_en && !i_utlb_hit) begin
            // 微型 ITLB 缺失 -> 查主 ITLB / PTW (保留 tag0_q/tag1_q/data0_q/data1_q)
            refill_killed <= 1'b0;
            flush_pend    <= 1'b0;
            state         <= S_TLB_WAIT;
          end
          else begin
            // TLB 已就绪但 I-Cache 缺失 -> 按物理地址 miss_pc 回填
            miss_pc       <= {q_ptag, req_pc_q[11:0]};
            repl_way      <= !q_vld0 ? 1'b0 : (!q_vld1 ? 1'b1 : lru_arr[q_idx]);
            word_cnt      <= 4'd0;
            refill_killed <= 1'b0;
            refill_err    <= 1'b0;
            resp_is_pf    <= 1'b0;
            if (q_cacheable) state <= S_REFILL;
            else             state <= S_UNCACHED;
          end
        end

        S_TLB_WAIT: begin
          if (itlb_resp_valid) begin
            if (flush_pend || flush_all) begin
              req_valid_q <= 1'b0;
              flush_cnt   <= 6'd0;
              flush_pend  <= 1'b0;
              state       <= S_FLUSH;
            end
            else if (refill_killed || ibus_kill) begin
              state <= S_RELOOKUP;
            end
            else if (itlb_resp_pf || itlb_resp_af) begin
              resp_is_pf <= itlb_resp_pf;
              state      <= S_RESP_ERR;
            end
            else begin
              // u_itlb 已填入有效表项，tag_q/data_q 完整保留，原地返回 S_RUN 复判
              state <= S_RUN;
            end
          end
          else if (flush_all) begin
            if (!itlb_serving) begin
              req_valid_q <= 1'b0;
              flush_cnt   <= 6'd0;
              flush_pend  <= 1'b0;
              state       <= S_FLUSH;
            end
            else begin
              refill_killed <= 1'b1;
              flush_pend    <= 1'b1;
            end
          end
          else if (ibus_kill) begin
            if (!itlb_serving) begin
              state <= S_RELOOKUP;
            end
            else begin
              refill_killed <= 1'b1;
            end
          end
        end

        S_REFILL: begin
          if (ibus_kill) refill_killed <= 1'b1;
          if (flush_all) begin
            refill_killed <= 1'b1;
            flush_pend    <= 1'b1;
          end

          if (mem_ack) begin
            if (flush_pend || flush_all) begin
              req_valid_q <= 1'b0;
              flush_cnt   <= 6'd0;
              flush_pend  <= 1'b0;
              state       <= S_FLUSH;
            end
            else begin
              if (word_cnt == miss_pc[5:2]) miss_word_r <= mem_rdata;
              if (mem_err) refill_err <= 1'b1;

              if (word_cnt == 4'd15) begin
                if (!(mem_err || refill_err)) begin
                  lru_arr[ms_idx] <= ~repl_way;
                end
                if (refill_killed || ibus_kill) begin
                  state <= S_RELOOKUP;
                end
                else if (mem_err || refill_err) begin
                  resp_is_pf <= 1'b0;
                  state      <= S_RESP_ERR;
                end
                else begin
                  state <= S_RESP_OK;
                end
              end
              else begin
                word_cnt <= word_cnt + 4'd1;
              end
            end
          end
        end

        S_UNCACHED: begin
          if (ibus_kill) refill_killed <= 1'b1;
          if (flush_all) begin
            refill_killed <= 1'b1;
            flush_pend    <= 1'b1;
          end

          if (mem_ack) begin
            miss_word_r <= mem_rdata;
            if (flush_pend || flush_all) begin
              req_valid_q <= 1'b0;
              flush_cnt   <= 6'd0;
              flush_pend  <= 1'b0;
              state       <= S_FLUSH;
            end
            else if (refill_killed || ibus_kill) begin
              state <= S_RELOOKUP;
            end
            else if (mem_err) begin
              resp_is_pf <= 1'b0;
              state      <= S_RESP_ERR;
            end
            else begin
              state <= S_RESP_OK;
            end
          end
        end

        S_RESP_OK: begin
          if (flush_all) begin
            req_valid_q <= 1'b0;
            flush_cnt   <= 6'd0;
            flush_pend  <= 1'b0;
            state       <= S_FLUSH;
          end
          else begin
            state       <= S_RUN;
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
          end
        end

        S_RESP_ERR: begin
          if (flush_all) begin
            req_valid_q <= 1'b0;
            flush_cnt   <= 6'd0;
            flush_pend  <= 1'b0;
            state       <= S_FLUSH;
          end
          else begin
            state       <= S_RUN;
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
          end
        end

        S_RELOOKUP: begin
          if (flush_all) begin
            req_valid_q <= 1'b0;
            flush_cnt   <= 6'd0;
            flush_pend  <= 1'b0;
            state       <= S_FLUSH;
          end
          else begin
            state       <= S_RUN;
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
          end
        end

        default: state <= S_RUN;
      endcase
    end
  end

endmodule
