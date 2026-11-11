"""Verify captured pipes, real binary stderr forwarding, and explicit refusals."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile


def main():
    binary, contract, mirror, unsupported, helper = [str(Path(p).resolve()) for p in sys.argv[1:6]]
    with tempfile.TemporaryDirectory(prefix='home-exec-capture-') as directory:
        root = Path(directory)
        (root / 'cwd ☃').mkdir()
        result = subprocess.run([binary, 'run', contract, sys.executable, helper, str(root)], capture_output=True, timeout=90)
        assert result.returncode == 0, result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace')
        lines = result.stdout.decode().splitlines()
        assert len(lines) == 2 and lines[1] == 'NODE EXEC CAPTURE 14 CHECKS OK', lines
        assert json.loads(lines[0].removeprefix('NODE EXEC CAPTURE RESULTS ')) == {'checks': 14, 'passed': 14, 'failures': []}
        assert result.stderr == b'', result.stderr
        forwarded = subprocess.run([binary, 'run', mirror, sys.executable, helper], capture_output=True, timeout=30)
        assert forwarded.returncode == 0 and forwarded.stdout == b'DEFAULT CAPTURE STDOUT 61637475616c\n', forwarded.stdout + forwarded.stderr
        assert forwarded.stderr == b'\0\xffdiagnostic', forwarded.stderr
        refused = subprocess.run([binary, 'run', unsupported, sys.executable, helper, str(root)], capture_output=True, timeout=30)
        assert refused.returncode == 0 and refused.stdout == b'HOME EXEC CAPTURE 10 REFUSALS OK\n' and refused.stderr == b'', refused.stdout + refused.stderr
        assert not (root / 'bad').exists() and not (root / 'unsupported-ran').exists()
        print(result.stdout.decode(), end='')
        print('NATIVE CAPTURE RAW STDERR FORWARDING VERIFIED')
        print(refused.stdout.decode(), end='')


if __name__ == '__main__':
    main()
