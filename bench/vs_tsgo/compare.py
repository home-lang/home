#!/usr/bin/env python3
"""Render Hyperfine JSON from bench/vs_tsgo as a Markdown table."""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path


def load_results(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        print(f"warning: skipped {path}: {error}", file=sys.stderr)
        return []
    return data.get("results", [])


def summarize_times(times: list[float]) -> dict:
    return {
        "mean": statistics.mean(times),
        "stddev": statistics.stdev(times) if len(times) > 1 else 0.0,
    }


def format_time(result: dict | None) -> str:
    if not result:
        return "—"
    return f"{result['mean'] * 1000:.1f} ± {result['stddev'] * 1000:.1f} ms"


def format_comparison(home_mean: float, competitor_mean: float) -> str:
    speedup = competitor_mean / home_mean
    factor = speedup if speedup >= 1 else 1 / speedup
    rounded = f"{factor:.2f}"
    # This is a display-resolution rule, not a statistical significance test.
    # Do not present an equal or rounded-equal ratio as a directional win.
    if rounded == "1.00":
        return "1.00× (near tie)"
    return f"**{rounded}× faster**" if speedup > 1 else f"{rounded}× slower"


def format_workload_comparison(workload: str, home_mean: float, competitor_mean: float, validation_schema=None) -> str:
    if workload in ("import_graph", "reexport_graph") and validation_schema != 2:
        return "Ineligible (graph types unvalidated)"
    return format_comparison(home_mean, competitor_mean)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <results-directory>", file=sys.stderr)
        return 2
    directory = Path(sys.argv[1])
    rows: dict[str, dict[str, dict]] = {}
    interleaved: dict[str, dict[str, list[float]]] = {}
    for path in sorted(directory.glob("*.json")):
        if path.name == "metadata.json":
            continue
        if "-round-" in path.stem:
            workload = path.stem.rsplit("-round-", 1)[0]
            for result in load_results(path):
                compiler = result.get("command", "").split(" ", 1)[0]
                if compiler not in {"tsc", "tsgo", "home"}:
                    continue
                interleaved.setdefault(workload, {}).setdefault(compiler, []).extend(result.get("times", []))
            continue
        workload, separator, compiler = path.stem.rpartition("-")
        if not separator or compiler not in {"tsc", "tsgo", "home"}:
            continue
        results = load_results(path)
        if results:
            rows.setdefault(workload, {})[compiler] = results[0]
    for workload, compilers in interleaved.items():
        rows[workload] = {
            compiler: summarize_times(times)
            for compiler, times in compilers.items()
            if times
        }
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
            comparison = format_workload_comparison(workload, home["mean"], min(competitors), metadata.get("validation_schema"))
        else:
            comparison = "—"
        print(
            f"| `{workload}` | {format_time(tsc)} | {format_time(tsgo)} | "
            f"{format_time(home)} | {comparison} |"
        )
    print()
    print("Times are mean ± sample standard deviation. Comparisons use the faster of tsc and tsgo.")
    print("Ratios rounding to 1.00× are labeled near ties; this is not a statistical significance test.")
    print("Legacy graph rows without schema-2 rejection controls are retained as timings, not fair speed claims (#487).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
