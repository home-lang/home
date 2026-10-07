---
title: Pantry Integration Boundary
description: Trace how `home pkg` routes native package operations, Pantry pass-through commands, project toolchain installation, and local inspection helpers.
---

# Pantry integration boundary

Home exposes one `home pkg` namespace, but its subcommands have three different
implementations. Knowing the route prevents documentation from attributing
native behavior to Pantry or Pantry behavior to Home.

## Command routing

| Route | Commands | Implementation |
|---|---|---|
| Native package manager | `init`, `login`, `logout`, `whoami`, `add`, `remove`, `update`, `install` | Home's Zig package manager |
| Toolchain delegation | `tools`, `toolchain` | Validates a YAML toolchain file, then runs `pantry install` |
| Pantry pass-through | `search`, `info`, `audit`, `dedupe`, `link`, `unlink`, `publish`, `pack`, `version`, `doctor`, `clean` | Runs the matching Pantry subcommand |
| Home inspection and generation | `tree`, `why`, `outdated`, `size`, `declarations`, `docs`, `api-diff`, `run`, `scripts` | Home CLI helpers, with Pantry preferred by some inspection commands |

The routing table is implemented in `pkgCommand` in `src/main.zig`.

## Process behavior

Delegated commands spawn the `pantry` executable with the original
subcommand arguments and wait for it to finish. A non-zero Pantry exit code is
returned to the caller. If the executable is missing, Home prints an explicit
error and exits unsuccessfully.

Home does not:

- Search a contributor-specific absolute path for Pantry.
- Download Pantry silently during a package command.
- Swallow a failed Pantry exit code.
- Echo registry credentials in the missing-executable error.

## Toolchain files

`home pkg tools` recognizes `deps.yaml`, `dependencies.yaml` and
`pantry.yaml`. A new `home pkg init` project receives `deps.yaml`.

```bash
home pkg init
home pkg tools
```

The first command creates the manifest and toolchain declaration. The second
delegates installation to Pantry.

## Package files are a different layer

Native dependency operations use the manifest and lockfile rules documented in
[package management](/docs/PACKAGE-MANAGEMENT). In particular, the current
native path writes `home.lock`; old documentation that described
`pantry-lock.json` or `.freezer` as the active `home pkg install` output was
not describing the current command path.

## Contributor guidance

When changing this integration:

1. Add a process-level test that supplies a controlled Pantry executable.
2. Assert argument forwarding and exit-code propagation.
3. Test the missing-executable diagnostic.
4. Keep native and delegated command lists synchronized with the help text.
5. Update this routing table and the package-management guide in the same
   change.

## Related pages

- [Pantry toolchain management](/docs/PANTRY)
- [Package management](/docs/PACKAGE-MANAGEMENT)
- [Package-manager roadmap](/docs/PACKAGE-MANAGER-IMPROVEMENTS)
