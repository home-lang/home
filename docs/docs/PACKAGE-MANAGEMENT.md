---
title: Package Management
description: Use Home's current `home pkg` command surface, understand which operations are native or delegated to Pantry, and track the manifest and lockfile limitations.
---

# Package management

Home's package manager is under active development. The CLI has native
dependency commands and Pantry-backed ecosystem commands, but the full manifest,
resolution and reproducibility contract is not yet stable.

## Initialize a package

```bash
home pkg init
```

The command creates:

- `home.toml`, with package metadata, dependencies, toolchain settings and
  scripts.
- `deps.yaml`, which pins the project toolchain for Pantry.

It does not create source files; use `home init [name]` for a complete
application scaffold.

## Native dependency commands

| Command | Current behavior |
|---|---|
| `home pkg add name@1.2.3` | Adds a registry dependency, resolves it and rewrites the active package manifest. |
| `home pkg add owner/repository` | Expands the GitHub shortcut to an HTTPS Git URL. |
| `home pkg add https://example.com/archive.tar.gz` | Adds a direct URL dependency. |
| `home pkg remove name` | Removes a dependency and resolves again. |
| `home pkg install` | Resolves configured dependencies, writes `home.lock` and downloads packages. |
| `home pkg update` | Drops the in-memory lock state and resolves again. |
| `home pkg login`, `logout`, `whoami` | Manages registry authentication. |
| `home pkg run name`, `scripts` | Reads the `[scripts]` table from `home.toml`. |

The current `add` parser supports a GitHub shortcut or a registry version, but
not a combined `owner/repository@revision` shortcut. Put a Git URL and `rev`
in a JSON manifest when a specific Git revision is required.

## Commands delegated to Pantry

Home forwards these commands to the external `pantry` executable:

- `search`, `info`, `audit` and `dedupe`
- `link`, `unlink`, `publish`, `pack` and `version`
- `doctor` and `clean`

`home pkg tools` and `home pkg toolchain` also delegate tool installation to
Pantry after checking for `deps.yaml`, `dependencies.yaml` or
`pantry.yaml`.

If Pantry is not installed, delegated commands fail with an explicit
installation message rather than silently changing behavior.

## Local inspection commands

Home implements additional project-facing commands, including:

```bash
home pkg tree
home pkg why <package>
home pkg outdated
home pkg size [path]
home pkg declarations
home pkg declarations --check
home pkg docs
home pkg api-diff old.d.hm new.d.hm
```

Some inspection paths are intentionally preliminary. For example, the local
`tree` fallback currently checks for `home.lock` but does not render the full
locked dependency graph.

## Manifests and precedence

Package-manager lookup currently checks:

1. `couch.jsonc`
2. `couch.json`
3. `home.json`
4. `package.jsonc`
5. `package.json`
6. `home.toml`
7. `couch.toml`

See [project configuration](/docs/CONFIGURATION) for the separate shared-tool
loader order and current parsing limits.

## Dependency sources

The native data model supports registry, Git and direct URL sources. A local
source variant exists internally, but the current JSON parser does not yet turn
a `{ "path": "..." }` entry into a dependency, so local path dependencies
should not be advertised as complete.

## Lockfile and storage

The active native package-manager path writes `home.lock`. It installs into
the project `pantry/` directory and uses `.home/cache` as its cache root.

A separate experimental lockfile module describes `.freezer`, but the current
`home pkg install` implementation does not write that file. Commit
`home.lock` when using the native package-manager path, and do not commit the
installed `pantry/` tree.

Lockfile loading and transitive resolution are still simplified. A generated
file is useful development evidence, but it should not yet be presented as a
fully audited reproducible-install guarantee.

## Current limitations

- TOML dependency parsing is incomplete.
- JSONC manifests are readable, but mutating package commands do not yet
  preserve their format.
- Full semantic-version range selection is not implemented.
- Lockfile loading does not yet reconstruct the complete package graph.
- Workspace hoisting and cross-workspace linking are not complete.
- Integrity and offline-install behavior need end-to-end acceptance tests.

Track package-manager maturity in the
[capability matrix](/docs/CAPABILITY_MATRIX#tooling).

## Related pages

- [Configuration](/docs/CONFIGURATION)
- [Pantry](/docs/PANTRY)
- [Pantry integration](/docs/PANTRY_INTEGRATION)
- [Package-manager roadmap](/docs/PACKAGE-MANAGER-IMPROVEMENTS)
