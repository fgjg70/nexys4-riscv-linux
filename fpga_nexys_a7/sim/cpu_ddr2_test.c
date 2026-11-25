#include <stdint.h>

#define REG32(address) (*(volatile uint32_t *)(address))

static unsigned errors;

static void expect_word(uint32_t address, uint32_t expected) {
    if (REG32(address) != expected) errors++;
}

int main(void) {
    unsigned timeout = 100000;
    while ((REG32(0xa100007cu) & 0x7fu) != 0x0fu && timeout) timeout--;
    if (!timeout) {
        REG32(0xa1000050u) = 0xdead0001u;
        for (;;) {}
    }
    expect_word(0xa100009cu, 0x08000000u);
    REG32(0xa1000100u) = 0;
    REG32(0xc0000000u) = 0x13579bdfu;
    REG32(0xc2000000u) = 0x2468ace0u;
    REG32(0xc4000000u) = 0x12345678u;
    REG32(0xc6000000u) = 0x99887766u;
    REG32(0xc7fffffcu) = 0x88776655u;
    REG32(0xa1000100u) = 5;
    expect_word(0xc0000000u, 0x13579bdfu);
    expect_word(0xc0000000u, 0x13579bdfu);
    expect_word(0xc2000000u, 0x2468ace0u);
    expect_word(0xc2000000u, 0x2468ace0u);
    expect_word(0xc4000000u, 0x12345678u);
    expect_word(0xc4000000u, 0x12345678u);
    expect_word(0xc6000000u, 0x99887766u);
    expect_word(0xc6000000u, 0x99887766u);
    expect_word(0xc7fffffcu, 0x88776655u);
    expect_word(0xc7fffffcu, 0x88776655u);
    if (REG32(0xa1000104u) < 5 || REG32(0xa1000108u) < 5) errors++;
    *(volatile uint8_t *)0xc4000001u = 0xabu;
    *(volatile uint16_t *)0xc2000002u = 0xcdefu;
    *(volatile uint8_t *)0xc7ffffffu = 0xddu;
    expect_word(0xc4000000u, 0x1234ab78u);
    expect_word(0xc2000000u, 0xcdeface0u);
    expect_word(0xc7fffffcu, 0xdd776655u);
    REG32(0xa1000100u) = 0;
    expect_word(0xc4000000u, 0x1234ab78u);
    expect_word(0xc2000000u, 0xcdeface0u);
    expect_word(0xc7fffffcu, 0xdd776655u);
    expect_word(0xc8000000u, 0xdd200badu);
    expect_word(0xc0000000u, 0x13579bdfu);
    expect_word(0xc6000000u, 0x99887766u);
    REG32(0xa1000050u) = errors ? 0xdead1000u | errors : 0x600d600du;
    for (;;) {}
}
