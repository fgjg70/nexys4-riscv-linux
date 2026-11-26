# Nexys 4 DDR · RISC-V Linux + VGA + Pmod OV5640 SoC

> **目标平台**：Digilent **Nexys 4 DDR**（Artix-7 `xc7a100tcsg324-1`，128 MB DDR2 `MT47H64M16HR-25E`，100 MHz 主时钟 `E3`）
> **外设组合**：板载 12-bit VGA（640×480@60 Hz RGB444）+ 双 Pmod（`JA + JB`）OV5640 摄像头 + USB-UART（NS16550A）+ microSD（SPI Mode 0）+ 128 MB DDR2（MIG 7 Series）
> **代码规范**：**全工程 100% 纯 Verilog-2001/2005（`.v` + `.vh`）**，零 `.sv` 文件、零 SystemVerilog 语法；回归脚本与 Vivado 综合严格不传 `-sv`/`--sv`。
> **核心策略**：**单发射高主频 RV32IMA 核**（含可选 `DIV_RADIX4` 基-4 除法宏），按 **路线 A（nommu Linux）→ 路线 B（Sv32 MMU Linux）** 渐进演进。

---

## 目录结构

```text
digital/
├── rtl/
│   ├── common/       # 纯 Verilog 跨时钟域基础件（async_fifo.v 格雷码双时钟异步 FIFO）
│   ├── cpu/          # 单发射五级流水线 RV32IMA 核心（rv32_cpu.v + 19 个纯 Verilog .v + rv32_defs.vh）
│   ├── soc/          # 8 KB 2路 VIPT icache.v / dcache.v (+256 B L0D)、soc_bus.v、bootrom.v、mig_ddr2_bridge.v、rv32_soc.v
│   ├── periph/       # 标准 SiFive clint.v、plic.v、NS16550A uart_16550.v、spi_master.v（+ 旧 mmio_subsys.v）
│   ├── video/        # 640×480@60Hz 12-bit RGB444 VGA 控制器（vga_ctrl.v）
│   └── camera/       # JA+JB Pmod OV5640 16-bit SCCB（ov5640_sccb.v）+ cam_pclk 异步采集（ov5640_capture.v）
├── fpga/
│   └── nexys4_ddr/   # 实板顶层 top_nexys4_ddr.v、nexys4_ddr.xdc、官方 mig.prj、build_project.tcl、synth_ooc.tcl
├── sim/              # 严格纯 Verilog 回归测试台（tb_units / tb_core / tb_soc / tb_sw / tb_linux_soc / tb_periph_stage2）
├── sw/               # 裸机启动固件与统一主存 SoC 端到端 C 验证固件（sw/soc_test/）
├── tools/            # 回归脚本（verify.py）、汇编器（asm.py）、ELF/HEX 转换与串口工具
└── docs/             # 架构规划与实测记录（ARCHITECTURE.md）与迁移溯源（MIGRATION-NOTES.md）
```

---

## Vivado 2023.2 布局布线实测（`xc7a100tcsg324-1`，`rv32_soc` 完整含全部外设）

| 指标 | 实测占用 / 结果（Round 4：100 MHz + 8K BRAM BHT + 异频 DDR2 解耦） | 占比 / 裕量与对比 |
|---|---|---|
| **分支预测与缓存** | **128 项分布式 RAM Taken-Only BTB + 8,192 项单 `RAMB18E1` 同步 Bimodal + 默认 16 项 RAS**；**8 KB 2 路 VIPT I$ (64 组×64 B, 21b `RAM64M` `{vld,tag}`)** + **8 KB 2 路 VIPT D$ + 256 B 0 拍直写 LUTRAM L0D** | `tb_linux_soc` (`soc_test.hex`) **95,651 → 85,497 周期（-10.6%，+11.9% IPC）**；叠加上板 **75 → 100 MHz (+33.3%)** 实板墙钟提速 **~1.49×** |
| **Slice LUTs** | **7,315** / 63,400（含 570 Distributed RAM） | **11.54%**（较 Round 3 骤降 **-1,007 LUT / -12.1%**） |
| **Slice Registers (FF)** | **3,943** / 126,800（**0 Latch**） | **3.11%**（较 Round 3 净减 **-322 FF**） |
| **Block RAM Tile** | **9.0** / 135（8×`RAMB36E1` + 2×`RAMB18E1`；加 `mig_ddr2_bridge` 双异步 FIFO 4.5 块合计 **13.5 / 135 = 10.0%**） | **6.67%**（含 8K Bimodal `RAMB18E1`） |
| **DSP48E1** | **4** / 240 | **1.67%**（统一 33×33 乘法器） |
| **`sys_clk` 布线后主频** | **100.52 MHz**（**`WNS = +0.052 ns`，`TNS = 0.000 ns`，0 / 11,876 违例**） | **默认 `opt/place/route` 一次达标 100 MHz**，通过 128-bit 双异步 FIFO 与 75 MHz MIG `ui_clk` 解耦 |
| **`mig_ddr2_bridge` 异频桥** | 165 LUT / 458 FF / 4.5 BRAM Tile（16 项 Posted Write + 128-bit 读行缓冲驻留 100 MHz 侧） | `sys_clk` (100 MHz) **`+4.332 ns`** / `mig_clk` (75 MHz) **`+7.606 ns`** / `WHS = +0.099 ns` |
| **`cam_pclk` / `vga_clk`** | 48 MHz 裕量 +14.879 ns / 25 MHz 裕量 +34.892 ns | `WHS = +0.031 ns` / 0 组合环 / 0 Critical Warnings |

---

## 统一地址映射与中断分配

| 地址区间 | 设备 | PLIC Source | 说明 |
|---|---|---|---|
| `0x0000_1000 .. 0x0000_4FFF` | `bootrom` (16 KB) | — | 只读启动 ROM（写触发 Store Access Fault） |
| `0x0200_0000 .. 0x0200_FFFF` | `clint` | — | 标准 SiFive `msip` / `mtimecmp` / `mtime` |
| `0x0C00_0000 .. 0x0C3F_FFFF` | `plic` | — | 标准最小 RISC-V PLIC（7 路中断源） |
| `0x1000_0000 .. 0x1000_0FFF` | `uart_16550` | **Source 1** | 标准 NS16550A（兼容 Linux 8250 驱动） |
| `0x1000_1000 .. 0x1000_1FFF` | `spi_master` | **Source 2** | microSD SPI Mode 0 主控制器 |
| `0x1000_2000 .. 0x1000_2FFF` | `vga_ctrl` | **Source 3** | VESA 640×480@60Hz 12-bit VGA（上电彩条自检 + RGB565 流） |
| `0x1000_3000 .. 0x1000_3FFF` | `ov5640_capture` | **Source 4** | 16-bit SCCB (`0x3C`) + `cam_pclk` 异步 FIFO RGB565 采集 |
| `0x8000_0000 .. 0x87FF_FFFF` | **128 MB DDR2** | — | 统一主存（8 KB 2 路 VIPT I/D-Cache + 256 B L0D + `mig_ddr2_bridge` 128-bit Native） |

---

## 快速验证与构建

1. **严格纯 Verilog 全量仿真回归**（24/24：`default(radix-2)` 12/12 + `DIV_RADIX4` 12/12，不传 `-sv`/`--sv`）：

```powershell
python tools/verify.py
python tools/verify.py --all-modes
```

2. **重新编译统一主存 SoC 端到端 C 测试固件**：

```powershell
python sw/soc_test/build.py
```

3. **一键生成 Vivado Nexys 4 DDR 完整工程**（自动创建 200/100/25/24 MHz `clk_wiz_0` 并导入 `fpga/nexys4_ddr/mig.prj`，SoC 跑 100 MHz 经异步 FIFO 桥接 75 MHz DDR2）：

```powershell
vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado
```

详细架构、JA+JB OV5640 引脚表与分阶段路线见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，四轮架构演进与全局审计优化记录见 [docs/AUDIT_OPTIMIZATION.md](docs/AUDIT_OPTIMIZATION.md)，迁移溯源见 [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md)。
