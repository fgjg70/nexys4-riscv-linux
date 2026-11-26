#!/usr/bin/env python3
"""
sw/linux/mk_sd_image.py — 将 OpenSBI fw_payload.bin (+ 可选 DTB) 打包为 Nexys 4 DDR microSD 镜像
--------------------------------------------------------------------------------
在 LBA 0 写入 512 字节 NX4L 引导头，Payload 从 LBA 2 起连续存放，可选 DTB 紧随其后，
直接由 sw/bootrom_linux/bootrom_linux.hex 上电自动加载至 DDR2 并启动 Linux。

用法:
  python sw/linux/mk_sd_image.py fw_payload.bin -o sd_linux.img
  python sw/linux/mk_sd_image.py Image --dtb nexys4_rv32_sv32.dtb -o sd_linux.img
写入 microSD 卡 (Linux/WSL2):
  sudo dd if=sd_linux.img of=/dev/sdX bs=1M status=progress conv=fsync
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

MAGIC_NX4L = 0x4E58344C  # 'NX4L'
SECTOR = 512


def pad_sector(b: bytes) -> bytes:
    rem = len(b) % SECTOR
    return b if rem == 0 else (b + b"\x00" * (SECTOR - rem))


def main() -> int:
    ap = argparse.ArgumentParser(description="Pack OpenSBI/Linux binary into NX4L raw microSD image.")
    ap.add_argument("payload", type=Path, help="OpenSBI fw_payload.bin or raw payload binary")
    ap.add_argument("-o", "--output", type=Path, default=Path("sd_linux.img"))
    ap.add_argument("--load-addr", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--entry-pc", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--dtb", type=Path, default=None, help="Optional standalone .dtb file")
    ap.add_argument("--dtb-addr", type=lambda s: int(s, 0), default=0x87000000)
    args = ap.parse_args()

    payload = args.payload.read_bytes()
    payload_padded = pad_sector(payload)
    payload_lba = 2
    payload_secs = len(payload_padded) // SECTOR

    dtb_bytes = b""
    dtb_padded = b""
    dtb_addr = 0
    dtb_lba = 0
    if args.dtb is not None:
        dtb_bytes = args.dtb.read_bytes()
        dtb_padded = pad_sector(dtb_bytes)
        dtb_addr = args.dtb_addr
        dtb_lba = payload_lba + payload_secs

    hdr = struct.pack(
        "<IIIIIIII",
        MAGIC_NX4L,
        args.load_addr,
        len(payload),
        payload_lba,
        dtb_addr,
        len(dtb_bytes),
        dtb_lba,
        args.entry_pc,
    )
    hdr_sec = hdr + b"\x00" * (SECTOR - len(hdr))
    reserved_sec = b"\x00" * SECTOR

    img = hdr_sec + reserved_sec + payload_padded + dtb_padded
    args.output.write_bytes(img)
    print(f"[mk_sd_image] Wrote {args.output} ({len(img)} bytes, {len(img)//SECTOR} sectors)")
    print(f"  Payload : LBA {payload_lba}, {len(payload)} bytes -> 0x{args.load_addr:08x}, entry=0x{args.entry_pc:08x}")
    if dtb_bytes:
        print(f"  DTB     : LBA {dtb_lba}, {len(dtb_bytes)} bytes -> 0x{dtb_addr:08x}")
    else:
        print("  DTB     : embedded in OpenSBI fw_payload.bin (a1=0)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
