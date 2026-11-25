// ============================================================================
// rv32_defs.vh — RV32IMA 核心编码、控制束与 SoC 地址定义（纯 Verilog-2001）
// ----------------------------------------------------------------------------
// 全部常量、编码与控制束命名位片集中定义于此，各模块通过 `include "rv32_defs.vh"`
// 引用，杜绝裸魔数位切片与重复维护。
// ============================================================================

`ifndef RV32_DEFS_VH
`define RV32_DEFS_VH

// ----------------------------------------------------------------------------
// 全局数据宽度
// ----------------------------------------------------------------------------
`define RV32_XLEN       32

// ----------------------------------------------------------------------------
// Opcode (instr[6:0])
// ----------------------------------------------------------------------------
`define OPC_LUI         7'b0110111
`define OPC_AUIPC       7'b0010111
`define OPC_JAL         7'b1101111
`define OPC_JALR        7'b1100111
`define OPC_BRANCH      7'b1100011
`define OPC_LOAD        7'b0000011
`define OPC_STORE       7'b0100011
`define OPC_OPIMM       7'b0010011
`define OPC_OP          7'b0110011
`define OPC_FENCE       7'b0001111
`define OPC_SYSTEM      7'b1110011
`define OPC_AMO         7'b0101111

// ----------------------------------------------------------------------------
// funct7 常量
// ----------------------------------------------------------------------------
`define F7_ZERO         7'b0000000
`define F7_ALT          7'b0100000
`define F7_MULDIV       7'b0000001

// ----------------------------------------------------------------------------
// ALU 操作码 (5-bit)
// ----------------------------------------------------------------------------
`define ALU_ADD         5'd0
`define ALU_SUB         5'd1
`define ALU_AND         5'd2
`define ALU_OR          5'd3
`define ALU_XOR         5'd4
`define ALU_SLL         5'd5
`define ALU_SRL         5'd6
`define ALU_SRA         5'd7
`define ALU_SLT         5'd8
`define ALU_SLTU        5'd9
// RV32M
`define ALU_MUL         5'd10
`define ALU_MULH        5'd11
`define ALU_MULHSU      5'd12
`define ALU_MULHU       5'd13
`define ALU_DIV         5'd14
`define ALU_DIVU        5'd15
`define ALU_REM         5'd16
`define ALU_REMU        5'd17
// RV32A (待写回内存的新值运算)
`define ALU_AMO_SWAP    5'd18
`define ALU_AMO_ADD     5'd19
`define ALU_AMO_XOR     5'd20
`define ALU_AMO_AND     5'd21
`define ALU_AMO_OR      5'd22
`define ALU_AMO_MIN     5'd23
`define ALU_AMO_MAX     5'd24
`define ALU_AMO_MINU    5'd25
`define ALU_AMO_MAXU    5'd26

// ----------------------------------------------------------------------------
// RV32A funct5 原子操作码 (instr[31:27])
// ----------------------------------------------------------------------------
`define AMO_LR          5'b00010
`define AMO_SC          5'b00011
`define AMO_SWAP        5'b00001
`define AMO_ADD         5'b00000
`define AMO_XOR         5'b00100
`define AMO_AND         5'b01100
`define AMO_OR          5'b01000
`define AMO_MIN         5'b10000
`define AMO_MAX         5'b10100
`define AMO_MINU        5'b11000
`define AMO_MAXU        5'b11100

// ----------------------------------------------------------------------------
// ALU 操作数来源
// ----------------------------------------------------------------------------
`define ALU_A_RS1       2'd0
`define ALU_A_PC        2'd1
`define ALU_A_ZERO      2'd2

`define ALU_B_RS2       1'b0
`define ALU_B_IMM       1'b1

// ----------------------------------------------------------------------------
// 立即数格式 (3-bit)
// ----------------------------------------------------------------------------
`define IMM_I           3'd0
`define IMM_S           3'd1
`define IMM_B           3'd2
`define IMM_U           3'd3
`define IMM_J           3'd4

// ----------------------------------------------------------------------------
// 分支类型 (3-bit: bit0=取反, bit2/1=有/无符号)
// ----------------------------------------------------------------------------
`define BR_EQ           3'b000
`define BR_NE           3'b001
`define BR_LT           3'b100
`define BR_GE           3'b101
`define BR_LTU          3'b110
`define BR_GEU          3'b111

// ----------------------------------------------------------------------------
// 访存宽度 (2-bit)
// ----------------------------------------------------------------------------
`define MEM_BYTE        2'd0
`define MEM_HALF        2'd1
`define MEM_WORD        2'd2

// ----------------------------------------------------------------------------
// 写回来源 (2-bit)
// ----------------------------------------------------------------------------
`define WB_ALU          2'd0
`define WB_MEM          2'd1
`define WB_PC4          2'd2
`define WB_CSR          2'd3

// ----------------------------------------------------------------------------
// SYSTEM / FENCE.I 子类型 (3-bit)
// ----------------------------------------------------------------------------
`define SYS_NONE        3'd0
`define SYS_CSR         3'd1
`define SYS_ECALL       3'd2
`define SYS_EBREAK      3'd3
`define SYS_MRET        3'd4
`define SYS_FENCEI      3'd5
`define SYS_WFI         3'd6

// ----------------------------------------------------------------------------
// 下一 PC 来源 (2-bit)
// ----------------------------------------------------------------------------
`define PC_NEXT         2'd0
`define PC_BR           2'd1
`define PC_J            2'd2
`define PC_JR           2'd3

// ----------------------------------------------------------------------------
// EX 段前递来源 (2-bit)
// ----------------------------------------------------------------------------
`define FWD_REG         2'd0
`define FWD_EX_MEM      2'd1
`define FWD_MEM_WB      2'd2

// ----------------------------------------------------------------------------
// 控制束 (56-bit 打包向量 + 命名字段位片, 全零即为安全 NOP)
// ----------------------------------------------------------------------------
`define CTRL_W            56
`define CTRL_NOP          56'd0

`define CTRL_ALU_OP       4:0     // 5-bit: ALU 操作
`define CTRL_ALU_A_SRC    6:5     // 2-bit: ALU A 来源
`define CTRL_ALU_B_SRC    7       // 1-bit: ALU B 来源
`define CTRL_BRANCH_TYPE  10:8    // 3-bit: 条件分支类型
`define CTRL_PC_SEL       12:11   // 2-bit: 下一 PC 来源
`define CTRL_MEM_READ     13      // 1-bit: load 使能
`define CTRL_MEM_WRITE    14      // 1-bit: store 使能
`define CTRL_MEM_SIZE     16:15   // 2-bit: 访存宽度
`define CTRL_MEM_UNSIGNED 17      // 1-bit: load 无符号扩展
`define CTRL_REG_WRITE    18      // 1-bit: 写回使能
`define CTRL_WB_SRC       20:19   // 2-bit: 写回数据来源
`define CTRL_IMM_FMT      23:21   // 3-bit: 立即数格式
`define CTRL_ILLEGAL      24      // 1-bit: 非法指令标志
`define CTRL_SYS_OP       27:25   // 3-bit: SYSTEM / FENCE.I 子类型
`define CTRL_CSR_ADDR     39:28   // 12-bit: CSR 地址
`define CTRL_CSR_CMD      41:40   // 2-bit: 01=W 10=S 11=C
`define CTRL_CSR_SRC_IMM  42      // 1-bit: 1=uimm, 0=rs1
`define CTRL_CSR_UIMM     47:43   // 5-bit: CSR 立即数
`define CTRL_AMO_EN       48      // 1-bit: RV32A 原子序列使能
`define CTRL_AMO_OP       53:49   // 5-bit: funct5
`define CTRL_AMO_AQ       54      // 1-bit: acquire
`define CTRL_AMO_RL       55      // 1-bit: release

// ----------------------------------------------------------------------------
// 兼容旧基线 (core.v + mmio_subsys.v 裸机测试用) 地址映射
// ----------------------------------------------------------------------------
`define PC_RESET          32'h8000_0000
`define IMEM_BASE         32'h8000_0000
`define IMEM_BYTES        16384
`define DMEM_BASE         32'h9000_0000
`define DMEM_BYTES        16384
`define INSTR_NOP         32'h0000_0013

`define MMIO_BASE         32'hA000_0000
`define MMIO_GPIO_OUT     32'hA000_0000
`define MMIO_GPIO_IN      32'hA000_0004
`define MMIO_CYCLE_LO     32'hA000_0008
`define MMIO_CYCLE_HI     32'hA000_000C
`define MMIO_UART_TX      32'hA000_0010
`define MMIO_UART_STAT    32'hA000_0014
`define MMIO_UART_RX      32'hA000_0018
`define MMIO_UART_RSTAT   32'hA000_001C
`define MMIO_MARK         32'hA000_0020
`define MMIO_RESULT       32'hA000_0024
`define MMIO_MTIMECMP_LO  32'hA000_0028
`define MMIO_MTIMECMP_HI  32'hA000_002C
`define MMIO_MTIME_LO     32'hA000_0030
`define MMIO_MTIME_HI     32'hA000_0034

// ----------------------------------------------------------------------------
// 路线 A / B 统一地址映射 (Nexys 4 DDR Linux SoC)
//   0x0000_1000 .. 0x0000_4FFF : 片上 BootROM (16 KB)
//   0x0200_0000 .. 0x0200_FFFF : 标准 SiFive CLINT (msip / mtimecmp / mtime)
//   0x0C00_0000 .. 0x0C3F_FFFF : 标准最小 RISC-V PLIC
//   0x1000_0000 .. 0x1000_0FFF : NS16550A 兼容串口 (Linux 8250 驱动免改)
//   0x1000_1000 .. 0x1000_1FFF : SPI microSD 控制器 (预留)
//   0x1000_2000 .. 0x1000_2FFF : VGA 640x480 控制寄存器 (预留)
//   0x1000_3000 .. 0x1000_3FFF : JA+JB Pmod OV5640 控制寄存器 (预留)
//   0x8000_0000 .. 0x87FF_FFFF : 128 MB DDR2 统一主存 (Cacheable)
// ----------------------------------------------------------------------------
`define SOC_ROM_BASE      32'h0000_1000
`define SOC_CLINT_BASE    32'h0200_0000
`define SOC_PLIC_BASE     32'h0C00_0000
`define SOC_UART_BASE     32'h1000_0000
`define SOC_SPI_BASE      32'h1000_1000
`define SOC_VGA_BASE      32'h1000_2000
`define SOC_CAM_BASE      32'h1000_3000
`define SOC_RAM_BASE      32'h8000_0000
`define SOC_RAM_MASK      32'hF800_0000  // 匹配 0x8000_0000 .. 0x87FF_FFFF (128 MB)

// ----------------------------------------------------------------------------
// 陷阱原因码 (RISC-V Privileged Spec Table 3.6)
// ----------------------------------------------------------------------------
// 同步异常 (mcause[31] = 0)
`define CAUSE_INSN_MISALIGN  4'd0
`define CAUSE_INSN_ACCESS    4'd1
`define CAUSE_ILLEGAL        4'd2
`define CAUSE_BREAKPOINT     4'd3
`define CAUSE_LOAD_MISALIGN  4'd4
`define CAUSE_LOAD_ACCESS    4'd5
`define CAUSE_STORE_MISALIGN 4'd6
`define CAUSE_STORE_ACCESS   4'd7
`define CAUSE_ECALL_M        4'd11

// 异步中断 (mcause[31] = 1, 写入 mcause 时由 {1'b1, code} 组合)
`define IRQ_SW               4'd3
`define IRQ_TIMER            4'd7
`define IRQ_EXT              4'd11

`endif
