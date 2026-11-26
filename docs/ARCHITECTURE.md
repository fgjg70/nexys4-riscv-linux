# 系统架构与演进路线（Nexys 4 DDR）

> 语言约束：**全工程 100% 纯 Verilog-2001/2005（`.v` + `.vh`）**，杜绝 SystemVerilog 语法，确保 Vivado / ModelSim / Icarus / Verilator 跨工具无障碍编译与综合。

---

## 1. 目标硬件平台

| 资源 | 规格（Digilent Nexys 4 DDR） |
|---|---|
| FPGA | Artix-7 `xc7a100tcsg324-1`（63,400 LUT / 126,800 FF / 135 BRAM36 / 240 DSP48E1） |
| 主时钟 | 100 MHz（`E3`）→ `clk_wiz_0`（VCO=1200 MHz 整数分频）生成 **100 MHz（SoC 主时钟）**、200 MHz（MIG）、25 MHz（VGA）、24 MHz（OV5640 XCLK） |
| 外置主存 | **128 MB DDR2**（`MT47H64M16HR-25E`，Vivado MIG 7 Series 4:1 PHY，`ui_clk = 75 MHz`，经 `mig_ddr2_bridge` 128-bit 双异步 FIFO 与 100 MHz SoC 解耦） |
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
   - **I/D-Cache 按 4 KB/路（8 KB 2 路 VIPT）+ 256 B 0 拍直写 L0D 设计**：I-Cache 采用 64 组 × 64 B × 2 路（`addr[11:6]` 页内索引 + 21-bit 单级 `RAM64M` `{valid, tag}`），D-Cache 采用 128 组 × 32 B × 2 路（`addr[11:5]` 页内索引，全部严格落在 4 KB 页内偏移内，后续接入 Sv32 TLB 时天然 VIPT 无别名）；每路 `data_ram` 采用独立无复位块推断为 `RAMB36E1`（I/D 共 4×`RAMB36E1`），L0D 为 64 字单级原生 `RAM64M` 异步读/WB 提交直写，将 Load-Use 从 2 拍砍为 1 拍（`dist=2` 零气泡）；
   - **IF / LSU 统一走多周期握手与精确故障信号**，B 阶段可直接在核与 Cache 间插入 ITLB/DTLB + PTW；
   - **混合 RAM 分支预测套件**：128 项分布式 RAM 全 32-bit Tag Taken-Only BTB + **8,192 项单块 `RAMB18E1` 同步 Bimodal BHT**（由 `pc_next` 提前一拍预读、停顿由 `pred_en = rst || !pc_hold_sel` 锁定，零额外延迟且随流水线透传 `pred_ctr` 根除 stall 污染）+ 默认启用 16 项循环 RAS + `flush_all`（A 接 `FENCE.I`，B 追加 `SFENCE.VMA`）；
   - **RV32A `res_valid` 在 Trap / `MRET` 及同址普通写时清零**；
   - **外设严格采用 Linux 主线标准寄存器布局**：CLINT + PLIC + NS16550A + SPI Mode 0 microSD。
3. **可选 `DIV_RADIX4` 宏**：基-4 除法器（32→16 步）已保留在 `rtl/cpu/muldiv.v` 中，24/24 双模式回归均通过。

---

## 4. Vivado `xc7a100tcsg324-1` 实测与时序演进

| 迭代轮次 | 优化措施 | LUT | FF | BRAM36 Tile | DSP48 | Post-Route `sys_clk` |
|---|---|---|---|---|---|---|
| 首轮基线 | 修复 `icache`/`dcache`/`async_fifo` 独立无复位 BRAM 推断 | 6,304 (9.94%) | 3,908 | 9 (6.67%) | 8 | 54.4 MHz |
| 二轮优化 | `dcache`/`icache` Tag 改分布式 RAM + MEM 拍预计算 `q_hit_r` | 6,340 (10.00%) | 3,949 | 8 (5.93%) | 8 | 56.5 MHz |
| 三轮优化 | `plic.irq_ext` 与 `clint.irq_timer` 增加 1 拍输出寄存器 | 6,342 (10.00%) | 3,951 | 8 (5.93%) | 8 | 67.6 MHz |
| 四轮基线 (`a957b1a`) | 精简 `fwd_wb_data` + 低 2 位 `insn_misalign` + 预计算 `irq_vector` | 6,358 (10.03%) | 3,951 (3.12%) | 8 (5.93%) | 8 (3.33%) | 79.05 MHz |
| 第一轮单模块审计 | 统一 33×33 乘法器（DSP 减半）、ALU/分支共享比较器、16 项循环 RAS、NS16550A `thre_ip`、全 CDC `ASYNC_REG`、`ODDR` `CAM_XCLK` | 6,132 (9.67%) | 3,917 (3.09%) | 8 (5.93%) | **4 (1.67%)** | 77.72 MHz |
| 第二轮全路径优化 (`e806489`, Vivado 2018.3) | BTB 元数据打包 `RAMB18E1` + 后台清零、EX 归并 `WB_PC4`、I-Cache 直出 `data_q` + `q_cacheable_r`、分支非对齐/非法 1 拍寄存陷阱、7-bit `id_sys_stall`、`hazard_unit` 末级门控、`mig_ddr2_bridge` 128-bit 读行缓冲 | 5,742 (9.06%) | 3,427 (2.70%) | 8 (5.93%) | 4 (1.67%) | 93.36 MHz |
| 第三轮微架构升级 (Vivado 2023.2) | 128 项分布式 RAM Taken-Only BTB + 512 项 Bimodal + 默认 16 项 RAS、8 KB 2 路 VIPT I/D-Cache、256 B 单级 `RAM64M` 0 拍直写 L0D（Load-Use 2→1 拍）、LSU 拆分尾址寄存化、`id_ex_reg` 控制/数据 CE 解耦、PLIC 3 级平衡锦标赛树 | 8,322 (13.13%) | 4,265 (3.36%) | 8.5 (6.30%) | 4 (1.67%) | 90.60 MHz（`soc_test` 84,878 周期） |
| **第四轮 100 MHz 突破 + 8K BRAM BHT + 异频 DDR2 解耦 (Vivado 2023.2)** | **I-Cache 64 组×64 B (`RAM64M` 21b `{vld,tag}` + `S_FLUSH` + 单级 LUT5 `ibus_rdata`)、`dcache` 纯 FF `dbus_stall_r`/`dbus_fault_r` + 移除 `wb_fault`/`mem_fault` 冗余 `!dbus_stall`、8,192 项单 `RAMB18E1` 同步 Bimodal BHT (`pc_next` 预读)、`u_ras` 剥离条件分支比较器、`id_ex_reg` 272-bit CE 拆扇出、`mig_ddr2_bridge` 100↔75 MHz 128-bit 双异步 FIFO + Posted Write** | 7,315 (11.54%) | 3,943 (3.11%) | 9.0 (6.67%) | 4 (1.67%) | 100.52 MHz（`WNS = +0.052 ns`, `TNS = 0`） |
| **第五轮 路线 B（M/S/U + Sv32 MMU + PLIC Ctx1 + Linux 引导栈, Vivado 2023.2）** | **完整 M/S/U 三态 + `medeleg`/`mideleg` + S-CSR + `SRET`/`SFENCE.VMA` + PLIC Context 1 + `sv32_mmu`（双侧 1 uTLB + 8 全相联主 TLB，4 KB/4 MB 巨页 + D-Cache 脏行一致性硬件 PTW）+ 物理标签 VIPT I$/D$/L0D；关键时序剪枝：`S_PTW_LK` 物理重查、`i_xlate_en_r` 寄存态 + I$ 21b/11b 含有效位并行 CARRY4 比较器 + 5-bit `id_is_sys_opc` + `ex_illegal` 统一经 1 拍 `ex_pend_trap_r` 交付** | **9,054 (14.28%)** | **5,255 (4.14%, 0 Latch)** | **9.0 (6.67%)**（+桥 4.5 = 13.5） | **4 (1.67%)** | **100.43 MHz**（OOC **`WNS = +0.043 ns`, `TNS = 0`**, `0/14,301` 违例；全芯片真 IP Linux 比特流 **`WNS = +0.170 ns` (101.73 MHz), `WHS = +0.032 ns`, `0/30,275` 违例, `0 DRC Errors`**） |

完整五轮设计空间评估、缺陷修复与关键路径剖析详见 [docs/AUDIT_OPTIMIZATION.md](AUDIT_OPTIMIZATION.md)。

---

## 5. 分阶段里程碑（进展跟踪）

- **Stage 0（已完成）**：独立新工程、单发射 RV32IMA 基底迁移、全量手工重构为纯 Verilog-2001/2005。
- **Stage 1A（已完成）**：总线解耦单发射核 `rv32_cpu.v`（32 位全地址 BTB + `flush_all`、`Zicntr`、`WFI`、真 `FENCE.I`、向量化 `mtvec`、精确总线异常）+ VIPT `icache`/`dcache` + `soc_bus`/`bootrom`/`clint`/`plic`/`uart_16550`。
- **Stage 2 硬件环（已完成）**：`async_fifo`、`spi_master`、`vga_ctrl`、`ov5640_sccb`、`ov5640_capture`、`mig_ddr2_bridge`（100↔75 MHz 128-bit 异步 FIFO 桥）、Nexys 4 DDR 工程脚本及 `board_bist.hex` 上电自检比特流。
- **Stage 3 路线 B：M/S/U + Sv32 MMU + Linux 引导栈（代码与比特流签核已完成）**：
  - **Phase D1（M/S/U + 委托 + PLIC Ctx1）**：`csr_file.v` / `rv32_cpu.v` / `control_unit.v` / `plic.v` 完整支持 M/S/U 特权级、S-CSR、`medeleg`/`mideleg`、`SRET`/`SFENCE.VMA`、PLIC Context 1（S-mode 外部中断 `irq_sext`）与 Spec §3.1.9 中断优先级；新增 `tb_soc_priv_s` 回归。
  - **Phase D2（Sv32 MMU + 100 MHz 时序闭环）**：新增 `rtl/soc/sv32_mmu.v`，升级 `icache.v` / `dcache.v`（含 256 B L0D）全物理标签零虚拟别名与脏行一致性硬件 PTW，支持 4 KB 普通页 / 4 MB 巨页、SUM/MXR/MPRV、软件 A/D 缺页（Cause 12/13/15）；新增 8 项综合压测 `tb_soc_sv32`；30/30 双模式回归通过，`rv32_soc` OOC 实测 **100.43 MHz (`WNS = +0.043 ns`)**，`tb_linux_soc` 保持 `85,497` 周期 0 退化。
  - **Phase C（Linux BootROM + DTS + 构建打包套件）**：完成 16 KB `sw/bootrom_linux/bootrom_linux.hex`（SPI Mode 0 microSD `NX4L` + USB-UART `NX4U` 双模加载，按 `a0=0, a1=dtb` 跳转内核/OpenSBI）、真实 SPI SDHC 行为模型端到端仿真 `tb_bootrom_linux`、标准 Sv32/nommu 设备树与构建/打包脚本（`sw/linux/*`），并完成全芯片真 IP Linux 比特流签核（`WNS = +0.170 ns`, `0 DRC Errors`）。
- **Stage 4 实板联合调试（由协作者在 Nexys 4 DDR 上板推进）**：
  - 烧录 `bist` 与 `linux` 比特流验证 DDR2 / VGA / UART / microSD / OV5640 实板通路；
  - 在 Linux 宿主机运行 `sw/linux/build_linux.sh` 构建 OpenSBI + Sv32 Linux v6.x + BusyBox 根文件系统，写入 microSD 或经 `send_uart.py` 串口下载点亮完整 Linux Shell。
