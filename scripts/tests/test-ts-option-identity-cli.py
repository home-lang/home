#!/usr/bin/env python3
"""Compare normal-mode option identities and boolean overrides with native tsc.

Run under scripts/run-bounded.pl. Each compiler owns an isolated fixture;
input hashes, emitted files, diagnostics and statuses must match. Watch
lifecycle controls for these aliases live in test-ts-declaration-cli.py.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess
import tempfile

HELPERS = runpy.run_path(str(Path(__file__).with_name("test-ts-list-files-cli.py")))
GLOBALS = HELPERS["GLOBALS"]
hashes = HELPERS["hashes"]
SOURCE = "export const value: number = 1;\n"


def cases() -> list[dict]:
    rows = []

    def add(name, flags, *, emitted=(), codes=(), status=0, options=None, files=None, alternate=False):
        rows.append(dict(name=name, flags=flags, emitted=list(emitted), codes=list(codes), status=status,
                         options=options or {}, files=files or {"main.ts": SOURCE}, alternate=alternate))

    add("no-emit-true", ["--noEmit", "true"])
    add("no-emit-false", ["--noEmit", "false"], emitted=("main.js",))
    add("no-emit-single-dash", ["-noEmit", "false"], emitted=("main.js",))
    add("no-emit-case", ["--NOEMIT", "false"], emitted=("main.js",))
    for flag, name in (("--watch", "long"), ("-watch", "single-long"), ("-w", "short"),
                       ("--w", "double-short"), ("--WATCH", "case"), ("--W", "short-case")):
        add("watch-false-" + name, [flag, "false"])
    nullable = {"main.ts": "export const value: string = null;\n"}
    add("strict-false", ["--strict", "false"], files=nullable)
    add("strict-true", ["--strict", "true"], files=nullable, options={"strict": False}, codes=(2322,), status=1)
    add("trace-false", ["--traceResolution", "false"], options={"traceResolution": True}, files={
        "main.ts": "export { value } from './helper';\n", "helper.ts": SOURCE,
    })
    add("project-short-case", ["--P", "Project.Case.JSON"], alternate=True, emitted=("main.js",))
    add("project-custom-file", ["--project", "Project.Case.custom"], alternate="Project.Case.custom", emitted=("main.js",))
    add("project-json-directory", ["--project", "as.json"], alternate="as.json/tsconfig.json", emitted=("main.js",))
    add("target-short-negative", ["--T", "invalid-target-value"], codes=(6046,), status=1)
    add("module-case-negative", ["--MODULE", "invalid-module-value"], codes=(6046,), status=1)
    add("boolean-actions-false", [flag for name in (
        "--listFiles", "--listFilesOnly", "--explainFiles", "--showConfig", "--init", "--help", "--all", "--version",
    ) for flag in (name, "false")])
    return rows


def invoke(command: list[str], directory: Path) -> dict:
    process = subprocess.Popen(command, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    return dict(command=command, exit=process.returncode, timed_out=timed_out, stdout=stdout, stderr=stderr)


def diagnostic_positions(output: str, directory: Path) -> list:
    positions = []
    for line in output.splitlines():
        code = re.search(r"error TS(\d+):", line)
        if not code:
            continue
        location = re.match(r"(.+?)\((\d+),(\d+)\): error TS", line)
        if location:
            filename = location[1].replace(str(directory) + os.sep, "")
            positions.append([filename, int(location[2]), int(location[3]), int(code[1])])
        else:
            positions.append(["", 0, 0, int(code[1])])
    return sorted(positions)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--reference-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    assert args.reference_only or args.home, "--home is required unless --reference-only"
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="home-option-identity-"))
    root.mkdir(parents=True, exist_ok=True)
    engines = [("reference", args.reference.resolve())]
    if not args.reference_only:
        engines.append(("home", args.home.resolve()))
    summary = dict(passed=False, reference_only=args.reference_only, observations=[],
                   binaries={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in engines})
    try:
        for case in cases():
            paired = []
            for engine, executable in engines:
                directory = root / case["name"] / engine
                directory.mkdir(parents=True, exist_ok=False)
                options = {"noLib": True, "types": [], "target": "ESNext", "module": "ESNext",
                           "moduleResolution": "bundler", "strict": True, "noEmit": True, **case["options"]}
                config = dict(compilerOptions=options, files=["globals.d.ts", "main.ts"])
                files = {"globals.d.ts": GLOBALS, **case["files"], "tsconfig.json": json.dumps(config)}
                if case["alternate"]:
                    alternate = "Project.Case.JSON" if case["alternate"] is True else case["alternate"]
                    alternate_parent = directory / Path(alternate).parent
                    alternate_roots = [os.path.relpath(directory / name, alternate_parent) for name in config["files"]]
                    files[alternate] = json.dumps({**config, "files": alternate_roots,
                                                 "compilerOptions": {**options, "noEmit": False}})
                for name, source in files.items():
                    path = directory / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(source)
                before = hashes(directory)
                result = invoke([str(executable), "-p", "tsconfig.json", "--pretty", "false", *case["flags"]], directory)
                after = hashes(directory)
                result.update(case=case["name"], engine=engine, input_hashes=before,
                              unchanged=all(after.get(name) == digest for name, digest in before.items()),
                              emitted=sorted(after.keys() - before.keys()),
                              diagnostics=diagnostic_positions(result["stdout"], directory))
                summary["observations"].append(result)
                assert not result["timed_out"] and not result["stderr"] and result["unchanged"], result
                assert result["exit"] == case["status"], result
                assert result["emitted"] == sorted(case["emitted"]), result
                assert sorted(row[3] for row in result["diagnostics"]) == sorted(case["codes"]), result
                if not case["codes"]:
                    assert result["stdout"] == "", result
                for name in result["emitted"]:
                    assert (directory / name).stat().st_size > 0, result
                paired.append(result)
            if len(paired) == 2:
                for key in ("input_hashes", "exit", "diagnostics", "emitted"):
                    assert paired[0][key] == paired[1][key], (key, paired)
        summary["passed"] = True
        print(f"Option identity contracts passed: {len(cases())} cases, {len(summary['observations'])} observations")
    finally:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
