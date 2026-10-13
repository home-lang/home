#!/usr/bin/env python3
"""Compare recursive ambient-interface checking with an installed TypeScript CLI.

Run under scripts/run-bounded.pl. All projects are isolated, have no dependencies,
and retain their inputs and observations when --output is supplied.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

GLOBALS = "\n".join(
    f"interface {name} {{}}"
    for name in (
        "Array<T>", "Boolean", "CallableFunction", "Function", "IArguments",
        "NewableFunction", "Number", "Object", "RegExp", "String",
    )
) + "\ninterface TemplateStringsArray extends Array<string> { readonly raw: readonly string[]; }\n"
CASES = {
    "recursive-generic-alias-scopes": (
        "declare namespace Left { type Tree<T> = T | { [key: string]: Tree<T> }; type Strings = Tree<string>; }\n"
        "declare namespace Right { type Tree<T> = T | { [key: string]: Tree<T> }; type Strings = Tree<string>; }\n",
        "declare const left: Left.Strings; declare const bad: Right.Tree<number>;\n"
        "const right: Right.Strings = left;\n",
        "const wrong: Right.Tree<string> = bad;\n",
    ),
    "qualified-generic-self": (
        "declare namespace Sockets { interface Link<T> { value: T; next: Sockets.Link<T>; } }\n",
        "declare const link: Sockets.Link<number>;\n"
        "const value: number = link.next.next.value;\n",
        "const wrong: string = link.next.next.value;\n",
    ),
    "qualified-generic-defaults": (
        "declare namespace Sockets { interface Pair<T = number, U = T> { first: T; second: U; } }\n",
        "declare const pair: Sockets.Pair;\n"
        "const value: number = pair.second;\n",
        "const wrong: string = pair.second;\n",
    ),
    "qualified-generic-sibling-scopes": (
        "declare namespace Left { interface Box<T> { value: T; } }\n"
        "declare namespace Right { interface Box<T> { value: T; label: string; } }\n",
        "declare const box: Left.Box<number>;\n"
        "const value: number = box.value;\n",
        "const wrong: string = box.value;\n",
    ),
    "forward-generic-builtin-name": (
        "declare namespace Sockets { interface Early<T> { promise: Promise<T>; } "
        "interface Promise<T> { value: T; } }\n",
        "declare const early: Sockets.Early<number>;\n"
        "const value: number = early.promise.value;\n",
        "const wrong: string = early.promise.value;\n",
    ),
    "forward-generic-namespace": (
        "declare namespace Sockets { interface Holder<T> { forward: LaterBox<T>; "
        "change<U>(value: U): LaterBox<U>; } "
        "interface LaterBox<T> { value: T; next?: Holder<T>; } }\n",
        "declare const holder: Sockets.Holder<number>;\n"
        "const value: number = holder.forward.value;\n",
        "const wrong: string = holder.forward.value;\n",
    ),
    "forward-generic-method": (
        "declare namespace Sockets { interface Holder<T> { forward: LaterBox<T>; "
        "change<U>(value: U): LaterBox<U>; } "
        "interface LaterBox<T> { value: T; next?: Holder<T>; } }\n",
        "declare const holder: Sockets.Holder<number>;\n"
        "const value: string = holder.change(\"value\").value;\n",
        "const wrong: number = holder.change(\"value\").value;\n",
    ),
    "self-property": (
        "interface Link { next: Link; value: number; }\n",
        "declare const link: Link;\nconst value: number = link.next.next.value;\n",
        "const wrong: string = link.next.next.value;\n",
    ),
    "self-method": (
        "interface TimerLike { ref(): TimerLike; label: string; }\n",
        "declare const timer: TimerLike;\nconst label: string = timer.ref().ref().label;\n",
        "const wrong: number = timer.ref().ref().label;\n",
    ),
    "self-method-with-alias": (
        "type Label = string;\ninterface TimerLike { ref(): TimerLike; label: Label; }\n",
        "declare const timer: TimerLike;\nconst label: string = timer.ref().ref().label;\n",
        "const wrong: number = timer.ref().ref().label;\n",
    ),
    "mutual-forward": (
        "interface Peer { other: Partner; value: number; }\n"
        "interface Partner { other: Peer; label: string; }\n",
        "declare const peer: Peer;\nconst value: number = peer.other.other.value;\n",
        "const wrong: string = peer.other.other.value;\n",
    ),
    "mutual-reversed": (
        "interface Partner { other: Peer; label: string; }\n"
        "interface Peer { other: Partner; value: number; }\n",
        "declare const peer: Peer;\nconst value: number = peer.other.other.value;\n",
        "const wrong: string = peer.other.other.value;\n",
    ),
    "merged-self": (
        "interface Link { next: Link; }\ninterface Link { value: number; }\n",
        "declare const link: Link;\nconst value: number = link.next.next.value;\n",
        "const wrong: string = link.next.next.value;\n",
    ),
    "many-merged-self": (
        "interface Link { next: Link; }\n" + "".join(
            f"interface Link {{ p{index}: number; }}\n" for index in range(24)
        ),
        "declare const link: Link;\nconst value: number = link.next.next.p23;\n",
        "const wrong: string = link.next.next.p23;\n",
    ),
    "nested-constructors": (
        "interface Tag { (strings: TemplateStringsArray, ...rest: number[]): Tag; "
        "member: { new (s: string): { new (n: number): { new (): boolean } } }; }\n",
        "declare const tag: Tag;\nconst value: boolean = new new new tag `head ${0}`.member(\"value\")(42);\n",
        "const wrong: number = new new new tag `head ${0}`.member(\"value\")(42);\n",
    ),
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--runtime", default="bun", help="Runtime for a JS reference")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    compilers = {
        "home": [str(args.home.resolve())],
        "reference": ([args.runtime] if args.reference.suffix == ".js" else [])
        + [str(args.reference.resolve())],
    }
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="home-recursive-interface-"))
    root.mkdir(parents=True, exist_ok=True)
    observations: list[dict] = []
    failures: list[str] = []
    summary = {
        "home_sha256": digest(args.home),
        "reference_sha256": digest(args.reference),
        "scope": "recursive ambient interface transfer, forward declaration order, merged bodies, and genuine type errors under skipLibCheck",
        "observations": observations,
        "failures": failures,
        "passed": False,
    }

    def save_summary() -> None:
        pending = root / "summary.pending.json"
        pending.write_text(json.dumps(summary, indent=2) + "\n")
        pending.replace(root / "summary.json")

    save_summary()
    for name, (declarations, valid, negative) in CASES.items():
        for planted in (False, True):
            variant = "negative" if planted else "valid"
            expected = [("main.ts", 3, 7, 2322)] if planted else []
            for engine, command in compilers.items():
                directory = root / name / variant / engine
                directory.mkdir(parents=True, exist_ok=False)
                (directory / "globals.d.ts").write_text(GLOBALS)
                (directory / "interfaces.d.ts").write_text(declarations)
                (directory / "main.ts").write_text(valid + (negative if planted else ""))
                (directory / "tsconfig.json").write_text(json.dumps({
                    "compilerOptions": {"noLib": True, "noEmit": True, "strict": True,
                                        "skipLibCheck": True, "target": "ESNext", "module": "ESNext"},
                    "files": ["globals.d.ts", "interfaces.d.ts", "main.ts"],
                }, indent=2) + "\n")
                inputs = {p.name: digest(p) for p in directory.iterdir()}
                argv = command + ["--project", "tsconfig.json", "--pretty", "false"]
                timed_out = False
                try:
                    result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
                    status, stdout, stderr = result.returncode, result.stdout, result.stderr
                except subprocess.TimeoutExpired as error:
                    timed_out = True
                    status = 124
                    stdout = error.stdout or ""
                    stderr = error.stderr or ""
                    if isinstance(stdout, bytes):
                        stdout = stdout.decode(errors="replace")
                    if isinstance(stderr, bytes):
                        stderr = stderr.decode(errors="replace")
                output = stdout + stderr
                diagnostics = sorted(
                    (Path(filename).name, int(line), int(column), int(code))
                    for filename, line, column, code in re.findall(
                        r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output,
                    )
                )
                outputs = {p.name: digest(p) for p in directory.iterdir() if p.is_file()}
                passed = (status == (1 if planted else 0)
                          and diagnostics == expected and inputs == outputs
                          and len(re.findall(r"error TS\d+:", output)) == len(expected))
                observations.append({
                    "case": name, "variant": variant, "engine": engine, "command": argv,
                    "cwd": str(directory), "inputs": inputs, "exit": status,
                    "stdout": stdout, "stderr": stderr, "timed_out": timed_out,
                    "diagnostics": diagnostics, "passed": passed,
                })
                if not passed:
                    failures.append(f"{name}/{variant}/{engine}: exit {status}, diagnostics {diagnostics}")
                save_summary()
    summary["passed"] = not failures
    save_summary()
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"All {len(observations)} recursive-interface observations passed; evidence: {root}")


if __name__ == "__main__":
    main()
