#!/usr/bin/env python3
"""Measure #1046's function-local lookup scaling on identical TypeScript inputs."""

import argparse
import json
import resource
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def source(statements: int, initialized: bool) -> str:
    lines = ["declare function take(value: number): number;", "function probe() {", "  let v" + (" = 0;" if initialized else ";")]
    lines.extend(f"  const t{i} = take(v = {i}) + v;" for i in range(statements))
    lines.append("}")
    return "\n".join(lines) + "\n"


def run(binary: Path, file: Path) -> tuple[float, float, bytes, bytes, int]:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    completed = subprocess.run(
        [str(binary), "--strict", "--target", "es2022", "--noEmit", "--pretty", "false", str(file)],
        cwd=file.parent,
        capture_output=True,
        timeout=120,
        check=False,
    )
    elapsed = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = after.ru_utime - before.ru_utime
    return elapsed, cpu, completed.stdout, completed.stderr, completed.returncode


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--tsc", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    binaries = {"Home": args.home.resolve(), "TypeScript": args.tsc.resolve()}
    for binary in binaries.values():
        if not binary.is_file():
            parser.error(f"missing binary: {binary}")

    rows = []
    with tempfile.TemporaryDirectory(prefix="home-ts-local-lookup-") as temporary:
        directory = Path(temporary)
        for initialized in (True, False):
            for statements in (1000, 2000):
                file = directory / f"locals-{initialized}-{statements}.ts"
                file.write_text(source(statements, initialized), encoding="utf-8")
                # A shared fixture, flags, and exact output check precede timing.
                controls = {label: run(binary, file) for label, binary in binaries.items()}
                left, right = controls.values()
                if left[2:] != right[2:]:
                    raise RuntimeError(f"diagnostic mismatch for {file.name}: Home={left[2:]!r}, TypeScript={right[2:]!r}")
                if left[4] != 0:
                    raise RuntimeError(f"unexpected diagnostics for {file.name}: {left[2:4]!r}")
                samples = {label: [] for label in binaries}
                for repetition in range(args.repetitions):
                    labels = list(binaries)
                    if repetition % 2:
                        labels.reverse()
                    for label in labels:
                        elapsed, cpu, stdout, stderr, code = run(binaries[label], file)
                        if (stdout, stderr, code) != left[2:]:
                            raise RuntimeError(f"non-deterministic diagnostics for {label} on {file.name}")
                        samples[label].append((elapsed, cpu))
                for label, measured in samples.items():
                    rows.append({
                        "compiler": label,
                        "initialized": initialized,
                        "statements": statements,
                        "median_wall_s": round(statistics.median(x[0] for x in measured), 3),
                        "median_user_cpu_s": round(statistics.median(x[1] for x in measured), 3),
                    })
    print(json.dumps({"repetitions": args.repetitions, "rows": rows}, indent=2))


if __name__ == "__main__":
    main()
