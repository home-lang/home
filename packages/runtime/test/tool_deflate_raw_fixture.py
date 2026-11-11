"""Decode actual native raw-deflate output independently using Python zlib."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import zlib

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
reference = '--reference' in sys.argv[3:]
prefix = [binary] + ([] if '--node' in sys.argv[3:] else ['run']) + [script]
with tempfile.TemporaryDirectory(prefix='home-raw-deflate-') as directory:
    result = subprocess.run(prefix+['contract',directory],capture_output=True,timeout=90)
    print(result.stdout.decode(),end='')
    assert result.returncode == 0,result.stdout+result.stderr
    lines=result.stdout.decode().splitlines()
    assert len(lines)==2 and lines[1]=='NODE RAW DEFLATE 14 CHECKS OK',lines
    assert json.loads(lines[0].removeprefix('NODE RAW DEFLATE RESULTS '))=={'checks':14,'passed':14,'failures':[]}
    assert result.stderr==b'',result.stderr
    binary_bytes=bytes([0,255,128,97,0,98])
    expected={'empty':b'','unicode':'actual raw é😀\0'.encode(),'binary':binary_bytes,'arraybuffer':binary_bytes,'wide':binary_bytes,'view':binary_bytes,'callback':b'callback bytes','null-options':binary_bytes,'empty-options':b'default bytes','sync-null':b'default bytes','large':b'a'*65536}
    expected.update({'concurrent-'+str(i):value for i,value in enumerate([b'one',b'two',b'three'])})
    assert {p.stem for p in Path(directory).glob('*.raw')}==set(expected)
    for name,value in expected.items():
        encoded=(Path(directory)/(name+'.raw')).read_bytes()
        decoder=zlib.decompressobj(-15)
        assert decoder.decompress(encoded)+decoder.flush()==value,name
        assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,name
    print('NATIVE RAW DEFLATE 14 STREAMS INDEPENDENTLY DECODED')
    if not reference:
        profile=subprocess.run(prefix+['profile',directory],capture_output=True,timeout=30)
        assert profile.returncode==0 and profile.stdout==b'HOME RAW DEFLATE 6 PROFILE GUARDS OK\n' and profile.stderr==b'',profile.stdout+profile.stderr
        print(profile.stdout.decode(),end='')

fatal = subprocess.run(prefix+['fatal'],capture_output=True,timeout=30)
assert fatal.returncode == 1 and fatal.stdout == b'RAW DEFLATE CALLBACK ENTERED\n' and b'RAW_DEFLATE_CALLBACK_FATAL' in fatal.stderr, fatal.stdout+fatal.stderr
print('NATIVE RAW DEFLATE CALLBACK FATAL POLICY VERIFIED')
