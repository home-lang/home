#!/usr/bin/env python3
"""Compare polymorphic this declaration boundaries with installed TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

prefix='interface Inner{inner:number;self():this}interface Outer{outer:number;nested:Inner}declare const outer:Outer;'
CASES={
 'nested-this':({'main.ts':prefix+'const result=outer.nested.self();const good:Inner=result;const wrong:string=result;'},[2322]),
 'indexed-nested-this':({'main.ts':prefix+'type Selected=Outer["nested"];declare const selected:Selected;const result=selected.self();const good:Inner=result;const wrong:string=result;'},[2322]),
 'direct-this':({'main.ts':'interface Base{base:number;self():this}interface Derived extends Base{extra:string}declare const derived:Derived;const result=derived.self();const good:Derived=result;const wrong:number=result.extra;'},[2322]),
 'nested-generic-this':({'main.ts':'interface Inner{inner:number;self<T>(value:T):this}interface Outer{outer:number;nested:Inner}declare const outer:Outer;const result=outer.nested.self(1);const good:Inner=result;const wrong:string=result;'},[2322]),
 'nested-this-parameter':({'main.ts':'interface Inner{inner:number;check(cb:(value:this)=>void):void}interface Outer{outer:number;nested:Inner}declare const outer:Outer;outer.nested.check(value=>{const good:Inner=value;const wrong:string=value;});'},[2322]),
 'imported-this':({'owner.ts':'export interface Inner{inner:number;self():this}export interface Outer{outer:number;nested:Inner}', 'main.ts':'import type {Inner,Outer} from "./owner";declare const outer:Outer;const result=outer.nested.self();const good:Inner=result;const wrong:string=result;'},[2322]),
 'nested-class-this':({'main.ts':'declare class Inner{inner:number;self():this}interface Outer{outer:number;nested:Inner}declare const outer:Outer;const result=outer.nested.self();const good:Inner=result;const wrong:string=result;'},[2322]),
 'same-type-read':({'main.ts':prefix+'declare function take(value:Inner):void;take(outer.nested);'},[]),
 'same-type-outer':({'main.ts':prefix+'declare function take(value:Outer):void;take(outer);'},[]),
}
CASES.update({
    'generic-boundary-argument': ({'main.ts':'interface Box<T>{value:T;self():this}interface Outer{outer:number;box:Box<this>}declare const outer:Outer;const value=outer.box.value;const good:Outer=value;const wrong:string=value;const box:Box<Outer>=outer.box.self();'}, [2322]),
    'alias-capture': ({'main.ts':'type Wrap<T>={value:T};interface Outer{outer:number;wrap():Wrap<this>}interface Derived extends Outer{extra:string}declare const outer:Derived;const value=outer.wrap().value;const good:Derived=value;const wrong:number=value.extra;'}, [2322]),
    'array-boundary': ({'main.ts':prefix+'interface Many{inners:Inner[]}declare const many:Many;const result=many.inners[0].self();const good:Inner=result;const wrong:string=result;'}, [2322]),
    'union-boundary': ({'main.ts':prefix+'interface Maybe{nested:Inner|null}declare const maybe:Maybe;const result=maybe.nested?.self();const good:Inner|undefined=result;const wrong:string=result;'}, [2322]),
    'class-field-boundary': ({'main.ts':prefix.replace('declare const outer:Outer;','')+'class Holder{value:Inner|null=null;set(value:Inner){this.value=value;}}'}, []),
    'class-method-boundary': ({'main.ts':prefix+'class Holder{take(value:Inner):void{} pass(value:Inner){this.take(value);}}'}, []),
})

CASES.update({
    'tuple-capture': ({'main.ts':'interface Outer{outer:number;copy():[this]}interface Derived extends Outer{extra:string}declare const outer:Derived;const value=outer.copy()[0];const good:Derived=value;const wrong:number=value.extra;'}, [2322]),
    'constraint-capture': ({'main.ts':'interface Outer{outer:number;take<T extends this>():T}declare const outer:Outer;const good:Outer=outer.take<Outer>();const wrong=outer.take<{other:boolean}>();'}, [2739]),
    'default-capture': ({'main.ts':'interface Outer{outer:number;get<T=this>():T}interface Derived extends Outer{extra:string}declare const outer:Derived;const result=outer.get();const good:Derived=result;const wrong:number=result.extra;'}, [2322,2339]),
    'callback-this-context': ({'main.ts':'interface Inner{inner:number;listen(callback:(this:this)=>void):void}declare const inner:Inner;inner.listen(function(){const good:Inner=this;const wrong:string=this;});'}, [2322]),
    'recursive-callback-positive': ({'main.ts':'interface Left{value:number;visit(cb:(value:Left)=>void):void}interface Right{value:number;visit(cb:(value:Right)=>void):void}declare const left:Left;const good:Right=left;'}, []),
    'recursive-callback-negative': ({'main.ts':'interface Left{value:string;visit(cb:(value:Left)=>void):void}interface Right{value:number;visit(cb:(value:Right)=>void):void}declare const left:Left;const wrong:Right=left;'}, [2322]),
})

CASES.update({
    'default-capture-with-parameter': ({'main.ts':'interface Base{base:number;get<T=this>(v:this):T}interface Derived extends Base{extra:string}declare const derived:Derived;const result=derived.get(derived);const good:Derived=result;const wrong:string=result;'}, [2322]),
    'derived-constraint-capture': ({'main.ts':'interface Base{base:number;take<T extends this>():T}interface Derived extends Base{extra:string}declare const derived:Derived;const result=derived.take<Base>();'}, [2741]),
    'primitive-constraint-capture': ({'main.ts':'interface Base{base:number;take<T extends this>():T}declare const base:Base;const result=base.take<string>();'}, [2344]),
    'merged-default-this': ({'main.ts':'interface Base{get<T=this>():T}interface Base{added:string}declare const base:Base;const result=base.get();const good:string=result.added;const wrong:number=result.added;'}, [2322]),
    'global-merged-default-this': ({'first.d.ts':'interface Base{get<T=this>():T}', 'second.d.ts':'interface Base{added:string}', 'main.ts':'export {};declare const base:Base;const result=base.get();const good:string=result.added;const wrong:number=result.added;'}, [2322]),
    'nested-interface-this': ({'main.ts':'class Outer{outer:number=1;method(){interface Inner{inner:number;self():this}const inner={} as Inner;const value=inner.self();const good:Inner=value;const wrong:string=value;}}'}, [2322]),
})

CASES.update({
    'intersection-receiver': ({'main.ts':'interface One{a:number;self():this}interface Two{b:number;me():this}function f(value:One&Two){const result=value.self().me();const a:number=result.a;const b:number=result.b;const wrong:string=result.a;}'}, [2322]),
    'fluent-intersection': ({'main.ts':'interface Component{extend<T>(props:T):this&T}interface Label extends Component{title:string}declare const label:Label;const result=label.extend({id:67}).extend({tag:"hello"});const id:number=result.id;const tag:string=result.tag;const wrong:boolean=result.id;'}, [2322]),
})

CASES['global-heritage-visibility'] = ({'globals.d.ts':'interface Base{base:number}', 'main.ts':'export {};interface Derived extends Base{extra:string}declare const value:Derived;const good:number=value.base;interface Invalid extends Missing{}'}, [2304])

CASES.update({
    'callback-data-negative': ({'main.ts':'interface Left{value:string;run(cb:(value:number)=>void):void}interface Right{value:number;run(cb:(value:number)=>void):void}declare const left:Left;const wrong:Right=left;'}, [2322]),
    'callback-index-negative': ({'main.ts':'interface Left{[n:number]:string;run(cb:(value:number)=>void):void}interface Right{[n:number]:number;run(cb:(value:number)=>void):void}declare const left:Left;const wrong:Right=left;'}, [2322]),
})

CASES['named-recursive-callback'] = ({'main.ts':'interface Inner{inner:number;check(cb:(value:Inner)=>void):void}declare const inner:Inner;inner.check(value=>{const good:Inner=value;const wrong:string=value;});'}, [2322])

CASES.update({
'generic-this-default':({'main.ts':'interface Box<T>{value:T;get<U=this>():U}declare const box:Box<number>;const out=box.get();const good:number=out.value;const wrong:string=out.value;'},[2322]),
'generic-derived-this-default':({'main.ts':'interface Box<T>{value:T;get<U=this>():U}interface Derived extends Box<number>{extra:string}declare const box:Derived;const out=box.get();const good:number=out.value;const wrong:string=out.value;const extra:string=out.extra;'},[2322]),
'generic-this-capture':({'main.ts':'interface Box<T>{value:T;get<U=this>(value:this):U}interface Derived extends Box<number>{extra:string}declare const box:Derived;const out=box.get(box);const good:number=out.value;const extra:string=out.extra;const wrong:string=out.value;'},[2322]),
})

CASES.update({
    'imported-generic-this-default': ({'owner.ts':'export interface Box<T>{value:T;get<U=this>():U}', 'main.ts':'import type {Box} from "./owner";interface Derived extends Box<number>{extra:string}declare const box:Derived;const out=box.get();const good:number=out.value;const extra:string=out.extra;const wrong:string=out.value;'}, [2322]),
    'global-generic-this-default': ({'globals.d.ts':'interface Box<T>{value:T;get<U=this>():U}', 'main.ts':'export {};interface Derived extends Box<number>{extra:string}declare const box:Derived;const out=box.get();const good:number=out.value;const extra:string=out.extra;const wrong:string=out.value;'}, [2322]),
    'phantom-generic-this-default': ({'main.ts':'interface Box<T>{get<U=this>():U}interface Derived extends Box<number>{extra:string}declare const box:Derived;const out=box.get();const good:string=out.extra;const wrong:number=out.extra;'}, [2322]),
})

CASES['visible-forward-callback-binder'] = ({'schemas.ts':'export interface Payload<T>{value:T}export type CheckFn<T>=(payload:Payload<T>)=>void;', 'api.ts':'import type * as schemas from "./schemas";export function use<T>(value:T):void{later<T>(payload=>{const exact:T=payload.value;const wrong:number=payload.value;void exact;void wrong;void value;});}export function later<O>(callback:schemas.CheckFn<O>):void{}'}, [2322])

CASES['global-alias-preserves-this-merge'] = ({'first.d.ts':'interface Base{get<T=this>():T}type Alias=Base;', 'second.d.ts':'interface Base{added:string}', 'main.ts':'export {};declare const base:Alias;const result=base.get();const good:string=result.added;const wrong:number=result.added;'}, [2322])

CASES.update({
    'transitive-global-alias-this': ({'first.d.ts':'interface Base{get<T=this>():T}type Middle=Base;type Alias=Middle;', 'second.d.ts':'interface Base{added:string}', 'main.ts':'export {};declare const base:Alias;const good:string=base.get().added;const wrong:number=base.get().added;'}, [2322]),
    'global-alias-parameter-shadow': ({'first.d.ts':'type Alias<Base>=Base;', 'second.d.ts':'interface Base{unrelated:string}', 'main.ts':'export {};declare const value:Alias<string>;const good:string=value;const wrong:number=value;'}, [2322]),
    'global-alias-module-local-owner': ({'first.d.ts':'export {};declare class Base{local:number}declare global{type Alias=Base}', 'second.d.ts':'interface Base{global:string}', 'main.ts':'export {};declare const value:Alias;const good:number=value.local;const wrong:string=value.local;value.global;'}, [2322,2339]),
})

cyclic_members=''.join(f'self{i}():this;' for i in range(16))
cyclic_values=','.join(f'self{i}:self' for i in range(16))
cyclic_prefix='interface Shape{'+cyclic_members+'}declare const self:()=>any;declare function take(value:Shape):void;'
CASES['cyclic-receiver-excess-positive']=({'main.ts':cyclic_prefix+'take({'+cyclic_values+'});'},[])
CASES['cyclic-receiver-excess-negative']=({'main.ts':cyclic_prefix+'take({'+cyclic_values+',extra:true});'},[2353])

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
        CASES.update({
            'bun-namespace-request-method-negative': ({'main.ts':'export {};class Audit{take(request:Request):void{} log(request:Request):void{this.take(request);this.take("bad");}}'}, [2345]),
            'bun-namespace-request-field-negative': ({'main.ts':'export {};class Guard{request:Request|null=null;setRequest(request:Request):void{this.request=request;this.request="bad";}}'}, [2322]),
            'bun-namespace-request-field': ({'main.ts':'export {};class Guard{request:Request|null=null;setRequest(request:Request):void{this.request=request;}}'}, []),
            'bun-namespace-request-method': ({'main.ts':'export {};class Audit{take(request:Request):void{} log(request:Request):void{this.take(request);}}'}, []),
            'bun-namespace-request-import': ({'owner.ts':'export function take(request:Request):void{}', 'main.ts':'import {take} from "./owner";declare const request:Request;take(request);'}, []),
            'bun-namespace-signal-read': ({'main.ts':'export {};declare const request:Request;const signal:AbortSignal=request.signal;'}, []),
        })
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
    print(f"All {len(report['observations'])} polymorphic this observations passed")

if __name__=='__main__':main()
