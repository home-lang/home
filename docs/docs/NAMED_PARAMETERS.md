---
title: Named Arguments
description: Call Home functions with reordered or mixed named arguments, understand validation behavior, and account for current backend and named-only limitations.
---

# Named arguments

Home call expressions can bind an argument by parameter name. The parser,
interpreter and x86-64 code generator contain named-argument paths, and the
repository has a focused Home-language fixture. Backend coverage is not yet
uniform, so this feature remains subject to the broader compiler maturity
boundary.

## Basic calls

```home
fn create_point(x: i32, y: i32, z: i32): i32 {
  return x * 100 + y * 10 + z;
}

let value = create_point(z: 3, x: 1, y: 2)
```

Named arguments may be reordered. Positional arguments may come first:

```home
fn calculate(base: i32, multiplier: i32, offset: i32): i32 {
  return base * multiplier + offset;
}

let value = calculate(10, offset: 5, multiplier: 3)
```

Once a named argument appears, the parser rejects a later positional argument.

## Defaults

A named call can skip defaulted parameters:

```home
fn configure(host: i32 = 100, port: i32 = 8080): i32 {
  return host + port;
}

let value = configure(port: 3000)
```

See [default parameters](/docs/DEFAULT_PARAMETERS) for the positional rules and
coverage boundary.

## Validation behavior

The interpreter's named-call path:

- Evaluates named argument expressions.
- Matches each name against the declared parameters.
- Rejects duplicate assignment of a parameter.
- Rejects an unknown parameter name.
- Fills omitted parameters from defaults where available.

The type checker visits named argument values, but comments in the current
implementation explicitly note that full name-to-parameter validation still
needs richer parameter-name handling. Runtime checks are not a substitute for
complete static diagnostics.

## Backend boundary

The x86-64 native code generator resolves named arguments into parameter slots.
The AArch64 backend still rejects named-argument calls in several lowering paths
with `NotImplemented`. Code that must compile natively on both architectures
needs a focused cross-target test before this feature can be described as
portable.

## Named-only parameters

The AST contains an `is_named_only` model and argument resolver, but the public
parser does not yet establish a stable underscore-separator syntax. Older
examples showing this form were design sketches:

```home
// Not yet a stable public contract:
fn connect(host: string, _, timeout: i32 = 30) {
  // ...
}
```

Do not rely on that separator until a parser fixture, checker test and both
native backends cover it.

## Evidence

- Parser: `packages/parser/src/parser.zig`
- AST helpers: `packages/ast/src/parameter_nodes.zig`
- Interpreter: `packages/interpreter/src/interpreter.zig`
- Native backends: `packages/codegen/src/native_codegen.zig` and
  `aarch64_native_codegen.zig`
- Fixture: `tests/feature/named-arguments.test.home`

## Related pages

- [Default parameters](/docs/DEFAULT_PARAMETERS)
- [Functions](/docs/guide/functions)
- [Compiler pipeline](/docs/COMPILER_PIPELINE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
