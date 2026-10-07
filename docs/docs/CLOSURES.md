---
title: Closures and Captures
description: Use Home's current anonymous-function and captured-scope behavior while distinguishing tested shapes from planned Rust-style closure semantics.
---

# Closures and captures

Home can represent callable expressions and resolve values from enclosing
scopes. Basic closure checking and capture behavior exist, but closures remain
**in progress** in the [capability matrix](/docs/CAPABILITY_MATRIX#language).

## Anonymous functions

The parser accepts pipe-delimited parameters:

```home
let double = |value| value * 2
let result = double(21)
```

The checker has focused tests for typed closure parameters, calls with valid and
invalid arguments, body checking and parent-scope capture.

## Captured scopes

The Home feature fixture also exercises nested functions that read enclosing
bindings:

```home
let multiplier = 3

fn multiply(value: i32): i32 {
  return value * multiplier;
}

assert(multiply(5) == 15)
```

Coverage includes primitive, string, array and struct captures, multiple
captured bindings, nested scopes and higher-order calls. Mutation and ownership
interactions need separate evidence.

## Higher-order functions

A function type can be used for a callable parameter:

```home
fn apply(operation: fn(i32): i32, value: i32): i32 {
  return operation(value);
}

let result = apply(|value| value * 2, 21)
```

This syntax appears in the named-argument and closure fixtures. Generic
higher-order inference is a wider generics/type-inference concern and remains
partial.

## Evidence map

| Area | Evidence |
|---|---|
| Closure AST and parser | `packages/ast/`, `packages/parser/` |
| Type checking | focused closure tests under `packages/types/tests/` |
| Interpreter capture behavior | `packages/interpreter/` |
| Home-language fixtures | `tests/feature/closures.test.home` and `collection-methods.test.home` |

## Not yet a stable contract

Older versions of this page described Rust's full closure model as if Home
already implemented it. Do not assume complete support for:

- Automatic `Fn`, `FnMut` and `FnOnce` classification.
- Rust-equivalent immutable, mutable and move capture inference.
- A `move || ...` ownership contract.
- Returning opaque closure types with `impl Fn`.
- Boxed dynamic closures.
- Async closures and future inference.
- Uniform closure lowering across interpreter, x86-64 and AArch64 backends.

Those are separate features that require parser, checker, ownership and backend
tests.

## Reporting a closure gap

Reduce the issue to one capture and one call when possible. State whether the
failure occurs in `home check`, the interpreter, or a native build, and include
the target architecture.

## Related pages

- [Functions](/docs/guide/functions)
- [Type inference](/docs/TYPE_INFERENCE)
- [Generics](/docs/features/generics)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
