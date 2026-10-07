---
title: Basics Zig Module
description: Use Home's implementation-side `basics` Zig module, understand its selected standard-library aliases, and avoid confusing it with Home's language-facing standard library.
---

# Basics Zig module

`packages/basics/src/basics.zig` is a Zig module used by parts of Home's own
implementation. It re-exports selected Zig standard-library APIs and adds Home
helpers. It is not implicitly available to `.home` programs and it is not the
public Home standard library.

## Who should use it

Use `basics` when working on a Zig package whose build file explicitly wires
the module:

```zig
const Basics = @import("basics");
```

That example is Zig syntax. A `.home` program should follow the
[language-facing standard-library status](/docs/reference/stdlib) instead.

## Current top-level surface

The root module currently exposes these groups from Zig's standard library:

- Containers and allocation: `Allocator`, `ArrayList`, `HashMap`,
  `StringHashMap`, `AutoHashMap`, `mem` and `heap`.
- Runtime helpers: `debug`, `fmt`, `math`, `fs`, `net`, `time`, `Thread`,
  `process`, `json`, `http`, `crypto`, `compress`, `sort` and `testing`.
- Convenience functions: `print`, `println`, `strEql`, `now`, `nowMillis`,
  `sleepMs`, `sleepSec`, `createAllocator` and `createArena`.
- Convenience types: `String`, `MutableString`, `Integer`, `Float`, `Boolean`,
  `Byte`, `Result` and `Option`.
- Home implementation modules including `http_router`, `session`,
  `middleware`, `validation`, `cli`, `datetime`, `regex`, `process_util`,
  `fs_util`, `net_util`, `crypto_util`, `memory_util` and `collections`.

The authoritative export list is
[`packages/basics/src/basics.zig`](https://github.com/home-lang/home/blob/main/packages/basics/src/basics.zig).

## Small Zig example

```zig
const Basics = @import("basics");

pub fn main() void {
    Basics.println("Home implementation helper: {s}", .{"basics"});

    if (!Basics.strEql("home", "home")) {
        Basics.debug.panic("string comparison failed", .{});
    }
}
```

The importing build must add the `basics` module. A bare import in an arbitrary
Zig project will not resolve automatically.

## Compatibility boundary

`basics` wraps a selected API surface; it does not expose every Zig `std`
symbol. Its aliases also follow the Zig version pinned by this repository, so
contributors should compile against Home's toolchain rather than assume an
arbitrary Zig release is compatible.

Before documenting a helper as supported:

1. Confirm it is exported by `packages/basics/src/basics.zig`.
2. Confirm the consuming build wires the `basics` import.
3. Add a focused Zig test for the helper.
4. Add a `.home` integration test separately if it is intended to become part
   of the language-facing standard library.

## Related pages

- [Standard-library status](/docs/reference/stdlib)
- [Standard-library module inventory](/docs/STDLIB-MODULES)
- [Capability matrix](/docs/CAPABILITY_MATRIX)
