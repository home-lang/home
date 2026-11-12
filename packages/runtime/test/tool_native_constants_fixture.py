"""Compare target libc constants with independent Python and real kernel IO."""
from pathlib import Path
import errno
import json
import os
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
with tempfile.TemporaryDirectory(prefix='home-native-constants-') as directory:
    args=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script,'--root',directory]
    if '--home-profile' in sys.argv[3:]:args.append('--home-profile')
    child=subprocess.run(args,capture_output=True,timeout=30)
    print(child.stdout.decode(),end='')
    assert child.returncode==0 and child.stderr==b'',child.stdout+child.stderr
    lines=child.stdout.decode().splitlines()
    ledger=json.loads(lines[0].removeprefix('NATIVE CONSTANTS RESULTS '))
    assert ledger=={'groups':18,'passed':18,'failures':[]},ledger
    snapshot=json.loads(lines[1].removeprefix('NATIVE CONSTANTS SNAPSHOT '))
    for name,value in snapshot['errno'].items():assert getattr(errno,name)==value,(name,value,getattr(errno,name))
    for name,value in snapshot['flags'].items():assert getattr(os,name)==value,(name,value)
    assert (Path(directory)/'exclusive').read_bytes()==b'KEEP'
    path=Path(directory)/'python-open'
    flags=snapshot['flags']['O_CREAT']|snapshot['flags']['O_EXCL']|snapshot['flags']['O_RDWR']
    fd=os.open(path,flags,0o600)
    os.write(fd,b'ACTUAL\0NATIVE')
    os.close(fd)
    try:os.open(path,flags,0o600)
    except OSError as error:assert error.errno==snapshot['errno']['EEXIST']
    else:raise AssertionError('Exclusive creation was not enforced')
    assert path.read_bytes()==b'ACTUAL\0NATIVE'
    print('INDEPENDENT NATIVE CONSTANTS AND EXCLUSIVE KERNEL OPEN VERIFIED '+json.dumps({'errno_names':len(snapshot['errno']),'flags':snapshot['flags']}))
