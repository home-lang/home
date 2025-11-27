# Home Macro System

Powerful compile-time code generation with built-in macros and custom macro definitions.

## Overview

The macro system provides hygienic macro expansion with pattern matching, AST transformation, and compile-time code generation. Includes essential built-in macros (todo!, assert!, unreachable!) and supports custom user-defined macros.

## Features

### Built-in Macros
- **todo!**: Mark unimplemented code with optional message
- **unimplemented!**: Alternative to todo! for clarity
- **unreachable!**: Mark code paths that should never execute
- **assert!**: Runtime assertions with custom messages
- **debug_assert!**: Debug-only assertions (zero cost in release builds)

### Custom Macros
- **Pattern matching**: Match against AST patterns
- **AST transformation**: Generate and manipulate code structures
- **Hygienic expansion**: Prevents variable capture and naming conflicts
- **Compile-time evaluation**: Executes during compilation

### Macro System Features
- **Macro registration**: Register custom macros with the compiler
- **Expansion tracking**: Maintain expansion history for debugging
- **Error reporting**: Clear error messages for macro expansion failures
- **Recursive expansion**: Support for macros that expand to other macros

## Architecture

```
MacroSystem
├── BuiltinMacros: Pre-registered macros
│   ├── todo!
│   ├── unimplemented!
│   ├── unreachable!
│   ├── assert!
│   └── debug_assert!
├── CustomMacros: User-defined macros
├── MacroExpander: AST transformation
└── PatternMatcher: Pattern recognition
```

## Built-in Macros

### todo!

Mark code that needs to be implemented:

```zig
fn authenticate_user(username: string, password: string): Result<User> {
    todo!("implement OAuth2 authentication");
}

// When executed:
// panic: not yet implemented: implement OAuth2 authentication
```

**With optional message:**
```zig
fn complex_algorithm() {
    todo!();  // panic: not yet implemented
}
```

**Expansion:**
```zig
// todo!("message") expands to:
panic("not yet implemented: message")
```

### unimplemented!

Semantic alias for todo!, often used for clarity:

```zig
fn handle_websocket() {
    unimplemented!("WebSocket support planned for v2.0");
}

// panic: not yet implemented: WebSocket support planned for v2.0
```

### unreachable!

Mark code paths that should never be reached:

```zig
fn handle_status(code: i32): string {
    if (code == 200) {
        return "OK";
    } else if (code == 404) {
        return "Not Found";
    } else if (code == 500) {
        return "Server Error";
    } else {
        unreachable!("unexpected HTTP status code");
    }
}

// If reached: panic: unreachable code: unexpected HTTP status code
```

**Expansion:**
```zig
// unreachable!("message") expands to:
panic("unreachable code: message")
```

### assert!

Runtime assertions with custom error messages:

```zig
fn divide(a: i32, b: i32): i32 {
    assert!(b != 0, "division by zero");
    return a / b;
}

fn process_array(items: []i32) {
    assert!(items.len > 0, "array must not be empty");
    // ... process items
}

// If assertion fails:
// panic: assertion failed: division by zero
```

**Expansion:**
```zig
// assert!(condition, "message") expands to:
if (!(condition)) {
    panic("assertion failed: message");
}
```

### debug_assert!

Debug-only assertions (compiled out in release builds):

```zig
fn complex_calculation(x: i32, y: i32): i32 {
    debug_assert!(x >= 0, "x must be non-negative");
    debug_assert!(y >= 0, "y must be non-negative");

    // ... complex computation
    const result = x * y + 42;

    debug_assert!(result > 0, "result must be positive");
    return result;
}

// In debug builds: Checks assertions
// In release builds: Compiles to no-op (zero overhead)
```

**Expansion (debug):**
```zig
if (!(condition)) {
    panic("assertion failed: message");
}
```

**Expansion (release):**
```zig
// Compiled out entirely
```

## Custom Macros

### Defining Macros

```zig
// Define a simple macro
macro log_entry($level: ident, $msg: expr) {
    print("[{s}] {s}\n", .{stringify!($level), $msg});
}

// Usage
fn example() {
    log_entry!(INFO, "Server started");
    log_entry!(ERROR, "Connection failed");
}

// Expands to:
// print("[{s}] {s}\n", .{"INFO", "Server started"});
// print("[{s}] {s}\n", .{"ERROR", "Connection failed"});
```

### Pattern Matching

```zig
// Match specific patterns
macro unwrap_or($opt: expr, $default: expr) {
    match $opt {
        Some(value) => value,
        None => $default,
    }
}

// Usage
const value = unwrap_or!(maybe_number, 0);

// Expands to:
// match maybe_number {
//     Some(value) => value,
//     None => 0,
// }
```

### AST Generation

```zig
// Generate complex AST structures
macro derive_debug($struct_name: ident) {
    comptime {
        const fields = type.getFieldNames($struct_name);

        // Generate debug impl
        impl Debug for $struct_name {
            fn debug(self) -> string {
                var result = stringify!($struct_name) ++ " { ";

                @for (field in fields) {
                    result = result ++ field ++ ": " ++ self.@field ++ ", ";
                }

                result = result ++ "}";
                return result;
            }
        }
    }
}

// Usage
struct Point {
    x: i32,
    y: i32,
}

derive_debug!(Point);
```

### Repetition

```zig
// Repeat patterns
macro vec!($($elem: expr),*) {
    {
        var v = Vec.init();
        $(v.push($elem);)*
        v
    }
}

// Usage
const numbers = vec!(1, 2, 3, 4, 5);

// Expands to:
// {
//     var v = Vec.init();
//     v.push(1);
//     v.push(2);
//     v.push(3);
//     v.push(4);
//     v.push(5);
//     v
// }
```

## API Reference

### MacroSystem

```zig
// Initialize macro system
fn init(allocator: Allocator): MacroSystem

// Register built-in macros
fn initBuiltinMacros(self: *MacroSystem): !void

// Register custom macro
fn registerMacro(
    self: *MacroSystem,
    name: []const u8,
    expander: MacroExpander,
): !void

// Expand macro invocation
fn expandMacro(
    self: *MacroSystem,
    name: []const u8,
    args: []const ast.Node,
): !ast.Node

// Check if macro is registered
fn hasMacro(self: *MacroSystem, name: []const u8): bool
```

### MacroExpander

```zig
pub const MacroExpander = struct {
    expand: *const fn (
        allocator: Allocator,
        args: []const ast.Node,
    ) anyerror!ast.Node,
};
```

### Built-in Macro Expanders

```zig
// todo! macro
fn expandTodo(allocator: Allocator, args: []const ast.Node) !ast.Node

// unreachable! macro
fn expandUnreachable(allocator: Allocator, args: []const ast.Node) !ast.Node

// assert! macro
fn expandAssert(allocator: Allocator, args: []const ast.Node) !ast.Node

// debug_assert! macro
fn expandDebugAssert(allocator: Allocator, args: []const ast.Node) !ast.Node

// unimplemented! macro (alias for todo!)
fn expandUnimplemented(allocator: Allocator, args: []const ast.Node) !ast.Node
```

## Real-World Examples

### Error Handling with Assertions

```zig
fn parse_config(path: string): Config {
    const file = fs.open(path) catch {
        unreachable!("config file must exist");
    };

    const content = file.read_all();
    assert!(content.len > 0, "config file cannot be empty");

    const config = parse_toml(content);
    debug_assert!(config.validate(), "config validation failed");

    return config;
}
```

### Progressive Feature Development

```zig
struct Database {
    fn query(self, sql: string): Result<Rows> {
        // Implemented
        return self.execute(sql);
    }

    fn transaction(self, callback: fn() -> Result<void>): Result<void> {
        todo!("implement transaction support");
    }

    fn migrate(self, version: i32): Result<void> {
        unimplemented!("database migrations coming in v1.5");
    }
}
```

### Enum Match Validation

```zig
enum Status {
    Pending,
    Processing,
    Complete,
    Failed,
}

fn status_color(status: Status): string {
    match status {
        .Pending => "yellow",
        .Processing => "blue",
        .Complete => "green",
        .Failed => "red",
        // If we forgot a variant, compiler error
    }
}

fn handle_unknown_status(code: i32): Status {
    match code {
        0 => .Pending,
        1 => .Processing,
        2 => .Complete,
        3 => .Failed,
        _ => unreachable!("invalid status code"),
    }
}
```

### Debug Build Validation

```zig
fn binary_search(arr: []i32, target: i32): ?usize {
    debug_assert!(is_sorted(arr), "array must be sorted for binary search");

    var left: usize = 0;
    var right: usize = arr.len;

    while (left < right) {
        const mid = left + (right - left) / 2;

        debug_assert!(mid < arr.len, "mid index out of bounds");

        if (arr[mid] == target) {
            return mid;
        } else if (arr[mid] < target) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    return null;
}
```

### Custom Macro: Lazy Evaluation

```zig
// Define lazy evaluation macro
macro lazy!($expr: expr) {
    struct {
        evaluated: bool = false,
        value: @TypeOf($expr) = undefined,

        fn get(self: *@This()): @TypeOf($expr) {
            if (!self.evaluated) {
                self.value = $expr;
                self.evaluated = true;
            }
            return self.value;
        }
    }
}

// Usage
fn expensive_computation(): i32 {
    print("Computing...\n", .{});
    return 42;
}

const lazy_value = lazy!(expensive_computation());

// First access: prints "Computing..." and returns 42
const x = lazy_value.get();

// Second access: returns cached 42, no print
const y = lazy_value.get();
```

## Macro Hygiene

The macro system ensures hygienic expansion to prevent variable capture:

```zig
macro swap!($a: ident, $b: ident) {
    {
        const temp = $a;
        $a = $b;
        $b = temp;
    }
}

fn example() {
    var x = 1;
    var y = 2;
    var temp = 999;  // Won't conflict with macro's temp

    swap!(x, y);

    // x = 2, y = 1, temp = 999
    assert!(x == 2);
    assert!(y == 1);
    assert!(temp == 999);  // Preserved!
}
```

## Testing

```bash
# Run macro system tests
zig test packages/macros/tests/macros_test.zig

# Run built-in macro tests
zig test packages/macros/tests/builtin_test.zig

# Run custom macro tests
zig test packages/macros/tests/custom_test.zig

# Run expansion tests
zig test packages/macros/tests/expansion_test.zig
```

## Integration

The macro system integrates with the parser:

```zig
const parser = @import("parser");
const macros = @import("macros");

var macro_system = macros.MacroSystem.init(allocator);
try macro_system.initBuiltinMacros();

// Parse macro invocation
if (token.type == .Identifier and parser.peekToken().type == .Bang) {
    const macro_name = token.lexeme;
    try parser.expect(.Bang);

    // Parse macro arguments
    const args = try parser.parseMacroArgs();

    // Expand macro
    const expanded = try macro_system.expandMacro(macro_name, args);

    // Replace invocation with expanded AST
    return expanded;
}
```

## Best Practices

### 1. Use Built-in Macros for Common Patterns

```zig
// Good: Clear intent
fn divide(a: i32, b: i32): i32 {
    assert!(b != 0, "division by zero");
    return a / b;
}

// Bad: Manual check
fn divide_bad(a: i32, b: i32): i32 {
    if (b == 0) {
        panic("division by zero");
    }
    return a / b;
}
```

### 2. Prefer debug_assert! for Internal Invariants

```zig
// Good: Zero cost in release
fn internal_helper(idx: usize, len: usize) {
    debug_assert!(idx < len, "index out of bounds");
    // ... implementation
}

// Bad: Always pays runtime cost
fn internal_helper_bad(idx: usize, len: usize) {
    assert!(idx < len, "index out of bounds");
    // ... implementation
}
```

### 3. Use todo! During Development

```zig
struct ApiClient {
    fn get(self, path: string): Result<Response> {
        todo!("implement GET request");
    }

    fn post(self, path: string, body: []const u8): Result<Response> {
        todo!("implement POST request");
    }

    // ... implement methods incrementally
}
```

### 4. Mark Unreachable Code Paths Explicitly

```zig
// Good: Documents intent
fn handle_event(event: Event): void {
    match event.type {
        .Click => handle_click(event),
        .Hover => handle_hover(event),
        .Scroll => handle_scroll(event),
        else => unreachable!("unsupported event type"),
    }
}

// Bad: Silent failure
fn handle_event_bad(event: Event): void {
    match event.type {
        .Click => handle_click(event),
        .Hover => handle_hover(event),
        .Scroll => handle_scroll(event),
        else => {},  // Silently ignored
    }
}
```

## Performance

### Compile-Time Overhead
- **Macro expansion**: < 1ms per invocation
- **Pattern matching**: Constant time for simple patterns
- **AST generation**: Proportional to generated code size

### Runtime Performance
- **assert!**: Small runtime cost (branch + panic)
- **debug_assert!**: Zero cost in release builds
- **todo!/unreachable!**: Immediate panic, no overhead before call

### Memory Usage
- **Macro registry**: ~100 bytes per registered macro
- **Expansion cache**: Memoizes expanded macros
- **AST nodes**: Standard AST node overhead

## Comparison with Other Languages

### Rust
```rust
// Rust
todo!("implement feature");
unreachable!("impossible state");
assert!(x > 0, "x must be positive");
debug_assert!(idx < len);
```

### Home (this package)
```zig
// Home - identical syntax!
todo!("implement feature");
unreachable!("impossible state");
assert!(x > 0, "x must be positive");
debug_assert!(idx < len);
```

## License

Part of the Home programming language project.
