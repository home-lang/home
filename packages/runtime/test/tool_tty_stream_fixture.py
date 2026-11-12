"""Use real PTYs and inspect physical output; no terminal API is simulated."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import pty
import tty
import termios
import fcntl
import struct
import select
import json

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
for columns, rows in [(93,27),(47,11)]:
    master, slave = pty.openpty()
    try:
        tty.setraw(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        env = dict(os.environ)
        for name in ['FORCE_COLOR','NO_COLOR','NODE_DISABLE_COLORS']:
            env.pop(name,None)
        args = [binary] + ([] if '--node' in sys.argv[3:] else ['run']) + [script]
        if '--home-profile' in sys.argv[3:]:
            args.append('--home-profile')
        process = subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=slave,stderr=subprocess.PIPE,env=env)
        try:
            _, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            _, stderr = process.communicate()
            raise AssertionError('PTY child timed out: '+repr(stderr))
        # Keep the parent's slave open while draining. On macOS, closing the
        # final slave first can discard queued bytes even after a successful write.
        output = b''
        while select.select([master],[],[],0.2)[0]:
            try:
                chunk = os.read(master,65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
        expected = 'TTY €😀\n'.encode()+bytes([0,255,65])+b'\x1b[3;4H\x1b[2D\x1b[1B\x1b[2K\x1b[0JEND\n'
        print('TTY PHYSICAL OBSERVATION '+json.dumps({'columns':columns,'rows':rows,'exit':process.returncode,'bytes':len(output),'hex':output.hex(),'stderr':stderr.decode()}))
        assert process.returncode == 0, stderr[:6000]
        assert output == expected, (output,expected)
        lines = stderr.decode().splitlines()
        assert len(lines)==(4 if '--home-profile' in sys.argv[3:] else 3), lines
        ledger = json.loads(lines[0].removeprefix('TTY STREAM RESULTS '))
        assert ledger=={'groups':29,'passed':29,'failures':[]}, ledger
        oracle = json.loads(lines[1].removeprefix('TTY COLOR ORACLE RESULTS '))
        assert oracle=={'node':'v26.10.0','cases':119,'mismatches':0,'first':[]}, oracle
        window=json.loads(lines[2].removeprefix('TTY NATIVE WINDOW '))
        retained=window.pop('originalStillTerminal')
        assert window=={'columns':columns,'rows':rows}
        if '--node' in sys.argv[3:]:
            assert retained is True
        if '--home-profile' in sys.argv[3:]:
            assert retained is True
            assert lines[3]=='HOME TTY PROFILE OWNED DUPLICATE CLOSED; CALLER FD RETAINED; OPTIONS REFUSED; READ/RAW/AUTOMATIC RESIZE UNAVAILABLE'
        print(lines[0])
        print(lines[1])
        print(lines[2])
        if '--home-profile' in sys.argv[3:]:
            print(lines[3])
    finally:
        os.close(master)
        os.close(slave)
print('NATIVE TTY TWO WINDOWS, UTF8/BINARY/ANSI BYTES AND REAL STREAM CLOSE VERIFIED')
