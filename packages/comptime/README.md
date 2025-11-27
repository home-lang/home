# Home Compile-Time Evaluation

Powerful compile-time execution with type reflection, string operations, and array transformations.

## Overview

The comptime package provides sophisticated compile-time code execution, enabling metaprogramming, code generation, and zero-cost abstractions. Features type introspection, string manipulation, array operations, and a complete macro system.

## Features

### Type Reflection
- **Field introspection**: Query struct fields, names, types, offsets
- **Type queries**: Check type properties (numeric, aggregate, callable)
- **Generic support**: Works with type parameters and generic types
- **Size and alignment**: Query type metadata

### String Operations (16 operations)
- **Transformations**: concat, toUpper, toLower, trim, repeat, reverse
- **Queries**: length, contains, startsWith, endsWith, indexOf
- **Manipulation**: substring, replaceAll, split, join

### Array Operations (15 operations)
- **Access**: length, get, append, prepend, concat, slice
- **Functional**: map, filter, reduce
- **Predicates**: contains, indexOf, all, any
- **Aggregations**: sum, min, max

### Macro System
- **Built-in macros**: todo!, unreachable!, assert!, debug_assert!, unimplemented!
- **Custom macros**: Define your own compile-time transformations
- **AST manipulation**: Transform code at compile time
- **Expression evaluation**: Execute code during compilation

## Architecture

```
Comptime System
├── ComptimeEvaluator: Execute comptime blocks
│   ├── TypeReflection: Type introspection
│   ├── StringOps: String manipulation
│   └── ArrayOps: Array transformations
├── MacroExpander: Macro expansion
│   ├── Built-in macros
│   └── Custom macros
└── Environment: Variable bindings
```

## Usage

### Type Reflection

```zig
comptime {
    const T = Point;

    // Get field count
    const field_count = type.getFieldCount(T);  // 2

    // Get field names
    const fields = type.getFieldNames(T);  // ["x", "y"]

    // Check if field exists
    const has_x = type.hasField(T, "x");  // true

    // Get field info
    const x_field = type.getField(T, "x");
    // x_field = { name: "x", type: "i32", offset: 0 }

    // Type queries
    const is_num = type.isNumeric(i32);     // true
    const is_agg = type.isAggregate(Point); // true
    const kind = type.getKindName(T);       // "struct"
}
```

### String Operations

```zig
comptime {
    // Basic operations
    const hello = "Hello";
    const world = "World";
    const greeting = string.concat(hello, " ", world);  // "Hello World"
    const len = string.length(greeting);                // 11

    // Case conversion
    const upper = string.toUpper("hello");  // "HELLO"
    const lower = string.toLower("WORLD");  // "world"

    // Trimming
    const trimmed = string.trim("  hello  ");       // "hello"
    const start = string.trimStart("  hello");      // "hello"
    const end = string.trimEnd("hello  ");          // "hello"

    // Searching
    const contains = string.contains("hello world", "world");  // true
    const starts = string.startsWith("hello", "hel");          // true
    const ends = string.endsWith("hello", "lo");               // true
    const index = string.indexOf("hello world", "world");      // 6

    // Manipulation
    const sub = string.substring("hello", 1, 4);     // "ell"
    const replaced = string.replaceAll("hello hello", "hello", "hi");  // "hi hi"
    const parts = string.split("a,b,c", ",");        // ["a", "b", "c"]
    const joined = string.join(["a", "b", "c"], ",");  // "a,b,c"
    const repeated = string.repeat("ab", 3);         // "ababab"
    const reversed = string.reverse("hello");        // "olleh"
}
```

### Array Operations

```zig
comptime {
    const numbers = [1, 2, 3, 4, 5];

    // Basic operations
    const len = array.length(numbers);        // 5
    const first = array.get(numbers, 0);      // 1
    const with_6 = array.append(numbers, 6);  // [1, 2, 3, 4, 5, 6]
    const with_0 = array.prepend(numbers, 0); // [0, 1, 2, 3, 4, 5]

    // Slicing and concatenation
    const slice = array.slice(numbers, 1, 4);  // [2, 3, 4]
    const concat = array.concat(numbers, [6, 7, 8]);  // [1, 2, 3, 4, 5, 6, 7, 8]
    const reversed = array.reverse(numbers);   // [5, 4, 3, 2, 1]

    // Searching
    const has_3 = array.contains(numbers, 3);  // true
    const idx = array.indexOf(numbers, 4);     // 3

    // Functional programming
    const doubled = array.map(numbers, fn(x) { x * 2 });  // [2, 4, 6, 8, 10]
    const evens = array.filter(numbers, fn(x) { x % 2 == 0 });  // [2, 4]
    const sum = array.reduce(numbers, 0, fn(acc, x) { acc + x });  // 15

    // Predicates
    const all_pos = array.all(numbers, fn(x) { x > 0 });  // true
    const any_gt_4 = array.any(numbers, fn(x) { x > 4 }); // true

    // Aggregations
    const total = array.sum(numbers);  // 15
    const min = array.min(numbers);    // 1
    const max = array.max(numbers);    // 5
}
```

### Built-in Macros

```zig
// todo! - Mark unimplemented code
fn incomplete_feature() {
    todo!("implement authentication");
}
// Panics: "not yet implemented: implement authentication"

// unimplemented! - Alternative to todo!
fn future_work() {
    unimplemented!("planned for v2.0");
}
// Panics: "not yet implemented: planned for v2.0"

// unreachable! - Mark unreachable code paths
fn handle_status(code: i32) {
    if (code == 200) {
        return "OK";
    } else if (code == 404) {
        return "Not Found";
    } else {
        unreachable!("unexpected status code");
    }
}
// Panics if reached: "unreachable code: unexpected status code"

// assert! - Runtime assertions
fn divide(a: i32, b: i32): i32 {
    assert!(b != 0, "division by zero");
    return a / b;
}
// Panics if b == 0: "assertion failed: division by zero"

// debug_assert! - Debug-only assertions
fn complex_calculation(x: i32) {
    debug_assert!(x >= 0, "x must be non-negative");
    // ... complex logic
}
// Only checks in debug builds
```

### Custom Macros

```zig
// Define a custom macro
macro repeat($count: expr, $body: block) {
    comptime {
        var i = 0;
        while (i < $count) {
            $body
            i += 1;
        }
    }
}

// Use the macro
fn example() {
    repeat!(3, {
        print("Hello");
    });
    // Expands to:
    // print("Hello");
    // print("Hello");
    // print("Hello");
}
```

## API Reference

### TypeReflection

```zig
// Field operations
getFieldCount(type: Type): usize
getFieldNames(type: Type): [][]const u8
getField(type: Type, name: []const u8): FieldInfo
hasField(type: Type, name: []const u8): bool

// Type queries
isNumeric(type: Type): bool
isAggregate(type: Type): bool
isCallable(type: Type): bool
getKindName(type: Type): []const u8
getSize(type: Type): usize
getAlignment(type: Type): usize
```

### StringOps

```zig
// Transformations
concat(...parts: []const u8): []const u8
toUpper(s: []const u8): []const u8
toLower(s: []const u8): []const u8
trim(s: []const u8): []const u8
trimStart(s: []const u8): []const u8
trimEnd(s: []const u8): []const u8
repeat(s: []const u8, count: usize): []const u8
reverse(s: []const u8): []const u8

// Queries
length(s: []const u8): usize
contains(s: []const u8, substr: []const u8): bool
startsWith(s: []const u8, prefix: []const u8): bool
endsWith(s: []const u8, suffix: []const u8): bool
indexOf(s: []const u8, substr: []const u8): ?usize

// Manipulation
substring(s: []const u8, start: usize, end: usize): []const u8
replaceAll(s: []const u8, old: []const u8, new: []const u8): []const u8
split(s: []const u8, sep: []const u8): [][]const u8
join(parts: [][]const u8, sep: []const u8): []const u8
```

### ArrayOps

```zig
// Access
length(arr: []T): usize
get(arr: []T, index: usize): T
append(arr: []T, item: T): []T
prepend(arr: []T, item: T): []T
concat(a: []T, b: []T): []T
slice(arr: []T, start: usize, end: usize): []T
reverse(arr: []T): []T

// Searching
contains(arr: []T, item: T): bool
indexOf(arr: []T, item: T): ?usize

// Functional
map(arr: []T, f: fn(T): U): []U
filter(arr: []T, pred: fn(T): bool): []T
reduce(arr: []T, init: U, f: fn(U, T): U): U

// Predicates
all(arr: []T, pred: fn(T): bool): bool
any(arr: []T, pred: fn(T): bool): bool

// Aggregations
sum(arr: []T): T  // where T is numeric
min(arr: []T): T  // where T is comparable
max(arr: []T): T  // where T is comparable
```

### Macro Registration

```zig
// Built-in macros are pre-registered
const builtin_macros = [
    "todo!",
    "unimplemented!",
    "unreachable!",
    "assert!",
    "debug_assert!",
];

// Register custom macro
fn registerMacro(name: []const u8, expander: MacroExpander) void
```

## Real-World Examples

### Code Generation with Type Reflection

```zig
comptime fn generateGetters(T: type): []const u8 {
    var code = std.ArrayList(u8).init(allocator);

    const fields = type.getFieldNames(T);
    for (fields) |field_name| {
        const field = type.getField(T, field_name);

        // Generate getter method
        code.appendSlice(std.fmt.allocPrint(allocator,
            \\pub fn get_{s}(self: *{s}): {s} {{
            \\    return self.{s};
            \\}}
            \\
        , .{field_name, @typeName(T), field.type, field_name}));
    }

    return code.toOwnedSlice();
}

// Usage
struct User {
    id: i64,
    name: string,
    email: string,

    // Inject generated getters
    comptime {
        @embed(generateGetters(User));
    }
}
```

### String-Based Configuration

```zig
comptime {
    const config = """
        server.host=localhost
        server.port=3000
        db.url=postgres://localhost/mydb
    """;

    const lines = string.split(config, "\n");
    for (lines) |line| {
        const trimmed = string.trim(line);
        if (string.length(trimmed) == 0) continue;

        const parts = string.split(trimmed, "=");
        const key = string.trim(parts[0]);
        const value = string.trim(parts[1]);

        // Store in compile-time map
        config_map.put(key, value);
    }
}
```

### Compile-Time Data Processing

```zig
comptime {
    // Read CSV at compile time
    const csv_data = @embedFile("data.csv");
    const rows = string.split(csv_data, "\n");

    // Process data
    const numbers = array.map(rows, fn(row) {
        const parts = string.split(row, ",");
        return parseInt(parts[0]);
    });

    // Calculate statistics
    const total = array.sum(numbers);
    const avg = total / array.length(numbers);
    const min = array.min(numbers);
    const max = array.max(numbers);

    // Export as constants
    pub const DATA_SUM = total;
    pub const DATA_AVG = avg;
    pub const DATA_MIN = min;
    pub const DATA_MAX = max;
}
```

## Performance

### Compile-Time Execution
- **Zero runtime cost**: All comptime code executes during compilation
- **Caching**: Results are memoized and reused across compilation units
- **Constant folding**: Complex expressions reduced to constants

### Memory Usage
- **Compile-time only**: No runtime memory overhead
- **Result caching**: Efficient storage of computed values
- **Incremental**: Only recomputes when dependencies change

## Testing

```bash
# Run comptime tests
zig test packages/comptime/tests/comptime_test.zig

# Run type reflection tests
zig test packages/comptime/tests/reflection_test.zig

# Run operations tests
zig test packages/comptime/tests/operations_test.zig

# Run macro tests
zig test packages/comptime/tests/macro_test.zig
```

## Integration

The comptime package integrates throughout the compiler:

```zig
const parser = @import("parser");
const comptime_pkg = @import("comptime");

// Parse comptime block
if (token.type == .Comptime) {
    const block = try parser.parseBlock();

    // Evaluate at compile time
    var evaluator = comptime_pkg.ComptimeEvaluator.init(allocator);
    const result = try evaluator.evaluate(block);

    // Inject result into AST
    try ast.statements.append(result);
}
```

## Best Practices

### 1. Use Type Reflection for Generic Code

```zig
comptime fn printStruct(value: anytype) void {
    const T = @TypeOf(value);
    const fields = type.getFieldNames(T);

    print("{s} {{\n", .{@typeName(T)});
    for (fields) |field_name| {
        const field_value = @field(value, field_name);
        print("  {s}: {}\n", .{field_name, field_value});
    }
    print("}\n", .{});
}
```

### 2. Leverage String Operations for Code Gen

```zig
comptime fn generateEnumMatch(E: type): []const u8 {
    const variants = type.getFieldNames(E);

    var code = string.concat("match value {\n");
    for (variants) |variant| {
        const line = string.concat(
            "    .",
            variant,
            " => \"",
            string.toLower(variant),
            "\",\n"
        );
        code = string.concat(code, line);
    }
    code = string.concat(code, "}");

    return code;
}
```

### 3. Use Built-in Macros for Safety

```zig
fn safe_divide(a: i32, b: i32): i32 {
    assert!(b != 0, "cannot divide by zero");
    return a / b;
}

fn handle_request(req: Request): Response {
    if (req.method == .GET) {
        return handle_get(req);
    } else if (req.method == .POST) {
        return handle_post(req);
    } else {
        unreachable!("unsupported HTTP method");
    }
}
```

### 4. Combine Operations for Complex Transformations

```zig
comptime {
    // Load, process, and transform data at compile time
    const raw_data = @embedFile("config.txt");
    const lines = string.split(raw_data, "\n");
    const non_empty = array.filter(lines, fn(line) {
        return string.length(string.trim(line)) > 0;
    });
    const uppercased = array.map(non_empty, fn(line) {
        return string.toUpper(line);
    });

    pub const PROCESSED_CONFIG = uppercased;
}
```

## License

Part of the Home programming language project.
