---
title: Monorepo Structure
description: Navigate Home's current repository layout, package conventions, root build files, generated directories, and validation boundaries.
---

# Monorepo structure

Home is organized as a Zig-first monorepo. The `packages/` directory currently
contains many focused subsystems; not every directory is independently
versioned, build-wired or language-facing.

## Root layout

```text
home/
├── build.zig             # Zig build graph
├── package.json          # Documentation and JavaScript tooling scripts
├── bunfig.toml           # Bun install behavior
├── pantry.json           # Repository toolchain/dependency bootstrap
├── src/                  # Main Home CLI and command helpers
├── packages/             # Compiler, runtime, tooling and subsystem packages
├── tests/                # Home integration and acceptance fixtures
├── bench/                # Benchmark drivers and fixtures
├── examples/             # Example programs
├── docs/                 # BunPress site source
└── scripts/              # Reproducible maintenance and measurement commands
```

Older documents referred to a root `ion.toml` and `src/ion.zig`. Those are not
the current repository entrypoints.

## Package families

The package graph is easier to understand by role.

### Home language frontend

`lexer`, `ast`, `parser`, `types`, `compiler`, `interpreter`,
`optimizer`, `codegen`, `diagnostics`, `comptime`, `modules`,
`patterns`, `traits` and related packages.

### TypeScript frontend

`ts_lexer`, `ts_parser`, `binder`, `hir`, `ts_checker`, `ts_program`,
`ts_resolver`, `ts_driver`, `ts_emit`, `ts_lsp`, `ts_lsp_server` and
`ts_conformance`.

### Runtime and compatibility

`runtime`, `compat`, `bundler`, `http`, `net`, `fs`, `io`,
`websocket` and related runtime subsystems.

### Tooling

`formatter`, `linter`, `lsp`, `tools`, `docgen`, `pkg`, `registry`
and `vscode-home`.

### Platform work

`kernel`, `bootloader`, `drivers`, `syscall`, `usb`, `dtb`, `iommu`
and other target-specific packages.

A package directory can be source backlog or experimental work. Check
`build.zig`, focused tests and the
[capability matrix](/docs/CAPABILITY_MATRIX) before calling it supported.

## Package conventions

Depending on its role, a package may contain:

- `src/` for implementation.
- `tests/` for focused Zig tests.
- `build.zig` for an independently buildable Zig graph.
- `home.toml` for Home package metadata.
- `package.json` for JavaScript tooling or generated upstream content.

These files are not universal. Do not assume every package has all of them.

## Generated and installed directories

Common local-only outputs include:

- `.zig-cache/` and `zig-out/` from Zig.
- `node_modules/` and `pantry/` for installed dependencies.
- `dist/` for generated documentation or application output.
- `.home/` and `.home-cache/` for Home package/compiler state.

Generated output is not evidence that its source is tracked, and installed
dependencies should not be edited as project source.

## Adding or moving a package

A package move is complete only when all relevant wiring moves with it:

1. Update `build.zig` module definitions and imports.
2. Update package metadata and JavaScript workspace references if present.
3. Update source imports and tests.
4. Run the focused package tests.
5. Run the nearest aggregate build or integration gate.
6. Update architecture and capability documentation when the public boundary
   changes.

## Related pages

- [Architecture](/docs/ARCHITECTURE)
- [Compiler pipeline](/docs/COMPILER_PIPELINE)
- [Tooling index](/docs/TOOLING_INDEX)
