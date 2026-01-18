# Pattern Matching

Pattern matching is one of Home's most powerful features, enabling expressive and safe destructuring of data. It combines the elegance of functional programming with the performance requirements of systems programming.

## Overview

Pattern matching in Home provides:

- **Exhaustive checking**: Compiler ensures all cases are handled
- **Deep destructuring**: Match nested structures in a single expression
- **Guard clauses**: Add conditions to patterns
- **Binding**: Extract and name values while matching

## Basic Match Expressions

The `match` expression is the primary pattern matching construct:

```home
let number = 42

let result = match number {
    0 => "zero",
    1 => "one",
    2 => "two",
    _ => "many",
}
```

### Matching Multiple Values

```home
let day = 3

let name = match day {
    1 | 7 => "weekend",
    2 | 3 | 4 | 5 | 6 => "weekday",
    _ => "invalid",
}
```

### Range Patterns

```home
let score = 85

let grade = match score {
    90..=100 => "A",
    80..90 => "B",
    70..80 => "C",
    60..70 => "D",
    0..60 => "F",
    _ => "Invalid score",
}
```

## Destructuring Patterns

### Tuple Destructuring

```home
let point = (10, 20)

match point {
    (0, 0) => print("origin"),
    (x, 0) => print("on x-axis at {x}"),
    (0, y) => print("on y-axis at {y}"),
    (x, y) => print("at ({x}, {y})"),
}
```

### Struct Destructuring

```home
struct User {
    name: string,
    age: i32,
    active: bool,
}

let user = User { name: "Alice", age: 30, active: true }

match user {
    User { name, age: 0..18, .. } => print("{name} is a minor"),
    User { name, active: false, .. } => print("{name} is inactive"),
    User { name, age, active: true } => print("{name} ({age}) is active"),
}
```

### Array and Slice Patterns

```home
let numbers = [1, 2, 3, 4, 5]

match numbers {
    [] => print("empty"),
    [x] => print("single: {x}"),
    [first, second] => print("pair: {first}, {second}"),
    [first, .., last] => print("first: {first}, last: {last}"),
    [head, tail @ ..] => print("head: {head}, tail has {tail.len()} elements"),
}
```

### Enum Destructuring

```home
enum Message {
    Quit,
    Move { x: i32, y: i32 },
    Write(string),
    ChangeColor(i32, i32, i32),
}

let msg = Message.Move { x: 10, y: 20 }

match msg {
    Message.Quit => print("quit"),
    Message.Move { x, y } => print("move to ({x}, {y})"),
    Message.Write(text) => print("message: {text}"),
    Message.ChangeColor(r, g, b) => print("color: rgb({r}, {g}, {b})"),
}
```

## Guard Clauses

Add additional conditions to patterns:

```home
let pair = (2, -2)

match pair {
    (x, y) if x == y => print("equal"),
    (x, y) if x + y == 0 => print("opposites"),
    (x, y) if x > y => print("{x} > {y}"),
    (x, y) => print("{x} <= {y}"),
}
```

### Complex Guards

```home
struct Request {
    method: string,
    path: string,
    authenticated: bool,
}

fn handle(req: Request) {
    match req {
        Request { method: "GET", path, .. } if path.starts_with("/public") => {
            serve_public(path)
        }
        Request { authenticated: false, .. } => {
            unauthorized()
        }
        Request { method: "GET", path, .. } => {
            serve_authenticated(path)
        }
        Request { method: "POST", path, .. } => {
            handle_post(path)
        }
        _ => not_found(),
    }
}
```

## Binding Patterns

### @ Bindings

Bind a value while also testing it against a pattern:

```home
let number = 5

match number {
    n @ 1..=5 => print("{n} is between 1 and 5"),
    n @ 6..=10 => print("{n} is between 6 and 10"),
    n => print("{n} is out of range"),
}
```

### Nested Bindings

```home
enum OptionalPoint {
    Some((i32, i32)),
    None,
}

let point = OptionalPoint.Some((3, 4))

match point {
    OptionalPoint.Some(coords @ (x, y)) if x > 0 && y > 0 => {
        print("positive quadrant: {coords:?}")
    }
    OptionalPoint.Some((x, y)) => print("point at ({x}, {y})"),
    OptionalPoint.None => print("no point"),
}
```

## If Let Expressions

Simplified pattern matching for single patterns:

```home
let maybe_number: ?i32 = 42

// Instead of full match
if let Some(n) = maybe_number {
    print("got {n}")
} else {
    print("nothing")
}
```

### Chained If Let

```home
enum Config {
    File(string),
    Env(string),
    Default,
}

fn load_config(primary: Config, fallback: Config) -> string {
    if let Config.File(path) = primary {
        read_file(path)
    } else if let Config.Env(var) = primary {
        env.get(var)
    } else if let Config.File(path) = fallback {
        read_file(path)
    } else {
        "default_config"
    }
}
```

## While Let Loops

Pattern matching in loop conditions:

```home
let mut stack = vec![1, 2, 3, 4, 5]

while let Some(top) = stack.pop() {
    print("popped: {top}")
}
```

### Iterator Processing

```home
let mut iter = [1, 2, 3, 4, 5].iter()

while let Some(n) = iter.next() {
    if n % 2 == 0 {
        print("even: {n}")
    }
}
```

## Let-Else Expressions

Destructure or diverge:

```home
fn process_user(data: ?UserData) -> Result<User, Error> {
    let Some(user_data) = data else {
        return Err(Error.new("no user data"))
    }

    let User { name, email, .. } = parse_user(user_data) else {
        return Err(Error.new("invalid user format"))
    }

    Ok(User { name, email })
}
```

## Pattern Matching in Function Parameters

```home
// Destructure in parameters
fn distance((x1, y1): (f64, f64), (x2, y2): (f64, f64)) -> f64 {
    let dx = x2 - x1
    let dy = y2 - y1
    (dx * dx + dy * dy).sqrt()
}

// Call with tuples
let d = distance((0.0, 0.0), (3.0, 4.0))  // 5.0
```

### Struct Parameter Destructuring

```home
struct Config {
    timeout: u64,
    retries: i32,
    verbose: bool,
}

fn connect({ timeout, retries, verbose }: Config) {
    if verbose {
        print("connecting with timeout={timeout}, retries={retries}")
    }
    // ...
}
```

## Refutable vs Irrefutable Patterns

### Irrefutable Patterns

Always match - used in `let`, function parameters, and `for` loops:

```home
// Always matches
let (x, y) = (1, 2)
let Point { x, y } = point

for (key, value) in map {
    // ...
}
```

### Refutable Patterns

May fail to match - require `if let`, `while let`, or `match`:

```home
// May not match
if let Some(x) = optional {
    // x is available here
}

// This would be a compile error:
// let Some(x) = optional  // Error: refutable pattern in irrefutable context
```

## Advanced Patterns

### Reference Patterns

```home
let reference = &42

match reference {
    &val => print("got value: {val}"),
}

// Or dereference in the match
match *reference {
    val => print("got value: {val}"),
}
```

### Mutable Bindings

```home
let mut point = (1, 2)

match point {
    (ref mut x, ref mut y) => {
        *x += 10
        *y += 20
    }
}

print("point is now: {point:?}")  // (11, 22)
```

### Nested Match Expressions

```home
let nested: Result<?i32, Error> = Ok(Some(42))

match nested {
    Ok(Some(n)) if n > 0 => print("positive: {n}"),
    Ok(Some(n)) => print("non-positive: {n}"),
    Ok(None) => print("ok but empty"),
    Err(e) => print("error: {e}"),
}
```

## Edge Cases

### Empty Patterns

```home
enum Never {}

fn handle_never(n: Never) -> i32 {
    // No patterns needed - type has no inhabitants
    match n {}
}
```

### Overlapping Patterns

Patterns are matched in order; earlier patterns take precedence:

```home
let n = 5

match n {
    1..=10 => print("1-10"),     // This matches
    5 => print("five"),          // Never reached for n=5
    _ => print("other"),
}
```

### Exhaustiveness Checking

The compiler ensures all cases are covered:

```home
enum Color {
    Red,
    Green,
    Blue,
}

let color = Color.Red

// Compile error: non-exhaustive patterns
// match color {
//     Color.Red => "red",
//     Color.Green => "green",
//     // Missing Color.Blue!
// }

// Correct
match color {
    Color.Red => "red",
    Color.Green => "green",
    Color.Blue => "blue",
}
```

## Best Practices

1. **Prefer exhaustive matching over wildcards**:
   ```home
   // Preferred - compiler catches new variants
   match status {
       Status.Active => handle_active(),
       Status.Pending => handle_pending(),
       Status.Inactive => handle_inactive(),
   }

   // Avoid when possible - hides new variants
   match status {
       Status.Active => handle_active(),
       _ => handle_other(),
   }
   ```

2. **Use destructuring to avoid field access**:
   ```home
   // Good
   let Point { x, y } = point
   let distance = (x * x + y * y).sqrt()

   // Less clear
   let distance = (point.x * point.x + point.y * point.y).sqrt()
   ```

3. **Guard clauses for complex conditions**:
   ```home
   // Good
   match user {
       User { age, .. } if age >= 18 => allow_access(),
       _ => deny_access(),
   }

   // Avoid nested if
   match user {
       User { age, .. } => {
           if age >= 18 {
               allow_access()
           } else {
               deny_access()
           }
       }
   }
   ```

4. **Use if-let for single pattern checks**:
   ```home
   // Good for single pattern
   if let Some(value) = optional {
       use_value(value)
   }

   // Match for multiple patterns
   match result {
       Ok(value) => use_value(value),
       Err(e) => handle_error(e),
   }
   ```

5. **Name bindings meaningfully**:
   ```home
   // Good
   match point {
       Point { x: horizontal, y: vertical } => {
           move_cursor(horizontal, vertical)
       }
   }

   // Less clear
   match point {
       Point { x: a, y: b } => move_cursor(a, b),
   }
   ```
