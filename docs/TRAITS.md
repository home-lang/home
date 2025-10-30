# Traits in Home

Traits in Home provide a powerful mechanism for polymorphism, code reuse, and abstraction. They are similar to Rust's traits and TypeScript's interfaces, but with some unique features.

## Table of Contents

- [Overview](#overview)
- [Defining Traits](#defining-traits)
- [Implementing Traits](#implementing-traits)
- [Trait Bounds](#trait-bounds)
- [Associated Types](#associated-types)
- [Default Implementations](#default-implementations)
- [Trait Inheritance](#trait-inheritance)
- [Trait Objects](#trait-objects)
- [Generic Traits](#generic-traits)
- [Where Clauses](#where-clauses)
- [Built-in Traits](#built-in-traits)

## Overview

Traits define shared behavior that types can implement. They enable:

- **Polymorphism**: Different types can implement the same trait
- **Code Reuse**: Default implementations reduce duplication
- **Abstraction**: Program against interfaces, not concrete types
- **Type Safety**: Trait bounds verified at compile time

```home
// Define a trait
trait Drawable {
    fn draw(&self) -> void
}

// Implement for a type
impl Drawable for Circle {
    fn draw(&self) -> void {
        println("Drawing circle at ({}, {})", self.x, self.y)
    }
}

// Use polymorphically
fn render(shape: &dyn Drawable) -> void {
    shape.draw()
}
```

## Defining Traits

### Basic Trait

```home
trait Animal {
    fn make_sound(&self) -> string
    fn get_name(&self) -> string
}
```

### Trait with Associated Types

```home
trait Iterator {
    type Item
    
    fn next(&mut self) -> Option<Self::Item>
}
```

### Trait with Default Implementation

```home
trait Greet {
    fn name(&self) -> string
    
    // Default implementation
    fn greet(&self) -> string {
        "Hello, " + self.name()
    }
}
```

## Implementing Traits

### Basic Implementation

```home
struct Dog {
    name: string,
}

impl Animal for Dog {
    fn make_sound(&self) -> string {
        "Woof!"
    }
    
    fn get_name(&self) -> string {
        self.name
    }
}
```

### Inherent Implementation (No Trait)

```home
impl Dog {
    fn new(name: string) -> Dog {
        Dog { name }
    }
    
    fn bark(&self) -> void {
        println("{}", self.make_sound())
    }
}
```

### Generic Implementation

```home
impl<T> Display for Vec<T> where T: Display {
    fn fmt(&self, f: &mut Formatter) -> Result {
        write!(f, "[")?
        for (i, item) in self.iter().enumerate() {
            if i > 0 {
                write!(f, ", ")?
            }
            write!(f, "{}", item)?
        }
        write!(f, "]")
    }
}
```

## Trait Bounds

### Function with Trait Bounds

```home
fn print_animal<T: Animal>(animal: &T) -> void {
    println("{} says {}", animal.get_name(), animal.make_sound())
}
```

### Multiple Bounds

```home
fn process<T: Clone + Debug>(value: T) -> void {
    let copy = value.clone()
    println("{:?}", copy)
}
```

### Bounds on Struct

```home
struct Container<T: Display> {
    value: T,
}

impl<T: Display> Container<T> {
    fn show(&self) -> void {
        println("{}", self.value)
    }
}
```

## Associated Types

Associated types allow traits to define placeholder types that implementers must specify.

```home
trait Graph {
    type Node
    type Edge
    
    fn nodes(&self) -> Vec<Self::Node>
    fn edges(&self) -> Vec<Self::Edge>
}

struct SimpleGraph {
    // ...
}

impl Graph for SimpleGraph {
    type Node = u32
    type Edge = (u32, u32)
    
    fn nodes(&self) -> Vec<u32> { ... }
    fn edges(&self) -> Vec<(u32, u32)> { ... }
}
```

### Associated Types vs Generic Parameters

```home
// With associated type (better for single implementation)
trait Iterator {
    type Item
    fn next(&mut self) -> Option<Self::Item>
}

// With generic parameter (allows multiple implementations)
trait From<T> {
    fn from(value: T) -> Self
}
```

## Default Implementations

Traits can provide default method implementations:

```home
trait Summary {
    fn summarize_author(&self) -> string
    
    // Default implementation
    fn summarize(&self) -> string {
        "Read more from " + self.summarize_author() + "..."
    }
}

struct Article {
    author: string,
    content: string,
}

impl Summary for Article {
    fn summarize_author(&self) -> string {
        self.author
    }
    // summarize() uses default implementation
}
```

## Trait Inheritance

Traits can inherit from other traits (super traits):

```home
trait Shape {
    fn area(&self) -> f64
}

trait Colored {
    fn color(&self) -> string
}

// ColoredShape requires both Shape and Colored
trait ColoredShape: Shape + Colored {
    fn describe(&self) -> string {
        "A " + self.color() + " shape with area " + self.area().to_string()
    }
}

struct ColoredCircle {
    radius: f64,
    color: string,
}

// Must implement all super traits
impl Shape for ColoredCircle {
    fn area(&self) -> f64 {
        3.14159 * self.radius * self.radius
    }
}

impl Colored for ColoredCircle {
    fn color(&self) -> string {
        self.color
    }
}

impl ColoredShape for ColoredCircle {
    // Can use default implementation or override
}
```

## Trait Objects

Trait objects enable dynamic dispatch:

```home
trait Drawable {
    fn draw(&self) -> void
}

// Function accepting any Drawable
fn render(shapes: &[dyn Drawable]) -> void {
    for shape in shapes {
        shape.draw()  // Dynamic dispatch
    }
}

// Usage
let shapes: Vec<dyn Drawable> = vec![
    Circle { x: 0, y: 0, radius: 5 },
    Rectangle { x: 10, y: 10, width: 20, height: 15 },
]

render(&shapes)
```

### Object Safety

Not all traits can be used as trait objects. A trait is object-safe if:

1. All methods have `&self` or `&mut self` as the first parameter
2. Methods don't use `Self` in return position (except in references)
3. No associated functions (functions without `self`)
4. No generic methods

```home
// Object-safe
trait Draw {
    fn draw(&self) -> void
}

// NOT object-safe (returns Self)
trait Clone {
    fn clone(&self) -> Self
}
```

## Generic Traits

Traits can have generic parameters:

```home
trait Add<Rhs = Self> {
    type Output
    fn add(self, rhs: Rhs) -> Self::Output
}

// Implement for different RHS types
impl Add<Vector> for Vector {
    type Output = Vector
    fn add(self, rhs: Vector) -> Vector { ... }
}

impl Add<f64> for Vector {
    type Output = Vector
    fn add(self, scalar: f64) -> Vector { ... }
}
```

## Where Clauses

For complex trait bounds, use where clauses:

```home
// Instead of this:
fn complex<T: Clone + Debug, U: Clone + Debug>(t: T, u: U) -> void { ... }

// Use this:
fn complex<T, U>(t: T, u: U) -> void 
where
    T: Clone + Debug,
    U: Clone + Debug
{
    // ...
}
```

### Where Clauses with Associated Types

```home
fn process<T>(container: T) -> void
where
    T: Iterator,
    T::Item: Display
{
    for item in container {
        println("{}", item)
    }
}
```

## Built-in Traits

Home provides several built-in traits:

### Clone

```home
trait Clone {
    fn clone(&self) -> Self
}

// Derive automatically
#[derive(Clone)]
struct Point {
    x: i32,
    y: i32,
}
```

### Copy

```home
trait Copy: Clone {}

// Copy types can be duplicated by simple bit copy
#[derive(Copy, Clone)]
struct Point {
    x: i32,
    y: i32,
}
```

### Debug

```home
trait Debug {
    fn fmt(&self, f: &mut Formatter) -> Result<(), Error>
}

#[derive(Debug)]
struct User {
    name: string,
    age: u32,
}

let user = User { name: "Alice", age: 30 }
println("{:?}", user)  // User { name: "Alice", age: 30 }
```

### Display

```home
trait Display {
    fn fmt(&self, f: &mut Formatter) -> Result<(), Error>
}

impl Display for User {
    fn fmt(&self, f: &mut Formatter) -> Result<(), Error> {
        write!(f, "{} (age {})", self.name, self.age)
    }
}
```

### PartialEq and Eq

```home
trait PartialEq {
    fn eq(&self, other: &Self) -> bool
}

trait Eq: PartialEq {}

#[derive(PartialEq, Eq)]
struct Point {
    x: i32,
    y: i32,
}
```

### PartialOrd and Ord

```home
trait PartialOrd: PartialEq {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering>
}

trait Ord: Eq + PartialOrd {
    fn cmp(&self, other: &Self) -> Ordering
}
```

### Iterator

```home
trait Iterator {
    type Item
    
    fn next(&mut self) -> Option<Self::Item>
    
    // Provided methods
    fn map<B, F>(self, f: F) -> Map<Self, F>
    where
        F: FnMut(Self::Item) -> B
    { ... }
    
    fn filter<P>(self, predicate: P) -> Filter<Self, P>
    where
        P: FnMut(&Self::Item) -> bool
    { ... }
}
```

### Default

```home
trait Default {
    fn default() -> Self
}

#[derive(Default)]
struct Config {
    timeout: u32,  // 0
    retries: u32,  // 0
}
```

### From and Into

```home
trait From<T> {
    fn from(value: T) -> Self
}

trait Into<T> {
    fn into(self) -> T
}

impl From<i32> for f64 {
    fn from(value: i32) -> f64 {
        value as f64
    }
}

let x: i32 = 42
let y: f64 = x.into()  // Automatically available
```

## Best Practices

1. **Prefer trait bounds over trait objects** when possible for better performance
2. **Use associated types** when a trait should have one implementation per type
3. **Use generic parameters** when multiple implementations make sense
4. **Keep traits focused** - single responsibility principle
5. **Provide default implementations** when reasonable
6. **Use descriptive names** - traits are interfaces, name them accordingly
7. **Document trait requirements** - explain what implementers must guarantee

## Examples

### Repository Pattern

```home
trait Repository<T> {
    fn find_by_id(&self, id: u64) -> Option<T>
    fn save(&mut self, entity: T) -> Result<(), Error>
    fn delete(&mut self, id: u64) -> Result<(), Error>
}

struct UserRepository {
    db: Database,
}

impl Repository<User> for UserRepository {
    fn find_by_id(&self, id: u64) -> Option<User> {
        self.db.query("SELECT * FROM users WHERE id = ?", id)
    }
    
    fn save(&mut self, user: User) -> Result<(), Error> {
        self.db.execute("INSERT INTO users ...", user)
    }
    
    fn delete(&mut self, id: u64) -> Result<(), Error> {
        self.db.execute("DELETE FROM users WHERE id = ?", id)
    }
}
```

### Builder Pattern

```home
trait Builder {
    type Output
    
    fn build(self) -> Self::Output
}

struct UserBuilder {
    name: Option<string>,
    email: Option<string>,
    age: Option<u32>,
}

impl Builder for UserBuilder {
    type Output = Result<User, Error>
    
    fn build(self) -> Result<User, Error> {
        Ok(User {
            name: self.name.ok_or("Name required")?,
            email: self.email.ok_or("Email required")?,
            age: self.age.unwrap_or(0),
        })
    }
}
```

## See Also

- [Operator Overloading](OPERATOR_OVERLOADING.md) - Traits for operator overloading
- [Generics](GENERICS.md) - Using traits with generic types
- [Type System](TYPE_SYSTEM.md) - How traits fit into the type system
