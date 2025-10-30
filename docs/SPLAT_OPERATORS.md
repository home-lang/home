# Splat Operators in Home

Splat operators (also known as spread/rest operators) provide powerful syntax for unpacking and collecting elements in arrays, objects, and function calls.

## Table of Contents

- [Array Spread](#array-spread)
- [Object Spread](#object-spread)
- [Function Call Spread](#function-call-spread)
- [Rest Parameters](#rest-parameters)
- [Array Destructuring](#array-destructuring)
- [Object Destructuring](#object-destructuring)
- [Best Practices](#best-practices)

## Array Spread

### Spreading Arrays

```home
let arr1 = [1, 2, 3]
let arr2 = [4, 5, 6]

// Spread arrays into new array
let combined = [...arr1, ...arr2]
// Result: [1, 2, 3, 4, 5, 6]

// Mix spread with literals
let extended = [0, ...arr1, 10, ...arr2, 20]
// Result: [0, 1, 2, 3, 10, 4, 5, 6, 20]
```

### Copying Arrays

```home
let original = [1, 2, 3, 4, 5]

// Shallow copy
let copy = [...original]

// Modify copy without affecting original
copy.push(6)
// original: [1, 2, 3, 4, 5]
// copy: [1, 2, 3, 4, 5, 6]
```

### Concatenation

```home
let fruits = ["apple", "banana"]
let vegetables = ["carrot", "potato"]
let dairy = ["milk", "cheese"]

// Concatenate multiple arrays
let groceries = [...fruits, ...vegetables, ...dairy]
```

## Object Spread

### Spreading Objects

```home
let defaults = {
    host: "localhost",
    port: 8080,
    timeout: 30,
}

let custom = {
    port: 3000,
    debug: true,
}

// Merge objects (later values override)
let config = { ...defaults, ...custom }
// Result: { host: "localhost", port: 3000, timeout: 30, debug: true }
```

### Copying Objects

```home
let original = {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
}

// Shallow copy
let copy = { ...original }

// Override specific fields
let updated = {
    ...original,
    age: 31,
    active: true,
}
```

### Conditional Spreading

```home
let base_config = { host: "localhost", port: 8080 }

// Conditionally add fields
let config = {
    ...base_config,
    ...(is_production ? { ssl: true, verify: true } : {}),
    debug: !is_production,
}
```

## Function Call Spread

### Spreading Arguments

```home
fn add(a: i32, b: i32, c: i32) -> i32 {
    a + b + c
}

let numbers = [1, 2, 3]

// Spread array as arguments
let sum = add(...numbers)
// Equivalent to: add(1, 2, 3)
```

### Mix Spread with Regular Arguments

```home
fn greet(greeting: string, ...names: string) -> void {
    for name in names {
        println("{}, {}!", greeting, name)
    }
}

let people = ["Alice", "Bob"]

// Mix regular and spread arguments
greet("Hello", ...people, "Charlie")
// Equivalent to: greet("Hello", "Alice", "Bob", "Charlie")
```

### Multiple Spreads

```home
fn sum(...numbers: i32) -> i32 {
    numbers.iter().sum()
}

let arr1 = [1, 2, 3]
let arr2 = [4, 5, 6]

// Multiple spreads in one call
let total = sum(...arr1, ...arr2, 7, 8, 9)
// Equivalent to: sum(1, 2, 3, 4, 5, 6, 7, 8, 9)
```

## Rest Parameters

### Collecting Arguments

```home
// Rest parameter collects remaining arguments
fn sum(first: i32, ...rest: i32) -> i32 {
    let total = first
    for num in rest {
        total += num
    }
    total
}

sum(1, 2, 3, 4, 5)  // first=1, rest=[2,3,4,5]
```

### With Named Parameters

```home
fn log(level: string, message: string, ...details: any) -> void {
    println("[{}] {}", level, message)
    for detail in details {
        println("  {:?}", detail)
    }
}

log("INFO", "User logged in", user_id, timestamp, ip_address)
```

## Array Destructuring

### Basic Destructuring with Rest

```home
let numbers = [1, 2, 3, 4, 5]

// Destructure with rest
let [first, second, ...rest] = numbers
// first: 1, second: 2, rest: [3, 4, 5]

// Rest in middle (if supported)
let [head, ...middle, tail] = numbers
// head: 1, middle: [2, 3, 4], tail: 5
```

### Ignoring Elements

```home
let data = [1, 2, 3, 4, 5]

// Ignore some elements
let [first, _, third, ...rest] = data
// first: 1, third: 3, rest: [4, 5]

// Only get rest
let [_, _, ...rest] = data
// rest: [3, 4, 5]
```

### Nested Destructuring

```home
let matrix = [[1, 2], [3, 4], [5, 6]]

// Destructure nested arrays
let [[a, b], ...rest] = matrix
// a: 1, b: 2, rest: [[3, 4], [5, 6]]
```

### Swapping Values

```home
let a = 1
let b = 2

// Swap using destructuring
[a, b] = [b, a]
// a: 2, b: 1
```

## Object Destructuring

### Basic Destructuring with Rest

```home
let user = {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
    active: true,
    role: "admin",
}

// Destructure with rest
let { name, age, ...rest } = user
// name: "Alice", age: 30, rest: { email: "...", active: true, role: "admin" }
```

### Renaming Fields

```home
let config = {
    host: "localhost",
    port: 8080,
    timeout: 30,
}

// Rename while destructuring
let { host: server, port: serverPort, ...options } = config
// server: "localhost", serverPort: 8080, options: { timeout: 30 }
```

### Default Values

```home
let partial = {
    name: "Bob",
    age: 25,
}

// Provide defaults for missing fields
let { name, age, email = "unknown@example.com", ...rest } = partial
// name: "Bob", age: 25, email: "unknown@example.com", rest: {}
```

### Nested Destructuring

```home
let person = {
    name: "Alice",
    address: {
        street: "123 Main St",
        city: "Portland",
        zip: "97201",
    },
    contacts: {
        email: "alice@example.com",
        phone: "555-1234",
    },
}

// Nested destructuring with rest
let {
    name,
    address: { city, ...addressRest },
    ...personRest
} = person
```

## Best Practices

### 1. Use Spread for Immutability

```home
// Good - creates new array
let new_array = [...original_array, new_item]

// Avoid - mutates original
original_array.push(new_item)
```

### 2. Shallow Copy Awareness

```home
let original = {
    name: "Alice",
    settings: { theme: "dark" },
}

// Shallow copy - nested objects are referenced
let copy = { ...original }
copy.settings.theme = "light"  // Affects original!

// Deep copy when needed
let deep_copy = {
    ...original,
    settings: { ...original.settings },
}
```

### 3. Rest Parameter Must Be Last

```home
// Good
fn func(a: i32, b: i32, ...rest: i32) -> void { }

// Error - rest must be last
fn func(a: i32, ...rest: i32, b: i32) -> void { }
```

### 4. Limit Spread Depth

```home
// Good - clear and simple
let config = { ...defaults, ...custom }

// Avoid - too many spreads
let result = { ...a, ...b, ...c, ...d, ...e, ...f }
```

### 5. Use Destructuring for Clarity

```home
// Good - clear what's being extracted
let { name, age } = user

// Avoid - accessing repeatedly
println("{}", user.name)
println("{}", user.age)
println("{}", user.name)  // Repeated access
```

## Common Patterns

### Merging Configurations

```home
const DEFAULT_CONFIG = {
    host: "localhost",
    port: 8080,
    timeout: 30,
    retries: 3,
}

fn create_client(config: Config) -> Client {
    let final_config = { ...DEFAULT_CONFIG, ...config }
    Client::new(final_config)
}
```

### Removing Properties

```home
let user = {
    id: 1,
    name: "Alice",
    password: "secret",
    email: "alice@example.com",
}

// Remove password
let { password, ...safe_user } = user
// safe_user: { id: 1, name: "Alice", email: "..." }
```

### Function Composition

```home
fn compose<T>(...functions: fn(T) -> T) -> fn(T) -> T {
    return |x| {
        let result = x
        for func in functions {
            result = func(result)
        }
        result
    }
}

let pipeline = compose(trim, lowercase, remove_spaces)
```

### Partial Application

```home
fn partial<F, Args, Rest>(func: F, ...args: Args) -> fn(...Rest) -> Result
where
    F: Fn(Args, Rest) -> Result
{
    return |...rest| func(...args, ...rest)
}

let add = |a, b, c| a + b + c
let add_5_and_10 = partial(add, 5, 10)
let result = add_5_and_10(3)  // 18
```

### Collecting Middleware

```home
fn apply_middleware(handler: Handler, ...middleware: Middleware) -> Handler {
    let mut wrapped = handler
    for mw in middleware.reverse() {
        wrapped = mw(wrapped)
    }
    wrapped
}

let handler = apply_middleware(
    base_handler,
    ...common_middleware,
    auth_middleware,
    logging_middleware
)
```

## Examples

### Array Manipulation

```home
let numbers = [1, 2, 3]

// Prepend
let with_zero = [0, ...numbers]

// Append
let with_four = [...numbers, 4]

// Insert in middle
let with_middle = [...numbers[..2], 99, ...numbers[2..]]

// Remove duplicates
let unique = [...new Set(numbers)]
```

### Object Updates

```home
let user = {
    name: "Alice",
    age: 30,
    email: "alice@example.com",
}

// Update age
let updated = { ...user, age: 31 }

// Add new field
let with_role = { ...user, role: "admin" }

// Update multiple fields
let modified = {
    ...user,
    age: 31,
    email: "alice.new@example.com",
    active: true,
}
```

### Function Arguments

```home
fn create_user(name: string, age: i32, ...options: UserOption) -> User {
    let mut user = User { name, age }
    
    for option in options {
        match option {
            UserOption::Email(email) => user.email = email,
            UserOption::Role(role) => user.role = role,
            UserOption::Active(active) => user.active = active,
        }
    }
    
    user
}

let user = create_user(
    "Alice",
    30,
    UserOption::Email("alice@example.com"),
    UserOption::Role("admin"),
    UserOption::Active(true)
)
```

### Matrix Flattening

```home
let matrix = [
    [1, 2, 3],
    [4, 5, 6],
    [7, 8, 9],
]

// Flatten using spread
let flat = [...matrix[0], ...matrix[1], ...matrix[2]]

// Or with reduce
let flat = matrix.reduce(|acc, row| [...acc, ...row], [])
```

## See Also

- [Destructuring](DESTRUCTURING.md) - Pattern matching and destructuring
- [Variadic Functions](VARIADIC_FUNCTIONS.md) - Variable arguments
- [Arrays](ARRAYS.md) - Array operations
- [Objects](OBJECTS.md) - Object manipulation
