#!/usr/bin/env python3
"""Exercise the real opt-in survey gates with temporary corpus controls.

Build the conformance artifact with -Dts-conformance-test-filter=opt-in, then
pass its .zig-cache/o/.../test path via --test-binary. Every invocation uses the
normal machine lock and memory supervisor. Upstream corpora are never edited.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def run_control(
    binary: Path,
    label: str,
    family: str,
    root: Path,
    expected_exit: int,
    marker: str,
    output: Path | None,
    start: str = "0",
) -> None:
    env = os.environ.copy()
    for name in list(env):
        if name.startswith(("HOME_TS_CONFORMANCE_", "HOME_TS_COMPILER_")):
            del env[name]
    env.update({
        "HOME_TS_SUITE_ROOT": str(root),
        "HOME_RUN_MAX_MB": "3840",
        "HOME_RUN_LABEL": label,
        f"HOME_TS_{family}_FULL": "1",
        f"HOME_TS_{family}_EXACT": "1",
        f"HOME_TS_{family}_LIMIT": "1",
        f"HOME_TS_{family}_START": start,
    })
    result = subprocess.run(
        ["perl", str(ROOT / "scripts/run-bounded.pl"), "120", str(binary)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if output is not None:
        with output.open("a", encoding="utf-8") as log:
            log.write(f"CONTROL {label}: exit={result.returncode}\n{result.stdout}\n")
    if result.returncode != expected_exit or marker not in result.stdout:
        raise AssertionError(
            f"{label}: expected exit {expected_exit} and {marker!r}; "
            f"got exit {result.returncode}\n{result.stdout}"
        )
    print(f"{label}: expected exit {expected_exit}, marker verified", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-binary", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="retain full control diagnostics")
    args = parser.parse_args()
    binary = args.test_binary.resolve(strict=True)
    if args.output is not None:
        args.output.write_text("", encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="home-ts-survey-controls-") as directory:
        root = Path(directory)
        for family in ("CONFORMANCE", "COMPILER"):
            run_control(binary, f"missing-{family.lower()}-corpus", family,
                        root / "missing", 1, "MissingTypeScriptCorpus", args.output)
            cases = root / "_submodules/TypeScript/tests/cases" / family.lower()
            baselines = root / "testdata/baselines/reference/submodule" / family.lower()
            cases.mkdir(parents=True)
            baselines.mkdir(parents=True)
            run_control(binary, f"empty-{family.lower()}-corpus", family,
                        root, 1, "total=0", args.output)
            source = cases / "required-corpus-control.ts"
            source.write_text("const value: number = 1;\n", encoding="utf-8")
            run_control(binary, f"valid-{family.lower()}-corpus", family,
                        root, 0, "passed=1 failed=0", args.output)
            run_control(binary, f"empty-{family.lower()}-range", family,
                        root, 1, "total=0", args.output, "999999")
            source.write_text('const value: number = "wrong";\n', encoding="utf-8")
            run_control(binary, f"mismatched-{family.lower()}-corpus", family,
                        root, 1, "passed=0 failed=1", args.output)


if __name__ == "__main__":
    main()
