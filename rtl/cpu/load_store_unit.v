`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// load_store_unit.v — 访存单元 (字节通道 + 非对齐拆分 + RV32A 真预约)
// 纯 Verilog-2001；Trap/MRET 时通过 res_clear 清除 LR/SC 预约寄存器。
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

  // RV32A 原子指令接口
  input  wire        amo_en,
  input  wire [31:0] amo_newdata,
  input  wire        amo_lr,
  input  wire        amo_sc,
  input  wire        res_clear,

  // DMEM 接口 (寄存读: 第 N 拍送地址, 第 N+1 拍出数据)
  output wire [31:0] dmem_addr,
  output wire [31:0] dmem_wdata,
  output wire [3:0]  dmem_wstrb,
  output wire        dmem_we,
  input  wire [31:0] dmem_rdata,

  output reg  [31:0] load_data,
  output wire        lsu_stall,
  output wire        amo_write_phase,
  output wire [31:0] amo_old_out,
  output wire        amo_sc_ok
);

  localparam [1:0] S_IDLE = 2'd0, S_HEAD = 2'd1, S_TAIL = 2'd2, S_AMO = 2'd3;

  reg [1:0]  state;
  reg        amo_phase;       // 0=读相, 1=写相
  reg        amo_wait;        // 1=等待 dmem 寄存读出
  reg        amo_active;
  reg [31:0] amo_old;
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
  assign dmem_wstrb = (state == S_AMO)  ? ((amo_wr && !amo_no_write) ? 4'b1111 : 4'b0000)
                    : (req_write && (state != S_TAIL))
                      ? ((state == S_IDLE) ? head_strb : tail_strb) : 4'b0000;
  assign dmem_we    = (state == S_AMO)  ? (amo_wr && !amo_no_write)
                    : (req_write && (state != S_TAIL));

  assign lsu_stall       = (state == S_HEAD) ||
                           ((state == S_IDLE) && (needs_split || amo_en)) ||
                           ((state == S_AMO) && (amo_wait || !amo_phase));
  assign amo_write_phase = amo_wr;
  assign amo_old_out     = amo_old;
  assign amo_sc_ok       = sc_ok_r;

  // Load 字节选择 (WB 段组合, 4:1 直选避免 64 位桶形移位器)
`ifndef A_DIS
  wire [31:0] rdata_eff = (amo_mode_r && amo_sc) ? {31'b0, ~sc_ok_r}
                        : amo_mode_r             ? amo_old
                                                 : dmem_rdata;
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
    else begin
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

      if (state == S_HEAD)             head_word_r <= dmem_rdata;
      if ((state == S_AMO) && amo_wait) amo_old    <= dmem_rdata;

      if (amo_en) begin
        off_wb     <= 2'd0;
        size_wb    <= `MEM_WORD;
        uns_wb     <= 1'b0;
        split_wb   <= 1'b0;
        amo_mode_r <= 1'b1;
      end
      else begin
        amo_mode_r <= amo_active ? 1'b1 : 1'b0;
        if ((req_read || req_write) && !lsu_stall) begin
          off_wb   <= off;
          size_wb  <= req_size;
          uns_wb   <= req_unsigned;
          split_wb <= needs_split;
        end
      end
    end
  end

endmodule
