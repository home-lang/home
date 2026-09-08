"""Exercise build configuration with and without the native HTML archive."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    archive = root / ".native/liblolhtml.a"
    saved = output / "liblolhtml.a.saved"
    original_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    results = []

    def check(label, enabled, expected):
        log = output / (label + ".log")
        with log.open("xb") as stream:
            code = subprocess.run(
                ["perl", str(root / "scripts/run-bounded.pl"), "120", args.zig,
                 "build", "--help", "-Denable_jsc=" + str(enabled).lower()],
                cwd=root, stdout=stream, stderr=subprocess.STDOUT,
            ).returncode
        raw = log.read_bytes()
        result = {"label": label, "exit_code": code, "expected_exit_code": expected,
                  "log": str(log), "log_sha256": hashlib.sha256(raw).hexdigest()}
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        assert code == expected, result
        if expected:
            assert b"JavaScript runtime requires .native/liblolhtml.a" in raw, raw
            assert b"scripts/build-lolhtml.sh" in raw, raw

    archive.rename(saved)
    try:
        check("missing-runtime-parser", True, 1)
        check("non-javascript-build", False, 0)
    finally:
        saved.rename(archive)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == original_hash
    check("restored-runtime-parser", True, 0)
    print("3 native HTML build configuration controls passed")


if __name__ == "__main__":
    main()
