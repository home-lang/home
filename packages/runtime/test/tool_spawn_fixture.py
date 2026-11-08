"""Real child I/O, scheduler liveness, reaping and explicit refusal contracts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

host = str(Path(sys.argv[1]).resolve())
fixtures = Path(__file__).resolve().parent / 'tool_modules'
with tempfile.TemporaryDirectory(prefix='home-spawn-') as directory:
    root = Path(directory)
    positive = subprocess.run([host, 'run', str(fixtures / 'spawn_lifecycle.mjs'), directory], input='actual inherited input\n', capture_output=True, text=True, timeout=30, env={**os.environ, 'REMOVED': 'must not inherit'})
    assert positive.returncode == 0, positive.stdout + positive.stderr
    assert positive.stdout == 'native child stdout 🐿\nOK real asynchronous child lifecycle\n', positive.stdout
    assert positive.stderr == 'native child stderr\n', positive.stderr
    assert (root / 'cwd.txt').read_text() == str(root.resolve())
    for mode in ['orphan', 'callback', 'no-await', 'refusals']:
        path = root / mode
        result = subprocess.run([host, 'run', str(fixtures / 'spawn_exit.cjs'), mode, str(path)], capture_output=True, text=True, timeout=15)
        if mode in ['orphan', 'callback']:
            assert result.returncode == 1 and ('owned child cleanup witness' if mode == 'orphan' else 'native child exit witness') in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
        if mode == 'orphan':
            pid = int(path.read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f'owned child {pid} survived host teardown')
        elif mode == 'no-await':
            assert path.read_text() == 'kept alive'
        elif mode == 'refusals':
            assert not path.exists()
print('OK real child lifecycle, inherited I/O, owner-loop liveness, cleanup and refusals')
