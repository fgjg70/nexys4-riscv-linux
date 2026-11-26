# ============================================================================
# fpga/nexys4_ddr/build_project.tcl — Vivado 2018.3/2023.2 Nexys 4 DDR 一键构建脚本
# 生成纯 Verilog 工程 (Clocking Wizard 200/100/25/24 MHz + MIG 7 Series 128 MB DDR2 + BootROM 自检)
# Round 4 架构: rv32_soc 跑 100 MHz (clk_100m)，经 128-bit 双异步 FIFO 与 75 MHz MIG 解耦
#
# 用法:
#   vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs <PROJ_DIR> [project|synth|bitstream] [bist|linux]
# 示例:
#   vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado                  # 仅生成工程
#   vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado bitstream       # 上电自检 BootROM 比特流
#   vivado -mode batch -source fpga/nexys4_ddr/build_project.tcl -tclargs build_vivado bitstream linux # Linux BootROM 比特流
# ============================================================================

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/../.."]
set proj_dir   [expr {$argc > 0 ? [file normalize [lindex $argv 0]] : "$root_dir/build_vivado"}]
set mode       [expr {$argc > 1 ? [lindex $argv 1] : "project"}]
set rom_sel    [expr {$argc > 2 ? [lindex $argv 2] : "bist"}]
set part       "xc7a100tcsg324-1"

create_project nexys4_riscv_soc $proj_dir -part $part -force
set_property target_language Verilog [current_project]

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
  "$root_dir/rtl/soc/sv32_mmu.v" \
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

# 绑定 16 KB BootROM 镜像 (默认 bist -> board_bist.hex; 传 linux -> bootrom_linux.hex)
if {$rom_sel eq "linux"} {
  set rom_hex "$root_dir/sw/bootrom_linux/bootrom_linux.hex"
} else {
  set rom_hex "$root_dir/sw/board_bist/board_bist.hex"
}
if {[file exists $rom_hex]} {
  add_files -norecurse $rom_hex
  set_property file_type {Memory Initialization Files} [get_files $rom_hex]
  set_property verilog_define [list "ROM_INIT_FILE=\"$rom_hex\""] [current_fileset]
  puts "=== BootROM Init Image Attached ($rom_sel): $rom_hex ==="
}

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

# IP 2: MIG 7 Series (导入实板验证版 Nexys 4 DDR MT47H64M16HR-25E mig.prj v4.1)
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_7series_0
set_property -dict [list \
  CONFIG.XML_INPUT_FILE "$root_dir/fpga/nexys4_ddr/mig.prj" \
] [get_ips mig_7series_0]

generate_target all [get_ips]
update_compile_order -fileset sources_1
puts "=== Nexys 4 DDR Vivado Project Created at: $proj_dir (mode=$mode) ==="

if {$mode eq "project"} {
  close_project
  exit 0
}

set rpt_dir "$proj_dir/reports"
file mkdir $rpt_dir

# 一键综合
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "Synthesis failed!"
}
open_run synth_1
report_utilization -file "$rpt_dir/util_synth.rpt"
report_timing_summary -delay_type max -max_paths 5 -file "$rpt_dir/timing_synth.rpt"
puts "=== SYNTH_DONE ==="

if {$mode eq "synth"} {
  close_project
  exit 0
}

# 一键实现 + 自动 phys_opt 兜底 + 报告 + 比特流 + QSPI SPIx4 .bin
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "Implementation failed!"
}
open_run impl_1

set worst_setup [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $worst_setup] != 0 && [get_property SLACK $worst_setup] < 0} {
  puts "=== Setup slack < 0, running AggressiveExplore phys_opt_design + route_design ==="
  phys_opt_design -directive AggressiveExplore
  route_design -directive Explore
}

report_utilization -file "$rpt_dir/util_impl.rpt"
report_timing_summary -delay_type min_max -max_paths 10 -file "$rpt_dir/timing_impl.rpt"
report_drc -file "$rpt_dir/drc_impl.rpt"
report_cdc -file "$rpt_dir/cdc_impl.rpt"

foreach dt {max min} {
  set p [get_timing_paths -quiet -delay_type $dt -max_paths 1]
  if {[llength $p] != 0} {
    puts "=== WORST $dt SLACK: [get_property SLACK $p] ns ==="
  }
}

set drc_errs [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errs] != 0} {
  error "DRC errors found ([llength $drc_errs]); see $rpt_dir/drc_impl.rpt"
}

write_checkpoint -force "$proj_dir/routed.dcp"
write_bitstream  -force "$proj_dir/top_nexys4_ddr.bit"
write_cfgmem     -force -format BIN -interface SPIx4 -size 16 \
  -loadbit "up 0x00000000 $proj_dir/top_nexys4_ddr.bit" \
  "$proj_dir/top_nexys4_ddr.bin"

puts "=== BITSTREAM_AND_BIN_DONE: $proj_dir/top_nexys4_ddr.bit ==="
close_project
exit 0
