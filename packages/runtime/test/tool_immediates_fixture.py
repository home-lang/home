"""Verify actual check-phase callbacks, owner lifecycle and failure policy."""
from pathlib import Path
import json
import subprocess
import sys

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
flags = sys.argv[3:]
prefix = [binary] + ([] if '--node' in flags else ['run']) + [script]
if '--context' in flags:
    context = subprocess.run(prefix, capture_output=True, timeout=30)
    assert context.returncode == 0, context.stdout + context.stderr
    lines = context.stdout.decode().splitlines()
    assert len(lines) == 2 and lines[1] == 'NODE IMMEDIATE CONTEXT 3 GROUPS OK', lines
    assert json.loads(lines[0].removeprefix('NODE IMMEDIATE CONTEXT RESULTS ')) == {'groups':3,'passed':3,'failures':[]}
    assert context.stderr == b'', context.stderr
    print(context.stdout.decode(), end='')
    sys.exit(0)
result = subprocess.run(prefix + ['contract'], capture_output=True, timeout=90)
assert result.returncode == 0, result.stdout + result.stderr
lines = result.stdout.decode().splitlines()
assert len(lines) == 2 and lines[1] == 'NODE IMMEDIATE 18 CHECKS OK', lines
assert json.loads(lines[0].removeprefix('NODE IMMEDIATE RESULTS ')) == {'checks':18,'passed':18,'failures':[]}
assert result.stderr == b'', result.stderr
for mode, expected in [('unref',b'UNREF IMMEDIATES REGISTERED\n'),('ref',b'REFERENCED IMMEDIATE FIRED\n')]:
    child = subprocess.run(prefix + [mode], capture_output=True, timeout=15)
    assert child.returncode == 0 and child.stdout == expected and child.stderr == b'', (mode,child.returncode,child.stdout,child.stderr)
fatal = subprocess.run(prefix + ['fatal'], capture_output=True, timeout=15)
assert fatal.returncode == 1 and fatal.stdout == b'monitor\nexit 1\n' and b'immediate fatal witness' in fatal.stderr, (fatal.returncode,fatal.stdout,fatal.stderr)
print(result.stdout.decode(), end='')
print('NATIVE IMMEDIATE REF LIVENESS AND FATAL POLICY VERIFIED')
if '--reference' not in flags:
    guarded = subprocess.run(prefix + ['guards'], capture_output=True, timeout=15)
    assert guarded.returncode == 0 and guarded.stdout == b'HOME IMMEDIATE 2 REFUSALS OK\n' and guarded.stderr == b'', (guarded.returncode,guarded.stdout,guarded.stderr)
    print(guarded.stdout.decode(), end='')
