`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// btb.v — 全 32 位地址空间两级流水 gshare 分支目标缓冲（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// Round 2 全路径优化:
//   - 将 {vld, is_cond, is_ret, tag[20:0]} (24-bit) 整体打包进单块 512×36 RAMB18E1，
//     彻底移除原 512-bit FF 向量与 6 级 512:1 MUX 树 (从 Top-1 关键路径削减 ~2.3 ns，
//     同时净省 ~500 FF、~170 LUT 与 4 个 RAM128X1D)；
//   - rst / flush_all (FENCE.I / SFENCE.VMA) 采用零停顿后台清零状态机:
//     首拍即拉低 q_vld_gate 杜绝任何陈旧预测 (冷启动/热复位/FENCE.I 全安全)，
//     随后 512 拍在后台无停顿擦除 meta_ram 有效位，CPU 照常全速执行。
// ============================================================================

module btb #(
  parameter        IDX_BITS      = 9,
  parameter        PC_TOP        = 32,
  parameter [31:0] PC_BASE       = `IMEM_BASE,
  parameter        PHT_BITS      = 13,
  parameter        GH_BITS       = 13,
  parameter [0:0]  HIST_ALL_CTRL = 1'b1
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        flush_all,

  // 兼容口 (恒不预测, 两级流水使用下方 p2_pc / q_* 端口)
  input  wire [31:0] pred_pc,
  output wire        pred_hit,
  output wire        pred_taken,
  output wire [31:0] pred_target,
  output wire        pred_is_ret,

  // 两级流水预测口
  input  wire [31:0] p2_pc,
  input  wire [31:0] p2_pc_pht,
  input  wire        p2_hold,
  output wire        q_hit,
  output wire        q_taken,
  output wire [31:0] q_target,
  output wire        q_is_ret,

  // 更新口 (EX 段)
  input  wire        upd_en,
  input  wire [31:0] upd_pc,
  input  wire        upd_taken,
  input  wire [31:0] upd_target,
  input  wire        upd_is_ret,
  input  wire        upd_is_cond,

  output wire [15:0] align_err_cnt
);

  localparam N        = (1 << IDX_BITS);
  localparam TAG_BITS = PC_TOP - IDX_BITS - 2;
  localparam TGT_BITS = PC_TOP - 2;
  localparam META_W   = TAG_BITS + 3; // {vld, is_cond, is_ret, tag}

  (* ram_style = "block" *) reg [META_W-1:0]   meta_ram [0:N-1];
  (* ram_style = "block" *) reg [TGT_BITS-1:0] tgt_ram  [0:N-1];

  wire [IDX_BITS-1:0] uidx = upd_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc[PC_TOP-1:IDX_BITS+2];

  wire [IDX_BITS-1:0] pidx = p2_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = p2_pc[PC_TOP-1:IDX_BITS+2];

  reg                scrubbing;
  reg [IDX_BITS-1:0] scrub_idx;
  reg                q_vld_gate;
  reg [META_W-1:0]   q_meta;
  reg [TAG_BITS-1:0] q_tagexp;
  reg [TGT_BITS-1:0] q_tgt;

  wire                meta_we    = scrubbing ? 1'b1 : upd_en;
  wire [IDX_BITS-1:0] meta_waddr = scrubbing ? scrub_idx : uidx;
  wire [META_W-1:0]   meta_wdata = scrubbing ? {META_W{1'b0}}
                                             : {1'b1, upd_is_cond, upd_is_ret, utag};
  wire                tgt_we     = !scrubbing && upd_en;

  wire [1:0]  q_ctr;
  wire [31:0] pht_pc = p2_pc_pht;

  bht #(
    .IDX_BITS      (PHT_BITS),
    .GH_BITS       (GH_BITS),
    .PC_TOP        (PC_TOP),
    .HIST_ALL_CTRL (HIST_ALL_CTRL)
  ) u_bht (
    .clk           (clk),
    .rst           (rst),
    .flush_all     (flush_all),
    .pred_pc       (pht_pc),
    .ctr_q         (q_ctr),
    .upd_en        (upd_en),
    .upd_pc        (upd_pc),
    .upd_taken     (upd_taken),
    .upd_is_cond   (upd_is_cond),
    .align_err_cnt (align_err_cnt)
  );

  wire                q_vld     = q_vld_gate && !scrubbing && q_meta[META_W-1];
  wire                q_cond_r  = q_meta[META_W-2];
  wire                q_isret_r = q_meta[META_W-3];
  wire [TAG_BITS-1:0] q_tag     = q_meta[TAG_BITS-1:0];

  assign q_hit = q_vld && (q_tag == q_tagexp);

  generate
    if (PC_TOP == 32) begin : gen_full32
      assign q_target = {q_tgt, 2'b00};
    end else begin : gen_part_pc
      assign q_target = {PC_BASE[31:PC_TOP], q_tgt, 2'b00};
    end
  endgenerate

  assign q_is_ret = q_hit && q_isret_r;
  assign q_taken  = q_hit && (q_cond_r ? q_ctr[1] : 1'b1);

  assign pred_hit    = 1'b0;
  assign pred_taken  = 1'b0;
  assign pred_target = 32'd0;
  assign pred_is_ret = 1'b0;

  integer i;
  initial begin
    q_meta = {META_W{1'b0}};
    q_tgt  = {TGT_BITS{1'b0}};
    for (i = 0; i < N; i = i + 1) begin
      meta_ram[i] = {META_W{1'b0}};
      tgt_ram[i]  = {TGT_BITS{1'b0}};
    end
`ifndef SYNTHESIS
    $display("[btb] 2-STAGE gshare BRAM-PACKED ACTIVE: BTB=%0d (IDX=%0d TAG=%0d PC_TOP=%0d) PHT=%0d GH=%0d",
             N, IDX_BITS, TAG_BITS, PC_TOP, (1 << PHT_BITS), GH_BITS);
`endif
  end

  // 独立无复位 BRAM 块: 2×RAMB18E1 (meta_ram + tgt_ram)
  always @(posedge clk) begin
    if (meta_we)
      meta_ram[meta_waddr] <= meta_wdata;
    if (!p2_hold)
      q_meta <= meta_ram[pidx];
  end

  always @(posedge clk) begin
    if (tgt_we)
      tgt_ram[uidx] <= upd_target[PC_TOP-1:2];
    if (!p2_hold)
      q_tgt <= tgt_ram[pidx];
  end

  // 后台非阻塞清零状态机 + 期望 Tag 寄存
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      scrubbing  <= 1'b1;
      scrub_idx  <= {IDX_BITS{1'b0}};
      q_vld_gate <= 1'b0;
      q_tagexp   <= {TAG_BITS{1'b0}};
    end
    else if (flush_all) begin
      scrubbing  <= 1'b1;
      scrub_idx  <= {IDX_BITS{1'b0}};
      q_vld_gate <= 1'b0;
    end
    else begin
      if (scrubbing) begin
        q_vld_gate <= 1'b0;
        if (scrub_idx == {IDX_BITS{1'b1}}) begin
          scrubbing <= 1'b0;
        end
        else begin
          scrub_idx <= scrub_idx + {{(IDX_BITS-1){1'b0}}, 1'b1};
        end
      end
      else if (!p2_hold) begin
        q_vld_gate <= 1'b1;
        q_tagexp   <= ptag;
      end
    end
  end

endmodule
