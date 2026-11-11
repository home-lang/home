"""Real native child for captured-pipe contract tests (no JS host fallback)."""
import json
import os
from pathlib import Path
import signal
import sys
import time

mode = sys.argv[1]
if mode == 'echo':
    sys.stdout.buffer.write(sys.stdin.buffer.read())
elif mode == 'binary':
    sys.stdout.buffer.write(b'\0\xff\x80a\0b')
elif mode == 'invalid-utf8':
    sys.stdout.buffer.write(b'\xffa\0b')
elif mode == 'failure':
    sys.stdout.buffer.write(b'out\0\xff'); sys.stdout.buffer.flush()
    sys.stderr.buffer.write(b'err\0\xfe'); sys.stderr.buffer.flush()
    sys.exit(7)
elif mode == 'signal':
    sys.stdout.buffer.write(b'before signal'); sys.stdout.buffer.flush()
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == 'duplex':
    sys.stdout.buffer.write(b'\0' * (256 * 1024)); sys.stdout.buffer.flush()
    sys.stderr.buffer.write(b'\0' * (256 * 1024)); sys.stderr.buffer.flush()
    sys.stdout.buffer.write(sys.stdin.buffer.read()); sys.stdout.buffer.flush()
elif mode == 'metadata':
    print(json.dumps({'cwd': os.getcwd(), 'witness': os.environ.get('HOME_EXEC_WITNESS'), 'path': os.environ.get('PATH')}), end='')
elif mode == 'argv':
    print(json.dumps(sys.argv[2:]), end='')
elif mode == 'overflow':
    sys.stdout.buffer.write(b'x' * (256 * 1024)); sys.stdout.buffer.flush()
    time.sleep(30)
elif mode == 'early-close':
    os.close(0); time.sleep(0.02)
    sys.stdout.buffer.write(b'done'); sys.stdout.buffer.flush()
elif mode == 'stderr':
    sys.stderr.buffer.write(b'\0\xffdiagnostic'); sys.stderr.buffer.flush()
    sys.stdout.buffer.write(b'actual'); sys.stdout.buffer.flush()
elif mode == 'touch':
    Path(sys.argv[2]).write_text('child executed')
else:
    raise ValueError(mode)
