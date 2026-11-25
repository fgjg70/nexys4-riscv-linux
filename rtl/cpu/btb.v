`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// btb.v — 全 32 位地址空间两级流水 gshare 分支目标缓冲（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 升级要点 (Stage 1A):
//   - PC_TOP 默认扩至 32: 21-bit 完整高位 Tag + 30-bit 字对齐目标，支持 BootROM
//     (0x0000_1000) 与 128 MB DDR2 (0x8000_0000..0x87FF_FFFF) 任意跨区跳转；
//   - 新增单拍同步 flush_all 端口: FENCE.I (路线 A) 与 SFENCE.VMA (路线 B) 一拍清零
//     全部 512 项有效位，vld 用 512-bit FF 向量实现，tag/tgt 仍可映射单块 RAMB36。
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
  localparam TGT_BITS = PC_TOP - 2; // 字对齐目标 [PC_TOP-1:2]

  // 有效位用打包寄存器向量: 支持 rst / flush_all 单拍全清
  reg [N-1:0]        vld;
  reg [TAG_BITS-1:0] tag     [0:N-1];
  reg [TGT_BITS-1:0] tgt     [0:N-1];
  reg                is_ret  [0:N-1];
  reg                is_cond [0:N-1];

  wire [IDX_BITS-1:0] uidx = upd_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc[PC_TOP-1:IDX_BITS+2];

  wire [IDX_BITS-1:0] pidx = p2_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = p2_pc[PC_TOP-1:IDX_BITS+2];

  reg                q_vld, q_isret_r, q_cond_r;
  reg [TAG_BITS-1:0] q_tag, q_tagexp;
  reg [TGT_BITS-1:0] q_tgt;

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
    vld = {N{1'b0}};
    for (i = 0; i < N; i = i + 1) begin
      tag[i]     = {TAG_BITS{1'b0}};
      tgt[i]     = {TGT_BITS{1'b0}};
      is_ret[i]  = 1'b0;
      is_cond[i] = 1'b0;
    end
`ifndef SYNTHESIS
    $display("[btb] 2-STAGE gshare ACTIVE: BTB=%0d (IDX=%0d TAG=%0d PC_TOP=%0d) PHT=%0d GH=%0d",
             N, IDX_BITS, TAG_BITS, PC_TOP, (1 << PHT_BITS), GH_BITS);
`endif
  end

  always @(posedge clk) begin
    if (rst || flush_all) begin
      vld       <= {N{1'b0}};
      q_vld     <= 1'b0;
      q_isret_r <= 1'b0;
      q_cond_r  <= 1'b0;
      q_tag     <= {TAG_BITS{1'b0}};
      q_tagexp  <= {TAG_BITS{1'b0}};
      q_tgt     <= {TGT_BITS{1'b0}};
    end
    else begin
      if (upd_en) begin
        vld[uidx]     <= 1'b1;
        tag[uidx]     <= utag;
        tgt[uidx]     <= upd_target[PC_TOP-1:2];
        is_ret[uidx]  <= upd_is_ret;
        is_cond[uidx] <= upd_is_cond;
      end
      if (!p2_hold) begin
        q_vld     <= vld[pidx];
        q_tag     <= tag[pidx];
        q_tagexp  <= ptag;
        q_tgt     <= tgt[pidx];
        q_isret_r <= is_ret[pidx];
        q_cond_r  <= is_cond[pidx];
      end
    end
  end

endmodule
