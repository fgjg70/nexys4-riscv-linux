.org 0x00001000
_start:
  # 设置栈指针到 DDR2 高端临时安全区 (仅用于需要子程序嵌套时，此处全程使用寄存器+s区不依赖DDR2即可串口打印)
  li s0, 0x10000000       # s0 = UART_BASE (NS16550A)
  li a0, str_banner
  jal ra, uart_puts
  jal ra, run_all_tests

cmd_loop:
  li a0, str_prompt
  jal ra, uart_puts
cmd_wait:
  lw t0, 20(s0)           # UART_LSR (+0x14)
  andi t0, t0, 1          # bit0 = RX_DR
  beq t0, zero, cmd_wait
  lw s1, 0(s0)            # 读接收字节
  andi s1, s1, 0xFF
  mv a0, s1
  jal ra, uart_putc       # 串口回显
  li a0, str_nl
  jal ra, uart_puts
  li t0, 116              # 't' -> DDR2 test
  beq s1, t0, do_cmd_t
  li t0, 98               # 'b' -> Bench
  beq s1, t0, do_cmd_b
  li t0, 99               # 'c' -> Cam ID
  beq s1, t0, do_cmd_c
  li t0, 115              # 's' -> Status
  beq s1, t0, do_cmd_s
  li a0, str_done
  jal ra, uart_puts
  j cmd_wait

do_cmd_t:
  jal ra, test_ddr2
  j cmd_loop
do_cmd_b:
  jal ra, test_bench
  j cmd_loop
do_cmd_c:
  jal ra, test_cam
  j cmd_loop
do_cmd_s:
  jal ra, test_vga_sd
  j cmd_loop

# ======================================================================
# 自动全套上电自检 (s11 保存返回地址)
# ======================================================================
run_all_tests:
  mv s11, ra
  jal ra, test_ddr2
  jal ra, test_bench
  jal ra, test_vga_sd
  jal ra, test_cam
  li a0, str_done
  jal ra, uart_puts
  jalr zero, 0(s11)

# ======================================================================
# [1/5] 128 MB DDR2 跨区 + 16 KB D-Cache 驱逐 + 字节掩码 + SMC FENCE.I
# ======================================================================
test_ddr2:
  mv s10, ra
  li a0, str_t1
  jal ra, uart_puts

  # 1A) 128 MB 全空间 8 个边界点写入与回读
  li s2, ddr_span_tbl
  li s3, 8
  li s4, 0xA55A0001
span_wr_loop:
  lw t0, 0(s2)
  sw s4, 0(t0)
  addi s2, s2, 4
  addi s4, s4, 0x111
  addi s3, s3, -1
  bne s3, zero, span_wr_loop

  li s2, ddr_span_tbl
  li s3, 8
  li s4, 0xA55A0001
span_rd_loop:
  lw t0, 0(s2)
  lw t1, 0(t0)
  li a0, 1
  bne t1, s4, ddr2_fail
  addi s2, s2, 4
  addi s4, s4, 0x111
  addi s3, s3, -1
  bne s3, zero, span_rd_loop

  # 1B) 16 KB 连续写回驱逐 (4096 字 = 2x L1D 容量, 强压 100<->75 MHz FIFO)
  li t0, 0x80020000
  li t1, 4096
  li t2, 0x13570000
evict_wr:
  sw t2, 0(t0)
  addi t0, t0, 4
  addi t2, t2, 0x101
  addi t1, t1, -1
  bne t1, zero, evict_wr

  li t0, 0x80020000
  li t1, 4096
  li t2, 0x13570000
evict_rd:
  lw t3, 0(t0)
  li a0, 2
  bne t3, t2, ddr2_fail
  addi t0, t0, 4
  addi t2, t2, 0x101
  addi t1, t1, -1
  bne t1, zero, evict_rd

  # 1C) 128-bit 行内全 4 lane 字节/半字写掩码 (SB/SH/LW 校验)
  li t0, 0x80001000
  li t1, 0x11223344
  sw t1, 0(t0)
  sw t1, 4(t0)
  sw t1, 8(t0)
  sw t1, 12(t0)
  li t2, 0xAA
  sb t2, 1(t0)            # lane0 -> 0x1122AA44
  li t2, 0xBBCC
  sh t2, 6(t0)            # lane1 -> 0xBBCC3344
  li t2, 0xDD
  sb t2, 11(t0)           # lane2 -> 0xDD223344
  li t2, 0xEE
  sb t2, 12(t0)           # lane3 -> 0x112233EE
  lw t3, 0(t0)
  li t4, 0x1122AA44
  li a0, 3
  bne t3, t4, ddr2_fail
  lw t3, 4(t0)
  li t4, 0xBBCC3344
  li a0, 4
  bne t3, t4, ddr2_fail
  lw t3, 8(t0)
  li t4, 0xDD223344
  li a0, 5
  bne t3, t4, ddr2_fail
  lw t3, 12(t0)
  li t4, 0x112233EE
  li a0, 6
  bne t3, t4, ddr2_fail

  # 1D) DDR2 自修改代码 + FENCE.I (验证 D$ 清洗 + I$ 64B 填充 + 32-bit BTB + RAS)
  li t0, 0x80002000
  li t1, 0x02A50513       # addi a0, a0, 42
  sw t1, 0(t0)
  li t1, 0x00008067       # jalr zero, 0(ra) (ret)
  sw t1, 4(t0)
  .word 0x0000100F        # fence.i
  li a0, 100
  jalr ra, 0(t0)
  mv t5, a0
  li t1, 142
  li a0, 7
  bne t5, t1, ddr2_fail
ddr2_ok:
  li a0, str_pass
  jal ra, uart_puts
  jalr zero, 0(s10)
ddr2_fail:
  mv s5, a0
  li a0, str_fail
  jal ra, uart_puts
  mv a0, s5
  jal ra, uart_puthex
  li a0, str_nl
  jal ra, uart_puts
  jalr zero, 0(s10)

# ======================================================================
# [2/5] CPU 性能计数 + L0D Load-Use + 100 MHz / 1 MHz CLINT 互证基准
# ======================================================================
test_bench:
  mv s10, ra
  li a0, str_t2
  jal ra, uart_puts
  li t6, 0x0200BFF8       # CLINT_MTIME_L (1 MHz)
  li t5, 0x80001000       # L0D 热地址
  li t0, 0x00000001
  sw t0, 0(t5)
  csrr s2, mcycle
  csrr s3, minstret
  lw s4, 0(t6)
  li t1, 2000             # 2000 次循环 (含 L0D 命中、ALU 与分支预测)
  li t2, 0
bench_loop:
  lw t3, 0(t5)
  addi t1, t1, -1
  add t2, t2, t3
  bne t1, zero, bench_loop
  csrr t0, mcycle
  csrr t1, minstret
  lw t4, 0(t6)
  sub s2, t0, s2          # delta mcycle
  sub s3, t1, s3          # delta minstret
  sub s4, t4, s4          # delta mtime (us @ 1 MHz)
  mv a0, s2
  jal ra, uart_puthex
  li a0, str_ins
  jal ra, uart_puts
  mv a0, s3
  jal ra, uart_puthex
  li a0, str_mt
  jal ra, uart_puts
  mv a0, s4
  jal ra, uart_puthex
  li a0, str_nl
  jal ra, uart_puts
  jalr zero, 0(s10)

# ======================================================================
# [3/5] VGA (640x480 彩条确认) & [4/5] microSD SPI 卡槽检测
# ======================================================================
test_vga_sd:
  mv s10, ra
  li t5, 0x10002000       # VGA_BASE
  li t0, 1                # EN=1, MODE=0 (8 色彩条)
  sw t0, 0(t5)
  lw s2, 12(t5)           # VGA_RES_ID (+0x0C = 0x028001E0)
  lw s3, 4(t5)            # VGA_STAT (+0x04, [31:16]=frame_cnt)
  srli s3, s3, 16
  li a0, str_t3
  jal ra, uart_puts
  mv a0, s2
  jal ra, uart_puthex
  li a0, str_fr
  jal ra, uart_puts
  mv a0, s3
  jal ra, uart_puthex
  li a0, str_nl
  jal ra, uart_puts

  li a0, str_t4
  jal ra, uart_puts
  li t5, 0x10001000       # SPI_BASE
  lw t0, 4(t5)            # SPI_STAT (+0x04, bit1 = SD_CD_N)
  andi t0, t0, 2
  bne t0, zero, sd_empty
  li a0, str_sd_in
  jal ra, uart_puts
  jalr zero, 0(s10)
sd_empty:
  li a0, str_sd_no
  jal ra, uart_puts
  jalr zero, 0(s10)

# ======================================================================
# [5/5] OV5640 SCCB 芯片 ID 探测 (0x300A=0x56, 0x300B=0x40, 无卡不死等)
# ======================================================================
test_cam:
  mv s10, ra
  li a0, str_t5
  jal ra, uart_puts
  li s6, 0x10003000       # CAM_BASE
  # 读 0x300A (Chip ID High)
  li a0, 0x300A
  jal ra, sccb_read_reg
  bne a1, zero, cam_nack
  mv s2, a0
  # 读 0x300B (Chip ID Low)
  li a0, 0x300B
  jal ra, sccb_read_reg
  bne a1, zero, cam_nack
  slli s2, s2, 8
  or s2, s2, a0           # 预期 0x00005640
  li a0, str_cam_ok
  jal ra, uart_puts
  mv a0, s2
  jal ra, uart_puthex
  li a0, str_nl
  jal ra, uart_puts
  jalr zero, 0(s10)
cam_nack:
  li a0, str_cam_no
  jal ra, uart_puts
  jalr zero, 0(s10)

# sccb_read_reg(a0=reg16) -> a0=data8, a1=err(0=ok, 1=nack/timeout)
sccb_read_reg:
  sw a0, 8(s6)            # CAM_SCCB_OP (+0x08)
  li t0, 0x0A             # CTRL: CAM_RST_N=1 (bit3), SCCB_RD=1 (bit1)
  sw t0, 0(s6)
  li t1, 200000           # 超时保护 (~2 ms @ 100 MHz)
sccb_wait:
  lw t2, 4(s6)            # CAM_STAT (+0x04): bit0=BUSY, bit1=NACK
  andi t3, t2, 1
  beq t3, zero, sccb_done
  addi t1, t1, -1
  bne t1, zero, sccb_wait
  li a0, 0
  li a1, 1
  ret
sccb_done:
  andi a1, t2, 2          # bit1 = SCCB_NACK
  lw a0, 12(s6)           # CAM_SCCB_RD (+0x0C)
  andi a0, a0, 0xFF
  ret

# ======================================================================
# UART 工具函数 (使用 s0=0x10000000, 仅破坏 t0-t4, a0)
# ======================================================================
uart_putc:
  lw t0, 20(s0)           # LSR (+0x14)
  andi t0, t0, 0x20       # bit5 = THRE
  beq t0, zero, uart_putc
  sw a0, 0(s0)            # THR (+0x00)
  ret

uart_puts:
  mv t4, ra
  mv t1, a0
puts_loop:
  lbu a0, 0(t1)
  beq a0, zero, puts_done
  jal ra, uart_putc
  addi t1, t1, 1
  j puts_loop
puts_done:
  jalr zero, 0(t4)

uart_puthex:
  mv t4, ra
  mv t1, a0
  li t2, 28
hex_loop:
  srl t3, t1, t2
  andi t3, t3, 0xF
  li a0, 10
  blt t3, a0, hex_dig
  addi a0, t3, 55         # 'A' - 10
  j hex_emit
hex_dig:
  addi a0, t3, 48         # '0'
hex_emit:
  jal ra, uart_putc
  addi t2, t2, -4
  bge t2, zero, hex_loop
  jalr zero, 0(t4)

# ======================================================================
# 只读数据表 (128 MB DDR2 跨区探测地址 + 字符串池)
# ======================================================================
.align 2
ddr_span_tbl:
  .word 0x80000000
  .word 0x80004004
  .word 0x80100008
  .word 0x8100000C
  .word 0x82000010
  .word 0x84000014
  .word 0x86000018
  .word 0x87FFF01C
str_banner:
  .word 0x3d3d0a0d
  .word 0x454e203d
  .word 0x34535958
  .word 0x33565220
  .word 0x414d4932
  .word 0x30303120
  .word 0x207a484d
  .word 0x4e495242
  .word 0x20505547
  .word 0x0d3d3d3d
  .word 0x0000000a
str_t1:
  .word 0x352f315b
  .word 0x4444205d
  .word 0x31203252
  .word 0x424d3832
  .word 0x61707320
  .word 0x202b206e
  .word 0x424b3631
  .word 0x69766520
  .word 0x2b207463
  .word 0x73616d20
  .word 0x202b206b
  .word 0x3a434d53
  .word 0x00000020
str_pass:
  .word 0x53534150
  .word 0x00000a0d
str_fail:
  .word 0x4c494146
  .word 0x646f6320
  .word 0x00003d65
str_t2:
  .word 0x352f325b
  .word 0x6542205d
  .word 0x2068636e
  .word 0x3d435943
  .word 0x00000000
str_ins:
  .word 0x534e4920
  .word 0x0000003d
str_mt:
  .word 0x49544d20
  .word 0x003d454d
str_t3:
  .word 0x352f335b
  .word 0x4756205d
  .word 0x44492041
  .word 0x0000003d
str_fr:
  .word 0x3d524620
  .word 0x00000000
str_t4:
  .word 0x352f345b
  .word 0x4453205d
  .word 0x3d44435f
  .word 0x00000000
str_sd_in:
  .word 0x45534e49
  .word 0x44455452
  .word 0x00000a0d
str_sd_no:
  .word 0x54504d45
  .word 0x000a0d59
str_t5:
  .word 0x352f355b
  .word 0x564f205d
  .word 0x30343635
  .word 0x43435320
  .word 0x00002042
str_cam_ok:
  .word 0x003d4449
str_cam_no:
  .word 0x4b43414e
  .word 0x73626128
  .word 0x29746e65
  .word 0x00000a0d
str_done:
  .word 0x44414552
  .word 0x43202159
  .word 0x203a646d
  .word 0x445d745b
  .word 0x20325244
  .word 0x425d625b
  .word 0x68636e65
  .word 0x5d635b20
  .word 0x206d6143
  .word 0x535d735b
  .word 0x0d746174
  .word 0x0000000a
str_nl:
  .word 0x00000a0d
str_prompt:
  .word 0x0000203e
