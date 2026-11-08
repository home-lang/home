#!/usr/bin/env python3
"""Compare owning root-admission contracts against a native TypeScript compiler.

Run under scripts/run-bounded.pl. All fixtures and symlinks belong to the
provided isolated output directory. Full casing/inclusion parity is separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    globals_source = '\n'.join(f'interface {name} {{}}' for name in (
        'Array<T>', 'Boolean', 'CallableFunction', 'Function', 'IArguments',
        'NewableFunction', 'Number', 'Object', 'RegExp', 'String',
    )) + '\n'
    report = {
        'scope': 'Relative project roots, composite membership, explanation reasons, mixed separators and lexical reads. Full inclusion/casing and platform/SDK qualification are separate.',
        'binaries': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                     for name, path in [('home', args.home), ('reference', args.reference)]},
        'observations': [], 'comparisons': [], 'passed': False,
    }

    def dep_reasons(output: str) -> tuple[bool, bool]:
        block = []
        in_dep = False
        for line in output.splitlines():
            if line and not line[0].isspace():
                in_dep = line.replace('\\', '/').endswith('/src/dep.ts')
            elif in_dep:
                block.append(line.strip().replace('\\', '/'))
        root_reason = "Part of 'files' list in tsconfig.json" in block
        import_reason = any(line.startswith('Imported via "./dep" from file ')
                            and line.endswith("/src/index.ts'") for line in block)
        return root_reason, import_reason

    cases = [
        ('relative-composite', ['globals.d.ts', 'src/index.ts', 'src/dep.ts'], True, False, False, []),
        ('relative-composite-import-only', ['globals.d.ts', 'src/index.ts'], True, False, False, [6307]),
        ('relative-explain', ['globals.d.ts', 'src/index.ts', 'src/dep.ts'], False, True, False, []),
        ('mixed-separator-single', ['globals.d.ts', 'src\\index.ts', 'src/dep.ts'], False, False, False, []),
        ('mixed-separator-duplicate', ['globals.d.ts', 'src\\index.ts', './src/index.ts', 'src/dep.ts'], False, False, True, []),
        ('lexical-parent-through-symlink', ['globals.d.ts', 'link/../index.ts'], False, False, False, []),
    ]
    try:
        for name, files, composite, explain, list_only, codes in cases:
            rows = []
            for engine, executable in [('reference', args.reference), ('home', args.home)]:
                directory = root / name / engine
                project = directory / 'project'
                (project / 'src').mkdir(parents=True)
                (project / 'globals.d.ts').write_text(globals_source)
                (project / 'src/index.ts').write_text('import { value } from "./dep"; export const result: number = value;\n')
                (project / 'src/dep.ts').write_text('export const value: number = 1;\n')
                if name == 'lexical-parent-through-symlink':
                    (project / 'index.ts').write_text('export const value: number = 1;\n')
                    (directory / 'other/sub').mkdir(parents=True)
                    (directory / 'other/index.ts').write_text('export const value: number = "wrong";\n')
                    (project / 'link').symlink_to(directory / 'other/sub', target_is_directory=True)
                (project / 'tsconfig.json').write_text(json.dumps({'files': files, 'compilerOptions': {
                    'noLib': True, 'noEmit': True, 'target': 'ESNext', 'module': 'ESNext', 'composite': composite,
                }}) + '\n')
                command = [str(executable.resolve()), '-p', 'project/tsconfig.json', '--pretty', 'false']
                if name == 'lexical-parent-through-symlink':
                    command = [str(executable.resolve()), 'project/globals.d.ts', 'project/link/../index.ts',
                               '--noLib', '--noEmit', '--target', 'ESNext', '--module', 'ESNext', '--pretty', 'false']
                if explain:
                    command.append('--explainFiles')
                if list_only:
                    command.append('--listFilesOnly')
                original_inputs = {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in directory.rglob("*") if path.is_file()}
                result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=30)
                inputs_unchanged = all(hashlib.sha256((directory / name).read_bytes()).hexdigest() == value
                                       for name, value in original_inputs.items())
                assert inputs_unchanged, directory
                dep_root, dep_import = dep_reasons(result.stdout)
                fixture_prefix = str(directory).replace('\\', '/') + '/'
                unlisted = sorted(target.replace('\\', '/').removeprefix(fixture_prefix) for target in
                                  re.findall(r"error TS6307: File '([^']+)' is not listed within", result.stdout))
                row = dict(case=name, engine=engine, command=command, cwd=str(directory), exit=result.returncode,
                           unlistedFiles=unlisted, depRootReason=dep_root, depImportReason=dep_import,
                           inputHashes=original_inputs, inputsUnchanged=inputs_unchanged,
                           stdout=result.stdout, stderr=result.stderr, codes=sorted(int(x) for x in re.findall(r'error TS(\d+):', result.stdout)),
                           filesReasons=result.stdout.count("Part of 'files' list in tsconfig.json"),
                           normalized=result.stdout.replace(str(directory), '<fixture>'))
                report['observations'].append(row)
                rows.append(row)
            reference, home = rows
            assert reference['codes'] == codes and reference['stderr'] == '', reference
            assert reference['exit'] == (1 if codes else 0), reference
            if name == 'relative-composite-import-only':
                assert reference['unlistedFiles'] == ['project/src/dep.ts'], reference
            if explain:
                assert reference['filesReasons'] == 3, reference
                assert reference['depRootReason'] and reference['depImportReason'], reference
            if list_only:
                assert len(reference['stdout'].splitlines()) == 3, reference
            parity = (
                home['codes'] == reference['codes']
                and home['exit'] == reference['exit']
                and home['stderr'] == reference['stderr']
                and home['unlistedFiles'] == reference['unlistedFiles']
                and (not explain or (home['filesReasons'] == reference['filesReasons']
                                     and home['depRootReason'] == reference['depRootReason']
                                     and home['depImportReason'] == reference['depImportReason']))
                and (not list_only or home['normalized'] == reference['normalized'])
            )
            report['comparisons'].append(dict(case=name, parity=parity))
        assert report['binaries'] == {name: hashlib.sha256(path.read_bytes()).hexdigest()
                                      for name, path in [('home', args.home), ('reference', args.reference)]}
        report['passed'] = all(row['parity'] for row in report['comparisons'])
    finally:
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'passed': report['passed'], 'comparisons': report['comparisons']}))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == "__main__":
    main()
