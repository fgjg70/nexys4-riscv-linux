# Nexys 4 DDR RV32IMA + Sv32 Linux 启动指南

本目录提供面向 `rv32_soc`（100 MHz RV32IMA + Zicsr + Zicntr + Zifencei + M/S/U + Sv32 MMU + 128 MB DDR2 + CLINT + PLIC Context 0/1 + NS16550A）的标准 **OpenSBI + Sv32 Linux** 启动套件。

## 1. 硬件内存与中断映射（已对齐 `nexys4_rv32_sv32.dts`）

| 区域 / 外设 | 物理基址 | 大小 | Linux 驱动 / 规格 |
|---|---|---|---|
| BootROM | `0x0000_1000` | 16 KB | `sw/bootrom_linux/bootrom_linux.hex` (microSD + UART NX4U) |
| CLINT | `0x0200_0000` | 64 KB | `sifive,clint0`, 1 MHz `timebase-frequency` (`CLINT_TICK_DIV=100`) |
| PLIC | `0x0C00_0000` | 4 MB | `sifive,plic-1.0.0`, 7 源, Context 0 (`M-mode`) + Context 1 (`S-mode`) |
| UART0 | `0x1000_0000` | 256 B | `ns16550a`, `reg-shift=2`, `reg-io-width=4`, 100 MHz, 115200 8N1, PLIC IRQ 1 |
| SPI microSD | `0x1000_1000` | 4 KB | SPI Mode 0, PLIC IRQ 2 (供 BootROM 加载镜像) |
| DDR2 主存 | `0x8000_0000` | 128 MB | `0x8000_0000` OpenSBI, `0x8040_0000` Linux `Image` + initramfs |

## 2. 第一步：生成带 Linux BootROM 的 Nexys 4 DDR 比特流

```powershell
# 1) 重新汇编 16 KB Linux BootROM (零外部 GCC 依赖)
python sw/bootrom_linux/build.py

# 2) 用 Vivado 一键生成带 Linux BootROM 的比特流与 QSPI .bin
vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs C:/tmp/nx4_linux bitstream linux
```

## 3. 第二步：在 Linux / WSL2 编译 OpenSBI + Sv32 Linux + BusyBox

推荐使用支持无 FPU (`-march=rv32ima_zicsr_zifencei -mabi=ilp32`) 的工具链（如 Buildroot 或 Bootlin `riscv32-ilp32` 工具链）：

```bash
export CROSS_COMPILE=riscv32-buildroot-linux-gnu-
bash sw/linux/build_linux.sh
```

脚本将生成：
- `build_linux_rv32/fw_payload.bin`：OpenSBI v1.5+（内置 `nexys4_rv32_sv32.dtb` + Linux v6.6 `Image` + BusyBox `initramfs`）。
- `build_linux_rv32/sd_linux.img`：已附带 512 B `NX4L` 引导头的原始 microSD 镜像。

## 4. 第三步：上板启动（microSD 或 USB-UART 二选一）

### 方式 A：microSD 卡上电自动启动（推荐）
```bash
sudo dd if=build_linux_rv32/sd_linux.img of=/dev/sdX bs=1M status=progress conv=fsync
```
插卡上电，串口工具打开 `115200 8N1`，即可自动看到：
```text
=== NEXYS4 RV32IMA-Sv32 LINUX BOOTROM v2.0 ===
[SD] Init... OK (SDHC)
[SD] Header NX4L OK, loading...
...
[BOOT] Jump 0x80000000

OpenSBI v1.5.1
   ____                    _____ ____ _____
...
[    0.000000] Linux version 6.6.60 ...
[    0.000000] Machine model: Nexys 4 DDR RV32IMA-Sv32 Linux SoC (100 MHz)
...
Welcome to Nexys 4 DDR RV32IMA-Sv32 Linux!
/ #
```

### 方式 B：免 SD 卡 USB-UART 直接下载启动
```powershell
python sw/bootrom_linux/send_uart.py COM5 build_linux_rv32/fw_payload.bin
```
