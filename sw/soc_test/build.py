#!/usr/bin/env python3
"""Build sw/soc_test firmware -> sim/prog/soc_test.hex using riscv-none-elf-gcc."""
from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def find_tool(name: str) -> str:
    env_dir = os.environ.get("RISCV_BIN")
    if env_dir:
        cand = Path(env_dir) / name
        if cand.exists():
            return str(cand)
    p = shutil.which(name)
    if p:
        return p
    for root in [
        Path(r"D:\software\tools\riscv-none-elf"),
        Path(r"C:\riscv-none-elf"),
    ]:
        if root.exists():
            matches = list(root.rglob(name))
            if matches:
                return str(matches[0])
    raise FileNotFoundError(f"Tool not found: {name}")


def main() -> int:
    exe = ".exe" if os.name == "nt" else ""
    gcc = find_tool(f"riscv-none-elf-gcc{exe}")
    objcopy = find_tool(f"riscv-none-elf-objcopy{exe}")

    elf = HERE / "soc_test.elf"
    bin_f = HERE / "soc_test.bin"
    hex_f = ROOT / "sim" / "prog" / "soc_test.hex"

    cmd_cc = [
        gcc,
        "-march=rv32ima_zicsr_zifencei",
        "-mabi=ilp32",
        "-O2",
        "-nostdlib",
        "-nostartfiles",
        "-ffreestanding",
        "-Wall",
        "-Wextra",
        "-T",
        str(HERE / "link.ld"),
        str(HERE / "start.S"),
        str(HERE / "main.c"),
        "-o",
        str(elf),
    ]
    print("+", " ".join(cmd_cc))
    subprocess.run(cmd_cc, check=True)

    cmd_oc = [objcopy, "-O", "binary", str(elf), str(bin_f)]
    subprocess.run(cmd_oc, check=True)

    data = bin_f.read_bytes()
    if len(data) % 4:
        data += b"\x00" * (4 - (len(data) % 4))
    words = [f"{struct.unpack_from('<I', data, i)[0]:08x}\n" for i in range(0, len(data), 4)]
    hex_f.write_text("".join(words), encoding="ascii")
    print(f"Built {hex_f} ({len(words)} words, {len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
