/* ============================================================================
 * sw/soc_test/link.ld — 统一主存 SoC 链接脚本 (0x8000_0000 统一代码/数据/栈)
 * ============================================================================ */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 240K
}

SECTIONS {
  . = 0x80000000;

  .text : {
    *(.text.init)
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > RAM

  .data : ALIGN(4) {
    *(.data .data.* .sdata .sdata.*)
  } > RAM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    __bss_end = .;
  } > RAM

  _stack_top = 0x8003C000;
}
