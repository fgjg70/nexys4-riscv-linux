# ============================================================================
# fpga/nexys4_ddr/synth_ooc.tcl — Vivado 2018.3 OOC 综合与布线摸底脚本 (纯 Verilog)
# 目标器件: Nexys 4 DDR (Artix-7 xc7a100tcsg324-1)
# 时钟约束: sys_clk = 100 MHz (10.0 ns), vga_clk = 25 MHz, cam_pclk = 48 MHz (异步)
# 用法: vivado -mode batch -source fpga/nexys4_ddr/synth_ooc.tcl -tclargs <ROOT> <OUT_DIR>
# ============================================================================

set root_dir [lindex $argv 0]
set out_dir  [lindex $argv 1]
file mkdir $out_dir

set part "xc7a100tcsg324-1"
set inc_dir "$root_dir/rtl/cpu"

# 严格使用纯 Verilog read_verilog (不加 -sv)
set rtl_files [list \
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
  "$root_dir/rtl/periph/clint.v" \
  "$root_dir/rtl/periph/plic.v" \
  "$root_dir/rtl/periph/uart_16550.v" \
  "$root_dir/rtl/periph/spi_master.v" \
  "$root_dir/rtl/video/vga_ctrl.v" \
  "$root_dir/rtl/camera/ov5640_sccb.v" \
  "$root_dir/rtl/camera/ov5640_capture.v" \
  "$root_dir/rtl/soc/rv32_soc.v" \
]

foreach f $rtl_files {
  read_verilog $f
}

synth_design -top rv32_soc -part $part -mode out_of_context -include_dirs $inc_dir

create_clock -name sys_clk  -period 10.000 [get_ports clk]
create_clock -name vga_clk  -period 40.000 [get_ports vga_clk]
create_clock -name cam_pclk -period 20.833 [get_ports cam_pclk]
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks vga_clk] -group [get_clocks cam_pclk]

report_utilization -file "$out_dir/util_synth.rpt"
report_timing_summary -delay_type max -report_unconstrained -max_paths 5 -file "$out_dir/timing_synth.rpt"

opt_design
place_design
route_design

report_utilization -file "$out_dir/util_impl.rpt"
report_timing_summary -delay_type max -max_paths 5 -file "$out_dir/timing_impl.rpt"
puts "=== SYNTH_IMPL_DONE ==="
exit 0
