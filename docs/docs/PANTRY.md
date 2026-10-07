---
title: Pantry Toolchain Management
description: Understand how Home delegates project toolchain and ecosystem operations to Pantry, which files Home creates, and where native package management remains separate.
---

# Pantry toolchain management

Pantry is an external tool used by Home for project toolchains and selected
package-ecosystem operations. Home does not embed Pantry's implementation.

## Project bootstrap

`home pkg init` writes a `deps.yaml` file like this:

```yaml
# Project toolchain managed by pantry.
# Run: home pkg tools
dependencies:
  - ziglang.org@0.17.0-dev.2163+89ff10d56
  - bun
```

The exact pinned versions evolve with the repository. Treat the generated file,
not this example, as authoritative.

`home pkg tools` accepts any extra arguments and delegates to:

```bash
pantry install [arguments...]
```

Before delegating, Home requires one of these project files:

- `deps.yaml`
- `dependencies.yaml`
- `pantry.yaml`

## Direct Pantry use in this repository

The Home repository currently has a root `pantry.json` and a generated
`pantry/` install tree. That is the repository's own Pantry setup. It does not
change which files `home pkg tools` recognizes in a generated Home project.

Use Pantry directly when working with Pantry-specific commands or repository
bootstrap behavior:

```bash
pantry install
pantry list
pantry info bun
```

Consult the installed Pantry version for its complete command and file-format
reference.

## Native Home package management is separate

The native `home pkg add`, `remove`, `install` and `update` commands use
Home's package-manager implementation. Their current paths are:

- Package manifests such as `home.toml`, `home.json` or `package.json`.
- `home.lock` for the active native lockfile.
- `.home/cache` for the project cache.
- `pantry/` for installed dependencies.

The directory name `pantry/` does not mean those commands are automatically
implemented by the external Pantry CLI. See
[package management](/docs/PACKAGE-MANAGEMENT) for the exact boundary.

## Delegated ecosystem commands

Home forwards these `home pkg` subcommands to Pantry:

`search`, `info`, `audit`, `dedupe`, `link`, `unlink`, `publish`,
`pack`, `version`, `doctor` and `clean`.

A missing Pantry executable is reported as an error. Home does not substitute a
different registry or fabricate successful output.

## Reproducibility guidance

- Commit the project toolchain declaration used by the project.
- Keep generated install directories out of version control.
- Run installation in CI from a clean checkout.
- Record the Pantry version when publishing performance or reproducibility
  results.
- Do not copy machine-specific absolute package paths into documentation.

## Related pages

- [Pantry integration boundary](/docs/PANTRY_INTEGRATION)
- [Package management](/docs/PACKAGE-MANAGEMENT)
- [Project configuration](/docs/CONFIGURATION)
