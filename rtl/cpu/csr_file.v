`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// csr_file.v — M-mode CSR 寄存器堆 + Zicntr + 向量化 mtvec + 严格非法 CSR 校验
// 纯 Verilog-2001，面向路线 A (nommu Linux) 并预留路线 B (S/U 特权级) 扩展口
// ----------------------------------------------------------------------------
// 已实现 CSR:
//   M-mode 信息: mvendorid(0xF11), marchid(0xF12), mimpid(0xF13), mhartid(0xF14), mconfigptr(0xF15)
//   M-mode 陷阱: mstatus(0x300), misa(0x301), mie(0x304), mtvec(0x305), mcounteren(0x306),
//                mstatush(0x310), mcountinhibit(0x320), mscratch(0x340), mepc(0x341),
//                mcause(0x342), mtval(0x343), mip(0x344)
//   Zicntr     : mcycle/h(0xB00/0xB80), minstret/h(0xB02/0xB82),
//                cycle/h(0xC00/0xC80), time/h(0xC01/0xC81), instret/h(0xC02/0xC82)
// 中断优先级 (RISC-V Priv Spec §3.1.9): MEI (11) > MSI (3) > MTI (7)
// ============================================================================

module csr_file #(
  parameter [31:0] MTVEC_RESET = 32'h8000_0100,
`ifndef A_DIS
  parameter [31:0] MISA_VALUE  = 32'h4000_1101    // RV32IMA
`else
  parameter [31:0] MISA_VALUE  = 32'h4000_1100    // RV32IM
`endif
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

  input  wire        instret_inc,
  input  wire [63:0] mtime_i,

  input  wire        irq_sw,
  input  wire        irq_timer,
  input  wire        irq_ext,
  output wire        irq_pending,
  output wire [4:0]  irq_cause,
  output wire        wfi_wake
);

  // CSR 地址常量
  localparam [11:0] CSR_MSTATUS       = 12'h300;
  localparam [11:0] CSR_MISA          = 12'h301;
  localparam [11:0] CSR_MIE           = 12'h304;
  localparam [11:0] CSR_MTVEC         = 12'h305;
  localparam [11:0] CSR_MCOUNTEREN    = 12'h306;
  localparam [11:0] CSR_MSTATUSH      = 12'h310;
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

  localparam MSTATUS_MIE  = 3;
  localparam MSTATUS_MPIE = 7;
  localparam IRQ_MSIP     = 3;
  localparam IRQ_MTIP     = 7;
  localparam IRQ_MEIP     = 11;

  // 状态寄存器
  reg        st_mie;
  reg        st_mpie;
  wire [1:0] st_mpp = 2'b11;  // 纯 M-mode 下 MPP WARL 恒为 2'b11 (路线 B 加 U/S 后改为寄存器)
  reg [31:0] mtvec;
  reg [2:0]  mcounteren;      // [0]=CY, [1]=TM, [2]=IR
  reg        inhibit_cy;
  reg        inhibit_ir;
  reg [31:0] mscratch;
  reg [31:0] mepc;
  reg [31:0] mcause;
  reg [31:0] mtval;
  reg        ie_msie, ie_mtie, ie_meie;
  reg [63:0] mcycle_cnt;
  reg [63:0] minstret_cnt;

  wire [31:0] mip_val = {20'b0, irq_ext, 3'b0, irq_timer, 3'b0, irq_sw, 3'b0};
  wire [31:0] mie_val = {20'b0, ie_meie, 3'b0, ie_mtie,   3'b0, ie_msie, 3'b0};

  // --------------------------------------------------------------------------
  // CSR 读出与存在性校验
  // --------------------------------------------------------------------------
  reg csr_exists;
  always @(*) begin
    csr_exists = 1'b1;
    case (raddr)
      CSR_MSTATUS       : rdata = {19'b0, st_mpp, 3'b0, st_mpie, 3'b0, st_mie, 3'b0};
      CSR_MISA          : rdata = MISA_VALUE;
      CSR_MIE           : rdata = mie_val;
      CSR_MTVEC         : rdata = mtvec;
      CSR_MCOUNTEREN    : rdata = {29'b0, mcounteren};
      CSR_MSTATUSH      : rdata = 32'd0;
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

      default           : begin
        rdata      = 32'd0;
        csr_exists = 1'b0;
      end
    endcase
  end

  wire csr_ro = (raddr[11:10] == 2'b11);
  assign csr_illegal = csr_op_en && (!csr_exists || (csr_ro && csr_wr_req));

  // --------------------------------------------------------------------------
  // 中断仲裁 (MEI > MSI > MTI) 与 WFI 唤醒
  // --------------------------------------------------------------------------
  wire ext_irq_en   = ie_meie && irq_ext;
  wire sw_irq_en    = ie_msie && irq_sw;
  wire timer_irq_en = ie_mtie && irq_timer;

  assign wfi_wake    = ext_irq_en || sw_irq_en || timer_irq_en;
  assign irq_pending = st_mie && wfi_wake;
  assign irq_cause   = ext_irq_en ? {1'b1, `IRQ_EXT}
                     : sw_irq_en  ? {1'b1, `IRQ_SW}
                     :              {1'b1, `IRQ_TIMER};

  // 向量化 mtvec (mode = 2'b01 时异步中断跳 base + 4*cause; 同步异常一律跳 base)
  wire [31:0] mtvec_base = {mtvec[31:2], 2'b00};
  assign trap_enter  = trap_req;
  assign trap_vector = (trap_cause[4] && (mtvec[1:0] == 2'b01))
                       ? (mtvec_base + {26'b0, trap_cause[3:0], 2'b00})
                       : mtvec_base;
  assign mret_taken  = mret_req;
  assign mret_pc     = mepc;

  // --------------------------------------------------------------------------
  // 状态更新 (64 位计数器 + 陷阱/MRET/CSR 写)
  // --------------------------------------------------------------------------
  wire [63:0] mcycle_next   = inhibit_cy ? mcycle_cnt   : (mcycle_cnt + 64'd1);
  wire [63:0] minstret_next = (!inhibit_ir && instret_inc) ? (minstret_cnt + 64'd1) : minstret_cnt;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      st_mie       <= 1'b0;
      st_mpie      <= 1'b0;
      mtvec        <= MTVEC_RESET;
      mcounteren   <= 3'b000;
      inhibit_cy   <= 1'b0;
      inhibit_ir   <= 1'b0;
      mscratch     <= 32'd0;
      mepc         <= 32'd0;
      mcause       <= 32'd0;
      mtval        <= 32'd0;
      ie_msie      <= 1'b0;
      ie_mtie      <= 1'b0;
      ie_meie      <= 1'b0;
      mcycle_cnt   <= 64'd0;
      minstret_cnt <= 64'd0;
    end
    else begin
      // 默认计数自增 (若同拍软件写 mcycle/minstret 则由下方 case 覆盖对应半字)
      mcycle_cnt   <= mcycle_next;
      minstret_cnt <= minstret_next;

      if (trap_req) begin
        mepc    <= trap_pc;
        mcause  <= {trap_cause[4], 27'b0, trap_cause[3:0]};
        mtval   <= trap_tval;
        st_mpie <= st_mie;
        st_mie  <= 1'b0;
      end
      else if (mret_req) begin
        st_mie  <= st_mpie;
        st_mpie <= 1'b1;
      end
      else if (we) begin
        case (waddr)
          CSR_MSTATUS : begin
            st_mie  <= wdata[MSTATUS_MIE];
            st_mpie <= wdata[MSTATUS_MPIE];
          end
          CSR_MIE     : begin
            ie_msie <= wdata[IRQ_MSIP];
            ie_mtie <= wdata[IRQ_MTIP];
            ie_meie <= wdata[IRQ_MEIP];
          end
          CSR_MTVEC   : begin
            mtvec <= {wdata[31:2], 1'b0, (wdata[1:0] == 2'b01) ? 1'b1 : 1'b0};
          end
          CSR_MCOUNTEREN    : mcounteren <= wdata[2:0];
          CSR_MCOUNTINHIBIT : begin
            inhibit_cy <= wdata[0];
            inhibit_ir <= wdata[2];
          end
          CSR_MSCRATCH      : mscratch <= wdata;
          CSR_MEPC          : mepc     <= {wdata[31:2], 2'b00};
          CSR_MCAUSE        : mcause   <= wdata;
          CSR_MTVAL         : mtval    <= wdata;
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
