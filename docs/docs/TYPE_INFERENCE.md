---
title: Type Inference
description: Understand Home's tested core inference behavior, implementation layers, focused fixtures, and the advanced inference guarantees that remain in progress.
---

# Type inference

Home infers common expression and binding types without requiring every local
variable to have an annotation. Core inference for primitives, structs, enums
and arrays is marked stable in the
[capability matrix](/docs/CAPABILITY_MATRIX#language). Broader
Hindley-Milner-style behavior remains under active development.

## Tested core shapes

The Home feature fixtures exercise inference from:

- Integer, boolean and string literals.
- Arithmetic, comparison and logical expressions.
- Homogeneous array elements and indexing.
- Function return annotations and call results.
- Conditional and match-expression branches.
- Struct fields.
- Nested expressions and loops.
- Basic closure parameters.

```home
let a = 10
let b = 20
let sum = a + b

let values = [1, 2, 3]
let first = values[0]

struct Data {
  value: i32
}

let data = Data { value: 42 }
let inferred = data.value
```

The examples mirror syntax in `tests/feature/type-inference.test.home`.
Feature-fixture presence is evidence of intended coverage, not a substitute for
running the current test gate.

## Implementation layers

| Layer | Source |
|---|---|
| General Home type checking | `packages/types/src/type_system.zig` |
| Constraint/unification work | `packages/types/src/type_inference.zig` |
| Focused Zig tests | `packages/types/tests/type_inference_test.zig` |
| Home-language fixture | `tests/feature/type-inference.test.home` |

The focused Zig tests cover literal inference, homogeneous arrays, unification,
occurs checks, function-type unification, tuple inference, let-polymorphism
generalization and substitution behavior. Those unit tests validate the
inferencer in isolation; public CLI behavior also depends on parser, AST and
type-checker integration.

## When to annotate

Use an explicit annotation when it communicates an API contract or when the
checker does not have enough local information:

```home
let timeout_ms: i32 = 5000

fn parse_port(value: string): i32 {
  // ...
}
```

Public function parameters and returns are especially useful places for
annotations while advanced inference is evolving.

## In-progress guarantees

Do not read the existence of `type_inference.zig` as proof of all textbook
Hindley-Milner properties. These areas still require end-to-end evidence across
the language frontend:

- Most-general-type guarantees for every expression form.
- Generalization across all scopes and mutable bindings.
- Advanced generic and trait-bound inference.
- Exhaustive inference for closures and higher-order functions.
- Stable diagnostics for ambiguous or underconstrained programs.
- A formal soundness claim covering interpreter and native backends.

## Diagnosing an inference problem

When reporting a gap, include:

1. The smallest `.home` source that reproduces it.
2. Whether `home check`, `home run` or `home build` was used.
3. The inferred or reported type.
4. The expected type and why surrounding syntax constrains it.
5. The target architecture if native code generation is involved.

## Related pages

- [Type system](/docs/features/type-system)
- [Generics](/docs/features/generics)
- [Traits](/docs/TRAITS)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
