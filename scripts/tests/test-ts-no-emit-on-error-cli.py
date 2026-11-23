#!/usr/bin/env python3
"""Compare noEmitOnError diagnostics and output selection with both installed TypeScript CLIs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


BAD = 'export const x: number = "wrong";\n'
CASES = {
    "valid": ({"noEmitOnError": True}, {"main.ts": 'export const x: number = 1;\n'}, [], 0, ["main.js"]),
    "semantic": ({"noEmitOnError": True}, {"main.ts": BAD}, [], 1, []),
    "syntax": ({"noEmitOnError": True}, {"main.ts": "const x = ;\n"}, [], 1, []),
    "multi-file": ({"noEmitOnError": True}, {
        "good.ts": 'export const good: number = 1;\n',
        "bad.ts": 'export const bad: number = "wrong";\n',
    }, [], 1, []),
    "declarations-and-maps": ({"noEmitOnError": True, "declaration": True,
                                "sourceMap": True, "declarationMap": True},
                               {"main.ts": BAD}, [], 1, []),
    "cli-enable": ({"noEmitOnError": False}, {"main.ts": BAD},
                   ["--noEmitOnError", "true"], 1, []),
    "cli-disable": ({"noEmitOnError": True}, {"main.ts": BAD},
                    ["--noEmitOnError", "false"], 2, ["main.js"]),
    "ordinary-emit": ({}, {"main.ts": BAD}, [], 2, ["main.js"]),
    # Native 7 and classic 5.7 differ on noEmit's error status. The shared
    # noEmitOnError contract here is that neither writes an output file.
    "no-emit": ({"noEmitOnError": True, "noEmit": True},
                {"main.ts": BAD}, [], {"home": 2, "native": 1, "classic": 2}, []),
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--classic", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    compilers = {"home": args.home.resolve(), "native": args.native.resolve(),
                 "classic": args.classic.resolve()}
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    summary = {"compiler_hashes": {name: digest(path) for name, path in compilers.items()},
               "observations": [], "failures": [], "passed": False}

    def save() -> None:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    save()
    for case, (options, files, flags, expected_exit, expected_outputs) in CASES.items():
        streams = {}
        for engine, executable in compilers.items():
            directory = root / case / engine
            directory.mkdir(parents=True)
            for filename, source in files.items():
                (directory / filename).write_text(source)
            (directory / "tsconfig.json").write_text(json.dumps({
                "compilerOptions": {"strict": True, "target": "ESNext", "module": "ESNext", **options},
                "files": list(files),
            }, indent=2) + "\n")
            inputs = {path.name: digest(path) for path in directory.iterdir()}
            argv = (["node", str(executable)] if engine == "classic" else [str(executable)]) + [
                "--project", "tsconfig.json", "--pretty", "false", *flags,
            ]
            result = subprocess.run(argv, cwd=directory, capture_output=True, text=True, timeout=45)
            outputs = sorted(path.name for path in directory.iterdir() if path.name not in inputs)
            unchanged = all(digest(directory / name) == hash_value for name, hash_value in inputs.items())
            status = expected_exit[engine] if isinstance(expected_exit, dict) else expected_exit
            passed = result.returncode == status and outputs == expected_outputs and unchanged
            summary["observations"].append({
                "case": case, "engine": engine, "command": argv, "cwd": str(directory),
                "input_hashes": inputs, "exit": result.returncode, "stdout": result.stdout,
                "stderr": result.stderr, "outputs": outputs, "passed": passed,
            })
            if not passed:
                summary["failures"].append(
                    f"{case}/{engine}: exit {result.returncode} (want {status}), "
                    f"outputs {outputs} (want {expected_outputs}), unchanged={unchanged}"
                )
            streams[engine] = (result.stdout, result.stderr)
            save()
        if streams["home"] != streams["native"] or streams["home"] != streams["classic"]:
            summary["failures"].append(f"{case}: diagnostic stdout/stderr differ from an official compiler")
            save()
    summary["passed"] = not summary["failures"]
    save()
    if summary["failures"]:
        raise SystemExit("\n".join(summary["failures"]))
    print(f"All {len(summary['observations'])} noEmitOnError observations passed")


if __name__ == "__main__":
    main()
