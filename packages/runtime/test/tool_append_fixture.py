"""Verify actual append bytes and preserved permissions outside the JS facade."""
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

host, fixture = str(Path(sys.argv[1]).resolve()), str(Path(sys.argv[2]).resolve())
with tempfile.TemporaryDirectory(prefix='home-append-', dir='/tmp') as directory:
    root = Path(directory)
    for name in ['existing', 'override', 'readonly-flag', 'descriptor', 'descriptor-append']:
        (root / name).write_bytes(b'seed')
        (root / name).chmod(0o640)
    command = [host] + ([] if len(sys.argv) > 3 and sys.argv[3] == 'reference' else ['run']) + [fixture, directory]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        sys.exit(result.returncode)
    expected = {'text': 'A\0🐿B'.encode(), 'existing': b'seedsyncpromise', 'override': b'replacement', 'readonly-flag': b'XYed', 'bytes': bytes([0, 128, 255, 128, 255, 255]), 'descriptor': b'ABed', 'descriptor-append': b'seedtail'}
    for name, data in expected.items():
        assert (root / name).read_bytes() == data, (name, (root / name).read_bytes(), data)
    assert stat.S_IMODE((root / 'existing').stat().st_mode) == 0o640
