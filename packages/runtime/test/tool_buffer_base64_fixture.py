"""Independently check the actual physical base64 output with Python's codec."""
from pathlib import Path
import base64
import json
import subprocess
import sys

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
args = [binary] + ([] if '--node' in sys.argv[3:] else ['run']) + [script]
result = subprocess.run(args, capture_output=True, timeout=90)
lines = result.stdout.decode().splitlines()
assert result.returncode == 0 and result.stderr == b'', result.stdout[:2000] + result.stderr
assert len(lines) == 3, lines[:1]
ledger = json.loads(lines[0].removeprefix('BUFFER BASE64 RESULTS '))
assert ledger == {'groups': 126, 'passed': 126, 'failures': []}, ledger
physical = json.loads(lines[1].removeprefix('BUFFER BASE64 PHYSICAL '))
expected = bytes((i * 73 + 19) & 255 for i in range(65536))
assert physical['bytes'] == len(expected)
assert physical['base64'] == base64.b64encode(expected).decode()
assert physical['base64url'] == base64.urlsafe_b64encode(expected).decode().rstrip('=')
assert base64.b64decode(physical['base64'], validate=True) == expected
print(lines[0])
print(lines[2])
print('NATIVE BASE64 65536 PHYSICAL BYTES INDEPENDENTLY VERIFIED')
