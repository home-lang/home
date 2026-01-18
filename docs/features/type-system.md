# Type System

Home features a powerful, expressive type system that combines the best aspects of modern programming languages. It provides strong static typing with excellent type inference, ensuring both safety and ergonomics.

## Overview

The Home type system is designed around several key principles:

- **Sound by default**: Types guarantee runtime behavior
- **Expressive**: Rich type constructs for modeling complex domains
- **Inferrable**: Minimal annotations required in most cases
- **Zero-cost abstractions**: Type information is erased at compile time

## Primitive Types

Home provides a comprehensive set of primitive types optimized for systems programming:

### Integer Types

```home
// Signed integers
let a: i8 = -128
let b: i16 = -32768
let c: i32 = -2147483648
let d: i64 = -9223372036854775808
let e: i128 = -170141183460469231731687303715884105728
let f: isize = -1  // Platform-dependent size

// Unsigned integers
let g: u8 = 255
let h: u16 = 65535
let i: u32 = 4294967295
let j: u64 = 18446744073709551615
let k: u128 = 340282366920938463463374607431768211455
let l: usize = 1  // Platform-dependent size
```

### Floating-Point Types

```home
let x: f32 = 3.14159
let y: f64 = 2.718281828459045

// Special values
let inf = f64.inf
let neg_inf = f64.neg_inf
let nan = f64.nan
```

### Boolean and Character Types

```home
let flag: bool = true
let letter: char = 'A'
let emoji: char = '\u{1F600}'  // Unicode scalar value
```

## Compound Types

### Tuples

Tuples group multiple values of different types:

```home
let point: (i32, i32) = (10, 20)
let mixed: (string, i32, bool) = ("hello", 42, true)

// Accessing tuple elements
let x = point.0  // 10
let y = point.1  // 20

// Destructuring
let (name, age, active) = mixed
```

### Arrays

Fixed-size collections of homogeneous elements:

```home
let numbers: [i32; 5] = [1, 2, 3, 4, 5]
let zeros: [i32; 100] = [0; 100]  // Initialize with repeated value

// Array access
let first = numbers[0]
let length = numbers.len()  // 5

// Compile-time bounds checking when index is known
let valid = numbers[4]    // OK
// let invalid = numbers[5]  // Compile error: index out of bounds
```

### Slices

Dynamically-sized views into contiguous sequences:

```home
let array = [1, 2, 3, 4, 5]
let slice: []i32 = array[1..4]  // [2, 3, 4]

// Slice operations
let first = slice[0]
let len = slice.len()  // 3

// Full slice
let full: []i32 = array[..]
```

## Type Inference

Home's type inference engine eliminates most explicit type annotations:

```home
// Types are inferred from context
let x = 42           // i32 (default integer type)
let y = 3.14         // f64 (default float type)
let z = "hello"      // string
let list = [1, 2, 3] // [i32; 3]

// Inference through function calls
fn double(n: i32) -> i32 {
    n * 2
}

let result = double(21)  // result: i32

// Inference in closures
let add = |a, b| a + b
let sum = add(1, 2)  // Inferred as (i32, i32) -> i32
```

## Type Aliases

Create meaningful names for complex types:

```home
type UserId = u64
type Point2D = (f64, f64)
type Matrix4x4 = [[f64; 4]; 4]
type Result<T> = Result<T, Error>
type Callback<T> = fn(T) -> void

// Usage
let id: UserId = 12345
let origin: Point2D = (0.0, 0.0)
```

## Optional Types

Home uses explicit optional types instead of null:

```home
// Optional type syntax
let maybe_number: ?i32 = 42
let nothing: ?i32 = null

// Working with optionals
if let Some(n) = maybe_number {
    print("Got: {n}")
}

// Optional chaining
let result = maybe_number?.to_string()

// Default values
let value = maybe_number ?? 0

// Unwrapping (panics if null)
let definitely = maybe_number.!
```

## Union Types

Express values that can be one of several types:

```home
type StringOrNumber = string | i32

fn process(value: StringOrNumber) {
    match value {
        string => print("String: {value}"),
        i32 => print("Number: {value}"),
    }
}

process("hello")  // String: hello
process(42)       // Number: 42
```

## Intersection Types

Combine multiple type constraints:

```home
trait Printable {
    fn print(self)
}

trait Serializable {
    fn serialize(self) -> []u8
}

// Type must implement both traits
fn save(item: Printable & Serializable) {
    item.print()
    let bytes = item.serialize()
    // ...
}
```

## Never Type

The `never` type represents computations that never complete:

```home
// Functions that never return
fn infinite_loop() -> never {
    loop {}
}

fn panic(message: string) -> never {
    print("PANIC: {message}")
    std.process.exit(1)
}

// Useful in match expressions
fn unwrap_or_panic<T>(opt: ?T) -> T {
    match opt {
        Some(value) => value,
        None => panic("unwrap failed"),  // never coerces to T
    }
}
```

## Phantom Types

Types used only at compile time for additional type safety:

```home
struct Meters<phantom T> {
    value: f64,
}

struct Validated {}
struct Unvalidated {}

fn validate(input: Meters<Unvalidated>) -> ?Meters<Validated> {
    if input.value >= 0.0 {
        Some(Meters { value: input.value })
    } else {
        null
    }
}

// Type system prevents mixing validated/unvalidated data
let raw: Meters<Unvalidated> = Meters { value: 100.0 }
let validated = validate(raw).!  // Meters<Validated>
```

## Type Constraints

Constrain generic types with trait bounds:

```home
// Single constraint
fn print_value<T: Display>(value: T) {
    print("{value}")
}

// Multiple constraints
fn process<T: Clone + Debug + Send>(value: T) {
    let copy = value.clone()
    debug_print(copy)
}

// Where clauses for complex constraints
fn complex<T, U>(a: T, b: U) -> T
where
    T: From<U> + Default,
    U: Into<T>,
{
    if a == T.default() {
        b.into()
    } else {
        a
    }
}
```

## Associated Types

Types defined within traits:

```home
trait Iterator {
    type Item

    fn next(mut self) -> ?Self.Item
}

struct Counter {
    current: i32,
    max: i32,
}

impl Iterator for Counter {
    type Item = i32

    fn next(mut self) -> ?i32 {
        if self.current < self.max {
            let value = self.current
            self.current += 1
            Some(value)
        } else {
            null
        }
    }
}
```

## Existential Types

Hide concrete types behind abstract interfaces:

```home
// Return type is hidden
fn make_iterator() -> impl Iterator<Item = i32> {
    Counter { current: 0, max: 10 }
}

// The caller only knows it implements Iterator
let iter = make_iterator()
for item in iter {
    print("{item}")
}
```

## Const Generics

Use compile-time values as type parameters:

```home
struct Array<T, const N: usize> {
    data: [T; N],
}

impl<T, const N: usize> Array<T, N> {
    fn new(default: T) -> Self where T: Copy {
        Array { data: [default; N] }
    }

    fn len(self) -> usize {
        N
    }
}

let arr: Array<i32, 10> = Array.new(0)
assert(arr.len() == 10)
```

## Edge Cases

### Recursive Types

Recursive types require indirection:

```home
// Direct recursion is not allowed
// struct Node { next: Node }  // Error: infinite size

// Use Box for indirection
struct Node {
    value: i32,
    next: ?Box<Node>,
}

// Or use explicit reference
struct TreeNode {
    value: i32,
    left: ?*TreeNode,
    right: ?*TreeNode,
}
```

### Zero-Sized Types

Types with no runtime representation:

```home
struct Unit {}

// ZSTs take no memory
let units: [Unit; 1000000] = [Unit {}; 1000000]
assert(std.mem.size_of::<[Unit; 1000000]>() == 0)
```

### Covariance and Contravariance

Understanding variance in generic types:

```home
// Covariant in T (can substitute subtypes)
struct Box<T> {
    value: T,
}

// Invariant (no substitution allowed)
struct Cell<T> {
    value: mut T,
}

// Contravariant in argument position
type Consumer<T> = fn(T) -> void
```

## Best Practices

1. **Prefer type inference**: Let the compiler infer types when clear
   ```home
   // Good
   let numbers = [1, 2, 3, 4, 5]

   // Unnecessary
   let numbers: [i32; 5] = [1, 2, 3, 4, 5]
   ```

2. **Use type aliases for clarity**: Name complex types
   ```home
   type HttpHeaders = HashMap<string, []string>
   type ResponseHandler = fn(Response) -> Result<void, Error>
   ```

3. **Prefer optionals over sentinel values**:
   ```home
   // Good
   fn find(items: []Item, id: u64) -> ?Item

   // Avoid
   fn find(items: []Item, id: u64) -> Item  // Returns "empty" Item if not found
   ```

4. **Use newtypes for type safety**:
   ```home
   struct UserId(u64)
   struct OrderId(u64)

   // Prevents accidentally mixing IDs
   fn get_user(id: UserId) -> User
   fn get_order(id: OrderId) -> Order
   ```

5. **Constrain generics appropriately**: Only require what you need
   ```home
   // Too restrictive
   fn count<T: Clone + Debug + Eq + Hash>(items: []T) -> usize

   // Just right
   fn count<T>(items: []T) -> usize {
       items.len()
   }
   ```
