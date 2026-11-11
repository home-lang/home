"""Require every inheritance contract group to execute and expose its ledger."""
from pathlib import Path
import json
import subprocess
import sys

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
result = subprocess.run([binary, 'run', script], capture_output=True, timeout=30)
assert result.returncode == 0, result.stdout + result.stderr
lines = result.stdout.decode().splitlines()
assert len(lines) == 2 and lines[1] == 'NODE UTIL INHERITS 18 CHECKS OK', lines
assert json.loads(lines[0].removeprefix('NODE UTIL INHERITS RESULTS ')) == {'checks': 18, 'passed': 18, 'failures': []}
assert result.stderr == b'', result.stderr
print(result.stdout.decode(), end='')
