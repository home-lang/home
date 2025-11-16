## Variadic Functions in Home

Variadic functions accept a variable number of arguments, enabling flexible APIs and utility functions. Home supports both type-safe variadic parameters and spread syntax.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Variadic Parameters](#variadic-parameters)
- [Spread Operator](#spread-operator)
- [Type Safety](#type-safety)
- [Built-in Variadic Functions](#built-in-variadic-functions)
- [Generic Variadic Functions](#generic-variadic-functions)
- [Best Practices](#best-practices)

## Basic Syntax

### Defining Variadic Functions

```home
// Variadic parameter with ...T syntax
fn sum(numbers: ...i32): i32 {
    let total = 0
    for num in numbers {
        total += num
    }
    total
}

// Call with any number of arguments
let result = sum(1, 2, 3, 4, 5)  // 15
let result2 = sum(10, 20)         // 30
let result3 = sum()               // 0
```

### Mixed Parameters

```home
// Regular parameters followed by variadic
fn format(template: string, ...args: any): string {
    // Format string with arguments
    template.format(args)
}

let msg = format("Hello, {}! You have {} messages", "Alice", 5)
```

## Variadic Parameters

### Syntax

```home
// Type-safe variadic parameter
fn print_all(...items: string): void {
    for item in items {
        println(item)
    }
}

// Generic variadic parameter
fn max<T: Ord>(...values: T): T {
    let mut maximum = values[0]
    for value in values[1..] {
        if value > maximum {
            maximum = value
        }
    }
    maximum
}
```

### Accessing Variadic Arguments

Variadic parameters are treated as slices within the function body:

```home
fn describe(...items: string): void {
    println("Received {} items", items.len())
    
    for (i, item) in items.iter().enumerate() {
        println("  [{}]: {}", i, item)
    }
}

describe("apple", "banana", "cherry")
// Output:
// Received 3 items
//   [0]: apple
//   [1]: banana
//   [2]: cherry
```

## Spread Operator

### Spreading Arrays

```home
let numbers = [1, 2, 3]
let more = [4, 5, 6]

// Spread in function calls
let total = sum(...numbers)           // 6
let all = sum(...numbers, ...more)    // 21
let mixed = sum(0, ...numbers, 10)    // 16
```

### Spreading in Array Literals

```home
let arr1 = [1, 2, 3]
let arr2 = [4, 5, 6]

// Create new array with spread
let combined = [...arr1, ...arr2]     // [1, 2, 3, 4, 5, 6]
let extended = [0, ...arr1, 10]       // [0, 1, 2, 3, 10]
```

## Type Safety

### Type Constraints

```home
// All variadic arguments must be same type
fn add_numbers(...nums: i32): i32 {
    nums.iter().sum()
}

add_numbers(1, 2, 3)      // OK
add_numbers(1, 2.5, 3)    // Error: expected i32, found f64
```

### Generic Constraints

```home
// Generic with trait bounds
fn print_all<T: Display>(...items: T): void {
    for item in items {
        println("{}", item)
    }
}

print_all(1, 2, 3)           // OK - i32 implements Display
print_all("a", "b", "c")     // OK - string implements Display
```

### Mixed Types with Any

```home
// Accept any type (less safe)
fn log(...items: any): void {
    for item in items {
        println("{:?}", item)
    }
}

log(1, "hello", true, 3.14)  // OK - different types
```

## Built-in Variadic Functions

### println

```home
// Print with automatic formatting
println("Hello, World!")
println("x =", x, "y =", y)
println("Values:", 1, 2, 3, 4, 5)
```

### format

```home
// String formatting
let msg = format("Hello, {}!", "World")
let info = format("{} + {} = {}", 2, 3, 5)
```

### vec/array

```home
// Create vector from values
let numbers = vec(1, 2, 3, 4, 5)
let mixed = vec("a", "b", "c")
```

### max/min

```home
// Find maximum
let maximum = max(1, 5, 3, 9, 2)  // 9
let minimum = min(1, 5, 3, 9, 2)  // 1

// Works with any Ord type
let max_str = max("apple", "zebra", "banana")  // "zebra"
```

## Generic Variadic Functions

### Type Parameters

```home
// Generic variadic function
fn first_of<T>(...items: T): Option<T> {
    if items.len() > 0 {
        Some(items[0])
    } else {
        None
    }
}

let num = first_of(1, 2, 3)        // Some(1)
let str = first_of("a", "b")       // Some("a")
let none = first_of::<i32>()       // None
```

### Multiple Type Parameters

```home
// Multiple generics with variadic
fn zip_with<T, U, R>(
    func: fn(T, U): R,
    ts: ...T,
    us: ...U
): Vec<R> {
    let mut results = vec![]
    let len = min(ts.len(), us.len())
    
    for i in 0..len {
        results.push(func(ts[i], us[i]))
    }
    
    results
}

let sums = zip_with(
    |a, b| a + b,
    1, 2, 3,
    10, 20, 30
)  // [11, 22, 33]
```

## Advanced Patterns

### Variadic Macros

```home
// Macro with variadic arguments
macro_rules! vec {
    ($($x:expr),*) => {
        {
            let mut temp_vec = Vec::new()
            $(
                temp_vec.push($x);
            )*
            temp_vec
        }
    };
}

let v = vec![1, 2, 3, 4, 5]
```

### Builder Pattern

```home
struct QueryBuilder {
    conditions: Vec<string>,
}

impl QueryBuilder {
    fn new(): QueryBuilder {
        QueryBuilder { conditions: vec![] }
    }
    
    fn where_in(&mut self, field: string, ...values: any): &mut QueryBuilder {
        let vals = values.iter()
            .map(|v| v.to_string())
            .collect::<Vec<_>>()
            .join(", ")
        
        self.conditions.push(format("{} IN ({})", field, vals))
        self
    }
}

let query = QueryBuilder::new()
    .where_in("id", 1, 2, 3, 4, 5)
    .build()
```

### Recursive Variadic

```home
// Process variadic arguments recursively
fn process_all<T>(...items: T): void
where
    T: Display
{
    if items.len() == 0 {
        return
    }
    
    println("{}", items[0])
    process_all(...items[1..])
}
```

## Best Practices

### 1. Use Type Constraints

```home
// Good - type safe
fn sum_numbers(...nums: i32): i32 {
    nums.iter().sum()
}

// Avoid - too permissive
fn sum_anything(...items: any): any {
    // Type safety lost
}
```

### 2. Provide Clear Documentation

```home
/// Calculates the average of the given numbers.
/// 
/// # Arguments
/// * `numbers` - Variable number of numeric values
/// 
/// # Returns
/// The arithmetic mean, or 0 if no numbers provided
/// 
/// # Examples
/// ```
/// let avg = average(1, 2, 3, 4, 5)  // 3
/// ```
fn average(...numbers: f64): f64 {
    if numbers.len() == 0 {
        return 0.0
    }
    numbers.iter().sum::<f64>() / numbers.len() as f64
}
```

### 3. Consider Minimum Arguments

```home
// Require at least one argument
fn max<T: Ord>(first: T, ...rest: T): T {
    let mut maximum = first
    for value in rest {
        if value > maximum {
            maximum = value
        }
    }
    maximum
}

// Compile-time error if called with no arguments
let m = max()  // Error: missing required argument
```

### 4. Use Spread for Readability

```home
// Good - clear intent
let all_numbers = [...first_batch, ...second_batch, ...third_batch]

// Avoid - manual concatenation
let all_numbers = first_batch.concat(second_batch).concat(third_batch)
```

### 5. Limit Variadic Complexity

```home
// Good - simple variadic
fn concat(...strings: string): string {
    strings.join("")
}

// Avoid - too complex
fn complex(...items: any): Result<any, Error> {
    // Too much type checking and branching
}
```

## Limitations

### Current Limitations

1. **Single variadic parameter** - Only one variadic parameter per function
2. **Must be last** - Variadic parameter must be the last parameter
3. **No named variadic** - Cannot use named arguments with variadic parameters

```home
// OK
fn func(a: i32, b: string, ...rest: i32): void { }

// Error - variadic not last
fn func(...rest: i32, a: i32): void { }

// Error - multiple variadic
fn func(...nums: i32, ...strs: string): void { }
```

## Examples

### Logging Utility

```home
enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

fn log(level: LogLevel, ...messages: any): void {
    let prefix = match level {
        LogLevel::Debug => "[DEBUG]",
        LogLevel::Info => "[INFO]",
        LogLevel::Warn => "[WARN]",
        LogLevel::Error => "[ERROR]",
    }
    
    print("{} ", prefix)
    for (i, msg) in messages.iter().enumerate() {
        if i > 0 {
            print(" ")
        }
        print("{:?}", msg)
    }
    println("")
}

log(LogLevel::Info, "Server started on port", 8080)
log(LogLevel::Error, "Failed to connect:", error_msg)
```

### SQL Query Builder

```home
fn select(...columns: string): QueryBuilder {
    QueryBuilder::new().select(columns)
}

fn where_clause(field: string, op: string, ...values: any): Condition {
    Condition::new(field, op, values)
}

let query = select("id", "name", "email")
    .from("users")
    .where_clause("age", ">", 18)
    .where_clause("status", "IN", "active", "pending")
    .build()
```

### Test Assertions

```home
fn assert_all_equal<T: PartialEq + Debug>(...values: T): void {
    if values.len() < 2 {
        return
    }
    
    let first = values[0]
    for (i, value) in values[1..].iter().enumerate() {
        if value != first {
            panic!(
                "Assertion failed: values[0] != values[{}]\n  left: {:?}\n right: {:?}",
                i + 1, first, value
            )
        }
    }
}

assert_all_equal(1, 1, 1, 1)  // OK
assert_all_equal(1, 1, 2, 1)  // Panics
```

## See Also

- [Functions](FUNCTIONS.md) - Regular function definitions
- [Generics](GENERICS.md) - Generic type parameters
- [Macros](MACROS.md) - Compile-time code generation
- [Arrays](ARRAYS.md) - Array and slice operations
