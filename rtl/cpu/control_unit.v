`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// control_unit.v — RV32IMA + Zicsr + Zifencei + WFI 主译码器（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 默认开启 RV32A (定义 A_DIS 可关闭)。全部字段经 rv32_defs.vh 命名位片访问。
// Stage 1A 升级: 区分 FENCE (f3=000) / FENCE.I (f3=001)，新增 WFI (12'h105)，
// 对 ECALL/EBREAK/MRET/WFI 严格校验 rs1=0 且 rd=0。
// ============================================================================

module control_unit #(
  parameter XLEN = 32
)(
  input  wire [XLEN-1:0]    instr,
  output reg  [`CTRL_W-1:0] ctrl
);

  wire [6:0] opcode = instr[6:0];
  wire [2:0] funct3 = instr[14:12];
  wire [6:0] funct7 = instr[31:25];
  wire [4:0] rs1    = instr[19:15];
  wire [4:0] rd     = instr[11:7];

  reg illegal;

  always @(*) begin
    ctrl    = `CTRL_NOP;
    illegal = 1'b0;

    case (opcode)
      // ------------------------------------------------------------------
      // R 型: RV32I + RV32M
      // ------------------------------------------------------------------
      `OPC_OP: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_RS2;
        ctrl[`CTRL_WB_SRC]    = `WB_ALU;
        case (funct3)
          3'b000: begin
            case (funct7)
              `F7_ZERO:   ctrl[`CTRL_ALU_OP] = `ALU_ADD;
              `F7_ALT:    ctrl[`CTRL_ALU_OP] = `ALU_SUB;
              `F7_MULDIV: ctrl[`CTRL_ALU_OP] = `ALU_MUL;
              default:    illegal = 1'b1;
            endcase
          end
          3'b001: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_MULH;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_SLL; illegal = (funct7 != `F7_ZERO); end
          end
          3'b010: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_MULHSU;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_SLT; illegal = (funct7 != `F7_ZERO); end
          end
          3'b011: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_MULHU;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_SLTU; illegal = (funct7 != `F7_ZERO); end
          end
          3'b100: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_DIV;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_XOR; illegal = (funct7 != `F7_ZERO); end
          end
          3'b101: begin
            case (funct7)
              `F7_ZERO:   ctrl[`CTRL_ALU_OP] = `ALU_SRL;
              `F7_ALT:    ctrl[`CTRL_ALU_OP] = `ALU_SRA;
              `F7_MULDIV: ctrl[`CTRL_ALU_OP] = `ALU_DIVU;
              default:    illegal = 1'b1;
            endcase
          end
          3'b110: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_REM;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_OR; illegal = (funct7 != `F7_ZERO); end
          end
          3'b111: begin
            if (funct7 == `F7_MULDIV) ctrl[`CTRL_ALU_OP] = `ALU_REMU;
            else begin ctrl[`CTRL_ALU_OP] = `ALU_AND; illegal = (funct7 != `F7_ZERO); end
          end
        endcase
      end

      // ------------------------------------------------------------------
      // I 型算术
      // ------------------------------------------------------------------
      `OPC_OPIMM: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_I;
        ctrl[`CTRL_WB_SRC]    = `WB_ALU;
        case (funct3)
          3'b000: ctrl[`CTRL_ALU_OP] = `ALU_ADD;
          3'b010: ctrl[`CTRL_ALU_OP] = `ALU_SLT;
          3'b011: ctrl[`CTRL_ALU_OP] = `ALU_SLTU;
          3'b100: ctrl[`CTRL_ALU_OP] = `ALU_XOR;
          3'b110: ctrl[`CTRL_ALU_OP] = `ALU_OR;
          3'b111: ctrl[`CTRL_ALU_OP] = `ALU_AND;
          3'b001: begin
            ctrl[`CTRL_ALU_OP] = `ALU_SLL;
            illegal = (funct7 != `F7_ZERO);
          end
          3'b101: begin
            case (funct7)
              `F7_ZERO: ctrl[`CTRL_ALU_OP] = `ALU_SRL;
              `F7_ALT:  ctrl[`CTRL_ALU_OP] = `ALU_SRA;
              default:  illegal = 1'b1;
            endcase
          end
        endcase
      end

      // ------------------------------------------------------------------
      // LOAD: LB/LH/LW/LBU/LHU
      // ------------------------------------------------------------------
      `OPC_LOAD: begin
        ctrl[`CTRL_REG_WRITE]    = 1'b1;
        ctrl[`CTRL_MEM_READ]     = 1'b1;
        ctrl[`CTRL_ALU_B_SRC]    = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]      = `IMM_I;
        ctrl[`CTRL_WB_SRC]       = `WB_MEM;
        ctrl[`CTRL_MEM_UNSIGNED] = 1'b0;
        case (funct3)
          3'b000: ctrl[`CTRL_MEM_SIZE] = `MEM_BYTE;
          3'b001: ctrl[`CTRL_MEM_SIZE] = `MEM_HALF;
          3'b010: ctrl[`CTRL_MEM_SIZE] = `MEM_WORD;
          3'b100: begin ctrl[`CTRL_MEM_SIZE] = `MEM_BYTE; ctrl[`CTRL_MEM_UNSIGNED] = 1'b1; end
          3'b101: begin ctrl[`CTRL_MEM_SIZE] = `MEM_HALF; ctrl[`CTRL_MEM_UNSIGNED] = 1'b1; end
          default: illegal = 1'b1;
        endcase
      end

      // ------------------------------------------------------------------
      // STORE: SB/SH/SW
      // ------------------------------------------------------------------
      `OPC_STORE: begin
        ctrl[`CTRL_MEM_WRITE] = 1'b1;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_S;
        ctrl[`CTRL_MEM_SIZE]  = `MEM_BYTE;
        case (funct3)
          3'b000: ctrl[`CTRL_MEM_SIZE] = `MEM_BYTE;
          3'b001: ctrl[`CTRL_MEM_SIZE] = `MEM_HALF;
          3'b010: ctrl[`CTRL_MEM_SIZE] = `MEM_WORD;
          default: illegal = 1'b1;
        endcase
      end

      // ------------------------------------------------------------------
      // 条件分支
      // ------------------------------------------------------------------
      `OPC_BRANCH: begin
        ctrl[`CTRL_PC_SEL]       = `PC_BR;
        ctrl[`CTRL_ALU_A_SRC]    = `ALU_A_PC;
        ctrl[`CTRL_ALU_B_SRC]    = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]      = `IMM_B;
        ctrl[`CTRL_BRANCH_TYPE]  = `BR_EQ;
        case (funct3)
          3'b000: ctrl[`CTRL_BRANCH_TYPE] = `BR_EQ;
          3'b001: ctrl[`CTRL_BRANCH_TYPE] = `BR_NE;
          3'b100: ctrl[`CTRL_BRANCH_TYPE] = `BR_LT;
          3'b101: ctrl[`CTRL_BRANCH_TYPE] = `BR_GE;
          3'b110: ctrl[`CTRL_BRANCH_TYPE] = `BR_LTU;
          3'b111: ctrl[`CTRL_BRANCH_TYPE] = `BR_GEU;
          default: illegal = 1'b1;
        endcase
      end

      // ------------------------------------------------------------------
      // LUI / AUIPC / JAL / JALR
      // ------------------------------------------------------------------
      `OPC_LUI: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_ALU_A_SRC] = `ALU_A_ZERO;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_U;
        ctrl[`CTRL_ALU_OP]    = `ALU_ADD;
        ctrl[`CTRL_WB_SRC]    = `WB_ALU;
      end

      `OPC_AUIPC: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_ALU_A_SRC] = `ALU_A_PC;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_U;
        ctrl[`CTRL_ALU_OP]    = `ALU_ADD;
        ctrl[`CTRL_WB_SRC]    = `WB_ALU;
      end

      `OPC_JAL: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_PC_SEL]    = `PC_J;
        ctrl[`CTRL_ALU_A_SRC] = `ALU_A_PC;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_J;
        ctrl[`CTRL_ALU_OP]    = `ALU_ADD;
        ctrl[`CTRL_WB_SRC]    = `WB_PC4;
      end

      `OPC_JALR: begin
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_PC_SEL]    = `PC_JR;
        ctrl[`CTRL_ALU_A_SRC] = `ALU_A_RS1;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_I;
        ctrl[`CTRL_ALU_OP]    = `ALU_ADD;
        ctrl[`CTRL_WB_SRC]    = `WB_PC4;
        if (funct3 != 3'b000) illegal = 1'b1;
      end

      // ------------------------------------------------------------------
      // RV32A: LR.W / SC.W / AMO*.W (默认开启, 定义 A_DIS 关闭)
      // ------------------------------------------------------------------
`ifndef A_DIS
      `OPC_AMO: begin
        ctrl[`CTRL_AMO_EN]    = 1'b1;
        ctrl[`CTRL_AMO_OP]    = instr[31:27];
        ctrl[`CTRL_AMO_AQ]    = instr[26];
        ctrl[`CTRL_AMO_RL]    = instr[25];
        ctrl[`CTRL_REG_WRITE] = 1'b1;
        ctrl[`CTRL_WB_SRC]    = `WB_MEM;
        ctrl[`CTRL_ALU_A_SRC] = `ALU_A_RS1;
        ctrl[`CTRL_ALU_B_SRC] = `ALU_B_IMM;
        ctrl[`CTRL_IMM_FMT]   = `IMM_I;
        if (funct3 != 3'b010) begin
          illegal = 1'b1;
        end
        else if ((instr[31:27] == `AMO_LR) && (instr[24:20] != 5'd0)) begin
          illegal = 1'b1;
        end
        else begin
          case (instr[31:27])
            `AMO_LR, `AMO_SC: ctrl[`CTRL_ALU_OP] = `ALU_ADD;
            `AMO_SWAP:        ctrl[`CTRL_ALU_OP] = `ALU_AMO_SWAP;
            `AMO_ADD:         ctrl[`CTRL_ALU_OP] = `ALU_AMO_ADD;
            `AMO_XOR:         ctrl[`CTRL_ALU_OP] = `ALU_AMO_XOR;
            `AMO_AND:         ctrl[`CTRL_ALU_OP] = `ALU_AMO_AND;
            `AMO_OR:          ctrl[`CTRL_ALU_OP] = `ALU_AMO_OR;
            `AMO_MIN:         ctrl[`CTRL_ALU_OP] = `ALU_AMO_MIN;
            `AMO_MAX:         ctrl[`CTRL_ALU_OP] = `ALU_AMO_MAX;
            `AMO_MINU:        ctrl[`CTRL_ALU_OP] = `ALU_AMO_MINU;
            `AMO_MAXU:        ctrl[`CTRL_ALU_OP] = `ALU_AMO_MAXU;
            default:          illegal = 1'b1;
          endcase
        end
      end
`else
      `OPC_AMO: illegal = 1'b1;
`endif

      // ------------------------------------------------------------------
      // FENCE (f3=000: 顺序核合法 NOP) / FENCE.I (f3=001: 冲刷 I-Cache + BTB + 流水线)
      // ------------------------------------------------------------------
      `OPC_FENCE: begin
        case (funct3)
          3'b000: ;                                     // FENCE (含 FENCE.TSO)
          3'b001: ctrl[`CTRL_SYS_OP] = `SYS_FENCEI;     // Zifencei: FENCE.I
          default: illegal = 1'b1;
        endcase
      end

      // ------------------------------------------------------------------
      // SYSTEM: ECALL / EBREAK / SRET / MRET / WFI / SFENCE.VMA / Zicsr
      // ------------------------------------------------------------------
      `OPC_SYSTEM: begin
        case (funct3)
          3'b000: begin
            if ((funct7 == 7'b0001001) && (rd == 5'd0)) begin
              // SFENCE.VMA (rs1=vaddr, rs2=asid 均可非零, rd 必须为 0)
              ctrl[`CTRL_SYS_OP] = `SYS_SFENCE;
            end
            else if ((rs1 != 5'd0) || (rd != 5'd0)) begin
              illegal = 1'b1;
            end
            else begin
              case (instr[31:20])
                12'h000: ctrl[`CTRL_SYS_OP] = `SYS_ECALL;
                12'h001: ctrl[`CTRL_SYS_OP] = `SYS_EBREAK;
                12'h102: ctrl[`CTRL_SYS_OP] = `SYS_SRET;
                12'h105: ctrl[`CTRL_SYS_OP] = `SYS_WFI;
                12'h302: ctrl[`CTRL_SYS_OP] = `SYS_MRET;
                default: illegal = 1'b1;
              endcase
            end
          end
          3'b100: illegal = 1'b1;
          default: begin
            ctrl[`CTRL_SYS_OP]      = `SYS_CSR;
            ctrl[`CTRL_CSR_ADDR]    = instr[31:20];
            ctrl[`CTRL_CSR_CMD]     = funct3[1:0];
            ctrl[`CTRL_CSR_SRC_IMM] = funct3[2];
            ctrl[`CTRL_CSR_UIMM]    = instr[19:15];
            ctrl[`CTRL_REG_WRITE]   = 1'b1;
            ctrl[`CTRL_WB_SRC]      = `WB_CSR;
          end
        endcase
      end

      default: illegal = 1'b1;
    endcase

    ctrl[`CTRL_ILLEGAL] = illegal;

    // 非法指令严格无架构副作用
    if (illegal) begin
      ctrl[`CTRL_REG_WRITE] = 1'b0;
      ctrl[`CTRL_MEM_READ]  = 1'b0;
      ctrl[`CTRL_MEM_WRITE] = 1'b0;
      ctrl[`CTRL_AMO_EN]    = 1'b0;
      ctrl[`CTRL_PC_SEL]    = `PC_NEXT;
      ctrl[`CTRL_SYS_OP]    = `SYS_NONE;
    end
  end

endmodule
