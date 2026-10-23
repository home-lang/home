#!/usr/bin/env python3
"""Compare imported generic inheritance and inference with native TypeScript under run-bounded.pl."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess


TYPES = """export interface Request { index: string; page?: number; }
export interface Driver<T> { value: T; search: (request: Request) => T; }
export interface Options<T> extends Omit<Request, "index"> { index: string; driver: Driver<T>; ranking?: {rules: readonly string[]}; }
export interface Table<T> { readonly driver: Driver<T>; search: (request?: Omit<Request,"index">) => T; }
"""
FACTORY = 'import type {Options,Table} from "./types";\nexport declare function create<T>(options:Options<T>):Table<T>;\n'
CASES = {}
for route in ('direct', 'reexport'):
    files = {'types.ts': TYPES, 'factory.ts': FACTORY}
    if route == 'reexport':
        files['index.ts'] = 'export * from "./factory";\nexport * from "./types";\n'
    for explicit in (False, True):
        valid = ('import { create } from "./' + ('factory' if route == 'direct' else 'index') + '";\n'
                 'import type {Driver,Table} from "./types";\n'
                 'declare const driver: Driver<{id:number}>;\n'
                 'const table = create' + ('<{id:number}>' if explicit else '') +
                 '({driver,index:"products",page:1,ranking:{rules:["ok"]}});\n'
                 'const check: Table<{id:number}> = table;\n'
                 'const id: number = table.search().id;\n')
        CASES[f'{route}-{"explicit" if explicit else "inferred"}'] = (
            files, valid, 'create({driver,index:"products",page:"bad"});\n', (7, 33, 2322))
        if route == 'direct' and not explicit:
            CASES['own-member-negative'] = (files, valid, 'create({driver,index:"products",ranking:"bad"});\n', (7, 33, 2322))
            CASES['inferred-result-negative'] = (files, valid, 'const wrong: string = table.search().id;\n', (7, 7, 2322))

files, valid, _, _ = CASES['direct-inferred']
CASES['contradictory-intersection'] = (
    files, valid, 'type Impossible = {kind:"a"} & {kind:"b"};\ndeclare let impossible: Impossible;\nimpossible = {kind:"a"};\n',
    (9, 15, 2322))


# Name resolution must retain the owner's type-space meaning even when a
# member's template pattern cannot yet be projected through the shared schema.
heritage_files = {
    'types.ts': ('export interface Contract { value: `prefix-${string}`; }\n'
                 'export default interface DefaultContract { value: `prefix-${string}`; }\n'
                 'export const valueOnly = 1;\n'),
    'named.ts': 'export type { Contract } from "./types";\n',
    'barrel.ts': ('export type { Contract as Forwarded } from "./types";\n'
                  'export { default, valueOnly } from "./types";\n'),
}
for route, binding in (
    ('direct', 'import type { Contract as Base } from "./types";\n'),
    ('barrel', 'import type { Forwarded as Base } from "./barrel";\n'),
    ('default', 'import type Base from "./types";\n'),
    ('default-barrel', 'import type Base from "./barrel";\n'),
):
    valid_heritage = (binding + 'interface Derived extends Base {}\n'
                      'class Implementation implements Base { value: `prefix-${string}` = "prefix-ok"; }\n')
    CASES[f'heritage-{route}'] = (
        heritage_files, valid_heritage, 'interface Unbound extends NotDeclared {}\n', (4, 27, 2304))

_, valid_heritage, _, _ = CASES['heritage-direct']
CASES['heritage-value-only'] = (
    heritage_files, valid_heritage,
    'import { valueOnly } from "./types";\ninterface ValueBase extends valueOnly {}\n', (5, 29, 2749))
CASES['heritage-type-only-value'] = (
    heritage_files, valid_heritage,
    'import type { valueOnly } from "./types";\ninterface ValueBase extends valueOnly {}\n', (5, 29, 2749))
CASES['heritage-missing-export'] = (
    heritage_files, valid_heritage, 'import type { Missing } from "./named";\n', (4, 15, 2305))



def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    globals_source = runpy.run_path(str(Path(__file__).with_name("test-ts-recursive-interface-cli.py")))['GLOBALS'] + '\ntype Pick<T, K extends keyof T> = { [P in K]: T[P] };\ntype Exclude<T, U> = T extends U ? never : T;\ntype Omit<T, K extends keyof any> = Pick<T, Exclude<keyof T, K>>;\n'
    compilers = {"home": args.home.resolve(), "reference": args.reference.resolve()}
    summary = {"scope": "imported generic inherited callable types",
               "compiler_hashes": {name: digest(exe) for name, exe in compilers.items()},
               "observations": [], "failures": [], "passed": False}

    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    save()
    for name, (files, valid, negative, error) in CASES.items():
        for exact in (False, True):
            for planted in (False, True):
                expected = [("main.ts", *error)] if planted else []
                for engine, exe in compilers.items():
                    directory = root / name / str(exact) / ("negative" if planted else "valid") / engine
                    directory.mkdir(parents=True)
                    for file, source in files.items():
                        target = directory / file
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text(source)
                    (directory / "globals.d.ts").write_text(globals_source)
                    (directory / "main.ts").write_text(valid + (negative if planted else ""))
                    (directory / "tsconfig.json").write_text(json.dumps({
                        "compilerOptions": {"noLib": True, "noEmit": True, "strict": True,
                                            "exactOptionalPropertyTypes": exact, "target": "ESNext", "module": "ESNext",
                                            "moduleResolution": "Bundler"},
                        "files": ["globals.d.ts", "main.ts", *files],
                    }, indent=2) + "\n")
                    inputs = {str(p.relative_to(directory)): digest(p) for p in directory.rglob('*') if p.is_file()}
                    argv = [str(exe), "--project", "tsconfig.json", "--pretty", "false"]
                    result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
                    output = result.stdout + result.stderr
                    diagnostics = sorted((Path(file).name, int(line), int(column), int(code))
                        for file, line, column, code in re.findall(
                            r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output))
                    unchanged = inputs == {str(p.relative_to(directory)): digest(p) for p in directory.rglob('*') if p.is_file()}
                    passed = (result.returncode == (1 if expected else 0) and diagnostics == expected
                              and unchanged and len(re.findall(r"error TS\d+:", output)) == len(expected))
                    summary["observations"].append({
                        "case": name, "exactOptionalPropertyTypes": exact, "variant": "negative" if planted else "valid",
                        "engine": engine, "command": argv, "cwd": str(directory), "input_hashes": inputs,
                        "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                        "diagnostics": diagnostics, "passed": passed,
                    })
                    if not passed:
                        summary["failures"].append(f"{name}/{exact}/{planted}/{engine}: {diagnostics}, exit {result.returncode}")
                    save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} imported generic observations passed")


if __name__ == "__main__":
    main()
