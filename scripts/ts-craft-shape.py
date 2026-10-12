#!/usr/bin/env python3
"""Type-check a Craft-shaped multi-package project with ``home-tsc``.

Craft (the native app toolkit) type-checks each package with ``tsc``. This
regression reproduces its shape: a root ``tsconfig.json`` that packages extend,
``types: ["bun"]`` and ``["node", "bun"]``, a React package with ``lib: DOM`` and
automatic ``@types`` inclusion, ``paths`` into a sibling package, and a
``node_modules`` dependency whose ``.d.ts`` files carry
``/// <reference types="bun" />``. The fixture sources live in
``tests/ts_real_world/craft_shape``; the pinned npm packages (``@types/node``,
``@types/react``, ``bun-types``...) are downloaded and verified by SHA-512.

Every project must report zero diagnostics within the per-project time budget.
With ``--tsgo`` the same projects are also checked by TypeScript's native
compiler and both outputs must agree (both empty).

The TypeScript library files come from ``HOME_TSC_LIB_DIR`` (default: the
pinned ``_submodules/typescript-go/internal/bundled/libs``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request


class ShapeError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=root / "zig-out/bin/home-tsc")
    parser.add_argument("--fixture", type=Path, default=root / "tests/ts_real_world/craft_shape")
    parser.add_argument("--lib-dir", type=Path, default=None, help="TypeScript lib directory (HOME_TSC_LIB_DIR)")
    parser.add_argument("--cache", type=Path, default=None, help="directory holding downloaded tarballs")
    parser.add_argument("--tsgo", type=Path, default=None, help="also run this tsc/tsgo binary and compare")
    parser.add_argument("--keep", action="store_true", help="keep the generated project directory")
    return parser.parse_args()


def fetch(package: dict[str, str], cache: Path) -> Path:
    name = package["name"].replace("/", "__")
    archive = cache / f"{name}-{package['version']}.tgz"
    if not archive.is_file():
        tmp = archive.with_suffix(".partial")
        try:
            with urllib.request.urlopen(package["url"], timeout=60) as response, tmp.open("wb") as out:
                shutil.copyfileobj(response, out)
        except OSError as exc:
            raise ShapeError(f"cannot download {package['url']}: {exc}") from exc
        tmp.rename(archive)
    digest = hashlib.sha512(archive.read_bytes()).hexdigest()
    if digest != package["sha512"]:
        raise ShapeError(f"SHA-512 mismatch for {package['name']}@{package['version']}")
    return archive


def extract(archive: Path, destination: Path) -> None:
    """Extract an npm tarball's `package/` tree without trusting tar paths."""
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts or not relative.parts:
                raise ShapeError(f"unsafe archive path: {member.name}")
            parts = relative.parts[1:]
            if not parts:
                continue
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                continue
            source = bundle.extractfile(member)
            if source is None:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("wb") as out:
                shutil.copyfileobj(source, out)


def build_project(fixture: Path, manifest: dict, workdir: Path, cache: Path) -> Path:
    project = workdir / "craft"
    shutil.copytree(fixture, project, ignore=shutil.ignore_patterns("packages.json"))
    modules = project / "node_modules"
    for package in manifest["packages"]:
        extract(fetch(package, cache), modules / package["name"])
    shutil.move(str(project / "vendor/map-dist"), str(modules / "map-dist"))
    shutil.rmtree(project / "vendor")
    return project


def run(binary: Path, project_dir: Path, env: dict[str, str]) -> tuple[int, str, float]:
    started = time.monotonic()
    proc = subprocess.run(
        [str(binary), "--noEmit", "--pretty", "false"],
        cwd=project_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout or "", time.monotonic() - started


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((args.fixture / "packages.json").read_text(encoding="utf-8"))
    lib_dir = args.lib_dir or Path(os.environ.get("HOME_TSC_LIB_DIR", root / "_submodules/typescript-go/internal/bundled/libs"))
    if not (lib_dir / "lib.es5.d.ts").is_file():
        raise ShapeError(f"no TypeScript libraries at {lib_dir}; set --lib-dir or HOME_TSC_LIB_DIR")
    env = dict(os.environ, HOME_TSC_LIB_DIR=str(lib_dir.resolve()))
    budget = float(manifest["max_seconds_per_project"])

    workdir = Path(tempfile.mkdtemp(prefix="home-craft-shape-"))
    cache = args.cache or workdir / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    try:
        project = build_project(args.fixture, manifest, workdir, cache)
        for relative in manifest["projects"]:
            package_dir = project / relative
            code, output, seconds = run(args.compiler.resolve(), package_dir, env)
            status = "ok" if code == 0 and not output.strip() else "FAIL"
            print(f"{relative}: home-tsc exit={code} {seconds:.2f}s {status}")
            if output.strip():
                print("\n".join("  " + line for line in output.strip().splitlines()[:40]))
            if code != 0 or output.strip():
                failures.append(f"{relative}: diagnostics")
            if seconds > budget:
                failures.append(f"{relative}: {seconds:.2f}s exceeds the {budget:.0f}s budget")
            if args.tsgo is not None:
                tsgo_code, tsgo_output, tsgo_seconds = run(args.tsgo.resolve(), package_dir, env)
                print(f"{relative}: tsgo exit={tsgo_code} {tsgo_seconds:.2f}s")
                if tsgo_code != 0 or tsgo_output.strip():
                    failures.append(f"{relative}: tsgo itself reports diagnostics (fixture bug)\n{tsgo_output}")
        if args.keep:
            print(f"project kept at {project}")
    finally:
        if not args.keep:
            shutil.rmtree(workdir, ignore_errors=True)
    if failures:
        print("craft-shape: FAILED\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    print("craft-shape: all projects clean")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ShapeError as exc:
        print(f"craft-shape: {exc}", file=sys.stderr)
        sys.exit(2)
