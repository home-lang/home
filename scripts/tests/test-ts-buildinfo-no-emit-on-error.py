#!/usr/bin/env python3
"""Compare --build noEmitOnError lifecycle and retained state with both installed TypeScript SDKs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


WRONG = 'export const x: number = "wrong";\n'
CORRECT = 'export const x: number = 1;\n'
SYNTAX = 'export const x = ;\n'
OPTIONS = {"composite": True, "strict": True, "noEmitOnError": True,
           "target": "ESNext", "module": "ESNext"}


def diagnostic_records(info: dict) -> list[dict]:
    return [diagnostic
            for entry in info.get("semanticDiagnosticsPerFile", [])
            if isinstance(entry, list) and len(entry) > 1
            for diagnostic in entry[1]]


def artifacts(directory: Path) -> list[str]:
    return sorted(str(path.relative_to(directory)) for path in directory.rglob("*")
                  if path.is_file() and path.name not in {"main.ts", "tsconfig.json"})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--classic", required=True, type=Path)
    parser.add_argument("--native", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    compilers = {"home": args.home.resolve(), "classic": args.classic.resolve(),
                 "native": args.native.resolve()}
    for name, expected in (("classic", "Version 5.7.3"), ("native", "Version 7.0.2")):
        result = subprocess.run([str(compilers[name]), "--version"], capture_output=True,
                                text=True, timeout=15)
        assert result.returncode == 0 and result.stdout.strip() == expected, (name, result)

    observations = []
    for case, source in (("semantic", WRONG), ("syntax", SYNTAX)):
        for engine in compilers:
            directory = root / case / engine
            directory.mkdir(parents=True)
            (directory / "main.ts").write_text(source)
            (directory / "tsconfig.json").write_text(json.dumps({
                "compilerOptions": OPTIONS, "files": ["main.ts"]}, indent=2) + "\n")

        phases = ("initial-error", "unchanged-error", "corrected", "unchanged-clean") if case == "semantic" else ("initial-error",)
        for phase in phases:
            streams = {}
            for engine, command in compilers.items():
                directory = root / case / engine
                if phase == "corrected":
                    (directory / "main.ts").write_text(CORRECT)
                before = {str(path.relative_to(directory)): path.stat().st_mtime_ns
                          for path in directory.rglob("*") if path.is_file()}
                result = subprocess.run([str(command), "--build", "tsconfig.json", "--pretty", "false"],
                                        cwd=directory, capture_output=True, text=True, timeout=45)
                streams[engine] = (result.returncode, result.stdout, result.stderr)
                info_path = directory / "tsconfig.tsbuildinfo"
                assert info_path.exists(), (case, phase, engine, "missing build info", streams[engine])
                info = json.loads(info_path.read_text())
                found = artifacts(directory)
                error_phase = phase.endswith("error")
                expected_files = ["tsconfig.tsbuildinfo"] if error_phase else ["main.d.ts", "main.js", "tsconfig.tsbuildinfo"]
                assert found == expected_files, (case, phase, engine, found)
                records = diagnostic_records(info)
                pending = bool(info.get("affectedFilesPendingEmit"))
                signatures = bool(info.get("emitSignatures"))
                assert pending == error_phase and signatures == error_phase, (case, phase, engine, info)
                if case == "semantic" and error_phase:
                    assert len(records) == 1 and records[0]["code"] == 2322, (engine, records)
                    if engine == "native":
                        assert (records[0]["pos"], records[0]["end"]) == (13, 14), records
                    else:
                        assert (records[0]["start"], records[0]["length"]) == (13, 1), records
                else:
                    assert not records, (case, phase, engine, records)
                if case == "syntax":
                    assert info.get("errors") is True, (engine, info)
                after = {str(path.relative_to(directory)): path.stat().st_mtime_ns
                         for path in directory.rglob("*") if path.is_file()}
                if phase == "unchanged-clean":
                    assert all(after[name] == before[name] for name in ("main.js", "main.d.ts")), (engine, before, after)
                observations.append({"case": case, "phase": phase, "engine": engine,
                                     "exit": result.returncode, "stdout": result.stdout,
                                     "stderr": result.stderr, "artifacts": found,
                                     "pending": pending, "emit_signatures": signatures,
                                     "diagnostics": records})
            assert streams["home"] == streams["classic"] == streams["native"], (case, phase, streams)
            assert streams["home"][0] == (1 if phase.endswith("error") else 0), (case, phase, streams)

    (root / "summary.json").write_text(json.dumps(observations, indent=2) + "\n")
    print(f"{len(observations)} build-info lifecycle observations matched")


if __name__ == "__main__":
    main()
