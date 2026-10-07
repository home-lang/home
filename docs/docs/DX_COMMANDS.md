---
title: Home CLI and DX Commands
description: Navigate Home's current command groups, execution routes, package aliases, and source-of-truth help without assuming every command is already stable.
---

# Home CLI and DX commands

The command list evolves quickly. `home help` from the binary under test is the
source of truth; this page groups the current routes and links to their detailed
status.

## Inspect and validate Home source

```bash
home parse <file>
home ast <file>
home check <path>
home lint [--fix] <file>
home fmt <file>
home fix [path]
```

`parse` prints tokens, `ast` prints the parsed tree, and `check` runs the
Home-language validation path. Formatter and linter support remain in progress.

## Run and build

```bash
home run <file|script>
home build <file> [options]
home watch <file>
home test [options]
home repl
home profile <file>
```

Routing depends on the entrypoint:

- `.home` and `.hm` files use the Home interpreter or native compiler.
- JavaScript, TypeScript and HTML entrypoints use the Bun-compatible runtime and
  bundler path.
- `home test` can route to the JavaScript runtime when the project shape calls
  for it.

These are different pipelines; a passing interpreter fixture does not prove a
native or JavaScript-runtime path.

## TypeScript and editors

```bash
home tsc [tsc options]
home lsp --stdio
home lsp
```

`home tsc` is the TypeScript-compatible compiler entrypoint.
`home lsp --stdio` serves editor JSON-RPC; bare `home lsp` prints or inspects
capabilities. See [TypeScript parity](/docs/PARITY-TYPESCRIPT) for measured
coverage.

## Project workflow helpers

```bash
home init [name]
home dev [script|file]
home symbols [path]
home docs [path] --out docs/API.md
home explain <code>
home completions <bash|zsh|fish>
home doctor
home clean
home ci [path]
home api-diff <old.d.hm> <new.d.hm>
home size [path]
```

These commands cover scaffolding, development scripts, declaration inspection,
documentation, diagnostics, shell integration and project checks. Use
`home <command> --help` where available before scripting flags.

## Top-level Pantry-compatible commands

Home also exposes package-manager aliases such as:

```bash
home add <package>
home install
home remove <package>
home update [package]
home outdated
home audit
home why <package>
home x <package> [arguments]
home create <template>
home publish
home pack
```

These routes use the Pantry-compatible command layer and are separate from some
native `home pkg` operations.

## The `home pkg` namespace

`home pkg` combines native commands, Pantry pass-through commands and Home
inspection helpers.

```bash
home pkg init
home pkg add <specifier>
home pkg remove <name>
home pkg update
home pkg install
home pkg tools
home pkg search <query>
home pkg audit
home pkg tree
home pkg why <name>
home pkg declarations [--check]
home pkg docs
home pkg run <script>
home pkg scripts
```

The exact routing and current limitations are documented in
[package management](/docs/PACKAGE-MANAGEMENT) and
[Pantry integration](/docs/PANTRY_INTEGRATION).

## Package and distribution helpers

```bash
home package [options]
home pkg api-diff <old.d.hm> <new.d.hm>
home pkg size [path]
```

`home package` creates distributable package output through its own option
parser. Use `home package --help` for that surface.

## Stability guidance

A command appearing in `home help` means it is routed by the CLI. It does not
by itself mean every mode is stable. Check the
[capability matrix](/docs/CAPABILITY_MATRIX), the relevant parity page and the
command's focused tests before using it as production evidence.

## Related pages

- [Tooling index](/docs/TOOLING_INDEX)
- [Compiler pipeline](/docs/COMPILER_PIPELINE)
- [Package management](/docs/PACKAGE-MANAGEMENT)
- [TypeScript tooling](/docs/features/tooling)
