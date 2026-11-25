set port_dir [file dirname [file normalize [info script]]]
set mode [lindex $argv 0]
if {$mode eq ""} { set mode bitstream }
set output_dir [lindex $argv 1]
if {$output_dir eq ""} { set output_dir [file join $port_dir build vision] }
set output_dir [file normalize $output_dir]
cd $output_dir
source config.tcl
create_project -force nexys_a7_vision [file join $output_dir project] -part xc7a100tcsg324-1
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
add_files [lsort [glob [file join $output_dir rtl *.v]]]
add_files [concat [glob [file join $output_dir firmware *.hex]] [glob [file join $output_dir model *.hex]]]
set_property file_type {Memory Initialization Files} [get_files *.hex]
set_property top top_nexys_a7_vision [current_fileset]
set_property generic [list BIST_TEST_WORDS=$bist_test_words MODEL_MASK=$model_mask] [current_fileset]
add_files -fileset constrs_1 [file join $output_dir nexys_a7.xdc]
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name ddr
set_property CONFIG.XML_INPUT_FILE [file join $output_dir ip mig.prj] [get_ips ddr]
generate_target all [get_ips ddr]
update_compile_order -fileset sources_1
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
if {$mode eq "project"} { close_project; exit }
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
open_run synth_1
report_utilization -file [file join $output_dir reports synthesis_utilization.rpt]
report_timing_summary -file [file join $output_dir reports synthesis_timing.rpt]
if {$mode eq "synth"} { close_project; exit }
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed" }
open_run impl_1
set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $setup_path] != 0 && [get_property SLACK $setup_path] < 0} {
    phys_opt_design -directive AggressiveExplore
}
report_utilization -file [file join $output_dir reports utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $output_dir reports timing.rpt]
report_drc -file [file join $output_dir reports drc.rpt]
report_cdc -file [file join $output_dir reports cdc.rpt]
foreach delay_type {max min} {
    set worst [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {[llength $worst] == 0 || [get_property SLACK $worst] < 0} { error "Timing failed: $delay_type" }
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]] != 0} { error "DRC errors remain" }
write_checkpoint -force [file join $output_dir routed.dcp]
write_bitstream -force [file join $output_dir top_nexys_a7_vision.bit]
write_cfgmem -force -format BIN -interface SPIx4 -size 16 \
    -loadbit "up 0x00000000 [file join $output_dir top_nexys_a7_vision.bit]" \
    [file join $output_dir top_nexys_a7_vision.bin]
set handle [open [file join $output_dir build_passed.txt] w]
puts $handle "Vivado implementation, setup/hold timing, DRC and bitstream generation passed. Hardware validation pending."
close $handle
close_project
exit
