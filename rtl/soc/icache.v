`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// icache.v — 4 KB 直接映射 VIPT 安全指令缓存 (128 行 × 32 字节, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 架构约束 (路线 A -> 路线 B 防返工):
//   - 总容量 4 KB (index = addr[11:5], word = addr[4:2]) 严格落在 4 KB 页内偏移内，
//     后续接入 Sv32 ITLB 时天然 VIPT 无别名；
//   - valid_arr 采用 128-bit 寄存器向量，支持 FENCE.I / SFENCE.VMA 单拍全清；
//   - 命中 1 拍同步读出 (与原 BRAM imem 零延迟差)；缺失时按 8 字突发填充；
//   - 缺失途中若 CPU 发生分支/陷阱重定向 (ibus_kill)，等待在途总线事务安全收尾后
//     自动丢弃旧路径结果并立即重查新 PC，杜绝 PC/指令错配。
// ============================================================================

module icache #(
  parameter [31:0] RAM_BASE = `SOC_RAM_BASE,
  parameter [31:0] RAM_MASK = `SOC_RAM_MASK,
  parameter [31:0] ROM_BASE = `SOC_ROM_BASE,
  parameter [31:0] ROM_MASK = 32'hFFFF_C000   // 16 KB BootROM: 0x0000_0000..0x0000_3FFF / 0x1000..0x4FFF
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

  // 存储阵列: 128-bit 有效位 FF + 128x20b Tag + 1024x32b Data (1 块 RAMB36)
  reg  [SETS-1:0] valid_arr;
  reg  [19:0]     tag_ram  [0:SETS-1];
  (* ram_style = "block" *) reg [31:0] data_ram [0:1023];

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
      tag_q         <= 20'd0;
      data_q        <= `INSTR_NOP;
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
            tag_q       <= tag_ram[in_idx];
            data_q      <= data_ram[in_word];
          end
          else if (!req_valid_q || q_hit || ibus_kill) begin
            // 正常命中、首次请求或缺失当拍即被重定向取消 -> 直接查询新 ibus_addr
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
            vld_q       <= valid_arr[in_idx];
            tag_q       <= tag_ram[in_idx];
            data_q      <= data_ram[in_word];
          end
          else begin
            // 发生真实缺失
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
            data_ram[{ms_idx, word_cnt}] <= mem_rdata;
            if (word_cnt == miss_pc[4:2]) miss_word_r <= mem_rdata;
            if (mem_err) refill_err <= 1'b1;

            if (word_cnt == 3'd7) begin
              if (!(mem_err || refill_err) && !flush_all) begin
                tag_ram[ms_idx]   <= miss_pc[31:12];
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
          // 本拍已向 CPU 交付 miss_word_r，沿跳回 S_RUN 并同时预查下一条 ibus_addr
          state       <= S_RUN;
          req_valid_q <= ibus_req;
          req_pc_q    <= ibus_addr;
          vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
          tag_q       <= tag_ram[in_idx];
          data_q      <= data_ram[in_word];
        end

        S_RESP_ERR: begin
          // 保持故障输出直到 CPU 消耗并推进 PC 或触发陷阱重定向 (ibus_kill)
          if (ibus_kill || flush_all || (ibus_addr != miss_pc)) begin
            state       <= S_RUN;
            req_valid_q <= ibus_req;
            req_pc_q    <= ibus_addr;
            vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
            tag_q       <= tag_ram[in_idx];
            data_q      <= data_ram[in_word];
          end
        end

        S_RELOOKUP: begin
          state       <= S_RUN;
          req_valid_q <= ibus_req;
          req_pc_q    <= ibus_addr;
          vld_q       <= flush_all ? 1'b0 : valid_arr[in_idx];
          tag_q       <= tag_ram[in_idx];
          data_q      <= data_ram[in_word];
        end

        default: state <= S_RUN;
      endcase
    end
  end

endmodule
