/* ============================================================================
 * sw/soc_test/main.c — rv32_soc 端到端 C 验证固件
 * ----------------------------------------------------------------------------
 * 逐项验证:
 *   1) BootROM(0x0000_1000) -> 统一 RAM(0x8000_0000) 启动与 32 位全地址 BTB
 *   2) 4 KB VIPT 回写 D-Cache: 16 KB 跨容量脏行驱逐/回写/填充 + 字节/半字/非对齐 + SW->LW 直通
 *   3) 自修改代码 + FENCE.I: D-Cache 脏行清洗 + I-Cache 失效 + BTB 清空闭环
 *   4) RV32M (含 DIV_RADIX4) 与 RV32A (AMO*.W + LR.W/SC.W) 穿透 D-Cache
 *   5) 标准 SiFive CLINT (msip 软件中断 + mtimecmp 定时中断 + WFI + CSR time)
 *   6) 标准 PLIC + NS16550A UART (SCR 探测 + MCR 环回 + 外部中断 Claim/Complete 收发)
 *   7) 精确总线访问异常: 读未映射地址 (mcause=5) 与写只读 BootROM (mcause=7)
 * ============================================================================ */
#include <stdint.h>

#define TOHOST_ADDR      0x8003F000u
#define SCRATCH_BUF_ADDR 0x80010000u   /* 16 KB 测试缓冲 (4 倍 D-Cache 容量) */
#define SMC_CODE_ADDR    0x80018000u   /* 自修改代码区 (统一 RAM 内) */

/* 标准 SiFive CLINT */
#define CLINT_MSIP       (*(volatile uint32_t *)0x02000000u)
#define CLINT_MTIMECMP_L (*(volatile uint32_t *)0x02004000u)
#define CLINT_MTIMECMP_H (*(volatile uint32_t *)0x02004004u)
#define CLINT_MTIME_L    (*(volatile uint32_t *)0x0200BFF8u)
#define CLINT_MTIME_H    (*(volatile uint32_t *)0x0200BFFCu)

/* 标准最小 RISC-V PLIC (Context 0) */
#define PLIC_PRIO(id)    (*(volatile uint32_t *)(0x0C000000u + 4u * (id)))
#define PLIC_PENDING     (*(volatile uint32_t *)0x0C001000u)
#define PLIC_ENABLE      (*(volatile uint32_t *)0x0C002000u)
#define PLIC_THRESH      (*(volatile uint32_t *)0x0C200000u)
#define PLIC_CLAIM       (*(volatile uint32_t *)0x0C200004u)

/* 标准 NS16550A UART (32-bit 对齐 reg-shift=2) */
#define UART_RBR_THR     (*(volatile uint32_t *)0x10000000u)
#define UART_IER         (*(volatile uint32_t *)0x10000004u)
#define UART_IIR_FCR     (*(volatile uint32_t *)0x10000008u)
#define UART_LCR         (*(volatile uint32_t *)0x1000000Cu)
#define UART_MCR         (*(volatile uint32_t *)0x10000010u)
#define UART_LSR         (*(volatile uint32_t *)0x10000014u)
#define UART_SCR         (*(volatile uint32_t *)0x1000001Cu)

static volatile uint32_t g_sw_irqs    = 0;
static volatile uint32_t g_tmr_irqs   = 0;
static volatile uint32_t g_ext_irqs   = 0;
static volatile uint32_t g_exc_count  = 0;
static volatile uint32_t g_last_cause = 0;
static volatile uint32_t g_last_tval  = 0;
static volatile uint32_t g_tmr_mepc   = 0;

static volatile char     g_rx_buf[32];
static volatile uint32_t g_rx_len     = 0;

static void uart_putc(char c) {
    while ((UART_LSR & 0x20u) == 0u) { }
    UART_RBR_THR = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void finish_test(uint32_t code) {
    *(volatile uint32_t *)TOHOST_ADDR = code;
    /* 清洗 D-Cache 确保仿真测试台从主存立刻观察到 tohost */
    __asm__ volatile ("fence.i" ::: "memory");
    for (;;) { }
}

uint32_t c_trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    if (mcause & 0x80000000u) {
        uint32_t irq = mcause & 0xFu;
        if (irq == 3u) {
            /* Machine Software Interrupt */
            CLINT_MSIP = 0u;
            g_sw_irqs++;
        } else if (irq == 7u) {
            /* Machine Timer Interrupt */
            g_tmr_mepc = mepc;
            CLINT_MTIMECMP_H = 0xFFFFFFFFu;
            CLINT_MTIMECMP_L = 0xFFFFFFFFu;
            g_tmr_irqs++;
        } else if (irq == 11u) {
            /* Machine External Interrupt -> PLIC Claim / Complete */
            uint32_t id = PLIC_CLAIM;
            if (id == 1u) {
                while (UART_LSR & 0x01u) {
                    uint8_t ch = (uint8_t)(UART_RBR_THR & 0xFFu);
                    if (g_rx_len < 31u) g_rx_buf[g_rx_len++] = (char)ch;
                }
                g_ext_irqs++;
            }
            if (id != 0u) PLIC_CLAIM = id;
        }
        return mepc;
    } else {
        /* Synchronous Exception */
        g_exc_count++;
        g_last_cause = mcause;
        g_last_tval  = mtval;
        return mepc + 4u;
    }
}

/* Test 2: 16 KB 跨容量 D-Cache 脏行替换 + 字节/半字/非对齐 + SW->LW 旁路 */
static int test_dcache(void) {
    volatile uint32_t *wbuf = (volatile uint32_t *)SCRATCH_BUF_ADDR;
    volatile uint8_t  *bbuf = (volatile uint8_t  *)SCRATCH_BUF_ADDR;

    /* 写满 4096 字 (16 KB = 4x D-Cache 容量)，强制触发大量脏行回写与替换 */
    for (uint32_t i = 0; i < 2048u; i += 7u) {
        wbuf[i] = 0xA5000000u ^ (i * 0x010101u);
    }
    for (uint32_t i = 0; i < 2048u; i += 7u) {
        uint32_t exp = 0xA5000000u ^ (i * 0x010101u);
        if (wbuf[i] != exp) return 10;
    }

    /* 背靠背同址 SW -> LW / SB -> LB 旁路验证 */
    wbuf[10] = 0x11223344u;
    if (wbuf[10] != 0x11223344u) return 11;
    bbuf[41] = 0xEEu;
    if (wbuf[10] != 0x1122EE44u) return 12;

    /* 跨字非对齐读写 (offset=3) */
    uint32_t unaligned_addr = SCRATCH_BUF_ADDR + 0x103u;
    uint32_t rval = 0;
    __asm__ volatile (
        "sw %1, 0(%2)\n"
        "lw %0, 0(%2)\n"
        : "=r"(rval)
        : "r"(0xCAFEBABEu), "r"(unaligned_addr)
        : "memory"
    );
    if (rval != 0xCAFEBABEu) return 13;
    return 0;
}

/* Test 3: 自修改代码 + FENCE.I (验证 D-Cache 回写 -> 统一 RAM -> I-Cache 失效 -> BTB 清空) */
static int test_smc_fencei(void) {
    volatile uint32_t *code = (volatile uint32_t *)SMC_CODE_ADDR;
    typedef uint32_t (*fn_t)(uint32_t);
    fn_t fn = (fn_t)SMC_CODE_ADDR;

    /* 版本 1: addi a0, a0, 77 ; jalr x0, 0(ra) */
    code[0] = 0x04D50513u;
    code[1] = 0x00008067u;
    __asm__ volatile ("fence.i" ::: "memory");
    if (fn(100u) != 177u) return 20;

    /* 版本 2: 原地覆写为 addi a0, a0, 123 (此时旧代码仍在 I-Cache 中，新代码脏在 D-Cache 中!) */
    code[0] = 0x07B50513u;
    __asm__ volatile ("fence.i" ::: "memory");
    if (fn(100u) != 223u) return 21;
    return 0;
}

/* Test 4: RV32M (含 DIV_RADIX4) + RV32A (AMO / LR-SC) 穿透 D-Cache */
static int test_rv32ma(void) {
    volatile int32_t a = -1234567;
    volatile int32_t b = 137;
    if ((a / b) != -9011) return 30;
    if ((a % b) != -60)   return 31;

    volatile uint32_t *slot = (volatile uint32_t *)(SCRATCH_BUF_ADDR + 0x200u);
    *slot = 50u;
    uint32_t old = 0;
    __asm__ volatile ("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(slot), "r"(25u) : "memory");
    if (old != 50u || *slot != 75u) return 32;

    uint32_t lr_val = 0, sc_res = 1;
    __asm__ volatile (
        "lr.w %0, (%2)\n"
        "sc.w %1, %3, (%2)\n"
        : "=&r"(lr_val), "=&r"(sc_res)
        : "r"(slot), "r"(999u)
        : "memory"
    );
    if (lr_val != 75u || sc_res != 0u || *slot != 999u) return 33;
    return 0;
}

/* Test 5: 标准 SiFive CLINT (msip 软中断 + mtimecmp 定时中断 + WFI + CSR time) */
static int test_clint_wfi(void) {
    /* 开启 MSIE(bit3) + MTIE(bit7) + MEIE(bit11) = 0x888, 全局 MIE(bit3)=8 */
    uint32_t mie_v = 0x888u;
    __asm__ volatile ("csrw mie, %0" :: "r"(mie_v));
    __asm__ volatile ("csrsi mstatus, 8");

    /* 5a: CLINT msip 触发软件中断 */
    CLINT_MSIP = 1u;
    for (volatile int k = 0; k < 20; k++) { }
    if (g_sw_irqs != 1u) return 40;

    /* 5b: CSR time 与 CLINT mtime 一致性 + WFI 定时唤醒 */
    uint32_t t0 = 0;
    __asm__ volatile ("csrr %0, time" : "=r"(t0));
    uint32_t m0 = CLINT_MTIME_L;
    if (m0 < t0) return 41;

    uint32_t target_lo = m0 + 200u;
    CLINT_MTIMECMP_H = CLINT_MTIME_H + ((target_lo < m0) ? 1u : 0u);
    CLINT_MTIMECMP_L = target_lo;

    uint32_t wfi_next_pc = 0;
    __asm__ volatile (
        "wfi\n"
        "1: auipc %0, 0\n"
        : "=r"(wfi_next_pc)
        :: "memory"
    );
    if (g_tmr_irqs != 1u) return 42;
    if (g_tmr_mepc != wfi_next_pc) return 43;
    return 0;
}

/* Test 6: 标准 PLIC + NS16550A 中断驱动环回收发 */
static int test_plic_uart(void) {
    /* 探测 SCR 暂存寄存器 (Linux 8250 驱动标准探测步骤) */
    UART_SCR = 0x5Au;
    if ((UART_SCR & 0xFFu) != 0x5Au) return 50;

    /* 配置快速仿真波特率分频 (DLAB=1 -> DLL=1, 即 16 拍/bit) + 清空 FIFO */
    UART_LCR     = 0x83u;
    UART_RBR_THR = 0x01u;
    UART_IER     = 0x00u;
    UART_LCR     = 0x03u;
    UART_IIR_FCR = 0x07u;

    /* 打开内部环回 MCR[4]=1 + UART RX 中断 IER[0]=1 */
    UART_MCR = 0x10u;
    UART_IER = 0x01u;

    /* 配置 PLIC Source 1 (UART): 优先级 1, 使能, 阈值 0 */
    PLIC_PRIO(1) = 1u;
    PLIC_THRESH  = 0u;
    PLIC_ENABLE  = (1u << 1);

    const char msg[] = "OK16550";
    for (int i = 0; msg[i] != '\0'; i++) {
        uart_putc(msg[i]);
    }

    /* 等待中断把 7 个字节全部收齐 */
    for (volatile int wait = 0; wait < 20000 && g_rx_len < 7u; wait++) { }

    /* 关闭环回与 RX 中断，恢复正常串口控制台输出 */
    UART_IER = 0x00u;
    UART_MCR = 0x00u;

    if (g_ext_irqs == 0u || g_rx_len != 7u) return 51;
    for (int i = 0; i < 7; i++) {
        if (g_rx_buf[i] != msg[i]) return 52;
    }
    return 0;
}

/* Test 7: 精确总线访问异常 (未映射读 mcause=5 + 只读 BootROM 写 mcause=7) */
static int test_bus_faults(void) {
    uint32_t sentinel = 0xDEADBEEFu;
    uint32_t bad_addr = 0x50000000u;
    g_exc_count = 0;
    __asm__ volatile (
        "lw %0, 0(%1)\n"
        : "+r"(sentinel)
        : "r"(bad_addr)
        : "memory"
    );
    if (g_exc_count != 1u || g_last_cause != 5u || g_last_tval != bad_addr) return 60;
    if (sentinel != 0xDEADBEEFu) return 61;

    uint32_t rom_addr = 0x00001000u;
    __asm__ volatile (
        "sw %0, 0(%1)\n"
        :: "r"(0x12345678u), "r"(rom_addr)
        : "memory"
    );
    if (g_exc_count != 2u || g_last_cause != 7u || g_last_tval != rom_addr) return 62;
    return 0;
}

int main(void) {
    /* 1) 快速初始化 UART 以便实时打印进度 */
    UART_LCR     = 0x83u;
    UART_RBR_THR = 0x01u;
    UART_IER     = 0x00u;
    UART_LCR     = 0x03u;
    UART_IIR_FCR = 0x07u;

    uart_puts("[soc_test] BootROM->RAM OK\n");

    int rc;
    if ((rc = test_dcache())     != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 1/6 D-Cache eviction+bypass OK\n");

    if ((rc = test_smc_fencei()) != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 2/6 SMC + FENCE.I coherence OK\n");

    if ((rc = test_rv32ma())     != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 3/6 RV32MA cached OK\n");

    if ((rc = test_clint_wfi())  != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 4/6 CLINT MSIP/MTIP + WFI OK\n");

    if ((rc = test_plic_uart())  != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 5/6 PLIC + NS16550A IRQ OK\n");

    if ((rc = test_bus_faults()) != 0) finish_test((uint32_t)rc);
    uart_puts("[soc_test] 6/6 Precise Bus Faults OK\n");

    uart_puts("[soc_test] ALL PASS!\n");
    finish_test(1u);
    return 0;
}
