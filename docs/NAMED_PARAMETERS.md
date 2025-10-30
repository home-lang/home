# Named Parameters in Home

Named parameters allow you to pass arguments to functions by parameter name rather than position, improving code clarity and flexibility.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Benefits](#benefits)
- [Mixing Positional and Named](#mixing-positional-and-named)
- [Named-Only Parameters](#named-only-parameters)
- [With Default Parameters](#with-default-parameters)
- [Best Practices](#best-practices)

## Basic Syntax

### Calling with Named Arguments

```home
fn create_rect(x: i32, y: i32, width: i32, height: i32) -> Rect {
    Rect { x, y, width, height }
}

// Positional arguments
let r1 = create_rect(10, 20, 100, 50)

// Named arguments
let r2 = create_rect(x: 10, y: 20, width: 100, height: 50)

// Named arguments in any order
let r3 = create_rect(width: 100, height: 50, x: 10, y: 20)
```

### Clarity for Boolean Flags

```home
fn copy_file(source: string, dest: string, overwrite: bool, preserve_metadata: bool) -> Result<()> {
    // ...
}

// Without named arguments - unclear
copy_file("a.txt", "b.txt", true, false)  // What do these booleans mean?

// With named arguments - crystal clear
copy_file(
    source: "a.txt",
    dest: "b.txt",
    overwrite: true,
    preserve_metadata: false
)
```

## Benefits

### 1. Self-Documenting Code

```home
// Hard to understand
connect("localhost", 5432, 30, 10, true, false)

// Self-documenting
connect(
    host: "localhost",
    port: 5432,
    timeout: 30,
    pool_size: 10,
    ssl: true,
    auto_reconnect: false
)
```

### 2. Skip Optional Parameters

```home
fn draw_text(
    text: string,
    x: i32 = 0,
    y: i32 = 0,
    size: i32 = 12,
    color: Color = Color::Black,
    bold: bool = false,
    italic: bool = false
) -> void {
    // ...
}

// Only set specific parameters
draw_text("Hello", x: 100, y: 200, bold: true)

// Without named args, you'd need:
draw_text("Hello", 100, 200, 12, Color::Black, true, false)
```

### 3. Prevent Argument Order Mistakes

```home
// Easy to swap arguments
send_email("user@example.com", "admin@example.com", "Subject", "Body")

// Named args prevent mistakes
send_email(
    from: "admin@example.com",
    to: "user@example.com",
    subject: "Subject",
    body: "Body"
)
```

## Mixing Positional and Named

### Rules for Mixing

1. Positional arguments must come first
2. Named arguments can follow in any order
3. Cannot use positional after named

```home
fn configure(host: string, port: i32, timeout: i32, retries: i32) -> Config {
    Config { host, port, timeout, retries }
}

// ✓ Valid - positional then named
configure("localhost", 8080, timeout: 30, retries: 3)
configure("localhost", 8080, retries: 3, timeout: 30)

// ✓ Valid - all positional
configure("localhost", 8080, 30, 3)

// ✓ Valid - all named
configure(host: "localhost", port: 8080, timeout: 30, retries: 3)

// ✗ Invalid - positional after named
configure(host: "localhost", 8080, 30, 3)
```

## Named-Only Parameters

### Separator Syntax

Use `*` to mark parameters as named-only:

```home
fn connect(
    host: string,
    port: i32,
    *,  // Everything after this is named-only
    timeout: i32 = 30,
    ssl: bool = false,
    verify_cert: bool = true
) -> Connection {
    // ...
}

// ✓ Valid
connect("localhost", 8080)
connect("localhost", 8080, timeout: 60)
connect("localhost", 8080, ssl: true, verify_cert: false)

// ✗ Invalid - can't pass named-only params positionally
connect("localhost", 8080, 60, true, false)
```

### Why Use Named-Only?

1. **Prevent mistakes** - Force explicit parameter names
2. **Future-proof** - Can add parameters without breaking calls
3. **Clarity** - Make boolean/config parameters obvious

```home
// Good - flags must be named
fn process_data(
    data: string,
    *,
    validate: bool = true,
    transform: bool = true,
    cache: bool = false
) -> Result<Data> {
    // ...
}

process_data(data, validate: false, cache: true)  // Clear intent
```

## With Default Parameters

### Powerful Combination

Named arguments work seamlessly with defaults:

```home
fn create_window(
    title: string,
    width: i32 = 800,
    height: i32 = 600,
    *,
    resizable: bool = true,
    fullscreen: bool = false,
    vsync: bool = true,
    msaa: i32 = 4
) -> Window {
    // ...
}

// Use defaults for most, customize specific ones
create_window("My App", fullscreen: true)
create_window("My App", width: 1920, height: 1080, vsync: false)
create_window("My App", msaa: 8, resizable: false)
```

### Skip Middle Parameters

```home
fn log(
    message: string,
    level: LogLevel = LogLevel::Info,
    timestamp: bool = true,
    color: bool = true,
    file: string = "app.log"
) -> void {
    // ...
}

// Skip middle parameters
log("Error occurred", level: LogLevel::Error, file: "errors.log")
log("Debug info", color: false)
```

## Best Practices

### 1. Use for Configuration

```home
// Good - configuration with named args
fn start_server(
    *,
    port: i32 = 8080,
    workers: i32 = 4,
    max_connections: i32 = 1000,
    timeout: i32 = 30,
    debug: bool = false
) -> Server {
    // ...
}

start_server(port: 3000, debug: true)
```

### 2. Use for Boolean Flags

```home
// Good - clear what each flag does
copy_file(
    "source.txt",
    "dest.txt",
    overwrite: true,
    preserve_metadata: true,
    follow_symlinks: false
)

// Avoid - unclear positional booleans
copy_file("source.txt", "dest.txt", true, true, false)
```

### 3. Use for Optional Parameters

```home
// Good - only specify what you need
http_get(
    "https://api.example.com/users",
    timeout: 60,
    headers: custom_headers
)

// Avoid - many None/default values
http_get("https://api.example.com/users", None, None, Some(60), Some(custom_headers), None)
```

### 4. Consistent Naming

```home
// Good - consistent parameter names across similar functions
fn read_file(path: string, encoding: string = "utf-8") -> Result<string> { }
fn write_file(path: string, content: string, encoding: string = "utf-8") -> Result<()> { }

// Both use 'encoding' with same meaning
let content = read_file("data.txt", encoding: "latin1")?
write_file("output.txt", content, encoding: "latin1")?
```

### 5. Group Related Parameters

```home
// Good - logical grouping
fn create_button(
    text: string,
    *,
    // Size parameters
    width: i32 = 100,
    height: i32 = 30,
    // Style parameters
    color: Color = Color::Blue,
    border_width: i32 = 1,
    // Behavior parameters
    enabled: bool = true,
    visible: bool = true
) -> Button {
    // ...
}
```

## Common Patterns

### Builder-Style Functions

```home
fn query_builder(
    table: string,
    *,
    columns: Vec<string> = vec!["*"],
    where_clause: Option<string> = None,
    order_by: Option<string> = None,
    limit: Option<i32> = None,
    offset: Option<i32> = None
) -> Query {
    // ...
}

let query = query_builder(
    "users",
    columns: vec!["id", "name", "email"],
    where_clause: Some("age > 18"),
    order_by: Some("name ASC"),
    limit: Some(10)
)
```

### HTTP Requests

```home
fn http_request(
    method: string,
    url: string,
    *,
    headers: HashMap<string, string> = HashMap::new(),
    body: Option<string> = None,
    timeout: i32 = 30,
    follow_redirects: bool = true,
    verify_ssl: bool = true
) -> Result<Response> {
    // ...
}

http_request(
    "POST",
    "https://api.example.com/users",
    body: Some(json_data),
    timeout: 60
)
```

### Database Connections

```home
fn connect_db(
    *,
    host: string = "localhost",
    port: i32 = 5432,
    database: string,
    username: string,
    password: string,
    pool_size: i32 = 10,
    timeout: i32 = 30,
    ssl: bool = false
) -> Result<Connection> {
    // ...
}

connect_db(
    database: "myapp",
    username: "admin",
    password: "secret",
    pool_size: 20,
    ssl: true
)
```

## Advanced Usage

### With Generics

```home
fn create_cache<K, V>(
    *,
    capacity: usize = 100,
    ttl: i32 = 3600,
    eviction_policy: EvictionPolicy = EvictionPolicy::LRU
) -> Cache<K, V> {
    // ...
}

let cache = create_cache::<string, User>(
    capacity: 1000,
    ttl: 7200
)
```

### With Trait Bounds

```home
fn sort_by<T, F>(
    items: &mut [T],
    compare: F,
    *,
    reverse: bool = false,
    stable: bool = true
) -> void
where
    F: Fn(&T, &T) -> Ordering
{
    // ...
}

sort_by(&mut items, |a, b| a.name.cmp(&b.name), reverse: true)
```

### Forwarding Named Arguments

```home
fn wrapper_function(
    data: string,
    *,
    timeout: i32 = 30,
    retries: i32 = 3
) -> Result<()> {
    // Forward named arguments
    inner_function(
        data,
        timeout: timeout,
        retries: retries
    )
}
```

## Examples

### Configuration Function

```home
fn configure_app(
    *,
    log_level: LogLevel = LogLevel::Info,
    log_file: string = "app.log",
    port: i32 = 8080,
    workers: i32 = 4,
    database_url: string,
    cache_size: usize = 100,
    debug: bool = false
) -> AppConfig {
    AppConfig {
        log_level,
        log_file,
        port,
        workers,
        database_url,
        cache_size,
        debug,
    }
}

// Easy to see what's being configured
let config = configure_app(
    database_url: "postgres://localhost/myapp",
    port: 3000,
    debug: true,
    cache_size: 1000
)
```

### Graphics Function

```home
fn draw_circle(
    x: f64,
    y: f64,
    radius: f64,
    *,
    fill_color: Color = Color::Black,
    stroke_color: Color = Color::Black,
    stroke_width: f64 = 1.0,
    alpha: f64 = 1.0
) -> void {
    // ...
}

draw_circle(100.0, 100.0, 50.0, fill_color: Color::Red, alpha: 0.5)
```

### Test Assertion

```home
fn assert_response(
    response: Response,
    *,
    status: i32 = 200,
    content_type: string = "application/json",
    contains: Option<string> = None,
    headers: HashMap<string, string> = HashMap::new()
) -> void {
    // ...
}

assert_response(
    response,
    status: 201,
    contains: Some("success"),
    headers: hashmap!{"X-Custom" => "value"}
)
```

## See Also

- [Default Parameters](DEFAULT_PARAMETERS.md) - Parameter defaults
- [Functions](FUNCTIONS.md) - Function definitions
- [Variadic Functions](VARIADIC_FUNCTIONS.md) - Variable arguments
