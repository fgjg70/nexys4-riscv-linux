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
│   ├── cpu/          # 单发射五级流水线 RV32IMA 核心（rv32_cpu.v + 19 个纯 Verilog .v + rv32_defs.vh）
│   ├── soc/          # 4 KB VIPT 安全 icache.v / dcache.v、soc_bus.v、bootrom.v、rv32_soc.v
│   ├── periph/       # 标准 SiFive clint.v、最小 plic.v、NS16550A uart_16550.v（+ 旧 mmio_subsys.v）
│   ├── video/        # [待建] 640×480 RGB444 VGA 控制器与帧缓冲读取通路
│   └── camera/       # [待建] JA+JB Pmod OV5640（16-bit SCCB + cam_pclk 异步 FIFO 采集）
├── fpga/
│   └── nexys4_ddr/   # [待建] Nexys 4 DDR 顶层、XDC 约束、MIG DDR2 IP 与 Vivado 构建脚本
├── sim/              # 严格纯 Verilog 回归测试台（tb_units / tb_core / tb_soc / tb_sw / tb_linux_soc）
├── sw/               # 裸机启动固件与统一主存 SoC 端到端 C 测试集（sw/soc_test/）
├── tools/            # 回归脚本（verify.py）、汇编器（asm.py）、ELF/HEX 转换与串口工具
└── docs/             # 架构规划（ARCHITECTURE.md）与迁移溯源（MIGRATION-NOTES.md）
```

---

## 当前进展（Stage 1A · 核与统一主存 SoC 闭环）

- **单发射核心（`rtl/cpu/rv32_cpu.v`）**：
  - 完整 `RV32IMA + Zicsr + Zicntr + Zifencei + WFI`（默认开启 RV32A，支持可选 `DIV_RADIX4`）；
  - 全 32 位地址空间两级流水 gshare BTB（`PC_TOP = 32`）+ 单拍 `flush_all`；
  - 64 位 `mcycle`/`minstret`/`time` + `mcountinhibit` + 向量化 `mtvec` + 严格非法/只读 CSR 异常 + 指令非对齐异常 + WB 段精确总线访问异常；
  - 解耦多周期 `ibus`/`dbus` 握手，已修复背靠背 `AMO`/`LR.W→SC.W` 冒险与写回隔离缺陷。
- **Cache 与标准 Linux 外设（`rtl/soc/rv32_soc.v`）**：
  - **4 KB 直接映射 VIPT 安全 `icache.v` / 回写 `dcache.v`**（索引严格位于 4 KB 页内 `addr[11:5]`，命中 1 拍零停顿，MMIO 自动旁路，`FENCE.I` 清洗脏行并失效 I-Cache/BTB）；
  - **统一总线 `soc_bus.v`**：`0x0000_1000` BootROM、`0x0200_0000` SiFive CLINT、`0x0C00_0000` PLIC、`0x1000_0000` NS16550A UART、`0x8000_0000` 128 MB 主存窗口（未映射地址与只读写返回精确总线错误）。

---

## 快速验证

使用 `tools/verify.py` 一键运行严格纯 Verilog 回归（不传 `-sv`/`--sv`；22/22 覆盖基-2 与 `DIV_RADIX4`，含 `tb_linux_soc` 端到端 C 固件仿真）：

```powershell
python tools/verify.py
python tools/verify.py --all-modes
```

重新编译统一主存 SoC 端到端 C 测试固件：

```powershell
python sw/soc_test/build.py
```

详细架构设计与分阶段路线见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，迁移溯源见 [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md)。
