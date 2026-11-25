# Nexys A7-100T 移植工程

把仓库中的 PG2L100H 视觉 SoC（RV32IM 双发射 CPU + 128 MAC NPU + 摄像头 + 瓶盖/手势应用）移植到
Digilent Nexys A7-100T（xc7a100tcsg324-1，兼容 Nexys 4 DDR）的独立工程。

本目录是**可独立构建**的移植层：复用 `fpga_pg2l100h/vision/` 下的 CPU、NPU、摄像头、视频和应用
RTL，替换板级时钟、DDR 存储、显示与管脚约束，并重新生成固件。

## 当前状态

| 项目 | 状态 |
|---|---|
| RTL 移植、固件交叉编译 | 完成 |
| DDR2 总线、视频时序、真实 RV32 指令、摄像头到 OLED 仿真 | 见 `validation/simulation_summary.json` |
| Nexys A7-100T 实板 | DDR2 校准和 CPU 读写通过。JA/JB 采到完整的 320×240 RGB565 帧，JC OLED 实时预览已确认。 |

已通过 USB-JTAG 下载 `build/vision_models/top_nexys_a7_vision.bit`。整机串口记录见
`validation/final_vision_uart.log`。DDR2 CPU 读写错误数为 0，瓶盖和手势两种模式的完成推理计数均持续增加。
最终时序报告的建立余量为 +0.019 ns，保持余量为 +0.022 ns，DRC 报告无错误。
JTAG 下载写入 FPGA 配置 SRAM，断电后需要重新下载。

移植版的 CPU 时钟为 **60 MHz**。原 PG2L100H 工程为 90 MHz，但 Artix-7-1 上 75 MHz 时
`clk75` 仍有 1413 个端点不满足建立时间（WNS -2.56 ns，主要路径为 dmem→LSU→转发→BTB），
因此先以 60 MHz 保证时序收敛；后续如需更高主频，需要给取数/分支预测路径加流水级，而不是放宽约束。

## 设计概览

| 资源 | 移植版实现 |
|---|---|
| FPGA | xc7a100tcsg324-1（Nexys A7-100T / Nexys 4 DDR） |
| 系统时钟 | 100 MHz 输入 → MMCM（VCO 1200 MHz）→ 50 MHz 系统 / 60 MHz CPU / 25 MHz 像素 / 200 MHz MIG 参考 |
| DDR 存储 | 板载 MT47H64M16HR-25E，DDR2-667，16 bit，128 MiB，MIG 4:1（ui_clk 75 MHz） |
| 显示 | VGA 640×480@60 扫描，中央 480×272 图像区，RGB444 |
| 摄像头 | AF-OV5640-U1.0，JA/JB，25 MHz XCLK，SCCB 配置，320×240 RGB565 DVP |
| OLED | Digilent Pmod OLED RGB，JC，SSD1331 SPI，96×64，显示色条或 80×60 实时预览 |
| 舵机 | 7 路 50 Hz PWM，接 JD |
| 调试 | 115200 8N1 UART、16 个 LED |
| 启动 | 片内 64 KiB 指令 ROM + 16 KiB 数据 RAM，模型仍在片上 ROM |

CPU、NPU、摄像头采集、帧缓存、视频桥、应用逻辑均直接复用原工程的 Verilog；移植层只新增：

- `rtl/nexys_clocks.v`：MMCM 时钟树。
- `rtl/nexys_ddr2*.v`：MIG 原生接口、跨时钟桥、上电 BIST、字节掩码/突发处理。
- `rtl/top_nexys_a7_vision.v`：板级顶层。
- `rtl/nexys_ov5640.v`、`rtl/nexys_oled_rgb.v`：摄像头初始化和 OLED 预览。
- `nexys_a7.xdc`：Nexys A7 管脚与时序约束。
- `ip/mig.prj`：与官方 Nexys 4 DDR OOB 工程**逐字节一致**的 MIG 配置。

## 目录

```
fpga_nexys_a7/
├─ build.tcl / build.ps1      # Vivado 工程生成与构建
├─ nexys_a7.xdc               # 管脚、时钟、IO 约束
├─ ip/mig.prj                 # DDR2 MIG 配置
├─ rtl/                       # 板级顶层、时钟、DDR2 桥、BIST
├─ sim/                       # Verilog .v 仿真，含摄像头 → OLED、DDR2、CPU 和 VGA
├─ tools/prepare.py           # 复制 RTL、编译固件、生成 HEX 与构建清单
├─ tools/verify.py            # 一键跑三套仿真
├─ tools/summarize.py         # 汇总时序/资源/DRC/位流
├─ build/vision/              # 构建产物（.gitignore）
└─ validation/                # 仿真与实现日志（.gitignore）
```

## 构建

依赖：

- Vivado 2018.3（`build.ps1` 默认 `E:\Vivado\2018.3`，可用 `-VivadoHome` 改）。
- Python 3。
- RISC-V GCC：默认
  `%LOCALAPPDATA%\CodexFPGA\tools\xpack-riscv-none-elf-gcc-15.2.0-1\bin`，
  可用 `-GccBin` 指定。

```powershell
# 完整构建：准备 → 综合 → 实现 → 时序/DRC → 位流 → SPI Flash bin
powershell -ExecutionPolicy Bypass -File fpga_nexys_a7\build.ps1

# 只生成工程（用于打开 Vivado GUI）
powershell -ExecutionPolicy Bypass -File fpga_nexys_a7\build.ps1 -ProjectOnly

# 只到综合
powershell -ExecutionPolicy Bypass -File fpga_nexys_a7\build.ps1 -SynthesisOnly

# 上电 BIST 遍历完整 128 MiB（默认只测前 1024 个字，节省上电时间）
powershell -ExecutionPolicy Bypass -File fpga_nexys_a7\build.ps1 -FullMemoryTest
```

产物位于 `build/vision/`：

- `top_nexys_a7_vision.bit`：JTAG 下载位流。
- `top_nexys_a7_vision.bin`：16 MiB QSPI Flash 镜像（SPIx4）。
- `routed.dcp`、`reports/{timing,utilization,drc,cdc}.rpt`。
- `build_summary.json`：时序、资源、DRC、位流 SHA256 汇总。

> Vivado 的自动层级分析会启动子进程；请在普通 PowerShell 中运行，不要在受限沙箱中运行，
> 否则会出现 “Could not find a top module in the fileset sources_1”。

## 管脚与接线

### AF-OV5640-U1.0 摄像头（JA/JB）

面对照片中的镜头，左排针插 JB，右排针插 JA。丝印靠镜头的一行为 Pmod 1–6，另一行为 7–12。管脚按照片丝印、Nexys 4 DDR 原理图与 Nexys A7-100T Master XDC 核对。

| 信号 | Pmod | FPGA | 说明 |
|---|---|---|---|
| cam_sda | JA1 | C17 | SDA |
| cam_reset_n | JA2 | D18 | RST，低有效 |
| cam_href | JA3 | E18 | HRE，行有效 |
| cam_xclk | JA4 | G17 | XCK，25 MHz 输出 |
| cam_scl | JA7 | D17 | SCL |
| cam_vsync | JA8 | E17 | VSY，场同步 |
| cam_pwdn | JA9 | F18 | PWD，高有效掉电，正常运行时为低 |
| cam_data[7] | JA10 | G18 | D7 |
| cam_data[5] | JB1 | D14 | D5 |
| cam_data[4] | JB2 | F16 | D4 |
| cam_data[3] | JB3 | G16 | D3 |
| cam_data[2] | JB4 | H14 | D2 |
| cam_data[6] | JB7 | E16 | D6 |
| cam_pclk | JB8 | F13 | PCK，像素时钟输入 |
| cam_data[0] | JB9 | G13 | D0 |
| cam_data[1] | JB10 | H16 | D1 |

SCCB 使用 7 位地址 `0x3C`，读回 `0x300A/0x300B` 为 `0x5640` 后配置 DVP。采集模块把 320×240 RGB565 下采样为 160×120，提供给原有视觉链。

### Digilent Pmod OLED RGB（JC）

| OLED 信号 | Pmod | FPGA |
|---|---|---|
| CS# | JC1 | K1 |
| MOSI | JC2 | F6 |
| SCK | JC4 | G6 |
| D/C | JC7 | E7 |
| RES# | JC8 | J3 |
| VCCEN | JC9 | J4 |
| PMODEN | JC10 | E6 |

屏幕通过 SPI 模式 3 接收 RGB565。等待完整相机帧时显示色条，收到完整帧后显示居中的 80×60 预览。VGA 显示识别叠加结果。

### 舵机（JD）

| 通道 | 功能 | Pmod | FPGA |
|---|---|---|---|
| servo_pwm[0] | 每 5 s 下料 | JD1 | H4 |
| servo_pwm[1] | 绿色舱门 | JD2 | H1 |
| servo_pwm[2] | 黄色舱门 | JD3 | G1 |
| servo_pwm[3] | 红色舱门 | JD4 | G3 |
| servo_pwm[4] | 预留 | JD7 | H2 |
| servo_pwm[5] | 预留 | JD8 | G4 |
| servo_pwm[6] | 预留 | JD9 | G2 |

PWM 50 Hz，回位 1500 µs，动作 2000 µs。舵机必须用独立 5 V 电源并共地；JD 只输出 3.3 V 信号，
不要用 JD 的 VCC 给舵机供电。

### 按键与复位

| 板上按键 | FPGA | 端口 | 功能 |
|---|---|---|---|
| CPU_RESETN | C12 | reset_n | 系统复位（低有效） |
| BTNC | N17 | buttons[0] | CoreMark |
| BTNL | P17 | buttons[1] | 瓶盖模式 |
| BTNR | M17 | buttons[2] | 手势模式 |
| BTND | P18 | buttons[3] | 下一个手势目标 |
| BTNU | M18 | — | 未使用 |

### VGA / UART / LED

- VGA：R=A3/B4/C5/A4，G=C6/A5/B6/A6，B=B7/C7/D7/D8，HS=B11，VS=B12（标准 Nexys VGA 口）。
- UART：RXD=C4，TXD=D4（板载 FTDI，115200 8N1）。
- LED[0]：50 MHz 心跳；LED[1]：DDR2 初始化完成；LED[2]：BIST 通过；LED[3]：存储器故障；
  LED[4]：DDR 端口故障；LED[5]：BIST 忙；LED[6]：推理忙；LED[7]：摄像头配置成功；
  LED[8]：摄像头配置失败；LED[9]：CPU 非法指令；LED[10]：CoreMark 完成；LED[11]：已采到完整相机帧；LED[15:12] 保留。

## 上板使用

1. 将显示器的 VGA 输入接到开发板 VGA 口，并将显示器输入源切到 VGA（PC 或 D-Sub）。连接 USB-JTAG/UART、摄像头和 OLED。使用舵机时接好舵机电源与信号。
2. 在 Hardware Manager 下载 `top_nexys_a7_vision.bit`。同一摄像头同时向 JC OLED 和 VGA 输出实时画面，VGA 还显示识别状态。
3. 串口 115200 应看到：

   ```
   VISION SOC READY
   CPU_HZ=03938700
   DDR2 STATUS=...
   VISION S=... MODE=... READY=... COUNT=... NN=... NPU=... DEC=... PWM=... FEED=...
   ```

4. 串口命令：`k` CoreMark，`p` 瓶盖，`g` 手势，`m` 切换模式，`d` 输出一帧，
   `t` DDR2 CPU 读写自检，`?` 立即打印状态，`q` 清统计。
5. 上电默认进入瓶盖模式（与原工程一致，由 `available_models` 决定）。

固件启动横幅中的 SW2/SW4/SW5/SW6 是原板的操作提示。Nexys A7 的实际控制见上方按键表。

## 验证

```powershell
python fpga_nexys_a7\tools\verify.py
```

四套 Verilog 仿真使用移植后的 RTL，DDR2 使用 MIG 原生接口行为模型。

- `tb_ddr2`：校准门控、边界 BIST、容量/越界拒绝、64 种字节掩码、5 类故障注入、校准丢失。
- `tb_video`：VGA 800×525 与原始 LCD 525×286 两种时序、480×272 有效区。
- `tb_camera_oled`：用 SCCB 和 DVP 模型检查芯片 ID、错误应答、QVGA RGB565 采集、OLED 上电和 SPI 色条及预览的逐像素输出。
- `tb_ddr2_cpu`：真实 RV32 指令流经 CPU、缓存、跨时钟桥访问 DDR2，校验结果 `600d600d`。

最新结果见 `validation/simulation_summary.json`；已下载的整机版实现结果见 `build/vision_models/build_summary.json`。

## 与原 PG2L100H 工程的差异

| 项 | PG2L100H | Nexys A7 移植 |
|---|---|---|
| CPU 时钟 | 90 MHz | 60 MHz（Artix-7-1 时序收敛） |
| 内存 | 1 GiB DDR3 | 128 MiB DDR2 |
| 显示 | 24-bit LCD + 触摸 | VGA RGB444 + JC OLED RGB |
| 舵机接口 | J12 | JD |
| 摄像头接口 | J7 | JA + JB，AF-OV5640-U1.0 |
| 构建 | Pango PDS | Vivado 2018.3 |

实板 VGA 显示、舵机动作及正式 CoreMark 成绩尚待验收。VGA 的 480×272 图像区域居中显示在 640×480@60 画面内。

## 许可证与来源

移植层复用仓库内原工程的 RTL 与固件，版权与许可沿用仓库根目录说明。DDR2 MIG 配置来自
Digilent Nexys 4 DDR OOB 工程（`板载初始程序`），仅用于本板。
