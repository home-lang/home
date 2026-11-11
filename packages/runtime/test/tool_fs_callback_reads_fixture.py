"""Check real physical read bytes, directory entries, callback liveness and fatal policy."""
from pathlib import Path
import base64
import json
import subprocess
import sys
import tempfile

binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
reference = '--reference' in sys.argv[3:]
prefix = [binary] + ([] if reference else ['run'])
with tempfile.TemporaryDirectory(prefix='home-fs-callback-') as temporary:
    root = Path(temporary) / 'fixture'
    root.mkdir()
    expected = bytes((i * 37 + 11) & 255 for i in range(65536))
    (root / 'binary.dat').write_bytes(expected)
    (root / 'text-☃.txt').write_bytes('real UTF8 ☃\0line\n'.encode())
    (root / 'malformed.dat').write_bytes(b'\xff\0\xe2\x82')
    (root / 'dir').mkdir()
    (root / 'link').symlink_to('binary.dat')
    (root / 'dangling').symlink_to('missing')
    result = subprocess.run(prefix + [str(Path(scripts) / 'node_fs_callback_reads.mjs'), str(root)], capture_output=True, timeout=90)
    lines = result.stdout.decode().splitlines()
    assert result.returncode == 0 and result.stderr == b'', result.stdout.splitlines()[:1] + [result.stderr]
    assert len(lines) == 3, lines[:1]
    ledger = json.loads(lines[0].removeprefix('FS CALLBACK READ RESULTS '))
    assert ledger == {'groups': 21, 'passed': 21, 'failures': []}, ledger
    actual = json.loads(lines[1].removeprefix('FS CALLBACK PHYSICAL '))
    assert actual['bytes'] == len(expected) and base64.b64decode(actual['base64'], validate=True) == expected
    print(lines[0])
    print(lines[2])
    print('NATIVE CALLBACK READ 65536 PHYSICAL BYTES INDEPENDENTLY VERIFIED')
    for mode, path in [('read', root / 'binary.dat'), ('read-error', root / 'missing'), ('directory', root)]:
        marker = Path(temporary) / (mode + '.marker')
        child = subprocess.run(prefix + [str(Path(scripts) / 'fs_callback_read_exit.cjs'), mode, str(path), str(marker)], capture_output=True, timeout=30)
        assert child.returncode != 0 and b'FS_CALLBACK_FATAL_WITNESS' in child.stderr, child
        assert marker.read_bytes() == b'X', 'An exception invoked the callback twice'
    marker = Path(temporary) / 'live.marker'
    child = subprocess.run(prefix + [str(Path(scripts) / 'fs_callback_read_exit.cjs'), 'live', str(root / 'binary.dat'), str(marker)], capture_output=True, timeout=30)
    assert child.returncode == 0 and child.stderr == b'' and child.stdout == b'FS CALLBACK LIVE REAL BYTES 65536\n', child
    assert marker.read_bytes() == b'X'
    print('NATIVE FS CALLBACK 3 FATAL CHILDREN AND REF LIVENESS VERIFIED')
    if not reference:
        guard = subprocess.run(prefix + [str(Path(scripts) / 'fs_callback_read_profile.mjs'), str(root)], capture_output=True, timeout=30)
        assert guard.returncode == 0 and guard.stderr == b'', guard
        lines = guard.stdout.decode().splitlines()
        assert json.loads(lines[0].removeprefix('HOME FS CALLBACK PROFILE RESULTS ')) == {'groups': 6, 'passed': 6, 'failures': []}
        print(guard.stdout.decode(), end='')
