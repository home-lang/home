---
title: Tooling Index
description: Find Home's current CLI, formatter, linter, language servers, editor extension, documentation, package, and registry tooling with honest maturity boundaries.
---

# Tooling index

Home's tooling is spread across the main CLI and focused packages. Source
presence does not make every feature stable; the
[capability matrix](/docs/CAPABILITY_MATRIX#tooling) remains authoritative.

## CLI surfaces

| Surface | Entry point | Status boundary |
|---|---|---|
| Main CLI | `src/main.zig` | Routes Home, TypeScript, JS runtime, test and package commands. |
| TypeScript compiler | `home tsc`, `packages/ts_cli/` | Broadly exercised; see [TypeScript parity](/docs/PARITY-TYPESCRIPT). |
| JavaScript runtime | `home run`, `home test`, `packages/runtime/` | In progress; see [Bun parity](/docs/PARITY-BUN). |
| Formatter | `home fmt`, `packages/formatter/` | In progress. |
| Linter | `home lint`, `packages/linter/` | In progress. |
| Documentation generator | `home docs`, `packages/docgen/` and `packages/tools/` | In progress. |
| Package commands | `home pkg`, `packages/pkg/` | In progress; some commands delegate to Pantry. |
| REPL | `home repl` | Native JavaScript REPL path; in progress. |

Run `home help` from the binary being tested for its exact command surface.

## Language servers

Home currently has two relevant code areas:

- `packages/lsp/` contains Home-language LSP work.
- `packages/ts_lsp/` and `packages/ts_lsp_server/` implement the TypeScript
  and JavaScript wire surface used by `home lsp --stdio`.

The measured LSP method count lives in
[parity status](/docs/PARITY-STATUS), not in a hand-maintained feature list.

## VS Code extension

`packages/vscode-home/` contains extension source for syntax support and
language-server integration, plus experimental debugging, profiling, code
action, CodeLens, semantic token and inlay-hint providers.

Treat those providers as in progress unless an extension-level integration test
proves the behavior. The existence of a TypeScript source file alone is not an
end-user completion claim.

## Registry

`packages/registry/src/server.ts` contains package-registry server work.
Authentication, publishing, search and deployment must be verified against a
running registry before they are documented as available services.

Package CLI routing is described in
[package management](/docs/PACKAGE-MANAGEMENT).

## Developer commands

The CLI also includes project workflow helpers:

- `home doctor` checks local setup.
- `home clean` removes Home/Zig caches.
- `home ci` combines project checks.
- `home symbols` lists public declarations.
- `home explain` describes diagnostics.
- `home api-diff` compares `.d.hm` declarations.
- `home size` reports project or output size.
- `home completions` emits shell completions.

See [DX commands](/docs/DX_COMMANDS) for routing details.

## Evidence required for a stable tool

A tool should be called stable only when:

1. Its public command and flags are documented.
2. Process-level tests cover success, invalid input and exit codes.
3. File mutations are fixture-tested.
4. Platform-sensitive paths run on each supported platform.
5. The capability matrix is updated from those results.

## Related pages

- [DX commands](/docs/DX_COMMANDS)
- [TypeScript tooling](/docs/features/tooling)
- [Package management](/docs/PACKAGE-MANAGEMENT)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
