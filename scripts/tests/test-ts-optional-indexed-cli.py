#!/usr/bin/env python3
"""Compare optional indexed read and write types with native TypeScript under run-bounded.pl."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess


CASES = {
    'optional-number': ({},
        'interface O { value?: number }\ndeclare function accept(v: O["value"]): void;\naccept(undefined);\naccept(1);\n',
        'accept("wrong");\n',
        (5, 8, 2345)),
    'optional-function': ({},
        'interface O { run?: (value: number) => string }\ndeclare function accept(v: O["run"]): void;\naccept(undefined);\naccept((v: number) => "ok");\n',
        'accept((v: string) => "wrong");\n',
        (5, 8, 2345)),
    'optional-nested': ({},
        'interface O { inner: { value?: number } }\ndeclare function accept(v: O["inner"]["value"]): void;\naccept(undefined);\n',
        'accept("wrong");\n',
        (4, 8, 2345)),
    'required-number': ({},
        'interface O { value: number }\ndeclare function accept(v: O["value"]): void;\naccept(1);\n',
        'accept(undefined);\n',
        (4, 8, 2345)),
    'optional-union-key': ({},
        'interface O { optional?: number; required: number }\ndeclare function accept(v: O["optional" | "required"]): void;\naccept(undefined);\n',
        'accept("wrong");\n',
        (4, 8, 2345)),
    'exact-write': ({},
        'interface O { value?: number }\ndeclare let o: O;\no["value"] = 1;\n',
        'o["value"] = undefined;\n',
        (4, 1, 2322)),
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
    summary = {"scope": "optional indexed access types and exact optional writes",
               "compiler_hashes": {name: digest(exe) for name, exe in compilers.items()},
               "observations": [], "failures": [], "passed": False}

    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    save()
    for name, (files, valid, negative, error) in CASES.items():
        for exact in (False, True):
            for planted in (False, True):
                expected = [("main.ts", *error)] if planted and (name != "exact-write" or exact) else []
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
    print(f"All {len(summary['observations'])} optional indexed observations passed")


if __name__ == "__main__":
    main()
