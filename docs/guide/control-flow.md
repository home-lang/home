# Control Flow

Home provides familiar control flow constructs with some powerful additions like pattern matching and expression-oriented design.

## If/Else Statements

Basic conditionals require parentheses around the condition:

```home
if (x > 5) {
  print("x is big")
}

if (age >= 18) {
  print("Adult")
} else {
  print("Minor")
}

if (score >= 90) {
  print("A")
} else if (score >= 80) {
  print("B")
} else if (score >= 70) {
  print("C")
} else {
  print("F")
}
```

### If Expressions

If statements can be used as expressions that return values:

```home
let status = if (code == 200) { "ok" } else { "error" }

let grade = if (score >= 90) {
  "A"
} else if (score >= 80) {
  "B"
} else if (score >= 70) {
  "C"
} else {
  "F"
}

// In function returns
fn abs(x: int): int {
  return if (x >= 0) { x } else { -x }
}
```

## While Loops

Execute while a condition is true:

```home
let mut count = 0

while (count < 5) {
  print(count)
  count = count + 1
}
```

### Break and Continue

Control loop execution:

```home
let mut i = 0
while (true) {
  i = i + 1

  if (i == 3) {
    continue  // Skip to next iteration
  }

  if (i > 5) {
    break  // Exit the loop
  }

  print(i)  // Prints: 1, 2, 4, 5
}
```

## For Loops

Iterate over ranges and collections:

### Range Iteration

```home
// Iterate 0 to 9
for (i in 0..10) {
  print(i)
}

// Iterate 1 to 10 (inclusive)
for (i in 1..=10) {
  print(i)
}

// Simple count iteration
for (i in 10) {
  print(i)  // 0 to 9
}
```

### Collection Iteration

```home
let items = ["apple", "banana", "cherry"]

for (item in items) {
  print(item)
}

// With index
for (index, item in items) {
  print("{index}: {item}")
}
```

### Step Iteration

```home
// Every other number
for (i in (0..10).step(2)) {
  print(i)  // 0, 2, 4, 6, 8
}

// Countdown
for (i in (10..0).step(-1)) {
  print(i)  // 10, 9, 8, ..., 1
}
```

## Match Expressions

Powerful pattern matching:

### Basic Matching

```home
let x = 2

match x {
  1 => print("one"),
  2 => print("two"),
  3 => print("three"),
  _ => print("other")  // Default case
}
```

### Match as Expression

```home
let name = match x {
  1 => "one",
  2 => "two",
  3 => "three",
  _ => "other"
}
```

### Matching Enums

```home
enum Color {
  Red,
  Green,
  Blue,
  Custom(r: int, g: int, b: int)
}

let color = Color.Custom(255, 128, 0)

match color {
  Color.Red => print("red"),
  Color.Green => print("green"),
  Color.Blue => print("blue"),
  Color.Custom(r, g, b) => print("rgb({r}, {g}, {b})")
}
```

### Matching Result Types

```home
match read_file("config.home") {
  Ok(content) => process(content),
  Err(e) => print("Failed: {e}")
}
```

### Guards

Add conditions to match arms:

```home
match x {
  n if n < 0 => print("negative"),
  n if n == 0 => print("zero"),
  n if n > 0 => print("positive"),
  _ => unreachable!()
}
```

### Multiple Patterns

Match multiple values in one arm:

```home
match x {
  1 | 2 | 3 => print("small"),
  4 | 5 | 6 => print("medium"),
  7 | 8 | 9 => print("large"),
  _ => print("other")
}
```

### Range Patterns

```home
match score {
  0..=59 => print("F"),
  60..=69 => print("D"),
  70..=79 => print("C"),
  80..=89 => print("B"),
  90..=100 => print("A"),
  _ => print("Invalid score")
}
```

### Destructuring in Patterns

```home
struct Point { x: int, y: int }

let point = Point { x: 10, y: 20 }

match point {
  Point { x: 0, y: 0 } => print("origin"),
  Point { x: 0, y } => print("on y-axis at {y}"),
  Point { x, y: 0 } => print("on x-axis at {x}"),
  Point { x, y } => print("at ({x}, {y})")
}
```

## Early Returns

Use `return` to exit a function early:

```home
fn find_user(id: int): Option<User> {
  if (id <= 0) {
    return None
  }

  let user = database.find(id)
  if (user.is_none()) {
    return None
  }

  return Some(user.unwrap())
}
```

### Guard Clauses

A common pattern for early validation:

```home
fn process_order(order: Order): Result<Receipt, Error> {
  // Guard clauses - check for invalid states first
  if (order.items.is_empty()) {
    return Err(Error.new("Order has no items"))
  }

  if (order.customer.is_none()) {
    return Err(Error.new("No customer specified"))
  }

  if (!order.is_valid()) {
    return Err(Error.new("Invalid order"))
  }

  // Main logic
  let total = calculate_total(order)
  let receipt = generate_receipt(order, total)
  return Ok(receipt)
}
```

## Loop Labels

Name loops to break or continue outer loops:

```home
'outer: for (i in 0..10) {
  for (j in 0..10) {
    if (i * j > 50) {
      break 'outer  // Breaks the outer loop
    }
    print("{i} * {j} = {i * j}")
  }
}
```

## Ternary-Style Expressions

Home uses if expressions instead of ternary operators:

```home
// Instead of: condition ? true_value : false_value
let value = if (condition) { true_value } else { false_value }

// Compact form for simple cases
let max = if (a > b) { a } else { b }
```

## Boolean Operators

Short-circuit evaluation:

```home
// && stops if left side is false
if (user != null && user.is_active()) {
  process(user)
}

// || stops if left side is true
let name = user?.name || "Anonymous"
```

## Exhaustive Matching

The compiler ensures all cases are handled:

```home
enum Status {
  Pending,
  Active,
  Completed,
  Failed
}

// This must handle all variants
fn describe(status: Status): string {
  match status {
    Status.Pending => "Waiting to start",
    Status.Active => "In progress",
    Status.Completed => "Done",
    Status.Failed => "Error occurred"
    // No _ needed - all cases covered
  }
}
```

## Next Steps

- [Structs and Enums](/guide/structs-enums) - Custom data types
- [Error Handling](/guide/error-handling) - Result types and the ? operator
- [Pattern Matching in Traits](/guide/traits) - Advanced matching
