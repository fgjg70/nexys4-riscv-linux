import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess


PORT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PORT_ROOT.parent
VISION_ROOT = REPO_ROOT / 'fpga_pg2l100h' / 'vision'
BASE_ROOT = VISION_ROOT / 'build' / 'dual_caps_sorter128_j11'
DDR_ROOT = VISION_ROOT / 'build' / 'dual_caps_ddr3_sorter128_j11'


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--gcc-bin', type=Path, default=Path(os.environ.get('LOCALAPPDATA', '')) /
                        'CodexFPGA/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin')
    parser.add_argument('--full-memory-test', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    gcc = args.gcc_bin / 'riscv-none-elf-gcc.exe'
    if not gcc.is_file():
        raise FileNotFoundError(f'RISC-V GCC not found: {gcc}; supply --gcc-bin')
    output = (args.output or PORT_ROOT / 'build' / ('vision_full_memory' if args.full_memory_test else 'vision')).resolve()
    for directory in ('rtl', 'firmware', 'model', 'ip', 'reports'):
        (output / directory).mkdir(parents=True, exist_ok=True)
    inputs = {}

    def copy(source, destination):
        shutil.copyfile(source, destination)
        inputs[source.relative_to(REPO_ROOT).as_posix()] = checksum(source)

    excluded = {'top_pg2l100h_vision.v', 'pg2l100h_clock.v', 'vision_cpu_clock.v',
                'vision_ddr3_bist.v', 'vision_ddr3_memory.v', 'vision_ddr3_port.v'}
    for source in sorted((BASE_ROOT / 'rtl').glob('*.v')):
        if source.name in excluded:
            continue
        override = DDR_ROOT / 'rtl' / source.name
        if source.name == 'vision_mmio_bridge.v':
            override = VISION_ROOT / 'ddr3' / 'rtl' / source.name
        copy(override if override.is_file() else source, output / 'rtl' / source.name)
    for source in sorted((PORT_ROOT / 'rtl').glob('*.v')):
        copy(source, output / 'rtl' / source.name)
    for staged in sorted((output / 'rtl').glob('*.v')):
        content = staged.read_text(encoding='utf-8-sig')
        content = re.sub(r'(\$readmemh\(")((?:firmware|model)/[^"]+)(")',
                         lambda match: match[1] + (output / match[2]).as_posix() + match[3], content)
        staged.write_text(content, encoding='utf-8')
    for source in sorted((DDR_ROOT / 'model').glob('*.hex')):
        copy(source, output / 'model' / source.name)
    for name in ('model_info.h', 'benchmark_flags.h', 'bht_init.hex', 'btb_zero.hex', 'regfile_zero.hex'):
        copy(DDR_ROOT / 'firmware' / name, output / 'firmware' / name)
    copy(PORT_ROOT / 'ip' / 'mig.prj', output / 'ip' / 'mig.prj')
    copy(PORT_ROOT / 'nexys_a7.xdc', output / 'nexys_a7.xdc')
    firmware = output / 'firmware'
    (firmware / 'platform_clock.h').write_text(
        '#define CLOCK_HZ 50000000u\n#define CPU_CLOCK_HZ 60000000u\n'
        '#define NPU_CLOCK_HZ 50000000u\n#define MEMORY_LABEL "DDR2"\n', encoding='ascii')
    common = ['-march=rv32im', '-mabi=ilp32', '-O2', '-ffreestanding', '-fno-builtin',
              '-fno-strict-aliasing', '-fno-stack-protector', '-fno-pic', '-fno-use-linker-plugin',
              '-fno-lto', '-msmall-data-limit=0', '-mno-relax', '-Wall', '-Wextra', '-Werror',
              '-I', str(firmware)]
    coremark = VISION_ROOT / 'build' / 'coremark_source'
    port = VISION_ROOT / 'competition'
    core_flags = common + ['-O3', '-funroll-all-loops', '-mbranch-cost=1', '-fira-loop-pressure',
                           '-I', str(coremark), '-I', str(port), '-DITERATIONS=6000',
                           '-DPERFORMANCE_RUN=1', '-DVALIDATION_RUN=0', '-DPROFILE_RUN=0',
                           '-DTOTAL_DATA_SIZE=2000', '-DCOREMARK_RUNTIME']
    objects = []
    for name in ('core_main', 'core_list_join', 'core_matrix', 'core_state', 'core_util', 'core_portme'):
        source = (port if name == 'core_portme' else coremark) / f'{name}.c'
        target = firmware / f'{name}.o'
        extra = ['-Dmain=coremark_main'] if name == 'core_main' else []
        subprocess.run([str(gcc), *core_flags, *extra, '-c', str(source), '-o', str(target)], check=True)
        objects.append(str(target))
        inputs[source.relative_to(REPO_ROOT).as_posix()] = checksum(source)
    for name in ('numeric_main.c', 'start.S'):
        source = VISION_ROOT / 'firmware' / name
        target = firmware / f'{source.stem}.o'
        subprocess.run([str(gcc), *common, '-c', str(source), '-o', str(target)], check=True)
        objects.append(str(target))
        inputs[source.relative_to(REPO_ROOT).as_posix()] = checksum(source)
    for source in sorted((VISION_ROOT / 'firmware').glob('*.h')):
        inputs[source.relative_to(REPO_ROOT).as_posix()] = checksum(source)
    linker = VISION_ROOT / 'firmware' / 'link.ld'
    inputs[linker.relative_to(REPO_ROOT).as_posix()] = checksum(linker)
    elf = firmware / 'vision.elf'
    subprocess.run([str(gcc), *common, '-nostdlib', '-Wl,--no-relax', '-T', str(linker),
                    *objects, '-o', str(elf)], check=True)
    for section, capacity, target in (('text', 65536, 'vision_imem.hex'), ('data', 16384, 'vision_dmem.hex')):
        binary = firmware / f'{section}.bin'
        subprocess.run([str(args.gcc_bin / 'riscv-none-elf-objcopy.exe'), '-O', 'binary',
                        '-j', f'.{section}', str(elf), str(binary)], check=True)
        payload = binary.read_bytes()
        if len(payload) > capacity:
            raise ValueError(f'{section} exceeds {capacity} bytes')
        words = struct.iter_unpack('<I', payload.ljust(capacity, b'\0'))
        (firmware / target).write_text(''.join(f'{word[0]:08x}\n' for word in words), encoding='ascii')
    model_mask = int((output / 'model' / 'available.hex').read_text(encoding='ascii').strip(), 16)
    if not 0 <= model_mask <= 3:
        raise ValueError('Invalid model availability mask')
    manifest = {
        'board': 'Nexys A7-100T / Nexys 4 DDR', 'part': 'xc7a100tcsg324-1',
        'memory_type': 'DDR2', 'memory_bytes': 134217728, 'memory_data_bits': 16,
        'cpu_clock_hz': 60000000, 'system_clock_hz': 50000000, 'pixel_clock_hz': 25000000,
        'mig_reference_clock_hz': 200000000, 'memory_clock_period_ps': 3333,
        'bist_test_words': 33554432 if args.full_memory_test else 1024,
        'model_mask': model_mask, 'firmware_sha256': checksum(elf), 'input_sha256': inputs,
        'hardware_validated': False,
    }
    (output / 'inputs.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (output / 'config.tcl').write_text(
        f'set bist_test_words {manifest["bist_test_words"]}\nset model_mask {model_mask}\n', encoding='ascii')
    subprocess.run([str(args.gcc_bin / 'riscv-none-elf-size.exe'), str(elf)], check=True)
    print(f'Prepared {output}')


if __name__ == '__main__':
    main()
