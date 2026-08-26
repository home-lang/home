#!/usr/bin/env python3
"""Render Hyperfine JSON from bench/vs_tsgo as a Markdown table."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_result(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        print(f"warning: skipped {path}: {error}", file=sys.stderr)
        return None
    results = data.get("results", [])
    return results[0] if results else None


def format_time(result: dict | None) -> str:
    if not result:
        return "—"
    return f"{result['mean'] * 1000:.1f} ± {result['stddev'] * 1000:.1f} ms"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <results-directory>", file=sys.stderr)
        return 2
    directory = Path(sys.argv[1])
    rows: dict[str, dict[str, dict]] = {}
    for path in sorted(directory.glob("*.json")):
        if path.name == "metadata.json":
            continue
        workload, separator, compiler = path.stem.rpartition("-")
        if not separator or compiler not in {"tsc", "tsgo", "home"}:
            continue
        result = load_result(path)
        if result:
            rows.setdefault(workload, {})[compiler] = result
    if not rows:
        print(f"no benchmark results found in {directory}", file=sys.stderr)
        return 1

    metadata_path = directory / "metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.is_file() else {}
    print(f"# TypeScript frontend benchmark — {directory.name}")
    print()
    if metadata:
        versions = metadata.get("compilers", {})
        print(
            f"{metadata.get('machine', 'unknown host')}; "
            f"{metadata.get('runs', '?')} runs after {metadata.get('warmup', '?')} warmups; "
            f"tsc `{versions.get('tsc', '?')}`, tsgo `{versions.get('tsgo', '?')}`, "
            f"Home `{versions.get('home', '?')}`."
        )
        print()
    print("| Workload | tsc | tsgo | Home | Home vs fastest competitor |")
    print("|---|---:|---:|---:|---:|")
    for workload, compilers in rows.items():
        tsc = compilers.get("tsc")
        tsgo = compilers.get("tsgo")
        home = compilers.get("home")
        competitors = [result["mean"] for result in (tsc, tsgo) if result]
        if home and competitors:
            speedup = min(competitors) / home["mean"]
            comparison = f"**{speedup:.2f}× faster**" if speedup >= 1 else f"{1 / speedup:.2f}× slower"
        else:
            comparison = "—"
        print(
            f"| `{workload}` | {format_time(tsc)} | {format_time(tsgo)} | "
            f"{format_time(home)} | {comparison} |"
        )
    print()
    print("Times are mean ± sample standard deviation. A Home win is measured against the faster of tsc and tsgo.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
