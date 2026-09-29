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

## Files

- `async.zig`: Public package root
- `runtime.zig`: Work-stealing task executor
- `future.zig` and `task.zig`: Future, waker, task, and join-handle types
- `concurrent_queue.zig`: Lock-free global injector
- `work_stealing_deque.zig`: Owner-local Chase-Lev deque
- `parker.zig`: Futex-backed worker parking

## Testing

```bash
zig build test -Dfilter=async
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
