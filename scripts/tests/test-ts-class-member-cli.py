#!/usr/bin/env python3
"""Compare imported generic methods beside inferred fields with installed TypeScript."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    reference = args.reference.resolve()
    package = reference.parent.parent
    if not (package / 'package.json').is_file():
        raise SystemExit('Reference must be the installed typescript/bin/tsc entry point')
    compilers = {'reference': reference, 'home': args.home.resolve()}
    summary = {'compiler_hashes': {n: digest(p) for n, p in compilers.items()},
               'observations': [], 'failures': [], 'passed': False}
    for field in ('data', '#data'):
        for route in ('direct', 'barrel'):
            for variant in ('valid', 'result', 'argument'):
                case = root / ('private' if field.startswith('#') else 'public') / route / variant
                case.mkdir(parents=True)
                (case / 'node_modules').mkdir()
                (case / 'node_modules/typescript').symlink_to(package, target_is_directory=True)
                files = {
                    'types.ts': 'export interface Result<R> { hits: R[] } export interface Request { index: string }\n',
                    'driver.ts': 'import type {Result,Request} from "./types"; export class Driver<R> {'
                        f'readonly {field} = new Map<string,R[]>(); '
                        'async search(request: Request): Promise<Result<R>> { return {hits: [] as R[]}; }}\n',
                    'index.ts': 'export {Driver} from "./driver";\n',
                }
                source = ('import {Driver} from "./' + ('driver' if route == 'direct' else 'index') + '";\n'
                          'const driver = new Driver<{id:number}>();\n'
                          'async function run() {\n'
                          '  const result = await driver.search({index:"products"});\n'
                          '  result.hits.map(row => { const id: number = row.id; return id; });\n'
                          '}\n')
                if variant == 'result':
                    source = source.replace('const id: number', 'const id: string')
                if variant == 'argument':
                    source = source.replace('index:"products"', 'index:42')
                files['main.ts'] = source
                for name, text in files.items():
                    (case / name).write_text(text)
                (case / 'tsconfig.json').write_text(json.dumps({'compilerOptions': {
                    'strict': True, 'noEmit': True, 'skipLibCheck': True, 'target': 'ESNext',
                    'module': 'ESNext', 'moduleResolution': 'Bundler', 'types': [], 'lib': ['ESNext', 'DOM'],
                }, 'files': list(files)}, indent=2) + '\n')
                inputs = {p.name: digest(p) for p in case.iterdir() if p.is_file()}
                observations = []
                for engine, exe in compilers.items():
                    run = subprocess.run([str(exe), '--project', 'tsconfig.json', '--pretty', 'false'],
                                         cwd=case, capture_output=True, text=True, timeout=90)
                    output = run.stdout + run.stderr
                    diagnostics = re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):', output)
                    row = {'case': str(case.relative_to(root)), 'engine': engine, 'exit': run.returncode,
                           'diagnostics': diagnostics, 'stdout': run.stdout, 'stderr': run.stderr,
                           'input_hashes': inputs}
                    observations.append(row)
                    summary['observations'].append(row)
                expected = int(variant != 'valid')
                passed = (all(row['exit'] == expected for row in observations)
                          and observations[0]['diagnostics'] == observations[1]['diagnostics']
                          and len(observations[0]['diagnostics']) == expected
                          and all(d[3] == '2322' for d in observations[0]['diagnostics'])
                          and inputs == {p.name: digest(p) for p in case.iterdir() if p.is_file()})
                if not passed:
                    summary['failures'].append(str(case.relative_to(root)))
                (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    summary['passed'] = not summary['failures']
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    if not summary['passed']:
        raise SystemExit('Failed: ' + ', '.join(summary['failures']))
    print(f"All {len(summary['observations'])} class member observations passed")


if __name__ == '__main__':
    main()
