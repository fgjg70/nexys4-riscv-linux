import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

import pymupdf


TEXT_EXTENSIONS = {
    '.v', '.sv', '.vh', '.vhd', '.vhdl', '.verilog', '.c', '.h', '.s',
    '.xdc', '.tcl', '.prj', '.xci', '.xml', '.txt', '.md', '.rst', '.ld',
    '.lds', '.asm', '.f', '.do', '.coe', '.mif', '.ini', '.bat', '.sh',
    '.py', '.mk', '.lpr', '.xpr', '.json', '.html', '.readme',
}


def decode(payload):
    for encoding in ('utf-8-sig', 'gb18030', 'utf-16'):
        try:
            return payload.decode(encoding)
        except UnicodeError:
            pass
    return payload.decode('utf-8', errors='replace')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('materials', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    text_root = args.output / 'texts'
    text_root.mkdir(exist_ok=True)
    records = []
    extracted = {}
    failures = []
    for path in sorted(args.materials.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(args.materials).as_posix()
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        checksum = digest.hexdigest()
        record = {'path': relative, 'bytes': path.stat().st_size, 'sha256': checksum}
        suffix = path.suffix.lower()
        try:
            if checksum in extracted:
                record['text'] = extracted[checksum]
            else:
                text = None
                if suffix == '.pdf':
                    with pymupdf.open(path) as document:
                        record['pages'] = len(document)
                        text = '\n'.join(f'PAGE {index + 1}\n{page.get_text()}'
                                         for index, page in enumerate(document))
                elif suffix in {'.docx', '.pptx', '.xlsx', '.vsdx'}:
                    with zipfile.ZipFile(path) as archive:
                        fragments = []
                        for name in archive.namelist():
                            if name.endswith('.xml'):
                                tree = ET.fromstring(archive.read(name))
                                fragments.extend(element.text for element in tree.iter()
                                                 if element.text and element.text.strip())
                        text = '\n'.join(fragments)
                elif suffix in TEXT_EXTENSIONS or path.name.lower() in {'makefile', 'license'}:
                    text = decode(path.read_bytes())
                if text is not None:
                    text_name = f'{checksum}.txt'
                    (text_root / text_name).write_text(text, encoding='utf-8')
                    record['text'] = text_name
                    extracted[checksum] = text_name
            if suffix == '.zip':
                with zipfile.ZipFile(path) as archive:
                    entries = []
                    for member in archive.infolist():
                        entry = {'path': member.filename, 'bytes': member.file_size}
                        if not member.is_dir() and Path(member.filename).suffix.lower() in TEXT_EXTENSIONS:
                            payload = archive.read(member)
                            member_hash = hashlib.sha256(payload).hexdigest()
                            text_name = f'{member_hash}.txt'
                            (text_root / text_name).write_text(decode(payload), encoding='utf-8')
                            entry['text'] = text_name
                        entries.append(entry)
                    record['archive_entries'] = entries
            elif suffix == '.rar':
                result = subprocess.run(['tar', '-tf', str(path)], capture_output=True)
                if result.returncode:
                    raise RuntimeError(decode(result.stderr))
                record['archive_entries'] = decode(result.stdout).splitlines()
        except Exception as error:
            record['read_error'] = str(error)
            failures.append({'path': relative, 'error': str(error)})
        records.append(record)
    summary = {
        'root': str(args.materials.resolve()),
        'file_count': len(records),
        'total_bytes': sum(record['bytes'] for record in records),
        'unique_files': len({record['sha256'] for record in records}),
        'text_extractions': len(list(text_root.glob('*.txt'))),
        'failures': failures,
    }
    (args.output / 'inventory.json').write_text(
        json.dumps({'summary': summary, 'files': records}, ensure_ascii=False, indent=2),
        encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
