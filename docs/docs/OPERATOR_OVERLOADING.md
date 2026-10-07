---
title: Operator Overloading Status
description: Understand Home's built-in operators, operator-trait design scaffolding, and the missing integration required before custom operators are a language contract.
---

# Operator overloading status

Home implements arithmetic, comparison, logical and bitwise operators for its
built-in value types. User-defined operator overloading is **not yet an
end-to-end language feature**.

## What works today

Primitive expressions use the compiler's built-in operator rules:

```home
let total = 20 + 22
let smaller = total < 100
let flags = 1 | 4
```

These expressions are parsed as unary or binary AST nodes, checked directly by
the type system, and lowered by the selected execution backend.

For user-defined types, use an ordinary named method while the operator path is
being integrated:

```home
struct Vector2 {
  x: i32,
  y: i32
}

impl Vector2 {
  fn add(self, other: Vector2): Vector2 {
    return Vector2 { x: self.x + other.x, y: self.y + other.y };
  }
}

let result = left.add(right)
```

This is normal method dispatch; it does not make `left + right` equivalent.

## Existing design scaffolding

`packages/traits/src/operator_traits.zig` defines descriptors and name mappings
for traits such as `Add`, `Sub`, `Mul`, `Neg`, assignment operators, indexing
and comparisons. `packages/types/src/operator_resolution.zig` contains a
resolver and an AST desugarer intended to turn an operator into a method call.

Those components express the intended direction, but the resolver is not
called by the main Home type-checking or code-generation pipeline. The current
Home-language fixtures also do not contain a passing `impl Add` example that
proves custom `+` end to end.

## Consequences

Do not currently rely on these claims from older documentation:

- `a + b` automatically desugars to `a.add(b)` for structs.
- Declaring `impl Add for T` enables `+` in compiled Home code.
- Compound assignment automatically uses `AddAssign`-style traits.
- `[]`, dereference or comparison operators can be customized through traits.
- Associated `Output` types are resolved uniformly across backends.

Each requires a parser/checker/backend fixture before it can become public
syntax documentation.

## Evidence map

| Area | Evidence |
|---|---|
| Built-in operator grammar | `packages/parser/src/parser.zig` |
| Built-in checking | `packages/types/src/type_system.zig` |
| Trait descriptors | `packages/traits/src/operator_traits.zig` |
| Unintegrated resolver | `packages/types/src/operator_resolution.zig` |
| Primitive feature tests | arithmetic and comparison fixtures under `tests/feature/` |

## Related pages

- [Traits](/docs/TRAITS)
- [Structs and enums](/docs/guide/structs-enums)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
