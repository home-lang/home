---
title: Array Comprehension Status
description: Inspect Home's parsed and interpreted array-comprehension form and the type-checker and native-backend work still required for usable support.
---

# Array comprehensions

Home parses a compact expression for mapping or filtering one array or range,
and the interpreter contains an evaluator for that node. The main type checker
currently leaves the result as `void`, so comprehensions are **not yet a usable
end-to-end language feature**.

## Syntax

```home
[result_expression for binding in source]
[result_expression for binding in source if condition]
```

For example:

```home
let doubled = [value * 2 for value in [1, 2, 3]]
let even_squares = [value * value for value in 0..10 if value % 2 == 0]
```

The expression before `for` is evaluated once for every retained source
element. The optional `if` expression runs first and excludes false elements.
The loop binding is scoped to that iteration.

## Interpreter behavior

The interpreter implementation handles:

- Array values.
- Integer ranges such as `0..5` and `-5..0`.

The range path advances by one and excludes the upper bound. An empty array or
range produces an empty result.

## Evidence map

| Area | Evidence |
|---|---|
| Grammar and AST construction | `packages/parser/src/parser.zig` and `packages/ast/src/comprehension_nodes.zig` |
| Interpreter evaluation | `packages/interpreter/src/interpreter.zig` |
| Intended Home-language cases | `tests/feature/list-comprehensions.test.home` |

The feature fixture expresses intended cases for mapping, one filter, arrays,
ranges, calls inside the result expression, empty results and comprehensions
returned from functions. It does not currently pass `home check`: indexing the
result reports a non-array type, and a comprehension returned as `[i32]` is
reported as `void`.

## Current boundary

Do not yet rely on these forms as supported language contracts:

- More than one `for` clause in a comprehension.
- Range `step` syntax.
- Dictionary or set comprehensions.
- Lazy generator expressions.
- Async comprehensions.
- Arbitrary user-defined iterators.
- Identical behavior from the interpreter, x86-64 and AArch64 backends.

The parser creates an `ArrayComprehension` node, but the main type-inference and
native-codegen switches do not yet provide a complete end-to-end lowering for
that node. The interpreter evaluator and the intended feature fixture therefore
do not prove portable execution.

## Reporting a gap

Include the source collection type, optional filter, command, and selected
backend. Reduce nested expressions to a single mapping operation before
reporting a compiler failure.

## Related pages

- [Control flow](/docs/guide/control-flow)
- [Type inference](/docs/TYPE_INFERENCE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
