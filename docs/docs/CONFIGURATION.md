---
title: Project Configuration
description: Choose the configuration file Home actually reads, understand loader precedence, and distinguish compiler settings from the evolving package-manager manifest path.
---

# Project configuration

Home has more than one configuration consumer. Their accepted files and
precedence are not identical, so the command you run determines which manifest
is read.

## Shared tool configuration

The shared `ConfigLoader`, used by tools such as the linter, checks the current
directory in this order and stops at the first file found:

1. `home.jsonc`
2. `home.json`
3. `package.jsonc`
4. `package.json`
5. `home.toml`
6. `couch.toml`

For new tool configuration, `home.jsonc` is the clearest project-specific
choice.

```jsonc
{
  // Tool settings live in named sections.
  "linter": {
    "max_line_length": 100,
    "indent_size": 2,
    "use_spaces": true,
  },
}
```

JSONC supports line and block comments. Individual tools define the sections
and fields they consume.

## Package-manager configuration

The native package manager currently has its own lookup order:

1. `couch.jsonc`
2. `couch.json`
3. `home.json`
4. `package.jsonc`
5. `package.json`
6. `home.toml`
7. `couch.toml`

This is an implementation detail of
`packages/pkg/src/package_manager.zig`, not the shared-loader order above.
The package manager remains marked **in progress** in the
[capability matrix](/docs/CAPABILITY_MATRIX#tooling).

`home pkg init` creates `home.toml` and a `deps.yaml` toolchain file.
`home init` creates `package.jsonc` for a full application scaffold. These
commands intentionally have different scopes.

## JSON package shape

The package parser reads `name`, `version` and `dependencies` from JSON and
JSONC input.

```jsonc
{
  "name": "my-home-project",
  "version": "0.1.0",
  "dependencies": {
    "http-router": "1.0.0",
    "zyte": {
      "git": "https://github.com/home-lang/zyte.git",
      "rev": "main",
    },
    "archive": {
      "url": "https://example.com/archive.tar.gz",
    },
  },
}
```

The current parser accepts an exact semantic version string and recognizes
leading `^`, `~` or `>=` syntax, but it normalizes those inputs to a semantic
version. It does not yet implement full range selection semantics, so do not
document a resolved range as if npm-compatible behavior were proven.

JSONC can currently be read, but the package-manager save path only selects
JSON serialization for a `.json` suffix. Until JSONC round-trip handling is
fixed, do not use a mutating `home pkg` command on a JSONC manifest.

## TOML package shape

`home pkg init` produces this shape:

```toml
[package]
name = "my-home-project"
version = "0.1.0"
authors = []

[toolchain]
manager = "pantry"
file = "deps.yaml"

[dependencies]

[scripts]
dev = "home run src/main.home --watch"
test = "home test tests/"
```

Script execution has a dedicated TOML reader used by `home pkg run` and
`home pkg scripts`. General TOML dependency loading is still simplified, so
review package-manager output and keep the manifest under version control.

## Toolchain files

Project toolchains are managed separately through Pantry. `home pkg tools`
recognizes `deps.yaml`, `dependencies.yaml` and `pantry.yaml`, then delegates
installation to the external `pantry` executable.

The Home repository itself also has a root `pantry.json` consumed directly by
Pantry. Do not treat that repository bootstrap file as the universal
application configuration format.

## Migration from obsolete names

Older documentation used `ion.jsonc`, `ion.json`, `ion.toml` and commands
such as `ion run`. Those names are obsolete. Use the `home` command and one of
the current filenames listed above.

## Related pages

- [Package management](/docs/PACKAGE-MANAGEMENT)
- [Pantry integration](/docs/PANTRY_INTEGRATION)
- [Tooling](/docs/features/tooling)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
