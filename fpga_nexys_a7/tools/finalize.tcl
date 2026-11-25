# Re-close the routed checkpoint after a constraint-only change, then write the bitstream.
set output_dir [lindex $argv 0]
if {$output_dir eq ""} { error "usage: finalize.tcl <build/vision>" }
set output_dir [file normalize $output_dir]
set checkpoint [file join $output_dir project nexys_a7_vision.runs impl_1 top_nexys_a7_vision_routed.dcp]
if {![file isfile $checkpoint]} { error "routed checkpoint not found: $checkpoint" }
open_checkpoint $checkpoint

set reset_pins [get_pins -quiet -regexp {^(system|cpu|video)_reset_sync_reg\[[0-2]\]/PRE$}]
puts "BOARD_RESET_PRESETS=$reset_pins"
if {[llength $reset_pins] != 9} { error "expected 9 board reset synchronizer preset pins" }
set_false_path -to $reset_pins
update_timing -full

set worst_max [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_min [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $worst_max] == 0 || [llength $worst_min] == 0} { error "no timing paths found" }
set wns [get_property SLACK $worst_max]
set whs [get_property SLACK $worst_min]
puts "FINAL_WNS=$wns FINAL_WHS=$whs"
if {$wns < 0 || $whs < 0} { error "Timing failed after final constraints: WNS=$wns WHS=$whs" }

write_checkpoint -force [file join $output_dir routed.dcp]
report_utilization -file [file join $output_dir reports utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $output_dir reports timing.rpt]
report_drc -file [file join $output_dir reports drc.rpt]
report_cdc -file [file join $output_dir reports cdc.rpt]
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]] != 0} { error "DRC errors remain" }

write_bitstream -force [file join $output_dir top_nexys_a7_vision.bit]
write_cfgmem -force -format BIN -interface SPIx4 -size 16 \
    -loadbit "up 0x00000000 [file join $output_dir top_nexys_a7_vision.bit]" \
    [file join $output_dir top_nexys_a7_vision.bin]
set handle [open [file join $output_dir build_passed.txt] w]
puts $handle "Vivado routed checkpoint finalized: setup/hold timing, DRC and bitstream generation passed. Hardware validation pending."
close $handle
close_project
exit
