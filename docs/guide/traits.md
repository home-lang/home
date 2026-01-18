# Traits

Traits define shared behavior that types can implement. They enable polymorphism, operator overloading, and generic programming.

## Defining Traits

### Basic Trait Definition

```home
trait Animal {
  fn make_sound(&self): string
  fn get_name(&self): string
}
```

### Implementing Traits

```home
struct Dog {
  name: string
}

struct Cat {
  name: string
}

impl Animal for Dog {
  fn make_sound(&self): string {
    "Woof!"
  }

  fn get_name(&self): string {
    self.name
  }
}

impl Animal for Cat {
  fn make_sound(&self): string {
    "Meow!"
  }

  fn get_name(&self): string {
    self.name
  }
}
```

### Using Traits

```home
fn greet_animal(animal: &dyn Animal) {
  print("{} says {}", animal.get_name(), animal.make_sound())
}

let dog = Dog { name: "Buddy" }
let cat = Cat { name: "Whiskers" }

greet_animal(&dog)  // Buddy says Woof!
greet_animal(&cat)  // Whiskers says Meow!
```

## Default Implementations

Traits can provide default method implementations:

```home
trait Summary {
  fn summarize_author(&self): string

  // Default implementation
  fn summarize(&self): string {
    "Read more from " + self.summarize_author() + "..."
  }
}

struct Article {
  author: string,
  title: string,
  content: string
}

struct Tweet {
  username: string,
  content: string
}

impl Summary for Article {
  fn summarize_author(&self): string {
    self.author
  }

  // Override default
  fn summarize(&self): string {
    self.title + " by " + self.author
  }
}

impl Summary for Tweet {
  fn summarize_author(&self): string {
    "@" + self.username
  }
  // Uses default summarize()
}
```

## Associated Types

Traits can have associated types:

```home
trait Iterator {
  type Item

  fn next(&mut self): Option<Self::Item>
}

struct Counter {
  count: u32,
  max: u32
}

impl Iterator for Counter {
  type Item = u32

  fn next(&mut self): Option<u32> {
    if (self.count < self.max) {
      self.count += 1
      Some(self.count)
    } else {
      None
    }
  }
}
```

## Trait Bounds

Constrain generic types with traits:

### Basic Bounds

```home
fn print_summary<T: Summary>(item: &T) {
  print("Summary: {}", item.summarize())
}
```

### Multiple Bounds

```home
fn print_details<T: Summary + Display>(item: &T) {
  print("Display: {}", item)
  print("Summary: {}", item.summarize())
}
```

### Where Clauses

For complex bounds:

```home
fn complex_function<T, U>(t: T, u: U)
where
  T: Clone + Debug,
  U: Clone + Debug
{
  let t_copy = t.clone()
  let u_copy = u.clone()

  print("T: {:?}", t_copy)
  print("U: {:?}", u_copy)
}
```

## Trait Inheritance

Traits can extend other traits:

```home
trait Shape {
  fn area(&self): f64
}

trait Colored {
  fn color(&self): string
}

trait ColoredShape: Shape + Colored {
  fn describe(&self): string {
    "A " + self.color() + " shape with area " + self.area().to_string()
  }
}

struct ColoredCircle {
  radius: f64,
  color: string
}

impl Shape for ColoredCircle {
  fn area(&self): f64 {
    3.14159 * self.radius * self.radius
  }
}

impl Colored for ColoredCircle {
  fn color(&self): string {
    self.color
  }
}

impl ColoredShape for ColoredCircle {}
```

## Generic Traits

Traits can be generic:

```home
trait Add<Rhs = Self> {
  type Output

  fn add(self, rhs: Rhs): Self::Output
}

struct Point {
  x: f64,
  y: f64
}

// Point + Point
impl Add for Point {
  type Output = Point

  fn add(self, rhs: Point): Point {
    Point {
      x: self.x + rhs.x,
      y: self.y + rhs.y
    }
  }
}

// Point + f64 (scalar)
impl Add<f64> for Point {
  type Output = Point

  fn add(self, scalar: f64): Point {
    Point {
      x: self.x + scalar,
      y: self.y + scalar
    }
  }
}
```

## Trait Objects

Use dynamic dispatch with trait objects:

```home
trait Drawable {
  fn draw(&self)
}

struct Circle {
  x: f64,
  y: f64,
  radius: f64
}

struct Rectangle {
  x: f64,
  y: f64,
  width: f64,
  height: f64
}

impl Drawable for Circle {
  fn draw(&self) {
    print("Drawing circle at ({}, {}) with radius {}",
          self.x, self.y, self.radius)
  }
}

impl Drawable for Rectangle {
  fn draw(&self) {
    print("Drawing rectangle at ({}, {}) with size {}x{}",
          self.x, self.y, self.width, self.height)
  }
}

fn render_all(shapes: &[&dyn Drawable]) {
  for (shape in shapes) {
    shape.draw()
  }
}
```

## Standard Traits

### Clone and Copy

```home
trait Clone {
  fn clone(&self): Self
}

trait Copy: Clone {}  // Marker trait

#[derive(Clone, Copy)]
struct Point {
  x: i32,
  y: i32
}
```

### Debug and Display

```home
trait Display {
  fn fmt(&self): string
}

trait Debug {
  fn debug_fmt(&self): string
}

impl Display for Point {
  fn fmt(&self): string {
    "({}, {})".format(self.x, self.y)
  }
}

impl Debug for Point {
  fn debug_fmt(&self): string {
    "Point { x: {}, y: {} }".format(self.x, self.y)
  }
}
```

### From and Into

```home
trait From<T> {
  fn from(value: T): Self
}

trait Into<T> {
  fn into(self): T
}

// Blanket implementation
impl<T, U> Into<U> for T where U: From<T> {
  fn into(self): U {
    U.from(self)
  }
}

struct Celsius(f64)
struct Fahrenheit(f64)

impl From<Fahrenheit> for Celsius {
  fn from(f: Fahrenheit): Celsius {
    Celsius((f.0 - 32.0) * 5.0 / 9.0)
  }
}

let f = Fahrenheit(98.6)
let c: Celsius = f.into()  // Uses Into trait
```

### Eq and Ord

```home
trait PartialEq {
  fn eq(&self, other: &Self): bool

  fn ne(&self, other: &Self): bool {
    !self.eq(other)
  }
}

trait Eq: PartialEq {}

trait PartialOrd: PartialEq {
  fn partial_cmp(&self, other: &Self): Option<Ordering>
}

trait Ord: Eq + PartialOrd {
  fn cmp(&self, other: &Self): Ordering
}
```

## Derive Macros

Automatically implement common traits:

```home
#[derive(Debug, Clone, PartialEq, Eq)]
struct User {
  id: i64,
  name: string,
  email: string
}

let user1 = User { id: 1, name: "Alice", email: "alice@example.com" }
let user2 = user1.clone()

print("{:?}", user1)           // Debug output
print("Equal: {}", user1 == user2)  // true
```

## Builder Pattern

Using traits for builders:

```home
trait Builder {
  type Output

  fn build(self): Self::Output
}

struct UserBuilder {
  name: Option<string>,
  email: Option<string>,
  age: Option<u32>
}

impl UserBuilder {
  fn new(): UserBuilder {
    UserBuilder { name: None, email: None, age: None }
  }

  fn name(mut self, name: string): UserBuilder {
    self.name = Some(name)
    self
  }

  fn email(mut self, email: string): UserBuilder {
    self.email = Some(email)
    self
  }

  fn age(mut self, age: u32): UserBuilder {
    self.age = Some(age)
    self
  }
}

impl Builder for UserBuilder {
  type Output = Result<User, string>

  fn build(self): Result<User, string> {
    let name = self.name.ok_or("Name is required")?
    let email = self.email.ok_or("Email is required")?
    let age = self.age.unwrap_or(0)

    Ok(User { name, email, age })
  }
}

let user = UserBuilder.new()
  .name("Alice")
  .email("alice@example.com")
  .age(30)
  .build()
  .unwrap()
```

## Repository Pattern

```home
trait Repository<T> {
  fn find_by_id(&self, id: u64): Option<T>
  fn save(&mut self, entity: T): Result<(), string>
  fn delete(&mut self, id: u64): Result<(), string>
  fn find_all(&self): Vec<T>
}

struct InMemoryRepository<T> {
  data: HashMap<u64, T>,
  next_id: u64
}

impl<T: Clone> Repository<T> for InMemoryRepository<T> {
  fn find_by_id(&self, id: u64): Option<T> {
    self.data.get(&id).cloned()
  }

  fn save(&mut self, entity: T): Result<(), string> {
    let id = self.next_id
    self.next_id += 1
    self.data.insert(id, entity)
    Ok(())
  }

  fn delete(&mut self, id: u64): Result<(), string> {
    self.data.remove(&id)
      .map(|_| ())
      .ok_or("Entity not found")
  }

  fn find_all(&self): Vec<T> {
    self.data.values().cloned().collect()
  }
}
```

## Next Steps

- [Generics](/guide/functions#generic-functions) - Generic programming
- [Error Handling](/guide/error-handling) - Error traits
- [Standard Library](/reference/stdlib) - Built-in traits
