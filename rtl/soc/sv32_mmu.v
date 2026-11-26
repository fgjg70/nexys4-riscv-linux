`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// sv32_mmu.v — RISC-V Sv32 虚拟内存管理单元 (ITLB + DTLB + 缓存一致性硬件 PTW)
// 纯 Verilog-2001，面向 Nexys 4 DDR 100 MHz 时序收敛与标准 Sv32 Linux v6.x
// ----------------------------------------------------------------------------
// 架构要点:
//   1) 分层零额外延迟快路 (保护 100 MHz 主频):
//        * 1 项纯 FF 微型 ITLB (u_itlb): 与 VIPT I-Cache 的 tag0_q/tag1_q 并行比对；
//        * 1 项纯 FF 微型 DTLB (u_dtlb): 与 VIPT D-Cache 及 256 B 物理标签 L0D 并行比对；
//   2) 16 项全相联主 ITLB + 16 项全相联主 DTLB (循环替换):
//        * 主 TLB 数据阵列的写使能 (ptw_fill_i/ptw_fill_d) 严格仅由本模块内纯 FF 与
//          ptw_ack/ptw_rdata 驱动，彻底隔断 CPU trap_redir/ibus_kill -> TLB CE 路径；
//        * satp_flush 与 sfence_req 仅清零 34 位 valid FF，零大扇出 CE 违例；
//   3) 两级硬件页表遍历器 (PTW) 经 D-Cache 一致性读口访问页表:
//        * 严格命中回写 D-Cache 脏行 (Linux 写 PTE 后仅执行 SFENCE.VMA 即可 100% 可见)；
//        * 完整支持 4 KB 普通页 (Level 0) 与 4 MB 巨页 (Level 1, 校验 PPN[0]==0 对齐)；
//        * 完整校验 V/R/W/X/U/A/D、SUM、MXR、MPRV+MPP、34->32-bit 物理越界 Access Fault。
// ============================================================================

module sv32_mmu #(
  parameter ITLB_ENTRIES = 8,
  parameter DTLB_ENTRIES = 8,
  parameter ITLB_IDX_W   = 3,
  parameter DTLB_IDX_W   = 3
)(
  input  wire        clk,
  input  wire        rst,

  // CPU 特权级与 MMU 控制输入
  input  wire [1:0]  mmu_priv,
  input  wire [31:0] mmu_satp,
  input  wire        mmu_i_xlate_en,
  input  wire        mmu_sum,
  input  wire        mmu_mxr,
  input  wire        mmu_mprv,
  input  wire [1:0]  mmu_mpp,
  input  wire        sfence_req,
  input  wire [31:0] sfence_vaddr,
  input  wire        satp_flush,
  output wire        sfence_done,

  // I-Cache 微型 ITLB 快速组合查找口 (输入为已寄存 req_pc_q)
  input  wire [31:0] ic_va,
  output wire        i_xlate_en,
  output wire        i_utlb_hit,
  output wire        i_utlb_perm_ok,
  output wire        i_utlb_super,
  output wire [19:0] i_utlb_ppn_raw,
  output wire [19:0] i_utlb_ppn,

  // I-Cache ITLB 缺失 / PTW 握手口
  input  wire        itlb_miss_req,
  input  wire [31:0] itlb_miss_va,
  input  wire        itlb_miss_kill,
  output wire        itlb_serving,
  output reg         itlb_resp_valid,
  output reg         itlb_resp_pf,
  output reg         itlb_resp_af,

  // D-Cache 微型 DTLB 快速组合查找口 (MEM 段主口 + L0D 快读口)
  input  wire [31:0] dc_va,
  input  wire        dc_we,
  input  wire        dc_is_amo,
  output wire        d_xlate_en,
  output wire        d_utlb_hit,
  output wire        d_utlb_perm_ok,
  output wire [19:0] d_utlb_ppn,

  input  wire [31:0] l0_va,
  output wire        l0_utlb_ok,
  output wire [19:0] l0_utlb_ppn,

  // D-Cache DTLB 缺失 / PTW 握手口
  input  wire        dtlb_miss_req,
  input  wire [31:0] dtlb_miss_va,
  input  wire        dtlb_miss_we,
  input  wire        dtlb_miss_amo,
  output reg         dtlb_resp_valid,
  output reg  [31:0] dtlb_resp_pa,
  output reg         dtlb_resp_pf,
  output reg         dtlb_resp_af,

  // 一致性硬件 PTW 读口 (接入 D-Cache 物理只读口)
  output reg         ptw_req,
  output reg  [31:0] ptw_addr,
  input  wire        ptw_ack,
  input  wire [31:0] ptw_rdata,
  input  wire        ptw_err
);

  // --------------------------------------------------------------------------
  // Sv32 翻译使能与有效数据特权级 (MPRV 仅影响数据访存，绝不影响取指)
  // --------------------------------------------------------------------------
  wire       sv32_mode = mmu_satp[31];
  wire [1:0] d_priv    = ((mmu_priv == `PRIV_M) && mmu_mprv) ? mmu_mpp : mmu_priv;

  assign i_xlate_en = mmu_i_xlate_en;
  assign d_xlate_en = sv32_mode && (d_priv != `PRIV_M);

  // 权限位打包格式: perm[4:0] = {D, U, X, W, R} (入 TLB 的表项均已保证 V=1, A=1)
  function check_perm;
    input [4:0] perm;
    input [1:0] priv;
    input       is_fetch;
    input       is_store;
    input       sum;
    input       mxr;
    reg         p_r, p_w, p_x, p_u, p_d;
    reg         u_ok, rwx_ok;
    begin
      p_r = perm[0];
      p_w = perm[1];
      p_x = perm[2];
      p_u = perm[3];
      p_d = perm[4];

      if (priv == `PRIV_U) begin
        u_ok = p_u;
      end
      else begin
        u_ok = !p_u || (!is_fetch && sum);
      end

      if (is_fetch) begin
        rwx_ok = p_x;
      end
      else if (is_store) begin
        rwx_ok = p_w && p_d;
      end
      else begin
        rwx_ok = p_r || (mxr && p_x);
      end

      check_perm = u_ok && rwx_ok;
    end
  endfunction

  // --------------------------------------------------------------------------
  // 1 项纯 FF 微型 ITLB (与 I-Cache tag_q 并行比对)
  // --------------------------------------------------------------------------
  reg        ui_vld;
  reg        ui_super;
  reg [19:0] ui_vpn;
  reg [19:0] ui_ppn;
  reg [4:0]  ui_perm;

  wire ui_hi_eq = (ic_va[31:22] == ui_vpn[19:10]);
  wire ui_lo_eq = (ic_va[21:12] == ui_vpn[9:0]);
  assign i_utlb_hit     = ui_vld && ui_hi_eq && (ui_super || ui_lo_eq);
  assign i_utlb_perm_ok = check_perm(ui_perm, mmu_priv, 1'b1, 1'b0, mmu_sum, mmu_mxr);
  assign i_utlb_super   = ui_super;
  assign i_utlb_ppn_raw = ui_ppn;
  assign i_utlb_ppn     = ui_super ? {ui_ppn[19:10], ic_va[21:12]} : ui_ppn;

  // --------------------------------------------------------------------------
  // 1 项纯 FF 微型 DTLB (与 D-Cache 主口及 L0D 物理标签并行比对)
  // --------------------------------------------------------------------------
  reg        ud_vld;
  reg        ud_super;
  reg [19:0] ud_vpn;
  reg [19:0] ud_ppn;
  reg [4:0]  ud_perm;

  wire ud_hi_eq = (dc_va[31:22] == ud_vpn[19:10]);
  wire ud_lo_eq = (dc_va[21:12] == ud_vpn[9:0]);
  assign d_utlb_hit     = ud_vld && ud_hi_eq && (ud_super || ud_lo_eq);
  assign d_utlb_perm_ok = check_perm(ud_perm, d_priv, 1'b0, (dc_we || dc_is_amo), mmu_sum, mmu_mxr);
  assign d_utlb_ppn     = ud_super ? {ud_ppn[19:10], dc_va[21:12]} : ud_ppn;

  wire l0_hi_eq  = (l0_va[31:22] == ud_vpn[19:10]);
  wire l0_lo_eq  = (l0_va[21:12] == ud_vpn[9:0]);
  wire l0_hit    = ud_vld && l0_hi_eq && (ud_super || l0_lo_eq);
  wire l0_perm   = check_perm(ud_perm, d_priv, 1'b0, 1'b0, mmu_sum, mmu_mxr);
  assign l0_utlb_ok  = l0_hit && l0_perm;
  assign l0_utlb_ppn = ud_super ? {ud_ppn[19:10], l0_va[21:12]} : ud_ppn;

  // --------------------------------------------------------------------------
  // 主 ITLB + 主 DTLB 存储阵列 (默认 8 项全相联 + 1 项微 TLB, 兼顾 4KB/4MB 与 100 MHz)
  // --------------------------------------------------------------------------
  reg [ITLB_ENTRIES-1:0] itlb_vld;
  reg [ITLB_ENTRIES-1:0] itlb_super;
  reg [19:0]             itlb_vpn  [0:ITLB_ENTRIES-1];
  reg [19:0]             itlb_ppn  [0:ITLB_ENTRIES-1];
  reg [4:0]              itlb_perm [0:ITLB_ENTRIES-1];
  reg [ITLB_IDX_W-1:0]   itlb_repl;

  reg [DTLB_ENTRIES-1:0] dtlb_vld;
  reg [DTLB_ENTRIES-1:0] dtlb_super;
  reg [19:0]             dtlb_vpn  [0:DTLB_ENTRIES-1];
  reg [19:0]             dtlb_ppn  [0:DTLB_ENTRIES-1];
  reg [4:0]              dtlb_perm [0:DTLB_ENTRIES-1];
  reg [DTLB_IDX_W-1:0]   dtlb_repl;

  // --------------------------------------------------------------------------
  // PTW 与主 TLB 状态机
  // --------------------------------------------------------------------------
  localparam [1:0]
    M_IDLE   = 2'd0,
    M_CHECK  = 2'd1,
    M_PTW_L1 = 2'd2,
    M_PTW_L0 = 2'd3;

  reg [1:0]  state;
  reg        walk_is_d;       // 0=I-side, 1=D-side
  reg [31:0] walk_va;
  reg        walk_is_store;
  reg [1:0]  walk_priv;
  reg        walk_discard;    // satp_flush 期间标记旧遍历结果禁止置位 valid

  assign sfence_done  = sfence_req && (state == M_IDLE);
  assign itlb_serving = (state != M_IDLE) && !walk_is_d;

  // 主 TLB 全相联查找 (仅在 M_CHECK 状态消费)
  reg        mitlb_hit;
  reg        mitlb_hit_super;
  reg [19:0] mitlb_hit_vpn;
  reg [19:0] mitlb_hit_ppn;
  reg [4:0]  mitlb_hit_perm;

  reg        mdtlb_hit;
  reg        mdtlb_hit_super;
  reg [19:0] mdtlb_hit_vpn;
  reg [19:0] mdtlb_hit_ppn;
  reg [4:0]  mdtlb_hit_perm;

  integer k;
  always @(*) begin
    mitlb_hit       = 1'b0;
    mitlb_hit_super = 1'b0;
    mitlb_hit_vpn   = 20'd0;
    mitlb_hit_ppn   = 20'd0;
    mitlb_hit_perm  = 5'd0;
    for (k = 0; k < ITLB_ENTRIES; k = k + 1) begin
      if (itlb_vld[k] && (walk_va[31:22] == itlb_vpn[k][19:10]) &&
          (itlb_super[k] || (walk_va[21:12] == itlb_vpn[k][9:0]))) begin
        mitlb_hit       = 1'b1;
        mitlb_hit_super = itlb_super[k];
        mitlb_hit_vpn   = itlb_vpn[k];
        mitlb_hit_ppn   = itlb_ppn[k];
        mitlb_hit_perm  = itlb_perm[k];
      end
    end

    mdtlb_hit       = 1'b0;
    mdtlb_hit_super = 1'b0;
    mdtlb_hit_vpn   = 20'd0;
    mdtlb_hit_ppn   = 20'd0;
    mdtlb_hit_perm  = 5'd0;
    for (k = 0; k < DTLB_ENTRIES; k = k + 1) begin
      if (dtlb_vld[k] && (walk_va[31:22] == dtlb_vpn[k][19:10]) &&
          (dtlb_super[k] || (walk_va[21:12] == dtlb_vpn[k][9:0]))) begin
        mdtlb_hit       = 1'b1;
        mdtlb_hit_super = dtlb_super[k];
        mdtlb_hit_vpn   = dtlb_vpn[k];
        mdtlb_hit_ppn   = dtlb_ppn[k];
        mdtlb_hit_perm  = dtlb_perm[k];
      end
    end
  end

  // PTE 译码辅助逻辑 (纯本地 FF + ptw_ack/ptw_rdata 驱动，零 CPU/ICache 外部路径!)
  wire        pte_v         = ptw_rdata[0];
  wire        pte_r         = ptw_rdata[1];
  wire        pte_w         = ptw_rdata[2];
  wire        pte_x         = ptw_rdata[3];
  wire        pte_u         = ptw_rdata[4];
  wire        pte_a         = ptw_rdata[6];
  wire        pte_d         = ptw_rdata[7];
  wire [21:0] pte_ppn22     = ptw_rdata[31:10];
  wire        pte_invalid   = !pte_v || (!pte_r && pte_w);
  wire        pte_is_leaf   = pte_r || pte_x;
  wire [4:0]  pte_perm5     = {pte_d, pte_u, pte_x, pte_w, pte_r};
  wire        pte_pa_hi_err = (pte_ppn22[21:20] != 2'b00);
  wire        pte_super_mis = (pte_ppn22[9:0]   != 10'd0);

  wire        walk_perm_ok  = check_perm(pte_perm5, walk_priv, !walk_is_d, walk_is_store, mmu_sum, mmu_mxr);
  wire [19:0] l1_leaf_ppn   = {pte_ppn22[19:10], walk_va[21:12]};
  wire [19:0] l0_leaf_ppn   = pte_ppn22[19:0];

  wire [19:0] mdtlb_res_ppn = mdtlb_hit_super ? {mdtlb_hit_ppn[19:10], walk_va[21:12]} : mdtlb_hit_ppn;
  wire        mdtlb_perm_ok = check_perm(mdtlb_hit_perm, walk_priv, 1'b0, walk_is_store, mmu_sum, mmu_mxr);
  wire        mitlb_perm_ok = check_perm(mitlb_hit_perm, walk_priv, 1'b1, 1'b0,          mmu_sum, mmu_mxr);

  // 独立 PTW 写主 TLB 判据 (仅依赖本地纯 FF + ptw_ack/ptw_rdata，彻底断绝 ibus_kill/satp_flush!)
  wire ptw_l1_ok = (state == M_PTW_L1) && ptw_ack && !ptw_err &&
                   !pte_invalid && pte_is_leaf && !pte_super_mis && !pte_pa_hi_err &&
                   pte_a && walk_perm_ok;
  wire ptw_l0_ok = (state == M_PTW_L0) && ptw_ack && !ptw_err &&
                   !pte_invalid && pte_is_leaf && !pte_pa_hi_err &&
                   pte_a && walk_perm_ok;
  wire ptw_fill_ok    = ptw_l1_ok || ptw_l0_ok;
  wire ptw_fill_super = ptw_l1_ok;
  wire [19:0] ptw_fill_vpn = ptw_l1_ok ? {walk_va[31:22], 10'd0}   : walk_va[31:12];
  wire [19:0] ptw_fill_ppn = ptw_l1_ok ? {pte_ppn22[19:10], 10'd0} : l0_leaf_ppn;

  (* max_fanout = 16 *) wire fill_dtlb_en = ptw_fill_ok &&  walk_is_d;
  (* max_fanout = 16 *) wire fill_itlb_en = ptw_fill_ok && !walk_is_d && !walk_discard;

  // ---- 独立无异步复位块写 16 项主 TLB 数据阵列 (短局部 CE，彻底脱离 CPU 关键路径) ----
  always @(posedge clk) begin
    if (fill_dtlb_en) begin
      dtlb_super[dtlb_repl] <= ptw_fill_super;
      dtlb_vpn[dtlb_repl]   <= ptw_fill_vpn;
      dtlb_ppn[dtlb_repl]   <= ptw_fill_ppn;
      dtlb_perm[dtlb_repl]  <= pte_perm5;
    end
  end

  always @(posedge clk) begin
    if (fill_itlb_en) begin
      itlb_super[itlb_repl] <= ptw_fill_super;
      itlb_vpn[itlb_repl]   <= ptw_fill_vpn;
      itlb_ppn[itlb_repl]   <= ptw_fill_ppn;
      itlb_perm[itlb_repl]  <= pte_perm5;
    end
  end

  integer j;
  initial begin
    itlb_super = {ITLB_ENTRIES{1'b0}};
    dtlb_super = {DTLB_ENTRIES{1'b0}};
    for (j = 0; j < ITLB_ENTRIES; j = j + 1) begin
      itlb_vpn[j]  = 20'd0;
      itlb_ppn[j]  = 20'd0;
      itlb_perm[j] = 5'd0;
    end
    for (j = 0; j < DTLB_ENTRIES; j = j + 1) begin
      dtlb_vpn[j]  = 20'd0;
      dtlb_ppn[j]  = 20'd0;
      dtlb_perm[j] = 5'd0;
    end
  end

  // ---- 状态机、微型 TLB 与 34 位 valid 向量维护 ----
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state           <= M_IDLE;
      walk_is_d       <= 1'b0;
      walk_va         <= 32'd0;
      walk_is_store   <= 1'b0;
      walk_priv       <= `PRIV_M;
      walk_discard    <= 1'b0;
      ui_vld          <= 1'b0;
      ui_super        <= 1'b0;
      ui_vpn          <= 20'd0;
      ui_ppn          <= 20'd0;
      ui_perm         <= 5'd0;
      ud_vld          <= 1'b0;
      ud_super        <= 1'b0;
      ud_vpn          <= 20'd0;
      ud_ppn          <= 20'd0;
      ud_perm         <= 5'd0;
      itlb_vld        <= {ITLB_ENTRIES{1'b0}};
      itlb_repl       <= {ITLB_IDX_W{1'b0}};
      dtlb_vld        <= {DTLB_ENTRIES{1'b0}};
      dtlb_repl       <= {DTLB_IDX_W{1'b0}};
      ptw_req         <= 1'b0;
      ptw_addr        <= 32'd0;
      itlb_resp_valid <= 1'b0;
      itlb_resp_pf    <= 1'b0;
      itlb_resp_af    <= 1'b0;
      dtlb_resp_valid <= 1'b0;
      dtlb_resp_pa    <= 32'd0;
      dtlb_resp_pf    <= 1'b0;
      dtlb_resp_af    <= 1'b0;
    end
    else begin
      itlb_resp_valid <= 1'b0;
      itlb_resp_pf    <= 1'b0;
      itlb_resp_af    <= 1'b0;
      dtlb_resp_valid <= 1'b0;
      dtlb_resp_pf    <= 1'b0;
      dtlb_resp_af    <= 1'b0;

      case (state)
        M_IDLE: begin
          ptw_req      <= 1'b0;
          walk_discard <= 1'b0;

          if (sfence_req) begin
            ui_vld   <= 1'b0;
            ud_vld   <= 1'b0;
            itlb_vld <= {ITLB_ENTRIES{1'b0}};
            dtlb_vld <= {DTLB_ENTRIES{1'b0}};
          end
          else if (dtlb_miss_req && !dtlb_resp_valid) begin
            walk_is_d     <= 1'b1;
            walk_va       <= dtlb_miss_va;
            walk_is_store <= dtlb_miss_we || dtlb_miss_amo;
            walk_priv     <= d_priv;
            state         <= M_CHECK;
          end
          else if (itlb_miss_req && !itlb_miss_kill && !itlb_resp_valid && !satp_flush) begin
            walk_is_d     <= 1'b0;
            walk_va       <= itlb_miss_va;
            walk_is_store <= 1'b0;
            walk_priv     <= mmu_priv;
            state         <= M_CHECK;
          end
        end

        M_CHECK: begin
          if (walk_is_d) begin
            if (mdtlb_hit) begin
              ud_vld          <= 1'b1;
              ud_super        <= mdtlb_hit_super;
              ud_vpn          <= mdtlb_hit_vpn;
              ud_ppn          <= mdtlb_hit_ppn;
              ud_perm         <= mdtlb_hit_perm;
              dtlb_resp_valid <= 1'b1;
              dtlb_resp_pa    <= {mdtlb_res_ppn, walk_va[11:0]};
              dtlb_resp_pf    <= !mdtlb_perm_ok;
              dtlb_resp_af    <= 1'b0;
              state           <= M_IDLE;
            end
            else if (mmu_satp[21:20] != 2'b00) begin
              dtlb_resp_valid <= 1'b1;
              dtlb_resp_pf    <= 1'b0;
              dtlb_resp_af    <= 1'b1;
              state           <= M_IDLE;
            end
            else begin
              ptw_req  <= 1'b1;
              ptw_addr <= {mmu_satp[19:0], walk_va[31:22], 2'b00};
              state    <= M_PTW_L1;
            end
          end
          else begin
            if (walk_discard) begin
              itlb_resp_valid <= 1'b1;
              state           <= M_IDLE;
            end
            else if (mitlb_hit) begin
              ui_vld          <= 1'b1;
              ui_super        <= mitlb_hit_super;
              ui_vpn          <= mitlb_hit_vpn;
              ui_ppn          <= mitlb_hit_ppn;
              ui_perm         <= mitlb_hit_perm;
              itlb_resp_valid <= 1'b1;
              itlb_resp_pf    <= !mitlb_perm_ok;
              itlb_resp_af    <= 1'b0;
              state           <= M_IDLE;
            end
            else if (mmu_satp[21:20] != 2'b00) begin
              itlb_resp_valid <= 1'b1;
              itlb_resp_pf    <= 1'b0;
              itlb_resp_af    <= 1'b1;
              state           <= M_IDLE;
            end
            else begin
              ptw_req  <= 1'b1;
              ptw_addr <= {mmu_satp[19:0], walk_va[31:22], 2'b00};
              state    <= M_PTW_L1;
            end
          end
        end

        M_PTW_L1: begin
          if (ptw_ack) begin
            ptw_req <= 1'b0;
            if (!walk_is_d && walk_discard) begin
              itlb_resp_valid <= 1'b1;
              state           <= M_IDLE;
            end
            else if (ptw_err) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_af <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_af <= 1'b1; end
              state <= M_IDLE;
            end
            else if (pte_invalid) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_pf <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_pf <= 1'b1; end
              state <= M_IDLE;
            end
            else if (pte_is_leaf) begin
              if (pte_super_mis) begin
                if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_pf <= 1'b1; end
                else           begin itlb_resp_valid <= 1'b1; itlb_resp_pf <= 1'b1; end
                state <= M_IDLE;
              end
              else if (pte_pa_hi_err) begin
                if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_af <= 1'b1; end
                else           begin itlb_resp_valid <= 1'b1; itlb_resp_af <= 1'b1; end
                state <= M_IDLE;
              end
              else if (!pte_a || !walk_perm_ok) begin
                if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_pf <= 1'b1; end
                else           begin itlb_resp_valid <= 1'b1; itlb_resp_pf <= 1'b1; end
                state <= M_IDLE;
              end
              else begin
                if (walk_is_d) begin
                  ud_vld              <= 1'b1;
                  ud_super            <= 1'b1;
                  ud_vpn              <= {walk_va[31:22], 10'd0};
                  ud_ppn              <= {pte_ppn22[19:10], 10'd0};
                  ud_perm             <= pte_perm5;
                  dtlb_vld[dtlb_repl] <= 1'b1;
                  dtlb_repl           <= dtlb_repl + {{(DTLB_IDX_W-1){1'b0}}, 1'b1};
                  dtlb_resp_valid     <= 1'b1;
                  dtlb_resp_pa        <= {l1_leaf_ppn, walk_va[11:0]};
                end
                else begin
                  ui_vld              <= 1'b1;
                  ui_super            <= 1'b1;
                  ui_vpn              <= {walk_va[31:22], 10'd0};
                  ui_ppn              <= {pte_ppn22[19:10], 10'd0};
                  ui_perm             <= pte_perm5;
                  itlb_vld[itlb_repl] <= 1'b1;
                  itlb_repl           <= itlb_repl + {{(ITLB_IDX_W-1){1'b0}}, 1'b1};
                  itlb_resp_valid     <= 1'b1;
                end
                state <= M_IDLE;
              end
            end
            else begin
              if (pte_pa_hi_err) begin
                if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_af <= 1'b1; end
                else           begin itlb_resp_valid <= 1'b1; itlb_resp_af <= 1'b1; end
                state <= M_IDLE;
              end
              else begin
                ptw_req  <= 1'b1;
                ptw_addr <= {pte_ppn22[19:0], walk_va[21:12], 2'b00};
                state    <= M_PTW_L0;
              end
            end
          end
        end

        M_PTW_L0: begin
          if (ptw_ack) begin
            ptw_req <= 1'b0;
            if (!walk_is_d && walk_discard) begin
              itlb_resp_valid <= 1'b1;
              state           <= M_IDLE;
            end
            else if (ptw_err) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_af <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_af <= 1'b1; end
              state <= M_IDLE;
            end
            else if (pte_invalid || !pte_is_leaf) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_pf <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_pf <= 1'b1; end
              state <= M_IDLE;
            end
            else if (pte_pa_hi_err) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_af <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_af <= 1'b1; end
              state <= M_IDLE;
            end
            else if (!pte_a || !walk_perm_ok) begin
              if (walk_is_d) begin dtlb_resp_valid <= 1'b1; dtlb_resp_pf <= 1'b1; end
              else           begin itlb_resp_valid <= 1'b1; itlb_resp_pf <= 1'b1; end
              state <= M_IDLE;
            end
            else begin
              if (walk_is_d) begin
                ud_vld              <= 1'b1;
                ud_super            <= 1'b0;
                ud_vpn              <= walk_va[31:12];
                ud_ppn              <= l0_leaf_ppn;
                ud_perm             <= pte_perm5;
                dtlb_vld[dtlb_repl] <= 1'b1;
                dtlb_repl           <= dtlb_repl + {{(DTLB_IDX_W-1){1'b0}}, 1'b1};
                dtlb_resp_valid     <= 1'b1;
                dtlb_resp_pa        <= {l0_leaf_ppn, walk_va[11:0]};
              end
              else begin
                ui_vld              <= 1'b1;
                ui_super            <= 1'b0;
                ui_vpn              <= walk_va[31:12];
                ui_ppn              <= l0_leaf_ppn;
                ui_perm             <= pte_perm5;
                itlb_vld[itlb_repl] <= 1'b1;
                itlb_repl           <= itlb_repl + {{(ITLB_IDX_W-1){1'b0}}, 1'b1};
                itlb_resp_valid     <= 1'b1;
              end
              state <= M_IDLE;
            end
          end
        end

        default: state <= M_IDLE;
      endcase

      // 写 satp 时后置覆盖仅清零 34 位 valid FF (零大扇出数据 CE 串行!)
      if (satp_flush) begin
        ui_vld   <= 1'b0;
        ud_vld   <= 1'b0;
        itlb_vld <= {ITLB_ENTRIES{1'b0}};
        dtlb_vld <= {DTLB_ENTRIES{1'b0}};
        if (state != M_IDLE) walk_discard <= 1'b1;
      end
    end
  end

endmodule
