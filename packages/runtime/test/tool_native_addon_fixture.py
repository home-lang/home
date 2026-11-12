"""Reject native formats without pretending any native addon body executed."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile


def main():
    binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    reference = '--reference' in sys.argv[3:]
    with tempfile.TemporaryDirectory(prefix='home-native-format-') as directory:
        root = Path(directory).resolve()
        text = 'globalThis.__addonSourceExecuted++;module.exports={loaded:true};\n'
        (root / 'entry.cjs').write_bytes(Path(script).read_bytes())
        (root / 'text.node').write_text(text)
        (root / 'binary.node').write_bytes(b'\x7fELF\x00\x01\x02not-a-valid-addon\x00')
        (root / 'alias.js').symlink_to(root / 'text.node')
        (root / 'indexpkg').mkdir()
        (root / 'indexpkg/index.node').write_text(text)
        (root / 'mainpkg').mkdir()
        (root / 'mainpkg/package.json').write_text('{"main":"binding.node"}')
        (root / 'mainpkg/binding.node').write_text(text)
        package = root / 'node_modules/addon-pkg'
        package.mkdir(parents=True)
        (package / 'package.json').write_text('{"name":"addon-pkg","exports":"./binding.node"}')
        (package / 'binding.node').write_text(text)
        (root / 'static.mjs').write_text('import "./text.node";globalThis.__staticAddonBody=true;')
        (root / 'control.js').write_text('globalThis.__sourceControlExecuted++;module.exports=41;')
        (root / 'control.json').write_text('{"answer":42}')
        prefix = [binary] + ([] if reference else ['run'])
        command = prefix + [str(root / 'entry.cjs'), 'reference' if reference else 'home']
        child = subprocess.run(command, cwd=root, capture_output=True, timeout=60)
        print(child.stdout.decode(), end='')
        if child.returncode:
            print(child.stderr.decode(), file=sys.stderr, end='')
        assert child.returncode == 0, (child.returncode, child.stdout, child.stderr)
        print('NATIVE ADDON REFUSAL STDERR ' + json.dumps(child.stderr.decode()))
        if reference and child.stderr:
            assert b'ExperimentalWarning: Importing addons is an experimental feature' in child.stderr, child.stderr
        else:
            assert child.stderr == b'', child.stderr
        lines = child.stdout.decode().splitlines()
        assert len(lines) == 1 and lines[0].startswith('NATIVE ADDON FORMAT RESULTS '), lines
        result = json.loads(lines[0].removeprefix('NATIVE ADDON FORMAT RESULTS '))
        assert result['resolved'] == result['refused'] == result['uncached'] == 8, result
        assert result['sourceBodiesExecuted'] == 0 and not result['staticBodyExecuted'], result
        assert result['sourceControls'], result
        assert result['outcomes'][0]['path'] == result['outcomes'][6]['path'] == str(root / 'text.node'), result
        print('NATIVE ADDONS REMAIN UNAVAILABLE; SOURCE EXECUTION AND FAKE CACHE ENTRIES REFUSED')


if __name__ == '__main__':
    main()
