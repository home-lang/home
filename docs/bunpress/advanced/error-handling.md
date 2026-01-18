# Error Handling

Home provides a comprehensive error handling system that combines the explicitness of Result types with the convenience of modern language features. This approach ensures errors are never silently ignored while maintaining ergonomic code.

## Overview

Home's error handling philosophy:

- **Explicit error paths**: Errors are part of the type signature
- **No hidden control flow**: No exceptions that unwind the stack unexpectedly
- **Composable errors**: Error types can be combined and transformed
- **Zero-cost when unused**: No overhead for code paths that don't error

## The Result Type

### Basic Result Usage

```home
enum Result<T, E> {
    Ok(T),
    Err(E),
}

fn parse_number(s: string) -> Result<i32, ParseError> {
    // Implementation
}

fn main() {
    let result = parse_number("42")

    match result {
        Ok(n) => print("Parsed: {n}"),
        Err(e) => print("Error: {e}"),
    }
}
```

### The ? Operator

Propagate errors concisely with the `?` operator:

```home
fn read_config() -> Result<Config, Error> {
    let file = File.open("config.json")?  // Returns early if Err
    let contents = file.read_to_string()?
    let config = json.parse(contents)?
    Ok(config)
}
```

### Result Methods

```home
let result: Result<i32, Error> = Ok(42)

// Transform success value
let doubled = result.map(|n| n * 2)  // Ok(84)

// Transform error value
let with_context = result.map_err(|e| Error.wrap(e, "context"))

// Chain operations
let final_result = result
    .and_then(|n| validate(n))
    .and_then(|n| process(n))

// Provide defaults
let value = result.unwrap_or(0)
let value = result.unwrap_or_else(|e| {
    log.warn("Using default: {e}")
    0
})

// Convert to Option
let maybe = result.ok()  // Some(42) or None
```

## Defining Error Types

### Simple Error Structs

```home
struct FileError {
    path: string,
    kind: FileErrorKind,
    source: ?Box<dyn Error>,
}

enum FileErrorKind {
    NotFound,
    PermissionDenied,
    InvalidFormat,
    IoError,
}

impl Error for FileError {
    fn message(&self) -> string {
        match self.kind {
            FileErrorKind.NotFound => "File not found: {self.path}",
            FileErrorKind.PermissionDenied => "Permission denied: {self.path}",
            FileErrorKind.InvalidFormat => "Invalid format: {self.path}",
            FileErrorKind.IoError => "IO error: {self.path}",
        }
    }

    fn source(&self) -> ?&dyn Error {
        self.source.as_deref()
    }
}
```

### Error Enums

```home
enum DatabaseError {
    ConnectionFailed { host: string, port: u16 },
    QueryFailed { query: string, message: string },
    Timeout { duration: Duration },
    InvalidData { expected: string, got: string },
}

impl Error for DatabaseError {
    fn message(&self) -> string {
        match self {
            DatabaseError.ConnectionFailed { host, port } => {
                "Failed to connect to {host}:{port}"
            }
            DatabaseError.QueryFailed { query, message } => {
                "Query failed: {message}\nQuery: {query}"
            }
            DatabaseError.Timeout { duration } => {
                "Operation timed out after {duration}"
            }
            DatabaseError.InvalidData { expected, got } => {
                "Invalid data: expected {expected}, got {got}"
            }
        }
    }
}
```

### The Error Trait

```home
trait Error {
    fn message(&self) -> string
    fn source(&self) -> ?&dyn Error { null }

    fn chain(&self) -> ErrorChain {
        ErrorChain { current: Some(self) }
    }
}

struct ErrorChain<'a> {
    current: ?&'a dyn Error,
}

impl Iterator for ErrorChain<'_> {
    type Item = &dyn Error

    fn next(mut self) -> ?Self.Item {
        let current = self.current?
        self.current = current.source()
        Some(current)
    }
}
```

## Error Conversion

### From Trait for Errors

```home
impl From<IoError> for AppError {
    fn from(e: IoError) -> AppError {
        AppError.Io(e)
    }
}

impl From<ParseError> for AppError {
    fn from(e: ParseError) -> AppError {
        AppError.Parse(e)
    }
}

// Now ? automatically converts
fn process_file(path: &str) -> Result<Data, AppError> {
    let file = File.open(path)?        // IoError -> AppError
    let text = file.read_to_string()?  // IoError -> AppError
    let data = parse(text)?            // ParseError -> AppError
    Ok(data)
}
```

### The #[derive(Error)] Macro

```home
#[derive(Error, Debug)]
enum ServiceError {
    #[error("Network error: {0}")]
    Network(#[from] NetworkError),

    #[error("Database error: {0}")]
    Database(#[from] DatabaseError),

    #[error("Validation failed: {message}")]
    Validation { message: string },

    #[error("Not found: {resource}")]
    NotFound { resource: string },
}
```

## Error Context

### Adding Context to Errors

```home
trait ResultExt<T, E> {
    fn context(self, msg: string) -> Result<T, ContextError<E>>
    fn with_context<F: Fn() -> string>(self, f: F) -> Result<T, ContextError<E>>
}

fn read_config(path: &str) -> Result<Config, Error> {
    let contents = std.fs.read_to_string(path)
        .context("Failed to read config file")?

    let config = json.parse(&contents)
        .with_context(|| "Failed to parse config at {path}")?

    Ok(config)
}
```

### Error Chains

```home
fn load_user(id: u64) -> Result<User, Error> {
    let row = database.query("SELECT * FROM users WHERE id = ?", id)
        .context("Failed to query database")?

    let user = User.from_row(row)
        .context("Failed to parse user data")?

    Ok(user)
}

// When error occurs, chain shows:
// Error: Failed to parse user data
// Caused by: Invalid date format in 'created_at' field
// Caused by: Expected ISO 8601 format
```

## Panic and Unrecoverable Errors

### When to Panic

```home
// Use panic for programming errors, not runtime errors
fn get_element(arr: []i32, index: usize) -> i32 {
    if index >= arr.len() {
        panic("Index {index} out of bounds for array of length {arr.len()}")
    }
    arr[index]
}

// Assertions for invariants
fn process_positive(n: i32) -> i32 {
    assert(n > 0, "Expected positive number, got {n}")
    n * 2
}

// Debug assertions (removed in release builds)
fn optimized_path(data: []u8) {
    debug_assert(data.len() >= 4, "Data too short")
    // ...
}
```

### Catching Panics

```home
use std.panic

fn risky_operation() {
    panic("Something went wrong!")
}

fn main() {
    let result = panic.catch(|| {
        risky_operation()
        42
    })

    match result {
        Ok(value) => print("Got: {value}"),
        Err(panic_info) => print("Caught panic: {panic_info}"),
    }
}
```

### Custom Panic Handlers

```home
#[panic_handler]
fn custom_panic(info: &PanicInfo) -> never {
    // Log the panic
    log.error("PANIC: {info}")

    // In embedded systems, might reset
    #[cfg(embedded)]
    system.reset()

    // Otherwise abort
    std.process.abort()
}
```

## Try Blocks

### Explicit Try Scopes

```home
fn process() -> Result<Output, Error> {
    let result = try {
        let a = operation_a()?
        let b = operation_b(a)?
        let c = operation_c(b)?
        c
    }

    match result {
        Ok(output) => {
            log.info("Success")
            Ok(output)
        }
        Err(e) => {
            log.error("Failed: {e}")
            Err(e)
        }
    }
}
```

### Try Blocks with Different Error Types

```home
fn mixed_errors() -> Result<Data, AppError> {
    // Convert errors within try block
    let data = try {
        let file_content = read_file()?  // IoError
        let parsed = parse_json(file_content)?  // ParseError
        let validated = validate(parsed)?  // ValidationError
        validated
    }.map_err(|e| AppError.from(e))?

    Ok(data)
}
```

## Optional Error Handling

### The Option Type

```home
fn find_user(id: u64) -> ?User {
    database.users.get(id)
}

fn main() {
    // Pattern matching
    match find_user(123) {
        Some(user) => print("Found: {user.name}"),
        None => print("User not found"),
    }

    // Optional chaining
    let name = find_user(123)?.profile?.display_name

    // Default values
    let user = find_user(123) ?? User.guest()

    // If-let
    if let Some(user) = find_user(123) {
        send_welcome_email(user)
    }
}
```

### Converting Between Option and Result

```home
// Option to Result
let result = maybe_value.ok_or(Error.new("No value"))
let result = maybe_value.ok_or_else(|| compute_error())

// Result to Option
let maybe = result.ok()   // Discards error
let maybe = result.err()  // Gets error, discards success

// Transpose nested types
let nested: ?Result<i32, Error> = Some(Ok(42))
let transposed: Result<?i32, Error> = nested.transpose()  // Ok(Some(42))
```

## Advanced Patterns

### Error Aggregation

```home
fn validate_all(items: []Item) -> Result<[], Vec<ValidationError>> {
    let mut errors = Vec.new()

    for item in items {
        if let Err(e) = validate(item) {
            errors.push(e)
        }
    }

    if errors.is_empty() {
        Ok([])
    } else {
        Err(errors)
    }
}
```

### Retry Logic

```home
fn retry<T, E>(
    attempts: u32,
    delay: Duration,
    operation: fn() -> Result<T, E>
) -> Result<T, E> {
    let mut last_error: ?E = null

    for attempt in 1..=attempts {
        match operation() {
            Ok(value) => return Ok(value),
            Err(e) => {
                log.warn("Attempt {attempt} failed: {e}")
                last_error = Some(e)

                if attempt < attempts {
                    std.thread.sleep(delay)
                }
            }
        }
    }

    Err(last_error.unwrap())
}
```

### Fallback Chains

```home
fn get_config() -> Result<Config, Error> {
    read_from_file("config.json")
        .or_else(|_| read_from_env())
        .or_else(|_| read_from_defaults())
}
```

## Integration Patterns

### With Async Code

```home
async fn fetch_data(url: &str) -> Result<Data, Error> {
    let response = http.get(url).await?
    let body = response.text().await?
    let data = json.parse(body)?
    Ok(data)
}

async fn fetch_with_fallback(urls: []&str) -> Result<Data, Error> {
    for url in urls {
        match fetch_data(url).await {
            Ok(data) => return Ok(data),
            Err(e) => log.warn("Failed to fetch from {url}: {e}"),
        }
    }
    Err(Error.new("All sources failed"))
}
```

### With Resources

```home
fn with_transaction<T>(f: fn(&Transaction) -> Result<T, Error>) -> Result<T, Error> {
    let tx = database.begin_transaction()?

    match f(&tx) {
        Ok(result) => {
            tx.commit()?
            Ok(result)
        }
        Err(e) => {
            tx.rollback()?
            Err(e)
        }
    }
}
```

## Best Practices

1. **Use Result for recoverable errors, panic for bugs**:
   ```home
   // Good: File might not exist
   fn read_file(path: &str) -> Result<string, IoError>

   // Good: Index out of bounds is a bug
   fn get(arr: []T, i: usize) -> T {
       assert(i < arr.len())
       arr[i]
   }
   ```

2. **Create domain-specific error types**:
   ```home
   // Good: Clear error domain
   enum UserServiceError {
       NotFound { id: UserId },
       InvalidCredentials,
       AccountLocked { until: DateTime },
   }

   // Avoid: Generic errors
   fn get_user() -> Result<User, string>
   ```

3. **Provide context at error sites**:
   ```home
   file.write_all(data)
       .context("Failed to save user preferences")?
   ```

4. **Don't ignore errors**:
   ```home
   // Bad: Error ignored
   let _ = file.write(data)

   // Good: Explicit handling
   if let Err(e) = file.write(data) {
       log.warn("Failed to write: {e}")
   }
   ```

5. **Use early returns for clarity**:
   ```home
   fn process(input: Input) -> Result<Output, Error> {
       if !input.is_valid() {
           return Err(Error.invalid_input())
       }

       let intermediate = step_one(input)?
       let result = step_two(intermediate)?
       Ok(result)
   }
   ```
