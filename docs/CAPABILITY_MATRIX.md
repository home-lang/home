# Capability Matrix

A conservative, honest view of what works in the Home compiler and stdlib today
vs. what is partial, in progress, or not yet started. When in doubt this matrix
errs on the side of caution — if something is not yet covered by examples or
tests we mark it 🚧 rather than ✅.

Legend:

- ✅ **Stable** — implemented, exercised by examples and/or tests, expected to keep working.
- 🚧 **In progress / Partial** — code exists but is incomplete, experimental, or not yet
  exercised end-to-end. Expect rough edges and breaking changes.
- ❌ **Not yet** — planned, but not meaningfully implemented.

## Language

| Feature | Status |
|---|---|
| Lexer (full token set, escapes, line/col tracking) | ✅ Stable |
| Recursive-descent parser with error recovery | ✅ Stable |
| Type inference (primitives, structs, enums, arrays) | ✅ Stable |
| Pattern matching (`match` over enums, primitives, wildcards) | 🚧 In progress |
| Closures | 🚧 In progress |
| Traits / `impl` blocks | 🚧 In progress |
| Trait objects / dynamic dispatch | 🚧 In progress |
| Generics (functions and types) | 🚧 In progress |
| Const generics | ❌ Not yet |
| Comptime evaluation | 🚧 In progress |
| Macros (`todo!`, `assert!`, `unreachable!`, …) | 🚧 In progress |
| Null-safety operators (`?.`, `?:`, `??`, `?[]`) | 🚧 In progress |
| Result types and `?` propagation | 🚧 In progress |
| Async / await | 🚧 In progress |
| Ownership / move checking | 🚧 In progress |
| Borrow checker | 🚧 In progress |

## Codegen targets

| Target | Status |
|---|---|
| x86-64 native codegen | 🚧 In progress (substantial; primary target) |
| arm64 codegen | 🚧 Partial (assembler scaffolding only) |
| WebAssembly codegen | 🚧 Stub |
| LLVM backend | 🚧 In progress |
| ELF object emission | 🚧 In progress |
| Mach-O object emission | 🚧 In progress |
| Tree-walking interpreter | ✅ Stable |

## Tooling

| Tool | Status |
|---|---|
| `home check` (type-check) | ✅ Stable |
| `home run` (interpret) | ✅ Stable |
| `home build` (native binary) | 🚧 In progress |
| `home test` runner | 🚧 In progress |
| Formatter | 🚧 In progress |
| Linter | 🚧 In progress |
| LSP / IDE integration | 🚧 In progress |
| VSCode extension | 🚧 In progress |
| REPL | 🚧 In progress |
| Package manager (`pkg`) | 🚧 In progress |
| Incremental compilation / IR cache | 🚧 In progress |

## Standard library

The stdlib has many modules under `packages/` and `src/`, but most have not
been validated end-to-end against the language frontend yet. Treat all stdlib
modules as 🚧 unless explicitly listed as stable here.

| Module | Status |
|---|---|
| Core primitives (`int`, `float`, `bool`, `string`, arrays) | ✅ Stable |
| String methods (`trim`, `upper`, `split`, …) | ✅ Stable |
| Range methods (`len`, `step`, `contains`, …) | ✅ Stable |
| HTTP server | 🚧 In progress |
| Database / SQL | 🚧 In progress |
| Threading | 🚧 In progress |
| FFI / C interop | 🚧 In progress |
| Audio / video / graphics | 🚧 In progress |
| Kernel / OS modules | 🚧 In progress |

## How to read this

If you want to know whether a specific feature is safe to depend on for real
work, the rule of thumb is:

- ✅ — go ahead, but please file issues for any regressions.
- 🚧 — try it, expect bugs and breakage, and please file issues.
- ❌ — don't depend on it; contributions welcome.

For the rough roadmap and prior milestone notes, see `git log` and the
internal notes under `docs/internal/`.
