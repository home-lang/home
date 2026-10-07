---
title: Systems Programming
description: Explore Home's systems-programming model for explicit memory, native code, Result-based failures, direct hardware access, and current maturity.
---

# Systems Programming

Systems code lives with constraints that most application code never meets: a
fixed latency budget, a memory ceiling, a machine you have to address
directly. Home is being built for that layer, with the front end and
interpreter usable today while native codegen, ownership, borrowing, and FFI
mature.

## What Home gives you here

**Collector-free design goal.** Ownership and borrowing are intended to settle
every lifetime at compile time. The target model has no collector to pause the
process and no hosted runtime to ship alongside a native binary. See
[the memory model](/docs/advanced/memory).

**Native code through LLVM.** `home build` produces native executables for the
currently supported single-entrypoint path. As generic and comptime support
matures, the optimiser can see specialized constants and types instead of a
dynamic dispatch table.

**Errors as values.** In Home's developing `Result` model, a function that can
fail says so in its type, and `?` propagates without hiding control flow. See
[error handling](/docs/advanced/error-handling).

**Direct-memory-access goal.** Pointers, slices, alignment control, and inline
assembly are intended to remain available as explicit tools rather than the
texture of ordinary code.

## What it looks like

A bounded ring buffer, the kind of structure that shows up in every systems
codebase:

```home
struct Ring<T> {
  items: []T,
  head: int,
  tail: int,
  len: int,
}

impl<T> Ring<T> {
  fn with_capacity(cap: int): Ring<T> {
    Ring { items: Array.with_capacity(cap), head: 0, tail: 0, len: 0 }
  }

  fn push(mut self, value: T): Result<(), Full> {
    if (self.len == self.items.len()) {
      return Err(Full)
    }

    self.items[self.tail] = value
    self.tail = (self.tail + 1) % self.items.len()
    self.len += 1
    Ok(())
  }

  fn pop(mut self): Option<T> {
    match self.len {
      0 => None,
      _ => {
        let value = self.items[self.head]
        self.head = (self.head + 1) % self.items.len()
        self.len -= 1
        Some(value)
      }
    }
  }
}
```

The capacity check returns a value rather than trapping, the empty case is
handled by the match rather than by a comment, and neither costs anything at
runtime that a hand-written C version would not also pay.

## Compile-time work

Anything you can compute before the program runs, you can compute in
[comptime](/docs/advanced/comptime). Lookup tables, protocol tables and dispatch
tables become constants in the binary:

```home
comptime {
  let crc_table = build_crc_table()
}
```

The table exists in the compiled output. No initialisation runs at start-up,
and nothing has to be lazily built on first use.

## Talking to C

Existing systems code is written in C, and Home calls it without a binding
generator:

```home
extern "C" {
  fn clock_gettime(clock: int, ts: *TimeSpec): int
}
```

See [FFI](/docs/features/ffi) for struct layout, callbacks and ownership across the
boundary.

## Status

The front end, type inference and the interpreter are usable today. Native
code generation goes through LLVM and handles single-entrypoint builds;
whole-module-graph bundling and cross-target builds are still in progress.
Check the [capability matrix](/docs/CAPABILITY_MATRIX) before committing a project
to a specific feature.

## Related

- [Memory model](/docs/advanced/memory)
- [Performance](/docs/advanced/performance)
- [Operating systems](/docs/use-cases/operating-systems)
- [FFI](/docs/features/ffi)
