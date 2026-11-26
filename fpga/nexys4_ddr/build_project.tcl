# ============================================================================
# fpga/nexys4_ddr/build_project.tcl — Vivado 2018.3/2023.2 Nexys 4 DDR 完整工程构建脚本
# 生成纯 Verilog 工程 (含 Clocking Wizard 200/100/25/24 MHz + MIG 7 Series 128 MB DDR2)
# Round 4 架构: rv32_soc 跑 100 MHz (clk_100m)，经 128-bit 双异步 FIFO 与 75 MHz MIG 解耦
# 用法:
#   vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs <PROJ_DIR>
# ============================================================================

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/../.."]
set proj_dir   [expr {$argc > 0 ? [lindex $argv 0] : "$root_dir/build_vivado"}]
set part       "xc7a100tcsg324-1"

create_project nexys4_riscv_soc $proj_dir -part $part -force

# 添加纯 Verilog RTL 与头文件目录
set rtl_files [list \
  "$root_dir/rtl/cpu/rv32_defs.vh" \
  "$root_dir/rtl/common/async_fifo.v" \
  "$root_dir/rtl/cpu/alu.v" \
  "$root_dir/rtl/cpu/branch_unit.v" \
  "$root_dir/rtl/cpu/imm_gen.v" \
  "$root_dir/rtl/cpu/regfile.v" \
  "$root_dir/rtl/cpu/pc.v" \
  "$root_dir/rtl/cpu/btb.v" \
  "$root_dir/rtl/cpu/bht.v" \
  "$root_dir/rtl/cpu/ras.v" \
  "$root_dir/rtl/cpu/hazard_unit.v" \
  "$root_dir/rtl/cpu/id_ex_reg.v" \
  "$root_dir/rtl/cpu/ex_mem_reg.v" \
  "$root_dir/rtl/cpu/mem_wb_reg.v" \
  "$root_dir/rtl/cpu/control_unit.v" \
  "$root_dir/rtl/cpu/load_store_unit.v" \
  "$root_dir/rtl/cpu/muldiv.v" \
  "$root_dir/rtl/cpu/csr_file.v" \
  "$root_dir/rtl/cpu/rv32_cpu.v" \
  "$root_dir/rtl/soc/icache.v" \
  "$root_dir/rtl/soc/dcache.v" \
  "$root_dir/rtl/soc/soc_bus.v" \
  "$root_dir/rtl/soc/bootrom.v" \
  "$root_dir/rtl/soc/mig_ddr2_bridge.v" \
  "$root_dir/rtl/periph/clint.v" \
  "$root_dir/rtl/periph/plic.v" \
  "$root_dir/rtl/periph/uart_16550.v" \
  "$root_dir/rtl/periph/spi_master.v" \
  "$root_dir/rtl/video/vga_ctrl.v" \
  "$root_dir/rtl/camera/ov5640_sccb.v" \
  "$root_dir/rtl/camera/ov5640_capture.v" \
  "$root_dir/rtl/soc/rv32_soc.v" \
  "$root_dir/fpga/nexys4_ddr/top_nexys4_ddr.v" \
]

add_files -norecurse $rtl_files
set_property include_dirs [list "$root_dir/rtl/cpu"] [current_fileset]
set_property top top_nexys4_ddr [current_fileset]

# 约束文件
add_files -fileset constrs_1 -norecurse "$root_dir/fpga/nexys4_ddr/nexys4_ddr.xdc"

# IP 1: Clocking Wizard (VCO=1200 MHz 精确整数分频: 200 MHz MIG / 25 MHz VGA / 24 MHz OV5640 / 100 MHz SoC)
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_0
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {100.000} \
  CONFIG.CLKOUT1_USED {true} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLK_OUT1_PORT {clk_200m} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {25.000} \
  CONFIG.CLK_OUT2_PORT {clk_25m} \
  CONFIG.CLKOUT3_USED {true} \
  CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {24.000} \
  CONFIG.CLK_OUT3_PORT {clk_24m} \
  CONFIG.CLKOUT4_USED {true} \
  CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLK_OUT4_PORT {clk_100m} \
  CONFIG.RESET_TYPE {ACTIVE_LOW} \
  CONFIG.RESET_PORT {resetn} \
] [get_ips clk_wiz_0]

# IP 2: MIG 7 Series (导入官方验证过的 Nexys 4 DDR MT47H64M16HR-25E mig.prj)
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_7series_0
set_property -dict [list \
  CONFIG.XML_INPUT_FILE "$root_dir/fpga/nexys4_ddr/mig.prj" \
] [get_ips mig_7series_0]

generate_target all [get_ips]
update_compile_order -fileset sources_1
puts "=== Nexys 4 DDR Vivado 2018.3 Project Created at: $proj_dir ==="
