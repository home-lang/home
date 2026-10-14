#!/usr/bin/env python3
"""Compare contextual index parameters and declaration grammar with TypeScript."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CASES = {'computed-expression/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                              'module': 'ESNext',
                                                              'moduleResolution': 'Bundler',
                                                              'noEmit': True,
                                                              'skipLibCheck': False,
                                                              'strict': True,
                                                              'target': 'ESNext'},
                                          'files': ['types.d.ts', 'main.ts']},
                               'expected': [('types.d.ts', 1, 24, 1169)],
                               'files': {'main.ts': 'export {};\n',
                                         'types.d.ts': 'export interface Bad { ["" + ""](): void; '
                                                       '}\n'}},
 'computed-expression/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                             'module': 'ESNext',
                                                             'moduleResolution': 'Bundler',
                                                             'noEmit': True,
                                                             'skipLibCheck': True,
                                                             'strict': True,
                                                             'target': 'ESNext'},
                                         'files': ['types.d.ts', 'main.ts']},
                              'expected': [],
                              'files': {'main.ts': 'export {};\n',
                                        'types.d.ts': 'export interface Bad { ["" + ""](): void; '
                                                      '}\n'}},
 'computed-key/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                       'module': 'ESNext',
                                                       'moduleResolution': 'Bundler',
                                                       'noEmit': True,
                                                       'skipLibCheck': False,
                                                       'strict': True,
                                                       'target': 'ESNext'},
                                   'files': ['types.d.ts', 'main.ts']},
                        'expected': [],
                        'files': {'main.ts': 'export {};\n',
                                  'types.d.ts': 'declare const key: symbol; interface Bad { '
                                                '[key](): void }\n'}},
 'computed-key/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                      'module': 'ESNext',
                                                      'moduleResolution': 'Bundler',
                                                      'noEmit': True,
                                                      'skipLibCheck': True,
                                                      'strict': True,
                                                      'target': 'ESNext'},
                                  'files': ['types.d.ts', 'main.ts']},
                       'expected': [],
                       'files': {'main.ts': 'export {};\n',
                                 'types.d.ts': 'declare const key: symbol; interface Bad { '
                                               '[key](): void }\n'}},
 'computed-type-literal/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                                'module': 'ESNext',
                                                                'moduleResolution': 'Bundler',
                                                                'noEmit': True,
                                                                'skipLibCheck': False,
                                                                'strict': True,
                                                                'target': 'ESNext'},
                                            'files': ['types.d.ts', 'main.ts']},
                                 'expected': [('types.d.ts', 1, 21, 1170)],
                                 'files': {'main.ts': 'export {};\n',
                                           'types.d.ts': 'export type Bad = { ["" + ""](): void; '
                                                         '};\n'}},
 'computed-type-literal/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                               'module': 'ESNext',
                                                               'moduleResolution': 'Bundler',
                                                               'noEmit': True,
                                                               'skipLibCheck': True,
                                                               'strict': True,
                                                               'target': 'ESNext'},
                                           'files': ['types.d.ts', 'main.ts']},
                                'expected': [],
                                'files': {'main.ts': 'export {};\n',
                                          'types.d.ts': 'export type Bad = { ["" + ""](): void; '
                                                        '};\n'}},
 'keyword-async/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                        'module': 'ESNext',
                                                        'moduleResolution': 'Bundler',
                                                        'noEmit': True,
                                                        'skipLibCheck': False,
                                                        'strict': True,
                                                        'target': 'ESNext'},
                                    'files': ['types.d.ts', 'main.ts']},
                         'expected': [('main.ts', 4, 7, 2322)],
                         'files': {'main.ts': 'import type {I} from "./types";\n'
                                              'declare const value:I;\n'
                                              'const good:number=value.hello;\n'
                                              'const wrong:string=value.hello;\n',
                                   'types.d.ts': 'export interface I { [async: string]: number; }\n'
                                                 'export type A = { readonly [async: number]: '
                                                 'string; };\n'
                                                 'export declare class C { [async: string]: '
                                                 'boolean; }\n'}},
 'keyword-async/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                       'module': 'ESNext',
                                                       'moduleResolution': 'Bundler',
                                                       'noEmit': True,
                                                       'skipLibCheck': True,
                                                       'strict': True,
                                                       'target': 'ESNext'},
                                   'files': ['types.d.ts', 'main.ts']},
                        'expected': [('main.ts', 4, 7, 2322)],
                        'files': {'main.ts': 'import type {I} from "./types";\n'
                                             'declare const value:I;\n'
                                             'const good:number=value.hello;\n'
                                             'const wrong:string=value.hello;\n',
                                  'types.d.ts': 'export interface I { [async: string]: number; }\n'
                                                'export type A = { readonly [async: number]: '
                                                'string; };\n'
                                                'export declare class C { [async: string]: '
                                                'boolean; }\n'}},
 'keyword-declare/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                          'module': 'ESNext',
                                                          'moduleResolution': 'Bundler',
                                                          'noEmit': True,
                                                          'skipLibCheck': False,
                                                          'strict': True,
                                                          'target': 'ESNext'},
                                      'files': ['types.d.ts', 'main.ts']},
                           'expected': [('main.ts', 4, 7, 2322)],
                           'files': {'main.ts': 'import type {I} from "./types";\n'
                                                'declare const value:I;\n'
                                                'const good:number=value.hello;\n'
                                                'const wrong:string=value.hello;\n',
                                     'types.d.ts': 'export interface I { [declare: string]: '
                                                   'number; }\n'
                                                   'export type A = { readonly [declare: number]: '
                                                   'string; };\n'
                                                   'export declare class C { [declare: string]: '
                                                   'boolean; }\n'}},
 'keyword-declare/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                         'module': 'ESNext',
                                                         'moduleResolution': 'Bundler',
                                                         'noEmit': True,
                                                         'skipLibCheck': True,
                                                         'strict': True,
                                                         'target': 'ESNext'},
                                     'files': ['types.d.ts', 'main.ts']},
                          'expected': [('main.ts', 4, 7, 2322)],
                          'files': {'main.ts': 'import type {I} from "./types";\n'
                                               'declare const value:I;\n'
                                               'const good:number=value.hello;\n'
                                               'const wrong:string=value.hello;\n',
                                    'types.d.ts': 'export interface I { [declare: string]: number; '
                                                  '}\n'
                                                  'export type A = { readonly [declare: number]: '
                                                  'string; };\n'
                                                  'export declare class C { [declare: string]: '
                                                  'boolean; }\n'}},
 'keyword-get/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                      'module': 'ESNext',
                                                      'moduleResolution': 'Bundler',
                                                      'noEmit': True,
                                                      'skipLibCheck': False,
                                                      'strict': True,
                                                      'target': 'ESNext'},
                                  'files': ['types.d.ts', 'main.ts']},
                       'expected': [('main.ts', 4, 7, 2322)],
                       'files': {'main.ts': 'import type {I} from "./types";\n'
                                            'declare const value:I;\n'
                                            'const good:number=value.hello;\n'
                                            'const wrong:string=value.hello;\n',
                                 'types.d.ts': 'export interface I { [get: string]: number; }\n'
                                               'export type A = { readonly [get: number]: string; '
                                               '};\n'
                                               'export declare class C { [get: string]: boolean; '
                                               '}\n'}},
 'keyword-get/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                     'module': 'ESNext',
                                                     'moduleResolution': 'Bundler',
                                                     'noEmit': True,
                                                     'skipLibCheck': True,
                                                     'strict': True,
                                                     'target': 'ESNext'},
                                 'files': ['types.d.ts', 'main.ts']},
                      'expected': [('main.ts', 4, 7, 2322)],
                      'files': {'main.ts': 'import type {I} from "./types";\n'
                                           'declare const value:I;\n'
                                           'const good:number=value.hello;\n'
                                           'const wrong:string=value.hello;\n',
                                'types.d.ts': 'export interface I { [get: string]: number; }\n'
                                              'export type A = { readonly [get: number]: string; '
                                              '};\n'
                                              'export declare class C { [get: string]: boolean; '
                                              '}\n'}},
 'keyword-number/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                         'module': 'ESNext',
                                                         'moduleResolution': 'Bundler',
                                                         'noEmit': True,
                                                         'skipLibCheck': False,
                                                         'strict': True,
                                                         'target': 'ESNext'},
                                     'files': ['types.d.ts', 'main.ts']},
                          'expected': [('main.ts', 4, 7, 2322)],
                          'files': {'main.ts': 'import type {I} from "./types";\n'
                                               'declare const value:I;\n'
                                               'const good:number=value.hello;\n'
                                               'const wrong:string=value.hello;\n',
                                    'types.d.ts': 'export interface I { [number: string]: number; '
                                                  '}\n'
                                                  'export type A = { readonly [number: number]: '
                                                  'string; };\n'
                                                  'export declare class C { [number: string]: '
                                                  'boolean; }\n'}},
 'keyword-number/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                        'module': 'ESNext',
                                                        'moduleResolution': 'Bundler',
                                                        'noEmit': True,
                                                        'skipLibCheck': True,
                                                        'strict': True,
                                                        'target': 'ESNext'},
                                    'files': ['types.d.ts', 'main.ts']},
                         'expected': [('main.ts', 4, 7, 2322)],
                         'files': {'main.ts': 'import type {I} from "./types";\n'
                                              'declare const value:I;\n'
                                              'const good:number=value.hello;\n'
                                              'const wrong:string=value.hello;\n',
                                   'types.d.ts': 'export interface I { [number: string]: number; '
                                                 '}\n'
                                                 'export type A = { readonly [number: number]: '
                                                 'string; };\n'
                                                 'export declare class C { [number: string]: '
                                                 'boolean; }\n'}},
 'keyword-readonly/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                           'module': 'ESNext',
                                                           'moduleResolution': 'Bundler',
                                                           'noEmit': True,
                                                           'skipLibCheck': False,
                                                           'strict': True,
                                                           'target': 'ESNext'},
                                       'files': ['types.d.ts', 'main.ts']},
                            'expected': [('main.ts', 4, 7, 2322)],
                            'files': {'main.ts': 'import type {I} from "./types";\n'
                                                 'declare const value:I;\n'
                                                 'const good:number=value.hello;\n'
                                                 'const wrong:string=value.hello;\n',
                                      'types.d.ts': 'export interface I { [readonly: string]: '
                                                    'number; }\n'
                                                    'export type A = { readonly [readonly: '
                                                    'number]: string; };\n'
                                                    'export declare class C { [readonly: string]: '
                                                    'boolean; }\n'}},
 'keyword-readonly/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                          'module': 'ESNext',
                                                          'moduleResolution': 'Bundler',
                                                          'noEmit': True,
                                                          'skipLibCheck': True,
                                                          'strict': True,
                                                          'target': 'ESNext'},
                                      'files': ['types.d.ts', 'main.ts']},
                           'expected': [('main.ts', 4, 7, 2322)],
                           'files': {'main.ts': 'import type {I} from "./types";\n'
                                                'declare const value:I;\n'
                                                'const good:number=value.hello;\n'
                                                'const wrong:string=value.hello;\n',
                                     'types.d.ts': 'export interface I { [readonly: string]: '
                                                   'number; }\n'
                                                   'export type A = { readonly [readonly: number]: '
                                                   'string; };\n'
                                                   'export declare class C { [readonly: string]: '
                                                   'boolean; }\n'}},
 'keyword-string/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                         'module': 'ESNext',
                                                         'moduleResolution': 'Bundler',
                                                         'noEmit': True,
                                                         'skipLibCheck': False,
                                                         'strict': True,
                                                         'target': 'ESNext'},
                                     'files': ['types.d.ts', 'main.ts']},
                          'expected': [('main.ts', 4, 7, 2322)],
                          'files': {'main.ts': 'import type {I} from "./types";\n'
                                               'declare const value:I;\n'
                                               'const good:number=value.hello;\n'
                                               'const wrong:string=value.hello;\n',
                                    'types.d.ts': 'export interface I { [string: string]: number; '
                                                  '}\n'
                                                  'export type A = { readonly [string: number]: '
                                                  'string; };\n'
                                                  'export declare class C { [string: string]: '
                                                  'boolean; }\n'}},
 'keyword-string/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                        'module': 'ESNext',
                                                        'moduleResolution': 'Bundler',
                                                        'noEmit': True,
                                                        'skipLibCheck': True,
                                                        'strict': True,
                                                        'target': 'ESNext'},
                                    'files': ['types.d.ts', 'main.ts']},
                         'expected': [('main.ts', 4, 7, 2322)],
                         'files': {'main.ts': 'import type {I} from "./types";\n'
                                              'declare const value:I;\n'
                                              'const good:number=value.hello;\n'
                                              'const wrong:string=value.hello;\n',
                                   'types.d.ts': 'export interface I { [string: string]: number; '
                                                 '}\n'
                                                 'export type A = { readonly [string: number]: '
                                                 'string; };\n'
                                                 'export declare class C { [string: string]: '
                                                 'boolean; }\n'}},
 'keyword-symbol/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                         'module': 'ESNext',
                                                         'moduleResolution': 'Bundler',
                                                         'noEmit': True,
                                                         'skipLibCheck': False,
                                                         'strict': True,
                                                         'target': 'ESNext'},
                                     'files': ['types.d.ts', 'main.ts']},
                          'expected': [('main.ts', 4, 7, 2322)],
                          'files': {'main.ts': 'import type {I} from "./types";\n'
                                               'declare const value:I;\n'
                                               'const good:number=value.hello;\n'
                                               'const wrong:string=value.hello;\n',
                                    'types.d.ts': 'export interface I { [symbol: string]: number; '
                                                  '}\n'
                                                  'export type A = { readonly [symbol: number]: '
                                                  'string; };\n'
                                                  'export declare class C { [symbol: string]: '
                                                  'boolean; }\n'}},
 'keyword-symbol/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                        'module': 'ESNext',
                                                        'moduleResolution': 'Bundler',
                                                        'noEmit': True,
                                                        'skipLibCheck': True,
                                                        'strict': True,
                                                        'target': 'ESNext'},
                                    'files': ['types.d.ts', 'main.ts']},
                         'expected': [('main.ts', 4, 7, 2322)],
                         'files': {'main.ts': 'import type {I} from "./types";\n'
                                              'declare const value:I;\n'
                                              'const good:number=value.hello;\n'
                                              'const wrong:string=value.hello;\n',
                                   'types.d.ts': 'export interface I { [symbol: string]: number; '
                                                 '}\n'
                                                 'export type A = { readonly [symbol: number]: '
                                                 'string; };\n'
                                                 'export declare class C { [symbol: string]: '
                                                 'boolean; }\n'}},
 'keyword-type/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                       'module': 'ESNext',
                                                       'moduleResolution': 'Bundler',
                                                       'noEmit': True,
                                                       'skipLibCheck': False,
                                                       'strict': True,
                                                       'target': 'ESNext'},
                                   'files': ['types.d.ts', 'main.ts']},
                        'expected': [('main.ts', 4, 7, 2322)],
                        'files': {'main.ts': 'import type {I} from "./types";\n'
                                             'declare const value:I;\n'
                                             'const good:number=value.hello;\n'
                                             'const wrong:string=value.hello;\n',
                                  'types.d.ts': 'export interface I { [type: string]: number; }\n'
                                                'export type A = { readonly [type: number]: '
                                                'string; };\n'
                                                'export declare class C { [type: string]: boolean; '
                                                '}\n'}},
 'keyword-type/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                      'module': 'ESNext',
                                                      'moduleResolution': 'Bundler',
                                                      'noEmit': True,
                                                      'skipLibCheck': True,
                                                      'strict': True,
                                                      'target': 'ESNext'},
                                  'files': ['types.d.ts', 'main.ts']},
                       'expected': [('main.ts', 4, 7, 2322)],
                       'files': {'main.ts': 'import type {I} from "./types";\n'
                                            'declare const value:I;\n'
                                            'const good:number=value.hello;\n'
                                            'const wrong:string=value.hello;\n',
                                 'types.d.ts': 'export interface I { [type: string]: number; }\n'
                                               'export type A = { readonly [type: number]: string; '
                                               '};\n'
                                               'export declare class C { [type: string]: boolean; '
                                               '}\n'}},
 'malformed/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                    'module': 'ESNext',
                                                    'moduleResolution': 'Bundler',
                                                    'noEmit': True,
                                                    'skipLibCheck': False,
                                                    'strict': True,
                                                    'target': 'ESNext'},
                                'files': ['types.d.ts', 'main.ts']},
                     'expected': [('types.d.ts', 1, 27, 1110)],
                     'files': {'main.ts': 'export {};\n',
                               'types.d.ts': 'interface Broken { value: ; }\n'}},
 'malformed/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                   'module': 'ESNext',
                                                   'moduleResolution': 'Bundler',
                                                   'noEmit': True,
                                                   'skipLibCheck': True,
                                                   'strict': True,
                                                   'target': 'ESNext'},
                               'files': ['types.d.ts', 'main.ts']},
                    'expected': [('types.d.ts', 1, 27, 1110)],
                    'files': {'main.ts': 'export {};\n',
                              'types.d.ts': 'interface Broken { value: ; }\n'}},
 'string-index/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                       'module': 'ESNext',
                                                       'moduleResolution': 'Bundler',
                                                       'noEmit': True,
                                                       'skipLibCheck': False,
                                                       'strict': True,
                                                       'target': 'ESNext'},
                                   'files': ['types.d.ts', 'main.ts']},
                        'expected': [],
                        'files': {'main.ts': 'export {};\n',
                                  'types.d.ts': 'declare module "node:ffi" { interface Signature { '
                                                'return?: string; arguments?: readonly string[]; } '
                                                'interface Definitions { [symbol: string]: '
                                                'Signature; } }\n'}},
 'string-index/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                      'module': 'ESNext',
                                                      'moduleResolution': 'Bundler',
                                                      'noEmit': True,
                                                      'skipLibCheck': True,
                                                      'strict': True,
                                                      'target': 'ESNext'},
                                  'files': ['types.d.ts', 'main.ts']},
                       'expected': [],
                       'files': {'main.ts': 'export {};\n',
                                 'types.d.ts': 'declare module "node:ffi" { interface Signature { '
                                               'return?: string; arguments?: readonly string[]; } '
                                               'interface Definitions { [symbol: string]: '
                                               'Signature; } }\n'}},
 'unique-key/False': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                     'module': 'ESNext',
                                                     'moduleResolution': 'Bundler',
                                                     'noEmit': True,
                                                     'skipLibCheck': False,
                                                     'strict': True,
                                                     'target': 'ESNext'},
                                 'files': ['types.d.ts', 'main.ts']},
                      'expected': [],
                      'files': {'main.ts': 'export {};\n',
                                'types.d.ts': 'declare const key: unique symbol; interface Good { '
                                              '[key](): void }\n'}},
 'unique-key/True': {'config': {'compilerOptions': {'lib': ['ES2023'],
                                                    'module': 'ESNext',
                                                    'moduleResolution': 'Bundler',
                                                    'noEmit': True,
                                                    'skipLibCheck': True,
                                                    'strict': True,
                                                    'target': 'ESNext'},
                                'files': ['types.d.ts', 'main.ts']},
                     'expected': [],
                     'files': {'main.ts': 'export {};\n',
                               'types.d.ts': 'declare const key: unique symbol; interface Good { '
                                             '[key](): void }\n'}}}

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("home", "reference", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    compilers = {"home": args.home.resolve(), "reference": args.reference.resolve()}
    summary = {"compiler_hashes": {n: digest(p) for n, p in compilers.items()},
               "observations": [], "failures": [], "passed": False}
    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    save()
    for name, case in CASES.items():
        expected = sorted(case["expected"])
        for engine, exe in compilers.items():
            directory = root / name / engine
            directory.mkdir(parents=True)
            for file, source in case["files"].items():
                (directory / file).write_text(source)
            (directory / "tsconfig.json").write_text(json.dumps(case["config"], indent=2) + "\n")
            inputs = {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
            argv = [str(exe), "--project", "tsconfig.json", "--pretty", "false"]
            result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
            output = result.stdout + result.stderr
            diagnostics = sorted((Path(f).name, int(l), int(c), int(n)) for f,l,c,n in
                re.findall(r"([^\r\n]+?)\((\d+),(\d+)\): error TS(\d+):", output))
            unchanged = inputs == {str(p.relative_to(directory)): digest(p) for p in directory.rglob("*") if p.is_file()}
            passed = (result.returncode == (1 if expected else 0) and diagnostics == expected and unchanged
                      and len(re.findall(r"error TS\d+:", output)) == len(expected))
            summary["observations"].append({"case": name, "engine": engine, "command": argv,
                "input_hashes": inputs, "exit": result.returncode, "stdout": result.stdout,
                "stderr": result.stderr, "diagnostics": diagnostics, "passed": passed})
            if not passed:
                summary["failures"].append(f"{name}/{engine}: {diagnostics}, exit {result.returncode}")
            save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} declaration index observations passed")


if __name__ == "__main__":
    main()
