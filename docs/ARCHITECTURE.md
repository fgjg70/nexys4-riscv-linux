# 系统架构与演进路线（Nexys 4 DDR）

> 状态：项目立项规划草案（详细地址映射、JA+JB Pmod OV5640 引脚表与时钟树待下一轮细化定稿）。
> 语言约束：**全工程统一使用纯 Verilog-2001/2005（`.v` + `.vh`）**，杜绝 SystemVerilog 语法，确保 Vivado / ModelSim / Icarus / Verilator 跨工具无障碍编译与综合。

---

## 1. 目标硬件平台

| 资源 | 规格（Digilent Nexys 4 DDR） |
|---|---|
| FPGA | Artix-7 `xc7a100tcsg324-1`（63,400 LUT / 126,800 FF / 135 BRAM36 / 240 DSP48E1） |
| 主时钟 | 100 MHz（`E3`） |
| 外置主存 | **128 MB DDR2**（`MT47H64M16HR-25:H`，Vivado MIG 7 Series + 200 MHz 参考时钟） |
| 显示接口 | 板载 **12-bit VGA**（`VGA_R[3:0]`, `VGA_G[3:0]`, `VGA_B[3:0]`, `VGA_HS`, `VGA_VS`，640×480@60 Hz / 25 MHz） |
| 摄像头接口 | **Pmod OV5640** 接 **`JA + JB`**（双 Pmod，24 MHz `XCLK`，16-bit SCCB `0x3C`，`cam_pclk` 异步 FIFO 采集） |
| 串口与存储 | USB-UART（FT2232HQ）、microSD 卡槽（SPI 模式 `mmc_spi`）、16 MB QSPI Flash（`S25FL128S`） |

---

## 2. 为什么坚持「单发射高主频 + 先 A 后 B」

1. **单发射优于顺序双发射**：在 FPGA 布线受限且面向 Linux 访存/分支密集型负载的条件下，单发射核主频更高、面积省一半、MMU/Cache 精确异常验证复杂度远低于顺序双发射。
2. **路线 A → 路线 B 防返工约束（做 A 时同步落实）**：
   - **I/D-Cache 按 4 KB/路设计**（如 4 KB 直接映射或 8 KB 2 路组相联），索引落在 4 KB 页内偏移 `addr[11:0]` 内，升 B 加 Sv32 TLB 时天然 VIPT 无别名；
   - **IF / LSU 统一走 `valid/ready + fault` 握手**，B 阶段直接在核与 Cache 之间插入 TLB/PTW；
   - **BTB 补齐完整 32 位高位 Tag 并引出 `flush_all`**（A 接 `FENCE.I`，B 追加 `SFENCE.VMA`）；
   - **RV32A `res_valid` 在 Trap / `MRET` 时清零**（已在基线 `rtl/cpu/load_store_unit.v` 中落地）；
   - **外设直接采用标准寄存器布局**：标准 CLINT + 最小 PLIC + NS16550A UART + SPI microSD，CSR 严格报非法指令异常。
3. **可选 `DIV_RADIX4` 宏**：基-4 除法器（32→16 步，仅 +112 LUT / +33 FF 且不进关键路径）已保留在 `rtl/cpu/muldiv.v` 中；前期关闭保持基线干净，Linux 跑稳后可一键开启实测时序收益。

---

## 3. 分阶段里程碑（草案）

- **Stage 0（已完成）**：`D:\Workspace\digital` 独立新工程、单发射 RV32IMA 基底迁移、全量手工重构为纯 Verilog-2001/2005（`.v`/`.vh`）并通过 16/16 非 `-sv` 回归。
- **Stage 1（外设最小环 / 仿真起步，可并行）**：
  - 板级环：Nexys 4 DDR 顶层 + XDC + **VGA 640×480 彩条** + **JA+JB Pmod OV5640 → VGA 实时画面** + **MIG 128 MB DDR2 压测**。
  - 核级环（路线 A1）：重构单发射核取指/访存总线 + 4 KB/路 I/D-Cache + 真 `FENCE.I` + BTB 扩 Tag + `Zicntr` + 标准 CLINT/PLIC/16550，在 Verilator 挂 32 MB 行为 RAM 跑通 `riscv-tests` 与 **nommu Linux (`CONFIG_MMU=n`, `CONFIG_RISCV_M_MODE=y`)** 进 BusyBox shell。
- **Stage 2（路线 A2 上板）**：把 Stage 1 的核接入 MIG DDR2 + BootROM + microSD/UART，在 Nexys 4 DDR 实板上点亮 nommu Linux，并将 VGA / OV5640 挂载为外设。
- **Stage 3（路线 B 升级完整 Linux）**：在稳定 A 核上增量补齐 S/U 特权级、S-CSR/委托、`SRET`/`SFENCE.VMA` 与 Sv32 MMU（ITLB/DTLB + 两级硬件 PTW），跑通 OpenSBI + 标准 MMU Linux（支持 `fork`/`mmap` 与标准 ELF 生态）。
- **Stage 4（可选扩展）**：按需将上游 `feat/ai-accel` 的 128-MAC NPU 引擎接入 DDR2 DMA + Linux 字符设备驱动。
