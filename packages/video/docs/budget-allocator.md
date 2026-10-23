# Live allocation budget

`core/budget_allocator.zig` wraps a supplied Zig allocator with a serialized
live-byte ceiling, peak telemetry and a saturating denial count. It allocates no
tracking table or headers. Keep the wrapper at a stable address and follow the
underlying allocator's exact slice/alignment and single-owner rules.

Allocation, resize and remap check the ceiling before entering the parent. Failed
parent calls preserve accounting and the original allocation. Shrinks/frees return
capacity; realloc fallback's simultaneous old/new allocations count toward peak.
A budget denial is `OutOfMemory` through Zig's allocator interface. Requests near
`usize` maximum cannot wrap the live-byte check.

`disown` transfers an exact allocation without freeing it. Only use it when the
receiving owner frees through the SAME underlying allocator, after the wrapper's
last use of that allocation. It does not make unrelated allocators compatible.
This supports returning an encoded result after a bounded worker joins.

The wrapper bounds allocations routed through it, not thread stacks, arbitrary
external allocations or an application's independently retained results. Native
codec adapters must route their workspace allocation hooks through the supplied
allocator for those bytes to count. Home image's zlib adapter now does so, with a
16-byte aligned length prefix and failure-safe cleanup of partial initialization.

Validation: five budget tests and four zlib tests pass Zig 0.15.2 and the Home
0.18 development compiler in Debug/ReleaseSafe on macOS. The standalone budget
tests also cross-link actual Linux x86-64 and ARM64 ELF executables on both
compiler lines. Native zlib execution on Linux belongs to the consumer CI matrix;
cross-linking the standalone accounting helper is not codec execution evidence.
