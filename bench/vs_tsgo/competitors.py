"""Pinned native competitor commands and lossless positive-output policies."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re


BASE_COMPILERS = {"tsc", "tsgo", "home"}
HASH = re.compile(r"[0-9a-f]{64}")
COUNT = r"(?:[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)"
CHECKED_FILES = re.compile(
    rf"✓ No type errors in {COUNT} files? \[[0-9]+(?:\.[0-9]+)?(?:ms|s)\]\r?\n?"
)


def successful_output(stdout: str, stderr: str, policy: str = "silent") -> bool:
    if policy == "silent":
        return not stdout and not stderr
    if policy == "checked-files":
        # One complete status line, on exactly one stream. Unknown output,
        # diagnostics, zero checked files, and silent success are not admitted.
        return bool(stdout) != bool(stderr) and CHECKED_FILES.fullmatch(stdout or stderr) is not None
    raise ValueError(f"unknown positive-output policy: {policy}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def payload_inventory(root: Path) -> dict[str, dict]:
    if not root.is_dir():
        raise ValueError(f"competitor payload directory is missing: {root}")
    entries = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"competitor payload inventory contains a symlink: {path}")
        if path.is_file():
            entries[path.relative_to(root).as_posix()] = {"sha256": sha256(path), "size": path.stat().st_size}
    if not entries:
        raise ValueError(f"competitor payload directory is empty: {root}")
    return entries


def inventory_hash(entries: dict) -> str:
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


@dataclass(frozen=True)
class Profile:
    name: str
    command: tuple[str, ...]
    version_command: tuple[str, ...]
    expected_version: str
    repository: str
    revision: str
    executable_sha256: str
    payloads: tuple[tuple[Path, str], ...]
    positive_output: str
    manifest_path: Path
    manifest_sha256: str

    def provenance(self, artifact) -> dict:
        manifest = artifact(self.manifest_path)
        executable = artifact(Path(self.command[0]))
        if manifest["sha256"] != self.manifest_sha256:
            raise ValueError("competitor manifest changed after it was loaded")
        if executable["sha256"] != self.executable_sha256:
            raise ValueError(f"{self.name} executable hash does not match its pin")
        payloads = []
        for root, expected in self.payloads:
            inventory = payload_inventory(root)
            digest = inventory_hash(inventory)
            if digest != expected:
                raise ValueError(f"{self.name} payload inventory does not match its pin: {root}")
            payloads.append({"path": str(root), "sha256": digest, "files": inventory})
        return {
            "command": list(self.command), "version_command": list(self.version_command),
            "expected_version": self.expected_version, "repository": self.repository,
            "revision": self.revision, "positive_output": self.positive_output,
            "executable": executable, "payloads": payloads, "manifest": manifest,
        }


def load_profiles(path: Path | None) -> dict[str, Profile]:
    if path is None:
        return {}
    path = path.resolve(strict=True)
    content = path.read_bytes()
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate competitor manifest field: {key}")
            result[key] = value
        return result
    data = json.loads(content, object_pairs_hook=unique_object)
    if (not isinstance(data, dict) or set(data) != {"schema", "compilers"}
            or type(data["schema"]) is not int or data["schema"] != 1):
        raise ValueError("competitor manifest requires schema 1 and compilers")
    if not isinstance(data["compilers"], list) or not data["compilers"]:
        raise ValueError("competitor manifest requires a nonempty compiler list")
    allowed = {"name", "command", "version_command", "expected_version", "repository", "revision",
               "executable_sha256", "payloads", "positive_output"}
    profiles = {}
    for entry in data["compilers"]:
        if not isinstance(entry, dict) or set(entry) != allowed:
            raise ValueError("competitor profile has missing or unknown fields")
        name = entry["name"]
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", name)
                or name in BASE_COMPILERS or name in profiles):
            raise ValueError("competitor name is invalid, reserved, or duplicated")
        for key in ("expected_version", "repository", "revision", "executable_sha256"):
            if not isinstance(entry[key], str) or not entry[key]:
                raise ValueError(f"competitor {key} must be a nonempty string")
        if not entry["repository"].startswith("https://") or not re.fullmatch(r"[0-9a-f]{40}", entry["revision"]):
            raise ValueError("competitor requires an HTTPS repository and exact Git revision")
        if not HASH.fullmatch(entry["executable_sha256"]):
            raise ValueError("competitor executable requires a SHA-256 pin")
        commands = []
        for key in ("command", "version_command"):
            argv = entry[key]
            if not isinstance(argv, list) or not argv or any(not isinstance(arg, str) or not arg or "\0" in arg for arg in argv):
                raise ValueError(f"competitor {key} must be a nonempty argument vector")
            executable = (path.parent / argv[0]).resolve(strict=True)
            if not executable.is_file():
                raise ValueError("competitor executable is not a file")
            commands.append((str(executable), *argv[1:]))
        if commands[0][0] != commands[1][0]:
            raise ValueError("competitor version probe must query the same executable")
        if entry["positive_output"] not in ("silent", "checked-files"):
            raise ValueError("unknown competitor positive-output policy")
        payloads = []
        if not isinstance(entry["payloads"], list) or not entry["payloads"]:
            raise ValueError("competitor requires pinned payload directories")
        for payload in entry["payloads"]:
            if (not isinstance(payload, dict) or set(payload) != {"path", "sha256"}
                    or not isinstance(payload["path"], str) or not payload["path"]
                    or not isinstance(payload["sha256"], str) or not HASH.fullmatch(payload["sha256"])):
                raise ValueError("invalid competitor payload pin")
            root = (path.parent / payload["path"]).resolve(strict=True)
            if not root.is_dir() or any(root == existing for existing, _ in payloads):
                raise ValueError("competitor payload directory is invalid or duplicated")
            payloads.append((root, payload["sha256"]))
        if not any(Path(commands[0][0]).is_relative_to(root) for root, _ in payloads):
            raise ValueError("competitor payload inventory must include its executable")
        profiles[name] = Profile(
            name, commands[0], commands[1], entry["expected_version"], entry["repository"],
            entry["revision"], entry["executable_sha256"], tuple(payloads), entry["positive_output"],
            path, hashlib.sha256(content).hexdigest(),
        )
    return profiles
