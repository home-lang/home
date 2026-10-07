---
title: Home Architecture
description: Navigate Home's language frontend, native compiler, TypeScript toolchain, Bun-compatible runtime, package graph, and evidence boundaries.
---

# Home architecture

Home is a Zig monorepo with three major execution surfaces:

1. The Home language frontend and native compiler.
2. The TypeScript parser, checker, emit and language-server toolchain.
3. The Bun-compatible JavaScript runtime built around JavaScriptCore.

All three are under active development. Use the
[capability matrix](/docs/CAPABILITY_MATRIX) and
[parity status](/docs/PARITY-STATUS) for measured support rather than inferring
maturity from source-file presence.

## Home language path

A `.home` or `.hm` source file passes through these layers:

```text
source
  -> lexer
  -> parser and AST
  -> type checking and compile-time value collection
  -> borrow checking and optimization
  -> interpreter or native code generation
```

| Layer | Primary source |
|---|---|
| Tokens and lexing | `packages/lexer/` |
| AST definitions | `packages/ast/` |
| Parsing and module resolution | `packages/parser/` |
| Types and inference | `packages/types/` |
| Borrow-check pass | `packages/compiler/` |
| Interpreter | `packages/interpreter/` |
| Optimization | `packages/optimizer/` |
| Native and kernel code generation | `packages/codegen/` |
| Diagnostics | `packages/diagnostics/` |
| CLI orchestration | `src/main.zig` |

`home run` uses the interpreter for Home source. `home build` performs the
type, borrow and optimization gates before selecting a native backend. Kernel
mode uses its dedicated code-generation path and skips the ordinary userspace
borrow/optimization block after type checking.

## TypeScript path

The TypeScript toolchain is split into focused packages:

- `packages/ts_lexer/` and `packages/ts_parser/`
- `packages/binder/`, `packages/hir/` and `packages/ts_checker/`
- `packages/ts_program/`, `packages/ts_resolver/` and `packages/ts_driver/`
- `packages/ts_emit/`, `packages/d_ts/` and `packages/d_hm/`
- `packages/ts_lsp/` and `packages/ts_lsp_server/`
- `packages/ts_conformance/` for upstream fixture comparison

The public compiler entrypoint is `home tsc`. Its measured coverage and known
gaps are documented in [TypeScript parity](/docs/PARITY-TYPESCRIPT).

## JavaScript runtime path

JavaScript and TypeScript entrypoints route through `packages/runtime/` when
Home is built with JavaScriptCore support. That package carries the runtime,
Node-compatible modules, WebCore bindings and copied Bun source being
integrated.

Source presence is tracked separately from callable parity. See
[Bun runtime parity](/docs/PARITY-BUN) and
[Node.js parity](/docs/PARITY-NODE) for the distinction.

## Build graph

`build.zig` creates and wires the Zig modules. A directory under `packages/`
does not become reachable merely by existing; the relevant build module must
import it and the CLI or runtime must exercise it.

The repository also contains implementation packages for networking, storage,
databases, graphics, kernel work, tooling and other planned surfaces. Their
support status varies, and most should be treated as experimental unless the
capability matrix says otherwise.

## Correctness boundaries

When assessing an architectural component, require evidence at the right layer:

- A source file proves implementation work exists.
- A Zig unit test proves the package can exercise that code in isolation.
- A CLI integration test proves build wiring and command routing.
- A `.home`, TypeScript or Bun-corpus fixture proves public behavior.
- A parity number is valid only when its documented harness reproduces it.

## Related pages

- [Compiler pipeline](/docs/COMPILER_PIPELINE)
- [Monorepo structure](/docs/MONOREPO-STRUCTURE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
- [Parity status](/docs/PARITY-STATUS)
