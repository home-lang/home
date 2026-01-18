# Compile-Time Evaluation

Home supports compile-time evaluation with the `comptime` keyword, enabling powerful metaprogramming and zero-cost abstractions.

## Comptime Basics

### Comptime Expressions

Evaluate expressions at compile time:

```home
fn main() {
  // Computed at compile time
  let a: int = comptime 10 + 20      // 30
  let b: int = comptime 5 * 6        // 30
  let c: int = comptime 100 - 25     // 75
  let d: int = comptime 50 / 2       // 25

  // Nested comptime expressions
  let nested: int = comptime (3 + 7) * (4 - 2)  // 20

  // Boolean comptime
  let is_true: bool = comptime 5 > 3   // true
  let is_false: bool = comptime 2 > 10 // false
}
```

### Mixing Comptime and Runtime

```home
fn main() {
  let comptime_val: int = comptime 30
  let runtime_val: int = 42
  let mixed: int = comptime_val + runtime_val  // 72

  print(mixed)
}
```

## Comptime Functions

Functions that execute entirely at compile time:

```home
comptime fn factorial(n: int): int {
  if (n <= 1) {
    return 1
  }
  return n * factorial(n - 1)
}

// Computed at compile time
const FACT_5 = factorial(5)    // 120
const FACT_10 = factorial(10)  // 3628800
```

### Comptime Fibonacci

```home
comptime fn fib(n: int): int {
  if (n <= 1) {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

const FIB_20 = fib(20)  // 6765

fn main() {
  // No runtime computation - value is embedded
  print("Fib(20) = {FIB_20}")
}
```

## Compile-Time Type Information

### Type Size

```home
comptime fn size_of<T>(): int {
  @sizeOf(T)
}

const INT_SIZE = size_of<int>()      // 8 (on 64-bit)
const BOOL_SIZE = size_of<bool>()    // 1
```

### Type Alignment

```home
comptime fn align_of<T>(): int {
  @alignOf(T)
}

const INT_ALIGN = align_of<int>()    // 8
```

## Conditional Compilation

### Comptime If

```home
fn process<T>(value: T) {
  comptime if (@typeInfo(T).is_integer) {
    // Only compiled for integer types
    print("Integer: {value}")
  } else if (@typeInfo(T).is_float) {
    // Only compiled for float types
    print("Float: {value}")
  } else {
    // Fallback
    print("Other: {value}")
  }
}
```

### Feature Flags

```home
const DEBUG = comptime @import("config").debug

fn log(msg: string) {
  comptime if (DEBUG) {
    print("[DEBUG] {msg}")
  }
  // In release builds, this function is empty
}
```

## Comptime String Operations

```home
comptime fn make_getter_name(field: string): string {
  "get_" + field
}

struct User {
  name: string,
  age: int
}

impl User {
  // Function name computed at compile time
  fn @(make_getter_name("name"))(self): string {
    self.name
  }
}
```

## Array and Buffer Operations

### Compile-Time Arrays

```home
comptime fn generate_powers_of_2(n: int): [n]int {
  let mut arr: [n]int
  for (i in 0..n) {
    arr[i] = 1 << i
  }
  return arr
}

const POWERS = generate_powers_of_2(8)  // [1, 2, 4, 8, 16, 32, 64, 128]
```

### Lookup Tables

```home
comptime fn generate_sin_table(size: int): [size]f64 {
  let mut table: [size]f64
  for (i in 0..size) {
    table[i] = @sin((i as f64) * 2.0 * 3.14159 / (size as f64))
  }
  return table
}

const SIN_TABLE = generate_sin_table(256)

fn fast_sin(angle: f64): f64 {
  let index = ((angle / (2.0 * 3.14159)) * 256.0) as int % 256
  SIN_TABLE[index]
}
```

## Generic Programming

### Type Constraints at Comptime

```home
fn add<T>(a: T, b: T): T {
  comptime if (!@typeInfo(T).is_numeric) {
    @compileError("add requires numeric type")
  }
  return a + b
}
```

### Comptime Type Selection

```home
comptime fn select_type<T>(): type {
  if (@sizeOf(T) <= 4) {
    return i32
  } else {
    return i64
  }
}

fn store<T>(value: T) {
  type StorageType = select_type<T>()
  let storage: StorageType = value as StorageType
}
```

## Built-In Macros

Home provides several built-in macros for common operations:

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

### unimplemented!

Alias for todo!:

```home
fn future_work() {
  unimplemented!("planned for v2.0")
}
```

## Compile-Time Validation

### Input Validation

```home
comptime fn validate_config(config: Config) {
  if (config.max_connections <= 0) {
    @compileError("max_connections must be positive")
  }
  if (config.port < 1024 && !config.allow_privileged) {
    @compileError("privileged port requires allow_privileged flag")
  }
}

const CONFIG = Config {
  max_connections: 100,
  port: 8080,
  allow_privileged: false
}

comptime {
  validate_config(CONFIG)
}
```

### Schema Validation

```home
comptime fn validate_struct<T>() {
  const info = @typeInfo(T)

  for (field in info.fields) {
    if (field.name.starts_with("_")) {
      @compileError("Fields cannot start with underscore: " + field.name)
    }
  }
}

struct User {
  name: string,
  email: string
}

comptime {
  validate_struct<User>()
}
```

## Performance Benefits

Comptime evaluation provides:

1. **Zero runtime cost** - Computed values are embedded in the binary
2. **Smaller binaries** - Dead code from comptime conditionals is eliminated
3. **Better optimizations** - Compiler has more information
4. **Catch errors early** - Validation happens at compile time

```home
// Lookup table is computed once at compile time
const CRC_TABLE = comptime generate_crc_table()

// At runtime, just table lookups - no computation
fn crc32(data: []u8): u32 {
  let mut crc: u32 = 0xFFFFFFFF
  for (byte in data) {
    let index = ((crc ^ byte) & 0xFF) as usize
    crc = (crc >> 8) ^ CRC_TABLE[index]
  }
  return crc ^ 0xFFFFFFFF
}
```

## Next Steps

- [Traits](/guide/traits) - Compile-time trait resolution
- [Generics](/guide/functions#generic-functions) - Type-safe generic programming
- [Standard Library](/reference/stdlib) - Comptime utilities
