#!/usr/bin/env python3
"""Exercise disk admission and cleanup without filling the host's filesystem."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
temporary_volume = out / "temporary files"
temporary_volume.mkdir()
root = Path(__file__).resolve().parents[2]
supervisor = root / "scripts/run-bounded.pl"
results = []


def run(label, overrides, program, expected_code, diagnostic):
    env = os.environ.copy()
    env.update(HOME_RUN_LOCK_WAIT="15", TMPDIR=str(temporary_volume))
    env.update(overrides)
    marker = out / (label + ".pid")
    log = out / (label + ".log")
    with log.open("xb") as stream:
        code = subprocess.run(
            ["perl", str(supervisor), "20", sys.executable, "-c", program, str(marker)],
            cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT,
        ).returncode
    text = log.read_text()
    ok = code == expected_code and diagnostic in text
    if label in ("admission", "unmeasurable"):
        ok = ok and not marker.exists()
    if label == "running":
        ok = ok and marker.exists()
        if marker.exists():
            pid = int(marker.read_text())
            state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], text=True, capture_output=True)
            still_running = bool(state.stdout.strip()) and not state.stdout.strip().startswith("Z")
            if still_running:
                # This PID was just created by this test. Clean up even if the
                # regression failed, so a broken supervisor leaves no sleeper.
                os.kill(pid, 9)
                ok = False
    result = {"case": label, "exit_code": code, "expected_exit": expected_code, "ok": ok, "log": log.name}
    results.append(result)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(result), flush=True)


child = "import os,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(10)"
run("admission", {"HOME_RUN_MIN_FREE_MB": "104857600"}, child, 123, "disk free")
run("unmeasurable", {"TMPDIR": str(out / "does not exist")}, child, 123, "cannot measure available disk space")
run("running", {"HOME_RUN_MIN_FREE_MB": "0", "HOME_RUN_CRIT_FREE_MB": "104857600"}, child, 123, "critical floor")
run("positive", {"HOME_RUN_MIN_FREE_MB": "1", "HOME_RUN_CRIT_FREE_MB": "1"}, "print('disk-positive-control')", 0, "disk-positive-control")

# The scanner must distinguish a supervisor disk stop from a child's own 123.
# Keep these control files outside the original corpus.
fixture = out / "scanner-fixture"
fixture.mkdir()
(fixture / "control.test.js").write_text("// supervisor classification control\n")
child_executable = out / "child-exit-123"
child_executable.write_text("#!/bin/sh\nexit 123\n")
child_executable.chmod(0o755)
relative = os.path.relpath(fixture, root / "packages/runtime/test/test")
for label, minimum, expected_status in (("scanner-child-123", "1", "fail"), ("scanner-disk-stop", "104857600", "disk_bound")):
    env = os.environ.copy()
    env.update(HOME_RUN_LOCK_WAIT="15", HOME_BIN=str(child_executable), HOME_RUN_MIN_FREE_MB=minimum, HOME_RUN_CRIT_FREE_MB="1", TMPDIR=str(temporary_volume))
    tsv = out / (label + ".tsv")
    log = out / (label + ".log")
    with log.open("xb") as stream:
        code = subprocess.run(["bash", str(root / "scripts/vm-corpus-scan.sh"), relative, str(tsv), "10"], cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
    rows = tsv.read_text().splitlines()
    fields = rows[0].split("\t") if len(rows) == 1 else []
    ok = code == 1 and len(fields) == 5 and fields[0] == expected_status and fields[4] == "123" and Path(fields[3]).is_file()
    result = {"case": label, "exit_code": code, "expected_status": expected_status, "row": fields, "ok": ok, "log": log.name}
    results.append(result)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(result), flush=True)
raise SystemExit(0 if all(r["ok"] for r in results) else 1)
