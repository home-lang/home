#!/usr/bin/env python3
"""Verify libproc measures physical allocation and the guard enforces it."""
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    raise SystemExit('libproc footprint verification requires macOS')
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='home-kernel-footprint-') as temporary:
    directory = Path(temporary)
    binary = directory / 'phys-footprint'
    subprocess.run(['/usr/bin/clang', '-O2', '-Wall', '-Wextra', '-Werror',
                    str(root / 'scripts/phys-footprint.c'), '-o', str(binary)],
                   check=True, timeout=30)

    def probe(*pids):
        return subprocess.run([str(binary), *map(str, pids)], capture_output=True,
                              text=True, timeout=2)

    def footprint(pid):
        result = probe(pid)
        assert result.returncode == 0, result
        match = re.fullmatch(r'process \[' + str(pid) + r'\]: 64-bit Footprint: (\d+) B\n', result.stdout)
        assert match, result.stdout
        return int(match[1])

    child = subprocess.Popen([sys.executable, '-u', '-c',
        "import os,sys; print('ready'); sys.stdin.readline(); "
        "payload=os.urandom(64*1024*1024); print('allocated'); sys.stdin.readline()"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        assert selector.select(10), 'child did not start'
        assert child.stdout.readline().strip() == 'ready'
        before = footprint(child.pid)
        child.stdin.write('\n')
        child.stdin.flush()
        assert selector.select(10), 'child did not allocate'
        assert child.stdout.readline().strip() == 'allocated'
        after = footprint(child.pid)
        assert after - before >= 32 * 1024 * 1024, (before, after)
        mixed = probe(child.pid, 2147483647)
        assert mixed.returncode == 0 and mixed.stdout.count('Footprint:') == 1
        assert probe(0).returncode == 2
        assert probe('not-a-pid').returncode == 2
    finally:
        child.kill()
        child.wait(timeout=10)
        selector.close()
    assert probe(child.pid).returncode == 1, 'exited process invented a zero measurement'

    env = os.environ.copy()
    env.update(HOME_RUN_LOCK=str(directory / 'lock'), HOME_RUN_MIN_FREE_MB='1',
               HOME_RUN_CRIT_FREE_MB='1', HOME_RUN_MIN_LEVEL='0', HOME_RUN_MAX_MB='32')
    log = directory / 'guard.log'
    with log.open('w') as output:
        result = subprocess.run(['perl', str(root / 'scripts/run-bounded.pl'), '15',
            sys.executable, '-u', '-c',
            "import os,time; payload=os.urandom(64*1024*1024); time.sleep(60)"],
            cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=30)
    text = log.read_text()
    assert result.returncode == 125, (result.returncode, text)
    assert 'tree footprint' in text and 'runaway ceiling' in text, text
    assert re.search(r'largest sampled tree process pid=\d+ footprint=\d+(?:\.\d+)? MB', text), text
    assert 'could not measure memory' not in text, text
    print(f'kernel footprint allocation delta: {after-before} bytes; memory bound enforced')
