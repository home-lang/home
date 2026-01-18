# Functions

Functions are the building blocks of Home programs. They support type inference, default parameters, generics, and more.

## Function Definition

Basic function syntax:

```home
fn greet(name: string) {
  print("Hello, {name}!")
}

fn add(a: int, b: int): int {
  return a + b
}
```

### Return Types

Return types can be explicit or inferred:

```home
// Explicit return type
fn multiply(a: int, b: int): int {
  return a * b
}

// Inferred return type
fn divide(a: float, b: float) {
  return a / b  // Return type inferred as float
}

// No return value (void)
fn log_message(msg: string): void {
  print("[LOG] {msg}")
}

// Implicit void
fn say_hello() {
  print("Hello!")
}
```

## Parameters

### Required Parameters

All parameters are required by default:

```home
fn create_user(name: string, age: int, email: string): User {
  return User { name, age, email }
}

// Must provide all arguments
let user = create_user("Alice", 30, "alice@example.com")
```

### Default Parameters

Parameters can have default values:

```home
fn greet(name: string = "World") {
  print("Hello, {name}!")
}

greet()           // Hello, World!
greet("Alice")    // Hello, Alice!

fn create_user(
  name: string,
  age: int = 0,
  active: bool = true
): User {
  return User { name, age, active }
}

let user1 = create_user("Bob")              // age=0, active=true
let user2 = create_user("Charlie", 25)      // active=true
let user3 = create_user("Dave", 30, false)  // all specified
```

### Named Arguments

Call functions with named arguments for clarity:

```home
fn create_rect(x: int, y: int, width: int, height: int): Rect {
  return Rect { x, y, width, height }
}

// Positional arguments
let r1 = create_rect(10, 20, 100, 50)

// Named arguments
let r2 = create_rect(x: 10, y: 20, width: 100, height: 50)

// Named arguments in any order
let r3 = create_rect(width: 100, height: 50, x: 10, y: 20)

// Mix positional and named
let r4 = create_rect(10, 20, width: 100, height: 50)
```

### Named-Only Parameters

Use `*` to require named arguments:

```home
fn connect(
  host: string,
  port: int = 8080,
  *,  // Everything after this must be named
  timeout: int = 30,
  retries: int = 3,
  ssl: bool = false
): Connection {
  // ...
}

// These work:
let c1 = connect("localhost")
let c2 = connect("localhost", 3000)
let c3 = connect("localhost", timeout: 60, ssl: true)

// This fails (timeout must be named):
// let c4 = connect("localhost", 3000, 60)
```

## Generic Functions

Functions can be parameterized over types:

```home
fn identity<T>(value: T): T {
  return value
}

let x = identity(42)        // T = int
let s = identity("hello")   // T = string

fn swap<T>(a: T, b: T): (T, T) {
  return (b, a)
}

let (x, y) = swap(1, 2)     // (2, 1)
```

### Multiple Type Parameters

```home
fn map<T, U>(items: []T, f: fn(T): U): []U {
  let result = []U.init(items.len)
  for (i, item in items) {
    result[i] = f(item)
  }
  return result
}

let numbers = [1, 2, 3, 4, 5]
let doubled = map(numbers, |x| x * 2)  // [2, 4, 6, 8, 10]
let strings = map(numbers, |x| "{x}")  // ["1", "2", "3", "4", "5"]
```

### Trait Bounds

Constrain generic types with traits:

```home
fn print_all<T: Display>(items: []T) {
  for (item in items) {
    print("{item}")
  }
}

fn max<T: Ord>(a: T, b: T): T {
  if (a > b) { a } else { b }
}

// Multiple bounds
fn process<T: Clone + Debug>(item: T) {
  let copy = item.clone()
  print("{:?}", copy)
}
```

## Higher-Order Functions

Functions can take functions as parameters:

```home
fn apply(x: int, f: fn(int): int): int {
  return f(x)
}

fn double(x: int): int {
  return x * 2
}

let result = apply(5, double)  // 10
```

### Returning Functions

```home
fn make_adder(x: int): fn(int): int {
  return |y| x + y
}

let add_5 = make_adder(5)
let add_10 = make_adder(10)

print(add_5(3))   // 8
print(add_10(3))  // 13
```

## Closures

Anonymous functions that capture their environment:

```home
// Basic closure
let double = |x| x * 2
let sum = |a, b| a + b

// With type annotations
let multiply = |a: int, b: int|: int {
  a * b
}

// Multi-line closure
let complex = |x| {
  let y = x * 2
  let z = y + 1
  z
}
```

### Capturing Variables

Closures capture variables from their enclosing scope:

```home
let multiplier = 3
let multiply = |x| x * multiplier  // Captures 'multiplier'

print(multiply(5))  // 15
```

### Mutable Captures

```home
let mut count = 0

let increment = || {
  count += 1
  print("Count: {count}")
}

increment()  // Count: 1
increment()  // Count: 2
increment()  // Count: 3
```

### Move Closures

Use `move` to transfer ownership into the closure:

```home
let data = [1, 2, 3, 4, 5]
let name = "Numbers"

let consume = move || {
  print("{name}: {data}")
  let sum = data.iter().sum()
  print("Sum: {sum}")
}

consume()
// data and name are no longer accessible here
```

## Method Syntax

Functions can be defined as methods on structs:

```home
struct Point {
  x: int,
  y: int
}

impl Point {
  // Associated function (no self)
  fn origin(): Point {
    Point { x: 0, y: 0 }
  }

  // Method (takes self)
  fn distance_from_origin(self): float {
    ((self.x * self.x + self.y * self.y) as float).sqrt()
  }

  // Mutable method
  fn translate(mut self, dx: int, dy: int) {
    self.x += dx
    self.y += dy
  }
}

let p = Point.origin()
let dist = p.distance_from_origin()
```

## Recursion

Functions can call themselves:

```home
fn factorial(n: int): int {
  if (n <= 1) {
    return 1
  }
  return n * factorial(n - 1)
}

print(factorial(5))  // 120
```

### Tail Recursion

Home optimizes tail-recursive functions:

```home
fn factorial_tail(n: int, acc: int = 1): int {
  if (n <= 1) {
    return acc
  }
  return factorial_tail(n - 1, n * acc)  // Tail position
}
```

## Function Composition

Combine functions to create new ones:

```home
fn compose<F, G, A, B, C>(f: F, g: G): fn(A): C
where
  F: Fn(B): C,
  G: Fn(A): B
{
  move |x| f(g(x))
}

let add_one = |x| x + 1
let double = |x| x * 2

let add_then_double = compose(double, add_one)
print(add_then_double(5))  // 12 = (5 + 1) * 2
```

## Async Functions

See the [Async Programming](/guide/async) guide for details on async functions:

```home
fn fetch_data(): async Result<Data> {
  let response = await http.get("/api/data")
  return response.json()
}
```

## Next Steps

- [Control Flow](/guide/control-flow) - Conditionals and loops
- [Error Handling](/guide/error-handling) - Result types and error propagation
- [Traits](/guide/traits) - Define shared behavior
