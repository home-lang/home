# Systems Programming

Systems code lives with constraints that most application code never meets: a
fixed latency budget, a memory ceiling, a machine you have to address
directly. Home is built for that layer, and tries to make it readable while it
is there.

## What Home gives you here

**No collector, no runtime.** Ownership and borrowing settle every lifetime at
compile time. There is no collector to pause your process and nothing to ship
alongside the binary. See [the memory model](/docs/advanced/memory).

**Native code through LLVM.** `home build` produces a native executable. The
optimiser sees monomorphized generics and comptime-resolved constants, not a
dynamic dispatch table.

**Errors as values.** Nothing unwinds the stack behind your back. A function
that can fail says so in its type, and `?` propagates without hiding control
flow. See [error handling](/docs/advanced/error-handling).

**Direct memory access when you need it.** Pointers, slices, alignment control
and inline assembly are available, and are the exception rather than the
texture of ordinary code.

## What it looks like

A bounded ring buffer, the kind of structure that shows up in every systems
codebase:

```home
struct Ring<T> {
  items: [T],
  head: int,
  tail: int,
  len: int,
}

impl<T> Ring<T> {
  fn with_capacity(cap: int) -> Ring<T> {
    Ring { items: Array.with_capacity(cap), head: 0, tail: 0, len: 0 }
  }

  fn push(mut self, value: T) -> Result<(), Full> {
    if (self.len == self.items.len()) {
      return Err(Full)
    }

    self.items[self.tail] = value
    self.tail = (self.tail + 1) % self.items.len()
    self.len += 1
    Ok(())
  }

  fn pop(mut self) -> Option<T> {
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
  fn clock_gettime(clock: int, ts: *TimeSpec) -> int
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
