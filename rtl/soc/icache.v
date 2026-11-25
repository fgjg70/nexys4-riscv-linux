`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// icache.v — 4 KB 直接映射 VIPT 安全指令缓存 (128 行 × 32 字节, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 架构约束 (路线 A -> 路线 B 防返工):
//   - 总容量 4 KB (index = addr[11:5], word = addr[4:2]) 严格落在 4 KB 页内偏移内，
//     后续接入 Sv32 ITLB 时天然 VIPT 无别名；
//   - data_ram (1024×32b) 置于独立无复位 posedge clk 块 -> 100% 推断为 1 块 RAMB36E1；
//   - tag_ram (128×20b) 采用分布式 RAM + 切片寄存器输出 tag_q，消除 BRAM Tag 读出延迟；
//   - valid_arr 采用 128-bit 寄存器向量，支持 FENCE.I / SFENCE.VMA 单拍全清；
//   - 缺失途中若 CPU 发生分支/陷阱重定向 (ibus_kill)，等待在途总线事务安全收尾后
//     自动丢弃旧路径结果并立即重查新 PC，杜绝 PC/指令错配。
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

  // 下游统一内存总线主口 (32-bit 字事务)
  output reg         mem_req,
  output wire        mem_we,
  output reg  [31:0] mem_addr,
  output wire [31:0] mem_wdata,
  output wire [3:0]  mem_wstrb,
  input  wire        mem_ack,
  input  wire [31:0] mem_rdata,
  input  wire        mem_err
);

  localparam SETS = 128;
  localparam [2:0]
    S_RUN      = 3'd0,
    S_REFILL   = 3'd1,
    S_UNCACHED = 3'd2,
    S_RESP_OK  = 3'd3,
    S_RESP_ERR = 3'd4,
    S_RELOOKUP = 3'd5;

  assign mem_we    = 1'b0;
  assign mem_wdata = 32'd0;
  assign mem_wstrb = 4'b0000;

  // 存储阵列: 128-bit 有效位 FF + 128×20b 分布式 Tag RAM + 1024×32b Data BRAM
  reg  [SETS-1:0] valid_arr;
  (* ram_style = "distributed" *) reg [19:0] tag_ram  [0:SETS-1];
  (* ram_style = "block" *)       reg [31:0] data_ram [0:1023];

  reg  [2:0]  state;
  reg         req_valid_q;
  reg  [31:0] req_pc_q;
  reg         vld_q;
  reg  [19:0] tag_q;
  reg  [31:0] data_q;

  reg  [31:0] miss_pc;
  reg  [2:0]  word_cnt;
  reg  [31:0] miss_word_r;
  reg         refill_killed;
  reg         refill_err;

  function is_cacheable;
    input [31:0] a;
    begin
      is_cacheable = (((a & RAM_MASK) == RAM_BASE) ||
                      ((a >= ROM_BASE) && (a < (ROM_BASE + 32'h0000_4000))));
    end
  endfunction

  wire q_cacheable = is_cacheable(req_pc_q);
  wire q_hit       = req_valid_q && q_cacheable && vld_q && (tag_q == req_pc_q[31:12]);

  wire [6:0] in_idx  = ibus_addr[11:5];
  wire [9:0] in_word = ibus_addr[11:2];
  wire [6:0] ms_idx  = miss_pc[11:5];

  // S_RESP_ERR 期间无条件预读 data_ram (该拍输出 NOP 不消费 data_q)，彻底剪断 ibus_addr -> BRAM EN 路径
  wire do_lookup =
      ((state == S_RUN) && (flush_all || !req_valid_q || q_hit || ibus_kill)) ||
      (state == S_RESP_OK) ||
      (state == S_RESP_ERR) ||
      (state == S_RELOOKUP);

  wire       data_we    = (state == S_REFILL) && mem_ack;
  wire [9:0] data_waddr = {ms_idx, word_cnt};
  wire       tag_we     = (state == S_REFILL) && mem_ack && (word_cnt == 3'd7) &&
                          !(mem_err || refill_err) && !flush_all;

  // 独立无异步复位时钟块: 严格符合 Vivado UG901 简单双口 RAMB36E1 推断模板
  always @(posedge clk) begin
    if (data_we)
      data_ram[data_waddr] <= mem_rdata;
    if (do_lookup)
      data_q <= data_ram[in_word];
  end

  always @(posedge clk) begin
    if (tag_we)
      tag_ram[ms_idx] <= miss_pc[31:12];
    if (do_lookup)
      tag_q <= tag_ram[in_idx];
  end

  // 组合输出: 命中零停顿返回，缺失/重查期间拉低 ibus_valid
  always @(*) begin
    ibus_valid = 1'b0;
    ibus_rdata = `INSTR_NOP;
    ibus_fault = 1'b0;
    mem_req    = 1'b0;
    mem_addr   = 32'd0;

    case (state)
      S_RUN: begin
        if (q_hit && !flush_all) begin
          ibus_valid = 1'b1;
          ibus_rdata = data_q;
          ibus_fault = 1'b0;
        end
      end
      S_REFILL: begin
        mem_req  = 1'b1;
        mem_addr = {miss_pc[31:5], word_cnt, 2'b00};
      end
      S_UNCACHED: begin
        mem_req  = 1'b1;
        mem_addr = {miss_pc[31:2], 2'b00};
      end
      S_RESP_OK: begin
        if (!flush_all) begin
          ibus_valid = 1'b1;
          ibus_rdata = miss_word_r;
          ibus_fault = 1'b0;
        end
      end
      S_RESP_ERR: begin
        if (!flush_all) begin
          ibus_valid = 1'b1;
          ibus_rdata = `INSTR_NOP;
          ibus_fault = 1'b1;
        end
      end
      default: ;
    endcase
  end

  integer i;
  initial begin
    valid_arr = {SETS{1'b0}};
    tag_q     = 20'd0;
    data_q    = `INSTR_NOP;
    for (i = 0; i < SETS; i = i + 1) tag_ram[i] = 20'd0;
    for (i = 0; i < 1024; i = i + 1) data_ram[i] = `INSTR_NOP;
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state         <= S_RUN;
      valid_arr     <= {SETS{1'b0}};
      req_valid_q   <= 1'b0;
      req_pc_q      <= 32'd0;
      vld_q         <= 1'b0;
      miss_pc       <= 32'd0;
      word_cnt      <= 3'd0;
      miss_word_r   <= `INSTR_NOP;
      refill_killed <= 1'b0;
      refill_err    <= 1'b0;
    end
    else begin
      if (flush_all) begin
        valid_arr <= {SETS{1'b0}};
      end

      case (state)
        S_RUN: begin
          if (flush_all) begin
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
            vld_q       <= 1'b0;
          end
          else if (!req_valid_q || q_hit || ibus_kill) begin
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
            vld_q       <= valid_arr[in_idx];
          end
          else begin
            miss_pc       <= req_pc_q;
            word_cnt      <= 3'd0;
            refill_killed <= 1'b0;
            refill_err    <= 1'b0;
            if (q_cacheable) state <= S_REFILL;
            else             state <= S_UNCACHED;
          end
        end

        S_REFILL: begin
          if (ibus_kill || flush_all) refill_killed <= 1'b1;

          if (mem_ack) begin
            if (word_cnt == miss_pc[4:2]) miss_word_r <= mem_rdata;
            if (mem_err) refill_err <= 1'b1;

            if (word_cnt == 3'd7) begin
              if (!(mem_err || refill_err) && !flush_all) begin
                valid_arr[ms_idx] <= 1'b1;
              end
              if (refill_killed || ibus_kill || flush_all) begin
                state <= S_RELOOKUP;
              end
              else if (mem_err || refill_err) begin
                state <= S_RESP_ERR;
              end
              else begin
                state <= S_RESP_OK;
              end
            end
            else begin
              word_cnt <= word_cnt + 3'd1;
            end
          end
        end

        S_UNCACHED: begin
          if (ibus_kill || flush_all) refill_killed <= 1'b1;
          if (mem_ack) begin
            miss_word_r <= mem_rdata;
            if (refill_killed || ibus_kill || flush_all) state <= S_RELOOKUP;
            else if (mem_err)                            state <= S_RESP_ERR;
            else                                         state <= S_RESP_OK;
          end
        end

        S_RESP_OK: begin
          state       <= S_RUN;
          req_valid_q <= ibus_req;
          req_pc_q    <= ibus_addr;
          vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
        end

        S_RESP_ERR: begin
          // 用 3-bit 偏移比对替代 32-bit 比较器，大幅削减关键路径延迟
          if (ibus_kill || flush_all || (ibus_addr[4:2] != miss_pc[4:2])) begin
            state       <= S_RUN;
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
            vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
          end
        end

        S_RELOOKUP: begin
          state       <= S_RUN;
          req_valid_q <= ibus_req;
          req_pc_q    <= ibus_addr;
          vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
        end

        default: state <= S_RUN;
      endcase
    end
  end

endmodule
