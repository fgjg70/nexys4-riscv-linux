set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {clk100}]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports {reset_n}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {buttons[0]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {buttons[1]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {buttons[2]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {buttons[3]}]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports {uart_rxd}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {uart_txd}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {led[15]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {vga_r[0]}]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {vga_r[1]}]
set_property -dict {PACKAGE_PIN C5 IOSTANDARD LVCMOS33} [get_ports {vga_r[2]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports {vga_r[3]}]
set_property -dict {PACKAGE_PIN C6 IOSTANDARD LVCMOS33} [get_ports {vga_g[0]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {vga_g[1]}]
set_property -dict {PACKAGE_PIN B6 IOSTANDARD LVCMOS33} [get_ports {vga_g[2]}]
set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {vga_g[3]}]
set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {vga_b[0]}]
set_property -dict {PACKAGE_PIN C7 IOSTANDARD LVCMOS33} [get_ports {vga_b[1]}]
set_property -dict {PACKAGE_PIN D7 IOSTANDARD LVCMOS33} [get_ports {vga_b[2]}]
set_property -dict {PACKAGE_PIN D8 IOSTANDARD LVCMOS33} [get_ports {vga_b[3]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {vga_hsync}]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports {vga_vsync}]
# AF-OV5640-U1.0 as installed on JA/JB, viewed facing the lens.
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports {cam_data[0]}] ;# JB9
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {cam_data[1]}] ;# JB10
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {cam_data[2]}] ;# JB4
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports {cam_data[3]}] ;# JB3
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {cam_data[4]}] ;# JB2
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {cam_data[5]}] ;# JB1
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {cam_data[6]}] ;# JB7
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {cam_data[7]}] ;# JA10
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {cam_scl}] ;# JA7
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {cam_pclk}] ;# JB8
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports {cam_sda}] ;# JA1
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {cam_vsync}] ;# JA8
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {cam_href}] ;# JA3
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {cam_xclk}] ;# JA4
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {cam_reset_n}] ;# JA2
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {cam_pwdn}] ;# JA9
# Digilent Pmod OLED RGB (SSD1331) on JC. JC3 is unconnected on the module.
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33} [get_ports {oled_cs_n}] ;# JC1
set_property -dict {PACKAGE_PIN F6 IOSTANDARD LVCMOS33} [get_ports {oled_mosi}] ;# JC2
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports {oled_sclk}] ;# JC4
set_property -dict {PACKAGE_PIN E7 IOSTANDARD LVCMOS33} [get_ports {oled_dc}] ;# JC7
set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports {oled_reset_n}] ;# JC8
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports {oled_vccen}] ;# JC9
set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {oled_pmoden}] ;# JC10
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[0]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[1]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[2]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[3]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[4]}]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[5]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {servo_pwm[6]}]
set_property PULLUP TRUE [get_ports {cam_scl cam_sda}]
set_property DRIVE 8 [get_ports {vga_* servo_pwm[*] cam_xclk oled_*}]
set_property SLEW SLOW [get_ports {vga_* servo_pwm[*] cam_xclk oled_*}]
create_clock -name sys100 -period 10.000 [get_ports clk100]
create_generated_clock -name clk50 -source [get_pins clocks/mmcm/CLKIN1] -multiply_by 12 -divide_by 24 [get_pins clocks/mmcm/CLKOUT0]
create_generated_clock -name clk60 -source [get_pins clocks/mmcm/CLKIN1] -multiply_by 12 -divide_by 20 [get_pins clocks/mmcm/CLKOUT1]
create_generated_clock -name clk25 -source [get_pins clocks/mmcm/CLKIN1] -multiply_by 12 -divide_by 48 [get_pins clocks/mmcm/CLKOUT2]
create_generated_clock -name ref200 -source [get_pins clocks/mmcm/CLKIN1] -multiply_by 12 -divide_by 6 [get_pins clocks/mmcm/CLKOUT3]
create_generated_clock -name camera_xclk -source [get_pins clocks/system_buffer/O] -divide_by 2 [get_ports cam_xclk]
set_false_path -from [get_ports {reset_n buttons[*] uart_rxd cam_vsync cam_href cam_pclk cam_data[*] cam_sda}]
set_false_path -to [get_ports {led[*] servo_pwm[*] uart_txd cam_scl cam_sda cam_reset_n cam_pwdn oled_*}]
# Only the asynchronous preset pins of the board-level reset synchronizers
# are exempt. Their 3-stage shift paths still have to meet setup and hold.
set_false_path -to [get_pins -quiet -regexp {^(system|cpu|video)_reset_sync_reg\[[0-2]\]/PRE$}]
set_output_delay -clock clk25 -max 5.000 [get_ports {vga_*}]
set_output_delay -clock clk25 -min 0.000 [get_ports {vga_*}]
