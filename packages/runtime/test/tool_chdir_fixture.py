"""Observe real cwd in relative filesystem access and a child shell."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile


def main():
    binary, contract, profile = map(lambda p: str(Path(p).resolve()), sys.argv[1:4])
    with tempfile.TemporaryDirectory(prefix='home-chdir-') as temporary:
        root = Path(temporary)
        nested = root / 'nested-☃'
        nested.mkdir()
        (nested / 'read.txt').write_text('kernel-relative')
        (root / 'other' / 'deep').mkdir(parents=True)
        (root / 'link').symlink_to(root / 'other' / 'deep', target_is_directory=True)
        (root / 'loop').symlink_to(root / 'loop', target_is_directory=True)
        (root / 'not-directory').write_text('file')
        (root / 'process_chdir_anchor.cjs').write_text("module.exports = {marker:'wrong cwd'};")
        denied = root / 'denied'
        denied.mkdir()
        denied.chmod(0)
        try:
            result = subprocess.run([binary, 'run', contract, str(root)], capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr
        finally:
            denied.chmod(0o700)
        lines = result.stdout.splitlines()
        assert len(lines) == 2 and lines[1] == 'NODE PROCESS CHDIR 19 CHECKS OK', result.stdout
        ledger = json.loads(lines[0].removeprefix('NODE PROCESS CHDIR RESULTS '))
        assert ledger['checks'] == ledger['passed'] == len(ledger['labels']) == 19
        assert (nested / 'written.txt').read_text() == 'real relative write'
        assert Path((nested / 'child-cwd.txt').read_text().strip()) == nested.resolve()
        assert not (root / 'written.txt').exists()
        guarded = subprocess.run([binary, 'run', profile], capture_output=True, text=True, timeout=30)
        assert guarded.returncode == 0 and guarded.stdout == 'HOME PROCESS CHDIR 2 PATH GUARDS OK\n', guarded.stdout + guarded.stderr
        print(result.stdout, end='')
        print('HOST CHDIR RELATIVE FILE AND CHILD VERIFIED')
        print(guarded.stdout, end='')


if __name__ == '__main__':
    main()
