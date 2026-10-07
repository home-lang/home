---
title: Tuple Spread Status
description: Inspect Home's parsed tuple-spread form, current interpreter and x86-64 paths, and the checker and cross-backend work still required.
---

# Tuple spread

Home parses `...expression` as a spread expression. The interpreter and x86-64
code generator contain tuple-spread paths, but the current checker does not type
the resulting tuple as indexable. Tuple spread is therefore **not yet a usable
end-to-end language feature**.

## Basic form

```home
let middle = (2, 3)
let values = (1, ...middle, 4)

assert(values.len() == 4)
assert(values[1] == 2)
```

A spread may appear at the beginning, middle or end of a tuple expression.
Multiple tuple values may be expanded into the same result:

```home
let left = (1, 2)
let right = (3, 4)
let combined = (...left, ...right)
```

A trailing comma keeps a one-element or spread-only expression in tuple form:

```home
let source = (1, 2, 3)
let copy = (...source,)
```

The intended fixture includes integer, string and boolean elements, empty and
one-element tuples, multiple spreads, and spread results used by loops and
indexing. It does not currently pass `home check`: its indexed results are
reported as non-array types.

## Type boundary

The type checker restricts a spread operand to an array or tuple type. The
interpreter represents tuple values through its array-value path and flattens
those elements while evaluating a tuple expression.

## Evidence map

| Area | Evidence |
|---|---|
| `...` parsing | `packages/parser/src/parser.zig` |
| Spread and tuple AST | `packages/ast/src/ast.zig` |
| Operand checking | `packages/types/src/type_system.zig` |
| Interpreter evaluation | `packages/interpreter/src/interpreter.zig` |
| Native lowering | `packages/codegen/src/native_codegen.zig` |
| Intended Home-language cases | `tests/feature/spread.test.home` |

## Not yet a stable spread contract

The repository contains AST helpers and TypeScript tooling for many other kinds
of spread. They do not prove that the equivalent Home-language syntax is wired
through every compiler stage. Do not infer support for:

- JavaScript-style array literals such as `[...items]`.
- Object or struct spread such as `{ ...base }`.
- Spreading an iterable into a function call.
- Rest parameters.
- Array or object rest destructuring.
- Pattern-rest capture.
- Arbitrary iterator-protocol values.

Native lowering is target-specific. Code intended for more than the current
x86-64 path needs a focused cross-target test rather than relying on the parser
accepting `...`.

## Related pages

- [Struct literals](/docs/STRUCT_LITERALS)
- [Variadic functions](/docs/VARIADIC_FUNCTIONS)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
