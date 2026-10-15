#!/usr/bin/env python3
"""Compare imported base fields, visibility, and generic heritage with TypeScript."""
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
    if not (package/'package.json').is_file():
        raise SystemExit('Reference must be the installed typescript/bin/tsc entry point')
    compilers = {'reference':reference,'home':args.home.resolve()}
    report = {'compiler_hashes':{n:digest(p) for n,p in compilers.items()},
              'observations':[],'failures':[],'passed':False}
    for route in ('direct','renamed','barrel'):
        for generic in (False,True):
            for variant in ('valid','wrong-type','outside-protected'):
                observations=[]
                for engine,exe in compilers.items():
                    d=root/route/str(generic)/variant/engine
                    d.mkdir(parents=True)
                    (d/'node_modules').mkdir()
                    (d/'node_modules/typescript').symlink_to(package,target_is_directory=True)
                    (d/'types.ts').write_text('export interface Config { value: string }\n')
                    parameters='<T extends Config = Config>' if generic else ''
                    field_type='T' if generic else 'Config'
                    (d/'base.ts').write_text('import type {Config} from "./types";\n'
                        f'export abstract class Base{parameters} {{\n'
                        f'  protected config: {field_type};\n'
                        '  protected inferred = "x";\n'
                        f'  constructor(config: {field_type}) {{ this.config=config; }}\n'
                        '  abstract run(): string;\n}\n')
                    (d/'barrel.ts').write_text('export {Base} from "./base";\n')
                    local='Parent' if route=='renamed' else 'Base'
                    statement=('import {Base as Parent} from "./base";' if route=='renamed' else
                               'import {Base} from "./'+('barrel' if route=='barrel' else 'base')+'";')
                    expression='const wrong: number = this.config.value;' if variant=='wrong-type' else ''
                    source=(statement+'\n'
                        f'export class Derived extends {local} {{\n'
                        f'  run(): string {{ const good: string = this.config.value; {expression} return good; }}\n'
                        '}\n')
                    if variant=='outside-protected':
                        source+='new Derived({value:"ok"}).config;\n'
                    (d/'main.ts').write_text(source)
                    (d/'tsconfig.json').write_text(json.dumps({'compilerOptions':{
                        'strict':True,'noEmit':True,'declaration':True,'skipLibCheck':True,'types':[],
                        'target':'ESNext','module':'ESNext','moduleResolution':'Bundler',
                    },'files':['main.ts','base.ts','types.ts','barrel.ts']},indent=2)+'\n')
                    inputs={p.name:digest(p) for p in d.iterdir() if p.is_file()}
                    x=subprocess.run([str(exe),'--project','tsconfig.json','--pretty','false'],cwd=d,capture_output=True,text=True,timeout=45)
                    output=x.stdout+x.stderr
                    diagnostics=[(Path(p).name,int(l),int(c),int(code)) for p,l,c,code in
                        re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):',output)]
                    row={'route':route,'generic':generic,'variant':variant,'engine':engine,'exit':x.returncode,
                         'diagnostics':diagnostics,'stdout':x.stdout,'stderr':x.stderr,'input_hashes':inputs,
                         'unchanged':inputs=={p.name:digest(p) for p in d.iterdir() if p.is_file()}}
                    observations.append(row)
                    report['observations'].append(row)
                code={'valid':None,'wrong-type':2322,'outside-protected':2445}[variant]
                passed=(all(row['unchanged'] and row['exit']==int(code is not None) and
                            len(row['diagnostics'])==int(code is not None) and
                            all(diag[3]==code for diag in row['diagnostics']) for row in observations)
                        and observations[0]['diagnostics']==observations[1]['diagnostics'])
                if not passed:
                    report['failures'].append(f'{route}/{generic}/{variant}')
                (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    report['passed']=not report['failures']
    (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:
        raise SystemExit('Failed: '+', '.join(report['failures']))
    print(f"All {len(report['observations'])} inherited field observations passed")

if __name__ == '__main__':
    main()
