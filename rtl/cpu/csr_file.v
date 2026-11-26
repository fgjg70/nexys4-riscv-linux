`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// csr_file.v — M/S/U 特权级 CSR 寄存器堆 + 陷阱委托 + Zicntr + 向量化 mtvec/stvec
// 纯 Verilog-2001，满足 OpenSBI v1.x + 标准 Sv32 Linux v6.x 全部特权规范需求
// ----------------------------------------------------------------------------
// 参数 ENABLE_SU:
//   - ENABLE_SU = 1 (默认, rv32_soc 路线 B): 完整 M/S/U 特权级、S-mode CSRs、
//     medeleg/mideleg 委托、satp、SRET、MPRV/SUM/MXR/TVM/TW/TSR、misa.S/U=1。
//   - ENABLE_SU = 0 (legacy core.v): 保持 100% 纯 M-mode 向后兼容 (misa=0x4000_1101,
//     MPP 恒 2'b11)，原有裸机测试零回归。
// 中断优先级 (RISC-V Priv Spec §3.1.9):
//   M-destined (MEI > MSI > MTI > SEI > SSI > STI) > S-destined (SEI > SSI > STI)
// ============================================================================

module csr_file #(
  parameter        ENABLE_SU   = 1,
  parameter [31:0] MTVEC_RESET = 32'h8000_0100,
  parameter [31:0] MISA_VALUE  = 32'd0   // 0=自动按 A_DIS 与 ENABLE_SU 生成
)(
  input  wire        clk,
  input  wire        rst,

  input  wire        csr_op_en,
  input  wire        csr_wr_req,
  input  wire [11:0] raddr,
  output reg  [31:0] rdata,
  output wire        csr_illegal,

  input  wire        we,
  input  wire [11:0] waddr,
  input  wire [31:0] wdata,

  input  wire        trap_req,
  input  wire [4:0]  trap_cause,
  input  wire [31:0] trap_pc,
  input  wire [31:0] trap_tval,
  output wire        trap_enter,
  output wire [31:0] trap_vector,

  input  wire        mret_req,
  output wire        mret_taken,
  output wire [31:0] mret_pc,

  input  wire        sret_req,
  output wire        sret_taken,
  output wire [31:0] sret_pc,

  input  wire        instret_inc,
  input  wire [63:0] mtime_i,

  input  wire        irq_sw,
  input  wire        irq_timer,
  input  wire        irq_ext,
  input  wire        irq_sext,
  output wire        irq_pending,
  output wire [4:0]  irq_cause,
  output wire        wfi_wake,

  // 特权级与 MMU / 陷阱控制实时输出
  output wire [1:0]  priv_o,
  output wire [31:0] satp_o,
  output wire        i_xlate_en_o,
  output wire        mstatus_sum,
  output wire        mstatus_mxr,
  output wire        mstatus_mprv,
  output wire [1:0]  mstatus_mpp,
  output wire        mstatus_tvm,
  output wire        mstatus_tw,
  output wire        mstatus_tsr
);

  // MISA 自动配置 (A_DIS 控制 bit0, ENABLE_SU 控制 bit18=S & bit20=U)
`ifndef A_DIS
  localparam [31:0] MISA_BASE = 32'h4000_1101;
`else
  localparam [31:0] MISA_BASE = 32'h4000_1100;
`endif
  localparam [31:0] MISA_AUTO = (ENABLE_SU != 0) ? (MISA_BASE | 32'h0014_0000) : MISA_BASE;
  localparam [31:0] MISA_EFF  = (MISA_VALUE != 32'd0) ? MISA_VALUE : MISA_AUTO;

  // S-mode CSR 地址常量
  localparam [11:0] CSR_SSTATUS       = 12'h100;
  localparam [11:0] CSR_SIE           = 12'h104;
  localparam [11:0] CSR_STVEC         = 12'h105;
  localparam [11:0] CSR_SCOUNTEREN    = 12'h106;
  localparam [11:0] CSR_SENVCFG       = 12'h10A;
  localparam [11:0] CSR_SSCRATCH      = 12'h140;
  localparam [11:0] CSR_SEPC          = 12'h141;
  localparam [11:0] CSR_SCAUSE        = 12'h142;
  localparam [11:0] CSR_STVAL         = 12'h143;
  localparam [11:0] CSR_SIP           = 12'h144;
  localparam [11:0] CSR_SATP          = 12'h180;

  // M-mode CSR 地址常量
  localparam [11:0] CSR_MSTATUS       = 12'h300;
  localparam [11:0] CSR_MISA          = 12'h301;
  localparam [11:0] CSR_MEDELEG       = 12'h302;
  localparam [11:0] CSR_MIDELEG       = 12'h303;
  localparam [11:0] CSR_MIE           = 12'h304;
  localparam [11:0] CSR_MTVEC         = 12'h305;
  localparam [11:0] CSR_MCOUNTEREN    = 12'h306;
  localparam [11:0] CSR_MENVCFG       = 12'h30A;
  localparam [11:0] CSR_MSTATUSH      = 12'h310;
  localparam [11:0] CSR_MENVCFGH      = 12'h31A;
  localparam [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam [11:0] CSR_MSCRATCH      = 12'h340;
  localparam [11:0] CSR_MEPC          = 12'h341;
  localparam [11:0] CSR_MCAUSE        = 12'h342;
  localparam [11:0] CSR_MTVAL         = 12'h343;
  localparam [11:0] CSR_MIP           = 12'h344;

  localparam [11:0] CSR_MCYCLE        = 12'hB00;
  localparam [11:0] CSR_MINSTRET      = 12'hB02;
  localparam [11:0] CSR_MCYCLEH       = 12'hB80;
  localparam [11:0] CSR_MINSTRETH     = 12'hB82;

  localparam [11:0] CSR_CYCLE         = 12'hC00;
  localparam [11:0] CSR_TIME          = 12'hC01;
  localparam [11:0] CSR_INSTRET       = 12'hC02;
  localparam [11:0] CSR_CYCLEH        = 12'hC80;
  localparam [11:0] CSR_TIMEH         = 12'hC81;
  localparam [11:0] CSR_INSTRETH      = 12'hC82;

  localparam [11:0] CSR_MVENDORID     = 12'hF11;
  localparam [11:0] CSR_MARCHID       = 12'hF12;
  localparam [11:0] CSR_MIMPID        = 12'hF13;
  localparam [11:0] CSR_MHARTID       = 12'hF14;
  localparam [11:0] CSR_MCONFIGPTR    = 12'hF15;

  // mstatus 位索引
  localparam MSTATUS_SIE  = 1;
  localparam MSTATUS_MIE  = 3;
  localparam MSTATUS_SPIE = 5;
  localparam MSTATUS_MPIE = 7;
  localparam MSTATUS_SPP  = 8;
  localparam MSTATUS_MPRV = 17;
  localparam MSTATUS_SUM  = 18;
  localparam MSTATUS_MXR  = 19;
  localparam MSTATUS_TVM  = 20;
  localparam MSTATUS_TW   = 21;
  localparam MSTATUS_TSR  = 22;

  // mip / mie 位索引
  localparam BIT_SSIP = 1;
  localparam BIT_MSIP = 3;
  localparam BIT_STIP = 5;
  localparam BIT_MTIP = 7;
  localparam BIT_SEIP = 9;
  localparam BIT_MEIP = 11;

  // medeleg 合法掩码 (禁止委托 ECALL_M=11 与保留位 10/14)
  localparam [15:0] MEDELEG_MASK = 16'hB3FF;
  // mideleg 合法掩码 (仅 SSIP=1, STIP=5, SEIP=9 可委托给 S-mode)
  localparam [11:0] MIDELEG_MASK = 12'h222;

  // --------------------------------------------------------------------------
  // 状态寄存器 (保留 st_mie / st_mpie / st_mpp 命名以兼容 sim/tb_soc.v 探针)
  // --------------------------------------------------------------------------
  reg [1:0]  priv;
  reg        st_sie;
  reg        st_mie;
  reg        st_spie;
  reg        st_mpie;
  reg        st_spp;
  reg [1:0]  st_mpp;
  reg        st_mprv;
  reg        st_sum;
  reg        st_mxr;
  reg        st_tvm;
  reg        st_tw;
  reg        st_tsr;

  reg [15:0] medeleg;
  reg [11:0] mideleg;
  reg [31:0] mtvec;
  reg [2:0]  mcounteren;      // [0]=CY, [1]=TM, [2]=IR
  reg        inhibit_cy;
  reg        inhibit_ir;
  reg [31:0] mscratch;
  reg [31:0] mepc;
  reg [31:0] mcause;
  reg [31:0] mtval;
  reg        ie_ssie, ie_msie, ie_stie, ie_mtie, ie_seie, ie_meie;
  reg        mip_ssip, mip_stip, mip_seip_sw;

  // S-mode 专属寄存器
  reg [31:0] stvec;
  reg [2:0]  scounteren;      // [0]=CY, [1]=TM, [2]=IR
  reg [31:0] sscratch;
  reg [31:0] sepc;
  reg [31:0] scause;
  reg [31:0] stval;
  reg [31:0] satp;            // [31]=MODE(Sv32), [30:22]=ASID(0), [21:0]=PPN
  reg        i_xlate_en_r;    // 寄存态 satp[31] && (priv != M)，为 VIPT I-Cache 提供 0-LUT 快路使能

  reg [63:0] mcycle_cnt;
  reg [63:0] minstret_cnt;

  wire su_en = (ENABLE_SU != 0);

  // 有效特权级与控制输出
  wire [1:0] priv_eff = su_en ? priv : `PRIV_M;
  assign priv_o       = priv_eff;
  assign satp_o       = su_en ? satp : 32'd0;
  assign i_xlate_en_o = su_en && i_xlate_en_r;
  assign mstatus_sum  = su_en && st_sum;
  assign mstatus_mxr  = su_en && st_mxr;
  assign mstatus_mprv = su_en && st_mprv;
  assign mstatus_mpp  = su_en ? st_mpp : `PRIV_M;
  assign mstatus_tvm  = su_en && st_tvm;
  assign mstatus_tw   = su_en && st_tw;
  assign mstatus_tsr  = su_en && st_tsr;

  // mstatus / sstatus / mip / mie / sip / sie 视图
  wire seip_eff = su_en && (mip_seip_sw || irq_sext);
  wire stip_eff = su_en && mip_stip;
  wire ssip_eff = su_en && mip_ssip;

  wire [31:0] mstatus_val = su_en
    ? {9'b0, st_tsr, st_tw, st_tvm, st_mxr, st_sum, st_mprv, 4'b0,
       st_mpp, 2'b0, st_spp, st_mpie, 1'b0, st_spie, 1'b0, st_mie, 1'b0, st_sie, 1'b0}
    : {19'b0, 2'b11, 3'b0, st_mpie, 3'b0, st_mie, 3'b0};

  wire [31:0] sstatus_val =
    {12'b0, st_mxr, st_sum, 9'b0, st_spp, 2'b0, st_spie, 3'b0, st_sie, 1'b0};

  wire [31:0] mip_val = {20'b0, irq_ext, 1'b0, seip_eff, 1'b0, irq_timer, 1'b0,
                         stip_eff, 1'b0, irq_sw, 1'b0, ssip_eff, 1'b0};
  wire [31:0] mie_val = {20'b0, ie_meie, 1'b0, (su_en && ie_seie), 1'b0, ie_mtie, 1'b0,
                         (su_en && ie_stie), 1'b0, ie_msie, 1'b0, (su_en && ie_ssie), 1'b0};
  wire [31:0] mideleg_ext = {20'b0, mideleg};
  wire [31:0] sip_val = mip_val & mideleg_ext;
  wire [31:0] sie_val = mie_val & mideleg_ext;

  // --------------------------------------------------------------------------
  // CSR 读出与并行存在性译码 (按高 4 位分段译码将 csr_exists 压至 3 级 LUT6 内)
  // --------------------------------------------------------------------------
  always @(*) begin
    case (raddr)
      CSR_SSTATUS       : rdata = sstatus_val;
      CSR_SIE           : rdata = sie_val;
      CSR_STVEC         : rdata = stvec;
      CSR_SCOUNTEREN    : rdata = {29'b0, scounteren};
      CSR_SENVCFG       : rdata = 32'd0;
      CSR_SSCRATCH      : rdata = sscratch;
      CSR_SEPC          : rdata = sepc;
      CSR_SCAUSE        : rdata = scause;
      CSR_STVAL         : rdata = stval;
      CSR_SIP           : rdata = sip_val;
      CSR_SATP          : rdata = satp;

      CSR_MSTATUS       : rdata = mstatus_val;
      CSR_MISA          : rdata = MISA_EFF;
      CSR_MEDELEG       : rdata = {16'b0, medeleg};
      CSR_MIDELEG       : rdata = {20'b0, mideleg};
      CSR_MIE           : rdata = mie_val;
      CSR_MTVEC         : rdata = mtvec;
      CSR_MCOUNTEREN    : rdata = {29'b0, mcounteren};
      CSR_MENVCFG       : rdata = 32'd0;
      CSR_MSTATUSH      : rdata = 32'd0;
      CSR_MENVCFGH      : rdata = 32'd0;
      CSR_MCOUNTINHIBIT : rdata = {29'b0, inhibit_ir, 1'b0, inhibit_cy};
      CSR_MSCRATCH      : rdata = mscratch;
      CSR_MEPC          : rdata = mepc;
      CSR_MCAUSE        : rdata = mcause;
      CSR_MTVAL         : rdata = mtval;
      CSR_MIP           : rdata = mip_val;

      CSR_MCYCLE        : rdata = mcycle_cnt[31:0];
      CSR_MCYCLEH       : rdata = mcycle_cnt[63:32];
      CSR_MINSTRET      : rdata = minstret_cnt[31:0];
      CSR_MINSTRETH     : rdata = minstret_cnt[63:32];

      CSR_CYCLE         : rdata = mcycle_cnt[31:0];
      CSR_CYCLEH        : rdata = mcycle_cnt[63:32];
      CSR_TIME          : rdata = mtime_i[31:0];
      CSR_TIMEH         : rdata = mtime_i[63:32];
      CSR_INSTRET       : rdata = minstret_cnt[31:0];
      CSR_INSTRETH      : rdata = minstret_cnt[63:32];

      CSR_MVENDORID     : rdata = 32'd0;
      CSR_MARCHID       : rdata = 32'd0;
      CSR_MIMPID        : rdata = 32'h0001_0000;
      CSR_MHARTID       : rdata = 32'd0;
      CSR_MCONFIGPTR    : rdata = 32'd0;

      default           : rdata = 32'd0;
    endcase
  end

  wire [3:0] r_hi = raddr[11:8];
  wire [7:0] r_lo = raddr[7:0];
  wire exists_s = su_en && (r_hi == 4'h1) && (
      (r_lo == 8'h00) || (r_lo == 8'h04) || (r_lo == 8'h05) || (r_lo == 8'h06) ||
      (r_lo == 8'h0A) || (r_lo == 8'h40) || (r_lo == 8'h41) || (r_lo == 8'h42) ||
      (r_lo == 8'h43) || (r_lo == 8'h44) || (r_lo == 8'h80));
  wire exists_m = (r_hi == 4'h3) && (
      (r_lo == 8'h00) || (r_lo == 8'h01) || (r_lo == 8'h04) || (r_lo == 8'h05) ||
      (r_lo == 8'h06) || (r_lo == 8'h10) || (r_lo == 8'h20) || (r_lo == 8'h40) ||
      (r_lo == 8'h41) || (r_lo == 8'h42) || (r_lo == 8'h43) || (r_lo == 8'h44) ||
      (su_en && ((r_lo == 8'h02) || (r_lo == 8'h03) || (r_lo == 8'h0A) || (r_lo == 8'h1A))));
  wire exists_cnt =
      ((r_hi == 4'hB) && ((r_lo == 8'h00) || (r_lo == 8'h02) || (r_lo == 8'h80) || (r_lo == 8'h82))) ||
      ((r_hi == 4'hC) && ((r_lo == 8'h00) || (r_lo == 8'h01) || (r_lo == 8'h02) ||
                          (r_lo == 8'h80) || (r_lo == 8'h81) || (r_lo == 8'h82)));
  wire exists_id  = (r_hi == 4'hF) && (r_lo[7:3] == 5'b00010) && (r_lo[2:0] >= 3'd1) && (r_lo[2:0] <= 3'd5);
  wire csr_exists = exists_s || exists_m || exists_cnt || exists_id;

  wire csr_ro       = (raddr[11:10] == 2'b11);
  wire csr_priv_bad = su_en && (priv_eff < raddr[9:8]);
  wire csr_tvm_bad  = su_en && (priv_eff == `PRIV_S) && st_tvm && (raddr == CSR_SATP);

  // Zicntr 访问控制 (cycle/time/instret 在 S 受 mcounteren 管控，在 U 受 mcounteren & scounteren 管控)
  wire is_ucnt_cy = (raddr == CSR_CYCLE)   || (raddr == CSR_CYCLEH);
  wire is_ucnt_tm = (raddr == CSR_TIME)    || (raddr == CSR_TIMEH);
  wire is_ucnt_ir = (raddr == CSR_INSTRET) || (raddr == CSR_INSTRETH);
  wire is_ucnt    = is_ucnt_cy || is_ucnt_tm || is_ucnt_ir;
  wire ucnt_m_ok  = (is_ucnt_cy && mcounteren[0]) ||
                    (is_ucnt_tm && mcounteren[1]) ||
                    (is_ucnt_ir && mcounteren[2]);
  wire ucnt_s_ok  = (is_ucnt_cy && scounteren[0]) ||
                    (is_ucnt_tm && scounteren[1]) ||
                    (is_ucnt_ir && scounteren[2]);
  wire csr_cnt_bad = su_en && is_ucnt && (
      ((priv_eff == `PRIV_S) && !ucnt_m_ok) ||
      ((priv_eff == `PRIV_U) && !(ucnt_m_ok && ucnt_s_ok))
  );

  assign csr_illegal = csr_op_en && (!csr_exists || (csr_ro && csr_wr_req) ||
                                     csr_priv_bad || csr_tvm_bad || csr_cnt_bad);

  // --------------------------------------------------------------------------
  // 中断仲裁 (RISC-V Priv Spec §3.1.9) 与 WFI 唤醒
  // --------------------------------------------------------------------------
  wire en_mei = ie_meie && irq_ext;
  wire en_msi = ie_msie && irq_sw;
  wire en_mti = ie_mtie && irq_timer;
  wire en_sei = su_en && ie_seie && seip_eff;
  wire en_ssi = su_en && ie_ssie && ssip_eff;
  wire en_sti = su_en && ie_stie && stip_eff;

  // WFI 唤醒无视全局 MIE/SIE 与委托，只要任一 (mip & mie) != 0 即唤醒
  assign wfi_wake = en_mei || en_msi || en_mti || en_sei || en_ssi || en_sti;

  wire m_glob_en = (priv_eff != `PRIV_M) || st_mie;
  wire s_glob_en = su_en && ((priv_eff == `PRIV_U) || ((priv_eff == `PRIV_S) && st_sie));

  // 目标为 M-mode 的可触发中断 (未委托的 S 中断亦路由至 M-mode)
  wire take_mei_m = m_glob_en && en_mei;
  wire take_msi_m = m_glob_en && en_msi;
  wire take_mti_m = m_glob_en && en_mti;
  wire take_sei_m = m_glob_en && en_sei && !mideleg[BIT_SEIP];
  wire take_ssi_m = m_glob_en && en_ssi && !mideleg[BIT_SSIP];
  wire take_sti_m = m_glob_en && en_sti && !mideleg[BIT_STIP];

  // 目标为 S-mode 的可触发中断 (在 M-mode 下 s_glob_en=0 绝不抢占)
  wire take_sei_s = s_glob_en && en_sei && mideleg[BIT_SEIP];
  wire take_ssi_s = s_glob_en && en_ssi && mideleg[BIT_SSIP];
  wire take_sti_s = s_glob_en && en_sti && mideleg[BIT_STIP];

  assign irq_pending = take_mei_m || take_msi_m || take_mti_m ||
                       take_sei_m || take_ssi_m || take_sti_m ||
                       take_sei_s || take_ssi_s || take_sti_s;

  assign irq_cause = take_mei_m ? {1'b1, `IRQ_EXT}
                   : take_msi_m ? {1'b1, `IRQ_SW}
                   : take_mti_m ? {1'b1, `IRQ_TIMER}
                   : take_sei_m ? {1'b1, `IRQ_SEIP}
                   : take_ssi_m ? {1'b1, `IRQ_SSIP}
                   : take_sti_m ? {1'b1, `IRQ_STIP}
                   : take_sei_s ? {1'b1, `IRQ_SEIP}
                   : take_ssi_s ? {1'b1, `IRQ_SSIP}
                   :              {1'b1, `IRQ_STIP};

  // --------------------------------------------------------------------------
  // 陷阱委托与向量化入口计算 (预计算 irq 向量避开 exc_req 关键路径)
  // --------------------------------------------------------------------------
  wire trap_irq_deleg =
      ((trap_cause[3:0] == `IRQ_SSIP) && mideleg[BIT_SSIP]) ||
      ((trap_cause[3:0] == `IRQ_STIP) && mideleg[BIT_STIP]) ||
      ((trap_cause[3:0] == `IRQ_SEIP) && mideleg[BIT_SEIP]);

  wire trap_deleg = su_en && (priv_eff != `PRIV_M) &&
                    (trap_cause[4] ? trap_irq_deleg : medeleg[trap_cause[3:0]]);

  wire [31:0] mtvec_base = {mtvec[31:2], 2'b00};
  wire [31:0] m_irq_vec  = mtvec_base + {26'b0, irq_cause[3:0], 2'b00};
  wire [31:0] m_trap_vec = (trap_cause[4] && (mtvec[1:0] == 2'b01)) ? m_irq_vec : mtvec_base;

  wire [31:0] stvec_base = {stvec[31:2], 2'b00};
  wire [31:0] s_irq_vec  = stvec_base + {26'b0, irq_cause[3:0], 2'b00};
  wire [31:0] s_trap_vec = (trap_cause[4] && (stvec[1:0] == 2'b01)) ? s_irq_vec : stvec_base;

  assign trap_enter  = trap_req;
  assign trap_vector = trap_deleg ? s_trap_vec : m_trap_vec;

  assign mret_taken  = mret_req;
  assign mret_pc     = mepc;
  assign sret_taken  = sret_req;
  assign sret_pc     = sepc;

  // --------------------------------------------------------------------------
  // 状态更新 (64 位计数器 + 陷阱/MRET/SRET/CSR 写)
  // --------------------------------------------------------------------------
  wire [63:0] mcycle_next   = inhibit_cy ? mcycle_cnt   : (mcycle_cnt + 64'd1);
  wire [63:0] minstret_next = (!inhibit_ir && instret_inc) ? (minstret_cnt + 64'd1) : minstret_cnt;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      priv         <= `PRIV_M;
      st_sie       <= 1'b0;
      st_mie       <= 1'b0;
      st_spie      <= 1'b0;
      st_mpie      <= 1'b0;
      st_spp       <= 1'b0;
      st_mpp       <= `PRIV_M;
      st_mprv      <= 1'b0;
      st_sum       <= 1'b0;
      st_mxr       <= 1'b0;
      st_tvm       <= 1'b0;
      st_tw        <= 1'b0;
      st_tsr       <= 1'b0;
      medeleg      <= 16'd0;
      mideleg      <= 12'd0;
      mtvec        <= MTVEC_RESET;
      mcounteren   <= 3'b000;
      inhibit_cy   <= 1'b0;
      inhibit_ir   <= 1'b0;
      mscratch     <= 32'd0;
      mepc         <= 32'd0;
      mcause       <= 32'd0;
      mtval        <= 32'd0;
      ie_ssie      <= 1'b0;
      ie_msie      <= 1'b0;
      ie_stie      <= 1'b0;
      ie_mtie      <= 1'b0;
      ie_seie      <= 1'b0;
      ie_meie      <= 1'b0;
      mip_ssip     <= 1'b0;
      mip_stip     <= 1'b0;
      mip_seip_sw  <= 1'b0;
      stvec        <= 32'd0;
      scounteren   <= 3'b000;
      sscratch     <= 32'd0;
      sepc         <= 32'd0;
      scause       <= 32'd0;
      stval        <= 32'd0;
      satp         <= 32'd0;
      i_xlate_en_r <= 1'b0;
      mcycle_cnt   <= 64'd0;
      minstret_cnt <= 64'd0;
    end
    else begin
      mcycle_cnt   <= mcycle_next;
      minstret_cnt <= minstret_next;

      if (trap_req) begin
        if (trap_deleg) begin
          sepc         <= trap_pc;
          scause       <= {trap_cause[4], 27'b0, trap_cause[3:0]};
          stval        <= trap_tval;
          st_spie      <= st_sie;
          st_sie       <= 1'b0;
          st_spp       <= priv_eff[0];
          priv         <= `PRIV_S;
          i_xlate_en_r <= satp[31];
        end
        else begin
          mepc         <= trap_pc;
          mcause       <= {trap_cause[4], 27'b0, trap_cause[3:0]};
          mtval        <= trap_tval;
          st_mpie      <= st_mie;
          st_mie       <= 1'b0;
          if (su_en) st_mpp <= priv_eff;
          priv         <= `PRIV_M;
          i_xlate_en_r <= 1'b0;
        end
      end
      else if (mret_req) begin
        st_mie  <= st_mpie;
        st_mpie <= 1'b1;
        if (su_en) begin
          priv         <= st_mpp;
          i_xlate_en_r <= satp[31] && (st_mpp != `PRIV_M);
          if (st_mpp != `PRIV_M) st_mprv <= 1'b0;
          st_mpp <= `PRIV_U;
        end
      end
      else if (sret_req && su_en) begin
        st_sie       <= st_spie;
        st_spie      <= 1'b1;
        priv         <= {1'b0, st_spp};
        i_xlate_en_r <= satp[31];
        st_spp       <= 1'b0;
        st_mprv      <= 1'b0;
      end
      else if (we) begin
        case (waddr)
          CSR_MSTATUS : begin
            st_mie  <= wdata[MSTATUS_MIE];
            st_mpie <= wdata[MSTATUS_MPIE];
            if (su_en) begin
              st_sie  <= wdata[MSTATUS_SIE];
              st_spie <= wdata[MSTATUS_SPIE];
              st_spp  <= wdata[MSTATUS_SPP];
              if (wdata[12:11] != 2'b10) st_mpp <= wdata[12:11];
              st_mprv <= wdata[MSTATUS_MPRV];
              st_sum  <= wdata[MSTATUS_SUM];
              st_mxr  <= wdata[MSTATUS_MXR];
              st_tvm  <= wdata[MSTATUS_TVM];
              st_tw   <= wdata[MSTATUS_TW];
              st_tsr  <= wdata[MSTATUS_TSR];
            end
          end
          CSR_SSTATUS : if (su_en) begin
            st_sie  <= wdata[MSTATUS_SIE];
            st_spie <= wdata[MSTATUS_SPIE];
            st_spp  <= wdata[MSTATUS_SPP];
            st_sum  <= wdata[MSTATUS_SUM];
            st_mxr  <= wdata[MSTATUS_MXR];
          end
          CSR_MEDELEG : if (su_en) begin
            medeleg <= wdata[15:0] & MEDELEG_MASK;
          end
          CSR_MIDELEG : if (su_en) begin
            mideleg <= wdata[11:0] & MIDELEG_MASK;
          end
          CSR_MIE     : begin
            ie_msie <= wdata[BIT_MSIP];
            ie_mtie <= wdata[BIT_MTIP];
            ie_meie <= wdata[BIT_MEIP];
            if (su_en) begin
              ie_ssie <= wdata[BIT_SSIP];
              ie_stie <= wdata[BIT_STIP];
              ie_seie <= wdata[BIT_SEIP];
            end
          end
          CSR_SIE     : if (su_en) begin
            if (mideleg[BIT_SSIP]) ie_ssie <= wdata[BIT_SSIP];
            if (mideleg[BIT_STIP]) ie_stie <= wdata[BIT_STIP];
            if (mideleg[BIT_SEIP]) ie_seie <= wdata[BIT_SEIP];
          end
          CSR_MIP     : if (su_en) begin
            mip_ssip    <= wdata[BIT_SSIP];
            mip_stip    <= wdata[BIT_STIP];
            mip_seip_sw <= wdata[BIT_SEIP];
          end
          CSR_SIP     : if (su_en) begin
            // Priv Spec §4.1.3: sip 仅允许写已委托的 SSIP 位
            if (mideleg[BIT_SSIP]) mip_ssip <= wdata[BIT_SSIP];
          end
          CSR_MTVEC   : begin
            mtvec <= {wdata[31:2], 1'b0, (wdata[1:0] == 2'b01) ? 1'b1 : 1'b0};
          end
          CSR_STVEC   : if (su_en) begin
            stvec <= {wdata[31:2], 1'b0, (wdata[1:0] == 2'b01) ? 1'b1 : 1'b0};
          end
          CSR_MCOUNTEREN    : mcounteren <= wdata[2:0];
          CSR_SCOUNTEREN    : if (su_en) scounteren <= wdata[2:0];
          CSR_MCOUNTINHIBIT : begin
            inhibit_cy <= wdata[0];
            inhibit_ir <= wdata[2];
          end
          CSR_MSCRATCH      : mscratch <= wdata;
          CSR_MEPC          : mepc     <= {wdata[31:2], 2'b00};
          CSR_MCAUSE        : mcause   <= wdata;
          CSR_MTVAL         : mtval    <= wdata;
          CSR_SSCRATCH      : if (su_en) sscratch <= wdata;
          CSR_SEPC          : if (su_en) sepc     <= {wdata[31:2], 2'b00};
          CSR_SCAUSE        : if (su_en) scause   <= wdata;
          CSR_STVAL         : if (su_en) stval    <= wdata;
          CSR_SATP          : if (su_en) begin
            satp         <= {wdata[31], 9'd0, wdata[21:0]};
            i_xlate_en_r <= wdata[31] && (priv_eff != `PRIV_M);
          end
          CSR_MCYCLE        : mcycle_cnt[31:0]    <= wdata;
          CSR_MCYCLEH       : mcycle_cnt[63:32]   <= wdata;
          CSR_MINSTRET      : minstret_cnt[31:0]  <= wdata;
          CSR_MINSTRETH     : minstret_cnt[63:32] <= wdata;
          default           : ;
        endcase
      end
    end
  end

endmodule
