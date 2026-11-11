"""Require real managed byte allocations and independently verify physical bytes."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
flags = sys.argv[3:]
prefix = [binary] + ([] if '--node' in flags else ['run']) + [script]
with tempfile.TemporaryDirectory(prefix='home-buffer-unsafe-') as directory:
    path = Path(directory) / 'actual.bin'
    result = subprocess.run(prefix + ['contract', str(path)], capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    lines = result.stdout.decode().splitlines()
    assert len(lines) == 2 and lines[1] == 'NODE BUFFER UNSAFE 14 CHECKS OK', lines
    assert json.loads(lines[0].removeprefix('NODE BUFFER UNSAFE RESULTS ')) == {'checks': 14, 'passed': 14, 'failures': []}
    assert result.stderr == b'', result.stderr
    assert path.read_bytes() == bytes(i % 251 for i in range(65536))
    print(result.stdout.decode(), end='')
    print('NATIVE BUFFER UNSAFE PHYSICAL 65536 BYTES VERIFIED')
    if '--reference' not in flags:
        refused = subprocess.run(prefix + ['guards', str(path)], capture_output=True, timeout=30)
        assert refused.returncode == 0 and refused.stdout == b'HOME BUFFER UNSAFE 7 PROFILE GUARDS OK\n' and refused.stderr == b'', refused.stdout + refused.stderr
        print(refused.stdout.decode(), end='')
