#!/usr/bin/env python3
"""Compare optional object writes with native TypeScript under run-bounded.pl."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess


CASES = {'call': {'source': 'import type {Result} from "./types";\n'
                    'declare const optional:number|undefined;\n'
                    'declare function accept(item:Result<string>):void;\n'
                    'accept({value:"ok",optional});\n',
          'files': {'types.ts': 'export interface Result<T> { value: T; optional?: number; }\n'},
          'expected': {'False': [], 'True': [['main.ts', 4, 8, 2379]]}},
 'return-imported': {'source': 'import type {Result} from "./types";\n'
                               'function make<T>(value:T, optional:number|undefined):Result<T> { return '
                               '{value,optional}; }\n',
                     'files': {'types.ts': 'export interface Result<T> { value: T; optional?: number; '
                                           '}\n'},
                     'expected': {'False': [], 'True': [['main.ts', 2, 66, 2375]]}},
 'return-local': {'source': 'interface Result<T> {value:T;optional?:number;}\n'
                            'function make<T>(value:T, optional:number|undefined):Result<T> { return '
                            '{value,optional}; }\n',
                  'files': {'types.ts': 'export interface Result<T> { value: T; optional?: number; }\n'},
                  'expected': {'False': [], 'True': [['main.ts', 2, 66, 2375]]}},
 'satisfies': {'source': 'import type {Result} from "./types";\n'
                         'declare const optional:number|undefined;\n'
                         'const item = {value:"ok",optional} satisfies Result<string>;\n',
               'files': {'types.ts': 'export interface Result<T> { value: T; optional?: number; }\n'},
               'expected': {'False': [], 'True': [['main.ts', 3, 36, 1360]]}},
 'variable': {'source': 'import type {Result} from "./types";\n'
                        'declare const optional:number|undefined;\n'
                        'const item:Result<string> = {value:"ok",optional};\n',
              'files': {'types.ts': 'export interface Result<T> { value: T; optional?: number; }\n'},
              'expected': {'False': [], 'True': [['main.ts', 3, 7, 2375]]}},
 'array': {'source': 'interface O { optional?: number }\n'
                     'declare const value: number | undefined;\n'
                     'const items:O[] = [{optional:value}];\n',
           'files': {},
           'expected': {'False': [], 'True': [['main.ts', 3, 7, 2322]]}},
 'array-call': {'source': 'interface O {optional?:number}\n'
                          'declare const value:number|undefined;\n'
                          'declare function accept(items:O[]):void;\n'
                          'accept([{optional:value}]);\n',
                'files': {},
                'expected': {'False': [], 'True': [['main.ts', 4, 8, 2345]]}},
 'array-return': {'source': 'interface O {optional?:number}\n'
                            'declare const value:number|undefined;\n'
                            'function make():O[]{return [{optional:value}];}\n',
                  'files': {},
                  'expected': {'False': [], 'True': [['main.ts', 3, 21, 2322]]}},
 'async-return-corrected': {'source': 'interface O {optional?:number}\n'
                                      'declare const value:number|undefined;\n'
                                      'async function make():Promise<O>{return {optional:value};}\n',
                            'files': {'promise.d.ts': 'interface PromiseLike<T> {}\n'
                                                      'interface Promise<T> {}\n'},
                            'expected': {'False': [], 'True': [['main.ts', 3, 34, 2375]]}},
 'concrete-number': {'source': 'interface O {optional?:number}\n'
                               'const item:O={optional:1};\n'
                               'function make():O{return {optional:1};}\n'
                               'declare function accept(item:O):void;\n'
                               'accept({optional:1});\n'
                               'const checked={optional:1} satisfies O;\n',
                     'files': {},
                     'expected': {'False': [], 'True': []}},
 'explicit-undefined-type': {'source': 'interface O { optional?: number | undefined }\n'
                                       'const item: O = { optional: undefined };\n'
                                       'function make():O {return {optional:undefined};}\n',
                             'files': {},
                             'expected': {'False': [], 'True': []}},
 'literal-undefined-return': {'source': 'interface O { optional?: number }\n'
                                        'function make(): O { return { optional: undefined }; }\n',
                              'files': {},
                              'expected': {'False': [], 'True': [['main.ts', 2, 22, 2375]]}},
 'literal-undefined-satisfies': {'source': 'interface O { optional?: number }\n'
                                           'const item = { optional: undefined } satisfies O;\n',
                                 'files': {},
                                 'expected': {'False': [], 'True': [['main.ts', 2, 38, 1360]]}},
 'literal-undefined-variable': {'source': 'interface O { optional?: number }\n'
                                          'const item: O = { optional: undefined };\n',
                                'files': {},
                                'expected': {'False': [], 'True': [['main.ts', 2, 7, 2375]]}},
 'nested': {'source': 'interface O { optional?: number }\n'
                      'declare const value: number | undefined;\n'
                      'const item: {nested:O} = {nested:{optional:value}};\n',
            'files': {},
            'expected': {'False': [], 'True': [['main.ts', 3, 27, 2375]]}},
 'omitted': {'source': 'interface O {optional?:number}\n'
                       'const item:O={};\n'
                       'function make():O{return {};}\n'
                       'declare function accept(item:O):void;\n'
                       'accept({});\n'
                       'const checked={} satisfies O;\n',
             'files': {},
             'expected': {'False': [], 'True': []}},
 'required-return': {'source': 'interface O { required: number }\n'
                               'function make(value: number | undefined): O { return {required:value}; '
                               '}\n',
                     'files': {},
                     'expected': {'False': [['main.ts', 2, 55, 2322]],
                                  'True': [['main.ts', 2, 55, 2322]]}},
 'typed-assignment': {'source': 'interface O { optional?: number }\n'
                                'declare const value: number | undefined;\n'
                                'declare const source: {optional:number|undefined};\n'
                                'const item: O = source;\n',
                      'files': {},
                      'expected': {'False': [], 'True': [['main.ts', 4, 7, 2375]]}},
 'typed-return': {'source': 'interface O { optional?: number }\n'
                            'declare const value: number | undefined;\n'
                            'declare const source: {optional:number|undefined};\n'
                            'function make():O {return source;}\n',
                  'files': {},
                  'expected': {'False': [], 'True': [['main.ts', 4, 20, 2375]]}},
 'wrong-return': {'source': 'interface O { optional?: number }\n'
                            'function make(): O { return { optional: "bad" }; }\n',
                  'files': {},
                  'expected': {'False': [['main.ts', 2, 31, 2322]], 'True': [['main.ts', 2, 31, 2322]]}},
 'wrong-satisfies': {'source': 'interface O { optional?: number }\n'
                               'const item = { optional: "bad" } satisfies O;\n',
                     'files': {},
                     'expected': {'False': [['main.ts', 2, 16, 2322]],
                                  'True': [['main.ts', 2, 16, 2322]]}},
 'wrong-variable': {'source': 'interface O { optional?: number }\n'
                              'const item: O = { optional: "bad" };\n',
                    'files': {},
                    'expected': {'False': [['main.ts', 2, 19, 2322]],
                                 'True': [['main.ts', 2, 19, 2322]]}},
 'generic-call': {'source': 'interface O {value:string;optional?:number}\n'
                            'declare const maybe:number|undefined;\n'
                            'declare function identity<T>(value:T):T;\n'
                            'declare function accept(item:O):void;\n'
                            'accept({value:"ok",optional:identity(maybe)});\n',
                  'files': {},
                  'expected': {'False': [], 'True': [('main.ts', 5, 8, 2379)]}},
 'generic-return': {'source': 'interface O {value:string;optional?:number}\n'
                              'declare const maybe:number|undefined;\n'
                              'declare function identity<T>(value:T):T;\n'
                              'function make():O{return {value:"ok",optional:identity(maybe)};}\n',
                    'files': {},
                    'expected': {'False': [], 'True': [('main.ts', 4, 19, 2375)]}},
 'generic-variable': {'source': 'interface O {value:string;optional?:number}\n'
                                'declare const maybe:number|undefined;\n'
                                'declare function identity<T>(value:T):T;\n'
                                'const item:O={value:"ok",optional:identity(maybe)};\n',
                      'files': {},
                      'expected': {'False': [], 'True': [('main.ts', 4, 7, 2375)]}},
 'mixed-return': {'source': 'interface O {value:string;optional?:number}\n'
                            'declare const maybe:number|undefined;\n'
                            'declare function identity<T>(value:T):T;\n'
                            'function make():O{return {value:123,optional:maybe};}\n',
                  'files': {},
                  'expected': {'False': [('main.ts', 4, 27, 2322)], 'True': [('main.ts', 4, 27, 2322)]}},
 'mixed-variable': {'source': 'interface O {value:string;optional?:number}\n'
                              'declare const maybe:number|undefined;\n'
                              'declare function identity<T>(value:T):T;\n'
                              'const item:O={value:123,optional:maybe};\n',
                    'files': {},
                    'expected': {'False': [('main.ts', 4, 15, 2322)],
                                 'True': [('main.ts', 4, 15, 2322)]}},
 'array-wrong-call': {'source': 'interface O {optional?:number}\n'
                                'declare function accept(items:O[]):void;\n'
                                'accept([{optional:"bad"}]);\n',
                      'files': {},
                      'expected': {'False': [('main.ts', 3, 8, 2345)],
                                   'True': [('main.ts', 3, 8, 2345)]}},
 'array-wrong-return': {'source': 'interface O {optional?:number}\n'
                                  'function make():O[]{return [{optional:"bad"}];}\n',
                        'files': {},
                        'expected': {'False': [('main.ts', 2, 21, 2322)],
                                     'True': [('main.ts', 2, 21, 2322)]}},
 'array-wrong-variable': {'source': 'interface O {optional?:number}\n'
                                    'const items:O[]=[{optional:"bad"}];\n',
                          'files': {},
                          'expected': {'False': [('main.ts', 2, 7, 2322)],
                                       'True': [('main.ts', 2, 7, 2322)]}},
 'mixed-call': {'source': 'interface O {value:string;optional?:number}\n'
                          'declare const maybe:number|undefined;\n'
                          'declare function accept(item:O):void;\n'
                          'accept({value:123,optional:maybe});\n',
                'files': {},
                'expected': {'False': [('main.ts', 4, 9, 2322)], 'True': [('main.ts', 4, 9, 2322)]}},
 'mixed-literal': {'source': 'interface O {value:string;optional?:number}\n'
                             'const item:O={value:123,optional:undefined};\n',
                   'files': {},
                   'expected': {'False': [('main.ts', 2, 15, 2322)],
                                'True': [('main.ts', 2, 15, 2322)]}}}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    globals_source = runpy.run_path(str(Path(__file__).with_name("test-ts-recursive-interface-cli.py")))["GLOBALS"]
    compilers = {"home": args.home.resolve(), "reference": args.reference.resolve()}
    summary = {"scope": "optional object writes across return, variable, call, satisfies, nested and array contexts",
               "compiler_hashes": {name: digest(exe) for name, exe in compilers.items()},
               "observations": [], "failures": [], "passed": False}

    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    save()
    for name, case in CASES.items():
        for exact in (False, True):
            expected = [tuple(item) for item in case["expected"][str(exact)]]
            for engine, exe in compilers.items():
                directory = root / name / str(exact) / engine
                directory.mkdir(parents=True)
                for file, source in case["files"].items():
                    (directory / file).write_text(source)
                (directory / "globals.d.ts").write_text(globals_source)
                (directory / "main.ts").write_text(case["source"])
                (directory / "tsconfig.json").write_text(json.dumps({
                    "compilerOptions": {"noLib": True, "noEmit": True, "strict": True,
                                        "exactOptionalPropertyTypes": exact, "target": "ESNext",
                                        "module": "ESNext", "moduleResolution": "Bundler"},
                    "files": ["globals.d.ts", "main.ts", *case["files"]],
                }, indent=2) + "\n")
                inputs = {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
                argv = [str(exe), "--project", "tsconfig.json", "--pretty", "false"]
                result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
                output = result.stdout + result.stderr
                diagnostics = sorted((Path(file).name, int(line), int(column), int(code))
                    for file, line, column, code in re.findall(
                        r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output))
                unchanged = inputs == {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
                passed = (result.returncode == (1 if expected else 0) and diagnostics == expected
                          and unchanged and len(re.findall(r"error TS\d+:", output)) == len(expected))
                summary["observations"].append({"case": name, "exactOptionalPropertyTypes": exact,
                    "engine": engine, "command": argv, "cwd": str(directory), "input_hashes": inputs,
                    "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                    "diagnostics": diagnostics, "passed": passed})
                if not passed:
                    summary["failures"].append(f"{name}/{exact}/{engine}: {diagnostics}, exit {result.returncode}")
                save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} optional object observations passed")


if __name__ == "__main__":
    main()
