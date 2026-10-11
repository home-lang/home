"""Continue only unrecorded matrix slots, retaining immutable checkpoint lineage.

Run one workload per normal machine guard. Recorded samples are never executed
again, originals are never rewritten, and partial/failed segments are terminal.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import shlex
import shutil
import subprocess

import checkpoint
import competitors
import run


def write_new(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def digest(path: Path) -> str:
    return run.sha256_file(path)


def initialize(source: Path, output: Path, current: dict, host: dict) -> dict:
    metadata_path = source / "metadata.json"
    if source.is_symlink() or not source.is_dir() or metadata_path.is_symlink() or not metadata_path.is_file():
        raise ValueError("checkpoint source and metadata must be real owned paths")
    metadata_raw = metadata_path.read_bytes()
    metadata = json.loads(metadata_raw)
    plan = checkpoint.plan_checkpoint(source, metadata, current)
    if metadata["host"] != host:
        raise ValueError("checkpoint host changed; no continuation")
    if output.exists() or output.is_symlink():
        raise ValueError("continuation output already exists")
    output.mkdir(parents=True)
    original = output / "lineage" / "original"
    original.mkdir(parents=True)
    shutil.copy2(source / "metadata.json", original / "metadata.json")
    shutil.copy2(source / "admission.jsonl", original / "admission.jsonl")
    shutil.copy2(source / "admission.jsonl", output / "admission.jsonl")
    sources = []
    for retained in plan["retained_rounds"]:
        filename = retained["path"]
        shutil.copy2(source / filename, original / filename)
        if digest(original / filename) != retained["sha256"]:
            raise ValueError("original checkpoint changed while copying")
        workload, index = filename.rsplit("-round-", 1)
        sources.append({"path": "lineage/original/" + filename, "sha256": retained["sha256"],
                        "workload": workload, "round": int(index.removesuffix(".json")),
                        "compiler_order": retained["compiler_order"]})
        if retained["samples"] == len(metadata["compilers"]):
            shutil.copy2(original / filename, output / filename)
    resumed = copy.deepcopy(metadata)
    resumed["provenance"] = {"status": "measuring", "before": current, "after": None}
    resumed["resumption"] = {"schema": 1, "original_directory": str(source.resolve()),
                             "measurement_pause": True, "original_recorded_samples": plan["recorded_successful_samples"],
                             "partial_round": plan["partial_round"], "source_metadata_sha256": hashlib.sha256(metadata_raw).hexdigest()}
    write_new(output / "metadata.json", resumed)
    write_new(output / "lineage" / "plan.json", plan)
    write_new(output / "lineage" / "base-sources.json", {"sources": sources})
    return plan


def execute_workload(output: Path, workload: str, commands: dict, corpus: Path,
                     provenance, host, process=subprocess.run) -> dict:
    metadata = json.loads((output / "metadata.json").read_bytes())
    plan = json.loads((output / "lineage" / "plan.json").read_bytes())
    if provenance() != metadata["provenance"]["before"] or host() != metadata["host"]:
        raise ValueError("checkpoint artifacts or host changed before execution")
    original = output / "lineage" / "original"
    revalidated = checkpoint.plan_checkpoint(original, json.loads((original / "metadata.json").read_bytes()), provenance())
    if plan != revalidated:
        raise ValueError("continuation plan or retained raw checkpoint changed")
    names = list(metadata["compilers"])
    if list(commands) != names or any(commands[name] != metadata["provenance"]["before"]["compilers"][name]["command"] for name in names):
        raise ValueError("continuation commands changed")
    slots = [row for row in plan["unrecorded_slots"] if row["workload"] == workload]
    if not slots:
        raise ValueError("workload has no unrecorded slots")
    phases = list(dict.fromkeys(row["workload"] for row in plan["unrecorded_slots"]))
    for prior in phases[:phases.index(workload)]:
        state = output / "lineage" / "phases" / (prior + ".json")
        if not state.is_file() or json.loads(state.read_bytes()).get("status") != "complete":
            raise ValueError("continuation workload order changed")
    phase = output / "lineage" / "phases" / (workload + ".json")
    if phase.exists() or phase.is_symlink():
        raise ValueError("continuation phase was already attempted; no repeats")
    write_new(phase, {"status": "running", "workload": workload,
                      "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "sources": []})
    argv = {name: commands[name] + ["--noEmit", "-p", str(corpus / workload / "tsconfig.json")] for name in names}
    sources = []
    try:
        already_warmed = any(row["path"].startswith(workload + "-round-") for row in plan["retained_rounds"])
        if not already_warmed:
            for index in range(metadata["warmup"]):
                order = names[index % len(names):] + names[:index % len(names)]
                for name in order:
                    result = process(argv[name], capture_output=True, text=True)
                    write_new(output / "lineage" / "warmups" / workload / f"{index:03d}-{name}.json",
                              {"command": argv[name], "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                    if result.returncode != 0:
                        raise ValueError("continuation warmup failed")
        for slot in slots:
            index, order = slot["round"], slot["compiler_order"]
            filename = f"{workload}-round-{index:03d}.json"
            raw_path = output / "lineage" / "segments" / filename
            assembled = output / filename
            if raw_path.exists() or raw_path.is_symlink() or assembled.exists() or assembled.is_symlink():
                raise ValueError("recorded sample output already exists; no repeats")
            raw_path.parent.mkdir(parents=True, exist_ok=True)
            timer = ["hyperfine", "--shell=none", "--runs", "1", "--style", "none", "--export-json", str(raw_path)]
            for name in order:
                timer += ["--command-name", name + " " + workload, shlex.join(argv[name])]
            process(timer, check=True)
            data = json.loads(raw_path.read_bytes())
            results = data.get("results", [])
            if [row.get("command") for row in results] != [name + " " + workload for name in order]:
                raise ValueError("continuation timer coverage/order changed")
            for row in results:
                times = row.get("times", [])
                if (row.get("exit_codes") != [0] or len(times) != 1
                        or type(times[0]) not in (int, float) or not math.isfinite(times[0]) or times[0] <= 0):
                    raise ValueError("continuation sample failed or is invalid; raw evidence retained")
            prefix = []
            if slot["partial_round"]:
                prefix = json.loads((output / "lineage" / "original" / filename).read_bytes())["results"]
            write_new(assembled, {"results": prefix + results})
            sources.append({"path": str(raw_path.relative_to(output)), "sha256": digest(raw_path),
                            "workload": workload, "round": index, "compiler_order": order})
        if provenance() != metadata["provenance"]["before"] or host() != metadata["host"]:
            raise ValueError("checkpoint artifacts or host changed after execution")
        state = {"status": "complete", "workload": workload, "sources": sources,
                 "finished_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "repeated_recorded_samples": 0}
    except BaseException as error:
        state = {"status": "incomplete", "workload": workload, "sources": sources,
                 "error": {"type": type(error).__name__, "message": str(error)}}
        phase.write_text(json.dumps(state, indent=2) + "\n")
        raise
    phase.write_text(json.dumps(state, indent=2) + "\n")
    return state


def finalize(output: Path, current: dict, host: dict) -> None:
    metadata_path = output / "metadata.json"
    metadata = json.loads(metadata_path.read_bytes())
    if current != metadata["provenance"]["before"] or host != metadata["host"]:
        raise ValueError("continuation final provenance/host changed")
    plan = json.loads((output / "lineage" / "plan.json").read_bytes())
    sources = json.loads((output / "lineage" / "base-sources.json").read_bytes())["sources"]
    for workload in dict.fromkeys(row["workload"] for row in plan["unrecorded_slots"]):
        phase = json.loads((output / "lineage" / "phases" / (workload + ".json")).read_bytes())
        if phase.get("status") != "complete":
            raise ValueError("continuation has an incomplete measurement phase")
        sources += phase["sources"]
    write_new(output / "lineage" / "manifest.json", {"schema": 1,
              "original_metadata_sha256": metadata["resumption"]["source_metadata_sha256"], "sources": sources,
              "measurement_pause": True, "recorded_samples_repeated": 0})
    metadata["provenance"].update(status="verified", after=current)
    checkpoint.validate_lineage(output, metadata)
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "workload", "finalize"])
    parser.add_argument("output", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--workload")
    parser.add_argument("--competitor-manifest", type=Path, required=True)
    args = parser.parse_args()
    profiles = competitors.load_profiles(args.competitor_manifest)
    commands = run.compiler_commands(profiles)
    provenance = lambda: run.benchmark_provenance(commands, profiles)
    if args.action == "init":
        if args.source is None: parser.error("init requires --source")
        initialize(args.source, args.output, provenance(), run.host_metadata())
    elif args.action == "workload":
        if args.workload is None: parser.error("workload requires --workload")
        execute_workload(args.output, args.workload, commands, run.CORPUS, provenance, run.host_metadata)
    else:
        finalize(args.output, provenance(), run.host_metadata())


if __name__ == "__main__":
    main()
