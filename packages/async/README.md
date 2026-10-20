# Home Async Runtime

## Overview

The async package provides Home's work-stealing executor, type-erased futures,
task handles, wakeups, and lock-free scheduling queues.

## Features

- **Futures**: Async computation primitives with completion tracking
- **Task Scheduling**: Multi-worker runtime with local Chase-Lev deques and a global injector
- **Waker System**: Notification mechanism for async operations
- **Task States**: Pending, Running, Completed, and Failed states
- **Blocking**: Futex-backed worker parking with retained notifications

## Usage

```zig
const async = @import("async");

var runtime = try async.Runtime.init(allocator, 0);
defer runtime.deinit();

const future = try async.future.ready(i32, 42, allocator);
const result = try runtime.blockOn(i32, future);

try std.testing.expectEqual(@as(i32, 42), result);
```

## API Reference

### Main Types

- **Future(T)**: Represents an async computation that will eventually produce a value of type T
- **Task**: A unit of async work with state tracking
- **Runtime**: Work-stealing runtime for executing and scheduling async tasks
- **Waker**: Callback mechanism to notify when a future is ready

### Main Functions

- `future.ready(T, value, allocator)`: Create an immediately ready future
- `future.pending(T, allocator)`: Create a future that remains pending
- `Runtime.spawn(T, future)`: Schedule a future and return a join handle
- `Runtime.blockOn(T, future)`: Run a future to completion
- `Runtime.initWithTaskAllocator(runtime_allocator, task_allocator, workers)`:
  Keep short-lived task and cloned-waker allocations in a dedicated pool

## Files

- `async.zig`: Public package root
- `runtime.zig`: Work-stealing task executor
- `future.zig` and `task.zig`: Future, waker, task, and join-handle types
- `concurrent_queue.zig`: Lock-free global injector
- `work_stealing_deque.zig`: Owner-local Chase-Lev deque
- `parker.zig`: Futex-backed worker parking

## Testing

`PreparationGate` separates queued, preparing, ready and published work from
terminal cancellation/failure. `claim`, `ready` and `publish` enforce that order.
Queued cancellation wins before resource acquisition. Cancelling preparing/ready
work records a cooperative request: the owner releases its resources, then calls
`cleaned()` to make cancellation terminal. Repeated requests return false.
Publication and terminal outcomes cannot be undone by late cancellation or errors.
If preparation itself fails while cancellation is requested, `fail()` preserves
failure instead of claiming successful cancellation.

Use the caller's mutex around the gate and the actual publication boundary.
Keep result events and slot release after cleanup, and retain resource ownership
while arbitrary callbacks are still running. The gate does not interrupt code,
run cleanup, allocate, or provide synchronization. Standalone tests cover queued
and claimed cancellation, publication, invalid order and failure races:

```bash
zig test packages/async/src/preparation_gate.zig
```

`CompletionWatermark` (also available directly from `src/completion_watermark.zig`)
tracks FIFO admissions and completed prefixes without allocations. `reserve()`
returns an increasing ticket; `complete()` acknowledges the next operation.
Capture `issued` at submission and `poll(ticket)` for pending, success, or the
first failure code. Later admissions cannot extend a ticket's boundary, and a
later failure cannot invalidate an already completed prefix. Invalid targets,
extra acknowledgements, and sequence overflow fail without mutation.

The caller supplies synchronization, wakeups, lifetime retention, and a bounded
ticket registry. Keep the watermark alive until its worker and all retained
waiters finish; never retain a pointer to a worker that may be destroyed.
`fail(code)` closes admission and fails unfinished prefixes, preserving the first
code. This helper does not cancel callbacks, create threads, or imply durable I/O.

```bash
zig test packages/async/src/completion_watermark.zig
```

```bash
zig build test -Dfilter=async
```

The executor acceptance test compiles its ThreadSanitizer binary once, then
runs one million tasks serially in bounded-memory batches backed by a reusable
task pool. Each batch is submitted by an executor worker into its local deque,
so peer workers must steal the child tasks. Every task must be polled exactly
once and every runtime worker must execute work. The default command repeats
that complete run 100 times, with each compiler and test process supervised by
Home's machine lock, timeout, and memory ceiling:

```bash
scripts/async-runtime-tsan.sh
```

For a quick local smoke run, pass iterations, task count, and batch size:

```bash
scripts/async-runtime-tsan.sh 1 10000 1024
```

## Implementation Status

- [x] Future type with generic values
- [x] Task state machine
- [x] Waker mechanism
- [x] Work-stealing executor core
- [x] Native and ThreadSanitizer coverage
- [x] Linux and Windows compile coverage
- [ ] Async I/O integration

## Related Packages

- [interpreter]: Uses async for concurrent execution
- [runtime]: Provides runtime support for async operations

## License

Part of the Home programming language project.

## Terminal job state and event completion

Task cancellation is terminal: an in-flight future poll returning Ready or Pending
cannot overwrite Cancelled, and cancelling an already completed/failed task does
not replace its result. JoinHandle.await returns TaskFailed immediately for a
failed task. Cancellation does not interrupt a currently executing poll or make
its storage safe to free; quiesce/join the polling owner before deinit.

`CompletionGate` is a small allocation-free two-phase event-job helper. It ignores
events from older revisions and terminal outcomes before an active phase has been
observed. A monotonic observation watermark also rejects completions older than
the latest accepted event, even when both are newer than the job start revision.
Equal-revision scan and completion events remain valid. Success, failure,
cancellation and stop are immutable terminal states.
The caller owns synchronization; it is not an executor or a generic Future.
zig-utils/zig-camera uses this Home module for autofocus scan gating under its
native session mutex without allocating or running consumer work in callbacks.

Regression tests cover cancellation between poll reservation and both Ready and
Pending results, late cancellation, failed joins, stale event revisions, and
terminal immutability. Focused task/gate tests pass on Zig 0.15.2 and Home's current
0.17 development toolchain. The complete async root suite also passes locally with
its threading_futex module supplied:

```sh
zig test -lc --dep threading_futex -Mroot=packages/async/src/async.zig -Mthreading_futex=packages/runtime/src/threading/Futex.zig
```
