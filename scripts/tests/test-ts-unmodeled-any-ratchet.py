#!/usr/bin/env python3
"""Hermetic controls for the Zod HM9002 ratchet."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
RATCHET = ROOT / "scripts/ts-unmodeled-any-ratchet.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_case(
    temporary: Path,
    baseline: Path,
    archive: Path,
    compiler: Path,
    count: int,
    expected: int,
) -> tuple[str, dict[str, object]]:
    current = temporary / f"current-{count}.json"
    diagnostics = temporary / f"diagnostics-{count}.txt"
    env = os.environ.copy()
    env["FAKE_HM9002_COUNT"] = str(count)
    proc = subprocess.run(
        [
            sys.executable,
            str(RATCHET),
            "--baseline",
            str(baseline),
            "--archive",
            str(archive),
            "--compiler",
            str(compiler),
            "--write-current",
            str(current),
            "--diagnostics-output",
            str(diagnostics),
        ],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if proc.returncode != expected:
        raise AssertionError(f"count {count}: expected exit {expected}, got {proc.returncode}\n{proc.stdout}")
    return proc.stdout, json.loads(current.read_text(encoding="utf-8"))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="home-unmodeled-ratchet-test-") as tmp:
        temporary = Path(tmp)
        package = temporary / "fixture/package"
        write(package / "src/v4/core/a.ts", "export const a = 1;\n")
        write(package / "src/v4/classic/b.ts", "export const b = 2;\n")
        write(package / "src/v4/core/tests/ignored.test.ts", "throw new Error();\n")
        archive = temporary / "fixture.tgz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(package, arcname="package")

        compiler = temporary / "fake-home-tsc"
        write(
            compiler,
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "for index in range(int(os.environ['FAKE_HM9002_COUNT'])):\n"
            "    print(f'fixture.ts(1,{index + 1}): warning HM9002: recovery')\n"
            "print('fixture.ts(2,1): error TS2322: control')\n"
            "raise SystemExit(1)\n",
        )
        compiler.chmod(0o755)

        baseline = temporary / "baseline.json"
        write(
            baseline,
            json.dumps(
                {
                    "corpus": {
                        "name": "fixture",
                        "version": "1.0.0",
                        "url": "https://invalid.example/fixture.tgz",
                        "sha512": hashlib.sha512(archive.read_bytes()).hexdigest(),
                        "production_files": 2,
                    },
                    "max_unmodeled_any": 1,
                },
                indent=2,
            )
            + "\n",
        )

        equal_output, equal = run_case(temporary, baseline, archive, compiler, 1, 0)
        assert "current=1 baseline=1 production_files=2" in equal_output
        assert equal["unmodeled_any"] == 1

        lower_output, lower = run_case(temporary, baseline, archive, compiler, 0, 0)
        assert "improved by 1" in lower_output
        assert lower["unmodeled_any"] == 0

        growth_output, growth = run_case(temporary, baseline, archive, compiler, 2, 1)
        assert "regressed by 1" in growth_output
        assert growth["unmodeled_any"] == 2

        broken = json.loads(baseline.read_text(encoding="utf-8"))
        broken["corpus"]["sha512"] = "0" * 128
        bad_baseline = temporary / "bad-baseline.json"
        write(bad_baseline, json.dumps(broken) + "\n")
        proc = subprocess.run(
            [
                sys.executable,
                str(RATCHET),
                "--baseline",
                str(bad_baseline),
                "--archive",
                str(archive),
                "--compiler",
                str(compiler),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        assert proc.returncode == 2
        assert "archive SHA-512 mismatch" in proc.stdout

    print("ts-unmodeled-any ratchet controls: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
