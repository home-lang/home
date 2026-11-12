"""Observe real warning events, physical stderr and fatal callback policy."""
from pathlib import Path
import json
import subprocess
import sys


def main():
    binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    reference = '--reference' in sys.argv[3:]
    prefix = [binary] + ([] if reference else ['run'])
    for script, marker, count in [
        ('deprecations.mjs', 'DEPRECATION RESULTS ', 20),
        ('process_warnings.mjs', 'WARNING RESULTS ', 13),
    ]:
        child = subprocess.run(prefix + [str(Path(scripts) / script)], capture_output=True, timeout=60)
        print(child.stdout.decode(), end='')
        if child.returncode:
            print(child.stderr.decode(), file=sys.stderr, end='')
        assert child.returncode == 0, (script, child.returncode)
        lines = child.stdout.decode().splitlines()
        assert len(lines) == 1 and lines[0].startswith(marker), lines
        assert json.loads(lines[0][len(marker):]) == {'groups': count, 'passed': count, 'failures': []}, lines
        assert b'OWN_REMOVED_WARNING' not in child.stderr, child.stderr
    for mode in ['basic', 'trace', 'throw', 'listener-throw', 'removed', 'silent']:
        child = subprocess.run(prefix + [str(Path(scripts) / 'deprecation_child.cjs'), mode], capture_output=True, timeout=30)
        print('DEPRECATION CHILD RESULT ' + json.dumps({'mode': mode, 'exit_code': child.returncode, 'stdout': child.stdout.decode(), 'stderr': child.stderr.decode()}))
        lines = child.stdout.decode().splitlines()
        assert lines[:3] == ['BODY:1', 'BODY:2', 'SYNC:{"one":5,"two":8,"calls":2,"warnings":0}'], (mode, lines, child.stderr)
        if mode in ['throw', 'listener-throw']:
            assert child.returncode != 0 and not any(line.startswith('LATER:') for line in lines), (mode, child.returncode, lines, child.stderr)
            code = 'OWN_CHILD' if mode == 'throw' else 'OWN_FATAL_LISTENER'
            assert 'FATAL_CODE:' + code in lines, (mode, lines, child.stderr)
        else:
            assert child.returncode == 0, (mode, child.returncode, lines, child.stderr)
            expected = 0 if mode in ['removed', 'silent'] else 1
            assert lines[-1] == 'LATER:' + str(expected), (mode, lines)
            if expected:
                assert child.stderr.count(b'[OWN_CHILD]') == 1 and b'DeprecationWarning: owned child warning' in child.stderr, (mode, child.stderr)
                if mode == 'trace':
                    assert b'deprecation_child.cjs' in child.stderr, child.stderr
            else:
                assert child.stderr == b'', (mode, child.stderr)
        print('NATIVE DEPRECATION CHILD ' + mode + ' VERIFIED')


if __name__ == '__main__':
    main()
