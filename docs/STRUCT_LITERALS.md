# Struct Literals with Shorthand in Home

Struct literals in Home support multiple convenient syntaxes including field shorthand, making struct initialization concise and readable.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Shorthand Syntax](#shorthand-syntax)
- [Struct Update Syntax](#struct-update-syntax)
- [Anonymous Structs](#anonymous-structs)
- [Tuple Structs](#tuple-structs)
- [Nested Structs](#nested-structs)
- [Best Practices](#best-practices)

## Basic Syntax

### Explicit Field Initialization

```home
struct User {
    name: string,
    age: i32,
    email: string,
}

// Explicit initialization
let user = User {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
}
```

### Field Order

Fields can be initialized in any order:

```home
let user = User {
    email: "bob@example.com",
    name: "Bob",
    age: 25,
}
```

## Shorthand Syntax

### Field Punning

When a variable name matches the field name, use shorthand:

```home
let name = "Charlie"
let age = 35
let email = "charlie@example.com"

// Shorthand syntax
let user = User { name, age, email }

// Equivalent to:
let user = User {
    name: name,
    age: age,
    email: email,
}
```

### Mixed Shorthand and Explicit

```home
let name = "Dave"
let email = "dave@example.com"

// Mix shorthand and explicit
let user = User {
    name,
    age: 28,
    email,
}
```

### Benefits

1. **Less repetition** - DRY principle
2. **Cleaner code** - Easier to read
3. **Refactoring friendly** - Rename once, works everywhere

```home
// Before shorthand
fn create_user(name: string, age: i32, email: string): User {
    User {
        name: name,
        age: age,
        email: email,
    }
}

// With shorthand
fn create_user(name: string, age: i32, email: string): User {
    User { name, age, email }
}
```

## Struct Update Syntax

### Spread Operator

Use `..` to copy fields from another struct:

```home
let user1 = User {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
}

// Create new struct with some fields updated
let user2 = User {
    age: 31,
    ..user1  // Copy other fields from user1
}

// user2 = { name: "Alice", age: 31, email: "alice@example.com" }
```

### Update Multiple Fields

```home
let user3 = User {
    name: "Alice Smith",
    email: "alice.smith@example.com",
    ..user1  // age: 30
}
```

### Shorthand with Update

```home
let name = "Bob"

let user = User {
    name,
    ..default_user
}
```

## Anonymous Structs

### Inline Struct Types

Create structs without defining a type:

```home
// Anonymous struct literal
let point = .{ x: 10, y: 20 }

// Type is inferred
fn draw_at(pos: .{ x: i32, y: i32 }): void {
    println("Drawing at ({}, {})", pos.x, pos.y)
}

draw_at(.{ x: 100, y: 200 })
```

### Return Anonymous Structs

```home
fn get_bounds(): .{ min: i32, max: i32 } {
    .{ min: 0, max: 100 }
}

let bounds = get_bounds()
println("Range: {} to {}", bounds.min, bounds.max)
```

### Shorthand in Anonymous Structs

```home
let x = 10
let y = 20

let point = .{ x, y }  // Shorthand works here too
```

## Tuple Structs

### Positional Fields

Tuple structs use positional initialization:

```home
struct Point(i32, i32)
struct Color(u8, u8, u8)

// Tuple struct literals
let point = Point(10, 20)
let color = Color(255, 128, 0)

// Access by position
println("Point: ({}, {})", point.0, point.1)
println("Color: RGB({}, {}, {})", color.0, color.1, color.2)
```

### Named Tuple Structs

```home
struct Rgb(r: u8, g: u8, b: u8)

// Can use named or positional
let color1 = Rgb(255, 128, 0)
let color2 = Rgb(r: 255, g: 128, b: 0)
```

## Nested Structs

### Nested Initialization

```home
struct Address {
    street: string,
    city: string,
    zip: string,
}

struct Person {
    name: string,
    age: i32,
    address: Address,
}

// Nested struct literal
let person = Person {
    name: "Alice",
    age: 30,
    address: Address {
        street: "123 Main St",
        city: "Springfield",
        zip: "12345",
    },
}
```

### Shorthand in Nested Structs

```home
let name = "Bob"
let age = 25
let street = "456 Oak Ave"
let city = "Portland"
let zip = "97201"

let person = Person {
    name,
    age,
    address: Address { street, city, zip },
}
```

### Update Nested Structs

```home
let person2 = Person {
    name: "Charlie",
    address: Address {
        street: "789 Pine Rd",
        ..person.address  // Copy city and zip
    },
    ..person  // Copy age
}
```

## Best Practices

### 1. Use Shorthand When Possible

```home
// Good - concise
fn create_user(name: string, age: i32, email: string): User {
    User { name, age, email }
}

// Avoid - repetitive
fn create_user(name: string, age: i32, email: string): User {
    User {
        name: name,
        age: age,
        email: email,
    }
}
```

### 2. Consistent Field Order

```home
// Good - consistent with struct definition
struct User {
    name: string,
    age: i32,
    email: string,
}

let user = User {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
}

// Works but less readable
let user = User {
    email: "alice@example.com",
    name: "Alice",
    age: 30,
}
```

### 3. Use Update Syntax for Defaults

```home
const DEFAULT_CONFIG: Config = Config {
    host: "localhost",
    port: 8080,
    timeout: 30,
    debug: false,
}

// Override specific fields
let dev_config = Config {
    port: 3000,
    debug: true,
    ..DEFAULT_CONFIG
}
```

### 4. Anonymous Structs for One-Off Data

```home
// Good - simple return value
fn get_stats(): .{ count: i32, average: f64 } {
    .{ count: 100, average: 75.5 }
}

// Avoid - defining struct for single use
struct Stats {
    count: i32,
    average: f64,
}

fn get_stats(): Stats {
    Stats { count: 100, average: 75.5 }
}
```

### 5. Multiline for Readability

```home
// Good - readable
let config = ServerConfig {
    host: "api.example.com",
    port: 443,
    ssl: true,
    timeout: 60,
    max_connections: 1000,
    workers: 8,
}

// Avoid - hard to read
let config = ServerConfig { host: "api.example.com", port: 443, ssl: true, timeout: 60, max_connections: 1000, workers: 8 }
```

## Common Patterns

### Builder Pattern Alternative

```home
// Instead of builder pattern
let user = User {
    name: "Alice",
    age: 30,
    ..User::default()
}
```

### Configuration Objects

```home
struct HttpConfig {
    timeout: i32,
    retries: i32,
    verify_ssl: bool,
}

const DEFAULT_HTTP: HttpConfig = HttpConfig {
    timeout: 30,
    retries: 3,
    verify_ssl: true,
}

// Easy customization
let custom = HttpConfig {
    timeout: 60,
    ..DEFAULT_HTTP
}
```

### Test Data

```home
fn test_user_creation() {
    let name = "Test User"
    let email = "test@example.com"
    
    let user = User {
        name,
        age: 25,
        email,
        active: true,
    }
    
    assert_eq!(user.name, "Test User")
}
```

### Response Objects

```home
fn handle_request(req: Request): Response {
    let status = 200
    let body = "OK"
    
    Response {
        status,
        body,
        headers: HashMap::new(),
        ..Response::default()
    }
}
```

## Examples

### Point and Rectangle

```home
struct Point {
    x: i32,
    y: i32,
}

struct Rect {
    top_left: Point,
    bottom_right: Point,
}

let x1 = 10
let y1 = 20
let x2 = 100
let y2 = 80

let rect = Rect {
    top_left: Point { x: x1, y: y1 },
    bottom_right: Point { x: x2, y: y2 },
}

// With shorthand
let rect2 = Rect {
    top_left: Point { x: x1, y: y1 },
    bottom_right: Point { x: x2, y: y2 },
}
```

### User Profile

```home
struct Profile {
    username: string,
    display_name: string,
    bio: string,
    avatar_url: string,
    verified: bool,
}

fn create_profile(username: string, display_name: string): Profile {
    Profile {
        username,
        display_name,
        bio: "",
        avatar_url: "/default-avatar.png",
        verified: false,
    }
}

// Update profile
fn verify_profile(profile: Profile): Profile {
    Profile {
        verified: true,
        ..profile
    }
}
```

### Database Record

```home
struct DbRecord {
    id: i64,
    created_at: DateTime,
    updated_at: DateTime,
    data: string,
}

fn create_record(data: string): DbRecord {
    let now = DateTime::now()
    
    DbRecord {
        id: generate_id(),
        created_at: now,
        updated_at: now,
        data,
    }
}

fn update_record(record: DbRecord, data: string): DbRecord {
    DbRecord {
        data,
        updated_at: DateTime::now(),
        ..record
    }
}
```

### Color Manipulation

```home
struct Color {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
}

const RED: Color = Color { r: 255, g: 0, b: 0, a: 255 }
const GREEN: Color = Color { r: 0, g: 255, b: 0, a: 255 }
const BLUE: Color = Color { r: 0, g: 0, b: 255, a: 255 }

fn with_alpha(color: Color, alpha: u8): Color {
    Color {
        a: alpha,
        ..color
    }
}

let semi_transparent_red = with_alpha(RED, 128)
```

### Event Data

```home
struct ClickEvent {
    x: i32,
    y: i32,
    button: MouseButton,
    modifiers: KeyModifiers,
    timestamp: i64,
}

fn handle_click(x: i32, y: i32, button: MouseButton): void {
    let event = ClickEvent {
        x,
        y,
        button,
        modifiers: get_modifiers(),
        timestamp: current_time(),
    }
    
    process_event(event)
}
```

## See Also

- [Structs](STRUCTS.md) - Struct definitions
- [Pattern Matching](PATTERN_MATCHING.md) - Destructuring structs
- [Methods](METHODS.md) - Struct methods
