#!/usr/bin/env python3
"""Inventory local tsc entrypoints without executing package scripts.

The report deliberately keeps configs without scripts and indirect type-check
scripts: neither is proof of replacement readiness. Dependency/cache directories
are pruned and recorded, while fixtures, nested packages and framework configs
remain visible. No symlink directory is followed, preventing recursion into
external trees; symlinked directories are listed separately for follow-up.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shlex

PRUNED_NAMES = frozenset((".git", "node_modules", "pantry", ".zig-cache", ".zig-global-cache", "zig-out", ".cache", ".home-cache"))
TSC = re.compile(r"(?<![\w-])tsc(?:\.js)?(?![\w.-])")
CONFIG = re.compile(r"tsconfig(?:\..*)?\.json$")


def command_segments(script: str) -> list[list[str]]:
    lexer = shlex.shlex(script, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    segments: list[list[str]] = [[]]
    for token in lexer:
        if token and all(character in ";&|()" for character in token):
            segments.append([])
        else:
            segments[-1].append(token)
    return [segment for segment in segments if segment]


def inventory(root: Path) -> dict:
    root = root.resolve()
    report: dict = {"schema": 1, "root": str(root), "pruned_names": sorted(PRUNED_NAMES),
                    "manifests": [], "configs": [], "symlink_directories": [], "included_pruned_name_projects": [], "errors": [],
                    "replacement_verified": False}

    def walk_error(error: OSError) -> None:
        report["errors"].append({"path": error.filename, "error": str(error)})

    for dirname, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        directory = Path(dirname)
        candidates = []
        for name in sorted(dirs):
            path = directory / name
            # A cache-like name can also identify an actual checkout (e.g.
            # ~/Code/pantry). A Git directory or worktree pointer distinguishes
            # that project from installed toolchain/dependency directories.
            project = name != ".git" and name in PRUNED_NAMES and (path / ".git").exists()
            if name in PRUNED_NAMES and not project:
                continue
            if path.is_symlink():
                report["symlink_directories"].append(str(path.relative_to(root)))
                continue
            if project:
                report["included_pruned_name_projects"].append(str(path.relative_to(root)))
            candidates.append(name)
        dirs[:] = candidates
        for name in sorted(files):
            path = directory / name
            if name != "package.json" and not CONFIG.fullmatch(name):
                continue
            relative = str(path.relative_to(root))
            try:
                data = path.read_bytes()
            except OSError as error:
                walk_error(error)
                continue
            identity = {"path": relative, "sha256": hashlib.sha256(data).hexdigest()}
            if name != "package.json":
                report["configs"].append(identity)
                continue
            try:
                manifest = json.loads(data)
                if not isinstance(manifest, dict):
                    raise ValueError("package manifest is not an object")
            except (ValueError, UnicodeError) as error:
                report["errors"].append({"path": relative, "error": str(error)})
                continue
            scripts = manifest.get("scripts", {})
            if not isinstance(scripts, dict):
                report["errors"].append({"path": relative, "error": "scripts is not an object"})
                continue
            entrypoints = []
            for label, script in sorted(scripts.items()):
                if not isinstance(script, str) or not (TSC.search(script) or "typecheck" in label or "check:types" in label):
                    continue
                entry = {"name": label, "script": script, "compiler_segments": [], "requires_review": []}
                try:
                    segments = command_segments(script)
                except ValueError as error:
                    entry["requires_review"].append(str(error))
                    segments = []
                # Shell directory changes and substitutions cannot be reconstructed
                # by token splitting, so retain them explicitly as unresolved work.
                if any(segment[0] == "cd" for segment in segments) or "$" in script or "`" in script:
                    entry["requires_review"].append("shell context or substitutions")
                for segment in segments:
                    if "tsc" in segment:
                        index = segment.index("tsc")
                        prefix = segment[:index]
                        known_prefixes = ([], ["bun"], ["bun", "--bun"], ["bun", "x"], ["bun", "x", "--bun"],
                                          ["bunx"], ["bunx", "--bun"], ["npx"], ["pnpm", "exec"], ["yarn"], ["yarn", "exec"])
                        if prefix not in known_prefixes:
                            entry["requires_review"].append("unrecognized runner prefix")
                        entry["compiler_segments"].append({"prefix": prefix, "args": segment[index + 1:]})
                if not entry["compiler_segments"]:
                    entry["requires_review"].append("indirect checker or wrapper")
                entrypoints.append(entry)
            if entrypoints:
                report["manifests"].append({**identity, "name": manifest.get("name"), "entrypoints": entrypoints})
    for key in ("manifests", "configs"):
        report[key].sort(key=lambda item: item["path"])
    report["symlink_directories"].sort()
    report["included_pruned_name_projects"].sort()
    report["counts"] = {"manifests_with_check_scripts": len(report["manifests"]),
                        "configs": len(report["configs"]),
                        "scripts": sum(len(row["entrypoints"]) for row in report["manifests"]),
                        "tsc_segments": sum(len(entry["compiler_segments"]) for row in report["manifests"] for entry in row["entrypoints"]),
                        "unresolved_scripts": sum(bool(entry["requires_review"]) for row in report["manifests"] for entry in row["entrypoints"]),
                        "errors": len(report["errors"])}
    return report


def project_scope(report: dict) -> dict:
    """Assign every inventoried source to its nearest Git checkout.

    Config-only projects and unreadable manifests remain in scope. Worktree
    checkouts share a canonical Git identity, without executing any Git or
    package command. Ownership never implies replacement qualification.
    """
    root = Path(report["root"]).resolve()
    owners = {}
    errors = []
    groups = {}
    sources = []
    drift = []

    def owner(directory):
        visited = []
        current = directory
        result = None
        while current == root or root in current.parents:
            if current in owners:
                result = owners[current]
                break
            visited.append(current)
            marker = current / ".git"
            try:
                if marker.is_dir():
                    common = marker.resolve()
                elif marker.is_file() or marker.is_symlink():
                    text = marker.read_text().strip()
                    if not text.startswith("gitdir:") or not text[7:].strip():
                        raise ValueError("invalid Git worktree pointer")
                    target = Path(text[7:].strip())
                    gitdir = (target if target.is_absolute() else current / target).resolve()
                    if not gitdir.is_dir():
                        raise ValueError("Git worktree directory is missing")
                    common_file = gitdir / "commondir"
                    if common_file.is_file() or common_file.is_symlink():
                        common_path = common_file.read_text().strip()
                        if not common_path:
                            raise ValueError("empty common Git directory pointer")
                        common = (gitdir / common_path).resolve()
                    else:
                        common = gitdir
                    if not common.is_dir():
                        raise ValueError("common Git directory is missing")
                else:
                    current = current.parent
                    continue
                result = {"checkout": str(current.relative_to(root)), "common_git_dir": str(common)}
            except (OSError, ValueError, UnicodeError) as error:
                errors.append({"path": str(marker.relative_to(root)), "error": str(error)})
            break
        for directory in visited:
            owners[directory] = result
        return result

    for kind, entries in (("manifest", report["manifests"]), ("config", report["configs"]),
                          ("inventory-error", report["errors"])):
        for entry in entries:
            record = {"kind": kind, "path": entry.get("path"), "owner": None, "replacement_verified": False}
            sources.append(record)
            try:
                path = Path(entry["path"])
                if not path.is_absolute():
                    path = root / path
                if ".." in path.parts or not path.is_relative_to(root):
                    raise ValueError("inventory source is outside its root")
                record["owner"] = owner(path.parent)
                if "sha256" in entry or path.is_file():
                    record["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                if "sha256" in entry:
                    record["matches_inventory"] = record["sha256"] == entry["sha256"]
                    if not record["matches_inventory"]:
                        drift.append(record["path"])
            except (OSError, ValueError, TypeError, KeyError) as error:
                errors.append({"path": entry.get("path"), "error": str(error)})
            if record["owner"]:
                key = record["owner"]["common_git_dir"]
                group = groups.setdefault(key, {"checkouts": set(), "counts": Counter(), "replacement_verified": False})
                group["checkouts"].add(record["owner"]["checkout"])
                group["counts"][kind] += 1
    for group in groups.values():
        group["checkouts"] = sorted(group["checkouts"])
        group["counts"] = dict(sorted(group["counts"].items()))
    summary = {
        "manifest_script_git_groups": sum(bool(g["counts"].get("manifest")) for g in groups.values()),
        "total_canonical_git_groups": len(groups),
        "additional_config_only_git_groups": sum(bool(g["counts"].get("config")) and not g["counts"].get("manifest") for g in groups.values()),
        "additional_error_only_git_groups": sum(bool(g["counts"].get("inventory-error")) and not g["counts"].get("manifest") and not g["counts"].get("config") for g in groups.values()),
        "unresolved_ownership_records": sum(row["owner"] is None for row in sources),
        "source_records": len(sources),
        "input_hash_drift": len(drift),
        "scope_errors": len(errors),
        "all_project_replacement_verified": False,
    }
    return {"summary": summary, "groups": dict(sorted(groups.items())), "sources": sources,
            "changed_inputs": drift, "errors": errors, "all_project_replacement_verified": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "Code")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scope-output", type=Path, help="Also retain Git ownership of manifests, configs and inventory errors")
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error(f"not a directory: {args.root}")
    report = inventory(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    scope_errors = False
    if args.scope_output:
        scope = project_scope(report)
        args.scope_output.parent.mkdir(parents=True, exist_ok=True)
        args.scope_output.write_text(json.dumps(scope, indent=2) + "\n")
        scope_errors = bool(scope["errors"] or scope["changed_inputs"])
    print(json.dumps(report["counts"], sort_keys=True))
    raise SystemExit(1 if report["errors"] or scope_errors else 0)


if __name__ == "__main__":
    main()
