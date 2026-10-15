#!/usr/bin/env python3
"""Compare source-owned global generic bindings with installed TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = {
    'array': ({'main.ts': 'const values=Array.from([1,2]);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'typed-array': ({'main.ts': 'declare const bytes:Uint8Array;const values=Array.from(bytes);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'arraylike': ({'main.ts': 'declare const input:ArrayLike<number>;const values=Array.from(input);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'iterable': ({'main.ts': 'declare const input:Iterable<number>;const values=Array.from(input);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'explicit': ({'main.ts': 'declare const bytes:Uint8Array;const values=Array.from<number>(bytes);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'mapper': ({'main.ts': 'declare const bytes:Uint8Array;const values=Array.from(bytes,(v,k)=>v.toString(k));const good:string=values[0];const wrong:number=values[0];'}, [2322]),
    'hex': ({'main.ts': 'function hex(bytes:Uint8Array):string{return Array.from(bytes).map(b=>b.toString(16).padStart(2,"0")).join("");}'}, []),
    'function': ({'main.ts': 'declare function from<T>(value:ArrayLike<T>):T[];declare const bytes:Uint8Array;const values=from(bytes);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'method': ({'main.ts': 'interface Maker{from<T>(value:ArrayLike<T>):T[];}declare const maker:Maker;declare const bytes:Uint8Array;const values=maker.from(bytes);const good:number=values[0];const wrong:string=values[0];'}, [2322]),
    'default': ({'owner.d.ts': 'interface Box<T extends string="default">{value:T;}', 'main.ts': 'export {};declare const box:Box;const exact:"default"=box.value;const wrong:number=box.value;type Invalid=Box<number>;'}, [2322,2344]),
    'alias': ({'owner.d.ts': 'type Wrapped<T=number>={item:T};', 'main.ts': 'export {};declare const wrapped:Wrapped;const good:number=wrapped.item;const wrong:string=wrapped.item;'}, [2322]),
    'dependent': ({'owner.d.ts': 'interface Pair<T,U=T>{first:T;second:U;}', 'main.ts': 'export {};declare const pair:Pair<string>;const good:string=pair.second;const wrong:number=pair.second;'}, [2322]),
    'merged': ({'first.d.ts': 'interface Box<T>{first:T;}', 'second.d.ts': 'interface Box<T>{second:T;}', 'main.ts': 'export {};declare const box:Box<number>;const first:number=box.first;const second:number=box.second;const wrong:string=box.second;'}, [2322]),
    'merged-default-first': ({'first.d.ts': 'interface Box<T=string>{first:T;}', 'second.d.ts': 'interface Box<T>{second:T;}', 'main.ts': 'export {};declare const box:Box;const first:string=box.first;const second:string=box.second;const wrong:number=box.second;'}, [2322]),
    'merged-default-later': ({'first.d.ts': 'interface Box<T>{first:T;}', 'second.d.ts': 'interface Box<T=string>{second:T;}', 'main.ts': 'export {};declare const box:Box;const first:string=box.first;const second:string=box.second;const wrong:number=box.second;'}, [2322]),
    'local-shadow': ({'owner.d.ts': 'interface Box<T=string>{value:T;}', 'main.ts': 'export {};interface Box{value:boolean;}declare const box:Box;const good:boolean=box.value;const wrong:string=box.value;'}, [2322]),
    'nested-shadow': ({'owner.d.ts': 'interface Box<T=string>{value:T;}', 'main.ts': 'export {};function f(){interface Box{value:boolean;}const box={} as Box;const good:boolean=box.value;const wrong:string=box.value;}'}, [2322]),
    'owner-shadow': ({'owner.ts': 'interface Box<T>{value:T;}function local(){interface Box<U>{other:U;}const box:Box<boolean>={other:true};}', 'main.ts': 'export {};declare const box:Box<string>;const good:string=box.value;const wrong:number=box.value;'}, [2322]),
    'class-default': ({'owner.d.ts': 'declare class Box<T=string>{value:T;}', 'main.ts': 'export {};declare const box:Box;const good:string=box.value;const wrong:number=box.value;'}, [2322]),
    'alias-owner-shadow': ({'owner.ts': 'type Box<T>={value:T};function local(){type Box<U>={other:U};const box:Box<boolean>={other:true};}', 'main.ts': 'export {};declare const box:Box<string>;const good:string=box.value;const wrong:number=box.value;'}, [2322]),
    'merged-dependent-default': ({'first.d.ts': 'interface Box<T,U>{first:T;second:U;}', 'second.d.ts': 'interface Box<T,U=T>{extra:U;}', 'main.ts': 'export {};declare const box:Box<string>;const first:string=box.first;const second:string=box.second;const extra:string=box.extra;const wrong:number=box.extra;'}, [2322]),
    'forward-nested-shadow': ({'owner.d.ts': 'interface Box<T=string>{value:T;}', 'main.ts': 'export {};declare const outer:Box;const exact:string=outer.value;function f(){const box:Box={value:true};const good:boolean=box.value;const wrong:string=box.value;interface Box{value:boolean;}}'}, [2322]),
    'skipped-declaration-constraints': ({'owner.d.ts': 'interface Box<T extends string>{value:T;}declare const invalid:Box<number>;', 'main.ts': 'export {};const good:number=invalid.value;const wrong:string=invalid.value;'}, [2322]),
    'checked-declaration-constraints': ({'owner.d.ts': 'interface Box<T extends string>{value:T;}declare const invalid:Box<number>;', 'main.ts': 'export {};const good:number=invalid.value;const wrong:string=invalid.value;'}, [2322,2344]),
    'entries-empty': ({'main.ts':'const entries=Object.entries({});const good:string=entries[0][0];'}, []),
    'entries-optional': ({'main.ts':'declare const values:Record<string,string>|undefined;const entries=Object.entries(values??{});const good:string=entries[0][0];'}, []),
    'entries-record': ({'main.ts':'declare const values:Record<string,string>;const entries=Object.entries(values);const good:string=entries[0][1];const wrong:number=entries[0][1];'}, [2322]),
    'index-union-negative': ({'main.ts':'declare function take(value:Record<string,string>|ArrayLike<string>):void;const bad={flag:true};take(bad);'}, [2345]),
    'nongeneric': ({'owner.d.ts': 'interface Plain{value:number;}', 'main.ts': 'export {};type Invalid=Plain<string>;'}, [2315]),
    'arity': ({'owner.d.ts': 'interface Box<T>{value:T;}', 'main.ts': 'export {};type Missing=Box;type Excess=Box<string,number>;'}, [2314,2314]),
}

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('home','reference','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--bun-node-modules',type=Path,help='Installed node_modules containing bun-types and its dependencies')
    args=parser.parse_args()
    if args.bun_node_modules:
        if not (args.bun_node_modules/'bun-types/package.json').is_file():raise SystemExit('bun-types is missing from --bun-node-modules')
        CASES['bun-namespace']=({'main.ts':'export {};const good:number=1;'},[])
        CASES['bun-namespace-negative']=({'main.ts':'export {};const wrong:number="bad";'},[2322])
    root=args.output.resolve();root.mkdir(parents=True,exist_ok=False)
    reference=args.reference.resolve();package=reference.parent.parent
    if not (package/'package.json').is_file():
        raise SystemExit('Reference must be installed typescript/bin/tsc')
    compilers={'reference':reference,'home':args.home.resolve()}
    report={'compiler_hashes':{name:digest(exe) for name,exe in compilers.items()},'observations':[],'failures':[],'passed':False}
    for name,(files,expected) in CASES.items():
        rows=[]
        declaration_control=name.endswith('declaration-constraints')
        if declaration_control:
            files={'globals.d.ts':'\n'.join(f'interface {name} {{}}' for name in ('Array<T>','Boolean','CallableFunction','Function','IArguments','NewableFunction','Number','Object','RegExp','String'))+'\n',**files}
        for engine,exe in compilers.items():
            d=root/name/engine;d.mkdir(parents=True)
            if name.startswith('bun-namespace'):(d/'node_modules').symlink_to(args.bun_node_modules.resolve(),target_is_directory=True)
            else:
                (d/'node_modules').mkdir();(d/'node_modules/typescript').symlink_to(package,target_is_directory=True)
            for file,source in files.items():(d/file).write_text(source+'\n')
            options={'strict':True,'noEmit':True,'skipLibCheck':not name.startswith('checked-declaration-'),'types':[],'target':'ESNext','module':'ESNext','moduleResolution':'Bundler'}
            if declaration_control:options['noLib']=True
            elif name.startswith('bun-namespace'):options.update(types=['bun'],lib=['ESNext','DOM'])
            else:options['lib']=['ESNext']
            (d/'tsconfig.json').write_text(json.dumps({'compilerOptions':options,'files':list(files)},indent=2)+'\n')
            inputs={p.name:digest(p) for p in d.iterdir() if p.is_file()}
            library_hashes={}
            if name.startswith('bun-namespace'):
                graph=subprocess.run([str(reference),'--project','tsconfig.json','--listFilesOnly','--pretty','false'],cwd=d,capture_output=True,text=True,timeout=120)
                if graph.returncode:raise SystemExit(graph.stdout+graph.stderr)
                library_hashes={str((d/line).resolve()):digest((d/line).resolve()) for line in graph.stdout.splitlines() if (d/line).is_file()}
            x=subprocess.run([str(exe),'--project','tsconfig.json','--pretty','false'],cwd=d,capture_output=True,text=True,timeout=120 if name.startswith('bun-namespace') else 45)
            output=x.stdout+x.stderr
            diagnostics=sorted((Path(p).name,int(l),int(c),int(code)) for p,l,c,code in re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):',output))
            row={'case':name,'engine':engine,'exit':x.returncode,'diagnostics':diagnostics,'stdout':x.stdout,'stderr':x.stderr,'input_hashes':inputs,'library_hashes':library_hashes,'unchanged':inputs=={p.name:digest(p) for p in d.iterdir() if p.is_file()} and all(digest(Path(p))==h for p,h in library_hashes.items())}
            rows.append(row);report['observations'].append(row)
        passed=(all(row['unchanged'] and row['exit']==int(bool(expected)) and sorted(d[3] for d in row['diagnostics'])==sorted(expected) and len(re.findall(r'error TS\d+:',row['stdout']+row['stderr']))==len(expected) for row in rows) and rows[0]['diagnostics']==rows[1]['diagnostics'])
        if not passed:report['failures'].append(name)
        (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    report['passed']=not report['failures'];(root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:raise SystemExit('Failed: '+', '.join(report['failures']))
    print(f"All {len(report['observations'])} global generic observations passed")

if __name__=='__main__':main()
