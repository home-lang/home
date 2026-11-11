"""Require all copy cases and verify real overlapping bytes independently."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
flags = sys.argv[3:]
prefix = [binary] + ([] if '--node' in flags else ['run']) + [script]
if '--shared' in flags:
    result = subprocess.run(prefix+['shared'],capture_output=True,timeout=30)
    assert result.returncode == 0 and result.stdout == b'NATIVE BUFFER COPY SHARED 2 CHECKS OK\n' and result.stderr == b'', result.stdout+result.stderr
    print(result.stdout.decode(),end='')
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix='home-buffer-copy-') as directory:
    path=Path(directory)/'actual.bin'
    result=subprocess.run(prefix+['contract',str(path)],capture_output=True,timeout=60)
    assert result.returncode == 0,result.stdout+result.stderr
    lines=result.stdout.decode().splitlines()
    assert len(lines)==2 and lines[1]=='NODE BUFFER COPY 20 CHECKS OK',lines
    assert json.loads(lines[0].removeprefix('NODE BUFFER COPY RESULTS '))=={'checks':20,'passed':20,'failures':[]}
    assert result.stderr==b'',result.stderr
    expected=bytearray(i%251 for i in range(65536))
    for target,start,end in [(3,0,40000),(0,7,64000),(999,600,35000)]:
        data=bytes(expected[start:end]);count=min(len(data),len(expected)-target);expected[target:target+count]=data[:count]
    assert path.read_bytes()==expected
    print(result.stdout.decode(),end='')
    print('NATIVE BUFFER COPY 65536 PHYSICAL OVERLAPPING BYTES VERIFIED')
    if '--reference' not in flags:
        profile=subprocess.run(prefix+['profile',str(path)],capture_output=True,timeout=30)
        assert profile.returncode==0 and profile.stdout==b'HOME BUFFER COPY NATIVE METADATA PROFILE OK\n' and profile.stderr==b'',profile.stdout+profile.stderr
        print(profile.stdout.decode(),end='')
