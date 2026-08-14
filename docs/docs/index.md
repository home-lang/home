---
title: Documentation
description: Guides, feature references and parity status for the Home programming language.
---

# Documentation

Home is a modern programming language for systems, apps and games, plus a
toolchain that also type-checks and builds TypeScript. Start with the guide if
you are new; the rest of this page is a map.

Every page says plainly what is usable today and what is still maturing. The
[capability matrix](/docs/CAPABILITY_MATRIX) is the single honest reference if
you only read one thing.

## Start here

- [Getting Started](/docs/guide/getting-started) - install the toolchain, build
  your first binary.
- [Variables](/docs/guide/variables), [Control Flow](/docs/guide/control-flow),
  [Functions](/docs/guide/functions) - the basics, in order.
- [Structs & Enums](/docs/guide/structs-enums) and [Traits](/docs/guide/traits) -
  how data and shared behaviour are modelled.

## Language features

- [Pattern Matching](/docs/features/pattern-matching) - exhaustive match with
  guards, ranges and destructuring.
- [Type System](/docs/features/type-system) - inference, unions, null safety and
  Result types.
- [Generics](/docs/features/generics) - monomorphized generics with trait bounds.
- [Macros](/docs/features/macros) - hygienic macros over the real AST.
- [FFI](/docs/features/ffi) - calling C without a binding generator.

## Systems concerns

- [Memory](/docs/advanced/memory) - ownership and borrowing, no collector.
- [Comptime](/docs/advanced/comptime) - running real code during compilation.
- [Async](/docs/advanced/async) - tasks, channels and the scheduler.
- [Error Handling](/docs/advanced/error-handling) - errors as values.
- [Performance](/docs/advanced/performance) and
  [Metaprogramming](/docs/advanced/metaprogramming).

## Toolchain

- [TypeScript Compiler](/docs/features/typescript) - what `home tsc` does and how
  its parity is measured.
- [Editor & CLI Tooling](/docs/features/tooling) - language server, formatter,
  test runner, package commands.
- [DX Commands](/docs/DX_COMMANDS) - the full command reference.
- [Package Management](/docs/PACKAGE-MANAGEMENT) - how Pantry is used.

## Use cases

- [Systems Programming](/docs/use-cases/systems)
- [Game Development](/docs/use-cases/games)
- [Operating Systems](/docs/use-cases/operating-systems)
- [Web Services](/docs/use-cases/web-services)
- [CLI Tools](/docs/use-cases/cli-tools)
- [TypeScript Migration](/docs/use-cases/typescript-migration)

## Status and parity

- [Capability Matrix](/docs/CAPABILITY_MATRIX) - every language, codegen,
  tooling and stdlib row with status.
- [TypeScript](/docs/PARITY-TYPESCRIPT), [Node.js](/docs/PARITY-NODE) and
  [Bun](/docs/PARITY-BUN) - feature-by-feature parity.
- [Architecture](/docs/ARCHITECTURE) and
  [Compiler Pipeline](/docs/COMPILER_PIPELINE) - how the compiler is built.
