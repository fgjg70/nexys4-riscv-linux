#!/usr/bin/env python3
"""
tools/verify.py — Nexys 4 DDR RV32IMA pure Verilog-2001/2005 simulation regression.

Compiles strictly WITHOUT SystemVerilog flags (no `-sv` / `--sv`) to guarantee
pure Verilog compliance across ModelSim and Vivado xsim.

Usage:
    python tools/verify.py                 # Default radix-2 RV32IMA regression (8 tests)
    python tools/verify.py --radix4        # Same 8 tests with +define+DIV_RADIX4
    python tools/verify.py --all-modes     # Run both radix-2 and DIV_RADIX4
    python tools/verify.py --sim msim      # Force ModelSim
    python tools/verify.py --sim xsim      # Force Vivado xsim
    python tools/verify.py --only tb_core_amo
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCDIR = ROOT / "rtl" / "cpu"

CPU_RTL = [
    "rtl/cpu/alu.v",
    "rtl/cpu/branch_unit.v",
    "rtl/cpu/imm_gen.v",
    "rtl/cpu/regfile.v",
    "rtl/cpu/pc.v",
    "rtl/cpu/imem.v",
    "rtl/cpu/dmem.v",
    "rtl/cpu/btb.v",
    "rtl/cpu/bht.v",
    "rtl/cpu/ras.v",
    "rtl/cpu/hazard_unit.v",
    "rtl/cpu/id_ex_reg.v",
    "rtl/cpu/ex_mem_reg.v",
    "rtl/cpu/mem_wb_reg.v",
    "rtl/cpu/control_unit.v",
    "rtl/cpu/load_store_unit.v",
    "rtl/cpu/muldiv.v",
    "rtl/cpu/csr_file.v",
    "rtl/cpu/rv32_cpu.v",
    "rtl/cpu/core.v",
]

SOC_RTL = CPU_RTL + [
    "rtl/periph/mmio_subsys.v",
]

LINUX_SOC_RTL = CPU_RTL + [
    "rtl/soc/icache.v",
    "rtl/soc/dcache.v",
    "rtl/soc/soc_bus.v",
    "rtl/soc/bootrom.v",
    "rtl/periph/clint.v",
    "rtl/periph/plic.v",
    "rtl/periph/uart_16550.v",
    "rtl/soc/rv32_soc.v",
]

TESTS = [
    {
        "name": "tb_units",
        "top": "tb_units",
        "files": CPU_RTL + ["sim/tb_units.v"],
        "plusargs": [],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_core_basic",
        "top": "tb_core",
        "files": CPU_RTL + ["sim/tb_core.v"],
        "plusargs": ["imem=sim/prog/basic.hex", "max_cycles=200000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_core_m_ext",
        "top": "tb_core",
        "files": CPU_RTL + ["sim/tb_core.v"],
        "plusargs": ["imem=sim/prog/m_ext.hex", "max_cycles=200000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_core_amo",
        "top": "tb_core",
        "files": CPU_RTL + ["sim/tb_core.v"],
        "plusargs": ["imem=sim/prog/amo.hex", "max_cycles=200000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_core_trap",
        "top": "tb_core",
        "files": CPU_RTL + ["sim/tb_core.v"],
        "plusargs": ["imem=sim/prog/trap.hex", "max_cycles=200000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_core_priv_ext",
        "top": "tb_core",
        "files": CPU_RTL + ["sim/tb_core.v"],
        "plusargs": ["imem=sim/prog/priv_ext.hex", "max_cycles=200000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_soc_mmio",
        "top": "tb_soc",
        "files": SOC_RTL + ["sim/tb_soc.v"],
        "plusargs": ["imem=sim/prog/mmio.hex", "max_cycles=400000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_soc_timer_irq",
        "top": "tb_soc",
        "files": SOC_RTL + ["sim/tb_soc.v"],
        "plusargs": ["imem=sim/prog/timer_irq.hex", "max_cycles=400000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_soc_wfi_vec",
        "top": "tb_soc",
        "files": SOC_RTL + ["sim/tb_soc.v"],
        "plusargs": ["imem=sim/prog/wfi_vec.hex", "max_cycles=400000"],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_sw_hello",
        "top": "tb_sw",
        "files": SOC_RTL + ["sim/tb_sw.v"],
        "plusargs": [
            "imem=sim/prog/hello.hex",
            "dmem=sim/prog/hello.dmem.hex",
            "max_cycles=400000",
        ],
        "pass_marker": "RESULT : PASS",
    },
    {
        "name": "tb_linux_soc",
        "top": "tb_linux_soc",
        "files": LINUX_SOC_RTL + ["sim/tb_linux_soc.v"],
        "plusargs": [
            "ram=sim/prog/soc_test.hex",
            "ram_lat=4",
            "max_cycles=500000",
        ],
        "pass_marker": "RESULT : PASS",
    },
]


def find_msim_bin() -> Path | None:
    env_bin = os.environ.get("MSIM_BIN")
    if env_bin and (Path(env_bin) / "vsim.exe").exists():
        return Path(env_bin)
    for c in [
        Path(r"D:\software\tools\Modelsim\win64"),
        Path(r"D:\software\Learn\Inter_FPGA\modelsim_ase\win32aloem"),
    ]:
        if (c / "vsim.exe").exists():
            return c
    vs = shutil.which("vsim")
    return Path(vs).parent if vs else None


def find_vivado_bin() -> Path | None:
    env_bin = os.environ.get("VIVADO_BIN")
    if env_bin and (Path(env_bin) / "xvlog.bat").exists():
        return Path(env_bin)
    for c in [
        Path(r"D:\software\Learn\Xilinx\Vivado\2018.3\bin"),
        Path(r"C:\Xilinx\Vivado\2018.3\bin"),
    ]:
        if (c / "xvlog.bat").exists():
            return c
    xv = shutil.which("xvlog")
    return Path(xv).parent if xv else None


def run_cmd(cmd: list[str], cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def format_plusarg(p: str) -> str:
    k, v = p.split("=", 1)
    if k in ("imem", "dmem", "ram", "rom"):
        v = (ROOT / v).as_posix()
    return f"{k}={v}"


def run_suite_msim(msim_bin: Path, defines: list[str], only: str | None) -> bool:
    label = ",".join(defines) if defines else "default(radix-2)"
    print(f"=== Running strict Verilog regression [msim | {label}] ===")
    vlib = str(msim_bin / ("vlib.exe" if os.name == "nt" else "vlib"))
    vlog = str(msim_bin / ("vlog.exe" if os.name == "nt" else "vlog"))
    vsim = str(msim_bin / ("vsim.exe" if os.name == "nt" else "vsim"))

    env = os.environ.copy()
    lic = msim_bin / "LICENSE.TXT"
    if lic.exists() and not env.get("LM_LICENSE_FILE"):
        env["LM_LICENSE_FILE"] = str(lic)

    selected = [t for t in TESTS if (only is None or t["name"] == only)]
    if not selected:
        print(f"ERROR: unknown test '{only}'")
        return False

    work_root = ROOT / ".sim_work"
    shutil.rmtree(work_root, ignore_errors=True)
    work_root.mkdir(parents=True, exist_ok=True)
    try:
        passed = 0
        compiled_tops: set[str] = set()
        for test in selected:
            t0 = time.time()
            top = test["top"]
            tdir = work_root / top
            if top not in compiled_tops:
                tdir.mkdir(parents=True, exist_ok=True)
                r = run_cmd([vlib, "work"], tdir, env=env)
                if r.returncode != 0:
                    print(f"  [FAIL] {test['name']} (vlib rc={r.returncode})\n{r.stdout[-1500:]}")
                    return False
                # Strict pure Verilog mode: intentionally NO `-sv` flag
                cmd_v = [vlog, "-work", "work", f"+incdir+{INCDIR}"] + [f"+define+{d}" for d in defines]
                cmd_v += [str(ROOT / f) for f in test["files"]]
                r = run_cmd(cmd_v, tdir, env=env)
                if r.returncode != 0:
                    print(f"  [FAIL] {test['name']} (vlog rc={r.returncode})\n{r.stdout[-2500:]}")
                    return False
                compiled_tops.add(top)

            cmd_s = [vsim, "-c", "-do", "run -all; quit -f", f"work.{top}"]
            cmd_s += [f"+{format_plusarg(p)}" for p in test["plusargs"]]
            r = run_cmd(cmd_s, tdir, env=env)
            dt = time.time() - t0
            ok = (
                test["pass_marker"] in r.stdout
                and "Errors: 0" in r.stdout
                and "RESULT : FAIL" not in r.stdout
                and "ERROR:" not in r.stdout
                and "** Error:" not in r.stdout
            )
            if ok:
                passed += 1
                extra = " [DIV_RADIX4]" if "DIV_RADIX4 ACTIVE" in r.stdout else ""
                print(f"  [PASS] {test['name']:<18} ({dt:.1f}s){extra}")
            else:
                print(f"  [FAIL] {test['name']} (rc={r.returncode}, {dt:.1f}s)\n{r.stdout[-2500:]}")
                return False

        print(f"RESULT : PASS ({passed}/{len(selected)}) [msim | {label}]\n")
        return True
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def run_suite_xsim(vivado_bin: Path, defines: list[str], only: str | None) -> bool:
    label = ",".join(defines) if defines else "default(radix-2)"
    print(f"=== Running strict Verilog regression [xsim | {label}] ===")
    xvlog = str(vivado_bin / ("xvlog.bat" if os.name == "nt" else "xvlog"))
    xelab = str(vivado_bin / ("xelab.bat" if os.name == "nt" else "xelab"))
    xsim = str(vivado_bin / ("xsim.bat" if os.name == "nt" else "xsim"))

    selected = [t for t in TESTS if (only is None or t["name"] == only)]
    if not selected:
        print(f"ERROR: unknown test '{only}'")
        return False

    work_root = ROOT / ".sim_work"
    shutil.rmtree(work_root, ignore_errors=True)
    work_root.mkdir(parents=True, exist_ok=True)
    try:
        passed = 0
        compiled_tops: dict[str, str] = {}
        for test in selected:
            t0 = time.time()
            top = test["top"]
            snap = f"snap_{top}"
            if top not in compiled_tops:
                # Strict pure Verilog mode: intentionally NO `--sv` flag
                cmd_v = [xvlog, "--nolog", "-i", str(INCDIR)]
                for d in defines:
                    cmd_v += ["-d", d]
                cmd_v += [str(ROOT / f) for f in test["files"]]
                r = run_cmd(cmd_v, work_root)
                if r.returncode != 0:
                    print(f"  [FAIL] {test['name']} (xvlog rc={r.returncode})\n{r.stdout[-2500:]}")
                    return False
                cmd_e = [xelab, "--nolog", "-mt", "off", "-debug", "off", top, "-s", snap]
                r = run_cmd(cmd_e, work_root)
                if r.returncode != 0:
                    print(f"  [FAIL] {test['name']} (xelab rc={r.returncode})\n{r.stdout[-2500:]}")
                    return False
                compiled_tops[top] = snap

            cmd_s = [xsim, snap, "--nolog", "-R"]
            for p in test["plusargs"]:
                cmd_s += ["-testplusarg", format_plusarg(p)]
            r = run_cmd(cmd_s, work_root)
            dt = time.time() - t0
            ok = (
                r.returncode == 0
                and test["pass_marker"] in r.stdout
                and "ERROR:" not in r.stdout
                and "RESULT : FAIL" not in r.stdout
            )
            if ok:
                passed += 1
                extra = " [DIV_RADIX4]" if "DIV_RADIX4 ACTIVE" in r.stdout else ""
                print(f"  [PASS] {test['name']:<18} ({dt:.1f}s){extra}")
            else:
                print(f"  [FAIL] {test['name']} (rc={r.returncode}, {dt:.1f}s)\n{r.stdout[-2500:]}")
                return False

        print(f"RESULT : PASS ({passed}/{len(selected)}) [xsim | {label}]\n")
        return True
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Run RV32IMA pure Verilog baseline regression.")
    ap.add_argument("--sim", choices=["auto", "msim", "xsim"], default="auto")
    ap.add_argument("--radix4", action="store_true", help="Enable DIV_RADIX4 macro")
    ap.add_argument("--all-modes", action="store_true", help="Run both default and DIV_RADIX4")
    ap.add_argument("--only", default=None, help="Run a single test by name")
    args = ap.parse_args()

    msim_bin = find_msim_bin()
    vivado_bin = find_vivado_bin()
    if args.sim == "msim" or (args.sim == "auto" and msim_bin is not None):
        if msim_bin is None:
            print("ERROR: ModelSim not found")
            return 1
        runner = lambda d: run_suite_msim(msim_bin, d, args.only)
    else:
        if vivado_bin is None:
            print("ERROR: Vivado xsim not found")
            return 1
        runner = lambda d: run_suite_xsim(vivado_bin, d, args.only)

    modes = [[], ["DIV_RADIX4"]] if args.all_modes else ([["DIV_RADIX4"]] if args.radix4 else [[]])
    for defines in modes:
        if not runner(defines):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
