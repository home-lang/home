"""Canonical paths and errno from the real filesystem; JS runs on the supplied host."""
import ctypes
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='home-realpath-', dir='/tmp') as directory:
    root = Path(directory)
    (root / 'real' / 'inner').mkdir(parents=True)
    for name in ['plain.txt', 'leaf', 'real/leaf', 'space 🐿.txt']:
        (root / name).write_text('actual bytes')
    (root / 'file-link').symlink_to('plain.txt')
    (root / 'folder-link').symlink_to('real/inner')
    (root / 'broken').symlink_to('absent')
    (root / 'loop-a').symlink_to('loop-b')
    (root / 'loop-b').symlink_to('loop-a')
    (root / 'mutable').symlink_to('plain.txt')
    native = ctypes.CDLL(None, use_errno=True)
    native.realpath.argtypes = (ctypes.c_char_p, ctypes.c_void_p)
    native.realpath.restype = ctypes.c_void_p
    native.free.argtypes = (ctypes.c_void_p,)
    def oracle(path):
        pointer = native.realpath(os.fsencode(path), None)
        if not pointer:
            return {'code': errno.errorcode[ctypes.get_errno()]}
        try:
            return {'path': os.fsdecode(ctypes.string_at(pointer))}
        finally:
            native.free(pointer)
    cases = []
    previous = os.getcwd()
    try:
        os.chdir(directory)
        for path in ['.', '', '/', directory, 'plain.txt', './plain.txt', 'file-link', 'folder-link', 'folder-link/..', 'folder-link/../leaf', 'real/inner/../../leaf', 'space 🐿.txt', 'broken', 'absent', 'loop-a', 'plain.txt/child', 'plain.txt/']:
            cases.append([path, oracle(os.path.abspath(path)), oracle(path)])
    finally:
        os.chdir(previous)
    fixture = str(Path(sys.argv[2]).resolve())
    command = [str(Path(sys.argv[1]).resolve())] + ([] if len(sys.argv) > 3 and sys.argv[3] == 'reference' else ['run']) + [fixture, json.dumps(cases, ensure_ascii=False), directory]
    sys.exit(subprocess.call(command, cwd=directory))
