---
title: Multiple Dispatch Status
description: Distinguish Home's multiple-dispatch design modules from currently integrated function, method, trait-object, and pattern-matching behavior.
---

# Multiple dispatch status

Multiple dispatch selects a function from the runtime types of more than one
argument. Home contains design and helper modules for that model, but it is
**not currently wired into the public language pipeline**.

## Current language behavior

Ordinary functions are resolved from their declared name and statically checked
parameter types. Methods use their receiver and implementation. Pattern matching
provides explicit branching when a value has several known variants.

Do not declare several functions with the same name and expect Home to choose a
body from all runtime argument types:

```home
// Not a supported multiple-dispatch contract:
fn collide(left: Circle, right: Circle): bool { return true; }
fn collide(left: Circle, right: Rectangle): bool { return false; }
```

The repository has no Home-language fixture proving this source shape through
parsing, type checking and either execution backend.

## What exists in the repository

`packages/ast/src/dispatch_nodes.zig` defines:

- A `MultiDispatchFn` model with typed variants.
- Dispatch parameters and type constraints.
- A dispatch table ordered by a numeric specificity value.
- A `DispatchCall` AST node and helper resolver.

`packages/ast/src/dispatch_enhancements.zig` adds standalone helpers for numeric
relationships, specificity scoring and ambiguity checks. Unit tests exercise
some of these helpers.

The parser does not construct `MultiDispatchFn` declarations or `DispatchCall`
expressions, and the main type checker, interpreter and native code generators
do not consume them. This makes them implementation scaffolding, not evidence
of a shipped feature.

## Separate concepts

Multiple dispatch should not be conflated with:

- Static overload selection in the TypeScript checker.
- Receiver-based methods on Home `impl` blocks.
- Dynamic calls through one trait-object receiver.
- A `match` expression over an enum or union.

Those mechanisms have different syntax and resolution rules. Their presence
does not complete multimethod selection over all arguments.

## Requirements before stabilization

A public multiple-dispatch contract needs, at minimum:

1. An unambiguous declaration grammar.
2. Registration and duplicate-signature diagnostics.
3. Static and runtime argument-type rules.
4. Deterministic specificity and ambiguity diagnostics.
5. Interpreter, x86-64 and AArch64 lowering.
6. Focused positive and negative Home-language fixtures.

Until those paths are integrated and verified, examples should be described as
design direction rather than executable Home code.

## Related pages

- [Functions](/docs/guide/functions)
- [Pattern matching](/docs/features/pattern-matching)
- [Traits](/docs/TRAITS)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
