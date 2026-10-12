#!/usr/bin/env python3
"""Audit automatic-variable diagnostics against an installed TypeScript CLI.

Use scripts/run-bounded.pl. Every source/config is isolated. A mismatch, timeout,
changed input, or unexpected emitted file is a failed observation; partial results
are retained. This audit includes remaining compiler gaps and exits nonzero until
all cases match. It does not qualify other compiler options or real projects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

CASES = {
    "unused-let": "let x;",
    "unused-var": "var x;",
    "local-unused": "function f() { let x; }",
    "direct-read": "let x; x;",
    "assigned": "let x; x = 1; const n: number = x;",
    "bad-assigned": "let x; x = 1; const s: string = x;",
    "read-before-write": "let x; x; x=1;",
    "closure-read": "let x; function f() { return x; }",
    "closure-written": "let x; x=1; function f() { return x; }",
    "shadow-only": "let x; function f(x: string) { return x; }",
    "nested-shadow": "let x; function f() { let x = 1; return x; }",
    "property-name": "let x; const obj = { x: 1 }; obj.x;",
    "object-shorthand": "let x; const obj = { x };",
    "computed-key": "let x; const obj = { [x]: 1 };",
    "branch-write": "declare const flag: boolean; let x; if (flag) x = 1; const n: number = x;",
    "exported": "export let x;",
    "namespace-export": "namespace N { export let x; }",
    "ambient-let": "declare let x;",
    "ambient-var": "declare var x;",
    "ambient-local": "declare namespace N { let x; }",
    "const-missing": "const x;",
    "null-init": "let x = null;",
    "empty-array-unused": "let x=[];",
    "empty-array-read": "let x=[]; x;",
    "array-capture": "let x=[]; function f() { return x; }",
    "local-read": "function f() { let x; return x; }",
    "local-capture": "function f() { let x; function g() { return x; } }",
    "var-type-query": "let x; type X = typeof x;",
    "function-expression-shadow": "let x; const f = function x() { return x; };",
    "block-shadow": "let x; { let x = 1; x; }",
    "class-field-shadow": "let x; class C { x: number = 1; }",
    "class-capture": "let x; class C { m() { return x; } }",
    "write-only-capture": "let x; function f() { x = 1; }",
    "branch-direct-read": "declare const flag: boolean; let x; if (flag) x;",
    "loop-write": "let x; for(let i=0; i<2; i++) x = i;",
    "local-written-capture": "function f() { let x; x=1; function g() { return x; } }",
    "local-conditional-capture": "declare const b: boolean; function f() { let x; if(b) x=1; function g() { return x; } }",
    "class-field-capture": "let x; class C { value = x; }",
    "class-static-capture": "let x; class C { static value = x; }",
    "export-list": "let x; export { x };",
    "export-written": "export let x; x=1;",
    "namespace-local": "namespace N { let x; }",
    "local-no-write-negative": "function f() { let x; const n: number = x; }",
    "global-no-write-negative": "let x; const n: number = x;",
    "global-var-negative": "var x; const n: number = x;",
    "forward-capture": "function f() { return x; } let x;",
    "array-local-unused": "function f() { let x=[]; }",
    "array-local-read": "function f(){ let x=[]; return x; }",
    "array-const-read": "const x=[]; x;",
    "array-export-read": "export let x=[]; x;",
    "array-push-read": "let x=[]; x.push(1); const n:number=x[0];",
    "array-push-negative": "let x=[]; x.push(1); const s:string=x[0];",
    "array-push-branch": "declare const b:boolean; let x=[]; if(b) x.push(1); const s:string=x[0];",
    "array-index-write": "let x=[]; x[0]=1; const s:string=x[0];",
    "array-push-capture": "let x=[]; x.push(1); function f(){ return x; }",
    "array-local-push-capture": "function f(){ let x=[]; x.push(1); function g(){ return x; }}",
    "array-assign-read": "let x=[]; x=[1]; const s:string=x[0];",
    "array-assign-capture": "let x=[]; x=[1]; function f(){ return x; }",
    "array-shadow-parameter": "let x=[]; function f(x:number[]){ return x; }",
    "array-shadow-local": "let x=[]; function f(){ let x=[1]; return x; }",
    "array-shadow-block": "let x=[]; { let x=[1]; x; }",
    "array-function-name": "let x=[]; const f=function x(){ return x; };",
    "array-forward-shadow": "let x=[]; function f(){ x; let x=[1]; }",
    "array-length": "let x=[]; x.length;",
    "array-push-empty": "let x=[]; x.push(); x;",
    "array-local-type-query": "function f(){ let x=[]; type X=typeof x; }",
    "array-array-type-query": "let x=[]; type X=typeof x;",
    "array-control-local-let-arrow": "function f(){ let x=[]; x.push(1); const g=()=>x; }",
    "array-control-local-const-arrow": "function f(){ const x=[]; x.push(1); const g=()=>x; }",
    "array-control-local-arrow-later-write": "function f(){ let x=[]; const g=()=>x; x=[1]; }",
    "array-control-global-arrow": "let x=[]; x.push(1); const g=()=>x;",
    "array-control-instance-field": "let x=[]; x.push(1); class C { value=x; }",
    "array-control-static-field": "let x=[]; x.push(1); class C { static value=x; }",
    "array-control-loop-push-read": "let x=[]; for(let i=0;i<2;i++){ x.push(1); const s:string=x[0]; }",
    "array-control-loop-read-before-push": "let x=[]; for(let i=0;i<2;i++){ const s:string=x[0]; x.push(1); }",
    "array-control-mixed-push": "declare const b:boolean; let x=[]; if(b) x.push(1); else x.push(\"s\"); const n:boolean=x[0];",
    "array-control-manifest-push": "let x=[]; x=[1]; x.push(\"s\");",
    "array-control-reset-empty": "let x=[]; x.push(1); x=[]; x;",
    "array-control-false-branch": "let x=[]; if(false) x.push(1); x;",
    "array-control-export-push": "export let x=[]; x.push(1);",
    "array-control-const-local-read": "function f(){ const x=[]; return x; }",
    "array-control-indexed-string": "let x=[]; x[\"hello\"]=1; x;",
    "array-control-spread-mutation": "let x=[]; x.push(...[1,2]); const s:string=x[0];",
    "scoped-forward-lifetime": "let value=[];\nfunction inspect(){ value; let value=[1]; }\ntype Query=typeof later;\nlet later=1;\nclass Deferred { field=eventual; }\nlet eventual=1;",
    "array-object-pattern-shadow": "let x=[]; function f(){ const {x}={x:[1]}; const s:string=x[0]; }",
    "array-pattern-shadow": "let x=[]; function f(){ const [x]=[[1]]; const s:string=x[0]; }",
    "array-catch-shadow": "let x=[]; try {} catch(x) { x; }",
    "array-hoisted-block-write": "function f(){ { var x=[]; x.push(1); } const s:string=x[0]; }",
    "array-read-before-declaration": "const n:number=x; let x=[];",
    "array-rejected-scalar-write": "let x=[]; x=1; const n:number=x[0];"
}

GLOBALS = "\n".join(
    f"interface {name} {{}}"
    for name in ("Array<T>", "Boolean", "CallableFunction", "Function", "IArguments",
                 "NewableFunction", "Number", "Object", "RegExp", "String")
) + "\ninterface Array<T> { [n:number]:T; length:number; push(...items:T[]):number; unshift(...items:T[]):number; }\n"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--runtime", default="bun")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="home-automatic-variable-"))
    root.mkdir(parents=True, exist_ok=True)
    compilers = {
        "reference": ([args.runtime] if args.reference.suffix == ".js" else []) + [str(args.reference.resolve())],
        "home": [str(args.home.resolve())],
    }
    observations: list[dict] = []
    comparisons: list[dict] = []
    report = {"home_sha256": digest(args.home), "reference_sha256": digest(args.reference),
              "observations": observations, "comparisons": comparisons, "passed": False,
              "scope": "automatic scalar/array variable checking with strict and loose-null options; diagnostic positions/codes, statuses, and input preservation; excludes message text and emitted API parity"}

    def save() -> None:
        pending = root / "summary.pending.json"
        pending.write_text(json.dumps(report, indent=2) + "\n")
        pending.replace(root / "summary.json")

    save()
    for mode in ("strict", "loose-null"):
        for name, source in CASES.items():
            pair = []
            for engine, compiler in compilers.items():
                directory = root / mode / name / engine
                directory.mkdir(parents=True, exist_ok=False)
                (directory / "globals.d.ts").write_text(GLOBALS)
                (directory / "index.ts").write_text(source + "\n")
                options = {"strict": True, "noEmit": True, "noLib": True, "target": "ESNext", "module": "ESNext"}
                if mode == "loose-null":
                    options["strictNullChecks"] = False
                (directory / "tsconfig.json").write_text(json.dumps({
                    "compilerOptions": options, "files": ["globals.d.ts", "index.ts"],
                }, indent=2) + "\n")
                json.loads((directory / "tsconfig.json").read_text())
                before = {p.name: digest(p) for p in directory.iterdir()}
                command = compiler + ["--project", "tsconfig.json", "--pretty", "false"]
                timed_out = False
                try:
                    result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=30)
                    status, stdout, stderr = result.returncode, result.stdout, result.stderr
                except subprocess.TimeoutExpired as error:
                    status, timed_out = 124, True
                    stdout, stderr = error.stdout or "", error.stderr or ""
                    if isinstance(stdout, bytes):
                        stdout = stdout.decode(errors="replace")
                    if isinstance(stderr, bytes):
                        stderr = stderr.decode(errors="replace")
                output = stdout + stderr
                diagnostics = sorted((Path(file).name, int(line), int(column), int(code))
                                     for file, line, column, code in re.findall(
                                         r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output))
                unexpected_output = [line for line in output.splitlines()
                                     if line and not line[0].isspace()
                                     and not re.match(r".+\(\d+,\d+\): error TS\d+:", line)]
                after = {p.name: digest(p) for p in directory.iterdir() if p.is_file()}
                valid = (not timed_out and status in (0, 1) and before == after and not unexpected_output
                         and len(re.findall(r"error TS\d+:", output)) == len(diagnostics))
                record = {"case": name, "mode": mode, "engine": engine, "command": command,
                          "cwd": str(directory), "inputs": before, "exit": status,
                          "stdout": stdout, "stderr": stderr, "diagnostics": diagnostics,
                          "unexpected_output": unexpected_output,
                          "timed_out": timed_out, "observation_valid": valid}
                observations.append(record)
                pair.append(record)
                save()
            reference, home = pair
            passed = (all(r["observation_valid"] for r in pair)
                      and reference["exit"] == home["exit"]
                      and reference["diagnostics"] == home["diagnostics"])
            comparisons.append({"case": name, "mode": mode, "passed": passed})
            save()
    report["passed"] = all(c["passed"] for c in comparisons)
    save()
    failures = [f"{c['mode']}/{c['case']}" for c in comparisons if not c["passed"]]
    print(f"Automatic-variable comparisons: {len(comparisons) - len(failures)}/{len(comparisons)} matched; evidence: {root}")
    if failures:
        raise SystemExit("Mismatches: " + ", ".join(failures))


if __name__ == "__main__":
    main()
