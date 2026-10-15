#!/usr/bin/env python3
"""Compare isolated-declaration parameter defaults with installed TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = {
    'trailing': 'export function f(p:number=1):void {}',
    'leading': 'export function f(p:number=1,q:number):void {}',
    'explicit-undefined': 'export function f(p:number|undefined=1,q:number):void {}',
    'constructor': 'export class C { constructor(p:number=1){} }',
    'method': 'export class C { f(p:number=1):void {} }',
    'rest': 'export function f(p:number=1,...rest:string[]):void {}',
    'optional': 'export function f(p:number=1,q?:number):void {}',
    'generic': 'export function f<T>(value:T=undefined as T):void {}',
    'asserted-inferred': 'type T=number; export function f(p=(value=1 as T, required:number):void=>{}):void {}',
}

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
    summary = {'compiler_hashes': {n: digest(p) for n,p in compilers.items()},
               'observations': [], 'failures': [], 'passed': False}
    for name, source in CASES.items():
        for strict in (False, True):
            for emit in (False, True):
                observations = []
                for engine, exe in compilers.items():
                    case = root / name / str(strict) / str(emit) / engine
                    case.mkdir(parents=True)
                    (case / 'node_modules').mkdir()
                    (case / 'node_modules/typescript').symlink_to(package, target_is_directory=True)
                    (case / 'main.ts').write_text(source + '\n')
                    (case / 'tsconfig.json').write_text(json.dumps({'compilerOptions': {
                        'strict': strict, 'declaration': True, 'isolatedDeclarations': True,
                        'noEmit': not emit, 'outDir': 'out', 'target': 'ESNext',
                        'module': 'ESNext', 'types': [], 'skipLibCheck': True,
                    }, 'files': ['main.ts']}, indent=2) + '\n')
                    inputs = {n: digest(case/n) for n in ['main.ts','tsconfig.json']}
                    result = subprocess.run([str(exe),'--project','tsconfig.json','--pretty','false'],
                                            cwd=case,capture_output=True,text=True,timeout=45)
                    output = result.stdout + result.stderr
                    diagnostics = re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):',output)
                    diagnostics = [(Path(p).name,int(l),int(c),int(code)) for p,l,c,code in diagnostics]
                    row = {'case': name,'strict': strict,'emit': emit,'engine': engine,
                           'exit': result.returncode,'diagnostics': diagnostics,
                           'stdout': result.stdout,'stderr': result.stderr,'input_hashes': inputs,
                           'inputs_unchanged': inputs == {n: digest(case/n) for n in inputs}}
                    observations.append(row)
                    summary['observations'].append(row)
                expected = [('main.ts',1,37,9025)] if name == 'asserted-inferred' and strict else []
                # Diagnostic-bearing declaration emit has separate exit-status gaps.
                passed = all(row['inputs_unchanged'] and row['diagnostics'] == expected and
                             (row['exit'] != 0 if expected else row['exit'] == 0) for row in observations)
                if not passed:
                    summary['failures'].append(f'{name}/{strict}/{emit}')
                (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    summary['passed'] = not summary['failures']
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    if not summary['passed']:
        raise SystemExit('Failed: '+', '.join(summary['failures']))
    print(f"All {len(summary['observations'])} parameter default observations passed")

if __name__ == '__main__':
    main()
