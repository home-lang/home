<p align="center"><img src="https://github.com/home-lang/home/blob/main/.github/art/banner.jpg?raw=true" alt="Social Card of this repo"></p>

A modern programming language for systems, apps, and games. Combines the speed of Zig, the safety of Rust, and the joy of TypeScript.

## Quick Start

```bash
# Clone and build
git clone https://github.com/home-lang/home.git
cd home
zig build

# Run an example
./zig-out/bin/home build examples/fibonacci.home
./examples/fibonacci
```

## Hello World

```home
fn main() {
  print("Hello, Home!")
}
```

## Language Overview

### Variables

```home
let name = "Alice"           // immutable by default
let mut counter = 0          // mutable
let age: int = 25            // explicit type
const PI = 3.14159           // compile-time constant
```

### Control Flow

```home
// if statements (parentheses required)
if (x > 5) {
  print("big")
} else {
  print("small")
}

// while loops
while (count < 10) {
  count = count + 1
}

// for loops
for (item in items) {
  print(item)
}

for (i in 0..10) {
  print(i)
}

// for with index
for (index, item in items) {
  print("{index}: {item}")
}
```

### Functions

```home
fn add(a: int, b: int): int {
  return a + b
}

fn greet(name: string) {
  print("Hello, {name}!")
}

// default parameter values
fn greet_with_default(name: string = "World") {
  print("Hello, {name}!")
}

greet_with_default()          // prints: Hello, World!
greet_with_default("Alice")   // prints: Hello, Alice!

// async functions
fn fetch_data(): async Result<Data> {
  let response = await http.get("/api/data")
  return response.json()
}
```

### Structs

```home
struct Point {
  x: int
  y: int
}

struct User {
  id: i64
  name: string
  email: string
}

let origin = Point { x: 0, y: 0 }
let user = User { id: 1, name: "Alice", email: "alice@example.com" }
```

### Enums

```home
enum Color {
  Red,
  Green,
  Blue,
  Custom(r: int, g: int, b: int)
}

enum Result<T, E> {
  Ok(T),
  Err(E)
}
```

### Pattern Matching

```home
match value {
  Ok(x) => print("Got: {x}"),
  Err(e) => print("Error: {e}")
}

match color {
  Color.Red => print("red"),
  Color.Green => print("green"),
  Color.Blue => print("blue"),
  Color.Custom(r, g, b) => print("rgb({r}, {g}, {b})")
}
```

### Expression Forms

If and match can be used as expressions that return values:

```home
// if expression
let status = if (code == 200) { "ok" } else { "error" }

// match expression
let name = match x {
  1 => "one",
  2 => "two",
  _ => "other"
}
```

### Null Safety Operators

```home
// Elvis operator (?:) - returns right side if left is null
let name = user?.name ?: "Anonymous"

// Null coalescing (??) - same as Elvis
let value = maybeNull ?? defaultValue

// Safe navigation (?.) - returns null if object is null
let city = user?.address?.city

// Safe indexing (?[]) - returns null if index out of bounds
let first = items?[0]
let safe = items?[10] ?: defaultItem
```

### Error Handling

```home
fn read_file(path: string): Result<string, Error> {
  let file = fs.open(path)?   // ? propagates errors
  return Ok(file.read_all())
}

// handle errors
match read_file("config.home") {
  Ok(content) => process(content),
  Err(e) => print("Failed: {e}")
}

// or with default
let content = read_file("config.home").unwrap_or("default")
```

### Arrays and Slices

```home
let numbers = [1, 2, 3, 4, 5]
let first = numbers[0]
let slice = numbers[1..4]      // [2, 3, 4]

for (n in numbers) {
  print(n)
}

// Array methods
numbers.len()       // 5
numbers.is_empty()  // false
numbers.first()     // 1
numbers.last()      // 5
```

### String Methods

```home
let s = "  Hello World  "

// Length
s.len()              // 15

// Case conversion
s.upper()            // "  HELLO WORLD  "
s.lower()            // "  hello world  "

// Trimming
s.trim()             // "Hello World"
s.trim_start()       // "Hello World  "
s.trim_end()         // "  Hello World"

// Searching
s.contains("World")  // true
s.starts_with("  H") // true
s.ends_with("  ")    // true

// Splitting and replacing
"a,b,c".split(",")           // ["a", "b", "c"]
s.replace("World", "Home")   // "  Hello Home  "

// Other methods
"ab".repeat(3)       // "ababab"
s.is_empty()         // false
s.char_at(2)         // "H"
"hello".reverse()    // "olleh"

// Method chaining
"  HELLO  ".trim().lower()  // "hello"
```

### Arithmetic Operators

```home
// Power operator (**)
let squared = 5 ** 2      // 25
let cubed = 2 ** 3        // 8
let power10 = 2 ** 10     // 1024

// Integer division (~/)
let result = 7 ~/ 2       // 3 (truncates toward zero)
let another = 17 ~/ 5     // 3

// Standard operators
let sum = 10 + 5          // 15
let diff = 10 - 3         // 7
let prod = 4 * 3          // 12
let quot = 10 / 4         // 2.5 (regular division)
let rem = 10 % 3          // 1 (modulo)
```

### Range Methods

```home
// Create ranges
let r = 0..10            // exclusive: 0,1,2,...,9
let inclusive = 0..=10   // inclusive: 0,1,2,...,10

// Range methods
r.len()                  // 10
r.first()                // 0
r.last()                 // 9
r.contains(5)            // true
r.contains(10)           // false (exclusive)

// Step through range
let stepped = (0..10).step(2)
stepped.to_array()       // [0, 2, 4, 6, 8]

// Inclusive range
inclusive.len()          // 11
inclusive.contains(10)   // true
inclusive.last()         // 10
```

### Generics

```home
fn map<T, U>(items: []T, f: fn(T): U): []U {
  let result = []U.init(items.len)
  for (i, item in items) {
    result[i] = f(item)
  }
  return result
}

struct Stack<T> {
  items: []T

  fn push(self, item: T) {
    self.items.append(item)
  }

  fn pop(self): Option<T> {
    return self.items.pop()
  }
}
```

### Comptime

```home
comptime fn factorial(n: int): int {
  if (n <= 1) {
    return 1
  }
  return n * factorial(n - 1)
}

const FACT_10 = factorial(10)  // computed at compile time
```

## Standard Library

### HTTP Server

```home
import http { Server, Response }

fn main() {
  let server = Server.bind(":3000")

  server.get("/", fn(req) {
    return "Hello from Home!"
  })

  server.get("/users/:id", fn(req): Response {
    let id = req.param("id")
    return Response.json({ id: id })
  })

  server.listen()
}
```

### Database

```home
import database { Connection }

fn main() {
  let db = Connection.open("app.db")

  db.exec("CREATE TABLE users (id INTEGER, name TEXT)")

  let stmt = db.prepare("INSERT INTO users VALUES (?, ?)")
  stmt.bind(1, 42)
  stmt.bind(2, "Alice")
  stmt.execute()

  let users = db.query("SELECT * FROM users")
  for (row in users) {
    print("User: {row.name}")
  }
}
```

### Async/Await

```home
fn fetch_users(): async []User {
  let response = await http.get("/api/users")
  return response.json()
}

fn main(): async {
  let users = await fetch_users()
  for (user in users) {
    print(user.name)
  }
}
```

## Project Structure

```
home/
├── src/main.zig           # CLI entry point
├── packages/
│   ├── lexer/             # Tokenization
│   ├── parser/            # AST generation
│   ├── ast/               # Syntax tree types
│   ├── types/             # Type system
│   ├── codegen/           # Native code generation (x64)
│   ├── interpreter/       # Direct execution
│   ├── diagnostics/       # Error reporting
│   └── ...
├── examples/              # Example programs
├── tests/                 # Integration tests
└── stdlib/                # Standard library
```

## Building

### Prerequisites

- Zig 0.16+ (for building the compiler)

```bash
# macOS
brew install zig

# alternatively
pantry install zig

# Linux
# Download from https://ziglang.org/download/
```

### Build Commands

```bash
# Build the compiler
zig build

# Run tests
zig build test

# Build and run an example
./zig-out/bin/home build examples/fibonacci.home
./examples/fibonacci
```

## File Extensions

- `.home` - Standard source file extension
- `.hm` - Short alternative

## Features

- **Fast compilation** - Incremental builds with IR caching
- **Memory safety** - Ownership and borrowing without ceremony
- **Native performance** - Compiles to native x64 code
- **Modern syntax** - TypeScript-inspired, clean and readable
- **Pattern matching** - Exhaustive match expressions
- **Expression-oriented** - If and match as expressions
- **Null safety** - Elvis (`?:`), safe navigation (`?.`), safe indexing (`?[]`)
- **Async/await** - Zero-cost async programming
- **Generics** - Type-safe generic functions and types
- **Comptime** - Compile-time code execution
- **Error handling** - Result types with `?` propagation
- **Power operator** - `**` for exponentiation (`2 ** 10`)
- **Integer division** - `~/` for truncating division
- **Range methods** - `.len()`, `.step()`, `.contains()`, `.to_array()`
- **Default parameters** - `fn greet(name: string = "World")`
- **String methods** - `.trim()`, `.upper()`, `.split()`, and more

## Current Status

Home is under active development. The compiler infrastructure is functional:

- Lexer and parser
- Type system with inference
- Native x64 code generation
- Basic standard library

## Contributing

Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT License - see [LICENSE](./LICENSE)
