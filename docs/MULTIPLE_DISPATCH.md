# Multiple Dispatch in Home

Multiple dispatch (also called multimethods) allows function selection based on the runtime types of **all** arguments, not just the first one. This enables more natural and maintainable code for operations involving multiple types.

## Table of Contents

- [Basic Concept](#basic-concept)
- [Syntax](#syntax)
- [Dispatch Resolution](#dispatch-resolution)
- [Specificity Rules](#specificity-rules)
- [Use Cases](#use-cases)
- [Best Practices](#best-practices)

## Basic Concept

### Traditional Single Dispatch

In traditional OOP, method selection is based only on the receiver (first argument):

```home
// Single dispatch - only 'self' type matters
impl Shape {
    fn collides_with(self, other: Shape): bool {
        // Must manually check 'other' type
        match other {
            Circle(c) => self.collides_with_circle(c),
            Rectangle(r) => self.collides_with_rectangle(r),
            // Must add case for every new type!
        }
    }
}
```

### Multiple Dispatch

With multiple dispatch, selection is based on **all** argument types:

```home
// Multiple dispatch - both types matter
fn collides(a: Circle, b: Circle): bool {
    // Circle-Circle specific logic
    let distance = sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
    distance < (a.radius + b.radius)
}

fn collides(a: Circle, b: Rectangle): bool {
    // Circle-Rectangle specific logic
    // ...
}

fn collides(a: Rectangle, b: Rectangle): bool {
    // Rectangle-Rectangle specific logic
    // ...
}

// Usage - automatically selects correct version
let circle = Circle { x: 0, y: 0, radius: 5 }
let rect = Rectangle { x: 10, y: 10, width: 20, height: 15 }

collides(circle, rect)  // Calls Circle-Rectangle version
collides(rect, circle)  // Calls Rectangle-Circle version (if defined)
```

## Syntax

### Basic Multi-Method Definition

```home
// Define multiple variants of the same function
fn process(data: String): Result {
    // Handle string
}

fn process(data: i32): Result {
    // Handle integer
}

fn process(data: Vec<u8>): Result {
    // Handle byte array
}

// Calls appropriate version
process("hello")     // String version
process(42)          // i32 version
process(vec![1,2,3]) // Vec version
```

### Multiple Parameters

```home
fn combine(a: String, b: String): String {
    a + b
}

fn combine(a: String, b: i32): String {
    a + b.to_string()
}

fn combine(a: i32, b: String): String {
    a.to_string() + b
}

fn combine(a: i32, b: i32): i32 {
    a + b
}

// All combinations handled
combine("hello", "world")  // "helloworld"
combine("count: ", 42)     // "count: 42"
combine(10, " items")      // "10 items"
combine(5, 10)             // 15
```

## Dispatch Resolution

### Exact Match

```home
fn greet(name: String): void {
    println("Hello, {}!", name)
}

greet("Alice")  // Exact match: String
```

### Most Specific Match

When multiple variants could match, the most specific one is chosen:

```home
trait Animal { }
trait Mammal: Animal { }

struct Dog;
impl Mammal for Dog { }

fn describe(a: Animal): String {
    "An animal"
}

fn describe(m: Mammal): String {
    "A mammal"
}

fn describe(d: Dog): String {
    "A dog"
}

let dog = Dog;
describe(dog)  // Calls Dog version (most specific)

let mammal: Mammal = dog;
describe(mammal)  // Calls Mammal version

let animal: Animal = dog;
describe(animal)  // Calls Animal version
```

### Ambiguity Detection

```home
fn process(a: i32, b: f64): void { }
fn process(a: f64, b: i32): void { }

// Error: Ambiguous!
process(1.0, 2.0)  // Could match either after coercion
```

## Specificity Rules

Dispatch resolution follows these rules (in order):

1. **Exact type match** - Most specific
2. **Subtype/trait implementation** - Less specific
3. **Generic with constraints** - Even less specific
4. **Generic without constraints** - Least specific

```home
fn handle(x: Circle): void { }           // Specificity: 100
fn handle(x: impl Shape): void { }       // Specificity: 50
fn handle<T: Display>(x: T): void { }    // Specificity: 25
fn handle<T>(x: T): void { }             // Specificity: 10

let circle = Circle { ... };
handle(circle)  // Calls Circle version (most specific)
```

## Use Cases

### 1. Collision Detection

```home
// Game physics
fn collide(a: Sphere, b: Sphere): Collision {
    // Sphere-sphere collision
}

fn collide(a: Sphere, b: Box): Collision {
    // Sphere-box collision
}

fn collide(a: Sphere, b: Plane): Collision {
    // Sphere-plane collision
}

fn collide(a: Box, b: Box): Collision {
    // Box-box collision
}

// Symmetric operations
fn collide(a: Box, b: Sphere): Collision {
    collide(b, a)  // Reuse Sphere-Box
}

// Usage
for entity1 in entities {
    for entity2 in entities {
        if let Some(collision) = collide(entity1, entity2) {
            handle_collision(collision)
        }
    }
}
```

### 2. Mathematical Operations

```home
// Matrix library
fn multiply(a: Matrix, b: Matrix): Matrix {
    // Matrix-matrix multiplication
}

fn multiply(a: Matrix, b: Vector): Vector {
    // Matrix-vector multiplication
}

fn multiply(a: Matrix, b: Scalar): Matrix {
    // Scalar multiplication
}

fn multiply(a: Vector, b: Vector): Scalar {
    // Dot product
}

// Natural usage
let m = Matrix::new(...)
let v = Vector::new(...)
let result = multiply(m, v)  // Returns Vector
```

### 3. Serialization

```home
fn serialize(data: User, format: JSON): String {
    // User to JSON
}

fn serialize(data: User, format: XML): String {
    // User to XML
}

fn serialize(data: Post, format: JSON): String {
    // Post to JSON
}

fn serialize(data: Post, format: Binary): Vec<u8> {
    // Post to binary
}

// Clean API
let json = serialize(user, JSON);
let xml = serialize(post, XML);
```

### 4. Event Handling

```home
fn handle(event: MouseClick, target: Button): void {
    // Button click
    target.on_click()
}

fn handle(event: MouseClick, target: TextInput): void {
    // Text input click (focus)
    target.focus()
}

fn handle(event: KeyPress, target: TextInput): void {
    // Text input key press
    target.insert_char(event.char)
}

fn handle(event: KeyPress, target: Canvas): void {
    // Canvas key press (shortcuts)
    if event.key == "Ctrl+S" {
        target.save()
    }
}

// Event loop
for event in events {
    for widget in widgets {
        handle(event, widget)
    }
}
```

### 5. Visitor Pattern (Simplified)

```home
// AST traversal
fn visit(visitor: TypeChecker, node: FunctionDecl): void {
    // Type check function
}

fn visit(visitor: TypeChecker, node: VariableDecl): void {
    // Type check variable
}

fn visit(visitor: CodeGenerator, node: FunctionDecl): void {
    // Generate code for function
}

fn visit(visitor: CodeGenerator, node: VariableDecl): void {
    // Generate code for variable
}

// Clean traversal
for node in ast {
    visit(type_checker, node)
}

for node in ast {
    visit(code_generator, node)
}
```

### 6. Protocol Negotiation

```home
fn connect(client: HTTP1Client, server: HTTP1Server): Connection {
    // HTTP/1.1 connection
}

fn connect(client: HTTP2Client, server: HTTP2Server): Connection {
    // HTTP/2 connection
}

fn connect(client: HTTP2Client, server: HTTP1Server): Connection {
    // Downgrade to HTTP/1.1
}

fn connect(client: HTTP1Client, server: HTTP2Server): Connection {
    // Upgrade to HTTP/2
}
```

## Best Practices

### 1. Keep Variants Focused

```home
// Good - clear, specific variants
fn draw(shape: Circle, canvas: Canvas2D): void { }
fn draw(shape: Rectangle, canvas: Canvas2D): void { }

// Avoid - too generic
fn draw(shape: Any, canvas: Any): void { }
```

### 2. Avoid Ambiguity

```home
// Good - unambiguous
fn process(a: i32, b: String): void { }
fn process(a: String, b: i32): void { }

// Avoid - ambiguous
fn process(a: Number, b: Number): void { }
fn process(a: Integer, b: Integer): void { }
// What if both Number and Integer match?
```

### 3. Use Symmetric Variants

```home
// Good - both directions defined
fn combine(a: String, b: i32): String { }
fn combine(a: i32, b: String): String { }

// Or use delegation
fn combine(a: i32, b: String): String {
    combine(b, a)  // Reuse String-i32 version
}
```

### 4. Document Dispatch Behavior

```home
/// Combines two values into a string.
/// 
/// # Dispatch Variants
/// - `(String, String)` - Concatenation
/// - `(String, i32)` - Append number
/// - `(i32, String)` - Prepend number
/// - `(i32, i32)` - Sum then convert
fn combine(a: impl Display, b: impl Display): String {
    // ...
}
```

### 5. Test All Combinations

```home
#[test]
fn test_collisions() {
    let sphere = Sphere::new();
    let box = Box::new();
    let plane = Plane::new();
    
    // Test all combinations
    assert!(collide(sphere, sphere).is_some());
    assert!(collide(sphere, box).is_some());
    assert!(collide(sphere, plane).is_some());
    assert!(collide(box, sphere).is_some());
    assert!(collide(box, box).is_some());
    assert!(collide(box, plane).is_some());
}
```

## Advanced Features

### Generic Dispatch

```home
fn process<T: Serialize>(data: T, format: JSON): String {
    // Generic data, specific format
    data.to_json()
}

fn process<T: Serialize>(data: T, format: XML): String {
    // Generic data, different format
    data.to_xml()
}
```

### Constrained Dispatch

```home
fn compare<T: Ord>(a: T, b: T): Ordering {
    // Same type comparison
    a.cmp(&b)
}

fn compare<T: Ord, U: Ord>(a: T, b: U): Ordering
where
    T: Into<U>
{
    // Different types with conversion
    a.into().cmp(&b)
}
```

### Default Fallback

```home
fn handle(event: Event, target: Widget): void {
    // Specific handlers defined elsewhere
}

fn handle(event: Event, target: impl Widget): void {
    // Default handler for any widget
    target.default_handle(event)
}
```

## Performance Considerations

### Static Dispatch

When types are known at compile time, dispatch is resolved statically (zero cost):

```home
let circle = Circle { ... };
let rect = Rectangle { ... };

collide(circle, rect)  // Resolved at compile time
```

### Dynamic Dispatch

When types are only known at runtime, a vtable lookup is required:

```home
let shapes: Vec<Box<dyn Shape>> = vec![...];

for s1 in &shapes {
    for s2 in &shapes {
        collide(s1, s2)  // Runtime dispatch
    }
}
```

### Optimization

The compiler can optimize dispatch in several ways:
- Inline specific variants
- Devirtualize when types are known
- Generate specialized code paths

## See Also

- [Traits](TRAITS.md) - Trait system
- [Generics](GENERICS.md) - Generic programming
- [Pattern Matching](PATTERN_MATCHING.md) - Pattern-based dispatch
- [Operator Overloading](OPERATOR_OVERLOADING.md) - Operator dispatch
