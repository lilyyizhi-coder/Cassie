"""Verify that UTF-8 source reaches CI byte-for-byte intact.

Run with --write after intentionally editing the tracked source files.
The JSON manifest and this script use ASCII for safe console transport.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'source-integrity.json'


def snapshot():
    paths = sorted((ROOT / 'Sources').glob('*.swift'))
    paths += sorted((ROOT / 'scripts').glob('*.py'))
    paths += [ROOT / 'project.yml', ROOT / '.github/workflows/ios-build.yml']
    result = {}
    for path in paths:
        raw = path.read_bytes()
        text = raw.decode('utf-8', errors='strict')
        if '\ufffd' in text:
            raise ValueError('Unicode replacement character in ' + str(path))
        result[path.relative_to(ROOT).as_posix()] = hashlib.sha256(raw).hexdigest()
    return result


def main():
    actual = snapshot()
    if sys.argv[1:] == ['--write']:
        MANIFEST.write_text(json.dumps(actual, indent=2, ensure_ascii=True) + '\n', encoding='ascii', newline='\n')
        print('Wrote source checksums for', len(actual), 'files.')
        return
    expected = json.loads(MANIFEST.read_text(encoding='ascii'))
    changed = sorted(path for path in set(actual) | set(expected) if actual.get(path) != expected.get(path))
    if changed:
        raise ValueError('Source bytes differ from reviewed UTF-8 files: ' + ', '.join(changed))
    print('PASS: UTF-8 and SHA-256 integrity for', len(actual), 'files.')


if __name__ == '__main__':
    main()
