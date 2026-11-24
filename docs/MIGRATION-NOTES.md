# 迁移溯源记录（MIGRATION-NOTES）

本工程于 **2026-11-24** 从原竞赛仓库 `fgjg70/FPGA` 精简拆分建立，并全部**手工重构为纯 Verilog-2001/2005（`.v` + `.vh`）**，保持独立演进、不污染原竞赛交付历史。

## 1. 迁入内容与来源

| 目标路径 | 来源分支 / 提交 | 说明 |
|---|---|---|
| `rtl/cpu/rv32_defs.vh` + 16 个 `.v` 模块 | `fgjg70/FPGA` `main` (`a8a1614`) | 纯单发射 RV32IM 核基线，由原 `.sv` 手工重构为纯 Verilog-2001/2005（`rv32_defs.vh` 替代 `rv32_pkg.sv`，以命名宏位片替代 `ctrl_s` packed struct） |
| `rtl/cpu/muldiv.v` | `fgjg70/FPGA` `radix-4` (`fc1fd5a`) | 保留 `` `ifdef DIV_RADIX4 ``（默认关闭 = radix-2；开启 = 16 步 radix-4），已手工重构为纯 Verilog-2001 |
| `rtl/cpu/control_unit.v`、`load_store_unit.v`、`core.v`（RV32A 部分） | `fgjg70/FPGA` `feat/isa-ac` (`3176f84`) | **仅抽取 RV32A**（默认开启，`` `ifndef A_DIS ``；含 `AMO*.W` + `LR.W/SC.W` 真预约 + 非对齐 AMO 异常），**彻底剔除 RV32C**；新增 `res_clear` 端口并在 `trap_enter \|\| mret_taken` 时清零 `res_valid`；`csr_file.v` 的 `MISA_VALUE` 在开启 A 时置位 bit 0（`0x4000_1101`） |
| `rtl/periph/mmio_subsys.v` | `fgjg70/FPGA` `main` (`fpga/mmio_subsys.sv`) | 剔除废弃 `GEMM_EN`/`gemm_accel` 桩并手工重构为纯 Verilog-2001，仅用于基线回归，后续由标准 CLINT/PLIC/16550 替换 |
| `sim/tb_*.v`、`sw/`、`tools/` | `fgjg70/FPGA` `main` + `feat/isa-ac` (`amo.S`, `asm.py`) | 4 个测试平台均已手工重构为纯 Verilog-2001；`tools/verify.py` 以严格非 `-sv`/`--sv` 模式驱动 ModelSim / Vivado `xsim` 回归 |

## 2. 明确不迁入的历史包袱

- 紫光同创 PG2L100H / MES50HP / PGL22G 全部工程、`.fdc` 约束、`GTP_GPLL` 原语、1/4-MAC `vision_npu.v`、舵机 PWM、43 MB `.rar`；
- 旧 AN430 LCD 驱动与旧 OV7670 8-bit SCCB / 过采样 DVP 驱动；
- 顺序双发射核（`feat/dual-issue`、`regfile_dual.sv`）、RV32C 压缩指令（`rvc_expand.sv`）、废弃 `gemm_accel.sv`；
- 旧 `daVinciPro` (`xc7a100tfgg484-2`) 顶层/XDC、历史微架构探索分支与旧构建缓存；
- 128-MAC NPU（`feat/ai-accel`）暂留原仓，待 Nexys 4 DDR Linux + VGA + OV5640 跑稳后再独立按需引入。
