---
title: Default Parameters
description: Use Home's tested trailing default-parameter syntax, combine defaults with named calls, and understand the generic and backend cases still being validated.
---

# Default parameters

A function parameter can provide a value that is used when the caller omits
that argument. The repository has a dedicated Home-language fixture for common
primitive defaults and partial positional calls.

## Basic syntax

```home
fn greet(name: string = "World"): string {
  return "Hello, " + name + "!";
}

greet()
greet("Alice")
```

Multiple trailing defaults are supported by the fixture:

```home
fn calculate(a: i32, b: i32 = 5, c: i32 = 1): i32 {
  return (a + b) * c;
}

calculate(10)
calculate(10, 10)
calculate(10, 10, 2)
```

Place required positional parameters before parameters with defaults. Positional
calls fill parameters from left to right.

## Named calls with defaults

Named arguments can select a later parameter while earlier defaults remain in
effect:

```home
fn settings(a: i32 = 1, b: i32 = 2, c: i32 = 3): i32 {
  return a + b + c;
}

let value = settings(b: 20)
```

Named-call behavior has its own
[reference page](/docs/NAMED_PARAMETERS).

## Current coverage

`tests/feature/default-parameters.test.home` contains cases for:

- String, integer and boolean defaults.
- Empty, zero, negative and larger literal values.
- Multiple defaults with partial positional overrides.
- Defaults used from expressions, loops and nested calls.
- Named arguments selecting specific defaulted parameters.

The AST also contains argument-resolution helpers for default and named
parameters. Public support still depends on parser, checker, interpreter and
backend integration.

## In-progress cases

Verify these separately before relying on them:

- Defaults that depend on earlier parameters.
- Generic defaults such as `T.default()`.
- Defaults on methods, trait methods and closures.
- Side-effect ordering for complex default expressions.
- Named-only parameter separators.
- Identical lowering across interpreter, x86-64 and AArch64.

The presence of a helper type in `packages/ast/src/parameter_nodes.zig` is not
proof that every syntax form is parsed and code-generated.

## Related pages

- [Named parameters](/docs/NAMED_PARAMETERS)
- [Functions](/docs/guide/functions)
- [Type inference](/docs/TYPE_INFERENCE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
