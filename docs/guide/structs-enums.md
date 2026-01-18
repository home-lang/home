# Structs and Enums

Home provides powerful data structures through structs and enums, supporting methods, generics, and algebraic data types.

## Structs

Structs group related data together:

### Basic Struct Definition

```home
struct Point {
  x: int,
  y: int
}

struct User {
  id: i64,
  name: string,
  email: string
}
```

### Creating Struct Instances

```home
let origin = Point { x: 0, y: 0 }
let user = User {
  id: 1,
  name: "Alice",
  email: "alice@example.com"
}

// Field shorthand when variable names match
let name = "Bob"
let email = "bob@example.com"
let bob = User { id: 2, name, email }
```

### Accessing Fields

```home
let p = Point { x: 10, y: 20 }
print("x = {p.x}, y = {p.y}")

// Nested access
struct Rectangle {
  top_left: Point,
  bottom_right: Point
}

let rect = Rectangle {
  top_left: Point { x: 0, y: 0 },
  bottom_right: Point { x: 100, y: 50 }
}

print("Width: {rect.bottom_right.x - rect.top_left.x}")
```

### Mutable Structs

```home
let mut point = Point { x: 0, y: 0 }
point.x = 10
point.y = 20
```

## Methods

Add behavior to structs with `impl` blocks:

```home
struct Rectangle {
  width: int,
  height: int
}

impl Rectangle {
  // Associated function (constructor)
  fn new(width: int, height: int): Rectangle {
    Rectangle { width, height }
  }

  // Method (takes self)
  fn area(self): int {
    self.width * self.height
  }

  fn perimeter(self): int {
    2 * (self.width + self.height)
  }

  // Mutable method
  fn scale(mut self, factor: int) {
    self.width *= factor
    self.height *= factor
  }

  fn is_square(self): bool {
    self.width == self.height
  }
}

// Usage
let rect = Rectangle.new(10, 5)
print("Area: {rect.area()}")          // 50
print("Perimeter: {rect.perimeter()}")  // 30
print("Is square: {rect.is_square()}")  // false

let mut square = Rectangle.new(5, 5)
square.scale(2)
print("Scaled: {square.width}x{square.height}")  // 10x10
```

### Self References

```home
impl Point {
  // Immutable borrow of self
  fn distance_from_origin(&self): float {
    ((self.x * self.x + self.y * self.y) as float).sqrt()
  }

  // Mutable borrow of self
  fn translate(&mut self, dx: int, dy: int) {
    self.x += dx
    self.y += dy
  }

  // Takes ownership of self
  fn into_tuple(self): (int, int) {
    (self.x, self.y)
  }
}
```

## Generic Structs

Structs can be parameterized over types:

```home
struct Pair<T> {
  first: T,
  second: T
}

struct Container<T, U> {
  key: T,
  value: U
}

let pair = Pair { first: 1, second: 2 }
let container = Container { key: "name", value: 42 }
```

### Generic Methods

```home
struct Stack<T> {
  items: []T
}

impl<T> Stack<T> {
  fn new(): Stack<T> {
    Stack { items: [] }
  }

  fn push(mut self, item: T) {
    self.items.append(item)
  }

  fn pop(mut self): Option<T> {
    self.items.pop()
  }

  fn is_empty(self): bool {
    self.items.len() == 0
  }

  fn len(self): int {
    self.items.len()
  }
}

let mut stack = Stack<int>.new()
stack.push(1)
stack.push(2)
stack.push(3)
let top = stack.pop()  // Some(3)
```

## Enums

Enums define types with a fixed set of variants:

### Simple Enums

```home
enum Color {
  Red,
  Green,
  Blue
}

let color = Color.Red

match color {
  Color.Red => print("red"),
  Color.Green => print("green"),
  Color.Blue => print("blue")
}
```

### Enums with Data

```home
enum Message {
  Quit,
  Move(x: int, y: int),
  Write(string),
  ChangeColor(int, int, int)
}

let msg = Message.Move(10, 20)

match msg {
  Message.Quit => print("Quit"),
  Message.Move(x, y) => print("Move to ({x}, {y})"),
  Message.Write(text) => print("Write: {text}"),
  Message.ChangeColor(r, g, b) => print("Color: rgb({r}, {g}, {b})")
}
```

### Generic Enums

```home
enum Option<T> {
  Some(T),
  None
}

enum Result<T, E> {
  Ok(T),
  Err(E)
}

let value: Option<int> = Option.Some(42)
let result: Result<string, Error> = Result.Ok("success")
```

### Enum Methods

```home
enum Option<T> {
  Some(T),
  None
}

impl<T> Option<T> {
  fn is_some(self): bool {
    match self {
      Option.Some(_) => true,
      Option.None => false
    }
  }

  fn is_none(self): bool {
    !self.is_some()
  }

  fn unwrap(self): T {
    match self {
      Option.Some(value) => value,
      Option.None => panic("Called unwrap on None")
    }
  }

  fn unwrap_or(self, default: T): T {
    match self {
      Option.Some(value) => value,
      Option.None => default
    }
  }

  fn map<U>(self, f: fn(T): U): Option<U> {
    match self {
      Option.Some(value) => Option.Some(f(value)),
      Option.None => Option.None
    }
  }
}
```

## Algebraic Data Types

Combine enums and structs for powerful type modeling:

```home
// A linked list
enum List<T> {
  Cons(T, Box<List<T>>),
  Nil
}

// A binary tree
enum Tree<T> {
  Node(T, Box<Tree<T>>, Box<Tree<T>>),
  Leaf
}

// Expression AST
enum Expr {
  Number(int),
  Add(Box<Expr>, Box<Expr>),
  Subtract(Box<Expr>, Box<Expr>),
  Multiply(Box<Expr>, Box<Expr>),
  Divide(Box<Expr>, Box<Expr>)
}

fn evaluate(expr: Expr): int {
  match expr {
    Expr.Number(n) => n,
    Expr.Add(a, b) => evaluate(*a) + evaluate(*b),
    Expr.Subtract(a, b) => evaluate(*a) - evaluate(*b),
    Expr.Multiply(a, b) => evaluate(*a) * evaluate(*b),
    Expr.Divide(a, b) => evaluate(*a) / evaluate(*b)
  }
}
```

## Tuple Structs

Structs with unnamed fields:

```home
struct Point2D(int, int)
struct Color(u8, u8, u8)

let point = Point2D(10, 20)
let red = Color(255, 0, 0)

print("x = {point.0}, y = {point.1}")
print("R = {red.0}")
```

## Unit Structs

Structs with no fields:

```home
struct Marker

impl Marker {
  fn describe() {
    print("I'm a marker type")
  }
}
```

## Struct Update Syntax

Create a new struct based on an existing one:

```home
let user1 = User {
  id: 1,
  name: "Alice",
  email: "alice@example.com"
}

// Create user2 with same email but different name
let user2 = User {
  id: 2,
  name: "Bob",
  ..user1  // Copy remaining fields from user1
}
```

## Visibility

Control access to struct fields:

```home
struct Config {
  pub name: string,      // Public
  secret_key: string     // Private (default)
}

impl Config {
  pub fn new(name: string, key: string): Config {
    Config { name, secret_key: key }
  }

  pub fn get_name(self): string {
    self.name
  }

  // Private method
  fn validate(self): bool {
    self.secret_key.len() >= 16
  }
}
```

## Pattern Matching with Structs

Destructure structs in patterns:

```home
struct Point { x: int, y: int }

let point = Point { x: 10, y: 20 }

match point {
  Point { x: 0, y: 0 } => print("origin"),
  Point { x: 0, y } => print("on y-axis at {y}"),
  Point { x, y: 0 } => print("on x-axis at {x}"),
  Point { x, y } if x == y => print("on diagonal"),
  Point { x, y } => print("at ({x}, {y})")
}

// Destructuring in let
let Point { x, y } = point
print("x = {x}, y = {y}")

// Ignoring fields
let Point { x, .. } = point
print("x = {x}")
```

## Next Steps

- [Traits](/guide/traits) - Define shared behavior for types
- [Error Handling](/guide/error-handling) - Using Result and Option types
- [Memory Safety](/guide/memory) - Ownership and borrowing
