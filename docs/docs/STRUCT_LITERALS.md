---
title: Struct Literals
description: Construct named and anonymous Home structs with the literal forms covered by current parser, diagnostic, interpreter, and native-codegen evidence.
---

# Struct literals

Struct literals associate field names with expressions. Home accepts the
regular named form and Zig-style dot-field initializers. Anonymous struct types
and literals are recognized by the parser but are not yet accepted end to end
by the main type checker.

## Named structs

```home
struct Point {
  x: i32,
  y: i32
}

let point = Point { x: 10, y: 20 }
```

The struct feature fixture covers construction, field access, values returned
from functions, nested structs and arrays of structs.

## Dot-field initializers

The parser also accepts the form used by Home kernel sources:

```home
pub const Pair = struct {
  left: i32,
  right: i32
}

fn make_pair(): Pair {
  return Pair { .left = 1, .right = 2 }
}
```

Module-qualified type names can precede the literal. The parser accepts `:` as
well as `=` after a leading dot, but `.field = value` is the canonical
Zig-compatible spelling.

## Shorthand fields

Once a struct literal has been recognized, a field can use its same-named local
as the value. Dot shorthand is unambiguous at the first field:

```home
let left = 1
let right = 2
let pair = Pair { .left, .right }
```

Do not assume that an all-bare form such as `Pair { left, right }` is equivalent.
The current lookahead recognizes a first bare field only when it is followed by
`:`, while a leading dot can be recognized as shorthand.

## Anonymous struct parser support

The parser recognizes anonymous struct types in return and local annotations,
with a dot-prefixed literal supplying the value:

```home
fn cursor(): struct { x: usize, y: usize } {
  return .{ .x = 10, .y = 20 }
}
```

The parser cases also include a clean negative diagnostic for a missing field
type. The current type checker still reports the anonymous type and its empty
literal type name as unknown, so this syntax is not yet a usable compiled
language contract.

## Evidence map

| Area | Evidence |
|---|---|
| Literal grammar | `packages/parser/src/parser.zig` |
| AST representation | `packages/ast/src/struct_literal_nodes.zig` |
| Interpreter values | `packages/interpreter/src/interpreter.zig` |
| Type and native paths | `packages/types/src/type_system.zig` and `packages/codegen/src/` |
| Language fixtures | `tests/feature/structs.test.home` and `tests/diagnostics/cases/parse/30_struct_literal_dot_field.home` |
| Anonymous parser cases | `tests/diagnostics/cases/parse/40_anon_struct_return_type.home` and `41_anon_struct_missing_field_type.home` |

## Current boundary

Older versions of this page presented several planned AST forms as completed.
Do not yet treat these as portable contracts:

- Struct update syntax such as `Point { ..base }`.
- Object-style spread such as `{ ...base }`.
- Tuple-struct construction.
- Automatic default values for omitted fields.
- Uniform duplicate, unknown, missing and wrong-type field diagnostics.
- Uniform nested-struct lowering across every native target.

The AST contains helpers for some of these forms, but a helper type is not an
end-to-end parser, checker and code-generation guarantee.

## Related pages

- [Structs and enums](/docs/guide/structs-enums)
- [Type inference](/docs/TYPE_INFERENCE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
