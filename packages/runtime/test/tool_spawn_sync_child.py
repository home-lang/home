"""Actual OS child: writes a PID/descriptor/environment witness and binary output."""
import sys, os, json, stat, hashlib
from pathlib import Path
witness, mode = sys.argv[1:3]
def write(fd,data):
    while data:
        count=os.write(fd,data); data=data[count:]
if mode == 'duplex':
    write(1, bytes(256*1024))
    write(2, bytes([7])*(256*1024))
input_data = sys.stdin.buffer.read() if mode in ('input','duplex','inherit') else b''
state = {'pid':os.getpid(),'cwd':os.getcwd(),'WITNESS':os.getenv('WITNESS'),'env_keys':sorted(os.environ), 'stdin_character':stat.S_ISCHR(os.fstat(0).st_mode),'args':sys.argv[3:],'input_bytes':len(input_data),'input_sha256':hashlib.sha256(input_data).hexdigest()}
Path(witness).write_text(json.dumps(state))
if mode == 'limit':
    write(1,bytes(256*1024))
    import time; time.sleep(30)
elif mode in ('input','duplex'): write(1,input_data)
elif mode == 'inherit':
    write(1,b'inherited-out:'+input_data)
    write(2,b'inherited-err')
else:
    write(1,b'out\x00\xff\xe2\x82\xac')
    write(2,b'err\x00\xfe')
