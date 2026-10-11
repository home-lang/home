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
