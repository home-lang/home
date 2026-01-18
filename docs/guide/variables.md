# Variables and Types

Home features a powerful type system with type inference, immutability by default, and compile-time constants.

## Variable Declarations

### Immutable Variables with `let`

Variables declared with `let` are immutable by default:

```home
let name = "Alice"
let age = 25
let pi = 3.14159

// This will cause a compile error:
// name = "Bob"  // Error: cannot assign to immutable variable
```

### Mutable Variables with `let mut`

Use `let mut` when you need to modify a variable:

```home
let mut counter = 0
counter = counter + 1
print("Counter: {counter}")  // Counter: 1

let mut name = "Alice"
name = "Bob"  // OK
```

### Compile-Time Constants with `const`

Constants are evaluated at compile time and must have a known value:

```home
const MAX_SIZE = 1024
const PI = 3.14159
const GREETING = "Hello, World!"

// Constants can use compile-time expressions
const DOUBLED = MAX_SIZE * 2  // 2048

// Cannot modify constants
// MAX_SIZE = 2048  // Error: cannot assign to constant
```

## Type Annotations

Home features type inference, but you can always add explicit type annotations:

```home
let name: string = "Alice"
let age: int = 25
let price: float = 19.99
let active: bool = true
```

## Basic Types

### Integers

Home supports various integer sizes:

| Type | Size | Range |
|------|------|-------|
| `i8` | 8-bit | -128 to 127 |
| `i16` | 16-bit | -32,768 to 32,767 |
| `i32` | 32-bit | -2^31 to 2^31-1 |
| `i64` | 64-bit | -2^63 to 2^63-1 |
| `int` | Platform | Alias for `i64` |
| `u8` | 8-bit | 0 to 255 |
| `u16` | 16-bit | 0 to 65,535 |
| `u32` | 32-bit | 0 to 2^32-1 |
| `u64` | 64-bit | 0 to 2^64-1 |

```home
let small: i8 = 127
let count: i32 = 1000000
let big: i64 = 9223372036854775807
let byte: u8 = 255
```

### Floating-Point Numbers

```home
let pi: f32 = 3.14159
let precise: f64 = 3.141592653589793
let price: float = 19.99  // Alias for f64
```

### Booleans

```home
let active: bool = true
let disabled: bool = false

let is_valid = age >= 18  // Type inferred as bool
```

### Strings

Strings in Home support interpolation using `{expression}`:

```home
let name = "Alice"
let age = 30
let greeting = "Hello, {name}! You are {age} years old."
print(greeting)  // Hello, Alice! You are 30 years old.
```

String escape sequences:

```home
let newline = "Line 1\nLine 2"
let tab = "Column1\tColumn2"
let quote = "She said \"Hello\""
let backslash = "Path: C:\\Users"
let hex = "\x41"       // 'A'
let unicode = "\u{1F600}"  // Emoji
```

### String Methods

```home
let s = "  Hello World  "

s.len()              // 15
s.upper()            // "  HELLO WORLD  "
s.lower()            // "  hello world  "
s.trim()             // "Hello World"
s.trim_start()       // "Hello World  "
s.trim_end()         // "  Hello World"
s.contains("World")  // true
s.starts_with("  H") // true
s.ends_with("  ")    // true
"a,b,c".split(",")   // ["a", "b", "c"]
s.replace("World", "Home")  // "  Hello Home  "
"ab".repeat(3)       // "ababab"
s.is_empty()         // false
s.char_at(2)         // "H"
"hello".reverse()    // "olleh"

// Method chaining
"  HELLO  ".trim().lower()  // "hello"
```

## Arrays and Slices

### Arrays

Fixed-size collections of elements:

```home
let numbers = [1, 2, 3, 4, 5]
let first = numbers[0]    // 1
let last = numbers[4]     // 5

// With type annotation
let scores: [5]int = [100, 95, 87, 92, 88]
```

### Slices

Dynamic views into arrays:

```home
let numbers = [1, 2, 3, 4, 5]

let slice = numbers[1..4]     // [2, 3, 4] (exclusive end)
let start = numbers[..3]      // [1, 2, 3]
let end = numbers[2..]        // [3, 4, 5]
let inclusive = numbers[1..=3] // [2, 3, 4] (inclusive end)
```

### Array Methods

```home
let arr = [1, 2, 3, 4, 5]

arr.len()       // 5
arr.is_empty()  // false
arr.first()     // 1
arr.last()      // 5
```

## Ranges

Create sequences of numbers:

```home
let exclusive = 0..10      // 0 to 9
let inclusive = 0..=10     // 0 to 10

// Range methods
exclusive.len()            // 10
exclusive.first()          // 0
exclusive.last()           // 9
exclusive.contains(5)      // true
exclusive.contains(10)     // false

inclusive.contains(10)     // true

// Stepped ranges
let stepped = (0..10).step(2)
stepped.to_array()         // [0, 2, 4, 6, 8]
```

## Type Aliases

Create custom names for types:

```home
type UserId = i64
type Email = string
type Scores = []int

let user_id: UserId = 12345
let email: Email = "alice@example.com"
let scores: Scores = [100, 95, 87]
```

## Type Inference

Home's type inference is powerful and reduces boilerplate:

```home
let x = 42           // Inferred as int
let y = 3.14         // Inferred as float
let name = "Alice"   // Inferred as string
let items = [1, 2]   // Inferred as []int

// Function return types can be inferred
fn add(a: int, b: int) {
  return a + b       // Return type inferred as int
}
```

## Null Safety

Home provides operators for safe null handling:

### Elvis Operator (`?:`)

Returns the right side if left is null:

```home
let name = user?.name ?: "Anonymous"
```

### Null Coalescing (`??`)

Same as Elvis operator:

```home
let value = maybeNull ?? defaultValue
```

### Safe Navigation (`?.`)

Returns null if object is null:

```home
let city = user?.address?.city
```

### Safe Indexing (`?[]`)

Returns null if index is out of bounds:

```home
let first = items?[0]
let safe = items?[10] ?: defaultItem
```

## Arithmetic Operators

### Standard Operators

```home
let sum = 10 + 5          // 15
let diff = 10 - 3         // 7
let prod = 4 * 3          // 12
let quot = 10 / 4         // 2.5
let rem = 10 % 3          // 1
```

### Power Operator (`**`)

```home
let squared = 5 ** 2      // 25
let cubed = 2 ** 3        // 8
let power10 = 2 ** 10     // 1024
```

### Integer Division (`~/`)

Truncates toward zero:

```home
let result = 7 ~/ 2       // 3
let another = 17 ~/ 5     // 3
```

## Bitwise Operators

```home
let a = 12    // 1100 in binary
let b = 10    // 1010 in binary

let and = a & b   // 8  (1000)
let or = a | b    // 14 (1110)
let xor = a ^ b   // 6  (0110)
let not = ~a      // -13
let left = a << 2 // 48
let right = a >> 2 // 3
```

## Next Steps

- [Functions](/guide/functions) - Define and call functions
- [Control Flow](/guide/control-flow) - Conditionals and loops
- [Structs and Enums](/guide/structs-enums) - Custom data types
