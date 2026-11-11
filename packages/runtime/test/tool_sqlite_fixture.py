"""Exercise real SQLite files using both Home and independent Python SQLite."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def checked(argv):
    run = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    if run.returncode:
        raise RuntimeError(run.stdout + run.stderr)
    return run.stdout


def main():
    with tempfile.TemporaryDirectory(prefix='home-native-sqlite-') as directory:
        database = Path(directory) / 'actual.sqlite'
        output = checked([sys.argv[1], 'run', sys.argv[2], str(database)])
        lines = output.splitlines()
        assert len(lines) == 2 and lines[0].startswith('BUN SQLITE CORE RESULTS '), output
        ledger = json.loads(lines[0].removeprefix('BUN SQLITE CORE RESULTS '))
        assert ledger == {'checks': 32, 'passed': 32, 'failures': []}, ledger
        assert lines[1] == 'BUN SQLITE CORE 32 CHECKS OK'
        with database.open('rb') as source:
            assert source.read(16) == b'SQLite format 3\0', 'not a native SQLite file'
        with sqlite3.connect(database) as independent:
            assert independent.execute('PRAGMA integrity_check').fetchone() == ('ok',)
            assert independent.execute('SELECT id,value,blob FROM persisted ORDER BY id').fetchall() == [
                (1, 'real SQLite 🌍', b'\0\1\xff'), (2, 'transaction', b'')]
            independent.execute('INSERT INTO persisted VALUES(?,?,?)', (3, 'written by independent sqlite3', b'\x10\x20'))
            independent.commit()
        observed = checked([sys.argv[1], 'run', sys.argv[3], str(database)])
        assert observed == 'SQLITE INDEPENDENT UPDATE OBSERVED\n', observed
        print(lines[0])
        print(lines[1])
        print('NATIVE SQLITE FILE AND INDEPENDENT ROUNDTRIP OK')


if __name__ == '__main__':
    main()
