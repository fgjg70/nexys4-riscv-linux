`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// load_store_unit.v — 访存单元 (字节通道 + 非对齐拆分 + RV32A + 多周期总线停顿)
// 纯 Verilog-2001；Trap/MRET 时通过 res_clear 清除 LR/SC 预约寄存器。
// Stage 1A 升级:
//   - 新增 dmem_re 精确读使能 (仅实际 LOAD/AMO 读相拉高，杜绝空周期误触发 MMIO);
//   - 新增 dbus_stall 支持 D-Cache 缺失 / DDR2 / 慢速外设任意多拍等待;
//   - 新增 req_cancel 在 WB 段发现更老访存异常时屏蔽本拍 MEM 总线请求。
// ============================================================================

module load_store_unit (
  input  wire        clk,
  input  wire        rst,

  input  wire        req_read,
  input  wire        req_write,
  input  wire [1:0]  req_size,
  input  wire        req_unsigned,
  input  wire [31:0] req_addr,
  input  wire [31:0] req_wdata,
  input  wire        req_cancel,

  // RV32A 原子指令接口
  input  wire        amo_en,
  input  wire [31:0] amo_newdata,
  input  wire        amo_lr,
  input  wire        amo_sc,
  input  wire        res_clear,

  // 下游数据总线 / D-Cache 接口 (同步读: N 拍送请求, N+1 拍出数据或拉高 dbus_stall)
  output wire [31:0] dmem_addr,
  output wire [31:0] dmem_wdata,
  output wire [3:0]  dmem_wstrb,
  output wire        dmem_we,
  output wire        dmem_re,
  input  wire [31:0] dmem_rdata,
  input  wire        dbus_stall,

  output reg  [31:0] load_data,
  output wire        lsu_stall,
  output wire        amo_write_phase,
  output wire [31:0] amo_old_out,
  output wire        amo_sc_ok,
  output wire [31:0] amo_wb_out
);

  localparam [1:0] S_IDLE = 2'd0, S_HEAD = 2'd1, S_TAIL = 2'd2, S_AMO = 2'd3;

  reg [1:0]  state;
  reg        amo_phase;       // 0=读相, 1=写相
  reg        amo_wait;        // 1=等待寄存读出
  reg        amo_active;
  reg [31:0] amo_old;
  reg [31:0] amo_wb_r;        // 锁存离开 MEM 的 AMO 写回值，隔离背靠背 LR/SC
  reg [31:0] amo_addr_r;
  reg        amo_mode_r;

  // LR/SC 单字预约寄存器
  reg        res_valid;
  reg [29:0] res_addr;
  reg        sc_ok_r;

  reg [31:0] head_word_r;
  reg [1:0]  off_wb;
  reg [1:0]  size_wb;
  reg        uns_wb;
  reg        split_wb;

  wire [1:0]  off        = req_addr[1:0];
  wire [31:0] size_bytes = (req_size == `MEM_BYTE) ? 32'd1 :
                           (req_size == `MEM_HALF) ? 32'd2 : 32'd4;
  wire        needs_split = (req_read || req_write) &&
                            (({30'd0, off} + size_bytes) > 32'd4);

  wire [31:0] head_addr = {req_addr[31:2], 2'b00};
  wire [31:0] tail_addr = head_addr + 32'd4;

`ifndef A_DIS
  assign dmem_addr = (state == S_AMO)  ? amo_addr_r
                   : (state == S_IDLE) ? head_addr : tail_addr;
`else
  assign dmem_addr = (state == S_IDLE) ? head_addr : tail_addr;
`endif

  // Store 移位与字节写使能
  wire [63:0] store_shifted = {32'b0, req_wdata} << {off, 3'b000};
  wire [7:0]  size_mask     = (8'd1 << size_bytes[3:0]) - 8'd1;
  wire [7:0]  strobe8       = size_mask << off;
  wire [3:0]  head_strb     = strobe8[3:0];
  wire [3:0]  tail_strb     = strobe8[7:4];

  wire amo_wr       = amo_active & amo_phase;
  wire amo_no_write = amo_lr || (amo_sc && !sc_ok_r);

  assign dmem_wdata = (state == S_AMO)  ? amo_newdata
                    : (state == S_IDLE) ? store_shifted[31:0]
                                        : store_shifted[63:32];
  assign dmem_wstrb = req_cancel ? 4'b0000
                    : (state == S_AMO) ? ((amo_wr && !amo_no_write) ? 4'b1111 : 4'b0000)
                    : (req_write && (state != S_TAIL))
                      ? ((state == S_IDLE) ? head_strb : tail_strb) : 4'b0000;
  assign dmem_we    = !req_cancel && (
                        (state == S_AMO) ? (amo_wr && !amo_no_write)
                                         : (req_write && (state != S_TAIL))
                      );
  assign dmem_re    = !req_cancel && (
                        (state == S_IDLE) ? (req_read || amo_en)
                      : (state == S_HEAD) ? req_read
                      :                     1'b0
                      );

  wire lsu_fsm_stall = (state == S_HEAD) ||
                       ((state == S_IDLE) && (needs_split || amo_en)) ||
                       ((state == S_AMO) && (amo_wait || !amo_phase));

  assign lsu_stall       = lsu_fsm_stall || dbus_stall;
  assign amo_write_phase = amo_wr;
  assign amo_old_out     = amo_old;
  assign amo_sc_ok       = sc_ok_r;
  assign amo_wb_out      = amo_wb_r;

  // Load 字节选择 (WB 段组合, 4:1 直选避免 64 位桶形移位器)
`ifndef A_DIS
  wire [31:0] rdata_eff = amo_mode_r ? amo_wb_r : dmem_rdata;
`else
  wire [31:0] rdata_eff = dmem_rdata;
`endif

  wire [63:0] s0       = split_wb ? {rdata_eff, head_word_r} : {32'b0, rdata_eff};
  wire [31:0] wr_off0  = s0[31:0];
  wire [31:0] wr_off1  = {s0[39:32], s0[31:8]};
  wire [31:0] wr_off2  = {s0[47:40], s0[39:16]};
  wire [31:0] wr_off3  = {s0[55:48], s0[47:24]};
  wire [31:0] load_raw = (off_wb == 2'd0) ? wr_off0
                       : (off_wb == 2'd1) ? wr_off1
                       : (off_wb == 2'd2) ? wr_off2
                                          : wr_off3;

  always @(*) begin
    case (size_wb)
      `MEM_BYTE: load_data = uns_wb ? {24'b0, load_raw[7:0]}
                                    : {{24{load_raw[7]}}, load_raw[7:0]};
      `MEM_HALF: load_data = uns_wb ? {16'b0, load_raw[15:0]}
                                    : {{16{load_raw[15]}}, load_raw[15:0]};
      default:   load_data = load_raw;
    endcase
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state       <= S_IDLE;
      amo_active  <= 1'b0;
      amo_wait    <= 1'b0;
      amo_phase   <= 1'b0;
      amo_old     <= 32'd0;
      amo_wb_r    <= 32'd0;
      amo_addr_r  <= 32'd0;
      amo_mode_r  <= 1'b0;
      res_valid   <= 1'b0;
      res_addr    <= 30'd0;
      sc_ok_r     <= 1'b0;
      head_word_r <= 32'd0;
      off_wb      <= 2'd0;
      size_wb     <= `MEM_WORD;
      uns_wb      <= 1'b0;
      split_wb    <= 1'b0;
    end
    else if (req_cancel) begin
      // 更老指令在 WB 段发生访存异常: 清空在途状态机并撤消 LR/SC 预约
      state      <= S_IDLE;
      amo_active <= 1'b0;
      amo_wait   <= 1'b0;
      amo_phase  <= 1'b0;
      amo_mode_r <= 1'b0;
      res_valid  <= 1'b0;
    end
    else if (!dbus_stall) begin
      case (state)
        S_IDLE:  if (amo_en)           state <= S_AMO;
                 else if (needs_split) state <= S_HEAD;
        S_HEAD:  state <= S_TAIL;
        S_AMO:   state <= amo_phase ? S_IDLE : S_AMO;
        default: state <= S_IDLE;
      endcase

      if ((state == S_IDLE) && amo_en) begin
        amo_active <= 1'b1;
        amo_wait   <= 1'b1;
        amo_phase  <= 1'b0;
        amo_addr_r <= head_addr;
        if (res_clear) begin
          res_valid <= 1'b0;
        end
        else if (amo_lr) begin
          res_valid <= 1'b1;
          res_addr  <= head_addr[31:2];
        end
        else if (amo_sc) begin
          sc_ok_r   <= res_valid && (res_addr == head_addr[31:2]);
          res_valid <= 1'b0;
        end
      end
      else begin
        if (res_clear) res_valid <= 1'b0;
        if (state == S_AMO) begin
          if (amo_wait)        amo_wait   <= 1'b0;
          else if (!amo_phase) amo_phase  <= 1'b1;
          else                 amo_active <= 1'b0;
        end
      end

      if (state == S_HEAD)              head_word_r <= dmem_rdata;
      if ((state == S_AMO) && amo_wait) amo_old     <= dmem_rdata;

      // 仅在 AMO 真正离开 MEM 进入 WB 那一拍 (S_AMO && amo_phase) 锁存 WB 写回值，
      // 防止背靠背 LR.W -> SC.W 时后一条进入 MEM 破坏前一条在 WB 的读数。
      if ((state == S_AMO) && amo_phase) begin
        off_wb     <= 2'd0;
        size_wb    <= `MEM_WORD;
        uns_wb     <= 1'b0;
        split_wb   <= 1'b0;
        amo_mode_r <= 1'b1;
        amo_wb_r   <= amo_sc ? {31'b0, ~sc_ok_r} : amo_old;
      end
      else if (!lsu_fsm_stall) begin
        amo_mode_r <= 1'b0;
        if (req_read || req_write) begin
          off_wb   <= off;
          size_wb  <= req_size;
          uns_wb   <= req_unsigned;
          split_wb <= needs_split;
        end
      end
    end
    else begin
      // dbus_stall 冻结期仍需响应 Trap/MRET 清除 LR/SC 预约
      if (res_clear) res_valid <= 1'b0;
    end
  end

endmodule
