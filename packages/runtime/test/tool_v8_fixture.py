"""Require real clone values, malformed input failures and explicit provider limits."""
from pathlib import Path
import json
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
root = Path(sys.argv[2]).resolve()
target = sys.argv[3] == 'zig-js'
cases = [('node_v8.mjs', 'V8 BINARY', 31)] if target else [('v8_jsc_profile.mjs', 'HOME JSC V8 PROFILE', 8)]
cases += [('v8_malformed.mjs', 'V8 MALFORMED', 17)]
cases += [('v8_node_wire.mjs', 'V8 NODE WIRE', 23)]
if target:
    cases += [('v8_profile.mjs', 'HOME V8 PROFILE', 9)]
for name, label, groups in cases:
    result = subprocess.run([binary, 'run', str(root / name)], capture_output=True, timeout=90)
    print(result.stdout.decode(), end='')
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stderr == b'', result.stderr
    lines = result.stdout.decode().splitlines()
    assert len(lines) == 2 and lines[0].startswith(label + ' RESULTS '), lines
    ledger = json.loads(lines[0].removeprefix(label + ' RESULTS '))
    assert ledger == {'groups': groups, 'passed': groups, 'failures': []}, ledger
