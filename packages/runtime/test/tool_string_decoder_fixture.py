"""Verify actual chunked byte decoding against a physical Python UTF-8 oracle."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
with tempfile.TemporaryDirectory(prefix='home-string-decoder-') as directory:
    root = Path(directory)
    raw = ('A€😀\ufeff\0𐐀漢字\n' * 2048).encode() + b'\xe0\x80\xe2\x82'
    source, output = root / 'input.bin', root / 'decoded.txt'
    source.write_bytes(raw)
    args = [binary] + ([] if '--node' in sys.argv[3:] else ['run']) + [script, '--physical', str(source), str(output)]
    result = subprocess.run(args, capture_output=True, timeout=90)
    assert result.returncode == 0 and result.stderr == b'', result.stdout[:4000] + result.stderr
    lines = result.stdout.decode().splitlines()
    assert len(lines) == 4, lines[:2]
    ledger = json.loads(lines[0].removeprefix('STRING DECODER RESULTS '))
    assert ledger == {'groups': 27, 'passed': 27, 'failures': []}, ledger
    oracle = json.loads(lines[1].removeprefix('STRING DECODER ORACLE RESULTS '))
    assert oracle == {'node': 'v26.10.0', 'cases': 3383, 'mismatches': 0, 'first': []}, oracle
    assert lines[2] == 'STRING DECODER PHYSICAL ' + str(len(raw)), lines[2]
    assert lines[3] == 'STRING DECODER 27 GROUPS OK', lines[3]
    expected = raw.decode('utf8', errors='replace').encode()
    actual = output.read_bytes()
    assert actual == expected, (len(actual), len(expected))
    print(lines[0])
    print(lines[1])
    print(lines[3])
    print('NATIVE STRING DECODER PHYSICAL UTF8 VERIFIED ' + json.dumps({'input_bytes': len(raw), 'output_bytes': len(actual), 'input_sha256': hashlib.sha256(raw).hexdigest(), 'output_sha256': hashlib.sha256(actual).hexdigest()}))
