# Home Programming Language - Comprehensive Syntax Review

**Generated:** 2025-11-03
**Purpose:** Detailed review of all language syntax and grammar for team discussion

---

## Table of Contents

1. [Language Overview](#language-overview)
2. [Lexical Structure](#lexical-structure)
3. [Type System](#type-system)
4. [Declarations](#declarations)
5. [Expressions](#expressions)
6. [Statements](#statements)
7. [Pattern Matching](#pattern-matching)
8. [Advanced Features](#advanced-features)
9. [Syntax Summary Tables](#syntax-summary-tables)
10. [Considerations & Discussion Points](#considerations--discussion-points)

---

## Language Overview

Home is a modern systems programming language with:
- **Static typing** with optional type inference
- **Ownership and borrowing** semantics (Rust-inspired)
- **Trait-based polymorphism**
- **Compile-time evaluation** (comptime)
- **Pattern matching** and algebraic data types
- **Async/await** for concurrency
- **Memory safety** without garbage collection

**Design Philosophy:** Combines Rust's safety with Zig's simplicity and compile-time capabilities.

---

## Lexical Structure

### Comments

```home
// Single-line comment

/* Multi-line comment
   Can span multiple lines
   Nested comments NOT supported */
```

### Literals

#### Integer Literals
```home
42          // Decimal (i64)
0           // Zero
-17         // Negative
```

#### Float Literals
```home
3.14        // Decimal point required
0.5         // Leading zero
2.0         // Trailing zero required
```

#### String Literals
```home
"hello"                  // Basic string
"hello\nworld"          // With escape sequences
"value: \x41"           // Hex escape (\xNN)
"emoji: \u{1F600}"      // Unicode escape (\u{NNNN})

// Supported escapes: \n \t \r \" \\ \' \0 \{

// String interpolation
"Hello {name}!"                    // Simple interpolation
"Result: {x + 1}"                  // Expression interpolation
"Full name: {first} {last}"        // Multiple interpolations
"Nested: {foo({bar})}"             // Nested braces in expressions
"Escaped: \{not interpolated}"     // Escaped brace (literal)

// Raw strings (no escape processing)
r"C:\path\to\file"                 // Raw string
r#"String with "quotes""#          // Raw string with # delimiter
r##"Can contain # in text"##       // Multiple # for flexibility
```

#### Boolean Literals
```home
true
false
```

### Identifiers

```home
foo             // Lowercase
myVariable      // CamelCase
my_variable     // Snake_case
_private        // Leading underscore
variable123     // With numbers
```

**Rules:**
- Start with letter or underscore
- Contain letters, digits, underscores
- Case-sensitive

### Keywords (52 total)

```
and, asm, async, await, break, case, catch, comptime, const,
continue, default, defer, do, dyn, else, finally, enum, false,
fn, for, if, impl, import, in, let, loop, match, mut, or,
return, Self, self, struct, switch, trait, true, try, type,
union, unsafe, where, while
```

---

## Type System

### Primitive Types

```home
// Integers (inferred as i64)
int, i8, i16, i32, i64, i128
uint, u8, u16, u32, u64, u128

// Floats (inferred as f64)
float, f32, f64

// Other
bool        // true/false
string      // UTF-8 string
void        // No return value
```

### Compound Types

#### Arrays
```home
let arr: [int] = [1, 2, 3, 4, 5]
let empty: [string] = []
```

#### Tuples
```home
let pair = (1, 2)
let triple = (1, "hello", true)
let empty = ()  // Unit type
```

#### Structs
```home
struct Point {
    x: int,
    y: int
}

struct Person {
    name: string,
    age: int
}
```

#### Enums (Algebraic Data Types)
```home
enum Color {
    Red,
    Green,
    Blue
}

enum Option {
    Some(int),
    None
}

enum Result {
    Ok(int),
    Err(string)
}
```

#### Unions (Discriminated)
```home
union Value {
    Int(int),
    Float(float),
    String(string)
}
```

#### Type Aliases
```home
type Name = string
type ID = u64
type Callback = fn(int) -> void
```

### Generic Types

```home
struct Vec<T> {
    data: [T],
    len: int
}

enum Option<T> {
    Some(T),
    None
}

struct Result<T, E> {
    Ok(T),
    Err(E)
}
```

---

## Declarations

### Variables

#### Let Declarations (Immutable by default)
```home
let x = 42                  // Type inferred
let y: int = 100           // Explicit type
let z: float               // No initializer
let name = "Alice"         // String inference
```

#### Mutable Variables
```home
let mut counter = 0
counter = counter + 1

let mut data: [int] = []
```

#### Const Declarations
```home
const PI = 3.14159
const MAX_SIZE = 1000
```

### Functions

#### Basic Function
```home
fn add(x: int, y: int) -> int {
    return x + y
}

fn greet(name: string) {
    print("Hello, {name}")
}
```

#### No Return Type (void inferred)
```home
fn print_message() {
    print("Hello")
}
```

#### Generic Functions
```home
fn identity<T>(value: T) -> T {
    return value
}

fn map<T, U>(arr: [T], f: fn(T) -> U) -> [U] {
    // ...
}
```

#### Async Functions
```home
async fn fetch_data(url: string) -> Result<Data> {
    let response = await http.get(url)
    return await response.json()
}
```

#### Test Functions
```home
@test
fn test_addition() {
    assert(add(2, 2) == 4)
}
```

### Struct Declarations

```home
struct Point {
    x: int,
    y: int
}

// Generic struct
struct Container<T> {
    value: T,
    next: Option<Container<T>>
}

// Multiple type parameters
struct Pair<T, U> {
    first: T,
    second: U
}
```

### Enum Declarations

```home
enum Status {
    Pending,
    Active,
    Completed
}

enum Option<T> {
    Some(T),
    None
}
```

### Union Declarations

```home
union Number {
    Integer(int),
    Float(float)
}
```

### Type Alias Declarations

```home
type UserId = u64
type Handler = fn(Event) -> void
type Result<T> = Result<T, Error>
```

### Trait Declarations

```home
trait Animal {
    fn make_sound(&self) -> string
    fn get_name(&self) -> string
}

// With associated types
trait Iterator {
    type Item
    fn next(&mut self) -> Option<Self::Item>
}

// With default implementations
trait Summary {
    fn summarize_author(&self) -> string

    fn summarize(&self) -> string {
        "Read more from " + self.summarize_author()
    }
}

// Trait inheritance
trait ColoredShape: Shape + Colored {
    fn describe(&self) -> string
}
```

### Implementation Blocks

```home
// Trait implementation
impl Animal for Dog {
    fn make_sound(&self) -> string {
        "Woof!"
    }

    fn get_name(&self) -> string {
        self.name
    }
}

// Generic implementation
impl<T> Iterator for Counter<T> {
    type Item = T

    fn next(&mut self) -> Option<T> {
        // ...
    }
}

// Where clauses
impl<T, U> Convert<U> for T
where
    T: Clone + Debug,
    U: From<T>
{
    // ...
}
```

### Import Declarations

```home
import basics/os/serial                    // Import module
import basics/os/serial { init, COM1 }     // Selective import
import std/http { get, post }              // Multiple imports
```

---

## Expressions

### Literals

```home
42              // Integer
3.14            // Float
"hello"         // String
true            // Boolean
[1, 2, 3]       // Array
(1, 2)          // Tuple
```

### Identifiers

```home
variable_name
my_function
CONSTANT_VALUE
```

### Operators

#### Arithmetic Operators
```home
x + y           // Addition
x - y           // Subtraction
x * y           // Multiplication
x / y           // Division
x % y           // Modulo
-x              // Negation
```

#### Comparison Operators
```home
x == y          // Equal
x != y          // Not equal
x < y           // Less than
x <= y          // Less or equal
x > y           // Greater than
x >= y          // Greater or equal
```

#### Logical Operators
```home
x && y          // Logical AND
x || y          // Logical OR
!x              // Logical NOT
x and y         // Alternative AND
x or y          // Alternative OR
```

#### Bitwise Operators
```home
x & y           // Bitwise AND
x | y           // Bitwise OR
x ^ y           // Bitwise XOR
~x              // Bitwise NOT
x << n          // Left shift
x >> n          // Right shift
```

#### Assignment Operators
```home
x = y           // Assignment
x += y          // Add assign (x = x + y)
x -= y          // Subtract assign
x *= y          // Multiply assign
x /= y          // Divide assign
x %= y          // Modulo assign
```

### Range Expressions

```home
0..10           // Exclusive range [0, 10)
0..=10          // Inclusive range [0, 10]
start..end      // Variable ranges
```

### Member Access

```home
point.x         // Field access
object.method() // Method call
```

### Index Expressions

```home
array[0]        // Index access
array[i]        // Variable index
```

### Slice Expressions

```home
array[0..5]     // Slice [0, 5)
array[0..=5]    // Slice [0, 5]
array[2..]      // Slice from index 2 to end
array[..5]      // Slice from start to 5
array[..]       // Full slice
```

### Call Expressions

```home
function()              // No arguments
function(arg)           // Single argument
function(arg1, arg2)    // Multiple arguments
```

### Ternary Expression

```home
condition ? true_val : false_val

// Examples:
let max = a > b ? a : b
let msg = is_ok ? "Success" : "Failure"
```

### Null Coalescing

```home
value ?? default

// Examples:
let x = null_value ?? 42
let name = user?.name ?? "Anonymous"
```

### Pipe Operator

```home
value |> function

// Examples:
5 |> double |> add_ten
data |> filter |> map |> reduce
```

### Safe Navigation

```home
object?.member      // Returns null if object is null
object?.method()    // Safe method call
```

### Spread Operator

```home
...array            // Spread array elements
...tuple            // Spread tuple elements
```

### Try Expression

```home
result?             // Propagate error (like Rust's ?)

// Example:
let data = fetch()?
let value = parse(data)?
```

### Await Expression

```home
await future

// Example:
let response = await fetch_data(url)
let json = await response.json()
```

### Comptime Expression

```home
comptime expr

// Example:
const SIZE = comptime calculate_size()
```

### Reflection Expressions

```home
@TypeOf(expr)               // Get type of expression
@sizeOf(Type)               // Get size in bytes
@alignOf(Type)              // Get alignment
@offsetOf(Type, "field")    // Get field offset
@typeInfo(Type)             // Get type metadata
@fieldName(Type, index)     // Get field name
@fieldType(Type, "field")   // Get field type
@intFromPtr(ptr)            // Convert pointer to integer
@ptrFromInt(int)            // Convert integer to pointer
@truncate(value)            // Truncate to smaller type
@as(Type, value)            // Explicit cast
@bitCast(value)             // Reinterpret bits
```

### Inline Assembly

```home
asm("cli")          // Disable interrupts
asm("hlt")          // Halt CPU
asm("outb %al, %dx") // Port I/O
```

### Macro Invocation

```home
println!("Hello")           // Macro call
debug!("value = {}", x)     // Macro with args
```

### Closures

```home
|| expr                         // No parameters
|x| expr                        // Single parameter
|x, y| expr                     // Multiple parameters
|x| { stmt; expr }             // Block body
|x: int| -> int { x + 1 }      // Type annotations
move |x| { x + captured }      // Move closure
```

---

## Statements

### Expression Statements

```home
function_call()
x = 10
x += 5
```

### Return Statements

```home
return                  // Return void
return value            // Return value
return x + y            // Return expression
```

### Let/Const Statements

```home
let x = 42
let mut y = 0
const MAX = 100
```

### Block Statements

```home
{
    let x = 10
    let y = 20
    x + y
}
```

### Control Flow Statements

#### If Statement

```home
if condition {
    // then branch
}

if condition {
    // then branch
} else {
    // else branch
}

if condition1 {
    // branch 1
} else if condition2 {
    // branch 2
} else {
    // branch 3
}
```

#### While Loop

```home
while condition {
    // body
}

// Example:
while i < 10 {
    print(i)
    i += 1
}
```

#### Loop (Infinite)

```home
loop {
    // infinite loop
    if condition {
        break
    }
}
```

#### Do-While Loop

```home
do {
    // body
} while condition

// Example:
do {
    count += 1
} while count < 10
```

#### For Loop

```home
for item in iterable {
    // body
}

// Examples:
for i in 0..10 {
    print(i)
}

for element in array {
    process(element)
}
```

#### Switch Statement

```home
switch value {
    case pattern1: {
        // body
    },
    case pattern2, pattern3: {
        // multiple patterns
    },
    default: {
        // default case
    }
}

// Example:
switch status {
    case 200: {
        print("OK")
    },
    case 404: {
        print("Not Found")
    },
    default: {
        print("Unknown status")
    }
}
```

#### Match Statement (Pattern Matching)

```home
match value {
    pattern1 => expr1,
    pattern2 if guard => expr2,
    _ => default_expr,
}

// Examples:
match option {
    Some(x) => x,
    None => 0,
}

match point {
    Point { x: 0, y: 0 } => "origin",
    Point { x, y } if x == y => "diagonal",
    Point { x, .. } => "on x axis",
    _ => "other",
}
```

#### Try-Catch-Finally Statement

```home
try {
    // may throw
} catch (error) {
    // handle error
} finally {
    // always executed
}

// Multiple catch clauses
try {
    risky_operation()
} catch (IOError) {
    // handle I/O error
} catch {
    // catch all
}
```

#### Defer Statement

```home
defer cleanup()     // Executed when scope exits

// Example:
{
    let file = open("data.txt")
    defer close(file)
    // file automatically closed on scope exit
}
```

---

## Pattern Matching

### Pattern Types

#### Literal Patterns

```home
match value {
    0 => "zero",
    1 => "one",
    42 => "the answer",
    _ => "other",
}
```

#### Identifier Pattern (Binding)

```home
match value {
    x => use(x),    // Binds value to x
}
```

#### Wildcard Pattern

```home
match value {
    _ => "ignored",
}
```

#### Tuple Patterns

```home
match pair {
    (0, 0) => "origin",
    (x, 0) => "x-axis",
    (0, y) => "y-axis",
    (x, y) => "point",
}
```

#### Array Patterns

```home
match array {
    [] => "empty",
    [x] => "single",
    [x, y] => "pair",
    [head, ..tail] => "head and tail",
}
```

#### Struct Patterns

```home
match point {
    Point { x: 0, y: 0 } => "origin",
    Point { x, y: 0 } => "on x-axis",
    Point { x, y } => "general point",
}

// Shorthand
match person {
    Person { name, age } => format("{} is {}", name, age),
}
```

#### Enum Patterns

```home
match option {
    Some(value) => use(value),
    None => default(),
}

match result {
    Ok(data) => process(data),
    Err(msg) => handle_error(msg),
}
```

#### Range Patterns

```home
match score {
    0..=59 => "F",
    60..=69 => "D",
    70..=79 => "C",
    80..=89 => "B",
    90..=100 => "A",
    _ => "invalid",
}
```

#### Or Patterns

```home
match value {
    1 | 2 | 3 => "low",
    4 | 5 | 6 => "medium",
    7 | 8 | 9 => "high",
    _ => "invalid",
}
```

#### Guards

```home
match point {
    Point { x, y } if x == y => "diagonal",
    Point { x, y } if x > y => "above diagonal",
    Point { x, y } => "below diagonal",
}
```

---

## Advanced Features

### Traits

```home
// Basic trait
trait Animal {
    fn make_sound(&self) -> string
}

// Associated types
trait Iterator {
    type Item
    fn next(&mut self) -> Option<Self::Item>
}

// Default implementations
trait Summary {
    fn summarize(&self) -> string {
        "Read more..."
    }
}

// Trait bounds
fn process<T: Display + Debug>(item: T) {
    // ...
}

// Where clauses
fn complex<T, U>(t: T, u: U)
where
    T: Clone + Debug,
    U: Iterator,
    U::Item: Display
{
    // ...
}

// Trait objects (dynamic dispatch)
fn draw(shapes: &[dyn Drawable]) {
    for shape in shapes {
        shape.draw()
    }
}
```

### Closures

```home
// Basic closures
let add = |a, b| a + b
let double = |x| x * 2

// Capture by reference
let value = 42
let closure = || value + 10

// Capture by mutable reference
let mut count = 0
let mut increment = || {
    count += 1
}

// Move closure (take ownership)
let data = vec![1, 2, 3]
let consume = move || {
    use(data)
}

// Returning closures
fn make_adder(x: int) -> impl Fn(int) -> int {
    move |y| x + y
}

// Higher-order functions
let doubled = numbers.map(|x| x * 2)
let evens = numbers.filter(|x| x % 2 == 0)
let sum = numbers.fold(0, |acc, x| acc + x)
```

### Async/Await

```home
// Async function
async fn fetch_user(id: int) -> Result<User> {
    let response = await http.get("/api/users/{id}")
    return await response.json()
}

// Async main
async fn main() {
    let user = await fetch_user(1)
    match user {
        Ok(u) => print("User: {u.name}"),
        Err(e) => print("Error: {e}"),
    }
}

// Concurrent operations
let (data1, data2) = await (
    fetch_data(url1),
    fetch_data(url2)
)
```

### Compile-Time Evaluation

```home
// Comptime expressions
const SIZE = comptime calculate_size()

// Comptime blocks
const TABLE = comptime {
    let mut table = []
    for i in 0..256 {
        table.push(compute(i))
    }
    table
}

// Type-level programming
fn generic<T>(value: T) {
    const TYPE_NAME = comptime @TypeOf(value)
    const SIZE = comptime @sizeOf(T)
}
```

### Generics

```home
// Generic functions
fn swap<T>(a: &mut T, b: &mut T) {
    let temp = *a
    *a = *b
    *b = temp
}

// Generic structs
struct Container<T> {
    value: T
}

// Multiple type parameters
struct Pair<T, U> {
    first: T,
    second: U
}

// Constrained generics
fn print_all<T: Display>(items: [T]) {
    for item in items {
        print(item)
    }
}
```

### Error Handling

```home
// Result type
enum Result<T, E> {
    Ok(T),
    Err(E)
}

// Try operator
fn process() -> Result<Data, Error> {
    let config = load_config()?
    let data = fetch_data(config)?
    return Ok(data)
}

// Try-catch
try {
    risky_operation()
} catch (error) {
    handle_error(error)
}
```

### Operator Overloading

```home
trait Add<Rhs = Self> {
    type Output
    fn add(self, rhs: Rhs) -> Self::Output
}

impl Add for Point {
    type Output = Point

    fn add(self, rhs: Point) -> Point {
        Point {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
        }
    }
}

// Usage: p1 + p2
```

### Variadic Functions

```home
fn print_all(args: ...string) {
    for arg in args {
        print(arg)
    }
}

// Call with variable args
print_all("hello", "world", "!")
```

### Default Parameters

```home
fn greet(name: string, greeting: string = "Hello") {
    print("{greeting}, {name}!")
}

// Calls
greet("Alice")              // "Hello, Alice!"
greet("Bob", "Hi")          // "Hi, Bob!"
```

### Named Parameters

```home
fn create_user(
    name: string,
    age: int,
    admin: bool = false
) -> User {
    // ...
}

// Named argument call
create_user(name: "Alice", age: 30, admin: true)
create_user(age: 25, name: "Bob")
```

### Struct Literals

```home
// Basic literal
let point = Point { x: 10, y: 20 }

// Field punning (shorthand)
let x = 5
let y = 10
let point = Point { x, y }  // Same as { x: x, y: y }

// Update syntax
let point2 = Point { x: 15, ..point }  // y from point

// Tuple struct literal
let color = Color(255, 128, 0)

// Anonymous struct
let config = struct {
    host: "localhost",
    port: 8080
}
```

### Array Comprehensions

```home
// Basic comprehension
let squares = [x * x for x in 0..10]

// With filter
let evens = [x for x in 0..20 if x % 2 == 0]

// Nested
let pairs = [(x, y) for x in 0..5 for y in 0..5]

// Dictionary comprehension
let dict = {k: v for (k, v) in pairs}
```

### Multiple Dispatch

```home
fn collide(a: Circle, b: Circle) {
    // Circle-Circle collision
}

fn collide(a: Circle, b: Rectangle) {
    // Circle-Rectangle collision
}

fn collide(a: Rectangle, b: Rectangle) {
    // Rectangle-Rectangle collision
}

// Calls dispatch to correct overload
collide(circle1, circle2)
collide(circle, rect)
```

---

## Syntax Summary Tables

### Operators by Precedence (Highest to Lowest)

| Precedence | Operators | Associativity | Example |
|------------|-----------|---------------|---------|
| 18 (Primary) | Literals, `()` | - | `42`, `"str"` |
| 17 (Call) | `.`, `()`, `[]`, `?.` | Left | `obj.field`, `fn()` |
| 16 (Unary) | `!`, `-`, `~`, `...` | Right | `-x`, `!flag` |
| 15 (Factor) | `*`, `/`, `%` | Left | `a * b` |
| 14 (Term) | `+`, `-` | Left | `a + b` |
| 13 (Shift) | `<<`, `>>` | Left | `x << 2` |
| 12 (Pipe) | `\|>` | Left | `x \|> f` |
| 11 (Range) | `..`, `..=` | - | `0..10` |
| 10 (Comparison) | `<`, `<=`, `>`, `>=` | Left | `a < b` |
| 9 (Equality) | `==`, `!=` | Left | `a == b` |
| 8 (BitAnd) | `&` | Left | `a & b` |
| 7 (BitXor) | `^` | Left | `a ^ b` |
| 6 (BitOr) | `\|` | Left | `a \| b` |
| 5 (And) | `&&` | Left | `a && b` |
| 4 (Or) | `\|\|` | Left | `a \|\| b` |
| 3 (Null Coalesce) | `??` | Left | `a ?? b` |
| 2 (Ternary) | `? :` | Right | `c ? a : b` |
| 1 (Assignment) | `=`, `+=`, `-=`, etc. | Right | `x = y` |

### All Operators Quick Reference

#### Arithmetic
- `+` Addition
- `-` Subtraction
- `*` Multiplication
- `/` Division
- `%` Modulo
- `-` Negation (unary)

#### Comparison
- `==` Equal
- `!=` Not equal
- `<` Less than
- `<=` Less or equal
- `>` Greater than
- `>=` Greater or equal

#### Logical
- `&&` Logical AND
- `||` Logical OR
- `!` Logical NOT
- `and` Alternative AND
- `or` Alternative OR

#### Bitwise
- `&` Bitwise AND
- `|` Bitwise OR
- `^` Bitwise XOR
- `~` Bitwise NOT
- `<<` Left shift
- `>>` Right shift

#### Assignment
- `=` Assign
- `+=` Add assign
- `-=` Subtract assign
- `*=` Multiply assign
- `/=` Divide assign
- `%=` Modulo assign

#### Special
- `.` Member access
- `?.` Safe navigation
- `??` Null coalescing
- `|>` Pipe
- `..` Range (exclusive)
- `..=` Range (inclusive)
- `...` Spread
- `? :` Ternary
- `?` Try
- `->` Function return type
- `@` Reflection/annotation

### Keywords by Category

#### Declaration Keywords
- `fn` - Function
- `struct` - Structure
- `enum` - Enumeration
- `union` - Discriminated union
- `trait` - Trait/interface
- `impl` - Implementation
- `type` - Type alias
- `let` - Variable binding
- `const` - Constant
- `mut` - Mutable modifier
- `import` - Module import

#### Control Flow
- `if` - Conditional
- `else` - Alternative branch
- `while` - While loop
- `for` - For loop
- `loop` - Infinite loop
- `do` - Do-while loop
- `match` - Pattern matching
- `switch` - Switch statement
- `case` - Switch case
- `default` - Default case
- `break` - Exit loop
- `continue` - Skip iteration
- `return` - Return from function

#### Error Handling
- `try` - Try block
- `catch` - Catch error
- `finally` - Finally block
- `defer` - Defer execution

#### Async/Concurrency
- `async` - Async function
- `await` - Await future

#### Types & Safety
- `unsafe` - Unsafe block
- `dyn` - Dynamic dispatch
- `where` - Where clause
- `Self` - Self type
- `self` - Self value

#### Compile-Time
- `comptime` - Compile-time evaluation
- `asm` - Inline assembly

#### Literals
- `true` - Boolean true
- `false` - Boolean false

#### Logical
- `and` - Logical AND
- `or` - Logical OR
- `in` - Membership test

---

## Considerations & Discussion Points

### 1. Keyword Density

**Current Count:** 52 keywords

**Question:** Is this the right balance?
- **Pro:** Comprehensive feature set
- **Con:** Large keyword count reduces available identifiers
- **Compare:**
  - Rust: ~40 keywords
  - Go: 25 keywords
  - C: 32 keywords
  - Zig: ~50 keywords

**Suggestions:**
- Consider making `and`/`or` non-keywords (use `&&`/`||` only)
- Evaluate necessity of both `const` and `comptime`
- Review if `unsafe` is needed in initial version

### 2. Operator Complexity

**Pipe Operator (`|>`)**
- Syntax: `value |> function`
- Precedence level: 12
- **Question:** Is this sufficiently distinct from bitwise OR (`|`)?
- **Suggestion:** Consider alternative syntax like `~>` or `=>` if ambiguity arises

**Null Coalescing (`??`)**
- Similar to JavaScript, TypeScript, C#
- **Question:** How does this interact with `?` (try operator)?
- **Consider:** `value?.field ?? default` - Is precedence clear?

**Safe Navigation (`?.`)**
- **Question:** Should this be an operator or method call syntax?
- **Compare:**
  - `object?.method()` (current)
  - `object.method()?` (alternative)

**Spread (`...`)**
- Used in arrays, function calls, destructuring
- **Question:** Is the syntax overloaded?
- **Example contexts:**
  - Array spread: `[...arr1, ...arr2]`
  - Function args: `fn(arg1, ...rest)`
  - Patterns: `[first, ...tail]`

### 3. String Interpolation

**Current:** Not clearly defined in examples
**Options:**
```home
// Option 1: Format strings (current approach?)
format("Hello, {}", name)
print("Value: {}", value)

// Option 2: String interpolation
"Hello, {name}"
"Value: {value}"

// Option 3: Template literals
`Hello, ${name}`
`Value: ${value}`
```

**Question:** Which syntax do we prefer?

### 4. Semicolons

**Observation:** Examples show inconsistent semicolon usage
```home
let x = 42          // No semicolon
return x + y        // No semicolon
function_call()     // No semicolon
```

**Question:** Are semicolons:
- Required?
- Optional (ASI like JavaScript)?
- Statement terminators or separators?

**Suggestion:** Define clear rules, preferably:
- Optional for simple statements
- Required for disambiguation

### 5. Closure Syntax

**Current Options:**
```home
|x| x + 1                           // Minimal
|x: int| -> int { x + 1 }          // Typed
move |x| { x + captured }          // Move
```

**Question:** Is `move` keyword necessary?
- **Pro:** Explicit ownership transfer
- **Con:** Extra syntax
- **Alternative:** Infer from capture usage

### 6. Type Inference vs Explicit Types

**Current:** Type annotations often optional
```home
let x = 42          // Inferred as int (i64?)
let y: i32 = 42     // Explicit
```

**Questions:**
- When is inference allowed?
- What is the default integer type? (i64 seems assumed)
- Should functions require return type annotations?

**Suggestion:** Document inference rules clearly

### 7. Trait Syntax Complexity

**Features:**
- Associated types: `type Item`
- Default implementations
- Trait bounds: `T: Trait`
- Where clauses
- Trait objects: `dyn Trait`

**Question:** Is this too complex for initial release?
**Suggestion:** Consider phased rollout:
- Phase 1: Basic traits
- Phase 2: Associated types
- Phase 3: Default impls, where clauses

### 8. Pattern Matching Completeness

**Current Support:**
- Literals, identifiers, wildcards
- Tuples, arrays (with rest)
- Structs (with shorthand)
- Enums
- Ranges
- Or patterns
- Guards

**Missing?**
- Nested patterns depth limit?
- Pattern aliases?
- `@` bindings (like Rust)?

**Example:**
```rust
// Rust style
Some(x @ 1..=10) => println!("x is {}", x)
```

### 9. Error Handling Dual System

**Two approaches:**
1. **Result + Try operator** (`?`)
```home
fn process() -> Result<T, E> {
    let data = fetch()?
    return Ok(data)
}
```

2. **Try-Catch blocks**
```home
try {
    let data = fetch()
} catch (e) {
    handle(e)
}
```

**Question:** Should we support both?
- **Pro:** Flexibility for different scenarios
- **Con:** Two ways to do the same thing
- **Suggestion:** Prefer Result/Try for library code, try-catch for application code?

### 10. Async Syntax

**Current:**
```home
async fn fetch() -> Result<Data>
let data = await fetch()
```

**Questions:**
- Can await be used outside async contexts?
- Is `await` a keyword or operator?
- How does error propagation work with async?
```home
let data = await fetch()?  // Valid?
```

### 11. Comptime vs Const

**Two keywords:**
- `const` - Compile-time constant
- `comptime` - Compile-time execution

**Question:** Are both needed?
```home
const VALUE = 42                    // Constant
const TABLE = comptime generate()   // Computed constant
```

**Alternative:** Single keyword?
```home
const VALUE = 42
const TABLE = generate()  // Auto-detected as comptime?
```

### 12. Mutability Syntax

**Current:** `let mut x`
**Alternative options:**
- `var x` vs `let x` (JavaScript style)
- `mut x` vs `x` (different default)

**Question:** Is `let mut` the clearest syntax?
- **Pro:** Clear distinction, matches Rust
- **Con:** More verbose than `var`

### 13. Import System

**Current:**
```home
import basics/os/serial
import basics/os/serial { init, COM1 }
```

**Questions:**
- How to import from subdirectories?
- Is there aliasing? `import foo as bar`?
- Re-exports? `pub import`?
- Relative imports? `import ./local`?

### 14. Reflection Syntax

**Current:** Extensive reflection with `@` prefix
```home
@TypeOf(x)
@sizeOf(T)
@offsetOf(T, "field")
```

**Question:** Is this Zig-like approach preferred?
**Alternative:** Built-in methods?
```home
x.type_of()
T.size_of()
```

### 15. Module System

**Not clearly defined:**
- How to export/make public?
- Module privacy?
- Nested modules?
- Package structure?

**Suggestion:** Define:
```home
// Visibility modifiers?
pub fn public_function() {}
fn private_function() {}

pub struct PublicStruct {}
```

### 16. Comments Documentation

**Current:** Basic comments only
**Missing:**
- Doc comments (like `///` in Rust)
- Markdown in docs?
- Attribute macros for docs?

**Suggestion:**
```home
/// This is a doc comment
/// # Examples
/// ```
/// let x = add(2, 3)
/// ```
fn add(a: int, b: int) -> int {
    return a + b
}
```

### 17. Attribute System

**Current:** Only `@test` shown
**Questions:**
- Other attributes needed?
  - `@deprecated`
  - `@inline`
  - `@must_use`
  - `@derive`
- Syntax for custom attributes?

### 18. String Escapes

**Current support:**
- Basic: `\n \t \r \" \\ \' \0`
- Hex: `\xNN`
- Unicode: `\u{NNNN}`

**Missing:**
- Raw strings? (no escaping)
```home
r"C:\path\to\file"      // Raw string
r#"String with "quotes""#  // Rust-style
```

### 19. Numeric Literals

**Missing:**
- Binary: `0b1010`
- Octal: `0o755`
- Hex: `0xFF`
- Underscores for readability: `1_000_000`
- Type suffixes: `42u64`, `3.14f32`

**Suggestion:** Add these for completeness

### 20. Array/Collection Literals

**Current:** Basic arrays only
**Missing:**
- Maps/Dictionaries?
```home
let map = { "key": "value", "foo": "bar" }
```
- Sets?
```home
let set = { 1, 2, 3, 4, 5 }
```

### 21. Operator Overloading Scope

**Question:** Which operators can be overloaded?
- Arithmetic: `+ - * / %`
- Comparison: `== != < > <= >=`
- Indexing: `[]`
- Call: `()`

**Missing from examples:**
- Custom indexing
- Call operator
- Conversion operators

### 22. Type Conversions

**Current:** Reflection-based?
```home
@as(Type, value)    // Explicit cast
```

**Alternative patterns:**
```home
value as Type       // Rust-style
Type(value)         // Constructor-style
value.into<Type>()  // Method-style
```

**Question:** What's the preferred idiom?

### 23. Visibility & Encapsulation

**Not defined:**
- Public/private
- Module-level privacy
- Struct field visibility
- Trait method visibility

**Critical for:** Library development

### 24. Lifetime Annotations

**Not shown in examples**
**Question:** Are lifetimes needed?
- Zig doesn't have them
- Rust requires them

**If borrowing is supported, lifetimes may be necessary:**
```home
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str
```

### 25. Memory Management

**Not clear from syntax:**
- Reference counting?
- Manual allocation?
- RAII?
- Ownership rules?

**Example patterns not shown:**
```home
let box = Box::new(value)   // Heap allocation?
let rc = Rc::new(value)     // Reference counting?
```

---

## Syntax Comparison with Other Languages

### Home vs Rust

| Feature | Home | Rust |
|---------|------|------|
| Variables | `let x = 42` | `let x = 42;` |
| Mutable | `let mut x = 0` | `let mut x = 0;` |
| Functions | `fn add(x: int) -> int` | `fn add(x: i32) -> i32` |
| Closures | `\|x\| x + 1` | `\|x\| x + 1` |
| Pattern Match | `match x { ... }` | `match x { ... }` |
| Error Propagation | `result?` | `result?` |
| Ranges | `0..10`, `0..=10` | `0..10`, `0..=10` |
| Traits | `trait Name { ... }` | `trait Name { ... }` |

**Similarities:** Very high - Home is heavily Rust-inspired
**Key Differences:**
- Semicolons optional in Home
- Different type names (`int` vs `i32`)
- Null coalescing (`??`) not in Rust

### Home vs Zig

| Feature | Home | Zig |
|---------|------|------|
| Variables | `let x = 42` | `var x: i32 = 42;` |
| Constants | `const X = 42` | `const X = 42;` |
| Comptime | `comptime expr` | `comptime expr` |
| Reflection | `@TypeOf(x)` | `@TypeOf(x)` |
| Error Union | `Result<T, E>` | `!T` (error union) |
| Functions | `fn foo() -> int` | `fn foo() i32` |

**Similarities:** Comptime and reflection syntax
**Key Differences:**
- Home has traits, Zig doesn't
- Different error handling models
- Home has closures, Zig doesn't

### Home vs TypeScript

| Feature | Home | TypeScript |
|---------|------|------------|
| Variables | `let x = 42` | `let x = 42` |
| Constants | `const X = 42` | `const X = 42` |
| Functions | `fn add(x: int) -> int` | `function add(x: number): number` |
| Optional | `Option<T>` | `T \| null \| undefined` |
| Null Coalesce | `a ?? b` | `a ?? b` |
| Safe Nav | `obj?.field` | `obj?.field` |
| Pipe | `x \|> f` | N/A |

**Similarities:** Modern operator set (`??`, `?.`)
**Key Differences:**
- Home is compiled, typed systems language
- Different error handling philosophy

---

## Summary Statistics

### Language Features Count
- **Keywords:** 52
- **Operators:** 30+
- **Built-in Types:** 15+
- **Expression Types:** 30+
- **Statement Types:** 15+
- **Pattern Types:** 8+
- **Advanced Features:** 12+

### Complexity Metrics
- **Operator Precedence Levels:** 18
- **Pattern Matching Depth:** Deep (nested patterns supported)
- **Generic Type Parameters:** Unlimited
- **Trait Constraints:** Multiple with where clauses

---

## Recommendations for Team Discussion

### High Priority

1. **Semicolon Rules** - Define clearly (required, optional, ASI?)
2. **String Interpolation** - Choose syntax and implement
3. **Visibility Modifiers** - Design pub/private system
4. **Module System** - Complete design with examples
5. **Type Inference Rules** - Document when/where allowed
6. **Default Integer Type** - Clarify (i64, i32, or context-dependent?)

### Medium Priority

7. **Numeric Literal Extensions** - Add hex, binary, underscores
8. **Raw String Literals** - Consider adding
9. **Collection Literals** - Design map/dict/set syntax
10. **Documentation Comments** - Add doc comment syntax
11. **Attribute System** - Expand beyond @test
12. **Operator Overloading Scope** - Define all overloadable operators

### Low Priority

13. **Keyword Consolidation** - Review and/or, comptime/const
14. **Closure Move Inference** - Consider inferring instead of explicit
15. **Alternative Operators** - Review pipe operator distinctness
16. **Pattern Match Extensions** - Consider @ bindings
17. **Error Handling Strategy** - Document when to use Result vs try-catch
18. **Memory Model** - Define ownership rules more explicitly

### Future Considerations

19. **Lifetime Annotations** - Determine if needed
20. **Trait System Phasing** - Consider gradual rollout
21. **Async Error Propagation** - Define `await fetch()?` behavior
22. **Reflection API Expansion** - Plan additional reflection features

---

## Example Programs Demonstrating Full Syntax

### Example 1: Complete Feature Showcase

```home
// Import with selective imports
import std/io { print, println }
import std/collections { Vec, HashMap }

// Type alias
type UserId = u64

// Struct with generics
struct User<T> {
    id: UserId,
    name: string,
    data: T
}

// Enum with data
enum Status {
    Active,
    Pending(string),
    Completed(i32)
}

// Trait definition
trait Displayable {
    fn display(&self) -> string
}

// Trait implementation
impl<T> Displayable for User<T> {
    fn display(&self) -> string {
        return "User: {self.name}"
    }
}

// Async function with error handling
async fn fetch_user(id: UserId) -> Result<User<string>, string> {
    let response = await http.get("/api/users/{id}")?
    let data = await response.json()?
    return Ok(data)
}

// Function with generics and trait bounds
fn process<T: Displayable>(items: [T]) {
    for item in items {
        println(item.display())
    }
}

// Comptime constant
const MAX_USERS = comptime calculate_limit()

// Main function demonstrating control flow
fn main() -> int {
    // Variable declarations
    let mut count = 0
    const threshold = 10

    // Ternary expression
    let message = count > 5 ? "High" : "Low"

    // Null coalescing
    let value = optional_value ?? 42

    // Pipe operator
    let result = value |> double |> add_ten

    // Array with range
    let numbers = [1, 2, 3, 4, 5]
    let range = 0..10

    // Array comprehension
    let squares = [x * x for x in numbers]

    // Closure
    let add = |a, b| a + b

    // Pattern matching
    match status {
        Active => println("Active"),
        Pending(msg) => println("Pending: {msg}"),
        Completed(code) if code > 0 => println("Success"),
        Completed(_) => println("Failed"),
    }

    // Try-catch with finally
    try {
        risky_operation()
    } catch (error) {
        handle_error(error)
    } finally {
        cleanup()
    }

    // Do-while loop
    do {
        count += 1
    } while count < threshold

    // Defer
    defer close_resources()

    return 0
}

// Test function
@test
fn test_addition() {
    assert(add(2, 2) == 4)
}
```

### Example 2: Advanced Features

```home
// Closure with move semantics
fn make_counter() -> impl Fn() -> int {
    let mut count = 0
    return move || {
        count += 1
        count
    }
}

// Higher-order function
fn map<T, U>(arr: [T], f: fn(T) -> U) -> [U] {
    let mut result = []
    for item in arr {
        result.push(f(item))
    }
    return result
}

// Trait with associated type and where clause
trait Container
where
    Self::Item: Display
{
    type Item
    fn get(&self, index: int) -> Option<Self::Item>
}

// Operator overloading
impl Add for Vector {
    type Output = Vector

    fn add(self, other: Vector) -> Vector {
        Vector {
            x: self.x + other.x,
            y: self.y + other.y
        }
    }
}

// Reflection usage
fn print_type_info<T>() {
    const TYPE = @TypeOf(T)
    const SIZE = @sizeOf(T)
    const ALIGN = @alignOf(T)

    println("Type: {TYPE}")
    println("Size: {SIZE} bytes")
    println("Alignment: {ALIGN} bytes")
}

// Inline assembly (low-level)
fn disable_interrupts() {
    asm("cli")
}
```

---

**Document End**

This comprehensive review captures all known syntax and grammar features of the Home programming language. Use this as a reference for team discussions about potential improvements, clarifications, or changes to the language design.
