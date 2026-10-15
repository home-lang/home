#!/usr/bin/env python3
"""Compare member assignment flow, resets and invalidation against TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = {
 'this-nullish': ('class C { state:string|null=null; make():string{return "ok";} run(state?:string):void {this.state=state??this.make();const good:string=this.state;} }', 0),
 'object': ('function f(obj:{value:string|null},value:string):void {obj.value=value;const good:string=obj.value;}', 0),
 'computed': ('function f(obj:{value:string|null},value:string):void {obj["value"]=value;const good:string=obj.value;}', 0),
 'reset': ('function f(obj:{value:string|null}):void {obj.value="ok";obj.value=null;const wrong:string=obj.value;}', 1),
 'branch': ('function f(obj:{value:string|null},flag:boolean):void {if(flag){obj.value="ok";}const wrong:string=obj.value;}', 1),
 'function-boundary': ('class C {value:string|null=null;one():void{this.value="ok";}two():void{const wrong:string=this.value;}}', 1),
 'widen': ('function f(obj:{value:string}):void {obj.value="ok";const wrong:"ok"=obj.value;}', 1),
 'rejected': ('function f(obj:{value:string|null}):void {obj.value=123;const wrong:string=obj.value;}', 2),
 'parent-reset': ('function f(obj:{inner:{value:string|null}}):void {obj.inner.value="ok";obj.inner={value:null};const wrong:string=obj.inner.value;}', 1),
 'root-reset': ('function f(obj:{value:string|null}):void {obj.value="ok";obj={value:null};const wrong:string=obj.value;}', 1),
 'literal-union': ('function f(obj:{value:"a"|"b"}):void {obj.value="a";const good:"a"=obj.value;const wrong:"b"=obj.value;}', 1),
 'loop': ('function f(obj:{value:string|null},flag:boolean):void {while(flag){obj.value="ok";}const wrong:string=obj.value;}', 1),
 'closure': ('function f(obj:{value:string|null}):void {obj.value="ok";function later():void {const wrong:string=obj.value;}}', 1),
 'url': ('interface Config{clientId:string;redirectUri:string;parameters?:Record<string,string>} class C {config:Config;state:string|null=null;constructor(config:Config){this.config=config;}make():string{return "ok";}run(state?:string):void{this.state=state??this.make();const params=new URLSearchParams({client_id:this.config.clientId,redirect_uri:this.config.redirectUri,state:this.state,...this.config.parameters});}}', 0),
}

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home',type=Path,required=True)
    parser.add_argument('--reference',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    root=args.output.resolve();root.mkdir(parents=True,exist_ok=False)
    reference=args.reference.resolve();package=reference.parent.parent
    if not (package/'package.json').is_file():
        raise SystemExit('Reference must be the installed typescript/bin/tsc entry point')
    compilers={'reference':reference,'home':args.home.resolve()}
    report={'compiler_hashes':{n:digest(p) for n,p in compilers.items()},'observations':[],'failures':[],'passed':False}
    for name,(source,count) in CASES.items():
        observations=[]
        for engine,exe in compilers.items():
            d=root/name/engine;d.mkdir(parents=True)
            (d/'node_modules').mkdir();(d/'node_modules/typescript').symlink_to(package,target_is_directory=True)
            (d/'main.ts').write_text(source+'\n')
            (d/'tsconfig.json').write_text(json.dumps({'compilerOptions':{'strict':True,'noEmit':True,'skipLibCheck':True,'target':'ESNext','module':'ESNext','moduleResolution':'Bundler','types':[]},'files':['main.ts']},indent=2)+'\n')
            inputs={p.name:digest(p) for p in d.iterdir() if p.is_file()}
            x=subprocess.run([str(exe),'--project','tsconfig.json','--pretty','false'],cwd=d,capture_output=True,text=True,timeout=45)
            output=x.stdout+x.stderr
            diagnostics=[(Path(p).name,int(l),int(c),int(code)) for p,l,c,code in re.findall(r'([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):',output)]
            row={'case':name,'engine':engine,'exit':x.returncode,'diagnostics':diagnostics,'stdout':x.stdout,'stderr':x.stderr,'input_hashes':inputs,'unchanged':inputs=={p.name:digest(p) for p in d.iterdir() if p.is_file()}}
            observations.append(row);report['observations'].append(row)
        passed=(all(row['unchanged'] and row['exit']==int(count>0) and len(row['diagnostics'])==count and all(d[3]==2322 for d in row['diagnostics']) for row in observations) and observations[0]['diagnostics']==observations[1]['diagnostics'])
        if not passed:report['failures'].append(name)
        (root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    report['passed']=not report['failures'];(root/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:raise SystemExit('Failed: '+', '.join(report['failures']))
    print(f"All {len(report['observations'])} member write observations passed")

if __name__=='__main__':main()
