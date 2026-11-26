`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// btb.v — 128 项分布式 RAM 全 32-bit Tag BTB + Bimodal BHT (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// Round 3 架构升级:
//   1) 128 项 (RAM128X1D 甜点上限) 分布式 RAM 异步组合读:
//        * 直接由寄存后的 pc (0.46ns FF) 寻址，彻底斩断 BTB BRAM -> pc_next -> BTB BRAM 闭环；
//        * 省下 2 块 RAMB18E1 (含 BHT 共省 1.5 块 BRAM36 Tile)；
//   2) 128-bit valid_arr FF 向量:
//        * rst / flush_all (FENCE.I / SFENCE.VMA) 单拍全清，彻底消灭原 512 拍后台擦除盲区；
//   3) Taken-Only 分配策略 (upd_en && upd_taken):
//        * 不为从不跳转的条件分支浪费 BTB 槽位，等效容量提升 ~1.7x-2.0x (~220+ 项)。
// ============================================================================

module btb #(
  parameter        IDX_BITS = 7,
  parameter        PC_TOP   = 32,
  parameter [31:0] PC_BASE  = `IMEM_BASE,
  parameter        PHT_BITS = 13
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        flush_all,

  // BTB 异步组合读 (pc 寻址) + BHT 8K RAMB18E1 同步预读 (pc_next 提前一拍寻址)
  input  wire [31:0] pred_pc,
  input  wire        pred_en,
  input  wire [31:0] pred_pc_next,
  output wire        pred_hit,
  output wire        pred_taken,
  output wire [31:0] pred_target,
  output wire        pred_is_ret,
  output wire [1:0]  pred_ctr,

  // EX 段更新口
  input  wire        upd_en,
  input  wire [31:0] upd_pc,
  input  wire        upd_taken,
  input  wire [31:0] upd_target,
  input  wire        upd_is_ret,
  input  wire        upd_is_cond,
  input  wire [1:0]  upd_old_ctr
);

  localparam N        = (1 << IDX_BITS);
  localparam TAG_BITS = PC_TOP - IDX_BITS - 2;
  localparam TGT_BITS = PC_TOP - 2;
  localparam META_W   = TAG_BITS + 2; // {is_cond, is_ret, tag}

  reg  [N-1:0]                      valid_arr;
  (* ram_style = "distributed" *) reg [META_W-1:0]   meta_ram [0:N-1];
  (* ram_style = "distributed" *) reg [TGT_BITS-1:0] tgt_ram  [0:N-1];

  wire [IDX_BITS-1:0] pidx = pred_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = pred_pc[PC_TOP-1:IDX_BITS+2];

  wire [IDX_BITS-1:0] uidx = upd_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc[PC_TOP-1:IDX_BITS+2];

  bht #(
    .IDX_BITS (PHT_BITS)
  ) u_bht (
    .clk          (clk),
    .rst          (rst),
    .pred_en      (pred_en),
    .pred_pc_next (pred_pc_next),
    .pred_ctr     (pred_ctr),
    .upd_en       (upd_en),
    .upd_pc       (upd_pc),
    .upd_taken    (upd_taken),
    .upd_is_cond  (upd_is_cond),
    .upd_old_ctr  (upd_old_ctr)
  );

  wire                p_vld     = valid_arr[pidx];
  wire [META_W-1:0]   p_meta    = meta_ram[pidx];
  wire [TGT_BITS-1:0] p_tgt     = tgt_ram[pidx];
  wire                p_is_cond = p_meta[META_W-1];
  wire                p_is_ret  = p_meta[META_W-2];
  wire [TAG_BITS-1:0] p_tag     = p_meta[TAG_BITS-1:0];

  // pred_is_ret 直出 p_is_ret (不串联 23-bit Tag 比较 pred_hit)，使 RAS/BTB 目标选择与
  // Tag 比较并行完成；pred_target 仅在 pred_taken=1 (已含 pred_hit) 时被 pc_next 采纳
  assign pred_hit    = p_vld && (p_tag == ptag);
  assign pred_is_ret = p_is_ret;
  assign pred_taken  = pred_hit && (p_is_cond ? pred_ctr[1] : 1'b1);

  generate
    if (PC_TOP == 32) begin : gen_full32
      assign pred_target = {p_tgt, 2'b00};
    end else begin : gen_part_pc
      assign pred_target = {PC_BASE[31:PC_TOP], p_tgt, 2'b00};
    end
  endgenerate

  // Taken-Only 分配: 仅实际发生跳转时写入 BTB，不为从不跳转的分支浪费槽位
  wire btb_alloc = !flush_all && upd_en && upd_taken;

  integer i;
  initial begin
    valid_arr = {N{1'b0}};
    for (i = 0; i < N; i = i + 1) begin
      meta_ram[i] = {META_W{1'b0}};
      tgt_ram[i]  = {TGT_BITS{1'b0}};
    end
`ifndef SYNTHESIS
    $display("[btb] LUTRAM BTB + 8K-BRAM BIMODAL TAKEN-ONLY ACTIVE: BTB=%0d (IDX=%0d TAG=%0d PC_TOP=%0d) PHT=%0d",
             N, IDX_BITS, TAG_BITS, PC_TOP, (1 << PHT_BITS));
`endif
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      valid_arr <= {N{1'b0}};
    end
    else if (flush_all) begin
      valid_arr <= {N{1'b0}};
    end
    else if (btb_alloc) begin
      valid_arr[uidx] <= 1'b1;
    end
  end

  always @(posedge clk) begin
    if (!rst && btb_alloc) begin
      meta_ram[uidx] <= {upd_is_cond, upd_is_ret, utag};
      tgt_ram[uidx]  <= upd_target[PC_TOP-1:2];
    end
  end

endmodule
