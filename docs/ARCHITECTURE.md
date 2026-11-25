# 系统架构与演进路线（Nexys 4 DDR）

> 语言约束：**全工程 100% 纯 Verilog-2001/2005（`.v` + `.vh`）**，杜绝 SystemVerilog 语法，确保 Vivado / ModelSim / Icarus / Verilator 跨工具无障碍编译与综合。

---

## 1. 目标硬件平台

| 资源 | 规格（Digilent Nexys 4 DDR） |
|---|---|
| FPGA | Artix-7 `xc7a100tcsg324-1`（63,400 LUT / 126,800 FF / 135 BRAM36 / 240 DSP48E1） |
| 主时钟 | 100 MHz（`E3`）→ `clk_wiz_0` 生成 200 MHz（MIG）、25 MHz（VGA）、24 MHz（OV5640 XCLK） |
| 外置主存 | **128 MB DDR2**（`MT47H64M16HR-25E`，Vivado MIG 7 Series 4:1 PHY，`ui_clk = 75 MHz`，128-bit Native） |
| 显示接口 | 板载 **12-bit VGA**（`VGA_R[3:0]`, `VGA_G[3:0]`, `VGA_B[3:0]`, `VGA_HS`, `VGA_VS`，640×480@60 Hz） |
| 摄像头接口 | **Pmod OV5640** 接 **`JA + JB`**（24 MHz `XCLK`，16-bit SCCB `0x3C`，`cam_pclk` 格雷码 `async_fifo` 采集） |
| 串口与存储 | USB-UART（FT2232HQ，`C4`/`D4`）、microSD 卡槽（SPI Mode 0：`E2`/`A1`/`B1`/`C1`/`C2`/`D2`） |

---

## 2. 双 Pmod (`JA + JB`) OV5640 引脚默认分配

> 引脚严格核对自 Digilent 官方 `Nexys-A7-100T-Master.xdc`（与 Nexys 4 DDR 兼容）；烧录前请对照实际转接板线序核对 `fpga/nexys4_ddr/nexys4_ddr.xdc`。

| Pmod 脚位 | FPGA 引脚 | 信号 | 说明 |
|---|---|---|---|
| `JA[1..4]` | `C17, D18, E18, G17` | `CAM_D[0..3]` | DVP 8-bit 像素数据低 4 位 |
| `JA[7..10]` | `D17, E17, F18, G18` | `CAM_D[4..7]` | DVP 8-bit 像素数据高 4 位 |
| `JB[1]` | `D14` | `CAM_VSYNC` | 帧同步输入 |
| `JB[2]` | `F16` | `CAM_HREF` | 行有效输入 |
| `JB[3]` | `G16` (**MRCC**) | `CAM_PCLK` | 像素时钟输入（选时钟专用脚） |
| `JB[4]` | `H14` | `CAM_XCLK` | 24 MHz 时钟输出至 OV5640 |
| `JB[7]` | `E16` | `CAM_SIOC` | SCCB 时钟输出 |
| `JB[8]` | `F13` (`PULLUP`) | `CAM_SIOD` | SCCB 开漏双向数据线 |
| `JB[9]` | `G13` | `CAM_RST_N` | 摄像头复位输出（低有效） |
| `JB[10]` | `H16` | `CAM_PWDN` | 摄像头低功耗控制输出 |

---

## 3. 为什么坚持「单发射高主频 + 先 A 后 B」

1. **单发射优于顺序双发射**：在 FPGA 布线受限且面向 Linux 访存/分支密集型负载的条件下，单发射核主频更高、面积更小、MMU/Cache 精确异常验证复杂度远低于顺序双发射。
2. **路线 A → 路线 B 防返工约束（已全部在硬件中落地）**：
   - **I/D-Cache 按 4 KB/路设计**：索引 `addr[11:5]` 严格位于 4 KB 页内偏移内，后续接入 Sv32 TLB 时天然 VIPT 无别名；`data_ram` 采用独立无复位块推断为 `RAMB36E1`，`tag_ram` 采用分布式 RAM 预计算 `q_hit_r` 消除关键路径；
   - **IF / LSU 统一走多周期握手与精确故障信号**，B 阶段可直接在核与 Cache 间插入 ITLB/DTLB + PTW；
   - **BTB 补齐完整 32 位高位 Tag 并引出单拍 `flush_all`**（A 接 `FENCE.I`，B 追加 `SFENCE.VMA`）；
   - **RV32A `res_valid` 在 Trap / `MRET` 及同址普通写时清零**；
   - **外设严格采用 Linux 主线标准寄存器布局**：CLINT + PLIC + NS16550A + SPI Mode 0 microSD。
3. **可选 `DIV_RADIX4` 宏**：基-4 除法器（32→16 步）已保留在 `rtl/cpu/muldiv.v` 中，24/24 双模式回归均通过。

---

## 4. Vivado 2018.3 `xc7a100tcsg324-1` 实测与时序演进

| 迭代轮次 | 优化措施 | LUT | FF | BRAM36 Tile | DSP48 | Post-Route `sys_clk` |
|---|---|---|---|---|---|---|
| 首轮基线 | 修复 `icache`/`dcache`/`async_fifo` 独立无复位 BRAM 推断 | 6,304 (9.94%) | 3,908 | 9 (6.67%) | 8 | 54.4 MHz |
| 二轮优化 | `dcache`/`icache` Tag 改分布式 RAM + MEM 拍预计算 `q_hit_r` | 6,340 (10.00%) | 3,949 | 8 (5.93%) | 8 | 56.5 MHz |
| 三轮优化 | `plic.irq_ext` 与 `clint.irq_timer` 增加 1 拍输出寄存器 | 6,342 (10.00%) | 3,951 | 8 (5.93%) | 8 | 67.6 MHz |
| 四轮基线 (`a957b1a`) | 精简 `fwd_wb_data` + 低 2 位 `insn_misalign` + 预计算 `irq_vector` | 6,358 (10.03%) | 3,951 (3.12%) | 8 (5.93%) | 8 (3.33%) | 79.05 MHz |
| 第一轮单模块审计 | 统一 33×33 乘法器（DSP 减半）、ALU/分支共享比较器、16 项循环 RAS、NS16550A `thre_ip`、全 CDC `ASYNC_REG`、`ODDR` `CAM_XCLK` | 6,132 (9.67%) | 3,917 (3.09%) | 8 (5.93%) | **4 (1.67%)** | 77.72 MHz |
| **第二轮全路径优化** | **BTB 元数据打包 `RAMB18E1` + 后台清零、EX 归并 `WB_PC4`、I-Cache 直出 `data_q` + `q_cacheable_r`、分支非对齐/非法 1 拍寄存陷阱、7-bit `id_sys_stall`、`hazard_unit` 末级门控、`mig_ddr2_bridge` 128-bit 读行缓冲** | **5,742 (9.06%)** | **3,427 (2.70%)** | **8 (5.93%)** | **4 (1.67%)** | **93.36 MHz**（相对 MIG 75 MHz **+2.622 ns** 正裕量） |

完整两轮设计空间评估、缺陷修复与六大路径剖析详见 [docs/AUDIT_OPTIMIZATION.md](AUDIT_OPTIMIZATION.md)。

---

## 5. 分阶段里程碑（进展跟踪）

- **Stage 0（已完成）**：`D:\Workspace\digital` 独立新工程、单发射 RV32IMA 基底迁移、全量手工重构为纯 Verilog-2001/2005。
- **Stage 1A（已完成）**：总线解耦单发射核 `rv32_cpu.v`（32 位全地址 BTB + `flush_all`、`Zicntr`、`WFI`、真 `FENCE.I`、向量化 `mtvec`、精确总线异常）+ 4 KB VIPT `icache`/`dcache` + `soc_bus`/`bootrom`/`clint`/`plic`/`uart_16550` + 4 处边界缺陷修复。
- **Stage 2 硬件环（已完成）**：
  - 完整实现并集成 `async_fifo`、`spi_master`（microSD）、`vga_ctrl`（640×480@60Hz 12-bit）、`ov5640_sccb`（16-bit 寄存器地址）、`ov5640_capture`（真实异步 `cam_pclk` RGB565 采集）与 `mig_ddr2_bridge`（128-bit Native MIG 桥）；
  - 完成 Nexys 4 DDR 实板工程文件（`top_nexys4_ddr.v`、`nexys4_ddr.xdc`、`mig.prj`、`build_project.tcl`、`synth_ooc.tcl`）；
  - ModelSim **24/24** 严格纯 Verilog 回归通过（含 `tb_periph_stage2` 全外设、MIG 4× 读行缓冲与随机反压压测）、Vivado `xvlog` 全量 0 报错；完成**两轮全局审计与全路径优化**（[docs/AUDIT_OPTIMIZATION.md](AUDIT_OPTIMIZATION.md)），Vivado 2018.3 `xc7a100t-1` 布局布线实测 **93.36 MHz** / **5,742 LUT** / **3,427 FF** / **4 DSP48E1**（覆盖 MIG 75 MHz 留有 +2.622 ns 正裕量）。
- **Stage 2 软件/实板环（下一步）**：
  - 在 Vivado 运行 `build_project.tcl` 生成比特流实板点亮 VGA 彩条 + UART 控制台 + microSD SPI 读卡 + DDR2 压测；
  - 编译并引导 **nommu Linux (`CONFIG_MMU=n`, `CONFIG_RISCV_M_MODE=y`)** + BusyBox shell，扩展 VGA 帧缓冲 DMA / OV5640→VGA 实时预览通路。
- **Stage 3（路线 B 升级完整 Linux）**：补齐 S/U 特权级、S-CSR/委托、`SRET`/`SFENCE.VMA` 与 Sv32 MMU（ITLB/DTLB + 两级硬件 PTW），跑通 OpenSBI + 标准 MMU Linux。
