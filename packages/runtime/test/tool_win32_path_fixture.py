"""Verify a deterministic path corpus against an executed, pinned Node oracle."""
from pathlib import Path
import hashlib
import itertools
import json
import random
import subprocess
import sys
import tempfile


def canonical(value):
    return json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode()


def corpus():
    roots = ['', '/', '\\', '//', '\\\\', '///', 'C:', 'C:/', 'c:\\', 'Z:\\', '//server/share', '//server/share/', '//server//share///', '//?/', '\\\\?\\', '//./', '\\\\?\\UNC\\', '\\\\?\\CON:', 'CON:', 'COM1:']
    segments = ['', 'a', 'b', '..', '.', '...', 'C:', 'x:y', 'CON', 'NUL', 'COM¹', '☃', 'é', '😀', 'sp ace', 'a.', '.x', 'foo:', 'C:/x']
    inputs = ['', '.', '..', '/', '\\', 'C:', 'C:.', 'C:..', 'C:/..', '//server', '//server/share', '//server/share/..', '//./NUL:', 'CONX', 'CON:', 'con:foo', 'ab:/x', 'a/../C:/x', 'a\0b/../c', '\0']
    for root, segment, suffix in itertools.product(roots, segments, ['', '/', '/..', '\\.']):
        inputs.append(root + segment + suffix)
    rng = random.Random(0x57494E32)
    for _ in range(2500):
        text = rng.choice(roots)
        for _ in range(rng.randrange(9)):
            text += rng.choice(['/', '\\', '/\\', '\\\\', '//']) + rng.choice(segments)
        inputs.append(text)
    return inputs


def main():
    binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    prefix = [binary] + ([] if '--reference' in sys.argv[3:] else ['run'])
    inputs = corpus()
    golden = json.loads((Path(scripts) / 'win32_path_oracle.json').read_text())
    assert len(inputs) == golden['cases'] and hashlib.sha256(canonical(inputs)).hexdigest() == golden['input_sha256']
    with tempfile.TemporaryDirectory(prefix='home-win32-path-') as temporary:
        data = Path(temporary) / 'inputs.json'
        data.write_bytes(canonical(inputs))
        child = subprocess.run(prefix + [str(Path(scripts) / 'node_path_win32.mjs'), str(data)], capture_output=True, timeout=90)
        assert child.returncode == 0 and child.stderr == b'', (child.returncode, child.stdout.decode().splitlines()[:1], child.stderr.decode())
        lines = child.stdout.decode().splitlines()
        ledger = json.loads(lines[0].removeprefix('WIN32 PATH RESULTS '))
        assert ledger == {'groups': 10, 'passed': 10, 'failures': []}, ledger
        result = json.loads(lines[1].removeprefix('WIN32 PATH ACTUAL '))
        assert len(result) == len(inputs)
        actual = hashlib.sha256(canonical(result)).hexdigest()
        assert actual == golden['result_sha256'], {'actual_digest': actual, 'node_digest': golden['result_sha256'], 'cases':len(result)}
        print(lines[0])
        print('NATIVE WIN32 PATH ORACLE VERIFIED ' + json.dumps({'cases':len(inputs),'node':golden['node_version'],'result_sha256':actual}))
        if '--reference' not in sys.argv[3:]:
            child = subprocess.run(prefix + [str(Path(scripts) / 'win32_path_profile.mjs')], capture_output=True, timeout=30)
            assert child.returncode == 0 and child.stderr == b'', (child.stdout, child.stderr)
            assert child.stdout == b'HOME WIN32 PATH PROFILE TWO LEXICAL METHODS; DRIVE CWD AND FILESYSTEM APIS ABSENT\n', child.stdout
            print(child.stdout.decode(), end='')


if __name__ == '__main__':
    main()
