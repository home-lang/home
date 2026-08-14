# Operating Systems

Kernel code has no runtime underneath it. There is no allocator until you
write one, no standard library assumptions to lean on, and no operating system
to catch mistakes. Home targets that environment directly, and ships a
`kernel` package of primitives for it.

## Freestanding by default

A Home program does not require a runtime to start. There is no collector
thread, no start-up initialisation you did not write, and no hidden
allocation. That is what makes the language usable before there is an OS to
run on.

## The kernel package

The `kernel` package groups the primitives OS work needs, as zero-cost
abstractions with compile-time checking:

| Namespace | What it covers |
|---|---|
| `Kernel.asm` | Assembly operations and CPU control |
| `Kernel.memory` | Memory management primitives |
| `Kernel.interrupts` | Interrupt and exception handling |
| `Kernel.paging` | Page tables and virtual memory |
| `Kernel.atomic` | Atomic operations and lock-free structures |
| `Kernel.sync` | Synchronization primitives |

Port I/O is typed rather than a cast at the call site:

```zig
const value = Kernel.asm.inb(0x60);   // read from the keyboard controller
Kernel.asm.outb(0x3F8, 'A');          // write to the serial port
const data = Kernel.asm.inw(0x1F0);   // read a word from disk
```

See [kernel features](/docs/KERNEL_FEATURES) for the full surface and
[kernel architecture](/docs/KERNEL_ARCHITECTURE) for how the pieces fit together.

## Why the type system helps here

The failure modes in kernel code are the ones a type system is good at
catching, provided the abstractions cost nothing:

**Exhaustive interrupt dispatch.** A `match` over an exception enum will not
compile with a vector unhandled, so adding a new exception type surfaces every
place that has to care.

**Errors as values.** A page-table walk that can fail returns a `Result`. There
is no unwinding through a fault handler, because there is nothing to unwind
with. See [error handling](/docs/advanced/error-handling).

**Ownership without an allocator.** Ownership is a compile-time property, so it
works the same before you have a heap as after. See
[the memory model](/docs/advanced/memory).

**Comptime tables.** Descriptor tables, page-table constants and interrupt
vectors can be built during compilation and land in the binary as data. See
[comptime](/docs/advanced/comptime).

## HomeOS

HomeOS is the operating system built on these primitives and is the main
consumer of the kernel package. It is developed at
[github.com/home-lang/homeos](https://github.com/home-lang/homeos), which is
also the best place to see the package used at scale rather than in isolation.

## Status

The kernel package targets x86_64 today. The primitives are in place; the
language underneath them is still maturing, and native code generation handles
single-entrypoint builds with module-graph bundling in progress. This is the
most experimental use case on this site, and worth treating as such. The
[capability matrix](/docs/CAPABILITY_MATRIX) is the honest reference.

## Related

- [Kernel features](/docs/KERNEL_FEATURES)
- [Kernel architecture](/docs/KERNEL_ARCHITECTURE)
- [Memory model](/docs/advanced/memory)
- [Systems programming](/docs/use-cases/systems)
