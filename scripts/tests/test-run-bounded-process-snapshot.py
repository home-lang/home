#!/usr/bin/env python3
"""Verify kernel relationships, exec-stable identity and detached-child cleanup."""
import hashlib
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
if sys.platform != 'darwin':
    raise SystemExit('kernel process snapshot verification requires macOS')
source = root / 'scripts/process-snapshot.c'
key = hashlib.sha256(source.read_bytes()).hexdigest()
binary = Path.home() / '.cache/home-run' / ('process-snapshot-' + key)
assert binary.exists(), 'prepare the source-addressed kernel snapshot helper first'

def snapshot():
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=2)
    assert result.returncode == 0, result
    rows = {}
    for line in result.stdout.splitlines():
        pid, parent, group, identity, state = line.split()
        assert pid not in rows
        rows[pid] = (int(parent), int(group), identity, int(state))
    return rows

with tempfile.TemporaryDirectory(prefix='home-process-snapshot-') as temporary:
    directory = Path(temporary)
    child = subprocess.Popen([sys.executable, '-u', '-c',
        "import os,sys; print('ready'); sys.stdin.readline(); "
        "os.execv(sys.executable,[sys.executable,'-u','-c',"
        "\"import sys; print('changed'); sys.stdin.readline()\"])"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    try:
        assert selector.select(10) and child.stdout.readline().strip() == 'ready'
        before = snapshot()[str(child.pid)]
        assert before[0] == os.getpid() and before[1] == child.pid
        assert before[2] != '0:0'
        child.stdin.write('\n')
        child.stdin.flush()
        assert selector.select(10) and child.stdout.readline().strip() == 'changed'
        after = snapshot()[str(child.pid)]
        assert before[:3] == after[:3], (before, after)
    finally:
        child.kill()
        child.wait(timeout=10)
        selector.close()

    marker = directory / 'detached.pid'
    program = ("import subprocess,sys,time; child=subprocess.Popen([sys.executable,'-c',"
               "'import time; time.sleep(60)'],start_new_session=True); "
               "open(sys.argv[1],'w').write(str(child.pid)); time.sleep(60)")
    env = os.environ.copy()
    env.update(HOME_RUN_LOCK=str(directory / 'lock'), HOME_RUN_MIN_FREE_MB='1',
               HOME_RUN_CRIT_FREE_MB='1', HOME_RUN_MIN_LEVEL='0', HOME_RUN_MAX_MB='3840')
    log = directory / 'guard.log'
    try:
        with log.open('w') as output:
            result = subprocess.run(['perl', str(root / 'scripts/run-bounded.pl'), '4',
                                     sys.executable, '-c', program, str(marker)],
                                    env=env, cwd=root, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=25)
        assert result.returncode == 124 and 'wall-clock bound' in log.read_text()
        assert marker.exists()
        pid = int(marker.read_text())
        # Darwin SZOMB (5) is terminal while launchd collects the descendant.
        remaining = snapshot().get(str(pid))
        assert remaining is None or remaining[3] == 5, remaining
    finally:
        if marker.exists():
            try:
                os.kill(int(marker.read_text()), 9)
            except ProcessLookupError:
                pass
    print('kernel snapshot preserves exec identity and cleans detached descendants')
