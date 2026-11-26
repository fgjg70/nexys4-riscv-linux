## ============================================================================
## fpga/nexys4_ddr/nexys4_ddr.xdc — Digilent Nexys 4 DDR / Nexys A7-100T (xc7a100tcsg324-1)
## 引脚严格核对自官方 Nexys-A7-100T-Master.xdc 与协作者实板验证的 AF-OV5640-U1.0 线序
## 说明: DDR2 (MT47H64M16HR-25E) 管脚约束由 MIG 7 Series IP (mig.prj) 自动生成。
## ============================================================================

## 100 MHz 主晶振 (不加 -add 以覆写 clk_wiz_0 默认同名主时钟，避免 report_cdc 出现重复 _1 影子时钟)
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }];
create_clock -name sys_clk_100m -period 10.000 -waveform {0 5} [get_ports { CLK100MHZ }];

## 复位按键 (低有效)
set_property -dict { PACKAGE_PIN C12   IOSTANDARD LVCMOS33 } [get_ports { CPU_RESETN }];

## 拨码开关 SW[7:0] (全部位于 3.3V Bank 14/15; SW[8..9] 为 1.8V 故未选用)
set_property -dict { PACKAGE_PIN J15   IOSTANDARD LVCMOS33 } [get_ports { SW[0] }];
set_property -dict { PACKAGE_PIN L16   IOSTANDARD LVCMOS33 } [get_ports { SW[1] }];
set_property -dict { PACKAGE_PIN M13   IOSTANDARD LVCMOS33 } [get_ports { SW[2] }];
set_property -dict { PACKAGE_PIN R15   IOSTANDARD LVCMOS33 } [get_ports { SW[3] }];
set_property -dict { PACKAGE_PIN R17   IOSTANDARD LVCMOS33 } [get_ports { SW[4] }];
set_property -dict { PACKAGE_PIN T18   IOSTANDARD LVCMOS33 } [get_ports { SW[5] }];
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports { SW[6] }];
set_property -dict { PACKAGE_PIN R13   IOSTANDARD LVCMOS33 } [get_ports { SW[7] }];

## 状态指示 LED[15:0]
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS33 } [get_ports { LED[0] }];
set_property -dict { PACKAGE_PIN K15   IOSTANDARD LVCMOS33 } [get_ports { LED[1] }];
set_property -dict { PACKAGE_PIN J13   IOSTANDARD LVCMOS33 } [get_ports { LED[2] }];
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { LED[3] }];
set_property -dict { PACKAGE_PIN R18   IOSTANDARD LVCMOS33 } [get_ports { LED[4] }];
set_property -dict { PACKAGE_PIN V17   IOSTANDARD LVCMOS33 } [get_ports { LED[5] }];
set_property -dict { PACKAGE_PIN U17   IOSTANDARD LVCMOS33 } [get_ports { LED[6] }];
set_property -dict { PACKAGE_PIN U16   IOSTANDARD LVCMOS33 } [get_ports { LED[7] }];
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 } [get_ports { LED[8] }];
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports { LED[9] }];
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { LED[10] }];
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { LED[11] }];
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS33 } [get_ports { LED[12] }];
set_property -dict { PACKAGE_PIN V14   IOSTANDARD LVCMOS33 } [get_ports { LED[13] }];
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { LED[14] }];
set_property -dict { PACKAGE_PIN V11   IOSTANDARD LVCMOS33 } [get_ports { LED[15] }];

## USB-UART (NS16550A 串口控制台, 115200 8N1)
set_property -dict { PACKAGE_PIN C4    IOSTANDARD LVCMOS33 } [get_ports { UART_TXD_IN }];
set_property -dict { PACKAGE_PIN D4    IOSTANDARD LVCMOS33 } [get_ports { UART_RXD_OUT }];

## 板载 microSD 卡槽 (SPI Mode 0: CMD=MOSI, DAT0=MISO, DAT3=CS_N, DAT1/2=拉高)
set_property -dict { PACKAGE_PIN E2    IOSTANDARD LVCMOS33 } [get_ports { SD_RESET }];
set_property -dict { PACKAGE_PIN A1    IOSTANDARD LVCMOS33 } [get_ports { SD_CD }];
set_property -dict { PACKAGE_PIN B1    IOSTANDARD LVCMOS33 } [get_ports { SD_SCK }];
set_property -dict { PACKAGE_PIN C1    IOSTANDARD LVCMOS33 } [get_ports { SD_CMD }];
set_property -dict { PACKAGE_PIN C2    IOSTANDARD LVCMOS33 } [get_ports { SD_DAT[0] }];
set_property -dict { PACKAGE_PIN E1    IOSTANDARD LVCMOS33 } [get_ports { SD_DAT[1] }];
set_property -dict { PACKAGE_PIN F1    IOSTANDARD LVCMOS33 } [get_ports { SD_DAT[2] }];
set_property -dict { PACKAGE_PIN D2    IOSTANDARD LVCMOS33 } [get_ports { SD_DAT[3] }];

## 板载 12-bit RGB444 VGA 接口 (640x480@60Hz)
set_property -dict { PACKAGE_PIN A3    IOSTANDARD LVCMOS33 } [get_ports { VGA_R[0] }];
set_property -dict { PACKAGE_PIN B4    IOSTANDARD LVCMOS33 } [get_ports { VGA_R[1] }];
set_property -dict { PACKAGE_PIN C5    IOSTANDARD LVCMOS33 } [get_ports { VGA_R[2] }];
set_property -dict { PACKAGE_PIN A4    IOSTANDARD LVCMOS33 } [get_ports { VGA_R[3] }];
set_property -dict { PACKAGE_PIN C6    IOSTANDARD LVCMOS33 } [get_ports { VGA_G[0] }];
set_property -dict { PACKAGE_PIN A5    IOSTANDARD LVCMOS33 } [get_ports { VGA_G[1] }];
set_property -dict { PACKAGE_PIN B6    IOSTANDARD LVCMOS33 } [get_ports { VGA_G[2] }];
set_property -dict { PACKAGE_PIN A6    IOSTANDARD LVCMOS33 } [get_ports { VGA_G[3] }];
set_property -dict { PACKAGE_PIN B7    IOSTANDARD LVCMOS33 } [get_ports { VGA_B[0] }];
set_property -dict { PACKAGE_PIN C7    IOSTANDARD LVCMOS33 } [get_ports { VGA_B[1] }];
set_property -dict { PACKAGE_PIN D7    IOSTANDARD LVCMOS33 } [get_ports { VGA_B[2] }];
set_property -dict { PACKAGE_PIN D8    IOSTANDARD LVCMOS33 } [get_ports { VGA_B[3] }];
set_property -dict { PACKAGE_PIN B11   IOSTANDARD LVCMOS33 } [get_ports { VGA_HS }];
set_property -dict { PACKAGE_PIN B12   IOSTANDARD LVCMOS33 } [get_ports { VGA_VS }];

## 双 Pmod (JA + JB) AF-OV5640-U1.0 摄像头接口 (已对齐协作者实板采通线序: 面对镜头左 JB 右 JA)
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { CAM_SIOD }];   # JA1 (SDA)
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { CAM_RST_N }];              # JA2 (RST#)
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { CAM_HREF }];               # JA3 (HREF)
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { CAM_XCLK }];               # JA4 (XCLK)
set_property -dict { PACKAGE_PIN D17   IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { CAM_SIOC }];   # JA7 (SCL)
set_property -dict { PACKAGE_PIN E17   IOSTANDARD LVCMOS33 } [get_ports { CAM_VSYNC }];              # JA8 (VSYNC)
set_property -dict { PACKAGE_PIN F18   IOSTANDARD LVCMOS33 } [get_ports { CAM_PWDN }];               # JA9 (PWDN)
set_property -dict { PACKAGE_PIN G18   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[7] }];               # JA10 (D7)

set_property -dict { PACKAGE_PIN D14   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[5] }];               # JB1 (D5)
set_property -dict { PACKAGE_PIN F16   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[4] }];               # JB2 (D4)
set_property -dict { PACKAGE_PIN G16   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[3] }];               # JB3 (D3)
set_property -dict { PACKAGE_PIN H14   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[2] }];               # JB4 (D2)
set_property -dict { PACKAGE_PIN E16   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[6] }];               # JB7 (D6)
set_property -dict { PACKAGE_PIN F13   IOSTANDARD LVCMOS33 } [get_ports { CAM_PCLK }];               # JB8 (PCLK, 非 MRCC)
set_property -dict { PACKAGE_PIN G13   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[0] }];               # JB9 (D0)
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { CAM_D[1] }];               # JB10 (D1)

## 驱动与摆率约束 (降低 VGA / XCLK 振铃)
set_property DRIVE 8   [get_ports { VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS CAM_XCLK }];
set_property SLEW SLOW [get_ports { VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS CAM_XCLK }];

## OV5640 像素时钟约束 (最大按 48 MHz 约束; JB8=F13 非专用时钟脚，开启非专用路由允许)
create_clock -add -name cam_pclk_pin -period 20.833 [get_ports { CAM_PCLK }];
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -quiet CAM_PCLK_IBUF];

## 低速异步外设与指示 IO 假路径 (复位/按键/开关/LED/串口/SCCB/SD 均已由 2-FF 同步器或低速协议保护)
set_false_path -from [get_ports { CPU_RESETN SW[*] UART_TXD_IN SD_CD SD_DAT[0] CAM_VSYNC CAM_HREF CAM_D[*] CAM_SIOD }];
set_false_path -to   [get_ports { LED[*] UART_RXD_OUT SD_RESET SD_SCK SD_CMD SD_DAT[1] SD_DAT[2] SD_DAT[3] CAM_SIOC CAM_SIOD CAM_RST_N CAM_PWDN }];

## 跨时钟域异步组约束 (所有 CDC 均已由 ASYNC_REG 2-FF 同步器或格雷码 async_fifo 保护)
## Round 4: clk_100m (SoC)、clk_25m (VGA)、ui_clk (MIG 75 MHz) 与 cam_pclk_pin 彼此独立异步
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_nets {clk_100m clk_200m clk_24m}]] \
  -group [get_clocks -of_objects [get_nets clk_25m]] \
  -group [get_clocks -of_objects [get_nets ui_clk]] \
  -group [get_clocks cam_pclk_pin];

## 配置电压、比特流压缩与 QSPI Flash (SPIx4) 固化属性
set_property CFGBVS VCCO [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design];
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design];
set_property CONFIG_MODE SPIx4 [current_design];
