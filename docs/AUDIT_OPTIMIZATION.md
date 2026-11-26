# 五轮全局审计与系统优化报告（纯 Verilog-2001/2005）

> **目标平台**：Digilent Nexys 4 DDR（Artix-7 `xc7a100tcsg324-1`，MIG 7 Series DDR2 `ui_clk = 75.0 MHz`）
> **基线提交**：`a957b1a`（Stage 2 完整外设基线：`6,358 LUT` / `3,951 FF` / `8 BRAM36` / `8 DSP48E1` / `79.05 MHz`）
> **验证标准**：ModelSim SE-64 **24/24** 严格纯 Verilog（禁 `-sv`）回归 + Vivado `xvlog` **42/42** 零报错（禁 `--sv`）+ Vivado 2018.3 `xc7a100tcsg324-1` OOC 真实布局布线签核。

---

## 总览：基线 → 第一轮 → 第二轮实测演进

| 指标（Vivado 2018.3 Post-Route `rv32_soc`） | 基线 (`a957b1a`) | 第一轮（自下而上单模块） | 第二轮（全路径跨模块） | 累计净收益 |
|---|---:|---:|---:|---|
| **Slice LUTs**（可用 63,400） | 6,358 (10.03%) | 6,132 (9.67%) | **5,742 (9.06%)** | **-616 LUT (-9.7%)** |
| **Slice Registers / FF**（可用 126,800） | 3,951 (3.12%) | 3,917 (3.09%) | **3,427 (2.70%)** | **-524 FF (-13.3%)，0 Latch** |
| **F7 / F8 Muxes** | 208 / 42 | 208 / 42 | **128 / 8** | **-80 F7 / -34 F8** |
| **Distributed RAM (LUTRAM)** | 232 | 232 | **216** | **-16 LUTRAM** |
| **Block RAM Tile**（可用 135） | 8 (5.93%) | 8 (5.93%) | **8 (5.93%)** | **+0 BRAM**（6×36K + 4×18K） |
| **DSP48E1**（可用 240） | 8 (3.33%) | **4 (1.67%)** | **4 (1.67%)** | **-4 DSP (-50.0%)** |
| **`sys_clk` WNS @ 100 MHz** | -2.650 ns | -2.867 ns | **-0.711 ns** | **+1.939 ns** |
| **`sys_clk` TNS @ 100 MHz** | — | -1,414.9 ns (1,905 ep) | **-18.09 ns (87 ep)** | **-98.7% TNS** |
| **布线后最高主频 `fmax`** | 79.05 MHz | 77.72 MHz | **93.36 MHz** | **+14.31 MHz (+18.1%)** |
| **相对 MIG 75 MHz 裕量** | +0.683 ns | +0.466 ns | **+2.622 ns** | **3.8× 时序裕量** |
| **DDR2 32B Cache 填充突发数** | 8 次 MIG 读 | 8 次 MIG 读 | **2 次 MIG 读** | **~3.5–4× 实板填充提速** |

> 异步域裕量：`cam_pclk`（48 MHz）`+14.595 ns`，`vga_clk`（25 MHz）`+36.010 ns`，保持时间 `WHS = +0.078 ns`（`THS = 0`），`0` 组合环、`0` 锁存器、`0` Critical Warnings。

---

## 第一轮：自下而上逐模块方案评估与优化

逐一审视全部 RTL 模块，对每个核心功能枚举可行硬件实现方案并权衡面积/主频/Linux 规范符合性/跨时钟域安全：

| 模块 | 候选实现方案对比 | 选型与落地改动 |
|---|---|---|
| `rtl/common/async_fifo.v` | A) 无属性普通 FF 同步器；B) 显式 `(* ASYNC_REG = "TRUE" *)` + 溢出脉冲观测；C) Xilinx 原语 `FIFO18E1`（丧失跨工具可移植性） | **选 B**：标注 `rd_gray_sync1/2` 与 `wr_gray_sync1/2` 的 `ASYNC_REG` 供 Vivado 紧邻布局降 MTBF，引出 `wr_ovf_pulse = wr_en && wr_full` 供摄像头诊断丢帧，同时保持 100% 跨工具纯 Verilog 与 BRAM 推断 |
| `rtl/cpu/alu.v` & `rtl/cpu/branch_unit.v` | A) 独立有符号/无符号两套 32-bit 比较器（双 CARRY4 链）；B) 共享单套 32-bit 无符号比较器 + MSB 符号异或修正（`slt = (a[31]^b[31]) ? a[31] : sltu`） | **选 B**：比较器进位链面积直接减半，功能经 `tb_units` 全边界（`INT_MIN`/`INT_MAX`/`-1`/`0`）验证零差异 |
| `rtl/cpu/ras.v` | A) 8 项非循环栈（溢出丢弃，且 `push && pop` 同拍丢失返回地址）；B) 16 项循环栈（环绕 `tos` + 饱和计数）且 `push && pop` 原地替换栈顶 | **选 B**：升级 `DEPTH=16`（覆盖 Linux 内核调用深度），修复 RISC-V Table 2.1 `jalr rd, rs1` 同时 call/ret 协程切换语义缺陷 |
| `rtl/cpu/muldiv.v` | A) 双 32×32 乘法器（`prod_ss` + `prod_uu` = 8×DSP48E1 + 额外 `mulhsu` 加法器）；B) 单一统一有符号 33×33 乘法器（4×DSP48E1，通过符号扩展位统一覆盖 `MUL/MULH/MULHSU/MULHU`）；C) 迭代移位乘法（省 DSP 但 32 拍延迟） | **选 B**：保持精确 2 拍乘法延迟，**DSP48E1 由 8 减半至 4（-50%）**，零附加加法器，完整通过 `tb_core_m_ext` 与 `tb_linux_soc` 双模式验证 |
| `rtl/soc/icache.v` & `rtl/soc/dcache.v` | A) 缺失填充出错时仅跳过 `valid_arr[idx]<=1`（若被驱逐旧行原本 `valid=1` 且 `data_ram` 已被部分覆写，将发生**静默伪命中损坏数据**）；B) 填充结束遇 `mem_err || rf_err` 显式清零 `valid_arr[idx]`（及 `dcache` 的 `dirty_arr[idx]`） | **选 B**：根除总线错误触发的缓存静默数据污染缺陷 |
| `rtl/soc/bootrom.v` | A) `rdata` 含 `or posedge rst`（部分综合器退化为 LUT）；B) `rdata` 置于独立无复位 `always @(posedge clk)` 块 | **选 B**：确保 Vivado / 第三方综合器稳定推断 Block ROM |
| `rtl/periph/uart_16550.v` | A) `tx_irq_req = ier[1] && tx_empty`（Linux `serial8250` 读 `IIR=0xC2` 后中断仍不撤销，触发 **THRE 死循环风暴**）；B) 实现标准 NS16550A `thre_ip` 锁存（TX 变空或 `IER[1]` `0->1` 置位，写 `THR` 或读 `IIR=0xC2` 清除）+ `LSR[1]` Overrun Error + `ASYNC_REG` RX 同步 + 21-bit 波特率计数器 | **选 B**：彻底对齐 Linux 8250 驱动中断模型，同时在 `sw/soc_test/main.c` 新增 `IIR 0xC2 -> 0xC1` 与 `IER[1]` 重触发自检 |
| `rtl/periph/spi_master.v` | A) 直采异步机械卡槽开关 `sd_cd_n`；B) 2 级 `ASYNC_REG` 同步链（`sd_cd_s1/s2`） | **选 B**：消除外部低速插拔引脚亚稳态风险 |
| `rtl/video/vga_ctrl.v` | A) 普通 FF 同步 `vs_tgl`/`reg_en`/`reg_mode`；B) 全量标注 `ASYNC_REG` + 新增 `+0x0C` 只读分辨率标识 `{16'd640, 16'd480}` | **选 B**：加固 `vga_clk <-> sys_clk` CDC 并提供驱动自探测寄存器 |
| `rtl/camera/ov5640_sccb.v` & `ov5640_capture.v` | A) 固定高有效 VSYNC + 固定 RGB565 字节序 + 无溢出诊断；B) 全部外部输入与 CDC 链标注 `ASYNC_REG`，新增 `CTRL[6]=VSYNC_INV`、`CTRL[7]=BYTE_SWAP`、`CTRL[8]=FIFO_CLR`（自清软复位）及 `STAT[5]=FIFO_OVF`（W1C 溢出标志） | **选 B**：兼容市面上全部 OV5640 模组配置，实板调图免改 RTL |
| `fpga/nexys4_ddr/top_nexys4_ddr.v` | A) 24 MHz `CAM_XCLK` 直接连通用 IO 布线（抖动大）；B) 综合时经 Xilinx `ODDR` 时钟转发输出 + 全复位同步链加 `ASYNC_REG` | **选 B**：符合 Artix-7 专用时钟输出规范，降低 OV5640 像素时钟抖动 |

---

## 第二轮：六大端到端系统全路径综合优化

基于第一轮布线后完整时序报告（`vivado_r1_out/timing_impl.rpt`），跨越模块边界审查全部 6 条系统主路径并逐项打破瓶颈：

### 路径 1：CPU 关键时序路径（IF → I-Cache → ID → Hazard → EX → Trap → PC/BTB）

逐层剥离实测 Top-1/2/3 关键路径，实施 6 项协同跨模块改造，将 `sys_clk` 从 **77.72 MHz 推升至 93.36 MHz**（`TNS` 暴降 **98.7%**）：

1. **BTB 元数据整体打包进单块 `RAMB18E1`（`rtl/cpu/btb.v`）**：
   - 将 `{vld, is_cond, is_ret, tag[20:0]}`（24-bit）打包进同一块 `512×36` `RAMB18E1`（`meta_ram`），彻底消除原 512-bit `vld` FF 向量及 6 级 512:1 MUX 树（此前占据 Top-1 关键路径尾端 2.3 ns）。
   - 配套 **零停顿后台清零状态机（512-cycle background scrubber）**：冷/热复位或 `FENCE.I`（`flush_all`）首拍立即拉低 `q_vld_gate` 杜绝任何陈旧预测，后台无停顿擦除 `meta_ram` 有效位，净省 ~500 FF、~170 LUT、0 额外 BRAM Tile。
2. **EX 段归并 `WB_PC4` 前递直通（`rtl/cpu/rv32_cpu.v`）**：
   - 在 EX 段直接将 `JAL`/`JALR` 返回地址 `id_ex_pc_plus4` 并入 `ex_result`，使 `ex_mem_fwd_data = ex_mem_alu_out` 与 `fwd_wb_data = mem_wb_alu_out` 均为零 MUX 直通，移除原 Top-1/Top-3 路径起点 `u_ex_mem/ctrl_reg[20]` 的 2 级前递选择延迟并裁去 64 个冗余 `pc_plus4` 寄存器。
3. **I-Cache `S_RESP_ERR` 无条件回 `S_RUN` + `S_RUN` 直出 `data_q` + 预锁存 `q_cacheable_r`（`rtl/soc/icache.v`）**：
   - 消除 `ibus_addr -> req_pc_q/vld_q CE` 比较器；
   - `S_RUN` 无条件直出 `ibus_rdata = data_q`（由 `ibus_valid` 统一门控），打破 `q_hit` 串联在 `control_unit` 前方的 3.5 ns 假依赖，使指令译码与 Tag 命中比对完全并行；
   - `q_cacheable_r` 随 `req_pc_q` 预锁存，缩短 `q_hit` 关键路径。
4. **条件分支非对齐与访存后非法指令 1 拍精确寄存陷阱（`rtl/cpu/rv32_cpu.v`）**：
   - 将依赖 32 位 `branch_unit` 进位链的 `PC_BR && ex_taken && ex_bj_mis` 异常与 `ex_illegal && ex_mem_is_mem` 统一经与 `br_redir_r` 同构的 1 拍寄存陷阱 `ex_pend_trap_r` 进入 `trap_req`（优先级严格低于更老访存的 `wb_fault`/`mem_fault`），彻底剪断 `fwd -> branch_unit (4×CARRY4) -> trap_enter -> pc_flush -> ibus_addr` 跨模块路径，正常指令流零额外周期开销。
5. **`id_sys_stall` 替换为 7-bit 快速操作码判别（`rtl/cpu/rv32_cpu.v`）**：
   - 原 `id_ctrl[ILLEGAL]` 综合出 6 级串联 `LUT6` 经 `id_sys_stall -> fetch_hold -> ibus_addr` 回环入 I-Cache；改用仅判 `if_instr[6:0]` 的 1–2 级 `id_opc_normal` 快速路径串行化 `SYSTEM`/`FENCE`/`if_fault`/未知操作码，已知操作码非法 `funct` 交由上述 `ex_pend_trap_r` 兜底，100% 保持精确异常语义。
6. **`hazard_unit` 末级门控 `load_use`（`rtl/cpu/hazard_unit.v` & `rv32_cpu.v`）**：
   - 将 5-bit 寄存器编号比较器直接接原始 `if_instr` 字段并行计算，`id_valid`（`id_en && !if_fault`）仅在末级门控 `load_use` 与 `load_use_ex`，剪断 `icache.q_hit -> id_rs_haz -> 5-bit 比较器 -> fetch_hold` 链条（实测 WNS 由 `-1.600 ns` 跃升至 `-0.711 ns`）。

### 路径 2：统一主存与 DDR2 带宽路径（I/D-Cache → `soc_bus` → `mig_ddr2_bridge` → MIG 128-bit）

- **问题诊断**：原 `mig_ddr2_bridge` 每次 32-bit 读请求都发起一次完整的 128-bit（4 字）MIG 突发并丢弃其余 3 字，导致每次 8 字（32 B）Cache 行填充产生 **8 次 DDR2 读突发**，75% 有效 DDR2 带宽白白浪费。
- **优化方案（`rtl/soc/mig_ddr2_bridge.v`）**：
  - 增加 **128-bit（16 B = 4 字）读行缓冲**（`rd_buf_valid`, `rd_buf_line`, `rd_buf_data`）：同 16 B 行内连续 4 个 32-bit 字仅发起 **1 次** MIG 突发，后 3 字缓冲直出，将 32 B I/D-Cache 填充突发由 8 次压降至 **2 次（~3.5–4× 实板填充提速）**；
  - 写通道保持 Write-Through 直写（天然 DMA 一致性安全），写命中当前读行缓冲时自动失效 `rd_buf_valid`，杜绝写后读陈旧；
  - 已在 `sim/tb_periph_stage2.v` 中用 MIG 命令计数器精确断言：16 字连续读严格只发出 **4 次** `CMD_READ`（`mig_rd_buf_4x_burst`），且写命中缓冲行后立即读回验证最新数据与精准 1 次重取（`mig_rd_buf_snoop_inval`）。

### 路径 3：中断与精确陷阱路径（CLINT/PLIC/UART/SPI/VGA/OV5640 → `csr_file` → `pc`）

- 全链路确认：`clint.irq_timer`、`plic.irq_ext` 均经 1 拍输出寄存，`csr_file` 预计算 `irq_vector`；`uart_16550` 补齐 `thre_ip` 杜绝中断风暴；精确异常优先级严格固定为 `wb_fault > mem_fault > ex_pend_trap_r > exc_req > irq_take`。

### 路径 4：摄像头与视频跨时钟域路径（`cam_pclk` → `async_fifo` → `sys_clk` ↔ `vga_clk`）

- 三时钟域（`sys_clk` / `cam_pclk` / `vga_clk`）全部跨界控制/状态位标注 `(* ASYNC_REG = "TRUE" *)`，像素数据经格雷码双时钟 BRAM `async_fifo`（1024×16b）传输并带 `FIFO_CLR` 帧对齐与 `FIFO_OVF` 溢出告警；XDC 严格配置 `set_clock_groups -asynchronous`，布线后两异步域分别具备 `+14.6 ns` / `+36.0 ns` 充裕裕量。

### 路径 5：冷启动与存储引导路径（`bootrom` → `spi_master` → DDR2）

- `bootrom` 支持跨工具 Block ROM 推断且严格只读（写触发精确 `mcause=7`）；`spi_master` 卡检测同步加固，具备随时挂载 SD Bootloader 从 microSD 搬运 nommu Linux 内核至 `0x8000_0000` DDR2 的硬件完备性。

### 路径 6：全局时钟与复位树（`top_nexys4_ddr.v`）

- 100 MHz 板载晶振经 `clk_wiz_0` 生成 200 MHz（MIG 参考/输入）、25 MHz（VGA）、24 MHz（`ODDR` 转发 `CAM_XCLK`）；MIG 输出 75 MHz `ui_clk` 驱动完整 `rv32_soc`；各时钟域均采用异步置位、同步释放（`ASYNC_REG` 2-FF）复位同步链，杜绝复位释放亚稳态。

---

## 回归与签核清单

- [x] **纯 Verilog 零违规**：全工程主线（`rtl/`、`fpga/`、`sim/`）0 个 `.sv` 文件；Vivado `xvlog` / `read_verilog` 严格禁 `--sv`/`-sv` 零报错。
- [x] **24/24 双模式严格纯 Verilog 回归全通过**：`default(radix-2)` 12/12 + `DIV_RADIX4` 12/12（ModelSim / Vivado `xsim` 均全量通过），覆盖 NS16550A THRE、VGA、OV5640、`mig_ddr2_bridge` 4× 读行缓冲、分布式 Taken-Only BTB + Bimodal + 16 项 RAS 逐拍自证、8 KB 2 路 VIPT I/D-Cache 与 256 B L0D 旁路/一致性/异常取消。
- [x] **Vivado 2023.2 `xc7a100tcsg324-1` Round 4 100 MHz 布局布线签核**：`rv32_soc` 占 `7,315 LUT (11.54%，含 570 LUTRAM)` / `3,943 FF (3.11%, 0 Latch)` / `9.0 BRAM36 (6.67%)` / `4 DSP48E1 (1.67%)` / **`sys_clk = 100.52 MHz`**（**`WNS = +0.052 ns`, `TNS = 0.000 ns`, 0/11,876 违例, `WHS = +0.031 ns`**）；`mig_ddr2_bridge`（100 MHz ↔ 75 MHz 双异步 FIFO 桥）独立 OOC 布局布线占 `165 LUT / 458 FF / 4.5 BRAM36`，`sys_clk` (100 MHz) **`+4.332 ns`** / `mig_clk` (75 MHz) **`+7.606 ns`**；`tb_linux_soc`（`soc_test.hex`, `ram_lat=4`）执行周期 **85,497**（较 Round 2 基线 95,651 **-10.62% / +11.88% IPC**，叠加 75→100 MHz 实板墙钟提速 **~1.49×**）。

---

## 第三轮：分支预测分布式化 + 8 KB 2 路 VIPT Cache + 256 B 0 拍直写 L0D 协同升级

基于 Round 2（`e806489`）的绝对吞吐量权衡评估，本轮面向 Linux 访存与控制流密集型负载落地四大微架构升级，并完成 Vivado 2023.2 布局布线闭环：

| 维度 | Round 2 基线 (`e806489`) | Round 3 升级后 | 净变化 / 说明 |
|---|---:|---:|---|
| **分支预测器** | 512 项 BRAM BTB + 8K BRAM gshare（无 stall 保护），RAS 默认关闭 | **128 项分布式 RAM Taken-Only BTB + 512 项分布式 Bimodal + 默认 16 项分布式 RAS** | 省 1.5 块 BRAM Tile；1 拍 `flush_all` 取代 512 拍清零盲区；流水线透传 `pred_ctr` 根除 `align_bad` 污染；Taken-Only 等效容量 ~1.8–2× |
| **L1 I/D-Cache** | 4 KB 直映 I$ + 4 KB 直映 D$（2×`RAMB36E1`） | **8 KB 2 路 VIPT I$ + 8 KB 2 路 VIPT D$**（4×`RAMB36E1` + 1-bit LRU） | 每路仍严格 4 KB（`addr[11:5]` 页内索引，天然 VIPT 无别名），显著降低冲突缺失 |
| **L0 D-Cache** | 无（Load-Use 固定 2 拍气泡） | **256 B（64×32b 单级原生 `RAM64M`）0 拍并行直写 L0D** | MEM 拍 0 拍读出并完成字节提取进 `mem_wb_load_data` FF，Load-Use 2 拍→1 拍（`dist=2` 零气泡）；WB 确认无异常提交写（无脏行、无推测污染）；`FENCE.I` 1 拍全清 |
| **`tb_linux_soc` (`soc_test.hex`)** | 95,651 cycles | **84,878 cycles** | **-10,773 cycles（-11.26%，+12.69% IPC 提速）** |
| **Slice LUTs / LUTRAM** | 5,742 / 216（Vivado 2018.3） | **8,322 / 658**（Vivado 2023.2） | 占 XC7A100T 仅 **13.13%** |
| **Slice Registers (FF)** | 3,427 (0 Latch) | **4,265 (0 Latch)** | 占 XC7A100T 仅 **3.36%** |
| **Block RAM Tile / DSP48E1** | 8.0 / 4 | **8.5 / 4** | Cache 翻倍仅净增 **+0.5 BRAM Tile** |
| **Post-Route `sys_clk`** | 93.36 MHz (`-0.711 ns`) | **90.60 MHz (`-1.037 ns`, `TNS = -23.72 ns`)** | 相对 MIG 75 MHz 留有 **+2.296 ns** 裕量；无约束极限绝对吞吐 **+9.4%**，75 MHz 实板 **+12.7%** |
| **异步域裕量 / Hold** | `cam_pclk` +14.60 / `vga_clk` +36.01 / `WHS` +0.078 ns | **`cam_pclk` +14.81 / `vga_clk` +35.45 / `WHS` +0.095 ns** | 0 组合环 / 0 Latch / 0 Critical Warnings |

### Round 3 时序收口关键技术点（`-5.170 ns` → `-1.037 ns`，累计追回 `+4.13 ns`）

1. **LSU 拆分尾址寄存化（`rtl/cpu/load_store_unit.v`）**：将 `tail_addr = head_addr + 4` 移至 `S_IDLE -> S_HEAD` 边沿复用 `amo_addr_r` 寄存（`S_AMO` 与拆分态互斥），彻底移除 `dmem_addr` 路径上的 32 位 `CARRY4` 加法器（省 ~2.4 ns）。
2. **L0D 甜点容量与直连寻址（`rtl/soc/dcache.v`、`rtl/cpu/rv32_cpu.v`）**：对比 512 B（84,853 周期）与 256 B（84,878 周期，仅差 0.03%），选定 64 字 **256 B 单级原生 `RAM64M`**（零 bank mux），由 `ex_mem_alu_out` FF 直连 `dbus_l0_addr` 并由 `dbus_l0_en` 门控单字对齐读，6-bit `l0_st_haz` 替代 30-bit `same_word_fwd`，`(* keep *)` 并行收敛 `l0_ctrl_ok` 与 `l0_tag_eq`。
3. **2 路 I-Cache 同步 Tag/有效位读取（`rtl/soc/icache.v`）**：双路 `tag_ram0/1`（分布式 RAM + 切片寄存器 `tag0_q/tag1_q`）与 `vld0_q/vld1_q`（独立 `do_lookup` CE）在 IF 拍同步读出，将 20-bit Tag 比较与 `is_cacheable` 移出 `pc_next` 路径，且 ID 拍双路命中在 `RAMB36E1` 数据返回前就绪。
4. **控制与扇出解耦（`btb.v` / `pc.v` / `id_ex_reg.v` / `hazard_unit.v` / `rv32_cpu.v` / `plic.v`）**：
   - `btb.pred_is_ret` 直出 `p_is_ret` 使 RAS/BTB 目标选择与 23-bit Tag 比较并行；`pc` 加 `max_fanout = 24`；
   - `pc_hold_sel = fetch_hold && !pc_flush` 与 `u_pc.stall` 共享折叠为单级 LUT6，并独立于 `id_ex_reg` 控制段 `flush||bubble`（数据段 220 位仅受 `!stall` 门控）；
   - `plic.v` 将原 7 级串行中断仲裁循环重构为 3 级平衡二叉锦标赛树（15 级→5 级逻辑）。

---

## 第四轮：冲破 100 MHz 主频 + 8K BRAM Bimodal BHT + 100↔75 MHz 异步 FIFO DDR2 解耦

在不牺牲 Round 3 全部微架构收益的前提下，本轮精准切碎 Round 3 Top-1 `-1.037 ns` 关键路径，同时吸收高容量单块 BRAM PHT 思路并在确认 `sys_clk ≥ 100 MHz` 后落地 128-bit 宽边界异步 FIFO DDR2 解耦架构：

| 维度 | Round 3 (`r3f`) | Round 4 (`r4c` + 异频 DDR2 桥) | 净变化 / 说明 |
|---|---:|---:|---|
| **BHT 方向预测表** | 512 项分布式 LUTRAM | **8,192 项单块 `RAMB18E1` 同步 Bimodal** | **16× 容量扩容**；由 `pc_next` 提前一拍预读 + `pred_en = rst \|\| !pc_hold_sel` 停顿锁存，BRAM 读延迟与 `pc <= pc_next` 完全重合 |
| **L1 I-Cache 构型** | 128 组 × 32 B × 2 路（64-bit `valid` FF + 128×20b Tag） | **64 组 × 64 B × 2 路（21-bit 单级 `RAM64M` `{vld,tag}` + `S_FLUSH`）** | 消除 4 级 LUT6 64:1 `valid` mux（省 ~1.8 ns）与 128 项 Tag bank mux；保持 4 KB/路 VIPT 无别名；单级 LUT5 `ibus_rdata` |
| **D-Cache 握手与故障** | `dbus_stall`/`dbus_fault` 组合输出 + `wb_fault` 串 `!dbus_stall` | **纯 FF `dbus_stall_r`/`dbus_fault_r` + 剥离冗余 `!dbus_stall`** | 彻底斩断 Round 3 Top-1 `q_valid -> dbus_stall -> any_bus_fault(fo=167) -> trap_redir -> pc_next`（-1.037 ns）路径 |
| **RAS / ID-EX 扇出优化** | `ex_is_call/ret` 依赖 `br_misalign_cond`；`id_ex` CE `fo=272` | **`btb_upd_base` 移出条件分支比较器；`id_ex_reg` `dp_en` 拆扇出** | `u_ras` 脱离 32-bit 4×CARRY4 分支比较器；`id_ex` 272-bit 数据通路 CE 压降 ~0.4 ns |
| **Slice LUTs / LUTRAM** | 8,322 / 658 | **7,315 / 570**（`rv32_soc`）+ 165（桥） | **`rv32_soc` 净降 -1,007 LUT（-12.1%）** |
| **Slice Registers (FF)** | 4,265 (0 Latch) | **3,943 (0 Latch)**（`rv32_soc`）+ 458（桥） | **`rv32_soc` 净降 -322 FF（-7.5%）** |
| **Block RAM Tile / DSP** | 8.5 / 4 | **9.0 / 4**（`rv32_soc`）+ **4.5**（桥双异步 FIFO） | 总 BRAM 仅 **13.5 / 135（10.0%）** |
| **Post-Route `sys_clk`** | 90.60 MHz (`-1.037 ns`, `TNS=-23.72 ns`) | **100.52 MHz (`WNS = +0.052 ns`, `TNS = 0.000 ns`, 0 违例)** | **+9.92 MHz (+10.95%)，默认 `opt/place/route` 一次达标 100 MHz** |
| **实板主频 & DDR2 解耦** | 75 MHz 同频（绑定 MIG `ui_clk`） | **100 MHz SoC ↔ 75 MHz MIG 128-bit 双异步 FIFO** | `clk_wiz_0` VCO=1200 MHz 精确整数分频 `200/100/25/24 MHz`；实板主频 **+33.3%** |
| **`mig_ddr2_bridge` 裕量** | 75 MHz 同步直连 | **`sys_clk`(100 MHz) `+4.332 ns` / `mig_clk`(75 MHz) `+7.606 ns`** | 128-bit `rd_buf` 与 16 项 Posted Write 驻留 100 MHz 侧，隐藏写 CDC 与 DDR2 写延迟并严格保序 |
| **`tb_linux_soc` / `tb_sw_hello`** | 84,878 / 6,176 cycles | **85,497 / 6,176 cycles**（CPI=1.138, 精度 87%） | 叠加 75→100 MHz 实板墙钟提速 **~1.49×**（vs Round 2 75 MHz） |

### Round 4 关键技术闭环记录

1. **为什么 64-bit `valid0/1` 必须并入 21-bit `RAM64M` `{valid, tag}`（`r4a` → `r4b` → `r4c` 实测对比）**：
   - `r4a` 保留 64-bit `valid0/1` FF 并于 IF 拍预选 `vld0_q/vld1_q` 时，全片 11,719 个终点中**仅剩 2 个终点违例**（`vld0_q -0.236 ns` / `vld1_q -0.130 ns`），根因是 64:1 FF 多路选择器展开为 4 级 LUT6（2.21 ns）；
   - `r4b` 将 `valid0/1[q_idx]` 移至 ID 拍则导致 64:1 mux（4.27 ns）反超 Tag 比较并拖慢 `id_ex/CE`；
   - `r4c` 将 `valid` 打包为 21-bit `tag_ram0/1[20]`（原生单级 `RAMD64E` 仅 0.35 ns）并配 64 拍 `S_FLUSH`（在 `rst` 与 `FENCE.I` 期间顺序清零，`S_REFILL`/`S_UNCACHED` 遇 `flush_all` 挂起 `flush_pend` 待当前字 `mem_ack` 后安全转入），一次性将 `WNS` 推正至 **`+0.052 ns`（100.52 MHz, `TNS = 0`）**，同时再省 **345 LUT + 132 FF**。
2. **128-bit 宽边界异步 FIFO 解耦设计（`rtl/soc/mig_ddr2_bridge.v`、`fpga/nexys4_ddr/*`）**：
   - 128-bit（4 字）读行缓冲 `rd_buf` 留在 `100 MHz` 侧，64 B I-Cache 填充仅需 4 次 CDC、32 B D-Cache 填充仅需 2 次 CDC，同行后 3 字 10 ns 直出；
   - 16 项 × 172-bit `u_req_fifo` 同时按程序顺序承载写请求与读请求：写请求未满即 1 拍应答（100 MHz 全速吞下整行 32 B D-Cache 脏行回写）并失效命中 `rd_buf`，后继读请求排在同一队列之后确保 MIG 后端严格先写后读；
   - `sim/tb_periph_stage2.v` 升级为真实 **100 MHz（10 ns）vs 75 MHz（13.334 ns）** 异频异步压测，覆盖 24 次连续 Posted Write 满队反压、4×/6× 突发计数断言、写命中失效与同址高频读写交替，24/24 回归全量通过；`top_nexys4_ddr.v` 通过纯 Verilog `xvlog`/`xelab` 编译细化 0 报错。

---

## 第五轮：路线 B（M/S/U + 委托 + PLIC Ctx1 + Sv32 MMU）100 MHz 时序收口与全芯片 Linux 比特流签核

在 Round 4（100.52 MHz）基础上完整实现 RISC-V M/S/U 特权级、异常/中断委托（`medeleg`/`mideleg`）、PLIC Context 1（S-mode 外部中断）、Sv32 MMU（`rtl/soc/sv32_mmu.v`）与物理标签 VIPT I$/D$/L0D + D-Cache 脏行一致性硬件 PTW，经 4 轮精准关键路径剪枝将布线后 `WNS` 从 `-2.134 ns`（`TNS = -3,248.7 ns`）一路推回 **`+0.043 ns`（`TNS = 0.000 ns`）**，全芯片真 IP Linux 比特流实测 **`WNS = +0.170 ns`**。

### 时序收敛实测轨迹（Vivado 2023.2 `xc7a100tcsg324-1`，默认 `opt/place/route`）

| 迭代 | 关键路径诊断与落地剪枝 | LUT | FF (0 Latch) | BRAM | Post-Route `WNS` | Post-Route `TNS` |
|---|---|---:|---:|---:|---:|---:|
| `ooc_sv32_v1` | 初版 M/S/U + 16×2 主 TLB + 一致性 PTW 接入基线 | 10,364 | 5,977 | 9.0 | -2.134 ns | -3,248.7 ns |
| `ooc_sv32_v2` | Cut #1：`sv32_mmu` 主 TLB 写使能 `fill_itlb_en`/`fill_dtlb_en` 彻底脱离 `ibus_kill`/`satp_flush`；`rv32_cpu` CSR/xRET/exc 改用 `!lsu_stall` 摆脱 `muldiv -> hold_mem`；`csr_exists` 3 级并行分段 | — | — | 9.0 | -2.001 ns | -559.9 ns (-82.8%) |
| `ooc_sv32_v3` | Cut #2：`dcache` 新增 `S_PTW_LK` 态使 `lk_pa`/`lk_idx` 纯 FF 选通（斩断 `amo_wait -> in_req -> ptw_accept -> tag_ram` ~5.0 ns）；`csr_file` 增寄存态 `i_xlate_en_r` + `icache` Bare/Sv32 并行 CARRY4 比较器 | 10,384 | 5,992 | 9.0 | -1.211 ns | -214.3 ns |
| `ooc_sv32_v4` | Cut #3：`icache` 将 `tag[20]` 有效位并入 21b/11b CARRY4 折叠 `q_way0/1` 为单级 LUT6；`rv32_cpu` `id_is_sys_opc` 缩减为 5-bit `if_instr[6:2]`；主 ITLB/DTLB 定型为 1 uTLB + 8 全相联主 TLB（4 向布线拥塞全部清零） | 9,296 | 5,249 | 9.0 | -0.906 ns | -83.2 ns |
| **`ooc_sv32_v5` (签核)** | **Cut #4：`rv32_cpu` 将 `ex_illegal`（含 `csr_exists`/`csr_illegal`/`priv_illegal`）全部经已有 1 拍精确寄存陷阱 `ex_pend_trap_r` 交付并同步清零 `u_ex_mem` 控制字、`satp_we_taken` 脱离 `csr_exists` 链** | **9,054 (14.28%)** | **5,255 (4.14%)** | **9.0 (6.67%)** | **`+0.043 ns` (100.43 MHz)** | **`0.000 ns` (`0 / 14,301`)** |
| **全芯片 Linux 比特流 (`top_nexys4_ddr`)** | **真实 `clk_wiz_0` + `mig_7series_0` (128 MB DDR2) + Sv32 MMU + `bootrom_linux.hex`（`SPIx4` `.bit`/`.bin`）** | **12,527 (19.76%)** | **8,869 (6.99%)** | **13.5 (10.00%)** | **`+0.170 ns` (101.73 MHz)** | **`0.000 ns` (`0 / 30,275`, `WHS = +0.032 ns`)** |

### 第五轮回归与功能签核清单

- [x] **100% 纯 Verilog-2001/2005 零违规**：`rtl/`、`fpga/`、`sim/` 共 0 个 `.sv` 文件，所有仿真与综合均严格不传 `-sv`/`--sv`。
- [x] **30/30 双模式严格纯 Verilog 回归全通过**：`default(radix-2)` 15/15 + `DIV_RADIX4` 15/15，新增 `tb_soc_priv_s`（3,351 周期，覆盖 M/S/U、`medeleg`/`mideleg`、`SRET`/`TVM`/`TW`/`TSR`/PLIC Context 1）、`tb_soc_sv32`（33,980 周期，覆盖 8 项 Sv32 脏行一致性 PTW / 4 MB 巨页 / 共享 PA L0D 零别名 / 跨页非对齐 / SUM/MXR / 软件 A/D / 动态重映射 / U-mode 虚址执行 / `MPRV=1`）、`tb_bootrom_linux`（真实 SPI Mode 0 SDHC 行为卡端到端引导）。
- [x] **裸机性能零退化**：`tb_linux_soc` (`soc_test.hex`, `ram_lat=4`) 实测 **`85,497` 周期**，与 Round 4 逐拍一致。
- [x] **全芯片真 IP 比特流签核**：`top_nexys4_ddr`（`bootrom_linux.hex`）`0 DRC Errors`、`0 Critical Warnings`、`0` 组合环、`0 Latch`，已成功输出 `.bit` 与 QSPI `SPIx4` `.bin`。
