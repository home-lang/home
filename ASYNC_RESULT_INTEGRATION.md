# Async/Await + Result Type Integration

## Overview

The Home language provides seamless integration between the async/await system and Result types for ergonomic error handling. This integration enables Rust-style error propagation with the `?` operator in async functions.

## Result Type

### Definition

```zig
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        // Methods for working with Results
        pub fn isOk(self: Self) bool;
        pub fn isErr(self: Self) bool;
        pub fn unwrap(self: Self) !T;
        pub fn unwrapErr(self: Self) E;
        pub fn unwrapOr(self: Self, default: T) T;
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) Result(U, E);
        pub fn mapErr(self: Self, comptime F: type, f: *const fn (E) F) Result(T, F);
        pub fn andThen(self: Self, comptime U: type, f: *const fn (T) Result(U, E)) Result(U, E);
    };
}
```

### Basic Usage

```home
// Creating Results
let ok_value = Result(i32, Error).ok_value(42);
let err_value = Result(i32, Error).err_value(Error.NetworkFailed);

// Checking Results
if (result.isOk()) {
    let value = result.unwrap();
}

// Pattern matching
match result {
    Ok(value) => println("Success: {value}"),
    Err(err) => println("Error: {err}"),
}
```

## The ? Operator

### Syntax

The `?` operator unwraps a Result, automatically propagating errors:

```home
async fn fetchUserData(user_id: i32) -> Result<User, NetworkError> {
    // If httpGet returns Err, the error is immediately returned
    let response = await httpGet(url)?;

    // Only reached if httpGet returned Ok
    let user = await response.json()?;

    return Ok(user);
}
```

### How It Works

The `?` operator is desugared to:

```home
// Before
let value = await fetchData()?;

// After (conceptual)
let result = await fetchData();
match result {
    Ok(val) => val,
    Err(e) => return Err(e),
}
```

### State Machine Transformation

When async functions use `?`, the compiler transforms them into state machines that handle both await points and error propagation:

```home
// Source
async fn example() -> Result<i32, Error> {
    let x = await foo()?;
    let y = await bar(x)?;
    return Ok(x + y);
}

// Generated state machine (conceptual)
struct ExampleStateMachine {
    state: enum { Start, AwaitFoo, AwaitBar, Done },
    x: ?i32,

    fn poll(self: *Self, ctx: *Context) PollResult(Result(i32, Error)) {
        switch (self.state) {
            .Start => {
                // Start foo future
                self.state = .AwaitFoo;
            },
            .AwaitFoo => {
                switch (foo_future.poll(ctx)) {
                    .Ready => |result| {
                        switch (result) {
                            .Ok => |val| {
                                self.x = val;
                                self.state = .AwaitBar;
                            },
                            .Err => |e| {
                                // Propagate error
                                return .{ .Ready = Result.err_value(e) };
                            },
                        }
                    },
                    .Pending => return .Pending,
                }
            },
            // ... similar for AwaitBar
        }
    }
}
```

## Error Propagation Patterns

### Basic Propagation

```home
async fn fetchAndProcess(id: i32) -> Result<ProcessedData, Error> {
    let data = await fetchData(id)?;
    let processed = await processData(data)?;
    return Ok(processed);
}
```

### Converting Error Types

```home
enum AppError {
    Network(NetworkError),
    Database(DatabaseError),
    Validation(string),
}

async fn complexOperation(id: i32) -> Result<Data, AppError> {
    // Convert NetworkError to AppError
    let user = await fetchUser(id)
        .mapErr(|e| AppError.Network(e))?;

    // Convert DatabaseError to AppError
    let posts = await fetchPosts(user.id)
        .mapErr(|e| AppError.Database(e))?;

    return Ok(Data { user, posts });
}
```

### Chaining Operations

```home
async fn pipeline(id: i32) -> Result<FinalData, Error> {
    return await fetchData(id)
        .andThen(|data| validateData(data))
        .andThen(|valid| processData(valid))
        .andThen(|processed| storeData(processed));
}
```

### Selective Error Handling

```home
async fn fetchWithFallback(id: i32) -> Result<User, Error> {
    match await fetchUser(id) {
        Ok(user) => Ok(user),
        Err(Error.NotFound) => {
            // Provide default user for NotFound
            Ok(User.default())
        },
        Err(e) => Err(e), // Propagate other errors
    }
}
```

## ResultFuture

For advanced use cases, `ResultFuture` provides combinators for working with futures that resolve to Results:

```zig
pub fn ResultFuture(comptime T: type, comptime E: type) type {
    return struct {
        inner: Future(Result(T, E)),

        pub fn map(self: *Self, comptime U: type, f: *const fn (T) U) !ResultFuture(U, E);
        pub fn andThen(self: *Self, comptime U: type, f: *const fn (T) Future(Result(U, E))) !ResultFuture(U, E);
    };
}
```

### Usage

```home
let fut = fetchUserFuture(123)
    .map(|user| user.name)
    .andThen(|name| fetchPostsByAuthor(name));

let result = await fut;
```

## Best Practices

### 1. Use ? for Early Returns

```home
// Good - clear error propagation
async fn process(id: i32) -> Result<Data, Error> {
    let user = await fetchUser(id)?;
    let posts = await fetchPosts(user.id)?;
    return Ok(Data { user, posts });
}

// Avoid - nested match statements
async fn process(id: i32) -> Result<Data, Error> {
    match await fetchUser(id) {
        Ok(user) => {
            match await fetchPosts(user.id) {
                Ok(posts) => Ok(Data { user, posts }),
                Err(e) => Err(e),
            }
        },
        Err(e) => Err(e),
    }
}
```

### 2. Convert Error Types at Boundaries

```home
// Convert errors at module boundaries
async fn publicApi(id: i32) -> Result<Data, PublicError> {
    let internal = await internalOperation(id)
        .mapErr(|e| PublicError.from(e))?;

    return Ok(internal);
}
```

### 3. Provide Context for Errors

```home
async fn fetchWithContext(id: i32) -> Result<User, Error> {
    await fetchUser(id)
        .mapErr(|e| Error.FetchFailed {
            user_id: id,
            reason: e,
        })?
}
```

### 4. Use unwrapOr for Defaults

```home
async fn fetchOrDefault(id: i32) -> User {
    let result = await fetchUser(id);
    return result.unwrapOr(User.default());
}
```

## Performance Characteristics

- **Zero-cost**: Result checking compiles to simple tag checks
- **? operator**: Inline early return, no function call overhead
- **State machines**: No heap allocation for error propagation
- **Type-safe**: All error paths checked at compile time

## Examples

See `examples/async_result_example.home` for comprehensive examples including:
- Basic Result + async usage
- Error propagation with ?
- Error type conversion
- Retry logic with Results
- Timeout + Result
- Parallel operations with Results
- Complex error handling workflows

## Implementation Files

- **packages/async/src/result_future.zig** (345 lines)
  - Result type definition
  - ResultFuture combinators
  - Helper functions

- **packages/codegen/src/async_transform.zig**
  - TryExpr handling in async functions
  - State machine generation with error propagation

- **packages/ast/src/ast.zig**
  - TryExpr AST node (? operator)

- **packages/codegen/src/native_codegen.zig**
  - Native code generation for ? operator
  - Result tag checking and early returns

## Testing

All Result functionality is thoroughly tested:

```bash
zig test packages/async/test_result.zig
```

Tests cover:
- Result construction (ok/err)
- Result checking (isOk/isErr)
- Unwrapping (unwrap/unwrapErr/unwrapOr)
- Transformations (map/mapErr)
- Chaining (andThen)
- Error propagation semantics

All 13 tests pass successfully.

## Future Enhancements

Planned improvements:

1. **Custom error context**: Attach additional context to errors
2. **Error recovery**: Built-in retry/fallback mechanisms
3. **Error aggregation**: Collect multiple errors from parallel operations
4. **Stack traces**: Async-aware error stack traces

## Conclusion

The Result + async integration provides:
- ✅ Type-safe error handling
- ✅ Ergonomic ? operator
- ✅ Zero-cost abstractions
- ✅ Composable error transformations
- ✅ Seamless async/await integration

This makes Home's async error handling as ergonomic as Rust while maintaining the performance and simplicity of the async runtime.
