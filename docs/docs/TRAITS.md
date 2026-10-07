---
title: Trait System Reference
description: Use Home's current trait declaration, implementation, bounds, and default-method syntax while understanding the advanced trait features still in progress.
---

# Traits

Traits describe behavior that structs can implement. Home has parser, checker
and fixture coverage for core trait declarations and implementations, but the
overall trait system remains **in progress** in the
[capability matrix](/docs/CAPABILITY_MATRIX#language).

## Basic declaration and implementation

```home
trait Printable {
  fn to_string(self): string;
}

struct Point {
  x: i32,
  y: i32
}

impl Printable for Point {
  fn to_string(self): string {
    return "Point(" + to_string(self.x) + ", " + to_string(self.y) + ")";
  }
}
```

This shape mirrors `tests/feature/traits.test.home`. The checker validates that
an implementation method's arguments and signature agree with the declared
trait method.

## Trait bounds

Generic functions can express a trait bound:

```home
fn print_it<T: Printable>(item: T): string {
  return item.to_string();
}
```

Focused fixtures cover a single bound and common generic-call shapes. Complex
bound combinations and inference interactions remain part of the wider
generics work.

## Default methods

A trait method may provide a body that an implementation can inherit or
override:

```home
trait Describable {
  fn describe(self): string {
    return "An object";
  }

  fn detailed(self): string;
}
```

The repository has a dedicated
`tests/feature/default-trait-impl.test.home` fixture for inherited and
overridden defaults.

## Evidence map

| Area | Evidence |
|---|---|
| Syntax and AST | `packages/parser/`, `packages/ast/` |
| Signature checking | `packages/types/src/trait_checker.zig` and type-system tests |
| Implementation-side trait registry | `packages/traits/` |
| Home-language behavior | `tests/feature/traits.test.home`, `trait-bounds.test.home`, `default-trait-impl.test.home` |

The Zig tests under `packages/traits/tests/` exercise the implementation-side
trait registry. They do not by themselves prove that every equivalent
`.home` syntax path is wired end to end.

## Still in progress

Treat these as design direction unless a focused Home-language test proves the
specific shape:

- Associated types across parsing, checking and code generation.
- Trait inheritance and multi-level supertraits.
- Dynamic trait objects and virtual dispatch.
- Object-safety rules.
- Generic traits with advanced where clauses.
- Coherence, overlap and orphan-style implementation rules.
- Complete native-backend support for trait calls.

In particular, Rust syntax such as `dyn Trait`, `&self` and `where` should
not be copied into Home code solely because older examples used it.

## Reporting a trait gap

Include the trait declaration, implementing type, exact call site, command
used, and whether the issue occurs in checking, interpretation or native code
generation.

## Related pages

- [Generics](/docs/features/generics)
- [Type inference](/docs/TYPE_INFERENCE)
- [Default parameters](/docs/DEFAULT_PARAMETERS)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
