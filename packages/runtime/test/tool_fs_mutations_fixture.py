"""Independently verify callback filesystem effects, bytes and inode semantics."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
with tempfile.TemporaryDirectory(prefix='home-fs-mutations-') as directory:
    root = Path(directory)
    raw = bytes((i*73+19)&255 for i in range(1048593))
    (root/'source.bin').write_bytes(raw)
    os.chmod(root/'source.bin',0o751)
    os.link(root/'source.bin',root/'source-alias')
    (root/'dest').write_bytes(b'OLD-LONGER-DESTINATION')
    inode=(root/'dest').stat().st_ino
    os.link(root/'dest',root/'dest-alias')
    (root/'destination-target').write_bytes(b'OLD-TARGET')
    os.symlink(root/'destination-target',root/'destination-link')
    (root/'unlink-target').write_bytes(b'KEEP')
    os.symlink(root/'unlink-target',root/'unlink-link')
    (root/'exclusive-old').write_bytes(b'UNCHANGED')
    args=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script,'--root',str(root)]
    home='--home-profile' in sys.argv[3:]
    if home:args.append('--home-profile')
    # A controlled native umask makes directory permission expectations portable.
    process=subprocess.run(args,capture_output=True,timeout=90,preexec_fn=lambda:os.umask(0o022))
    print(process.stdout.decode(),end='')
    assert process.returncode==0 and process.stderr==b'', process.stdout[:8000]+process.stderr
    lines=process.stdout.decode().splitlines()
    ledger=json.loads(lines[0].removeprefix('FS MUTATION RESULTS '))
    assert ledger=={'groups':43,'passed':43,'failures':[],'doubleCallbacks':[]}, ledger
    for name in ['source.bin','source-alias','fresh-copy','dest','dest-alias','destination-link','destination-target','exclusive-new','sync-copy','fractional-mode']:
        assert (root/name).read_bytes()==raw,name
        assert (root/name).stat().st_mode&0o777==0o751,name
    assert (root/'dest').stat().st_ino==inode
    assert (root/'dest-alias').stat().st_ino==inode
    assert (root/'destination-link').is_symlink()
    assert not (root/'unlink-link').exists() and (root/'unlink-target').read_bytes()==b'KEEP'
    assert (root/'exclusive-old').read_bytes()==b'UNCHANGED'
    assert (root/'descriptor').read_bytes()==b'AB'
    assert (root/'promisified/b').read_bytes()==b'REAL\x00IO'
    print('NATIVE FS MUTATION BYTES/INODES/LINKS/PERMISSIONS VERIFIED '+json.dumps({'source_bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'hardlink_identity_preserved':True,'symlink_entry_preserved':True}))

# No awaited promise keeps these children alive. Their native task queue must
# finish real IO, dispatch the identical thrown object, and never convert a
# callback exception into a rejected promise or call the callback twice.
child = str(Path(script).with_name('fs_mutations_child.cjs'))
for operation in ['writeFile', 'mkdir', 'unlink', 'copyFile']:
    for mode in ['handled', 'error', 'fatal', 'liveness']:
        with tempfile.TemporaryDirectory(prefix='home-fs-child-') as directory:
            root = Path(directory)
            (root/'child-source').write_bytes(b'ACTUAL\0BYTES')
            args = [binary] + ([] if '--node' in sys.argv[3:] else ['run']) + [child, operation, mode, str(root)]
            process = subprocess.run(args, capture_output=True, timeout=15)
            if mode in ['handled', 'error']:
                assert process.returncode == 91 and process.stderr == b'', (operation, mode, process)
                assert process.stdout.decode() == 'FS CALLBACK EXCEPTION IDENTITY '+operation+' '+mode+'\n'
                assert (root/'child-marker').read_bytes() == b'IDENTITY'
            elif mode == 'fatal':
                assert process.returncode != 0 and b'actual filesystem callback witness' in process.stderr, (operation, process)
                assert not (root/'child-marker').exists()
            else:
                assert process.returncode == 0 and process.stderr == b'', (operation, process)
                assert process.stdout.decode() == 'FS CALLBACK LIVENESS '+operation+'\n'
                assert (root/'child-marker').read_bytes() == b'LIVE'
            if mode != 'error':
                if operation == 'writeFile': assert (root/'child-destination').read_bytes() == b'REAL'
                if operation == 'mkdir': assert (root/'child-destination').is_dir()
                if operation == 'unlink': assert not (root/'child-source').exists()
                if operation == 'copyFile': assert (root/'child-destination').read_bytes() == b'ACTUAL\0BYTES'
print('FS MUTATION 16 EXCEPTION/FATAL/LIVENESS CHILDREN OK')
