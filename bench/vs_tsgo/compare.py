#!/usr/bin/env python3
"""bench/vs_tsgo/compare.py — render hyperfine JSON results into a Markdown
table (per TS_PARITY_PLAN §6.4) or print the planned corpus actions.

Usage:
    compare.py <results-dir>            # render results to stdout
    compare.py --plan-corpus <toml>     # print planned `git clone` actions

This script intentionally has zero non-stdlib dependencies — it reads
hyperfine's standard JSON schema and tomllib (Python 3.11+) for the
corpus manifest.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python <3.11
    tomllib = None


def cmd_render(results_dir: Path) -> int:
    rows: dict[str, dict[str, dict]] = {}  # workload -> compiler -> stats

    for entry in sorted(results_dir.iterdir()):
        if entry.suffix != ".json":
            continue
        # Filename: <workload>-<compiler>.json
        name = entry.stem
        if "-" not in name:
            continue
        workload, _, compiler = name.partition("-")
        try:
            with entry.open() as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"# warning: skipped {entry}: {e}", file=sys.stderr)
            continue
        if not data.get("results"):
            continue
        r = data["results"][0]
        rows.setdefault(workload, {})[compiler] = {
            "mean": r.get("mean", 0.0),
            "stddev": r.get("stddev", 0.0),
            "min": r.get("min", 0.0),
            "max": r.get("max", 0.0),
        }

    if not rows:
        print(f"# no results found in {results_dir}", file=sys.stderr)
        return 1

    print(f"# bench/vs_tsgo report — {results_dir.name}")
    print()
    print("| Workload | tsc | tsgo | home | tsgo/tsc | home/tsgo |")
    print("|---|---|---|---|---|---|")
    for workload in sorted(rows):
        compilers = rows[workload]
        tsc = compilers.get("tsc", {}).get("mean")
        tsgo = compilers.get("tsgo", {}).get("mean")
        home = compilers.get("home", {}).get("mean")
        tsc_s = f"{tsc:.3f}s" if tsc else "—"
        tsgo_s = f"{tsgo:.3f}s" if tsgo else "—"
        home_s = f"{home:.3f}s" if home else "—"
        ratio_tsgo = f"{tsgo / tsc:.2f}×" if tsc and tsgo else "—"
        ratio_home = f"{home / tsgo:.2f}×" if tsgo and home else "—"
        print(f"| {workload} | {tsc_s} | {tsgo_s} | {home_s} | {ratio_tsgo} | {ratio_home} |")

    print()
    print("`tsgo/tsc` < 1 means tsgo is faster than tsc.")
    print("`home/tsgo` < 1 means home is faster than tsgo (the goal: ≤ 0.5).")
    return 0


def cmd_plan_corpus(toml_path: Path) -> int:
    if tomllib is None:
        print("# Python 3.11+ required for --plan-corpus", file=sys.stderr)
        return 1
    with toml_path.open("rb") as f:
        manifest = tomllib.load(f)
    workloads = manifest.get("workloads", {})
    print(f"# planned corpus: {len(workloads)} workloads")
    for name, info in sorted(workloads.items()):
        sha = info.get("sha", "")
        url = info.get("url", "")
        loc = info.get("expected_loc", "?")
        if all(c == "0" for c in sha):
            placeholder = " (PLACEHOLDER — needs real SHA)"
        else:
            placeholder = ""
        print(f"  - {name:<24} {url}@{sha[:8]:<10} ~{loc} LOC{placeholder}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("results_dir", nargs="?", help="directory of hyperfine JSON files")
    p.add_argument("--plan-corpus", metavar="TOML",
                   help="instead of rendering, print the planned corpus actions")
    args = p.parse_args()

    if args.plan_corpus:
        return cmd_plan_corpus(Path(args.plan_corpus))
    if not args.results_dir:
        p.print_help(sys.stderr)
        return 1
    return cmd_render(Path(args.results_dir))


if __name__ == "__main__":
    sys.exit(main())
