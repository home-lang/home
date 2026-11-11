"""Compare runtime ABI metadata with this executable's actual ELF/Mach-O header."""
import json
from pathlib import Path
import struct
import subprocess
import sys


def executable_abi(path):
    with Path(path).open('rb') as source:
        header = source.read(64)
    if header[:4] == b'\x7fELF':
        endian = {1: 'LE', 2: 'BE'}[header[5]]
        machine = struct.unpack_from('<H' if endian == 'LE' else '>H', header, 18)[0]
        arch = {62: 'x64', 183: 'arm64'}[machine]
        assert header[4] == 2, 'requires the maintained 64-bit executable profile'
    elif header[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
        endian = 'LE' if header[:4] == b'\xcf\xfa\xed\xfe' else 'BE'
        machine = struct.unpack_from('<I' if endian == 'LE' else '>I', header, 4)[0]
        arch = {0x01000007: 'x64', 0x0100000c: 'arm64'}[machine]
    else:
        raise ValueError('Unsupported executable ABI fixture profile')
    return arch, endian


def main():
    expected = executable_abi(sys.argv[1])
    run = subprocess.run([sys.argv[1], 'run', sys.argv[2]], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
    lines = run.stdout.splitlines()
    assert len(lines) == 2 and lines[1] == 'NODE OS ABI 5 CHECKS OK', run.stdout
    result = json.loads(lines[0].removeprefix('NODE OS ABI RESULTS '))
    assert result['checks'] == result['passed'] == 5, result
    assert (result['arch'], result['endianness']) == expected, (result, expected)
    print(run.stdout, end='')
    print('NATIVE EXECUTABLE ABI HEADER MATCHES RUNTIME')


if __name__ == '__main__':
    main()
