#!/usr/bin/env python3
"""Collect the Nexys A7 build reports into one machine-readable summary."""

import argparse
import hashlib
import json
import re
from pathlib import Path


def first_number_after(text, label):
    match = re.search(re.escape(label) + r"[^\n]*", text)
    return match.group(0) if match else None


def parse_timing(text):
    section = text.split("Design Timing Summary", 1)[1].split("Clock Summary", 1)[0]
    numbers = re.findall(r"-?\d+(?:\.\d+)?", section)
    keys = ["wns_ns", "tns_ns", "tns_failing_endpoints", "tns_total_endpoints",
            "whs_ns", "ths_ns", "ths_failing_endpoints", "ths_total_endpoints",
            "wpws_ns", "tpws_ns", "tpws_failing_endpoints", "tpws_total_endpoints"]
    values = [float(number) for number in numbers[:12]]
    result = dict(zip(keys, values))
    for key in ("tns_failing_endpoints", "tns_total_endpoints", "ths_failing_endpoints",
                "ths_total_endpoints", "tpws_failing_endpoints", "tpws_total_endpoints"):
        if key in result:
            result[key] = int(result[key])
    return result


def parse_utilization(text):
    result = {}
    for label, key in (("Slice LUTs", "slice_luts"), ("Slice Registers", "slice_registers"),
                       ("Block RAM Tile", "block_ram_tiles"), ("DSPs", "dsps")):
        match = re.search(r"^\|\s*" + re.escape(label) + r"\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|",
                          text, re.MULTILINE)
        if match:
            result[key] = {"used": int(match.group(1)), "available": int(match.group(3)),
                           "percent": float(match.group(4))}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("build", type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    reports = build / "reports"
    timing = parse_timing((reports / "timing.rpt").read_text(encoding="utf-8", errors="replace"))
    utilization = parse_utilization((reports / "utilization.rpt").read_text(encoding="utf-8", errors="replace"))
    drc_text = (reports / "drc.rpt").read_text(encoding="utf-8", errors="replace")
    drc_errors = sum(int(match.group(1)) for match in re.finditer(r"^\|\s*\S+\s*\|\s*Error\s*\|\s*[^|]+\|\s*(\d+)\s*\|", drc_text, re.MULTILINE))
    inputs = json.loads((build / "inputs.json").read_text(encoding="utf-8"))
    bitstream = build / "top_nexys_a7_vision.bit"
    summary = {
        "board": inputs["board"],
        "part": inputs["part"],
        "cpu_clock_hz": inputs["cpu_clock_hz"],
        "system_clock_hz": inputs["system_clock_hz"],
        "pixel_clock_hz": inputs["pixel_clock_hz"],
        "memory_type": inputs["memory_type"],
        "memory_bytes": inputs["memory_bytes"],
        "bist_test_words": inputs["bist_test_words"],
        "timing": timing,
        "utilization": utilization,
        "drc_errors": drc_errors,
        "build_passed": (build / "build_passed.txt").is_file(),
        "bitstream": str(bitstream) if bitstream.is_file() else None,
        "bitstream_sha256": hashlib.sha256(bitstream.read_bytes()).hexdigest() if bitstream.is_file() else None,
        "hardware_validated": False,
    }
    (build / "build_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
