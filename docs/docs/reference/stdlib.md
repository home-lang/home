---
title: Standard Library Status
description: Understand which Home standard-library capabilities are stable today, which source modules are experimental, and how to verify an API before depending on it.
---

# Standard library status

Home's standard library is still being connected to the language frontend. The
repository contains broad implementation modules, but source presence does not
mean that a module is available end to end from a `.home` program.

The [capability matrix](/docs/CAPABILITY_MATRIX#standard-library) is the source
of truth for support status. Unless that matrix marks a library capability as
stable, treat it as experimental.

## Stable language-facing capabilities

| Capability | Status | Evidence boundary |
|---|---|---|
| Core primitives | Stable | Integers, floats, booleans, strings and arrays are exercised by language tests. |
| String methods | Stable | Common operations such as `trim`, `upper` and `split` are covered by frontend tests. |
| Range methods | Stable | Common operations such as `len`, `step` and `contains` are covered by frontend tests. |

## Experimental areas

| Area | Current status |
|---|---|
| HTTP and networking | In progress; implementation code exists, but the public Home API is not yet a stable contract. |
| Database and SQL | In progress; do not infer availability from the Zig packages alone. |
| Threading and synchronization | In progress; see the [threading implementation status](https://github.com/home-lang/home/blob/main/packages/threading/THREADING_IMPLEMENTATION.md). |
| FFI and C interop | In progress. |
| Audio, video and graphics | In progress. |
| Kernel and OS modules | In progress and target-specific. |

## Source layout

The repository uses several layers that serve different audiences:

- `packages/basics/src/` contains Zig helpers used by Home's implementation.
- `packages/core/src/` exposes implementation-side core wrappers.
- Packages such as `packages/net/`, `packages/database/` and
  `packages/threading/` contain subsystem work.
- Language examples and tests demonstrate what `.home` programs can use today.

The first three locations are implementation evidence, not by themselves a
language-level API guarantee. In particular, Zig imports such as
`@import("basics")` are not Home source syntax.

## Verify before depending on an API

For an experimental capability, check all three of these before treating it as
usable:

1. The capability matrix describes the feature as stable.
2. A `.home` example or test exercises the same import and call shape.
3. The relevant test passes through the current Home CLI, not only as a Zig
   unit test of an implementation package.

If any layer is missing, the feature remains in progress. Please report a
minimal reproducer in the
[Home issue tracker](https://github.com/home-lang/home/issues).

## Related references

- [Standard-library module inventory](/docs/STDLIB-MODULES)
- [Implementation-side Basics module](/docs/BASICS_MODULE_GUIDE)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
- [Language guide](/docs/guide/getting-started)
