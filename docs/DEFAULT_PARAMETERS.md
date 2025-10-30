# Default Parameters in Home

Default parameters allow functions to have optional arguments with predefined values, making APIs more flexible and easier to use.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Parameter Order Rules](#parameter-order-rules)
- [Calling Functions](#calling-functions)
- [With Named Parameters](#with-named-parameters)
- [Generic Functions](#generic-functions)
- [Best Practices](#best-practices)

## Basic Syntax

### Simple Default Parameters

```home
// Function with default parameter
fn greet(name: string = "World") -> void {
    println("Hello, {}!", name)
}

// Call with argument
greet("Alice")  // Hello, Alice!

// Call without argument (uses default)
greet()  // Hello, World!
```

### Multiple Defaults

```home
fn create_user(
    name: string,
    age: i32 = 0,
    active: bool = true,
    role: string = "user"
) -> User {
    User { name, age, active, role }
}

// Various ways to call
let user1 = create_user("Alice")
let user2 = create_user("Bob", 25)
let user3 = create_user("Charlie", 30, false)
let user4 = create_user("Dave", 35, true, "admin")
```

## Parameter Order Rules

### Required Before Optional

Required parameters must come before optional ones:

```home
// ✓ Correct - required first, then optional
fn func(required: i32, optional: i32 = 0) -> void { }

// ✗ Error - optional before required
fn func(optional: i32 = 0, required: i32) -> void { }
```

### All or Nothing for Positional

When calling with positional arguments, you must provide all arguments up to the one you want:

```home
fn config(
    host: string = "localhost",
    port: i32 = 8080,
    timeout: i32 = 30
) -> Config {
    Config { host, port, timeout }
}

// Must provide all preceding args
config()                          // All defaults
config("example.com")             // Custom host
config("example.com", 3000)       // Custom host and port
config("example.com", 3000, 60)   // All custom

// Can't skip middle parameter with positional args
// config("example.com", _, 60)   // Not allowed
```

## Calling Functions

### Positional Arguments

```home
fn draw_rect(
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 100,
    height: i32 = 100
) -> void {
    // Draw rectangle
}

draw_rect()                    // All defaults
draw_rect(10)                  // x=10, rest default
draw_rect(10, 20)              // x=10, y=20, rest default
draw_rect(10, 20, 200)         // x=10, y=20, width=200, height=100
draw_rect(10, 20, 200, 150)    // All specified
```

### With Named Arguments

Named arguments allow skipping parameters:

```home
// Skip middle parameters
draw_rect(x: 10, height: 200)  // x=10, y=0, width=100, height=200

// Any order with named args
draw_rect(height: 200, x: 10)  // Same as above

// Mix positional and named
draw_rect(10, 20, height: 200)  // x=10, y=20, width=100, height=200
```

## With Named Parameters

### Named-Only Parameters

Parameters after a `*` separator can only be passed by name:

```home
fn connect(
    host: string,
    port: i32 = 8080,
    *,  // Everything after this is named-only
    timeout: i32 = 30,
    retries: i32 = 3,
    ssl: bool = false
) -> Connection {
    // ...
}

// Must use names for timeout, retries, ssl
connect("localhost")
connect("localhost", 3000)
connect("localhost", timeout: 60)
connect("localhost", 3000, ssl: true, timeout: 60)

// Error - positional after named-only separator
// connect("localhost", 3000, 60)  // Not allowed
```

## Generic Functions

### Generic with Defaults

```home
fn create_vec<T>(
    capacity: usize = 10,
    fill_value: T = T::default()
) -> Vec<T> {
    let mut vec = Vec::with_capacity(capacity)
    for _ in 0..capacity {
        vec.push(fill_value.clone())
    }
    vec
}

let v1 = create_vec::<i32>()           // capacity=10, fill=0
let v2 = create_vec::<i32>(20)         // capacity=20, fill=0
let v3 = create_vec::<i32>(20, 42)     // capacity=20, fill=42
```

### Trait Bounds with Defaults

```home
fn sort<T: Ord>(
    items: &mut [T],
    reverse: bool = false
) -> void {
    if reverse {
        items.sort_by(|a, b| b.cmp(a))
    } else {
        items.sort()
    }
}

let mut nums = vec![3, 1, 4, 1, 5]
sort(&mut nums)              // Ascending
sort(&mut nums, true)        // Descending
sort(&mut nums, reverse: true)  // Named argument
```

## Best Practices

### 1. Sensible Defaults

Choose defaults that work for the common case:

```home
// Good - sensible defaults
fn read_file(
    path: string,
    encoding: string = "utf-8",
    buffer_size: usize = 4096
) -> Result<string> { }

// Avoid - arbitrary defaults
fn process(
    data: string,
    multiplier: i32 = 42  // Why 42?
) -> void { }
```

### 2. Document Defaults

```home
/// Connects to a database
/// 
/// # Parameters
/// * `host` - Database host
/// * `port` - Database port (default: 5432)
/// * `timeout` - Connection timeout in seconds (default: 30)
/// * `pool_size` - Connection pool size (default: 10)
fn connect_db(
    host: string,
    port: i32 = 5432,
    timeout: i32 = 30,
    pool_size: i32 = 10
) -> Connection { }
```

### 3. Use Named-Only for Clarity

Use named-only parameters for boolean flags and configuration:

```home
// Good - clear what each boolean means
fn copy_file(
    source: string,
    dest: string,
    *,
    overwrite: bool = false,
    preserve_metadata: bool = true,
    follow_symlinks: bool = false
) -> Result<()> { }

copy_file("a.txt", "b.txt", overwrite: true)

// Avoid - unclear boolean meanings
fn copy_file(
    source: string,
    dest: string,
    overwrite: bool = false,
    preserve: bool = true,
    follow: bool = false
) -> Result<()> { }

copy_file("a.txt", "b.txt", true, false, true)  // What do these mean?
```

### 4. Limit Number of Defaults

```home
// Good - focused function
fn create_button(
    text: string,
    width: i32 = 100,
    height: i32 = 30
) -> Button { }

// Avoid - too many parameters
fn create_widget(
    text: string = "",
    width: i32 = 100,
    height: i32 = 30,
    color: Color = Color::Blue,
    border: i32 = 1,
    padding: i32 = 5,
    margin: i32 = 0,
    font_size: i32 = 12,
    // ... 10 more parameters
) -> Widget { }  // Consider a builder pattern instead
```

### 5. Avoid Mutable Defaults

```home
// Avoid - mutable default can cause issues
fn process(items: Vec<i32> = vec![]) -> void {
    // Each call shares the same default vector!
}

// Better - use Option
fn process(items: Option<Vec<i32>> = None) -> void {
    let items = items.unwrap_or_else(|| vec![])
    // Now each call gets a fresh vector
}
```

## Common Patterns

### Configuration Functions

```home
fn start_server(
    port: i32 = 8080,
    *,
    workers: i32 = 4,
    max_connections: i32 = 1000,
    timeout: i32 = 30,
    debug: bool = false
) -> Server {
    Server::new()
        .port(port)
        .workers(workers)
        .max_connections(max_connections)
        .timeout(timeout)
        .debug(debug)
        .start()
}

// Easy to use with defaults
let server = start_server()

// Easy to customize specific options
let dev_server = start_server(3000, debug: true)
let prod_server = start_server(workers: 8, max_connections: 5000)
```

### Range Functions

```home
fn range(start: i32 = 0, end: i32, step: i32 = 1) -> Range {
    Range { start, end, step }
}

for i in range(10) {           // 0..10
    println("{}", i)
}

for i in range(5, 15) {        // 5..15
    println("{}", i)
}

for i in range(0, 20, 2) {     // 0, 2, 4, ..., 18
    println("{}", i)
}
```

### Formatting Functions

```home
fn format_number(
    num: f64,
    decimals: i32 = 2,
    *,
    thousands_sep: string = ",",
    decimal_point: string = "."
) -> string {
    // Format number with specified options
}

format_number(1234.5678)                    // "1,234.57"
format_number(1234.5678, 4)                 // "1,234.5678"
format_number(1234.5678, decimal_point: ",")  // "1,234,57"
```

## Examples

### HTTP Client

```home
fn get(
    url: string,
    *,
    timeout: i32 = 30,
    headers: HashMap<string, string> = HashMap::new(),
    follow_redirects: bool = true,
    max_redirects: i32 = 10
) -> Result<Response> {
    // Make HTTP GET request
}

// Simple usage
let response = get("https://api.example.com/users")?

// With custom timeout
let response = get("https://slow-api.com", timeout: 60)?

// With headers
let mut headers = HashMap::new()
headers.insert("Authorization", "Bearer token123")
let response = get("https://api.example.com/private", headers: headers)?
```

### Database Query

```home
fn query<T>(
    sql: string,
    *,
    params: Vec<any> = vec![],
    timeout: i32 = 30,
    readonly: bool = false
) -> Result<Vec<T>> {
    // Execute database query
}

// Simple query
let users = query::<User>("SELECT * FROM users")?

// With parameters
let users = query::<User>(
    "SELECT * FROM users WHERE age > ?",
    params: vec![18]
)?

// Read-only query
let count = query::<i32>(
    "SELECT COUNT(*) FROM users",
    readonly: true
)?
```

## See Also

- [Named Parameters](NAMED_PARAMETERS.md) - Named argument syntax
- [Functions](FUNCTIONS.md) - Function definitions
- [Variadic Functions](VARIADIC_FUNCTIONS.md) - Variable arguments
