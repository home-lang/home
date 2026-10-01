#!/usr/bin/env python3
"""Gate checker-synthesized ``any`` recoveries on pinned Zod sources.

The corpus metadata and maximum accepted HM9002 count live in the checked-in
baseline.  This tool verifies the archive byte-for-byte, reconstructs the same
strict 106-file project used by Home's Zod audits, runs ``home-tsc`` with the
opt-in provenance diagnostic, and fails when the count grows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


HM9002_RE = re.compile(r"\b(?:warning|error) HM9002:")


class RatchetError(RuntimeError):
    """A corpus, compiler, or baseline error rather than a count regression."""


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--compiler",
        type=Path,
        default=root / "zig-out/bin/home-tsc",
        help="home-tsc binary to run",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=root / ".github/ts-unmodeled-any-baseline.json",
        help="checked-in corpus metadata and maximum HM9002 count",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        help="use an existing archive instead of downloading the pinned URL",
    )
    parser.add_argument(
        "--write-current",
        type=Path,
        help="write the measured corpus/count record as deterministic JSON",
    )
    parser.add_argument(
        "--diagnostics-output",
        type=Path,
        help="retain the compiler's complete stdout/stderr for CI diagnosis",
    )
    return parser.parse_args()


def load_baseline(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RatchetError(f"cannot read baseline {path}: {exc}") from exc

    corpus = data.get("corpus")
    if not isinstance(corpus, dict):
        raise RatchetError("baseline corpus must be an object")
    required_strings = ("name", "version", "url", "sha512")
    for key in required_strings:
        if not isinstance(corpus.get(key), str) or not corpus[key]:
            raise RatchetError(f"baseline corpus.{key} must be a non-empty string")
    for key in ("production_files",):
        if not isinstance(corpus.get(key), int) or corpus[key] <= 0:
            raise RatchetError(f"baseline corpus.{key} must be a positive integer")
    maximum = data.get("max_unmodeled_any")
    if not isinstance(maximum, int) or maximum < 0:
        raise RatchetError("baseline max_unmodeled_any must be a non-negative integer")
    expected_hash = corpus["sha512"]
    if len(expected_hash) != 128 or any(c not in "0123456789abcdef" for c in expected_hash):
        raise RatchetError("baseline corpus.sha512 must be a lowercase SHA-512 hex digest")
    return data


def obtain_archive(corpus: dict[str, object], supplied: Path | None, destination: Path) -> Path:
    if supplied is not None:
        source = supplied.resolve()
        if not source.is_file():
            raise RatchetError(f"archive does not exist: {source}")
        shutil.copyfile(source, destination)
    else:
        url = str(corpus["url"])
        try:
            with urllib.request.urlopen(url, timeout=60) as response, destination.open("xb") as out:
                shutil.copyfileobj(response, out)
        except (OSError, urllib.error.URLError) as exc:
            raise RatchetError(f"cannot download {url}: {exc}") from exc

    actual = hashlib.sha512(destination.read_bytes()).hexdigest()
    expected = str(corpus["sha512"])
    if actual != expected:
        raise RatchetError(f"archive SHA-512 mismatch: expected {expected}, got {actual}")
    return destination


def extract_archive(archive: Path, destination: Path) -> Path:
    """Extract regular files and directories without trusting tar paths/links."""
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            for member in bundle.getmembers():
                relative = PurePosixPath(member.name)
                if relative.is_absolute() or ".." in relative.parts:
                    raise RatchetError(f"unsafe archive path: {member.name}")
                target = destination.joinpath(*relative.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise RatchetError(f"unsupported archive entry: {member.name}")
                extracted = bundle.extractfile(member)
                if extracted is None:
                    raise RatchetError(f"cannot read archive entry: {member.name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as out:
                    shutil.copyfileobj(extracted, out)
    except (OSError, tarfile.TarError) as exc:
        raise RatchetError(f"cannot extract {archive}: {exc}") from exc

    package = destination / "package"
    if not package.is_dir():
        raise RatchetError("archive does not contain the expected package/ root")
    return package


def production_sources(package: Path) -> list[Path]:
    root = package / "src/v4"
    if not root.is_dir():
        raise RatchetError("archive does not contain package/src/v4")
    return sorted(
        path
        for path in root.rglob("*.ts")
        if not path.name.endswith(".test.ts") and "tests" not in path.relative_to(root).parts
    )


def write_project(package: Path) -> Path:
    project = package / "tsconfig.benchmark.json"
    config = {
        "compilerOptions": {
            "target": "ES2022",
            "module": "NodeNext",
            "moduleResolution": "NodeNext",
            "strict": True,
            "noEmit": True,
            "skipLibCheck": True,
            "types": [],
            "pretty": False,
        },
        "include": ["src/v4/**/*.ts"],
        "exclude": ["src/v4/**/*.test.ts", "src/v4/**/tests/**"],
    }
    project.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    return project


def run_compiler(compiler: Path, project: Path) -> tuple[int, str]:
    binary = compiler.resolve()
    if not binary.is_file():
        raise RatchetError(f"compiler does not exist: {binary}")
    proc = subprocess.run(
        [
            str(binary),
            f"--project={project}",
            "--pretty=false",
            "--home-list-unmodeled-any",
        ],
        cwd=project.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if proc.returncode not in (0, 1):
        tail = "\n".join((proc.stdout or "").splitlines()[-20:])
        raise RatchetError(
            f"compiler exited {proc.returncode}; expected 0 or diagnostic exit 1"
            + (f"\n{tail}" if tail else "")
        )
    return proc.returncode, proc.stdout or ""


def write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    baseline = load_baseline(args.baseline)
    corpus = baseline["corpus"]
    assert isinstance(corpus, dict)

    with tempfile.TemporaryDirectory(prefix="home-zod-unmodeled-") as temporary:
        work = Path(temporary)
        archive = obtain_archive(corpus, args.archive, work / "corpus.tgz")
        package = extract_archive(archive, work / "source")
        sources = production_sources(package)
        expected_files = int(corpus["production_files"])
        if len(sources) != expected_files:
            raise RatchetError(
                f"production source count mismatch: expected {expected_files}, got {len(sources)}"
            )
        project = write_project(package)
        compiler_exit, output = run_compiler(args.compiler, project)

        if args.diagnostics_output:
            args.diagnostics_output.parent.mkdir(parents=True, exist_ok=True)
            args.diagnostics_output.write_text(output, encoding="utf-8")

        count = sum(1 for line in output.splitlines() if HM9002_RE.search(line))
        maximum = int(baseline["max_unmodeled_any"])
        current = {
            "compiler_exit": compiler_exit,
            "corpus": corpus,
            "max_unmodeled_any": maximum,
            "unmodeled_any": count,
        }
        if args.write_current:
            write_json(args.write_current, current)

        print(
            f"{corpus['name']} {corpus['version']} unmodeled-any recoveries: "
            f"current={count} baseline={maximum} production_files={len(sources)}"
        )
        if count > maximum:
            print(f"error: HM9002 count regressed by {count - maximum}", file=sys.stderr)
            return 1
        if count < maximum:
            print(
                f"note: HM9002 count improved by {maximum - count}; lower the checked-in baseline",
                file=sys.stderr,
            )
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RatchetError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
