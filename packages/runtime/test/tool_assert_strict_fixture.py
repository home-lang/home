"""Require every strict facade group to execute and pass."""
from pathlib import Path
import json
import subprocess
import sys
binary,script=[str(Path(p).resolve()) for p in sys.argv[1:3]]
args=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script]
r=subprocess.run(args,capture_output=True,timeout=90)
print(r.stdout.decode(),end='')
assert r.returncode==0,r.stdout+r.stderr
lines=r.stdout.decode().splitlines()
assert len(lines)==2 and lines[1]=='STRICT ASSERT 18 GROUPS OK',lines
assert json.loads(lines[0].removeprefix('STRICT ASSERT RESULTS '))=={'groups':18,'passed':18,'failures':[]}
assert r.stderr==b'',r.stderr
