"""Execute function/spy contracts without claiming a test runner exists."""
from pathlib import Path
import json
import subprocess
import sys


def main():
    binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    reference = '--reference' in sys.argv[3:]
    prefix = [binary] + ([] if reference else ['run'])
    child = subprocess.run(prefix + [str(Path(scripts) / 'bun_function_mocks.mjs')], capture_output=True, timeout=60)
    assert child.returncode == 0 and child.stderr == b'', (child.returncode, child.stdout, child.stderr)
    lines = child.stdout.decode().splitlines()
    assert len(lines) == 1 and lines[0].startswith('FUNCTION MOCK RESULTS '), lines
    assert json.loads(lines[0].removeprefix('FUNCTION MOCK RESULTS ')) == {'groups': 30, 'passed': 30, 'failures': []}, lines
    print(lines[0])
    if not reference:
        child = subprocess.run(prefix + [str(Path(scripts) / 'function_mocks_profile.mjs')], capture_output=True, timeout=30)
        expected = b'HOME FUNCTION MOCK PROFILE REAL INVOCATION TRACES; TEST SCHEDULING AND MODULE MOCKING ABSENT\n'
        assert child.returncode == 0 and child.stderr == b'' and child.stdout == expected, (child.returncode, child.stdout, child.stderr)
        print(child.stdout.decode(), end='')


if __name__ == '__main__':
    main()
