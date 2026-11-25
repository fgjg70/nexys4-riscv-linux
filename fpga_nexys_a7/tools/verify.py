import argparse
from datetime import datetime
import json
from pathlib import Path
import struct
import subprocess
import sys

from prepare import PORT_ROOT, VISION_ROOT, checksum


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vivado-bin', type=Path, default=Path('E:/Vivado/2018.3/bin'))
    parser.add_argument('--gcc-bin', type=Path)
    args = parser.parse_args()
    output = PORT_ROOT / 'validation' / datetime.now().strftime('simulation_%Y%m%d_%H%M%S')
    prepare_args = [sys.executable, str(PORT_ROOT / 'tools' / 'prepare.py'), '--output', str(output)]
    if args.gcc_bin:
        prepare_args += ['--gcc-bin', str(args.gcc_bin)]
    subprocess.run(prepare_args, check=True)
    source_paths = []
    for source in sorted((output / 'rtl').glob('*.v')):
        if source.name in {'nexys_clocks.v', 'nexys_ddr2.v', 'top_nexys_a7_vision.v'}:
            continue
        source_paths.append(source)
    for source in sorted((PORT_ROOT / 'sim').glob('*.v')):
        source_paths.append(source)
    (output / 'sources.f').write_text('\n'.join(f'"{source.as_posix()}"' for source in source_paths), encoding='ascii')

    def run(tool, arguments, log_name):
        with (output / log_name).open('w', encoding='utf-8') as log:
            result = subprocess.run([str(tool), *arguments], cwd=output, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{tool.name} failed; inspect {output / log_name}')

    summary = {
        'success': False,
        'evidence_directory': str(output),
        'scope': 'Verilog simulation of RV32/SoC RTL, MIG native interface, VGA, SCCB/DVP and OLED SPI',
    }
    try:
        run(args.vivado_bin / 'xvlog.bat', ['-f', 'sources.f'], 'compile.log')
        tests = [
            ('tb_ddr2', 'bus', 'PASS all integrated DDR2 bus tests'),
            ('tb_video', 'video', 'PASS VGA timing and original LCD timing'),
            ('tb_camera_oled', 'camera_oled', 'PASS OV5640 capture and OLED preview'),
        ]
        for top, name, marker in tests:
            run(args.vivado_bin / 'xelab.bat', [top, '-s', name], f'{name}_elaborate.log')
            run(args.vivado_bin / 'xsim.bat', [name, '-tclbatch', (PORT_ROOT / 'sim' / 'run.tcl').as_posix()], f'{name}.log')
            text = (output / f'{name}.log').read_text(encoding='utf-8', errors='replace')
            if marker not in text or 'FAIL ' in text:
                raise RuntimeError(f'{name} simulation failed; inspect {output / (name + ".log")}')
            summary[name] = [line for line in text.splitlines() if line.startswith('PASS ')]
        if args.gcc_bin is None:
            import os
            args.gcc_bin = Path(os.environ['LOCALAPPDATA']) / 'CodexFPGA/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin'
        elf = output / 'cpu_test.elf'
        run(args.gcc_bin / 'riscv-none-elf-gcc.exe', [
            '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-O2', '-ffreestanding', '-fno-builtin',
            '-fno-stack-protector', '-fno-pic', '-fno-use-linker-plugin', '-fno-lto', '-msmall-data-limit=0',
            '-nostdlib', '-Wl,--no-relax', '-T', str(VISION_ROOT / 'firmware' / 'link.ld'),
            str(VISION_ROOT / 'firmware' / 'start.S'), str(PORT_ROOT / 'sim' / 'cpu_ddr2_test.c'), '-o', str(elf),
        ], 'cpu_compile.log')
        for section, capacity, name in [('text', 65536, 'vision_imem.hex'), ('data', 16384, 'vision_dmem.hex')]:
            binary = output / f'{section}.bin'
            run(args.gcc_bin / 'riscv-none-elf-objcopy.exe', ['-O', 'binary', '-j', f'.{section}', str(elf), str(binary)], f'{section}_extract.log')
            payload = binary.read_bytes()
            if len(payload) > capacity:
                raise ValueError('CPU test firmware exceeds RAM capacity')
            (output / 'firmware' / name).write_text(''.join(f'{word[0]:08x}\n' for word in struct.iter_unpack('<I', payload.ljust(capacity, b'\0'))), encoding='ascii')
        run(args.vivado_bin / 'xelab.bat', ['tb_ddr2_cpu', '-s', 'cpu'], 'cpu_elaborate.log')
        run(args.vivado_bin / 'xsim.bat', ['cpu', '-tclbatch', (PORT_ROOT / 'sim' / 'run.tcl').as_posix()], 'cpu.log')
        text = (output / 'cpu.log').read_text(encoding='utf-8', errors='replace')
        if 'PASS real RV32 CPU DDR2 execution result=600d600d' not in text or 'FAIL ' in text:
            raise RuntimeError(f'CPU simulation failed; inspect {output / "cpu.log"}')
        summary['cpu'] = [line for line in text.splitlines() if line.startswith('PASS ')]
        summary['cpu_firmware_sha256'] = checksum(elf)
        summary['success'] = True
    except Exception as error:
        summary['error'] = str(error)
        raise
    finally:
        (output / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
        (PORT_ROOT / 'validation' / 'simulation_summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
