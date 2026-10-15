#!/usr/bin/env python3
"""Compare public imported declaration types and retained semantic errors."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROUTES = {
    'direct': ('import type {Config} from "./types";', 'Config'),
    'renamed': ('import type {Config as Local} from "./types";', 'Local'),
    'barrel': ('import type {PublicConfig as Config} from "./barrel";', 'Config'),
    'default': ('import Config from "./types";', 'Config'),
    'namespace': ('import type * as Types from "./types";', 'Types.Config'),
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
    if not (package/'package.json').is_file():
        raise SystemExit('Reference must be the installed typescript/bin/tsc entry point')
    compilers = {'reference': reference, 'home': args.home.resolve()}
    report = {'compiler_hashes': {n:digest(p) for n,p in compilers.items()},
              'observations': [], 'failures': [], 'passed': False}
    for route,(statement,type_name) in ROUTES.items():
        for emit in (False, True):
            for negative in (False, True):
                observations = []
                for engine,exe in compilers.items():
                    d = root/route/str(emit)/str(negative)/engine
                    d.mkdir(parents=True)
                    (d/'node_modules').mkdir()
                    (d/'node_modules/typescript').symlink_to(package,target_is_directory=True)
                    (d/'types.ts').write_text('export interface Config { value: string }\nexport default Config;\n')
                    (d/'barrel.ts').write_text('export type {Config as PublicConfig} from "./types";\n')
                    source = (statement+'\n'
                        f'export class C {{ constructor(config: {type_name}) {{}} method(config: {type_name}): {type_name} {{ return config; }} }}\n'
                        f'export function use(config: {type_name}): {type_name} {{ return config; }}\n'
                        f'export interface Box {{ value: {type_name}; }}\n')
                    if negative:
                        source += f'const wrong: {type_name} = {{ value: 1 }};\n'
                    (d/'main.ts').write_text(source)
                    (d/'tsconfig.json').write_text(json.dumps({'compilerOptions': {
                        'strict':True,'declaration':True,'emitDeclarationOnly':emit,'noEmit':not emit,
                        'outDir':'out','target':'ESNext','module':'ESNext','moduleResolution':'Bundler',
                        'skipLibCheck':True,'types':[],
                    },'files':['main.ts','types.ts','barrel.ts']},indent=2)+'\n')
                    inputs = {p.name:digest(p) for p in d.iterdir() if p.is_file()}
                    x = subprocess.run([str(exe),'--project','tsconfig.json','--pretty','false'],cwd=d,capture_output=True,text=True,timeout=45)
                    output = x.stdout+x.stderr
                    diagnostics = [(Path(p).name,int(l),int(c),int(code)) for p,l,c,code in
                        re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):',output)]
                    declaration = d/'out/main.d.ts'
                    declaration_text = declaration.read_text() if declaration.is_file() else ''
                    row = {'route':route,'emit':emit,'negative':negative,'engine':engine,'exit':x.returncode,
                           'diagnostics':diagnostics,'stdout':x.stdout,'stderr':x.stderr,'input_hashes':inputs,
                           'inputs_unchanged':all(digest(d/n)==h for n,h in inputs.items()),
                           'declaration':declaration_text}
                    report['observations'].append(row)
                    observations.append(row)
                native,home = observations
                expected_count = int(negative)
                passed = (all(row['inputs_unchanged'] and len(row['diagnostics'])==expected_count and
                              all(diag[3]==2322 for diag in row['diagnostics']) and
                              (row['exit']!=0 if negative else row['exit']==0) for row in observations)
                          and native['diagnostics']==home['diagnostics'])
                if emit and not negative:
                    passed = passed and all(row['declaration'] and statement.replace('type ','').split(' from ')[-1].strip(';') in row['declaration'] for row in observations)
                if not passed:
                    report['failures'].append(f'{route}/{emit}/{negative}')
                (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    report['passed'] = not report['failures']
    (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:
        raise SystemExit('Failed: '+', '.join(report['failures']))
    print(f"All {len(report['observations'])} public import observations passed")

if __name__ == '__main__':
    main()
