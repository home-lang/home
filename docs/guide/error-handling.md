# Error Handling

Home uses the `Result<T, E>` type for recoverable errors, providing explicit and composable error handling without exceptions.

## The Result Type

```home
enum Result<T, E> {
  Ok(T),
  Err(E)
}
```

Functions that can fail return a `Result`:

```home
fn divide(a: int, b: int): Result<int, string> {
  if (b == 0) {
    return Err("division by zero")
  }
  return Ok(a / b)
}
```

## Handling Results

### Pattern Matching

The most explicit way to handle results:

```home
let result = divide(10, 2)

match result {
  Ok(value) => print("Result: {value}"),
  Err(e) => print("Error: {e}")
}
```

### unwrap and expect

For quick prototyping (panics on error):

```home
// Panics with generic message if Err
let value = divide(10, 2).unwrap()

// Panics with custom message if Err
let value = divide(10, 2).expect("Division failed")
```

::: warning
Avoid `unwrap()` and `expect()` in production code. Use proper error handling instead.
:::

### unwrap_or and unwrap_or_else

Provide default values:

```home
// Use default value on error
let value = divide(10, 0).unwrap_or(0)

// Compute default lazily
let value = divide(10, 0).unwrap_or_else(|e| {
  print("Error: {e}, using default")
  0
})
```

## The ? Operator

The `?` operator propagates errors automatically:

```home
fn read_config(): Result<Config, Error> {
  let content = fs.read_file("config.json")?  // Returns early if Err
  let config = json.parse(content)?
  return Ok(config)
}
```

This is equivalent to:

```home
fn read_config(): Result<Config, Error> {
  let content = match fs.read_file("config.json") {
    Ok(c) => c,
    Err(e) => return Err(e)
  }

  let config = match json.parse(content) {
    Ok(c) => c,
    Err(e) => return Err(e)
  }

  return Ok(config)
}
```

### Chaining with ?

```home
fn get_user_email(id: int): Result<string, Error> {
  let user = database.find_user(id)?
  let profile = user.get_profile()?
  let email = profile.email.ok_or(Error.new("No email"))?
  return Ok(email)
}
```

## Custom Error Types

Define your own error types:

```home
enum FileError {
  NotFound(string),
  PermissionDenied(string),
  IoError(string)
}

impl FileError {
  fn message(self): string {
    match self {
      FileError.NotFound(path) => "File not found: {path}",
      FileError.PermissionDenied(path) => "Permission denied: {path}",
      FileError.IoError(msg) => "IO error: {msg}"
    }
  }
}

fn read_file(path: string): Result<string, FileError> {
  if (!file_exists(path)) {
    return Err(FileError.NotFound(path))
  }

  if (!has_permission(path)) {
    return Err(FileError.PermissionDenied(path))
  }

  // ... read file
  return Ok(content)
}
```

### Error Traits

Implement standard traits for error types:

```home
trait Error {
  fn message(&self): string
  fn source(&self): Option<&dyn Error> {
    None
  }
}

impl Error for FileError {
  fn message(&self): string {
    self.message()
  }
}
```

## The Option Type

For values that may or may not exist:

```home
enum Option<T> {
  Some(T),
  None
}

fn find_user(id: int): Option<User> {
  // Returns None if not found
  database.query("SELECT * FROM users WHERE id = ?", id)
}
```

### Option Methods

```home
let user = find_user(1)

// Check if value exists
if (user.is_some()) {
  print("Found user")
}

// Get value or default
let name = user.map(|u| u.name).unwrap_or("Unknown")

// Transform the value
let upper_name = user.map(|u| u.name.upper())

// Chain optional operations
let email = user
  .and_then(|u| u.profile)
  .and_then(|p| p.email)

// Convert to Result
let user_result = user.ok_or(Error.new("User not found"))
```

## Converting Between Option and Result

```home
// Option to Result
let opt: Option<int> = Some(42)
let res: Result<int, string> = opt.ok_or("No value")

// Result to Option
let res: Result<int, string> = Ok(42)
let opt: Option<int> = res.ok()  // Discards error
```

## Error Propagation Patterns

### Early Return Pattern

```home
fn process_data(data: Data): Result<Output, Error> {
  // Validate early
  if (!data.is_valid()) {
    return Err(Error.new("Invalid data"))
  }

  // Process with ?
  let step1 = first_step(data)?
  let step2 = second_step(step1)?
  let result = final_step(step2)?

  return Ok(result)
}
```

### Collecting Results

```home
fn process_all(items: []Item): Result<[]Output, Error> {
  let results = []

  for (item in items) {
    let output = process_item(item)?
    results.push(output)
  }

  return Ok(results)
}

// Or using iterators
fn process_all(items: []Item): Result<[]Output, Error> {
  items.iter()
    .map(|item| process_item(item))
    .collect()
}
```

### Combining Multiple Results

```home
fn fetch_data(): Result<CombinedData, Error> {
  let users = fetch_users()?
  let posts = fetch_posts()?
  let comments = fetch_comments()?

  return Ok(CombinedData { users, posts, comments })
}
```

## Built-in Macros for Errors

### assert!

Panics if condition is false:

```home
fn divide(a: i32, b: i32): i32 {
  assert!(b != 0, "division by zero")
  return a / b
}
```

### debug_assert!

Only checked in debug builds:

```home
fn validate_input(value: i32) {
  debug_assert!(value >= 0, "value must be non-negative")
  debug_assert!(value <= 100, "value must be at most 100")
}
```

### todo!

Marks unfinished code:

```home
fn incomplete_feature() {
  todo!("OAuth authentication")
}
```

### unreachable!

Marks code that should never execute:

```home
fn handle_status(code: i32): string {
  if (code == 200) {
    return "OK"
  } else if (code == 404) {
    return "Not Found"
  } else {
    unreachable!("unexpected status code")
  }
}
```

## Best Practices

### 1. Use Result for Expected Failures

```home
// Good: Expected failure (file might not exist)
fn read_config(): Result<Config, Error> { ... }

// Bad: Using panic for expected failures
fn read_config(): Config {
  // Don't do this
  let content = fs.read_file("config.json").unwrap()
  ...
}
```

### 2. Provide Context

```home
fn load_user(id: int): Result<User, Error> {
  database.find(id)
    .ok_or_else(|| Error.new("User {id} not found"))
}
```

### 3. Create Domain-Specific Errors

```home
enum AppError {
  Database(DatabaseError),
  Network(NetworkError),
  Validation(string),
  NotFound(string)
}
```

### 4. Use ? Liberally

```home
// Clean and readable
fn process(): Result<Output, Error> {
  let a = step1()?
  let b = step2(a)?
  let c = step3(b)?
  Ok(c)
}
```

## Next Steps

- [Memory Safety](/guide/memory) - Ownership and borrowing
- [Async Programming](/guide/async) - Async error handling
- [Standard Library](/reference/stdlib) - Built-in error types
