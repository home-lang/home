#!/usr/bin/env python3
"""Prepare real copy inputs and independently verify large copied file bytes.

The given executable always runs the JS tests; --direct-reference only changes
its CLI syntax for separate Node/Bun oracle runs. There is no runtime fallback.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

executable, script = sys.argv[1:3]
direct_reference = sys.argv[3:] == ['--direct-reference']
if not direct_reference and len(sys.argv) != 4:
    raise SystemExit('Home runs require the explicit unsupported-copy fixture')
with tempfile.TemporaryDirectory(prefix='home-real-copy-') as temporary:
    root = Path(temporary)
    source = root / 'input'
    output = root / 'output'
    source.mkdir()
    output.mkdir()
    (source / 'direct.bin').write_bytes(bytes(range(256)) * 3)
    (source / 'direct.bin').chmod(0o750)
    os.link(source / 'direct.bin', source / 'same-inode')
    tree = source / 'tree'
    (tree / 'deep').mkdir(parents=True)
    (tree / 'empty').mkdir()
    (tree / 'omit').mkdir()
    (tree / 'omit/child').write_text('excluded')
    (tree / 'deep/espaço-🦎').write_text('unicode data')
    (tree / 'deep/espaço-🦎').chmod(0o640)
    (tree / '.hidden').write_text('hidden')
    os.symlink(tree, source / 'alias-to-tree')
    os.symlink(source / 'direct.bin', source / 'source-link')
    os.mkfifo(source / 'source-fifo')
    readonly = source / 'readonly'
    readonly.mkdir()
    (readonly / 'file').write_text('read-only tree')
    readonly.chmod(0o555)
    block = bytes(range(256)) * 4096
    with (source / 'large.bin').open('wb') as stream:
        for _ in range(9):
            stream.write(block)
    try:
        command = [executable] + ([] if direct_reference else ['run']) + [script]
        result = subprocess.run(command, env={**os.environ, 'HOME_TOOL_COPY_FIXTURE': str(root)})
        if result.returncode:
            raise SystemExit(result.returncode)
        if not direct_reference:
            rejected = subprocess.run([executable, 'run', sys.argv[3]], env={**os.environ, 'HOME_TOOL_COPY_FIXTURE': str(root)})
            if rejected.returncode:
                raise SystemExit(rejected.returncode)
        expected = hashlib.sha256((source / 'large.bin').read_bytes()).hexdigest()
        for lane in ['promise', 'sync']:
            copied = output / (lane + '-large.bin')
            if not copied.is_file() or hashlib.sha256(copied.read_bytes()).hexdigest() != expected:
                raise RuntimeError('Actual ' + lane + ' copy differs from the 9 MiB source')
        print('HOST CP INDEPENDENT 9 MiB FILE HASHES OK', flush=True)
    finally:
        # Read-only output directories must be restored before test cleanup.
        for parent, directories, _ in os.walk(root, followlinks=False):
            for name in directories:
                path = Path(parent) / name
                if not path.is_symlink():
                    path.chmod(0o755)
