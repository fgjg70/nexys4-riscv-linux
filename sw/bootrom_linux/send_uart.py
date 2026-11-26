#!/usr/bin/env python3
"""
sw/bootrom_linux/send_uart.py — Nexys 4 DDR Linux BootROM 串口二进制下载工具 (NX4U 协议)
--------------------------------------------------------------------------------
无需 microSD 卡即可通过 USB-UART 将 OpenSBI fw_payload.bin (+ 可选独立 .dtb) 下载至
128 MB DDR2 并自动启动 Linux，随后无缝切入交互式串口终端。

用法:
  # 方式 1: 单文件 OpenSBI fw_payload.bin (已内置 DTB + Linux Image + initramfs)
  python sw/bootrom_linux/send_uart.py COM5 fw_payload.bin

  # 方式 2: 独立 DTB + OpenSBI/内核镜像
  python sw/bootrom_linux/send_uart.py COM5 fw_payload.bin --dtb nexys4_rv32_sv32.dtb --dtb-addr 0x87000000
"""
from __future__ import annotations

import argparse
import struct
import sys
import time
from pathlib import Path

MAGIC_NX4U = b"NX4U"


def send_chunk(ser, data: bytes, load_addr: int, entry_pc: int, dtb_addr: int) -> None:
    hdr = MAGIC_NX4U + struct.pack("<IIII", load_addr, len(data), entry_pc, dtb_addr)
    ser.write(hdr)
    ser.flush()

    t0 = time.time()
    sent = 0
    chunk = 1024
    while sent < len(data):
        piece = data[sent : sent + chunk]
        ser.write(piece)
        sent += len(piece)
        if sent % 16384 == 0 or sent == len(data):
            pct = 100.0 * sent / max(1, len(data))
            dt = max(1e-3, time.time() - t0)
            sys.stdout.write(f"\r  -> 0x{load_addr:08x}: {sent}/{len(data)} bytes ({pct:5.1f}%, {sent/dt/1024:.1f} KB/s)")
            sys.stdout.flush()
    ser.flush()
    print()

    exp_csum = sum(data) & 0xFFFFFFFF
    resp = ser.read(4)
    if len(resp) != 4:
        raise RuntimeError(f"Checksum timeout: received {len(resp)} bytes")
    got_csum = struct.unpack("<I", resp)[0]
    if got_csum != exp_csum:
        raise RuntimeError(f"Checksum mismatch: got 0x{got_csum:08x}, expected 0x{exp_csum:08x}")
    print(f"  [OK] Checksum verified: 0x{got_csum:08x}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Upload Linux/OpenSBI binary to Nexys 4 DDR via NX4U UART protocol.")
    ap.add_argument("port", help="Serial port (e.g. COM5 or /dev/ttyUSB1)")
    ap.add_argument("payload", type=Path, help="Payload binary (e.g. fw_payload.bin)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--load-addr", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--entry-pc", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--dtb", type=Path, default=None, help="Optional standalone .dtb file")
    ap.add_argument("--dtb-addr", type=lambda s: int(s, 0), default=0x87000000)
    ap.add_argument("--no-console", action="store_true", help="Exit immediately after boot jump")
    args = ap.parse_args()

    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial not installed. Run: pip install pyserial")
        return 1

    payload_bytes = args.payload.read_bytes()
    with serial.Serial(args.port, args.baud, timeout=5.0) as ser:
        ser.reset_input_buffer()
        # 触发 BootROM 进入 UART 加载模式
        ser.write(b"u")
        time.sleep(0.1)
        banner = ser.read(ser.in_waiting or 0)
        if banner:
            sys.stdout.write(banner.decode("ascii", errors="replace"))
            sys.stdout.flush()

        dtb_addr = 0
        if args.dtb is not None:
            dtb_bytes = args.dtb.read_bytes()
            dtb_addr = args.dtb_addr
            print(f"[NX4U] Uploading DTB ({len(dtb_bytes)} bytes) -> 0x{dtb_addr:08x}")
            send_chunk(ser, dtb_bytes, dtb_addr, entry_pc=0, dtb_addr=0)

        print(f"[NX4U] Uploading Payload ({len(payload_bytes)} bytes) -> 0x{args.load_addr:08x}, entry=0x{args.entry_pc:08x}")
        send_chunk(ser, payload_bytes, args.load_addr, args.entry_pc, dtb_addr)

        if args.no_console:
            return 0

        print("=== Attached to Nexys 4 DDR Linux Console (Ctrl+C to exit) ===")
        ser.timeout = 0.05
        try:
            while True:
                rx = ser.read(256)
                if rx:
                    sys.stdout.write(rx.decode("utf-8", errors="replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            print("\n[Disconnected]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
