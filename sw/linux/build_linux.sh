#!/usr/bin/env bash
# ============================================================================
# sw/linux/build_linux.sh — 在 Linux / WSL2 一键编译 OpenSBI + Sv32 Linux + BusyBox
# ----------------------------------------------------------------------------
# 依赖工具 (Ubuntu 22.04/24.04):
#   sudo apt install -y gcc-riscv64-linux-gnu device-tree-compiler \
#       bc bison flex libssl-dev libelf-dev cpio make git python3 curl
# 注意:
#   Ubuntu 的 gcc-riscv64-linux-gnu 支持 multilib 或需 riscv32 工具链;
#   若发行版未带 32 位 multilib glibc，建议用 Buildroot (configs/qemu_riscv32_virt_defconfig)
#   或 Bootlin 预编译 riscv32-ilp32-glibc 工具链:
#     https://toolchains.bootlin.com/ (arch=riscv32-ilp32d / riscv32-ilp32, NO FPU!)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$PWD/build_linux_rv32}"
CROSS_COMPILE="${CROSS_COMPILE:-riscv32-buildroot-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

OPENSBI_VER="${OPENSBI_VER:-v1.5.1}"
LINUX_VER="${LINUX_VER:-v6.6.60}"
BUSYBOX_VER="${BUSYBOX_VER:-1_36_1}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=== [1/5] Compile Device Tree (nexys4_rv32_sv32.dtb) ==="
dtc -I dts -O dtb -o "$WORK_DIR/nexys4_rv32_sv32.dtb" "$SCRIPT_DIR/nexys4_rv32_sv32.dts"

echo "=== [2/5] Build Minimal Static BusyBox initramfs (RV32IMA, soft-float) ==="
if [ ! -d busybox ]; then
  git clone --depth 1 --branch "$BUSYBOX_VER" https://git.busybox.net/busybox
fi
make -C busybox ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' busybox/.config
sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' busybox/.config
make -C busybox ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" \
  EXTRA_CFLAGS="-march=rv32ima_zicsr_zifencei -mabi=ilp32" -j"$JOBS"
make -C busybox ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" CONFIG_PREFIX="$WORK_DIR/rootfs" install

mkdir -p "$WORK_DIR/rootfs"/{dev,proc,sys,tmp,etc}
cat > "$WORK_DIR/rootfs/init" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || true
echo ""
echo "=============================================="
echo "  Welcome to Nexys 4 DDR RV32IMA-Sv32 Linux!"
echo "=============================================="
uname -a
cat /proc/cpuinfo
exec /bin/sh
EOF
chmod +x "$WORK_DIR/rootfs/init"
(cd "$WORK_DIR/rootfs" && find . | cpio -H newc -o | gzip -9 > "$WORK_DIR/initramfs.cpio.gz")

echo "=== [3/5] Build Linux $LINUX_VER (RV32IMA + Sv32 + embedded initramfs) ==="
if [ ! -d linux ]; then
  git clone --depth 1 --branch "$LINUX_VER" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
fi
make -C linux ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" rv32_defconfig
linux/scripts/kconfig/merge_config.sh -m -O linux linux/.config "$SCRIPT_DIR/linux_sv32_defconfig"
echo "CONFIG_INITRAMFS_SOURCE=\"$WORK_DIR/initramfs.cpio.gz\"" >> linux/.config
make -C linux ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C linux ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image

echo "=== [4/5] Build OpenSBI $OPENSBI_VER (fw_payload.bin @ 0x8000_0000, S-mode Linux @ 0x8040_0000) ==="
if [ ! -d opensbi ]; then
  git clone --depth 1 --branch "$OPENSBI_VER" https://github.com/riscv-software-src/opensbi.git
fi
make -C opensbi \
  CROSS_COMPILE="$CROSS_COMPILE" \
  PLATFORM=generic \
  PLATFORM_RISCV_XLEN=32 \
  PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
  PLATFORM_RISCV_ABI=ilp32 \
  FW_TEXT_START=0x80000000 \
  FW_PAYLOAD_OFFSET=0x400000 \
  FW_FDT_PATH="$WORK_DIR/nexys4_rv32_sv32.dtb" \
  FW_PAYLOAD_PATH="$WORK_DIR/linux/arch/riscv/boot/Image" \
  -j"$JOBS"

FW_BIN="$WORK_DIR/opensbi/build/platform/generic/firmware/fw_payload.bin"
cp "$FW_BIN" "$WORK_DIR/fw_payload.bin"

echo "=== [5/5] Pack Nexys 4 DDR microSD Image (sd_linux.img) ==="
python3 "$SCRIPT_DIR/mk_sd_image.py" "$WORK_DIR/fw_payload.bin" -o "$WORK_DIR/sd_linux.img"
echo "=== DONE! Artifacts in $WORK_DIR ==="
echo "  1) microSD : sudo dd if=$WORK_DIR/sd_linux.img of=/dev/sdX bs=1M conv=fsync"
echo "  2) UART    : python3 sw/bootrom_linux/send_uart.py COMx $WORK_DIR/fw_payload.bin"
