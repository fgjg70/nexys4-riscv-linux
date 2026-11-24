# Nexys 4 DDR · RISC-V Linux + VGA + Pmod OV5640 SoC

> **目标平台**：Digilent **Nexys 4 DDR**（Artix-7 `xc7a100tcsg324-1`，128 MB DDR2，100 MHz 主时钟）
> **外设组合**：板载 12-bit VGA（640×480@60 Hz RGB444）+ 双 Pmod（`JA + JB`）OV5640 摄像头 + USB-UART + microSD + 16 MB QSPI Flash
> **代码规范**：**全工程纯 Verilog-2001/2005（`.v` + `.vh`）**，禁止 SystemVerilog 语法；回归脚本默认不带 `-sv`/`--sv` 严格校验。
> **核心策略**：**单发射高主频 RV32IMA 核**（含可选 `DIV_RADIX4` 基-4 除法宏），按 **路线 A（nommu Linux）→ 路线 B（Sv32 MMU Linux）** 渐进演进；NPU 等 AI 加速子系统后续按独立外设挂载。

---

## 目录结构

```text
digital/
├── rtl/
│   ├── cpu/          # 单发射五级流水线 RV32IMA 核心（19 个纯 Verilog .v + rv32_defs.vh，零厂商原语）
│   ├── periph/       # 基底 MMIO（后续升级为标准 CLINT + 最小 PLIC + NS16550A + SPI-SD）
│   ├── soc/          # [待建] 统一总线互联、4 KB/路 I/D-Cache、BootROM、MIG DDR2 桥接
│   ├── video/        # [待建] 640×480 RGB444 VGA 控制器与帧缓冲读取通路
│   └── camera/       # [待建] JA+JB Pmod OV5640（16-bit SCCB + cam_pclk 异步 FIFO 采集）
├── fpga/
│   └── nexys4_ddr/   # [待建] Nexys 4 DDR 顶层、XDC 约束、MIG DDR2 IP 与 Vivado 构建脚本
├── sim/              # 纯 Verilog 单元/核心/SoC/裸机测试平台与基础回归向量
├── sw/               # 最小裸机 C 启动与验证固件
├── tools/            # 回归脚本（verify.py）、汇编器、ELF/HEX 转换与串口工具
└── docs/             # 架构规划（ARCHITECTURE.md）与迁移溯源（MIGRATION-NOTES.md）
```

---

## 当前基线（Pure Verilog Baseline）

当前仓库包含从上游 `fgjg70/FPGA` 精简迁入并**手工重构为纯 Verilog-2001/2005**、已通过全量非 `-sv` 回归的**单发射 RV32IMA 基底**：
- **ISA**：`RV32IMA + Zicsr`（默认开启 RV32A `AMO*.W` + `LR.W/SC.W` 真预约寄存器，且已在 Trap / `MRET` 时自动清除预约以适配 OS 抢占；保留 `DIV_RADIX4` 基-4 除法宏，默认关闭）。
- **纯 Verilog 规范**：所有公共编码与 56-bit 控制束命名位片集中在 `rtl/cpu/rv32_defs.vh`，模块端口与内部逻辑全部采用可综合 Verilog-2001/2005 写法，无 `logic`/`always_ff`/`always_comb`/`struct`/`enum`/`package`。
- **已剔除**：紫光同创 PG2L100H 专属工程与原语、旧 LCD/OV7670 驱动、顺序双发射核、RV32C 压缩指令扩展及废弃 GEMM 实验代码。

---

## 快速验证

使用 `tools/verify.py` 一键运行严格纯 Verilog 基线回归（自动检测 ModelSim / Vivado `xsim`，不传 `-sv`/`--sv`；默认测试基-2，加 `--all-modes` 同时覆盖 `DIV_RADIX4`）：

```powershell
python tools/verify.py
python tools/verify.py --all-modes
```

详细架构设计与分阶段路线见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，迁移溯源见 [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md)。
