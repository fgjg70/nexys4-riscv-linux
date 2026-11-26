`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_units.v — 6 个 RTL 模块的单元回归测试 (自校验, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 覆盖: alu / imm_gen / branch_unit / control_unit / regfile / pc
// 其中 RV32A 部分:
//   alu          — 9 个 AMO 算符的"待写回值"计算, 含 min/max 的有符号/无符号边界
//   control_unit — OPC_AMO 译码: amo_en/amo_op/alu_op 映射/aq/rl/非法组合
// ============================================================================

module tb_units;
  localparam TCLK_HALF = 5;          // 100 MHz 等效时钟 (ns)
  localparam [31:0] RESET_PC = 32'h0000_0100;  // 故意用非零复位值, 抓接线错误

  reg clk;
  initial clk = 1'b0;
  always #(TCLK_HALF) clk = ~clk;

  integer errors;
  integer checks;
  integer i;

  // --------------------------------------------------------------------------
  // 检查任务
  // --------------------------------------------------------------------------
  task chk;
    input [31:0]     got;
    input [31:0]     exp;
    input [8*96-1:0] what;
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  [FAIL] %0s: got=%h exp=%h", what, got, exp);
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // 指令编码辅助函数 (仅按规范字段布局拼接, 与 RTL 无共享代码)
  // --------------------------------------------------------------------------
  function [31:0] enc_r;
    input [6:0] f7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] f3;
    input [4:0] rd;
    begin
      enc_r = {f7, rs2, rs1, f3, rd, 7'b0110011};
    end
  endfunction

  function [31:0] enc_i;
    input [11:0] imm;
    input [4:0]  rs1;
    input [2:0]  f3;
    input [4:0]  rd;
    input [6:0]  opc;
    begin
      enc_i = {imm, rs1, f3, rd, opc};
    end
  endfunction

  function [31:0] enc_s;
    input [11:0] imm;
    input [4:0]  rs2;
    input [4:0]  rs1;
    input [2:0]  f3;
    begin
      enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011};
    end
  endfunction

  function [31:0] enc_b;
    input [12:0] imm;
    input [4:0]  rs2;
    input [4:0]  rs1;
    input [2:0]  f3;
    begin
      enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
    end
  endfunction

  function [31:0] enc_u;
    input [19:0] imm20;
    input [4:0]  rd;
    input [6:0]  opc;
    begin
      enc_u = {imm20, rd, opc};
    end
  endfunction

  function [31:0] enc_j;
    input [20:0] imm;
    input [4:0]  rd;
    begin
      enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    end
  endfunction

  // --------------------------------------------------------------------------
  // DUT: ALU
  // --------------------------------------------------------------------------
  reg  [31:0] alu_a, alu_b;
  reg  [4:0]  alu_op;
  wire [31:0] alu_out;

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .out(alu_out));

  // --------------------------------------------------------------------------
  // DUT: imm_gen
  // --------------------------------------------------------------------------
  reg  [31:0] ig_instr;
  reg  [2:0]  ig_fmt;
  wire [31:0] ig_imm;

  imm_gen u_ig (.instr(ig_instr), .fmt(ig_fmt), .imm_out(ig_imm));

  // --------------------------------------------------------------------------
  // DUT: branch_unit
  // --------------------------------------------------------------------------
  reg  [31:0] bu_rs1, bu_rs2;
  reg  [2:0]  bu_type;
  wire        bu_taken;

  branch_unit u_bu (
    .rs1(bu_rs1), .rs2(bu_rs2),
    .branch_type(bu_type), .taken(bu_taken)
  );

  // --------------------------------------------------------------------------
  // DUT: control_unit
  // --------------------------------------------------------------------------
  reg  [31:0]        cu_instr;
  wire [`CTRL_W-1:0] cu_ctrl;

  control_unit u_cu (.instr(cu_instr), .ctrl(cu_ctrl));

  // --------------------------------------------------------------------------
  // DUT: regfile
  // --------------------------------------------------------------------------
  reg         rf_we;
  reg  [4:0]  rf_waddr, rf_raddr1, rf_raddr2;
  reg  [31:0] rf_wdata;
  wire [31:0] rf_rdata1, rf_rdata2;

  regfile u_rf (
    .clk(clk),
    .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
    .raddr1(rf_raddr1), .raddr2(rf_raddr2),
    .rdata1(rf_rdata1), .rdata2(rf_rdata2),
    .dbg_raddr(5'd0), .dbg_rdata()
  );

  // --------------------------------------------------------------------------
  // DUT: pc
  // --------------------------------------------------------------------------
  reg         pc_rst, pc_stall, pc_flush, pc_src;
  reg  [31:0] pc_flush_pc, pc_target;
  wire [31:0] pc_pc, pc_plus4;

  pc #(.RESET_PC(RESET_PC)) u_pc (
    .clk(clk), .rst(pc_rst),
    .stall(pc_stall), .flush(pc_flush), .flush_pc(pc_flush_pc),
    .pc_src(pc_src), .pc_target(pc_target),
    .pc(pc_pc), .pc_plus4(pc_plus4)
  );

  // ==========================================================================
  // 测试主体
  // ==========================================================================
  initial begin
    errors = 0;
    checks = 0;

    // ------------------------------------------------------------------
    $display("[1/6] ALU ...");
    // 加减法 (含边界)
    alu_op = `ALU_ADD; alu_a = 32'd1;          alu_b = 32'd2;          #1; chk(alu_out, 32'd3,          "ADD 1+2");
    alu_a = 32'hFFFFFFFF;                      alu_b = 32'd1;          #1; chk(alu_out, 32'd0,          "ADD -1+1");
    alu_a = 32'h7FFFFFFF;                      alu_b = 32'd1;          #1; chk(alu_out, 32'h80000000,   "ADD max+1");
    alu_op = `ALU_SUB; alu_a = 32'd5;          alu_b = 32'd3;          #1; chk(alu_out, 32'd2,          "SUB 5-3");
    alu_a = 32'd3;                             alu_b = 32'd5;          #1; chk(alu_out, 32'hFFFFFFFE,   "SUB 3-5");
    // 逻辑
    alu_op = `ALU_AND; alu_a = 32'hF0F0F0F0;   alu_b = 32'h0FF00FF0;   #1; chk(alu_out, 32'h00F000F0,   "AND");
    alu_op = `ALU_OR;  alu_a = 32'hF0F0F0F0;   alu_b = 32'h0F0F0F0F;   #1; chk(alu_out, 32'hFFFFFFFF,   "OR");
    alu_op = `ALU_XOR; alu_a = 32'hAAAA5555;   alu_b = 32'hAAAA55AA;   #1; chk(alu_out, 32'h000000FF,   "XOR");
    // 移位 (含 0/31/超宽移位量)
    alu_op = `ALU_SLL; alu_a = 32'd1;          alu_b = 32'd31;         #1; chk(alu_out, 32'h80000000,   "SLL 1<<31");
                       alu_a = 32'hDEADBEEF;   alu_b = 32'd4;          #1; chk(alu_out, 32'hEADBEEF0,   "SLL <<4");
                       alu_a = 32'h12345678;   alu_b = 32'd0;          #1; chk(alu_out, 32'h12345678,   "SLL <<0");
                       alu_a = 32'd1;          alu_b = 32'd32;         #1; chk(alu_out, 32'd1,          "SLL <<32(高位忽略)");
    alu_op = `ALU_SRL; alu_a = 32'h80000000;   alu_b = 32'd31;         #1; chk(alu_out, 32'd1,          "SRL >>31");
                       alu_a = 32'hFFFFFFFF;   alu_b = 32'd4;          #1; chk(alu_out, 32'h0FFFFFFF,   "SRL -1>>4");
    alu_op = `ALU_SRA; alu_a = 32'h80000000;   alu_b = 32'd31;         #1; chk(alu_out, 32'hFFFFFFFF,   "SRA min>>31");
                       alu_a = 32'hFFFFFFFF;   alu_b = 32'd4;          #1; chk(alu_out, 32'hFFFFFFFF,   "SRA -1>>4");
                       alu_a = 32'h7FFFFFFF;   alu_b = 32'd4;          #1; chk(alu_out, 32'h07FFFFFF,   "SRA max>>4");
                       alu_a = 32'h80000000;   alu_b = 32'd1;          #1; chk(alu_out, 32'hC0000000,   "SRA min>>1");
    // 比较 (有符号/无符号边界)
    alu_op = `ALU_SLT;  alu_a = 32'hFFFFFFFF;  alu_b = 32'd0;          #1; chk(alu_out, 32'd1,          "SLT -1<0");
                        alu_a = 32'd0;         alu_b = 32'hFFFFFFFF;   #1; chk(alu_out, 32'd0,          "SLT 0<-1");
                        alu_a = 32'h80000000;  alu_b = 32'h7FFFFFFF;   #1; chk(alu_out, 32'd1,          "SLT min<max");
    alu_op = `ALU_SLTU; alu_a = 32'hFFFFFFFF;  alu_b = 32'd0;          #1; chk(alu_out, 32'd0,          "SLTU max<u 0");
                        alu_a = 32'd0;         alu_b = 32'hFFFFFFFF;   #1; chk(alu_out, 32'd1,          "SLTU 0<u max");
                        alu_a = 32'h80000000;  alu_b = 32'h7FFFFFFF;   #1; chk(alu_out, 32'd0,          "SLTU 0x8.. <u 0x7..");
    // RV32M: M 算符由 muldiv 负责, ALU 对其输出 0
    alu_op = `ALU_MUL;  alu_a = 32'd7;         alu_b = 32'd6;          #1; chk(alu_out, 32'd0,          "MUL -> ALU 输出 0");
    alu_op = `ALU_DIV;                                                 #1; chk(alu_out, 32'd0,          "DIV -> ALU 输出 0");

    // RV32A 原子指令待写回值计算 (a=旧值, b=rs2)
    alu_op = `ALU_AMO_SWAP; alu_a = 32'hDEADBEEF; alu_b = 32'h12345678; #1; chk(alu_out, 32'h12345678, "AMO_SWAP 新值=rs2");
    alu_op = `ALU_AMO_ADD;  alu_a = 32'd100;      alu_b = 32'd23;       #1; chk(alu_out, 32'd123,      "AMO_ADD 100+23");
    alu_op = `ALU_AMO_XOR;  alu_a = 32'hAAAA5555; alu_b = 32'hAAAA55AA; #1; chk(alu_out, 32'h000000FF, "AMO_XOR");
    alu_op = `ALU_AMO_AND;  alu_a = 32'hF0F0F0F0; alu_b = 32'h0FF00FF0; #1; chk(alu_out, 32'h00F000F0, "AMO_AND");
    alu_op = `ALU_AMO_OR;   alu_a = 32'hF0F0F0F0; alu_b = 32'h0F0F0F0F; #1; chk(alu_out, 32'hFFFFFFFF, "AMO_OR");
    alu_op = `ALU_AMO_MIN;  alu_a = 32'hFFFFFFFF; alu_b = 32'd1;        #1; chk(alu_out, 32'hFFFFFFFF, "AMO_MIN -1<1 -> -1");
    alu_op = `ALU_AMO_MAX;  alu_a = 32'hFFFFFFFF; alu_b = 32'd1;        #1; chk(alu_out, 32'd1,        "AMO_MAX -1<1 -> 1");
    alu_op = `ALU_AMO_MINU; alu_a = 32'hFFFFFFFF; alu_b = 32'd1;        #1; chk(alu_out, 32'd1,        "AMO_MINU max>1 -> 1");
    alu_op = `ALU_AMO_MAXU; alu_a = 32'hFFFFFFFF; alu_b = 32'd1;        #1; chk(alu_out, 32'hFFFFFFFF, "AMO_MAXU max>1 -> max");
    alu_op = `ALU_AMO_MIN;  alu_a = 32'h80000000; alu_b = 32'h7FFFFFFF; #1; chk(alu_out, 32'h80000000, "AMO_MIN min<max -> min");
    alu_op = `ALU_AMO_MAX;  alu_a = 32'h80000000; alu_b = 32'h7FFFFFFF; #1; chk(alu_out, 32'h7FFFFFFF, "AMO_MAX min<max -> max");
    alu_op = `ALU_AMO_MINU; alu_a = 32'h80000000; alu_b = 32'h7FFFFFFF; #1; chk(alu_out, 32'h7FFFFFFF, "AMO_MINU 0x8..>u0x7..");
    alu_op = `ALU_AMO_MAXU; alu_a = 32'h80000000; alu_b = 32'h7FFFFFFF; #1; chk(alu_out, 32'h80000000, "AMO_MAXU -> 0x8..");

    // ------------------------------------------------------------------
    $display("[2/6] imm_gen ...");
    // 黄金向量 (独立手推)
    ig_instr = 32'h00000013; ig_fmt = `IMM_I; #1; chk(ig_imm, 32'h00000000, "golden NOP imm");
    ig_instr = 32'hFFF00093; ig_fmt = `IMM_I; #1; chk(ig_imm, 32'hFFFFFFFF, "golden addi x1,x0,-1");
    ig_instr = 32'hDEADB2B7; ig_fmt = `IMM_U; #1; chk(ig_imm, 32'hDEADB000, "golden lui x5,0xDEADB");
    ig_instr = 32'h008000EF; ig_fmt = `IMM_J; #1; chk(ig_imm, 32'h00000008, "golden jal x1,+8");
    ig_instr = 32'hFE208EE3; ig_fmt = `IMM_B; #1; chk(ig_imm, 32'hFFFFFFFC, "golden beq x1,x2,-4");
    // 字段构造向量
    ig_instr = enc_i(12'h7FF, 5'd3, 3'b000, 5'd1, `OPC_OPIMM); ig_fmt = `IMM_I; #1; chk(ig_imm, 32'h000007FF, "I max pos");
    ig_instr = enc_s(12'hFFC, 5'd5, 5'd2, 3'b010);             ig_fmt = `IMM_S; #1; chk(ig_imm, 32'hFFFFFFFC, "S -4");
    ig_instr = enc_s(12'h800, 5'd5, 5'd2, 3'b000);             ig_fmt = `IMM_S; #1; chk(ig_imm, 32'hFFFFF800, "S min neg");
    ig_instr = enc_b(13'd16,  5'd1, 5'd2, 3'b000);             ig_fmt = `IMM_B; #1; chk(ig_imm, 32'h00000010, "B +16");
    ig_instr = enc_b(13'h1FF0, 5'd1, 5'd2, 3'b001);            ig_fmt = `IMM_B; #1; chk(ig_imm, 32'hFFFFFFF0, "B -16");
    ig_instr = enc_j(21'd1024, 5'd1);                          ig_fmt = `IMM_J; #1; chk(ig_imm, 32'h00000400, "J +1024");
    ig_instr = enc_j(21'h100000, 5'd1);                        ig_fmt = `IMM_J; #1; chk(ig_imm, 32'hFFF00000, "J neg");
    ig_instr = enc_u(20'h12345, 5'd5, `OPC_LUI);               ig_fmt = `IMM_U; #1; chk(ig_imm, 32'h12345000, "U");

    // ------------------------------------------------------------------
    $display("[3/6] branch_unit ...");
    bu_rs1 = 32'd5; bu_rs2 = 32'd5;
    bu_type = `BR_EQ;  #1; chk({31'd0, bu_taken}, 32'd1, "EQ  5,5");
    bu_type = `BR_NE;  #1; chk({31'd0, bu_taken}, 32'd0, "NE  5,5");
    bu_rs1 = 32'd5; bu_rs2 = 32'd6;
    bu_type = `BR_EQ;  #1; chk({31'd0, bu_taken}, 32'd0, "EQ  5,6");
    bu_type = `BR_NE;  #1; chk({31'd0, bu_taken}, 32'd1, "NE  5,6");
    bu_rs1 = 32'hFFFFFFFF; bu_rs2 = 32'd1;
    bu_type = `BR_LT;  #1; chk({31'd0, bu_taken}, 32'd1, "LT  -1,1");
    bu_type = `BR_GE;  #1; chk({31'd0, bu_taken}, 32'd0, "GE  -1,1");
    bu_type = `BR_LTU; #1; chk({31'd0, bu_taken}, 32'd0, "LTU max,1");
    bu_type = `BR_GEU; #1; chk({31'd0, bu_taken}, 32'd1, "GEU max,1");
    bu_rs1 = 32'h80000000; bu_rs2 = 32'h7FFFFFFF;
    bu_type = `BR_LT;  #1; chk({31'd0, bu_taken}, 32'd1, "LT  min,max");
    bu_type = `BR_LTU; #1; chk({31'd0, bu_taken}, 32'd0, "LTU 0x8..,0x7..");

    // ------------------------------------------------------------------
    $display("[4/6] control_unit ...");
    // NOP: addi x0,x0,0
    cu_instr = 32'h00000013; #1;
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]}, 32'd1,              "NOP reg_write");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_ADD},  "NOP alu_op");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]}, {31'd0, `ALU_B_IMM},"NOP alu_b_src");
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},    {30'd0, `PC_NEXT},  "NOP pc_sel");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},    {30'd0, `WB_ALU},   "NOP wb_src");

    // R 型
    cu_instr = enc_r(`F7_ZERO, 5'd3, 5'd2, 3'b000, 5'd1); #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_ADD},  "ADD alu_op");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]}, {31'd0, `ALU_B_RS2},"ADD alu_b_src");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]}, 32'd1,              "ADD reg_write");
    cu_instr = enc_r(`F7_ALT, 5'd3, 5'd2, 3'b000, 5'd1); #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_SUB},  "SUB alu_op");
    cu_instr = enc_r(`F7_ALT, 5'd3, 5'd2, 3'b101, 5'd1); #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_SRA},  "SRA alu_op");
    cu_instr = enc_r(7'b0000010, 5'd3, 5'd2, 3'b000, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd1,              "R bad funct7 illegal");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]}, 32'd0,              "illegal R 不写寄存器");

    // RV32M
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b000, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "MUL 合法");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]}, 32'd1,              "MUL 写寄存器");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_MUL},  "MUL -> ALU_MUL");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b001, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "MULH 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_MULH}, "MULH -> ALU_MULH");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b010, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "MULHSU 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_MULHSU},"MULHSU -> ALU_MULHSU");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b011, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "MULHU 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_MULHU},"MULHU -> ALU_MULHU");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b100, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "DIV 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_DIV},  "DIV -> ALU_DIV");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b101, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "DIVU 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_DIVU}, "DIVU -> ALU_DIVU");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b110, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "REM 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_REM},  "REM -> ALU_REM");
    cu_instr = enc_r(`F7_MULDIV, 5'd3, 5'd2, 3'b111, 5'd1); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd0,              "REMU 合法");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_REMU}, "REMU -> ALU_REMU");

    // I 型
    cu_instr = enc_i(12'hFF4, 5'd2, 3'b000, 5'd1, `OPC_OPIMM); #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_ADD},  "ADDI alu_op");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]}, {31'd0, `ALU_B_IMM},"ADDI alu_b_src");
    cu_instr = enc_i(12'h401, 5'd2, 3'b101, 5'd1, `OPC_OPIMM); #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},    {27'd0, `ALU_SRA},  "SRAI alu_op");
    cu_instr = enc_i(12'h401, 5'd2, 3'b001, 5'd1, `OPC_OPIMM); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},   32'd1,              "SLLI bad funct7 illegal");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]}, 32'd0,              "illegal I 不写寄存器");

    // LOAD
    cu_instr = enc_i(12'hFF4, 5'd2, 3'b000, 5'd3, `OPC_LOAD); #1;
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_I},    "LB imm_fmt");
    chk({30'd0, cu_ctrl[`CTRL_MEM_SIZE]},    {30'd0, `MEM_BYTE}, "LB mem_size");
    chk({31'd0, cu_ctrl[`CTRL_MEM_READ]},    32'd1,              "LB mem_read");
    chk({31'd0, cu_ctrl[`CTRL_MEM_UNSIGNED]},32'd0,              "LB mem_unsigned");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_MEM},   "LB wb_src");
    cu_instr = enc_i(12'd4, 5'd2, 3'b101, 5'd3, `OPC_LOAD); #1;
    chk({30'd0, cu_ctrl[`CTRL_MEM_SIZE]},    {30'd0, `MEM_HALF}, "LHU mem_size");
    chk({31'd0, cu_ctrl[`CTRL_MEM_UNSIGNED]},32'd1,              "LHU mem_unsigned");
    cu_instr = enc_i(12'd4, 5'd2, 3'b010, 5'd3, `OPC_LOAD); #1;
    chk({30'd0, cu_ctrl[`CTRL_MEM_SIZE]},    {30'd0, `MEM_WORD}, "LW mem_size");
    cu_instr = enc_i(12'd4, 5'd2, 3'b011, 5'd3, `OPC_LOAD); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,              "LW f3=011 illegal");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd0,              "illegal load 不写寄存器");
    chk({31'd0, cu_ctrl[`CTRL_MEM_READ]},    32'd0,              "illegal load 不读存储器");

    // 锁存器回归
    cu_instr = enc_i(12'hFFC, 5'd2, 3'b101, 5'd3, `OPC_LOAD); #1;
    cu_instr = enc_i(12'd1, 5'd2, 3'b000, 5'd1, `OPC_OPIMM); #1;
    chk({31'd0, cu_ctrl[`CTRL_MEM_UNSIGNED]},32'd0,              "ADDI mem_unsigned 回默认");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_ALU},   "ADDI wb_src");

    // STORE
    cu_instr = enc_i(12'd4, 5'd2, 3'b010, 5'd3, `OPC_LOAD); #1;
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b000); #1;
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_ALU},   "SB wb_src 回默认");
    chk({31'd0, cu_ctrl[`CTRL_MEM_WRITE]},   32'd1,              "SB mem_write");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd0,              "SB reg_write");
    chk({30'd0, cu_ctrl[`CTRL_MEM_SIZE]},    {30'd0, `MEM_BYTE}, "SB mem_size");
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_S},    "SB imm_fmt");
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b010); #1;
    chk({30'd0, cu_ctrl[`CTRL_MEM_SIZE]},    {30'd0, `MEM_WORD}, "SW mem_size");
    cu_instr = enc_s(12'd8, 5'd4, 5'd2, 3'b100); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,              "SB f3=100 illegal");
    chk({31'd0, cu_ctrl[`CTRL_MEM_WRITE]},   32'd0,              "illegal store 不写存储器");

    // 分支
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b000); #1;
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_BR},    "BEQ pc_sel");
    chk({29'd0, cu_ctrl[`CTRL_BRANCH_TYPE]}, {29'd0, `BR_EQ},    "BEQ branch_type");
    chk({30'd0, cu_ctrl[`CTRL_ALU_A_SRC]},   {30'd0, `ALU_A_PC}, "BEQ alu_a_src");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]},   {31'd0, `ALU_B_IMM},"BEQ alu_b_src");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},      {27'd0, `ALU_ADD},  "BEQ alu_op");
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_B},    "BEQ imm_fmt");
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b111); #1;
    chk({29'd0, cu_ctrl[`CTRL_BRANCH_TYPE]}, {29'd0, `BR_GEU},   "BGEU branch_type");
    cu_instr = enc_b(13'd8, 5'd2, 5'd1, 3'b010); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,              "BR f3=010 illegal");
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_NEXT},  "illegal branch 不跳转");

    // LUI / AUIPC / JAL / JALR
    cu_instr = enc_u(20'hDEADB, 5'd5, `OPC_LUI); #1;
    chk({30'd0, cu_ctrl[`CTRL_ALU_A_SRC]},   {30'd0, `ALU_A_ZERO},"LUI alu_a_src");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]},   {31'd0, `ALU_B_IMM}, "LUI alu_b_src");
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_U},     "LUI imm_fmt");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd1,               "LUI reg_write");

    cu_instr = enc_u(20'h00001, 5'd6, `OPC_AUIPC); #1;
    chk({30'd0, cu_ctrl[`CTRL_ALU_A_SRC]},   {30'd0, `ALU_A_PC},  "AUIPC alu_a_src");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},      {27'd0, `ALU_ADD},   "AUIPC alu_op");

    cu_instr = enc_j(21'd16, 5'd1); #1;
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_J},      "JAL pc_sel");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_PC4},    "JAL wb_src");
    chk({30'd0, cu_ctrl[`CTRL_ALU_A_SRC]},   {30'd0, `ALU_A_PC},  "JAL alu_a_src");
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_J},     "JAL imm_fmt");

    cu_instr = enc_i(12'd4, 5'd3, 3'b000, 5'd1, `OPC_JALR); #1;
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_JR},     "JALR pc_sel");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_PC4},    "JALR wb_src");
    chk({30'd0, cu_ctrl[`CTRL_ALU_A_SRC]},   {30'd0, `ALU_A_RS1}, "JALR alu_a_src");
    chk({31'd0, cu_ctrl[`CTRL_ALU_B_SRC]},   {31'd0, `ALU_B_IMM}, "JALR alu_b_src");
    chk({29'd0, cu_ctrl[`CTRL_IMM_FMT]},     {29'd0, `IMM_I},     "JALR imm_fmt");
    cu_instr = enc_i(12'd4, 5'd3, 3'b001, 5'd1, `OPC_JALR); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "JALR f3=001 illegal");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd0,               "illegal jalr 不写寄存器");
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_NEXT},   "illegal jalr 不跳转");

    // SYSTEM / Zicsr
    cu_instr = {25'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "ECALL 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_ECALL}, "ECALL sys_op");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd0,               "ECALL 不写寄存器");
    cu_instr = {12'h001, 5'd0, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "EBREAK 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_EBREAK},"EBREAK sys_op");
    cu_instr = {12'h102, 5'd0, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "SRET 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_SRET},  "SRET sys_op");
    cu_instr = {12'h302, 5'd0, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "MRET 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_MRET},  "MRET sys_op");
    cu_instr = {7'b0001001, 5'd2, 5'd1, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "SFENCE.VMA 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_SFENCE},"SFENCE.VMA sys_op");
    cu_instr = {7'b0001001, 5'd0, 5'd0, 3'b000, 5'd1, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "SFENCE.VMA rd!=0 非法");
    cu_instr = {12'h223, 5'd0, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "SYSTEM f3=000 未知 imm illegal");
    cu_instr = {12'h300, 5'd0, 3'b100, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "SYSTEM f3=100 illegal");

    cu_instr = enc_i(12'h300, 5'd2, 3'b001, 5'd5, 7'b1110011); #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "CSRRW 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_CSR},   "CSRRW sys_op");
    chk({20'd0, cu_ctrl[`CTRL_CSR_ADDR]},    32'h300,             "CSRRW csr_addr");
    chk({30'd0, cu_ctrl[`CTRL_CSR_CMD]},     32'd1,               "CSRRW csr_cmd = W");
    chk({31'd0, cu_ctrl[`CTRL_CSR_SRC_IMM]}, 32'd0,               "CSRRW 源取 rs1");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd1,               "CSRRW 写回旧值");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_CSR},    "CSRRW wb_src = WB_CSR");

    cu_instr = enc_i(12'h305, 5'd2, 3'b010, 5'd5, 7'b1110011); #1;
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_CSR},   "CSRRS sys_op");
    chk({30'd0, cu_ctrl[`CTRL_CSR_CMD]},     32'd2,               "CSRRS csr_cmd = S");

    cu_instr = {12'h340, 5'd17, 3'b101, 5'd6, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_CSR_SRC_IMM]}, 32'd1,               "CSRRWI 源取 uimm");
    chk({27'd0, cu_ctrl[`CTRL_CSR_UIMM]},    32'd17,              "CSRRWI csr_uimm");

    // FENCE / FENCE.I / WFI
    cu_instr = {25'd0, 7'b0001111}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "FENCE 合法 (NOP)");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd0,               "FENCE 不写寄存器");
    chk({30'd0, cu_ctrl[`CTRL_PC_SEL]},      {30'd0, `PC_NEXT},   "FENCE 不跳转");
    cu_instr = {12'd0, 5'd0, 3'b001, 5'd0, 7'b0001111}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "FENCE.I 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_FENCEI},"FENCE.I sys_op");
    cu_instr = {12'd0, 5'd0, 3'b010, 5'd0, 7'b0001111}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "FENCE f3=010 非法");
    cu_instr = {12'h105, 5'd0, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,               "WFI 合法");
    chk({28'd0, cu_ctrl[`CTRL_SYS_OP]},      {28'd0, `SYS_WFI},   "WFI sys_op");
    cu_instr = {12'h000, 5'd1, 3'b000, 5'd0, 7'b1110011}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd1,               "ECALL rs1!=0 非法");

    // RV32A
`ifndef A_DIS
    cu_instr = {`AMO_ADD, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]},     32'd0,                 "AMOADD 合法");
    chk({31'd0, cu_ctrl[`CTRL_AMO_EN]},      32'd1,                 "AMOADD amo_en=1");
    chk({27'd0, cu_ctrl[`CTRL_AMO_OP]},      {27'd0, `AMO_ADD},     "AMOADD amo_op");
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]},      {27'd0, `ALU_AMO_ADD}, "AMOADD alu_op");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},      {30'd0, `WB_MEM},      "AMOADD rd<-旧值(WB_MEM)");
    chk({31'd0, cu_ctrl[`CTRL_REG_WRITE]},   32'd1,                 "AMOADD 写回使能");

    cu_instr = {`AMO_SWAP, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_SWAP}, "AMOSWAP alu_op");
    cu_instr = {`AMO_XOR,  2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_XOR},  "AMOXOR alu_op");
    cu_instr = {`AMO_AND,  2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_AND},  "AMOAND alu_op");
    cu_instr = {`AMO_OR,   2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_OR},   "AMOOR alu_op");
    cu_instr = {`AMO_MIN,  2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_MIN},  "AMOMIN alu_op");
    cu_instr = {`AMO_MAX,  2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_MAX},  "AMOMAX alu_op");
    cu_instr = {`AMO_MINU, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_MINU}, "AMOMINU alu_op");
    cu_instr = {`AMO_MAXU, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({27'd0, cu_ctrl[`CTRL_ALU_OP]}, {27'd0, `ALU_AMO_MAXU}, "AMOMAXU alu_op");

    cu_instr = {`AMO_LR, 2'b00, 5'd0, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd0,            "LR.W 合法");
    chk({31'd0, cu_ctrl[`CTRL_AMO_EN]},  32'd1,            "LR.W amo_en=1");
    chk({27'd0, cu_ctrl[`CTRL_AMO_OP]},  {27'd0, `AMO_LR}, "LR.W amo_op");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},  {30'd0, `WB_MEM}, "LR.W rd<-读到的值");
    cu_instr = {`AMO_SC, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd0,            "SC.W 合法");
    chk({31'd0, cu_ctrl[`CTRL_AMO_EN]},  32'd1,            "SC.W amo_en=1");
    chk({30'd0, cu_ctrl[`CTRL_WB_SRC]},  {30'd0, `WB_MEM}, "SC.W rd<-成功标志");

    cu_instr = {`AMO_ADD, 2'b11, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_AMO_AQ]},  32'd1, "AMO aq 位译码");
    chk({31'd0, cu_ctrl[`CTRL_AMO_RL]},  32'd1, "AMO rl 位译码");
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd0, "AMO aq=rl=1 仍合法");

    cu_instr = {`AMO_ADD, 2'b00, 5'd2, 5'd3, 3'b011, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd1, "AMO funct3=011 非法");
    cu_instr = {5'b11111, 2'b00, 5'd2, 5'd3, 3'b010, 5'd1, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd1, "AMO funct5=11111 非法");
`else
    cu_instr = {25'd0, `OPC_AMO}; #1;
    chk({31'd0, cu_ctrl[`CTRL_ILLEGAL]}, 32'd1, "A_DIS 开: OPC_AMO 非法");
`endif

    // ------------------------------------------------------------------
    $display("[5/6] regfile ...");
    rf_we = 1'b0;
    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd0; rf_wdata = 32'hDEADBEEF;
    @(negedge clk);
    rf_we = 1'b0; rf_raddr1 = 5'd0; rf_raddr2 = 5'd0; #1;
    chk(rf_rdata1, 32'd0, "x0 读恒零");
    chk(rf_rdata2, 32'd0, "x0 写被忽略");

    for (i = 1; i < 32; i = i + 1) begin
      @(negedge clk);
      rf_we = 1'b1; rf_waddr = i[4:0]; rf_wdata = i * 32'h01010101;
    end
    @(negedge clk);
    rf_we = 1'b0;
    for (i = 1; i < 32; i = i + 1) begin
      rf_raddr1 = i[4:0]; rf_raddr2 = 32 - i; #1;
      chk(rf_rdata1, i * 32'h01010101, "写读回端口1");
      chk(rf_rdata2, (32 - i) * 32'h01010101, "写读回端口2");
    end

    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd5; rf_wdata = 32'hCAFEBABE;
    @(negedge clk);
    rf_we = 1'b0; rf_raddr1 = 5'd5; #1;
    chk(rf_rdata1, 32'hCAFEBABE, "覆盖写生效");

    rf_raddr1 = 5'd7;
    @(negedge clk);
    rf_we = 1'b1; rf_waddr = 5'd7; rf_wdata = 32'h77777777;
    @(posedge clk);
    #1;
    rf_we = 1'b0;
    chk(rf_rdata1, 32'h77777777, "写穿透 (async read)");

    // ------------------------------------------------------------------
    $display("[6/6] pc ...");
    pc_stall = 1'b0; pc_flush = 1'b0; pc_src = 1'b0;
    pc_target = 32'd0; pc_flush_pc = 32'd0;
    pc_rst = 1'b1; #1;
    chk(pc_pc, RESET_PC, "复位到 RESET_PC");
    chk(pc_plus4, RESET_PC + 32'd4, "pc_plus4");
    pc_rst = 1'b0;
    @(posedge clk); #1; chk(pc_pc, RESET_PC + 32'd4,  "顺序 +4 (1)");
    @(posedge clk); #1; chk(pc_pc, RESET_PC + 32'd8,  "顺序 +4 (2)");
    pc_src = 1'b1; pc_target = 32'h0000_0200;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "跳转到 target");
    pc_src = 1'b0; pc_stall = 1'b1;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "stall 保持");
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0200, "stall 保持 (2)");
    pc_flush = 1'b1; pc_flush_pc = 32'h0000_0300;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0300, "flush 优先于 stall");
    pc_flush = 1'b0; pc_stall = 1'b0;
    @(posedge clk); #1; chk(pc_pc, 32'h0000_0304, "恢复顺序执行");

    // ------------------------------------------------------------------
    $display("=================================================");
    $display("  检查点: %0d", checks);
    $display("  错误数: %0d", errors);
    if (errors == 0) begin
      $display("  RESULT : PASS");
      $finish;
    end else begin
      $display("  RESULT : FAIL");
      $finish;
    end
  end

endmodule
