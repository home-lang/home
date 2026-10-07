#!/usr/bin/env python3
"""Render Hyperfine JSON from bench/vs_tsgo as a Markdown table."""

from __future__ import annotations

import json
import hashlib
import math
import re
import statistics
import sys
from pathlib import Path
import competitors


def load_results(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        print(f"warning: skipped {path}: {error}", file=sys.stderr)
        return []
    return data.get("results", [])


def summarize_times(times: list[float]) -> dict:
    if not times or any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in times):
        raise ValueError("timing samples must be finite positive numbers")
    return {
        "median": statistics.median(times),
        "samples": len(times),
    }


def format_time(result: dict | None) -> str:
    if not result:
        return "—"
    return f"{result['median'] * 1000:.1f} ms"


def format_comparison(home_median: float, competitor_median: float) -> str:
    speedup = competitor_median / home_median
    factor = speedup if speedup >= 1 else 1 / speedup
    rounded = f"{factor:.2f}"
    # This is a display-resolution rule, not a statistical significance test.
    # Do not present an equal or rounded-equal ratio as a directional win.
    if rounded == "1.00":
        return "1.00× (near tie)"
    return f"**{rounded}× faster**" if speedup > 1 else f"{rounded}× slower"


def format_workload_comparison(workload: str, home_median: float, competitor_median: float, validation_schema=None) -> str:
    if workload in ("import_graph", "reexport_graph") and validation_schema not in (2, 3):
        return "Ineligible (graph types unvalidated)"
    if workload == "variadic_tuples" and validation_schema != 3:
        return "Provisional (tuple controls unvalidated)"
    return format_comparison(home_median, competitor_median)


def provenance_notice(metadata: dict) -> str:
    provenance = metadata.get("provenance")
    if provenance is None:
        return "Provenance: legacy result; executable identities were not recorded automatically."
    return "Provenance: verified unchanged before admission and after measurement."


def host_notice(metadata: dict) -> str:
    host = metadata.get("host")
    if not isinstance(host, dict):
        return f"{metadata.get('system', 'unknown host')} ({metadata.get('machine', 'unknown architecture')})"
    cpu = host["cpu_model"]
    machine_model = host.get("machine_model")
    if machine_model and machine_model != cpu:
        cpu = f"{cpu} / {machine_model}"
    return (
        f"{cpu}; {host['logical_cores']} logical cores; "
        f"{host['os']} {host['os_release']} ({host['architecture']})"
    )


def tools_notice(metadata: dict) -> str | None:
    tools = metadata.get("provenance", {}).get("before", {}).get("tools", {})
    versions = [
        f"{name} `{details['version']}`"
        for name, details in tools.items()
        if isinstance(details, dict) and details.get("version")
    ]
    return f"Measurement tools: {', '.join(versions)}." if versions else None


def validate_admission(directory: Path, metadata: dict, names: list[str], workloads: list[str]) -> None:
    descriptor = metadata.get("admission", {})
    if not isinstance(descriptor, dict) or descriptor.get("path") != "admission.jsonl":
        raise ValueError("additional compilers require retained admission evidence")
    raw = (directory / "admission.jsonl").read_bytes()
    if hashlib.sha256(raw).hexdigest() != descriptor.get("sha256"):
        raise ValueError("admission evidence hash does not match metadata")
    admission = json.loads(raw)
    provenance = metadata["provenance"]
    if (not isinstance(admission, dict) or admission.get("schema") != 1 or admission.get("passed") is not True
            or admission.get("before") != provenance["before"] or admission.get("after") != provenance["before"]):
        raise ValueError("admission provenance or success record is invalid")
    records = admission.get("records")
    if not isinstance(records, list) or len(records) != descriptor.get("records"):
        raise ValueError("admission record count is invalid")
    required_negatives = {"destructuring", "type_predicates", "type_predicates_large", "import_graph",
                          "reexport_graph", "variadic_tuples", "commonjs_graph", "recursive_generics"}
    expected = {(name, workload, "positive") for name in names for workload in workloads}
    expected |= {(name, workload, "negative") for name in names for workload in workloads if workload in required_negatives}
    seen = set()
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("admission record is invalid")
        key = (record.get("compiler"), record.get("workload"), record.get("kind"))
        if key not in expected or key in seen or record.get("passed") is not True:
            raise ValueError("admission coverage or success is invalid")
        seen.add(key)
        entry = provenance["before"]["compilers"][key[0]]
        prefix = entry.get("command", [])
        command = record.get("command", [])
        if (not isinstance(prefix, list) or not prefix or not isinstance(command, list)
                or command[:len(prefix)] != prefix or command[len(prefix):len(prefix) + 2] != ["--noEmit", "-p"]
                or len(command) != len(prefix) + 3):
            raise ValueError("admission command differs from measured command")
        stdout, stderr = record.get("stdout"), record.get("stderr")
        if not isinstance(stdout, str) or not isinstance(stderr, str) or type(record.get("exit_code")) is not int:
            raise ValueError("admission raw process output is invalid")
        codes = sorted(re.findall(r"\berror TS(\d+):", stdout + stderr))
        if codes != record.get("codes"):
            raise ValueError("admission diagnostics differ from retained output")
        if key[2] == "positive":
            policy = entry.get("positive_output", "silent")
            if (record["exit_code"] != 0 or record.get("expected_codes") is not None
                    or record.get("positive_output") != policy or not competitors.successful_output(stdout, stderr, policy)):
                raise ValueError("positive admission is invalid")
        else:
            expected_codes = record.get("expected_codes")
            if (record["exit_code"] not in (1, 2) or not isinstance(expected_codes, list)
                    or not expected_codes or codes != sorted(expected_codes)):
                raise ValueError("negative admission is invalid")
    if seen != expected:
        raise ValueError("admission coverage is incomplete")


def validate_interleaved_rounds(directory: Path, metadata: dict) -> None:
    if metadata.get("schedule") != "round-robin interleaved":
        if set(metadata.get("compilers", {})) - {"tsc", "tsgo", "home"}:
            raise ValueError("additional compilers require round-robin interleaved samples")
        return
    provenance = metadata.get("provenance")
    if provenance is not None:
        if provenance.get("status") != "verified":
            raise ValueError(f"benchmark provenance is {provenance.get('status', 'invalid')}, not verified")
        if provenance.get("before") != provenance.get("after"):
            raise ValueError("benchmark provenance changed during measurement")
    runs = metadata.get("runs")
    workloads = metadata.get("workloads", [])
    names = list(metadata.get("compilers", {}))
    if (type(runs) is not int or runs < 1 or not workloads or len(set(workloads)) != len(workloads)
            or not {"tsc", "tsgo", "home"}.issubset(names)
            or any(not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", name) for name in names)):
        raise ValueError("invalid interleaved measurement metadata")
    extras = set(names) - {"tsc", "tsgo", "home"}
    if extras:
        if metadata.get("schema", 1) < 3 or provenance is None:
            raise ValueError("additional compilers require schema 3 and verified provenance")
        recorded = provenance.get("before", {}).get("compilers", {})
        if not isinstance(recorded, dict) or not set(names).issubset(recorded):
            raise ValueError("additional compiler provenance is incomplete")
        for name in extras:
            entry = recorded[name]
            artifact = entry.get("executable", {}) if isinstance(entry, dict) else {}
            if (not isinstance(artifact, dict)
                    or not re.fullmatch(r"[0-9a-f]{64}", str(artifact.get("sha256", "")))
                    or type(artifact.get("size")) is not int or artifact["size"] < 1):
                raise ValueError("additional compiler executable provenance is incomplete")
        validate_admission(directory, metadata, names, workloads)
    if metadata.get("schema", 1) >= 2:
        host = metadata.get("host")
        required = ("os", "os_release", "architecture", "cpu_model")
        if not isinstance(host, dict) or any(not host.get(key) for key in required):
            raise ValueError("benchmark host metadata is incomplete")
        cores = host.get("logical_cores")
        if type(cores) is not int or cores < 1:
            raise ValueError("benchmark logical core count is invalid")
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
    names = list(metadata.get("compilers") or {"tsc": "?", "tsgo": "?", "home": "?"})
    rows: dict[str, dict[str, dict]] = {}
    interleaved: dict[str, dict[str, list[float]]] = {}
    for path in sorted(directory.glob("*.json")):
        if path.name == "metadata.json":
            continue
        if "-round-" in path.stem:
            workload = path.stem.rsplit("-round-", 1)[0]
            for result in load_results(path):
                compiler = result.get("command", "").split(" ", 1)[0]
                if compiler not in names:
                    continue
                interleaved.setdefault(workload, {}).setdefault(compiler, []).extend(result.get("times", []))
            continue
        workload, separator, compiler = path.stem.rpartition("-")
        if not separator or compiler not in names:
            continue
        results = load_results(path)
        if results:
            try:
                rows.setdefault(workload, {})[compiler] = summarize_times(results[0].get("times", []))
            except ValueError as error:
                print(f"cannot report {path}: {error}", file=sys.stderr)
                return 1
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
        version_labels = ", ".join(
            f"{'Home' if name == 'home' else name} `{versions.get(name, '?')}`"
            for name in names
        )
        print(
            f"{host_notice(metadata)}; "
            f"{metadata.get('runs', '?')} runs after {metadata.get('warmup', '?')} warmups; "
            f"{version_labels}."
        )
        if tools := tools_notice(metadata):
            print(tools)
        print(provenance_notice(metadata))
        print()
    columns = [f"{'Home' if name == 'home' else name} median" for name in names]
    print("| Workload | " + " | ".join(columns) + " | Home vs fastest competitor |")
    print("|---|" + "---:|" * (len(names) + 1))
    for workload, compilers in rows.items():
        home = compilers.get("home")
        competitors = [result["median"] for name, result in compilers.items() if name != "home"]
        if home and competitors:
            comparison = format_workload_comparison(workload, home["median"], min(competitors), metadata.get("validation_schema"))
        else:
            comparison = "—"
        values = " | ".join(format_time(compilers.get(name)) for name in names)
        print(f"| `{workload}` | {values} | {comparison} |")
    print()
    print("Times are medians of all retained fresh-process samples. Comparisons use the fastest median of every measured competitor.")
    print("Ratios rounding to 1.00× are labeled near ties; this is not a statistical significance test.")
    print("Legacy graph rows without schema-2 rejection controls are retained as timings, not fair speed claims (#487).")
    print("Legacy tuple rows without schema-3 rejection controls are provisional; schema 3 also retains the graph gates.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
