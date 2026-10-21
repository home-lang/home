#!/usr/bin/env python3
"""Compare declaration-output CLI contracts with an installed TypeScript compiler.

Run under scripts/run-bounded.pl. All inputs, outputs, and watch edits belong to
an isolated directory; original project sources and dependency trees are unused.
The artifact comparisons cover JS/declaration selection, not build-info format
or byte-exact source-map mappings, which have separate compatibility gaps.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

GLOBALS = "\n".join(
    f"interface {name} {{}}"
    for name in (
        "Array<T>", "Boolean", "CallableFunction", "Function", "IArguments",
        "NewableFunction", "Number", "Object", "RegExp", "String",
    )
) + "\n"
SOURCE = "export const answer: number = 42;\n"


def artifacts(directory: Path) -> list[str]:
    return sorted(
        str(path.relative_to(directory))
        for path in directory.rglob("*")
        if path.is_file()
        and (path.suffix in (".js", ".map") or path.name.endswith(".d.ts"))
        and path.name != "globals.d.ts"
        and not (path == directory / "index.js" and not (directory / "index.ts").exists())
    )


def diagnostics(output: str) -> list[int]:
    return sorted(int(code) for code in re.findall(r"error TS(\d+):", output))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True,
                        help="Native tsc/tsgo executable or tsc.js")
    parser.add_argument("--runtime", default="bun", help="Runtime for a JS reference")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    home = [str(args.home.resolve())]
    reference = ([args.runtime] if args.reference.suffix == ".js" else []) + [str(args.reference.resolve())]
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="home-declaration-cli-"))
    root.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    summary = {
        "home_sha256": hashlib.sha256(args.home.read_bytes()).hexdigest(),
        "reference_sha256": hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        "contracts": records,
        "scope": "JS/declaration artifact selection, type checking, build freshness/clean, and watch updates; excludes build-info encoding and source-map mapping parity",
        "passed": False,
    }

    def invoke(compiler: list[str], directory: Path, flags: list[str]) -> dict:
        result = subprocess.run(compiler + flags, cwd=directory, capture_output=True, text=True, timeout=45)
        record = {"command": compiler + flags, "cwd": str(directory), "exit": result.returncode,
                  "stdout": result.stdout, "stderr": result.stderr, "artifacts": artifacts(directory)}
        records.append(record)
        return record

    def setup(name: str, engine: str, overrides: dict, source: str = SOURCE, javascript: bool = False) -> Path:
        directory = root / name / engine
        directory.mkdir(parents=True, exist_ok=False)
        filename = "index.js" if javascript else "index.ts"
        (directory / filename).write_text(source)
        (directory / "globals.d.ts").write_text(GLOBALS)
        options = {"noLib": True, "target": "ESNext", "module": "ESNext", "declaration": True,
                   "emitDeclarationOnly": True, "outDir": "js", "declarationDir": "types"}
        options.update(overrides)
        (directory / "tsconfig.json").write_text(json.dumps(
            {"compilerOptions": options, "files": ["globals.d.ts", filename]}, indent=2) + "\n")
        return directory

    def compare(name: str, overrides: dict, flags: list[str], expected: list[str], codes: list[int] | None = None,
                source: str = SOURCE, javascript: bool = False, expected_exit: int | None = None) -> None:
        expected_codes = codes or []
        observations = []
        for engine, compiler in (("reference", reference), ("home", home)):
            directory = setup(name, engine, overrides, source, javascript)
            result = invoke(compiler, directory, ["-p", "tsconfig.json", "--pretty", "false"] + flags)
            assert diagnostics(result["stdout"]) == expected_codes, result
            assert result["artifacts"] == sorted(expected), result
            assert result["stderr"] == "", result
            result["diagnostic_headers"] = [
                line.replace(str(directory) + os.sep, "")
                for line in result["stdout"].splitlines() if re.search(r"error TS\d+:", line)
            ]
            observations.append(result)
            if source == SOURCE and any(path.endswith(".d.ts") for path in expected):
                dts = next(directory / path for path in expected if path.endswith(".d.ts"))
                assert "answer: number" in dts.read_text(), dts.read_text()
            if javascript:
                assert (directory / "index.js").read_text() == source
        assert observations[0]["diagnostic_headers"] == observations[1]["diagnostic_headers"], observations
        assert observations[0]["exit"] == observations[1]["exit"], observations
        expected_status = expected_exit if expected_exit is not None else (2 if expected_codes and expected else 1 if expected_codes else 0)
        assert observations[0]["exit"] == expected_status, observations

    try:
        compare("config-only", {}, [], ["types/index.d.ts"])
        compare("cli-override", {"emitDeclarationOnly": False, "declaration": False},
                ["--declaration", "--emitDeclarationOnly", "--declarationDir", "cli-types"], ["cli-types/index.d.ts"])
        compare("explicit-false", {"sourceMap": True, "declarationMap": True},
                ["--emitDeclarationOnly", "false", "--sourceMap", "false", "--declarationMap", "false",
                 "--declarationDir", "alternate"], ["js/index.js", "alternate/index.d.ts"])
        compare("no-emit", {}, ["--noEmit"], [])
        compare("type-error", {}, [], ["types/index.d.ts"], [2322],
                'export const answer: number = "wrong";\n')
        compare("type-error-no-emit", {}, ["--noEmit"], [], [2322],
                'export const answer: number = "wrong";\n')
        compare("declaration-map", {"sourceMap": True, "declarationMap": True}, [],
                ["types/index.d.ts", "types/index.d.ts.map"])
        compare("missing-declaration", {"declaration": False, "declarationDir": None, "noEmit": True},
                [], [], [5069], expected_exit=2)
        compare("missing-declaration-list", {"declaration": False, "declarationDir": None, "noEmit": True},
                ["--listFilesOnly"], [], [5069], expected_exit=1)
        for option_name, invalid_option, code in (
            ("removed-option", {"outFile": "bundle.js"}, 5102),
            ("check-js-dependency", {"checkJs": True, "allowJs": False}, 5052),
        ):
            for no_emit in (False, True):
                compare(f"{option_name}-no-emit-{no_emit}", {
                    "declaration": False, "declarationDir": None, "emitDeclarationOnly": False,
                    "noEmit": no_emit, **invalid_option,
                }, [], [] if no_emit else ["js/index.js"], [code], expected_exit=1 if no_emit else 2)
                compare(f"{option_name}-list-no-emit-{no_emit}", {
                    "declaration": False, "declarationDir": None, "emitDeclarationOnly": False,
                    "noEmit": no_emit, **invalid_option,
                }, ["--listFilesOnly"], [], [code], expected_exit=1)
        compare("javascript-input", {"allowJs": True, "outDir": None}, [], ["types/index.d.ts"],
                source="export const answer = 42;\n", javascript=True)

        for engine, compiler in (("reference", reference), ("home", home)):
            directory = setup("build-and-clean", engine, {"composite": True})
            first = invoke(compiler, directory, ["--build", "tsconfig.json", "--pretty", "false"])
            assert first["exit"] == 0 and first["stderr"] == "" and diagnostics(first["stdout"]) == [], first
            assert first["artifacts"] == ["types/index.d.ts"], first
            assert "answer: number" in (directory / "types/index.d.ts").read_text(), first
            mtime = (directory / "types/index.d.ts").stat().st_mtime_ns
            second = invoke(compiler, directory, ["--build", "tsconfig.json", "--verbose", "--pretty", "false"])
            assert second["exit"] == 0 and "is up to date" in second["stdout"], second
            assert (directory / "types/index.d.ts").stat().st_mtime_ns == mtime, second
            # Cleaning a declaration-only project must leave another tool's JS intact.
            (directory / "js").mkdir(exist_ok=True)
            sentinel = directory / "js/index.js"
            sentinel.write_text("// owned by another build tool\n")
            cleaned = invoke(compiler, directory, ["--build", "tsconfig.json", "--clean", "--pretty", "false"])
            assert cleaned["exit"] == 0 and not (directory / "types/index.d.ts").exists(), cleaned
            assert sentinel.read_text() == "// owned by another build tool\n", cleaned

        # Seed both clean controls with genuine reference outputs, including a
        # imported source omitted from the explicit root list and build maps.
        for engine, compiler in (("reference", reference), ("home", home)):
            directory = setup("clean-reference-artifacts", engine,
                              {"composite": False, "declarationMap": True, "moduleResolution": "bundler"},
                              'export { value } from "./helper";\n')
            (directory / "helper.ts").write_text("export const value: number = 42;\n")
            seeded = invoke(reference, directory, ["--build", "tsconfig.json", "--pretty", "false"])
            assert seeded["exit"] == 0, seeded
            assert seeded["artifacts"] == ["types/helper.d.ts", "types/helper.d.ts.map", "types/index.d.ts", "types/index.d.ts.map"], seeded
            build_info = list(directory.rglob("*.tsbuildinfo"))
            assert len(build_info) == 1, seeded
            originals = {name: (directory / name).read_bytes() for name in ("globals.d.ts", "index.ts", "helper.ts", "tsconfig.json")}
            cleaned = invoke(compiler, directory, ["--build", "tsconfig.json", "--clean", "--pretty", "false"])
            assert cleaned["exit"] == 0 and cleaned["artifacts"] == ["types/helper.d.ts", "types/helper.d.ts.map"], cleaned
            assert all(not path.exists() for path in build_info), cleaned
            assert all((directory / name).read_bytes() == data for name, data in originals.items()), cleaned

        for engine, compiler in (("reference", reference), ("home", home)):
            directory = setup("clean-protects-js-source", engine,
                              {"allowJs": True, "declaration": False, "emitDeclarationOnly": False,
                               "outDir": None, "declarationDir": None},
                              source="export const answer = 42;\n", javascript=True)
            original = (directory / "index.js").read_bytes()
            cleaned = invoke(compiler, directory, ["--build", "tsconfig.json", "--clean", "--pretty", "false"])
            assert cleaned["exit"] == 0 and (directory / "index.js").read_bytes() == original, cleaned

        for label, watch_flag in (("canonical", "--watch"), ("short", "-w"), ("double-short", "--w"),
                                  ("single-long", "-watch"), ("case", "--WATCH")):
            for engine, compiler in (("reference", reference), ("home", home)):
                directory = setup("watch-" + label, engine, {})
                log_path = directory / "watch.log"
                command = compiler + [watch_flag, "-p", "tsconfig.json", "--pretty", "false"]
                with log_path.open("w") as log:
                    process = subprocess.Popen(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        def await_declaration(needle: str) -> None:
                            deadline = time.monotonic() + 30
                            while time.monotonic() < deadline:
                                assert process.poll() is None, log_path.read_text()
                                dts = directory / "types/index.d.ts"
                                if dts.exists() and needle in dts.read_text():
                                    assert artifacts(directory) == ["types/index.d.ts"], artifacts(directory)
                                    return
                                time.sleep(0.05)
                            raise AssertionError(log_path.read_text())
                        await_declaration("answer: number")
                        # Emission can finish before the compiler installs its
                        # watchers. Wait for readiness before making the edit.
                        ready_deadline = time.monotonic() + 30
                        while "Watching for file changes." not in log_path.read_text():
                            assert process.poll() is None, log_path.read_text()
                            if time.monotonic() >= ready_deadline:
                                raise AssertionError(log_path.read_text())
                            time.sleep(0.05)
                        (directory / "index.ts").write_text('export const answer: string = "updated";\n')
                        await_declaration("answer: string")
                    finally:
                        try:
                            os.killpg(process.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                records.append({"command": command, "cwd": str(directory), "stdout": log_path.read_text(),
                                "artifacts": artifacts(directory), "watch_reemitted": True})
        summary["passed"] = True
        print(f"Declaration CLI contracts passed ({len(records)} compiler observations); evidence: {root}")
    finally:
        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
