`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// btb.v — 128 项分布式 RAM 8-bit Epoch 全 32-bit Tag BTB + Bimodal BHT (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 架构要点:
//   1) 128 项 (2×RAM64M) 分布式 RAM 异步组合读，直接由寄存后的 pc 寻址；
//   2) 8-bit Epoch 替代 128-bit valid_arr FF 向量:
//        * epoch=0 保留为非法态，cur_epoch 复位为 1，常规 flush_all 单拍 cur_epoch+1
//          (消灭 128 个 valid FF、128:1 读 MUX 与 flush_all 128 扇出布线浪费)；
//        * 仅在每 255 次 flush_all 回绕时触发一次 128 拍后台清零 (scrubbing)，
//          常态 254 次 flush 与 valid_arr 逐拍 100% 等价 (零预测率/IPC 损失)，
//          回绕时 100% 根除跨代伪命中；
//        * {p_epoch, p_tag} == {cur_epoch, ptag} 31-bit 并入单条 3 级 CARRY4 比较链；
//   3) Taken-Only 分配策略 (upd_en && upd_taken)，等效容量 ~220+ 项。
// ============================================================================

module btb #(
  parameter        IDX_BITS   = 7,
  parameter        PC_TOP     = 32,
  parameter [31:0] PC_BASE    = `IMEM_BASE,
  parameter        PHT_BITS   = 13,
  parameter        EPOCH_BITS = 8
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
  localparam META_W   = EPOCH_BITS + 2 + TAG_BITS; // {epoch, is_cond, is_ret, tag}
  localparam [EPOCH_BITS-1:0] EPOCH_ONE = {{(EPOCH_BITS-1){1'b0}}, 1'b1};
  localparam [EPOCH_BITS-1:0] EPOCH_MAX = {EPOCH_BITS{1'b1}};
  localparam [IDX_BITS-1:0]   IDX_MAX   = {IDX_BITS{1'b1}};

  reg  [EPOCH_BITS-1:0] cur_epoch;
  reg                   scrubbing;
  reg  [IDX_BITS-1:0]   scrub_cnt;

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

  wire [META_W-1:0]     p_meta    = meta_ram[pidx];
  wire [TGT_BITS-1:0]   p_tgt     = tgt_ram[pidx];
  wire [EPOCH_BITS-1:0] p_epoch   = p_meta[META_W-1 : TAG_BITS+2];
  wire                  p_is_cond = p_meta[TAG_BITS+1];
  wire                  p_is_ret  = p_meta[TAG_BITS];
  wire [TAG_BITS-1:0]   p_tag     = p_meta[TAG_BITS-1:0];

  // {p_epoch, p_tag} == {cur_epoch, ptag} 单条 3-CARRY4 比较链; pred_is_ret 并行直出
  assign pred_hit    = !scrubbing && ({p_epoch, p_tag} == {cur_epoch, ptag});
  assign pred_is_ret = p_is_ret;
  assign pred_taken  = pred_hit && (p_is_cond ? pred_ctr[1] : 1'b1);

  generate
    if (PC_TOP == 32) begin : gen_full32
      assign pred_target = {p_tgt, 2'b00};
    end else begin : gen_part_pc
      assign pred_target = {PC_BASE[31:PC_TOP], p_tgt, 2'b00};
    end
  endgenerate

  // Taken-Only 分配 (回绕清零期间让出写口给后台擦除器; 拆扇出避免 33-bit RAMD64E WE 拥塞)
  wire                btb_en_ok = !rst && !flush_all && upd_en;
  wire                btb_alloc = !scrubbing && btb_en_ok && upd_taken;
  (* max_fanout = 12 *) wire meta_we = (!rst && scrubbing) || (btb_en_ok && upd_taken);
  wire [IDX_BITS-1:0] meta_widx = scrubbing ? scrub_cnt : uidx;
  wire [META_W-1:0]   meta_wdat = scrubbing
                                  ? {META_W{1'b0}}
                                  : {cur_epoch, upd_is_cond, upd_is_ret, utag};

  integer i;
  initial begin
    cur_epoch = EPOCH_ONE;
    scrubbing = 1'b0;
    scrub_cnt = {IDX_BITS{1'b0}};
    for (i = 0; i < N; i = i + 1) begin
      meta_ram[i] = {META_W{1'b0}};
      tgt_ram[i]  = {TGT_BITS{1'b0}};
    end
`ifndef SYNTHESIS
    $display("[btb] LUTRAM %0d-BIT EPOCH BTB + 8K-BRAM BIMODAL TAKEN-ONLY ACTIVE: BTB=%0d (IDX=%0d TAG=%0d PC_TOP=%0d) PHT=%0d",
             EPOCH_BITS, N, IDX_BITS, TAG_BITS, PC_TOP, (1 << PHT_BITS));
`endif
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      cur_epoch <= EPOCH_ONE;
      scrubbing <= 1'b0;
      scrub_cnt <= {IDX_BITS{1'b0}};
    end
    else if (scrubbing) begin
      if (scrub_cnt == IDX_MAX) begin
        scrubbing <= 1'b0;
        scrub_cnt <= {IDX_BITS{1'b0}};
      end
      else begin
        scrub_cnt <= scrub_cnt + {{(IDX_BITS-1){1'b0}}, 1'b1};
      end
    end
    else if (flush_all) begin
      if (cur_epoch == EPOCH_MAX) begin
        cur_epoch <= EPOCH_ONE;
        scrubbing <= 1'b1;
        scrub_cnt <= {IDX_BITS{1'b0}};
      end
      else begin
        cur_epoch <= cur_epoch + EPOCH_ONE;
      end
    end
  end

  always @(posedge clk) begin
    if (meta_we) begin
      meta_ram[meta_widx] <= meta_wdat;
    end
    if (!rst && btb_alloc) begin
      tgt_ram[uidx] <= upd_target[PC_TOP-1:2];
    end
  end

endmodule
