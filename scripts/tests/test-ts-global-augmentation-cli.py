#!/usr/bin/env python3
"""Compare global augmentation aliases with native TypeScript under run-bounded.pl."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess


def alias(module: str = "./tools", target: str = "Module") -> str:
    return f'import * as Module from "{module}";\ndeclare global {{ export import Api = {target}; }}\n'


CASES = {
    "ambient-constructor": (
        {"node_modules/tool-api/index.d.ts": 'declare module "tool-api" { class Item { constructor(value: string); value: string; } }\n',
         "augmentation.d.ts": alias("tool-api")},
        "const item = new Api.Item('ok'); const value: string = item.value;\nexport {};\n",
        "const wrong: number = item.value;\n", (3, 7, 2322),
    ),
    "ambient-class-type": (
        {"node_modules/tool-api/index.d.ts": 'declare module "tool-api" { class Item { constructor(value: string); value: string; } }\n',
         "augmentation.d.ts": alias("tool-api")},
        "declare const item: Api.Item;\nconst value: string = item.value;\n",
        "const wrong: number = item.value;\n", (3, 7, 2322),
    ),
    "ambient-function": (
        {"node_modules/tool-api/index.d.ts": 'declare module "tool-api" { function convert(value: number): string; } declare module "other-api" { function convert(value: string): number; }\n',
         "augmentation.d.ts": alias("tool-api")},
        "const text: string = Api.convert(1);\nexport {};\n",
        "const wrong: number = Api.convert(1);\n", (3, 7, 2322),
    ),
    "ambient-generic-type": (
        {"node_modules/tool-api/index.d.ts": 'declare module "tool-api" { interface Box<T = number> { value: T; } }\n',
         "augmentation.d.ts": alias("tool-api")},
        "declare const box: Api.Box<number>;\nconst value: number = box.value;\n",
        "const wrong: string = box.value;\n", (3, 7, 2322),
    ),
    "ambient-missing-member": (
        {"node_modules/tool-api/index.d.ts": 'declare module "tool-api" { function convert(value: number): string; }\n',
         "augmentation.d.ts": alias("tool-api")},
        "const text: string = Api.convert(1);\nexport {};\n",
        "Api.missing;\n", (3, 5, 2339),
    ),
    "qualified-default-type": (
        {"tools.d.ts": "export interface Box<T = number> { value: T; }\n",
         "augmentation.d.ts": alias()},
        "declare const box: Api.Box;\nconst value: number = box.value;\n",
        "const wrong: string = box.value;\n", (3, 7, 2322),
    ),
    "function": (
        {"tools.d.ts": "export declare function convert(value: number): string;\n",
         "augmentation.d.ts": alias()},
        "const text: string = Api.convert(1);\nexport {};\n",
        "const wrong: number = Api.convert(1);\n", (3, 7, 2322),
    ),
    "generic-function": (
        {"tools.d.ts": "export declare function identity<T>(value: T): T;\n",
         "augmentation.d.ts": alias()},
        "const text: string = Api.identity('ok');\nexport {};\n",
        "const wrong: number = Api.identity('bad');\n", (3, 7, 2322),
    ),
    "constructor": (
        {"tools.d.ts": "export declare class Item { constructor(value: string); value: string; }\n",
         "augmentation.d.ts": alias()},
        "const item = new Api.Item('ok'); const text: string = item.value;\nexport {};\n",
        "const wrong: number = item.value;\n", (3, 7, 2322),
    ),
    "qualified-alias": (
        {"tools.d.ts": "export declare namespace Nested { function convert(value: number): string; }\n",
         "augmentation.d.ts": alias(target="Module.Nested")},
        "const text: string = Api.convert(1);\nexport {};\n",
        "const wrong: number = Api.convert(1);\n", (3, 7, 2322),
    ),
    "star-reexport": (
        {"tools.d.ts": "export declare function convert(value: number): string;\n",
         "barrel.d.ts": 'export * from "./tools";\n',
         "augmentation.d.ts": alias("./barrel")},
        "const text: string = Api.convert(1);\nexport {};\n",
        "const wrong: number = Api.convert(1);\n", (3, 7, 2322),
    ),
    "qualified-type": (
        {"tools.d.ts": "export interface Box<T> { value: T; }\n",
         "augmentation.d.ts": alias()},
        "declare const box: Api.Box<number>;\nconst value: number = box.value;\n",
        "const wrong: string = box.value;\n", (3, 7, 2322),
    ),
    "missing-member": (
        {"tools.d.ts": "export declare function convert(value: number): string;\n",
         "augmentation.d.ts": alias()},
        "const text: string = Api.convert(1);\nexport {};\n",
        "Api.missing;\n", (3, 5, 2339),
    ),
    "wrong-argument": (
        {"tools.d.ts": "export declare function convert(value: number): string;\n",
         "augmentation.d.ts": alias()},
        "const text: string = Api.convert(1);\nexport {};\n",
        "Api.convert('bad');\n", (3, 13, 2345),
    ),
}


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
    globals_source = runpy.run_path(str(Path(__file__).with_name("test-ts-recursive-interface-cli.py")))['GLOBALS']
    compilers = {"home": args.home.resolve(), "reference": args.reference.resolve()}
    summary = {"scope": "global namespace augmentation aliases, module values and types",
               "compiler_hashes": {name: digest(exe) for name, exe in compilers.items()},
               "observations": [], "failures": [], "passed": False}

    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    save()
    for name, (files, valid, negative, error) in CASES.items():
        for skip in (False, True):
            for planted in (False, True):
                expected = [("main.ts", *error)] if planted else []
                for engine, exe in compilers.items():
                    directory = root / name / str(skip) / ("negative" if planted else "valid") / engine
                    directory.mkdir(parents=True)
                    for file, source in files.items():
                        target = directory / file
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text(source)
                    (directory / "globals.d.ts").write_text(globals_source)
                    (directory / "main.ts").write_text(valid + (negative if planted else ""))
                    (directory / "tsconfig.json").write_text(json.dumps({
                        "compilerOptions": {"noLib": True, "noEmit": True, "strict": True,
                                            "skipLibCheck": skip, "target": "ESNext", "module": "ESNext",
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
                    passed = (result.returncode == (1 if planted else 0) and diagnostics == expected
                              and unchanged and len(re.findall(r"error TS\d+:", output)) == len(expected))
                    summary["observations"].append({
                        "case": name, "skipLibCheck": skip, "variant": "negative" if planted else "valid",
                        "engine": engine, "command": argv, "cwd": str(directory), "input_hashes": inputs,
                        "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                        "diagnostics": diagnostics, "passed": passed,
                    })
                    if not passed:
                        summary["failures"].append(f"{name}/{skip}/{planted}/{engine}: {diagnostics}, exit {result.returncode}")
                    save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} global augmentation observations passed")


if __name__ == "__main__":
    main()
