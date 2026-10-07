---
title: Compiler Pipeline
description: Follow the current Home source pipeline from lexing and parsing through type and borrow checks, optimization, interpretation, and native or kernel code generation.
---

# Compiler pipeline

The Home CLI uses different pipelines for Home source and JavaScript/TypeScript
source. This page covers the native Home-language path implemented in
`src/main.zig`.

## Interpret a Home program

`home run app.home` takes the direct interpreter path:

1. Read the entrypoint.
2. Tokenize with `packages/lexer`.
3. Parse with `packages/parser` and initialize module-resolution context.
4. Build the AST from `packages/ast`.
5. Execute it with `packages/interpreter`.

This path is useful for language development and examples. It is not identical
to the native build pipeline below.

## Build a Home program

`home build app.home` performs these stages.

### 1. Read and tokenize

The CLI reads the source and creates tokens with `Lexer.tokenize`. Token
locations feed parser and diagnostic output.

### 2. Parse and resolve modules

`Parser.parse` builds the AST. The parser receives the source path and an I/O
context for module resolution. Any collected parse error is fatal to a build;
Home refuses to generate code from a partial AST.

### 3. Collect compile-time values and check types

The build initializes a `ComptimeValueStore`, then runs
`TypeChecker.check`. Type errors stop an ordinary build unless the caller uses
the explicit continue-on-type-error option supported by the build CLI.

Compile-time evaluation, generics, traits and related language features remain
at different maturity levels. Their presence in this stage does not make every
shape stable; see the [capability matrix](/docs/CAPABILITY_MATRIX#language).

### 4. Check borrows

For a non-kernel build, `BorrowCheckPass` validates the AST after type
checking. A failed borrow check exits unsuccessfully.

Ownership and borrow checking are still listed as in progress, so this gate is
not yet evidence of Rust-equivalent coverage.

### 5. Optimize

The userspace path configures the optimizer at the current O2 level and runs its
pass manager over the program. Optimization correctness is part of the build
gate; performance claims require separate benchmark evidence.

### 6. Generate code

The backend depends on the requested mode and architecture:

- Normal builds select the native x86-64 or AArch64 code generator.
- `--kernel` selects the kernel backend, with explicit x86-64-freestanding and
  AArch64-freestanding target handling.
- JavaScript and TypeScript build entrypoints use the runtime/bundler path
  instead of this Home AST pipeline.

The native code generators are substantial but still marked in progress.

### 7. Cache the artifact

When the IR cache build option is enabled, a non-kernel build may restore a
byte-identical cached executable. On a miss, Home stores the newly generated
artifact after a successful build.

## Diagnostics and failure behavior

The compiler reports parse, type and borrow failures at their owning stage.
Builds must not continue silently after parse errors. Test and documentation
claims should include the command, target and optimization mode because the
interpreter, userspace compiler, kernel compiler and JS runtime are different
paths.

## Related pages

- [Architecture](/docs/ARCHITECTURE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
- [Error messages](/docs/ERROR_MESSAGES)
- [Type inference](/docs/TYPE_INFERENCE)
