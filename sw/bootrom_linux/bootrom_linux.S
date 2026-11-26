.org 0x00001000
_start:
  # 纯寄存器无栈引导 (兼容 256 KB 仿真 RAM 与 128 MB 实板 DDR2)
  # 固定基址: s0 = NS16550A UART (0x1000_0000), s1 = SPI Master (0x1000_1000)
  li   s0, 0x10000000
  li   s1, 0x10001000
  li   a0, str_banner
  jal  ra, uart_puts

  # 快速检查串口控制键 ('u'=强制进 UART 下载, 'j'=直接跳 0x8000_0000)
  lw   t0, 20(s0)          # LSR (+0x14)
  andi t0, t0, 1           # RX_DR
  beqz t0, check_sd
  lw   t0, 0(s0)
  andi t0, t0, 0xFF
  li   t1, 117             # 'u'
  beq  t0, t1, uart_loader
  li   t1, 106             # 'j'
  beq  t0, t1, direct_jump

# ======================================================================
# 1) microSD SPI Mode 0 初始化与 NX4L 镜像加载
# ======================================================================
check_sd:
  lw   t0, 4(s1)           # SPI_STAT (+0x04): bit1 = SD_CD_N (0=插卡)
  andi t0, t0, 2
  bnez t0, uart_loader

  li   a0, str_sd_init
  jal  ra, uart_puts

  # CS_N=1, SD_RESET=0, 发送 10 字节 0xFF (80 dummy clocks)
  li   t0, 1
  sw   t0, 8(s1)
  li   s10, 10
sd_dummy:
  li   a0, 0xFF
  jal  ra, spi_xfer
  addi s10, s10, -1
  bnez s10, sd_dummy

  # CMD0 (GO_IDLE_STATE, arg=0, crc=0x95) -> 期望 R1 = 0x01
  li   s10, 16
sd_cmd0_retry:
  li   a0, 0x40
  li   a1, 0
  li   a2, 0x95
  jal  ra, sd_cmd
  li   t0, 1
  beq  a0, t0, sd_cmd0_ok
  jal  ra, sd_deselect
  addi s10, s10, -1
  bnez s10, sd_cmd0_retry
  j    sd_init_fail

sd_cmd0_ok:
  jal  ra, sd_deselect

  # CMD8 (SEND_IF_COND, arg=0x1AA, crc=0x87)
  li   a0, 0x48
  li   a1, 0x000001AA
  li   a2, 0x87
  jal  ra, sd_cmd
  li   t0, 1
  bne  a0, t0, sd_skip_r7
  # 消费 4 字节 R7
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
sd_skip_r7:
  jal  ra, sd_deselect

  # CMD55 + ACMD41 (HCS=1, arg=0x40000000) 循环直到 R1 == 0x00
  li   s10, 256
sd_acmd41_loop:
  li   a0, 0x77            # CMD55
  li   a1, 0
  li   a2, 0x65
  jal  ra, sd_cmd
  jal  ra, sd_deselect
  li   a0, 0x69            # ACMD41
  li   a1, 0x40000000
  li   a2, 0x77
  jal  ra, sd_cmd
  mv   s11, a0
  jal  ra, sd_deselect
  beqz s11, sd_ready
  addi s10, s10, -1
  bnez s10, sd_acmd41_loop
  j    sd_init_fail

sd_ready:
  # CMD58 (READ_OCR) 判定 SDHC (CCS = OCR[30]) vs SDSC
  li   a0, 0x7A
  li   a1, 0
  li   a2, 0xFD
  jal  ra, sd_cmd
  bnez a0, sd_init_fail_desel
  li   a0, 0xFF
  jal  ra, spi_xfer
  srli s9, a0, 6
  andi s9, s9, 1           # s9 = 1(SDHC块寻址) / 0(SDSC字节寻址)
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
  jal  ra, sd_deselect

  # 提速 SPI 时钟 (若原分频 > 3 则降至 3 -> ~16.7 MHz @ 100 MHz, 仿真低压测保持原值)
  lw   t0, 12(s1)
  li   t1, 3
  blt  t0, t1, sd_div_keep
  sw   t1, 12(s1)
sd_div_keep:
  beqz s9, sd_print_sdsc
  li   a0, str_sdhc
  jal  ra, uart_puts
  j    sd_read_hdr
sd_print_sdsc:
  li   a0, str_sdsc
  jal  ra, uart_puts

  # 尝试读取 LBA 0 的 NX4L 镜像头到临时缓冲 0x8000_0000; 不匹配则再试 LBA 1
sd_read_hdr:
  li   a0, 0
  li   a1, 0x80000000
  jal  ra, sd_read_sector
  bnez a0, sd_init_fail
  li   t0, 0x80000000
  lw   t1, 0(t0)
  li   t2, 0x4E58344C      # 'NX4L' little-endian
  beq  t1, t2, sd_hdr_ok
  li   a0, 1
  li   a1, 0x80000000
  jal  ra, sd_read_sector
  bnez a0, sd_init_fail
  li   t0, 0x80000000
  lw   t1, 0(t0)
  li   t2, 0x4E58344C
  bne  t1, t2, sd_init_fail

sd_hdr_ok:
  # 解析 32 字节 NX4L 头到 s2..s8
  lw   s2, 4(t0)           # payload_load_addr
  lw   s3, 8(t0)           # payload_byte_size
  lw   s4, 12(t0)          # payload_start_lba
  lw   s5, 16(t0)          # dtb_load_addr
  lw   s6, 20(t0)          # dtb_byte_size
  lw   s7, 24(t0)          # dtb_start_lba
  lw   s8, 28(t0)          # entry_pc
  li   a0, str_sd_hdr
  jal  ra, uart_puts

  # 加载 Payload: n_sec = (s3 + 511) >> 9
  addi s10, s3, 511
  srli s10, s10, 9
  mv   s11, s2             # 当前写指针
sd_load_pay:
  beqz s10, sd_load_dtb
  mv   a0, s4
  mv   a1, s11
  jal  ra, sd_read_sector
  bnez a0, sd_init_fail
  addi s4, s4, 1
  addi s11, s11, 512
  addi s10, s10, -1
  andi t0, s10, 63
  bnez t0, sd_load_pay
  li   a0, 46              # '.' 进度点
  jal  ra, uart_putc
  j    sd_load_pay

sd_load_dtb:
  beqz s6, do_boot_jump
  li   a0, str_sd_dtb
  jal  ra, uart_puts
  addi s10, s6, 511
  srli s10, s10, 9
  mv   s11, s5
sd_load_dtb_loop:
  beqz s10, do_boot_jump
  mv   a0, s7
  mv   a1, s11
  jal  ra, sd_read_sector
  bnez a0, sd_init_fail
  addi s7, s7, 1
  addi s11, s11, 512
  addi s10, s10, -1
  j    sd_load_dtb_loop

sd_init_fail_desel:
  jal  ra, sd_deselect
sd_init_fail:
  li   a0, str_sd_fail
  jal  ra, uart_puts

# ======================================================================
# 2) UART 二进制加载协议 (NX4U: 4B magic + 16B header + payload + 4B csum)
# ======================================================================
uart_loader:
  li   a0, str_uart_wait
  jal  ra, uart_puts
uart_sync:
  jal  ra, uart_getc
  li   t0, 0x4E            # 'N'
  bne  a0, t0, uart_sync
  jal  ra, uart_getc
  li   t0, 0x58            # 'X'
  bne  a0, t0, uart_sync
  jal  ra, uart_getc
  li   t0, 0x34            # '4'
  bne  a0, t0, uart_sync
  jal  ra, uart_getc
  li   t0, 0x55            # 'U'
  bne  a0, t0, uart_sync

  # 读取 load_addr (s2), byte_len (s3), entry_pc (s8), dtb_addr (s5)
  jal  ra, uart_get32
  mv   s2, a0
  jal  ra, uart_get32
  mv   s3, a0
  jal  ra, uart_get32
  mv   s8, a0
  jal  ra, uart_get32
  mv   s5, a0

  li   s6, 0               # 32-bit 累加校验和
  mv   s11, s2
  mv   s10, s3
uart_rx_data:
  beqz s10, uart_rx_done
  jal  ra, uart_getc
  sb   a0, 0(s11)
  add  s6, s6, a0
  addi s11, s11, 1
  addi s10, s10, -1
  j    uart_rx_data

uart_rx_done:
  # 回传 4 字节小端校验和供主机确认
  andi a0, s6, 0xFF
  jal  ra, uart_putc
  srli a0, s6, 8
  andi a0, a0, 0xFF
  jal  ra, uart_putc
  srli a0, s6, 16
  andi a0, a0, 0xFF
  jal  ra, uart_putc
  srli a0, s6, 24
  andi a0, a0, 0xFF
  jal  ra, uart_putc

  # entry_pc == 0 表示继续接收下一文件 (例如先传 DTB 再传 fw_payload.bin)
  beqz s8, uart_sync
  j    do_boot_jump

direct_jump:
  li   s8, 0x80000000
  li   s5, 0

# ======================================================================
# 3) 标准 RISC-V OpenSBI / Linux 跳转 ABI (fence.i, a0=hartid=0, a1=dtb)
# ======================================================================
do_boot_jump:
  li   a0, str_boot
  jal  ra, uart_puts
  mv   a0, s8
  jal  ra, uart_puthex
  li   a0, str_nl
  jal  ra, uart_puts
  fence.i                  # 清洗回写 D-Cache 到 DDR2 并清空 I-Cache/BTB
  li   a0, 0               # mhartid = 0
  mv   a1, s5              # dtb 物理地址 (内置 DTB 时为 0)
  jalr zero, 0(s8)

# ======================================================================
# SPI & SD 子程序 (仅使用 t0..t6, a0..a5, 无栈)
# ======================================================================
# spi_xfer(a0=tx8) -> a0=rx8 (不破坏 t3..t6, a1..a5)
spi_xfer:
  sw   a0, 0(s1)
spi_wait:
  lw   t0, 4(s1)
  andi t0, t0, 1
  bnez t0, spi_wait
  lw   a0, 0(s1)
  andi a0, a0, 0xFF
  ret

# sd_deselect(): CS_N=1 并补 1 字节 0xFF 释放 MISO
sd_deselect:
  mv   t6, ra
  li   t0, 1
  sw   t0, 8(s1)
  li   a0, 0xFF
  jal  ra, spi_xfer
  jr   t6

# sd_cmd(a0=cmd|0x40, a1=arg32, a2=crc8) -> a0=R1 (返回时 CS_N 保持拉低)
sd_cmd:
  mv   t6, ra
  mv   t3, a0
  mv   t4, a1
  mv   t5, a2
  sw   zero, 8(s1)         # CS_N = 0
  li   a0, 0xFF
  jal  ra, spi_xfer
  mv   a0, t3
  jal  ra, spi_xfer
  srli a0, t4, 24
  andi a0, a0, 0xFF
  jal  ra, spi_xfer
  srli a0, t4, 16
  andi a0, a0, 0xFF
  jal  ra, spi_xfer
  srli a0, t4, 8
  andi a0, a0, 0xFF
  jal  ra, spi_xfer
  andi a0, t4, 0xFF
  jal  ra, spi_xfer
  mv   a0, t5
  jal  ra, spi_xfer
  # 轮询最多 32 字节等待 R1 (bit7 == 0)
  li   t2, 32
sd_cmd_r1:
  li   a0, 0xFF
  jal  ra, spi_xfer
  andi t1, a0, 0x80
  beqz t1, sd_cmd_done
  addi t2, t2, -1
  bnez t2, sd_cmd_r1
sd_cmd_done:
  jr   t6

# sd_read_sector(a0=lba, a1=dst_addr) -> a0=0(OK)/1(ERR)
sd_read_sector:
  mv   a5, ra
  mv   a4, a1              # dst_addr
  mv   a1, a0              # arg = lba (SDHC) 或 lba<<9 (SDSC)
  bnez s9, sd_rd_is_hc
  slli a1, a1, 9
sd_rd_is_hc:
  li   a0, 0x51            # CMD17 (READ_SINGLE_BLOCK)
  li   a2, 0xFF
  jal  ra, sd_cmd
  bnez a0, sd_rd_err
  # 等待数据起始令牌 0xFE
  li   t2, 4096
sd_wait_fe:
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   t1, 0xFE
  beq  a0, t1, sd_got_fe
  addi t2, t2, -1
  bnez t2, sd_wait_fe
  j    sd_rd_err
sd_got_fe:
  li   t2, 512
sd_rd_bytes:
  li   a0, 0xFF
  jal  ra, spi_xfer
  sb   a0, 0(a4)
  addi a4, a4, 1
  addi t2, t2, -1
  bnez t2, sd_rd_bytes
  # 消费 2 字节 CRC16 并拉高 CS_N
  li   a0, 0xFF
  jal  ra, spi_xfer
  li   a0, 0xFF
  jal  ra, spi_xfer
  jal  ra, sd_deselect
  li   a0, 0
  jr   a5
sd_rd_err:
  jal  ra, sd_deselect
  li   a0, 1
  jr   a5

# ======================================================================
# UART 工具函数 (使用 s0=0x1000_0000, 无栈)
# ======================================================================
uart_putc:
  lw   t0, 20(s0)
  andi t0, t0, 0x20        # THRE
  beqz t0, uart_putc
  sw   a0, 0(s0)
  ret

uart_getc:
  lw   t0, 20(s0)
  andi t0, t0, 1           # RX_DR
  beqz t0, uart_getc
  lw   a0, 0(s0)
  andi a0, a0, 0xFF
  ret

# uart_get32() -> a0=little-endian uint32 (使用 t3, t4, t5)
uart_get32:
  mv   t5, ra
  jal  ra, uart_getc
  mv   t3, a0
  jal  ra, uart_getc
  slli a0, a0, 8
  or   t3, t3, a0
  jal  ra, uart_getc
  slli a0, a0, 16
  or   t3, t3, a0
  jal  ra, uart_getc
  slli a0, a0, 24
  or   a0, t3, a0
  jr   t5

uart_puts:
  mv   t4, ra
  mv   t1, a0
puts_loop:
  lbu  a0, 0(t1)
  beqz a0, puts_done
  jal  ra, uart_putc
  addi t1, t1, 1
  j    puts_loop
puts_done:
  jr   t4

uart_puthex:
  mv   t4, ra
  mv   t1, a0
  li   t2, 28
hex_loop:
  srl  t3, t1, t2
  andi t3, t3, 0xF
  li   a0, 10
  blt  t3, a0, hex_dig
  addi a0, t3, 55
  j    hex_emit
hex_dig:
  addi a0, t3, 48
hex_emit:
  jal  ra, uart_putc
  addi t2, t2, -4
  bge  t2, zero, hex_loop
  jr   t4

.align 2
str_banner:
  .word 0x3d3d0a0d
  .word 0x454e203d
  .word 0x34535958
  .word 0x33565220
  .word 0x414d4932
  .word 0x3376532d
  .word 0x494c2032
  .word 0x2058554e
  .word 0x544f4f42
  .word 0x204d4f52
  .word 0x302e3276
  .word 0x3d3d3d20
  .word 0x00000a0d
str_sd_init:
  .word 0x5d44535b
  .word 0x696e4920
  .word 0x2e2e2e74
  .word 0x00000020
str_sdhc:
  .word 0x28204b4f
  .word 0x43484453
  .word 0x000a0d29
str_sdsc:
  .word 0x28204b4f
  .word 0x43534453
  .word 0x000a0d29
str_sd_hdr:
  .word 0x5d44535b
  .word 0x61654820
  .word 0x20726564
  .word 0x4c34584e
  .word 0x2c4b4f20
  .word 0x616f6c20
  .word 0x676e6964
  .word 0x0d2e2e2e
  .word 0x0000000a
str_sd_dtb:
  .word 0x535b0a0d
  .word 0x4c205d44
  .word 0x6964616f
  .word 0x4420676e
  .word 0x2e2e4254
  .word 0x000a0d2e
str_sd_fail:
  .word 0x4c494146
  .word 0x00000a0d
str_uart_wait:
  .word 0x5241555b
  .word 0x57205d54
  .word 0x69746961
  .word 0x4e20676e
  .word 0x20553458
  .word 0x65727473
  .word 0x28206d61
  .word 0x32353131
  .word 0x38203030
  .word 0x2e29314e
  .word 0x0a0d2e2e
  .word 0x00000000
str_boot:
  .word 0x425b0a0d
  .word 0x5d544f4f
  .word 0x6d754a20
  .word 0x78302070
  .word 0x00000000
str_nl:
  .word 0x00000a0d
