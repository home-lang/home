"""Inspect interrupted matrices without mutating evidence or executing compilers.

A plan identifies only unrecorded slots. It is never a completed benchmark or
permission to rank partial data; execution and final lineage need verification.
"""
import hashlib
import json
import math
from pathlib import Path
import re

import compare


def plan_checkpoint(directory: Path, metadata: dict, current_provenance: dict) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("checkpoint directory must be a real directory")
    admission_path = directory / "admission.jsonl"
    if admission_path.is_symlink() or not admission_path.is_file():
        raise ValueError("checkpoint admission must be a real file")
    if not isinstance(metadata, dict) or not isinstance(current_provenance, dict):
        raise ValueError("invalid checkpoint provenance metadata")
    provenance = metadata.get("provenance", {})
    if (not isinstance(provenance, dict)
            or provenance.get("status") not in {"measuring", "incomplete"}
            or not isinstance(provenance.get("before"), dict)
            or provenance["before"] != current_provenance):
        raise ValueError("interrupted checkpoint provenance is missing or changed")
    if provenance.get("after") not in (None, provenance["before"]):
        raise ValueError("checkpoint recorded changed provenance")
    if not isinstance(metadata.get("compilers"), dict):
        raise ValueError("invalid checkpoint compiler metadata")
    names = list(metadata["compilers"])
    workloads = metadata.get("workloads", [])
    runs = metadata.get("runs")
    if (not isinstance(workloads, list) or not workloads
            or any(not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", value)
                   for value in names + workloads)):
        raise ValueError("invalid checkpoint workload metadata")
    if (metadata.get("schedule") != "round-robin interleaved"
            or metadata.get("validation_schema") != 5
            or type(metadata.get("schema")) is not int or metadata["schema"] < 3
            or type(runs) is not int or runs < 1
            or type(metadata.get("warmup")) is not int or metadata["warmup"] < 0
            or len(set(workloads)) != len(workloads)
            or not {"tsc", "tsgo", "home"}.issubset(names)
            or any(not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", value)
                   for value in names + workloads)):
        raise ValueError("invalid checkpoint measurement metadata")
    host = metadata.get("host", {})
    if (not isinstance(host, dict)
            or any(not host.get(key) for key in ("os", "os_release", "architecture", "cpu_model"))
            or type(host.get("logical_cores")) is not int or host["logical_cores"] < 1):
        raise ValueError("checkpoint host metadata is incomplete")
    recorded = current_provenance.get("compilers", {})
    if not isinstance(recorded, dict) or not set(names).issubset(recorded):
        raise ValueError("checkpoint compiler provenance is incomplete")
    for name in names:
        entry = recorded[name]
        if not isinstance(entry, dict):
            raise ValueError("checkpoint compiler record is invalid")
        artifacts = [entry.get(key) for key in ("executable", "launcher", "payload") if key in entry]
        if (not entry.get("command") or not artifacts
                or any(not isinstance(artifact, dict)
                       or not re.fullmatch(r"[0-9a-f]{64}", str(artifact.get("sha256", "")))
                       or type(artifact.get("size")) is not int or artifact["size"] < 1
                       for artifact in artifacts)):
            raise ValueError("checkpoint executable provenance is incomplete")
    compare.validate_admission(directory, metadata, names, workloads)
    sequence = [(workload, index, f"{workload}-round-{index:03d}.json")
                for workload in workloads for index in range(runs)]
    allowed = {filename for _, _, filename in sequence}
    files = {path.name for path in directory.glob("*.json") if path.name != "metadata.json"}
    if files - allowed:
        raise ValueError("unexpected checkpoint round files")
    missing = []
    retained = []
    open_prefix = False
    complete_rounds = 0
    successful_samples = 0
    partial_round = None
    for workload, index, filename in sequence:
        offset = index % len(names)
        order = names[offset:] + names[:offset]
        results = []
        if filename in files:
            if open_prefix:
                raise ValueError("checkpoint round set is not a contiguous prefix")
            path = directory / filename
            if path.is_symlink() or not path.is_file():
                raise ValueError("checkpoint round must be a real file")
            raw = path.read_bytes()
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError("checkpoint round record is invalid")
            results = data.get("results")
            if not isinstance(results, list) or not 1 <= len(results) <= len(names):
                raise ValueError("checkpoint round has invalid compiler coverage")
            if any(not isinstance(result, dict) for result in results):
                raise ValueError("checkpoint sample record is invalid")
            if [result.get("command") for result in results] != [f"{name} {workload}" for name in order[:len(results)]]:
                raise ValueError("checkpoint compiler samples are not an ordered prefix")
            for result in results:
                times = result.get("times", [])
                if (result.get("exit_codes") != [0] or len(times) != 1
                        or type(times[0]) not in (int, float)
                        or not math.isfinite(times[0]) or times[0] <= 0):
                    raise ValueError("checkpoint contains an invalid or failed recorded sample")
            retained.append({"path": filename, "sha256": hashlib.sha256(raw).hexdigest(),
                             "compiler_order": order[:len(results)], "samples": len(results)})
            successful_samples += len(results)
            if len(results) == len(names):
                complete_rounds += 1
            else:
                partial_round = filename
        if len(results) < len(names):
            open_prefix = True
            missing.append({"workload": workload, "round": index,
                            "compiler_order": order[len(results):],
                            "already_recorded": order[:len(results)],
                            "partial_round": filename if results else None})
    if not missing:
        raise ValueError("complete matrices must use the completed-result verifier")
    return {"schema": 1, "diagnostic_only": True, "ranking_qualified": False,
            "execution_authorized_by_plan": False, "complete_rounds": complete_rounds,
            "recorded_successful_samples": successful_samples, "partial_round": partial_round,
            "retained_rounds": retained, "unrecorded_slots": missing,
            "missing_sample_count": sum(len(row["compiler_order"]) for row in missing),
            "provenance": current_provenance,
            "admission_sha256": metadata["admission"]["sha256"]}


def validate_lineage(directory: Path, metadata: dict) -> None:
    """Require every assembled sample to come exactly once from retained raw data.

    This supplements, never replaces, the normal complete-matrix verifier.
    Original files and measurement segments live below `lineage/`, so reports
    still require the exact complete top-level round set and unchanged provenance.
    """
    if directory.is_symlink() or not directory.is_dir() or not isinstance(metadata, dict):
        raise ValueError("matrix lineage requires real directory and metadata")
    lineage_directory = directory / "lineage"
    if lineage_directory.is_symlink() or not lineage_directory.is_dir():
        raise ValueError("matrix lineage must remain in a real directory")
    lineage_path = lineage_directory / "manifest.json"
    if lineage_path.is_symlink() or not lineage_path.is_file():
        raise ValueError("matrix lineage manifest must be a real file")
    lineage = json.loads(lineage_path.read_bytes())
    if not isinstance(lineage, dict) or lineage.get("schema") != 1:
        raise ValueError("invalid matrix lineage manifest")
    original = directory / "lineage" / "original"
    if original.is_symlink() or not original.is_dir():
        raise ValueError("original checkpoint must remain in a real directory")
    original_metadata_path = original / "metadata.json"
    if original_metadata_path.is_symlink() or not original_metadata_path.is_file():
        raise ValueError("original checkpoint metadata must be a real file")
    original_raw = original_metadata_path.read_bytes()
    if hashlib.sha256(original_raw).hexdigest() != lineage.get("original_metadata_sha256"):
        raise ValueError("original checkpoint metadata checksum changed")
    original_metadata = json.loads(original_raw)
    current_provenance = metadata.get("provenance", {}).get("before")
    original_plan = plan_checkpoint(original, original_metadata, current_provenance)
    descriptor = metadata.get("resumption")
    if (not isinstance(descriptor, dict) or descriptor.get("schema") != 1
            or descriptor.get("measurement_pause") is not True
            or descriptor.get("source_metadata_sha256") != lineage["original_metadata_sha256"]
            or descriptor.get("original_recorded_samples") != original_plan["recorded_successful_samples"]
            or descriptor.get("partial_round") != original_plan["partial_round"]):
        raise ValueError("matrix continuation pause or checkpoint descriptor is missing or changed")
    if (metadata.get("workloads") != original_metadata.get("workloads")
            or metadata.get("compilers") != original_metadata.get("compilers")
            or metadata.get("runs") != original_metadata.get("runs")
            or metadata.get("warmup") != original_metadata.get("warmup")
            or metadata.get("host") != original_metadata.get("host")):
        raise ValueError("matrix continuation changed its original selection or host")
    sources = lineage.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("matrix lineage sources are missing")
    names = list(metadata.get("compilers", {}))
    workloads = metadata.get("workloads", [])
    runs = metadata.get("runs")
    if type(runs) is not int or runs < 1 or not names or not workloads:
        raise ValueError("matrix lineage measurement metadata is invalid")
    samples = {}
    seen_paths = set()
    for source in sources:
        if not isinstance(source, dict):
            raise ValueError("invalid matrix lineage source")
        relative = source.get("path")
        path = Path(relative) if isinstance(relative, str) else Path()
        if (not isinstance(relative, str) or path.is_absolute() or ".." in path.parts
                or not path.parts or path.parts[0] != "lineage" or relative in seen_paths):
            raise ValueError("matrix lineage path is invalid or duplicated")
        seen_paths.add(relative)
        target = directory / path
        if (any(directory.joinpath(*path.parts[:length]).is_symlink() for length in range(len(path.parts) + 1))
                or not target.is_file() or directory.resolve() not in target.resolve().parents):
            raise ValueError("matrix lineage source must remain inside the real directory")
        raw = target.read_bytes()
        if hashlib.sha256(raw).hexdigest() != source.get("sha256"):
            raise ValueError("matrix lineage source checksum changed")
        workload, index = source.get("workload"), source.get("round")
        if workload not in workloads or type(index) is not int or not 0 <= index < runs:
            raise ValueError("matrix lineage sample identity is invalid")
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("matrix lineage raw record is invalid")
        results = data.get("results")
        order = source.get("compiler_order")
        offset = index % len(names)
        expected = names[offset:] + names[:offset]
        if (not isinstance(results, list) or not results or any(not isinstance(result, dict) for result in results)
                or not isinstance(order, list)
                or any(name not in expected for name in order)
                or len(set(order)) != len(order)
                or [r.get("command") for r in results] != [name + " " + workload for name in order]
                or [expected.index(name) for name in order] != sorted(expected.index(name) for name in order)):
            raise ValueError("matrix lineage compiler order is invalid")
        for name, result in zip(order, results):
            identity = (workload, index, name)
            if identity in samples:
                raise ValueError("matrix lineage repeats a recorded sample")
            times = result.get("times", [])
            if (result.get("exit_codes") != [0] or len(times) != 1
                    or type(times[0]) not in (int, float) or not math.isfinite(times[0]) or times[0] <= 0):
                raise ValueError("matrix lineage sample is unsuccessful or invalid")
            samples[identity] = result
    original_paths = {"lineage/original/" + row["path"]: row for row in original_plan["retained_rounds"]}
    source_by_path = {source["path"]: source for source in sources}
    for relative, retained in original_paths.items():
        source = source_by_path.get(relative)
        if (source is None or source.get("sha256") != retained["sha256"]
                or source.get("compiler_order") != retained["compiler_order"]):
            raise ValueError("matrix lineage omitted or replaced an original recorded sample")
    if {source["path"] for source in sources if source["path"].startswith("lineage/original/")} != set(original_paths):
        raise ValueError("matrix lineage original sources differ from retained checkpoint")
    expected_samples = {(workload, index, name) for workload in workloads for index in range(runs) for name in names}
    if set(samples) != expected_samples:
        raise ValueError("matrix lineage does not cover every sample exactly once")
    compare.validate_interleaved_rounds(directory, metadata)
    for workload in workloads:
        for index in range(runs):
            offset = index % len(names)
            order = names[offset:] + names[:offset]
            path = directory / f"{workload}-round-{index:03d}.json"
            if path.is_symlink() or not path.is_file():
                raise ValueError("assembled matrix round must be a real file")
            actual = json.loads(path.read_bytes()).get("results")
            if actual != [samples[(workload, index, name)] for name in order]:
                raise ValueError("assembled matrix altered its retained raw samples")
