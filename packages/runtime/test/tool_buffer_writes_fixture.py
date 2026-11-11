"""Verify the executed ledger and independent native integer byte encodings."""
from pathlib import Path
import json
import struct
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
flags = sys.argv[3:]
prefix = [binary] + ([] if '--node' in flags else ['run']) + [script]
with tempfile.TemporaryDirectory(prefix='home-buffer-writes-') as directory:
    path = Path(directory) / 'actual.bin'
    result = subprocess.run(prefix + ['contract', str(path)], capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    lines = result.stdout.decode().splitlines()
    assert len(lines) == 2 and lines[1] == 'NODE BUFFER WRITES 18 CHECKS OK', lines
    assert json.loads(lines[0].removeprefix('NODE BUFFER WRITES RESULTS ')) == {'checks':18,'passed':18,'failures':[]}
    assert result.stderr == b'', result.stderr
    fields = [('B',0xab),('b',-7),('<H',0xcdef),('>H',0x1234),('<h',-12345),('>h',-23456),('<I',0xfedcba98),('>I',0x89abcdef),('<i',-123456789),('>i',-2147483648)]
    expected = b''.join(struct.pack(fmt,value) for fmt,value in fields)
    assert len(expected) == 26 and path.read_bytes() == expected
    print(result.stdout.decode(), end='')
    print('NATIVE BUFFER WRITES 10 FORMATS 26 PHYSICAL BYTES VERIFIED')
    if '--reference' not in flags:
        guarded = subprocess.run(prefix + ['guards', str(path)], capture_output=True, timeout=30)
        assert guarded.returncode == 0 and guarded.stdout == b'HOME BUFFER WRITES 5 RECEIVER GUARDS OK\n' and guarded.stderr == b'', guarded.stdout + guarded.stderr
        print(guarded.stdout.decode(), end='')
