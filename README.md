# Nexys 4 DDR · RISC-V Linux + VGA + Pmod OV5640 SoC

> **目标平台**：Digilent **Nexys 4 DDR**（Artix-7 `xc7a100tcsg324-1`，128 MB DDR2 `MT47H64M16HR-25E`，100 MHz 主时钟 `E3`）
> **外设组合**：板载 12-bit VGA（640×480@60 Hz RGB444）+ 双 Pmod（`JA + JB`）OV5640 摄像头 + USB-UART（NS16550A）+ microSD（SPI Mode 0）+ 128 MB DDR2（MIG 7 Series）
> **代码规范**：**全工程 100% 纯 Verilog-2001/2005（`.v` + `.vh`）**，零 `.sv` 文件、零 SystemVerilog 语法；回归脚本与 Vivado 综合严格不传 `-sv`/`--sv`。
> **核心策略**：**单发射高主频 RV32IMA 核**（含可选 `DIV_RADIX4` 基-4 除法宏），已完成 **路线 A（nommu Linux）→ 路线 B（M/S/U + Sv32 MMU + OpenSBI/标准 Linux 引导栈）** 全链路纯 Verilog 硬件与固件闭环。

---

## 目录结构

```text
digital/
├── rtl/
│   ├── common/       # 纯 Verilog 跨时钟域基础件（async_fifo.v 格雷码双时钟异步 FIFO）
│   ├── cpu/          # 单发射五级流水线 RV32IMA 核（M/S/U 特权级 + S-CSR/委托 + SRET/SFENCE.VMA）
│   ├── soc/          # Sv32 MMU（sv32_mmu.v）、8 KB 2路 VIPT icache/dcache (+256 B 物理标签 L0D)、soc_bus、bootrom、mig_ddr2_bridge、rv32_soc
│   ├── periph/       # 标准 SiFive clint.v、plic.v（Context 0 M-mode + Context 1 S-mode）、NS16550A uart_16550.v、spi_master.v
│   ├── video/        # 640×480@60Hz 12-bit RGB444 VGA 控制器（vga_ctrl.v）
│   └── camera/       # JA+JB Pmod OV5640 16-bit SCCB（ov5640_sccb.v）+ cam_pclk 异步采集（ov5640_capture.v）
├── fpga/
│   └── nexys4_ddr/   # 实板顶层 top_nexys4_ddr.v、nexys4_ddr.xdc、官方 mig.prj、build_project.tcl（支持 bist/linux 双 ROM）、synth_ooc.tcl
├── sim/              # 严格纯 Verilog 回归测试台（30/30 双模式：含 tb_soc_priv_s / tb_soc_sv32 / tb_bootrom_linux / tb_linux_soc / tb_periph_stage2）
├── sw/
│   ├── board_bist/   # 实板硬件上电自检 BootROM（board_bist.hex）
│   ├── bootrom_linux/# 16 KB Linux 启动加载器（microSD SPI Mode 0 + USB-UART NX4U 双模加载 + send_uart.py）
│   ├── linux/        # 标准 Sv32 / nommu 设备树（.dts）、Linux defconfig、SD 镜像打包器（mk_sd_image.py）与编译脚本（build_linux.sh）
│   └── soc_test/     # 统一主存 SoC 端到端 C 验证固件
├── tools/            # 回归脚本（verify.py）、汇编器（asm.py，支持 S-CSR/sret/sfence.vma）、ELF/HEX 转换工具
└── docs/             # 架构规划与实测记录（ARCHITECTURE.md）、五轮优化签核（AUDIT_OPTIMIZATION.md）与迁移溯源（MIGRATION-NOTES.md）
```

---

## Vivado 2023.2 布局布线实测（`xc7a100tcsg324-1`，含完整 M/S/U + Sv32 MMU）

| 指标 | 实测占用 / 结果（Phase D+C：M/S/U + Sv32 MMU + 100 MHz + Linux BootROM） | 占比 / 裕量与对比 |
|---|---|---|
| **特权级与 MMU** | **M/S/U 三态 + `medeleg`/`mideleg` + S-CSR + PLIC Context 1**；**Sv32 MMU**（双侧 1 项微 TLB + 8 项全相联主 TLB，支持 4 KB/4 MB 巨页 + D-Cache 脏行一致性硬件 PTW + `SFENCE.VMA` + 物理标签 VIPT I$/D$/L0D） | `tb_linux_soc` (`soc_test.hex`) 保持 **`85,497` 周期（0 Bare-mode IPC 退化）**；`tb_soc_priv_s` `3,351` 周期、`tb_soc_sv32` `33,980` 周期全通过 |
| **OOC `rv32_soc` 资源** | **`9,054` LUT**（含 570 LUTRAM）/ **`5,255` FF（0 Latch）** / **`9.0` BRAM Tile** / **`4` DSP48E1** | LUT **14.28%** / FF **4.14%** / BRAM **6.67%**（**Sv32 零新增 BRAM**）/ DSP **1.67%** |
| **OOC `sys_clk` 主频** | **`100.43 MHz`**（**`WNS = +0.043 ns`，`TNS = 0.000 ns`，`0 / 14,301` 违例，`WHS = +0.080 ns`**） | 默认 `opt/place/route` 一次达标 100 MHz；`cam_pclk` +15.038 ns / `vga_clk` +35.644 ns |
| **全芯片 Linux 比特流 (`top_nexys4_ddr`)** | 含真实 `clk_wiz_0` + `mig_7series_0` (128 MB DDR2) + Sv32 MMU + `bootrom_linux.hex`：**`12,527` LUT (19.76%) / `8,869` FF (6.99%, 0 Latch) / `13.5` BRAM (10.00%) / `4` DSP** | **`WNS = +0.170 ns` (`clk_100m` 101.73 MHz, `0 / 30,275` 违例), `WHS = +0.032 ns` (`0 / 30,274`), `ui_clk` +4.553 ns, `0 DRC Errors`**, 已签核 `.bit` + QSPI `SPIx4` `.bin` |
| **Linux 引导软件栈** | 16 KB `bootrom_linux.hex`（SDHC/SDSC `NX4L` + USB-UART `NX4U` + RISC-V Linux ABI `a0=0, a1=dtb`）+ Sv32/nommu DTS + OpenSBI/Linux/Buildroot 构建脚本 | `tb_bootrom_linux` 真实 SPI Mode 0 SDHC 行为卡端到端引导仿真通过；详见 [sw/linux/README.md](sw/linux/README.md) |

---

## 统一地址映射与中断分配

| 地址区间 | 设备 | PLIC Source | 说明 |
|---|---|---|---|
| `0x0000_1000 .. 0x0000_4FFF` | `bootrom` (16 KB) | — | 只读启动 ROM（支持 `board_bist.hex` / `bootrom_linux.hex` 切换，写触发 Store Access Fault） |
| `0x0200_0000 .. 0x0200_FFFF` | `clint` | — | 标准 SiFive `msip` / `mtimecmp` / `mtime` |
| `0x0C00_0000 .. 0x0C3F_FFFF` | `plic` | — | 标准 RISC-V PLIC（7 路中断源，**Context 0 M-mode + Context 1 S-mode**） |
| `0x1000_0000 .. 0x1000_0FFF` | `uart_16550` | **Source 1** | 标准 NS16550A（兼容 Linux 8250 驱动） |
| `0x1000_1000 .. 0x1000_1FFF` | `spi_master` | **Source 2** | microSD SPI Mode 0 主控制器 |
| `0x1000_2000 .. 0x1000_2FFF` | `vga_ctrl` | **Source 3** | VESA 640×480@60Hz 12-bit VGA（上电彩条自检 + RGB565 流） |
| `0x1000_3000 .. 0x1000_3FFF` | `ov5640_capture` | **Source 4** | 16-bit SCCB (`0x3C`) + `cam_pclk` 异步 FIFO RGB565 采集 |
| `0x8000_0000 .. 0x87FF_FFFF` | **128 MB DDR2** | — | 统一主存（Sv32 MMU + 8 KB 2 路 VIPT I/D-Cache + 256 B L0D + `mig_ddr2_bridge` 128-bit 异步 FIFO 桥） |

---

## 快速验证与构建

1. **严格纯 Verilog 全量仿真回归**（**30/30**：`default(radix-2)` 15/15 + `DIV_RADIX4` 15/15，不传 `-sv`/`--sv`）：

```powershell
python tools/verify.py
python tools/verify.py --all-modes
```

2. **生成 Linux BootROM 镜像与打包 microSD / 串口下载 Linux**：

```powershell
# 重新生成 16 KB Linux BootROM (sw/bootrom_linux/bootrom_linux.hex)
python sw/bootrom_linux/build.py

# 打包 OpenSBI fw_payload.bin (+ 可选独立 DTB) 为 microSD 镜像
python sw/linux/mk_sd_image.py fw_payload.bin -o sd_linux.img
# 或附加独立 .dtb: python sw/linux/mk_sd_image.py fw_payload.bin --dtb nexys4_rv32_sv32.dtb -o sd_linux.img

# 或经 USB-UART 免拔卡直接下载到板载 DDR2 启动（详见 sw/linux/README.md）
python sw/bootrom_linux/send_uart.py COM5 fw_payload.bin
```

3. **一键生成 Vivado Nexys 4 DDR 完整工程 / 比特流**（第 3 参数可选 `bist` 上电自检 BootROM 或 `linux` Linux BootROM）：

```powershell
# 生成 Linux BootROM 完整工程与 100 MHz 比特流 (.bit) + QSPI SPIx4 (.bin)
vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado bitstream linux

# 生成硬件上电自检 (board_bist.hex) 比特流
vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado bitstream bist
```

详细架构、JA+JB OV5640 引脚表与分阶段路线见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，五轮优化与 Sv32 100 MHz 时序签核记录见 [docs/AUDIT_OPTIMIZATION.md](docs/AUDIT_OPTIMIZATION.md)，Linux 编译引导说明见 [sw/linux/README.md](sw/linux/README.md)，迁移溯源见 [docs/MIGRATION-NOTES.md](docs/MIGRATION-NOTES.md)。
