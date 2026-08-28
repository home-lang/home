#!/usr/bin/env python3
"""Render Hyperfine JSON from bench/vs_tsgo as a Markdown table."""

from __future__ import annotations

import json
import math
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
    if workload in ("import_graph", "reexport_graph") and validation_schema not in (2, 3):
        return "Ineligible (graph types unvalidated)"
    if workload == "variadic_tuples" and validation_schema != 3:
        return "Provisional (tuple controls unvalidated)"
    return format_comparison(home_mean, competitor_mean)


def validate_interleaved_rounds(directory: Path, metadata: dict) -> None:
    if metadata.get("schedule") != "round-robin interleaved":
        return
    runs = metadata.get("runs")
    workloads = metadata.get("workloads", [])
    names = list(metadata.get("compilers", {}))
    if (type(runs) is not int or runs < 1 or not workloads or len(set(workloads)) != len(workloads)
            or set(names) != {"tsc", "tsgo", "home"}):
        raise ValueError("invalid interleaved measurement metadata")
    expected = {f"{workload}-round-{index:03d}.json" for workload in workloads for index in range(runs)}
    actual = {path.name for path in directory.glob("*.json") if path.name != "metadata.json"}
    if actual != expected:
        raise ValueError(f"incomplete or unexpected round set: {len(expected - actual)} missing, {len(actual - expected)} extra")
    for workload in workloads:
        for index in range(runs):
            path = directory / f"{workload}-round-{index:03d}.json"
            results = json.loads(path.read_text(encoding="utf-8")).get("results", [])
            offset = index % len(names)
            order = names[offset:] + names[:offset]
            if [result.get("command") for result in results] != [f"{name} {workload}" for name in order]:
                raise ValueError(f"incorrect compiler coverage/order in {path.name}")
            for result in results:
                times = result.get("times", [])
                if (result.get("exit_codes") != [0] or len(times) != 1 or type(times[0]) not in (int, float)
                        or not math.isfinite(times[0]) or times[0] <= 0):
                    raise ValueError(f"invalid or unsuccessful sample in {path.name}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <results-directory>", file=sys.stderr)
        return 2
    directory = Path(sys.argv[1])
    metadata_path = directory / "metadata.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.is_file() else {}
        validate_interleaved_rounds(directory, metadata)
    except (ValueError, OSError) as error:
        print(f"cannot report {directory}: {error}", file=sys.stderr)
        return 1
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
    print("Legacy tuple rows without schema-3 rejection controls are provisional; schema 3 also retains the graph gates.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
