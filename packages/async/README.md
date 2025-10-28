# Home Async Runtime

## Overview

The async package provides async/await functionality and concurrent task execution for Home. It includes a Future-based async runtime with support for task scheduling and waker mechanisms.

## Features

- **Futures**: Async computation primitives with completion tracking
- **Task Scheduling**: Runtime for managing concurrent tasks
- **Waker System**: Notification mechanism for async operations
- **Task States**: Pending, Running, Completed, and Failed states

## Usage

```zig
const async_runtime = @import("async_runtime");

// Create a future
var future = async_runtime.Future(i32).init();

// Complete the future
future.complete(42);

// Poll for result
const result = try future.poll();
```

## API Reference

### Main Types

- **Future(T)**: Represents an async computation that will eventually produce a value of type T
- **Task**: A unit of async work with state tracking
- **AsyncRuntime**: Runtime for executing and scheduling async tasks
- **Waker**: Callback mechanism to notify when a future is ready

### Main Functions

- `Future.init()`: Create a new pending future
- `Future.complete(value)`: Mark future as completed with a value
- `Future.fail(err)`: Mark future as failed with an error
- `Future.poll()`: Check if future is ready and get result

## Files

- `async_runtime.zig`: Core async runtime and Future implementation
- `executor.zig`: Task executor
- `concurrency.zig`: Concurrency primitives
- `io.zig`: Async I/O operations

## Testing

```bash
zig test packages/async/tests/async_test.zig
```

## Implementation Status

- [x] Future type with generic values
- [x] Task state machine
- [x] Waker mechanism
- [x] Basic tests
- [ ] Full executor implementation
- [ ] Async I/O integration

## Related Packages

- [interpreter]: Uses async for concurrent execution
- [runtime]: Provides runtime support for async operations

## License

Part of the Home programming language project.
