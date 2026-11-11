"""Verify real shell IO, descriptor inheritance, refusals and physical output."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile


def main():
    binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    flags = sys.argv[3:]
    prefix = [binary] + ([] if '--node' in flags else ['run']) + [script]
    with tempfile.TemporaryDirectory(prefix='home-shell-') as directory:
        root = Path(directory)
        (root / 'cwd ☃').mkdir()
        result = subprocess.run(prefix + ['contract', directory], capture_output=True, timeout=90)
        assert result.returncode == 0, result.stdout + result.stderr
        lines = result.stdout.decode().splitlines()
        assert len(lines) == 2 and lines[1] == 'NODE EXEC SHELL 16 CHECKS OK', lines
        assert json.loads(lines[0].removeprefix('NODE EXEC SHELL RESULTS ')) == {'checks': 16, 'passed': 16, 'failures': []}
        assert result.stderr == b'', result.stderr
        assert (root / 'shell result.bin').read_bytes() == b'\0\xffphysical'
        mirrored = subprocess.run(prefix + ['mirror', directory], capture_output=True, timeout=30)
        assert mirrored.returncode == 0 and mirrored.stdout == b'DEFAULT SHELL STDOUT 61637475616c\n', mirrored.stdout + mirrored.stderr
        assert mirrored.stderr == b'\0\xffdiagnostic', mirrored.stderr
        inherited = subprocess.run(prefix + ['inherit', directory], capture_output=True, timeout=30)
        assert inherited.returncode == 0 and inherited.stdout == b'inherited INHERITED SHELL NULL VERIFIED\n', inherited.stdout + inherited.stderr
        assert inherited.stderr == b'native-stderr', inherited.stderr
        # A captured/replayed implementation sees pipes in the shell and fails
        # this regular-file descriptor witness even if the final bytes match.
        with (root / 'stdout').open('wb') as out, (root / 'stderr').open('wb') as err:
            direct = subprocess.run(prefix + ['inherit-file', directory], stdout=out, stderr=err, timeout=30)
        assert direct.returncode == 0
        assert (root / 'stdout').read_bytes() == b'descriptor-file'
        assert (root / 'stderr').read_bytes() == b'file-stderr'
        print(result.stdout.decode(), end='')
        print('NATIVE SHELL RAW STDERR, INHERITED DESCRIPTORS AND PHYSICAL FILE VERIFIED')
        if '--reference' not in flags:
            refused = subprocess.run(prefix + ['unsupported', directory], capture_output=True, timeout=30)
            assert refused.returncode == 0 and refused.stdout == b'HOME EXEC SHELL 8 REFUSALS OK\n' and refused.stderr == b'', refused.stdout + refused.stderr
            assert not (root / 'unsupported-ran').exists()
            print(refused.stdout.decode(), end='')


if __name__ == '__main__':
    main()
