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
you only read one thing, and [parity status](/docs/PARITY-STATUS) has every
published number with the harness that produces it.

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

## Language reference

Per-feature pages that go deeper than the guide, roughly in the order you meet
them.

- [Type Inference](/docs/TYPE_INFERENCE) and [Traits](/docs/TRAITS) - how types
  and shared behaviour are resolved.
- [Closures](/docs/CLOSURES), [Default Parameters](/docs/DEFAULT_PARAMETERS),
  [Named Parameters](/docs/NAMED_PARAMETERS) and
  [Variadic Functions](/docs/VARIADIC_FUNCTIONS) - the full call surface.
- [Struct Literals](/docs/STRUCT_LITERALS),
  [Array Comprehensions](/docs/ARRAY_COMPREHENSIONS) and
  [Splat Operators](/docs/SPLAT_OPERATORS) - building values concisely.
- [Operator Overloading](/docs/OPERATOR_OVERLOADING) and
  [Multiple Dispatch](/docs/MULTIPLE_DISPATCH) - extending behaviour over types.
- [Home Declarations](/docs/HOME_DECLARATIONS) - `.d.hm` files, the `.d.ts`
  analogue for Home.
- [Error Messages](/docs/ERROR_MESSAGES) - what the diagnostics look like and
  why they are worded that way.

## Standard library

- [Standard Library reference](/docs/reference/stdlib) - collections, files,
  HTTP, JSON, networking, time, database.
- [Stdlib Modules](/docs/STDLIB-MODULES) - the module-by-module index.
- [Basics Module](/docs/BASICS_MODULE_GUIDE) - what is available without an
  import.
- [Typed ORM Guide](/docs/TYPED_ORM_GUIDE) and
  [Backend Quick Guide](/docs/QUICK_BACKEND_GUIDE) - building a service end to
  end.
- [Kernel Features](/docs/KERNEL_FEATURES) and
  [Kernel Architecture](/docs/KERNEL_ARCHITECTURE) - freestanding and OS work.

## Toolchain

- [TypeScript Compiler](/docs/features/typescript) - what `home tsc` does and how
  its parity is measured.
- [Editor & CLI Tooling](/docs/features/tooling) - language server, formatter,
  test runner, package commands.
- [Tooling Index](/docs/TOOLING_INDEX) - every tool in the repo, with its state.
- [DX Commands](/docs/DX_COMMANDS) - the full command reference.
- [Configuration](/docs/CONFIGURATION) - project and compiler settings.
- [Package Management](/docs/PACKAGE-MANAGEMENT),
  [Pantry](/docs/PANTRY) and
  [Pantry Integration](/docs/PANTRY_INTEGRATION) - how dependencies are resolved.
- [Testing Matchers](/docs/MATCHERS_REFERENCE) - the assertion surface of
  `home test`.

## Use cases

- [Systems Programming](/docs/use-cases/systems)
- [Game Development](/docs/use-cases/games)
- [Operating Systems](/docs/use-cases/operating-systems)
- [Web Services](/docs/use-cases/web-services)
- [CLI Tools](/docs/use-cases/cli-tools)
- [TypeScript Migration](/docs/use-cases/typescript-migration)

## Status and parity

- [Parity Status](/docs/PARITY-STATUS) - every published number and the harness
  behind it.
- [Capability Matrix](/docs/CAPABILITY_MATRIX) - every language, codegen,
  tooling and stdlib row with status.
- [TypeScript](/docs/PARITY-TYPESCRIPT), [Node.js](/docs/PARITY-NODE),
  [Bun](/docs/PARITY-BUN) and the
  [Bun compat shim](/docs/PARITY-BUN-COMPAT) - feature-by-feature parity.
- [TypeScript Performance](/docs/TS_PERFORMANCE) - benchmark methodology,
  results and the correctness audits that gate them.
- [Diagnostic Code Status](/docs/TS_DIAGNOSTIC_CODE_STATUS) and
  [Diagnostic Reachability](/docs/TS_DIAGNOSTIC_REACHABILITY) - which `TSxxxx`
  codes Home emits, and which are dead in the reference compiler.
- [Roadmap](/docs/ROADMAP-WEB-COMPETITIVE) - where the runtime work is going.

## Project internals

For contributors, or anyone who wants to know how the compiler is put together.

- [Architecture](/docs/ARCHITECTURE) and
  [Compiler Pipeline](/docs/COMPILER_PIPELINE) - how a source file becomes a
  binary.
- [Monorepo Structure](/docs/MONOREPO-STRUCTURE) - what lives in which package.
- [Technical Decisions](/docs/DECISIONS) - the choices behind the design, and
  why.
- [Native Runtime Bindings](/docs/NATIVE_RUNTIME_BINDINGS) - how the Zig runtime
  is exposed to JavaScript.
- [Security Policy](/docs/SECURITY) and
  [Security Hardening](/docs/LANGUAGE_SECURITY_HARDENING) - reporting issues and
  the language-level guarantees.
