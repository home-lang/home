#!/usr/bin/env python3
"""ts_parity_snapshot.py — TypeScript-conformance per-category gate helper.

Two modes:

  generate   Run Pantry-pinned `zig build test -Dfilter=ts_conformance`, parse the
             structured "[ts_conformance ...]" lines, and write a
             deterministic JSON snapshot to stdout (or --out <file>).

  compare    Run the conformance suite the same way, parse the output,
             and diff against a checked-in baseline JSON. Exits 0 when
             every per-category passed-count is >= the baseline's.
             Exits 1 on any regression, 2 on usage / I/O / parse errors.

Snapshot shape:

    {
      "smoke":            { "<name>": {"total": N, "passed": N}, ... },
      "category":         { "<path>": {"total": N, "passed": N}, ... },
      "baseline-aware":   { "<path>": {"total": N, "passed": N}, ... },
      "diagnostic-codes": { "emitted": {"total": 2076, "passed": 633} }
    }

The "COMBINED" rows the harness emits are intentionally dropped: they're
sums of the per-row entries and would double-book regressions. Keys are
sorted on write to keep the JSON byte-identical between runs.

The `diagnostic-codes` section is populated from the generated ledger
at `docs/TS_DIAGNOSTIC_CODE_STATUS.md`. The `emitted` row counts
upstream TS diagnostic codes referenced from production source — the
parity-ratchet metric each `feat(ts-parity): implement TSxxxx` commit
moves by +1. CI regenerates the ledger before compare so the count
reflects HEAD, not whatever was checked in.

Why this script exists: the TS-parity Phase 6 plan needs CI to fail PRs
that drop a single category's passed-count, even if the umbrella
pass-count holds. Total may grow (new tests get added), but passed must
not shrink for any tracked row.

Usage:

  ./tools/ts_parity_snapshot.py generate --out .github/conformance-baseline.json
  ./tools/ts_parity_snapshot.py compare --baseline .github/conformance-baseline.json
  ./tools/ts_parity_snapshot.py compare \\
      --baseline .github/conformance-baseline.json \\
      --from-log /tmp/conformance.log         # skip running zig
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Dict, Optional, Tuple

# Sections we recognise. Order matters only for the human-readable diff
# output; the JSON itself is sorted alphabetically per section.
SECTIONS = ("smoke", "category", "baseline-aware", "diagnostic-codes")
EXPECTED_ZIG_VERSION = "0.17.0-dev.1275+59a628c6d"

# Lines look like:
#   [ts_conformance smoke] comparable: total=13 passed=13 failed=0 skipped=0 pass_rate=1.00
#   [ts_conformance category] types/typeRelationships/comparable: total=13 passed=13 ...
#   [ts_conformance baseline-aware] types/typeRelationships/typeInference: total=52 ...
LINE_RE = re.compile(
    r"^\[ts_conformance (?P<section>smoke|category|baseline-aware)\] "
    r"(?P<name>[^:]+): "
    r"total=(?P<total>\d+) "
    r"passed=(?P<passed>\d+) "
    r"failed=\d+ "
    r"skipped=\d+ "
    r"pass_rate=[0-9.]+\s*$"
)


def repo_root() -> str:
    here = os.path.abspath(os.path.dirname(__file__))
    return os.path.dirname(here)


def run_conformance(cwd: str) -> str:
    """Run the conformance suite and return the captured stdout+stderr.

    The Zig test runner exits non-zero whenever any case fails — that's
    fine here, we just want the structured lines. The caller decides
    whether a regression is present.
    """
    zig_bin = os.path.join(cwd, "pantry", ".bin", "zig")
    version_proc = subprocess.run(
        [zig_bin, "version"],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if version_proc.returncode != 0:
        message = (version_proc.stdout or "").strip()
        raise RuntimeError(message or f"Pantry Zig not found at {zig_bin}")
    actual_version = (version_proc.stdout or "").strip()
    if actual_version != EXPECTED_ZIG_VERSION:
        raise RuntimeError(
            f"unsupported Zig version: {actual_version}\n"
            f"expected Pantry Zig {EXPECTED_ZIG_VERSION} at {zig_bin}"
        )

    cmd = [zig_bin, "build", "test", "-Dfilter=ts_conformance"]
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return proc.stdout or ""


def parse_log(text: str) -> Dict[str, Dict[str, Dict[str, int]]]:
    """Parse structured lines into the snapshot dict.

    "COMBINED" rows are skipped — they're aggregates of the rows we
    already have and including them would cause a single-row regression
    to count twice.
    """
    snapshot: Dict[str, Dict[str, Dict[str, int]]] = {s: {} for s in SECTIONS}
    for raw in text.splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        name = m.group("name").strip()
        if name == "COMBINED":
            continue
        section = m.group("section")
        snapshot[section][name] = {
            "total": int(m.group("total")),
            "passed": int(m.group("passed")),
        }
    return snapshot


# Diagnostic-code-status ledger row pattern. The ledger is generated
# by `scripts/gen-ts-diagnostic-status.mjs` and lives at
# `docs/TS_DIAGNOSTIC_CODE_STATUS.md`. Each row looks like:
#   | TS1234 | err | emitted | <source-refs> | <message-key> |
# We count rows per `status` token. The "emitted" count is the parity
# metric tracked by `feat(ts-parity): implement TSxxxx` commits; the
# gate fails any PR that drops it.
DIAG_LEDGER_PATH = "docs/TS_DIAGNOSTIC_CODE_STATUS.md"
DIAG_ROW_RE = re.compile(
    r"^\|\s*TS\d+\s*\|\s*(?:err|message|suggestion|deprecated)\s*\|\s*"
    r"(?P<status>emitted|declared|tested-only|catalog-only)\s*\|"
)


def count_diagnostic_codes(cwd: str) -> Dict[str, Dict[str, int]]:
    """Read the generated TS-diagnostic-code ledger and return the
    parity-ratchet row. Snapshot shape mirrors the rest of the file:
    `passed` = current count of emitted codes (production source has
    at least one reference), `total` = upstream-catalogue size. Each
    `feat(ts-parity): implement TSxxxx` commit moves `passed` up by 1.

    Only the `emitted` row is gated: a PR that drops the emitted
    count regresses parity. The other ledger statuses (`declared`,
    `tested-only`, `catalog-only`) are derivable from the ledger
    directly and would invert the monotonic-passed semantics if
    included.
    """
    path = os.path.join(cwd, DIAG_LEDGER_PATH)
    if not os.path.exists(path):
        return {}
    emitted = 0
    total = 0
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = DIAG_ROW_RE.match(line)
            if not m:
                continue
            total += 1
            if m.group("status") == "emitted":
                emitted += 1
    if total == 0:
        return {}
    return {
        "emitted": {"total": total, "passed": emitted},
    }


def to_json(snapshot: Dict[str, Dict[str, Dict[str, int]]]) -> str:
    """Serialise deterministically: keys sorted, 2-space indent, trailing
    newline. Two runs against the same source must produce byte-identical
    output."""
    # Re-build with sorted inner keys so we don't depend on dict insertion
    # order for the per-row {"total","passed"} pair either.
    normalised = {
        section: {
            name: {"total": data["total"], "passed": data["passed"]}
            for name, data in sorted(snapshot.get(section, {}).items())
        }
        for section in SECTIONS
    }
    return json.dumps(normalised, indent=2, sort_keys=True) + "\n"


def load_baseline(path: str) -> Dict[str, Dict[str, Dict[str, int]]]:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"baseline {path}: expected object at top level")
    for section in SECTIONS:
        section_data = data.get(section, {})
        if not isinstance(section_data, dict):
            raise ValueError(f"baseline {path}: section '{section}' must be an object")
        for name, row in section_data.items():
            if not isinstance(row, dict) or "total" not in row or "passed" not in row:
                raise ValueError(
                    f"baseline {path}: row '{section}/{name}' missing total/passed"
                )
    # Ensure every section key exists so downstream code can index safely.
    return {section: data.get(section, {}) for section in SECTIONS}


def diff_against_baseline(
    baseline: Dict[str, Dict[str, Dict[str, int]]],
    current: Dict[str, Dict[str, Dict[str, int]]],
) -> Tuple[list, list, list]:
    """Return (regressions, missing, gains).

    - regressions: rows whose passed-count dropped (hard failure)
    - missing:     rows present in baseline but not in current run (hard failure)
    - gains:       rows whose passed-count grew or new rows appeared (informational)
    """
    regressions = []
    missing = []
    gains = []
    for section in SECTIONS:
        base_section = baseline.get(section, {})
        cur_section = current.get(section, {})
        for name, base_row in sorted(base_section.items()):
            base_passed = int(base_row["passed"])
            base_total = int(base_row["total"])
            if name not in cur_section:
                missing.append((section, name, base_passed, base_total))
                continue
            cur_passed = int(cur_section[name]["passed"])
            cur_total = int(cur_section[name]["total"])
            if cur_passed < base_passed:
                regressions.append((section, name, base_passed, cur_passed, cur_total))
            elif cur_passed > base_passed or cur_total > base_total:
                gains.append(
                    (section, name, base_passed, base_total, cur_passed, cur_total)
                )
        for name, cur_row in sorted(cur_section.items()):
            if name not in base_section:
                gains.append(
                    (
                        section,
                        name,
                        0,
                        0,
                        int(cur_row["passed"]),
                        int(cur_row["total"]),
                    )
                )
    return regressions, missing, gains


def cmd_generate(args: argparse.Namespace) -> int:
    cwd = args.repo_root or repo_root()
    if args.from_log:
        with open(args.from_log, "r", encoding="utf-8") as fh:
            text = fh.read()
    else:
        print(
            f"running: ./pantry/.bin/zig build test -Dfilter=ts_conformance (cwd={cwd})",
            file=sys.stderr,
        )
        text = run_conformance(cwd)
    snapshot = parse_log(text)
    snapshot["diagnostic-codes"] = count_diagnostic_codes(cwd)
    rendered = to_json(snapshot)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(rendered)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(rendered)
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    cwd = args.repo_root or repo_root()
    baseline = load_baseline(args.baseline)
    if args.from_log:
        with open(args.from_log, "r", encoding="utf-8") as fh:
            text = fh.read()
    else:
        print(
            f"running: ./pantry/.bin/zig build test -Dfilter=ts_conformance (cwd={cwd})",
            file=sys.stderr,
        )
        text = run_conformance(cwd)
    current = parse_log(text)
    current["diagnostic-codes"] = count_diagnostic_codes(cwd)

    if args.write_current:
        with open(args.write_current, "w", encoding="utf-8") as fh:
            fh.write(to_json(current))

    regressions, missing, gains = diff_against_baseline(baseline, current)

    # Use GitHub-Actions error/warning annotations when present so the gate
    # surfaces clearly in PR checks. Falls back to plain text locally.
    in_ci = os.environ.get("GITHUB_ACTIONS") == "true"
    err_prefix = "::error::" if in_ci else "ERROR: "
    warn_prefix = "::warning::" if in_ci else "warning: "

    if gains:
        print("Gains vs. baseline (informational):")
        for section, name, bp, bt, cp, ct in gains:
            print(f"  + [{section}] {name}: {bp}/{bt} -> {cp}/{ct}")
        print(
            "If these gains are intentional and stable, regenerate the baseline:"
        )
        print(
            "  ./tools/ts_parity_snapshot.py generate --out .github/conformance-baseline.json"
        )

    if missing:
        for section, name, bp, bt in missing:
            print(
                f"{err_prefix}conformance row missing from current run: "
                f"[{section}] {name} (baseline {bp}/{bt})",
                file=sys.stderr,
            )

    if regressions:
        for section, name, bp, cp, ct in regressions:
            print(
                f"{err_prefix}conformance regression: "
                f"[{section}] {name} passed dropped {bp} -> {cp} (total now {ct})",
                file=sys.stderr,
            )

    if regressions or missing:
        print(
            f"{err_prefix}conformance gate failed: "
            f"{len(regressions)} regression(s), {len(missing)} missing row(s).",
            file=sys.stderr,
        )
        print(
            "If a drop is intentional, regenerate the baseline in the same PR with:",
            file=sys.stderr,
        )
        print(
            "  ./tools/ts_parity_snapshot.py generate --out .github/conformance-baseline.json",
            file=sys.stderr,
        )
        return 1

    if not gains:
        print("conformance gate: holds at baseline (no regressions, no gains).")
    else:
        print(
            f"conformance gate: holds (no regressions; {len(gains)} row(s) improved or expanded)."
        )
        if in_ci:
            print(
                f"{warn_prefix}conformance gains detected; "
                f"consider bumping .github/conformance-baseline.json in a follow-up PR."
            )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate or compare TypeScript-conformance per-category snapshots."
    )
    parser.add_argument(
        "--repo-root",
        help="Repository root (defaults to the parent of this script's directory).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate", help="Run the suite and emit a JSON snapshot.")
    gen.add_argument(
        "--out",
        help="Write JSON to this file instead of stdout.",
    )
    gen.add_argument(
        "--from-log",
        help="Skip running zig and parse a captured log file instead.",
    )
    gen.set_defaults(func=cmd_generate)

    cmp_ = sub.add_parser(
        "compare", help="Run the suite and gate against a baseline snapshot."
    )
    cmp_.add_argument(
        "--baseline",
        required=True,
        help="Path to the checked-in baseline JSON.",
    )
    cmp_.add_argument(
        "--from-log",
        help="Skip running zig and parse a captured log file instead.",
    )
    cmp_.add_argument(
        "--write-current",
        help="Also write the current-run snapshot to this file (useful for CI artifacts).",
    )
    cmp_.set_defaults(func=cmd_compare)
    return parser


def main(argv: Optional[list] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
