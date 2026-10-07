---
title: Package Manager Roadmap
description: Separate the package-manager capabilities Home already implements from the correctness, reproducibility, workspace, cache, and UX work that still needs evidence.
---

# Package manager roadmap

This roadmap describes the current implementation rather than a speculative
Bun feature list. Status is based on `src/main.zig` and
`packages/pkg/src/package_manager.zig`.

## Implemented foundation

| Capability | Evidence |
|---|---|
| Registry, Git and URL dependency variants | Native dependency model and `home pkg add` routing |
| Parallel downloads | Native installer uses up to eight worker threads |
| Project cache and install roots | `.home/cache` and `pantry/` |
| Native lockfile emission | `home pkg install` writes `home.lock` |
| Registry authentication | `login`, `logout` and `whoami` |
| Package scripts | `home pkg run` and `home pkg scripts` read `home.toml` |
| Toolchain bootstrap | `home pkg tools` delegates to Pantry |
| Ecosystem operations | Search, audit, publish and related commands delegate to Pantry |
| Declaration tooling | Generate, check and compare `.d.hm` package declarations |

Implemented means code exists on the active command path. It does not imply the
whole package manager is stable.

## Correctness work

### Unify configuration behavior

The shared configuration loader and package manager currently have different
precedence lists. The package manager also has full JSON/JSONC dependency
parsing but only simplified TOML dependency loading.

Exit criteria:

- One documented precedence contract, or explicitly named contracts for
  distinct consumers.
- Round-trip tests for every accepted writable format.
- JSONC writes select JSON serialization rather than falling through to TOML.
- `home pkg init`, `add`, `remove` and `install` agree on the same
  manifest.
- Comments and unrelated fields survive a supported mutation path, or the CLI
  clearly rejects that format as read-only.

### Complete version resolution

The parser recognizes common range prefixes but currently normalizes them to a
single semantic version.

Exit criteria:

- Exact, caret, tilde and comparison ranges have table-driven tests.
- Prerelease ordering and incompatible-major behavior match the documented
  contract.
- Transitive conflicts produce deterministic diagnostics.

### Make lockfiles authoritative

The active path writes `home.lock`, while a separate experimental module uses
the name `.freezer`. Lockfile loading is currently simplified.

Exit criteria:

- One active lockfile format and filename.
- A clean install consumes the lock without contacting the resolver when all
  artifacts are available.
- Checksums, source identity and transitive edges round-trip.
- Tampering fails closed with a useful diagnostic.

## Performance and storage work

Parallel downloads are already present. Remaining performance work should be
measured rather than inferred:

- Content-addressed global storage with project links.
- Deduplication across projects.
- Bounded concurrency and cancellation.
- Resumable downloads.
- Offline installs from a verified cache.
- Benchmarks that report fixture size, network setup, warm/cold state, machine,
  repeat count and median.

## Workspace work

Workspace metadata exists in the native config type, but complete workspace
installation is not yet proven.

Exit criteria:

- Root discovery and include/exclude rules.
- Cross-workspace dependency linking.
- Deterministic hoisting.
- A single lockfile for a multi-package fixture.
- Focused tests for cycles, duplicate names and version conflicts.

## Security and UX work

- Verify every downloaded artifact before extraction.
- Prevent archive traversal and unsafe symlink extraction.
- Redact registry credentials from diagnostics.
- Add progress output based on measured bytes without changing non-interactive
  output.
- Keep machine-readable output stable for CI.

## Acceptance gate

The package manager should move from **in progress** to **stable** only after a
fresh temporary project can initialize, add each supported source type, install
from a clean cache, reinstall from the lockfile with networking disabled, run a
script, and reject a corrupted artifact through the public `home pkg` CLI.
