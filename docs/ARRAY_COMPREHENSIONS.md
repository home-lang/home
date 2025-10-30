# Array Comprehensions in Home

Array comprehensions provide a concise, readable syntax for creating and transforming collections. They combine mapping, filtering, and iteration into a single expression.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Filtering](#filtering)
- [Mapping](#mapping)
- [Nested Comprehensions](#nested-comprehensions)
- [Dictionary Comprehensions](#dictionary-comprehensions)
- [Set Comprehensions](#set-comprehensions)
- [Generator Expressions](#generator-expressions)
- [Best Practices](#best-practices)

## Basic Syntax

### Simple Array Comprehension

```home
// Basic syntax: [expression for variable in iterable]
let numbers = [1, 2, 3, 4, 5]
let doubled = [x * 2 for x in numbers]
// Result: [2, 4, 6, 8, 10]

// Identity comprehension
let copy = [x for x in numbers]
// Result: [1, 2, 3, 4, 5]
```

### Range-Based Comprehensions

```home
// Using range
let squares = [x * x for x in 0..10]
// Result: [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]

// With step
let evens = [x for x in 0..20 step 2]
// Result: [0, 2, 4, 6, 8, 10, 12, 14, 16, 18]
```

## Filtering

### With if Clause

```home
// Syntax: [expression for variable in iterable if condition]
let numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

// Filter even numbers
let evens = [x for x in numbers if x % 2 == 0]
// Result: [2, 4, 6, 8, 10]

// Filter and transform
let even_squares = [x * x for x in numbers if x % 2 == 0]
// Result: [4, 16, 36, 64, 100]
```

### Multiple Conditions

```home
// Multiple conditions with and
let filtered = [x for x in numbers if x > 3 and x < 8]
// Result: [4, 5, 6, 7]

// Complex conditions
let result = [x for x in numbers if x % 2 == 0 and x > 5]
// Result: [6, 8, 10]
```

## Mapping

### Transform Elements

```home
let names = ["alice", "bob", "charlie"]

// Uppercase
let upper = [name.to_uppercase() for name in names]
// Result: ["ALICE", "BOB", "CHARLIE"]

// String formatting
let greetings = ["Hello, {}!".format(name) for name in names]
// Result: ["Hello, alice!", "Hello, bob!", "Hello, charlie!"]
```

### Method Calls

```home
let strings = ["  hello  ", "  world  ", "  !  "]

// Trim whitespace
let trimmed = [s.trim() for s in strings]
// Result: ["hello", "world", "!"]

// Chain operations
let processed = [s.trim().to_uppercase() for s in strings]
// Result: ["HELLO", "WORLD", "!"]
```

## Nested Comprehensions

### Flattening Lists

```home
// Nested comprehension: [expr for x in iter1 for y in iter2]
let matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

// Flatten matrix
let flat = [x for row in matrix for x in row]
// Result: [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### Cartesian Product

```home
let colors = ["red", "green", "blue"]
let sizes = ["S", "M", "L"]

// All combinations
let products = [
    "{}-{}".format(color, size)
    for color in colors
    for size in sizes
]
// Result: ["red-S", "red-M", "red-L", "green-S", "green-M", "green-L", "blue-S", "blue-M", "blue-L"]
```

### Nested with Filter

```home
let matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

// Flatten and filter
let filtered = [x for row in matrix for x in row if x % 2 == 0]
// Result: [2, 4, 6, 8]

// Transform nested data
let doubled = [x * 2 for row in matrix for x in row if x > 3]
// Result: [8, 10, 12, 14, 16, 18]
```

## Dictionary Comprehensions

### Basic Dict Comprehension

```home
// Syntax: {key_expr: value_expr for variable in iterable}
let numbers = [1, 2, 3, 4, 5]

// Number to square mapping
let squares = {x: x * x for x in numbers}
// Result: {1: 1, 2: 4, 3: 9, 4: 16, 5: 25}

// String to length mapping
let names = ["alice", "bob", "charlie"]
let lengths = {name: name.len() for name in names}
// Result: {"alice": 5, "bob": 3, "charlie": 7}
```

### With Filtering

```home
let numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

// Only even numbers
let even_squares = {x: x * x for x in numbers if x % 2 == 0}
// Result: {2: 4, 4: 16, 6: 36, 8: 64, 10: 100}
```

### Transform Keys and Values

```home
let data = [("a", 1), ("b", 2), ("c", 3)]

// Uppercase keys, doubled values
let transformed = {
    k.to_uppercase(): v * 2
    for (k, v) in data
}
// Result: {"A": 2, "B": 4, "C": 6}
```

## Set Comprehensions

### Unique Elements

```home
// Syntax: {expression for variable in iterable}
let numbers = [1, 2, 2, 3, 3, 3, 4, 4, 4, 4]

// Unique values
let unique = {x for x in numbers}
// Result: {1, 2, 3, 4}

// Unique squares
let unique_squares = {x * x for x in numbers}
// Result: {1, 4, 9, 16}
```

### With Filtering

```home
let words = ["apple", "banana", "apricot", "blueberry", "avocado"]

// Unique first letters of words starting with 'a'
let first_letters = {
    word[0]
    for word in words
    if word.starts_with("a")
}
// Result: {'a'}
```

## Generator Expressions

### Lazy Evaluation

```home
// Syntax: (expression for variable in iterable)
// Generators are lazy - elements computed on demand

let numbers = 0..1000000

// Generator (doesn't compute all values immediately)
let squares = (x * x for x in numbers)

// Only computes values as needed
for square in squares.take(5) {
    println("{}", square)
}
// Prints: 0, 1, 4, 9, 16
```

### Memory Efficient

```home
// Array comprehension - creates full array in memory
let big_array = [x * x for x in 0..1000000]  // Uses lots of memory

// Generator - computes on demand
let big_gen = (x * x for x in 0..1000000)    // Minimal memory

// Use in sum
let sum = big_gen.sum()  // Efficient
```

## Best Practices

### 1. Keep It Simple

```home
// Good - clear and concise
let evens = [x for x in numbers if x % 2 == 0]

// Avoid - too complex
let result = [
    x * y + z
    for x in range1
    for y in range2
    for z in range3
    if x > y and y > z and (x + y) % 2 == 0
]  // Consider using regular loops
```

### 2. Use Meaningful Variable Names

```home
// Good
let user_names = [user.name for user in users]
let active_ids = [user.id for user in users if user.active]

// Avoid
let x = [u.n for u in us]
let y = [u.i for u in us if u.a]
```

### 3. Prefer Comprehensions for Simple Cases

```home
// Good - simple transformation
let doubled = [x * 2 for x in numbers]

// Avoid - use regular loop for complex logic
let result = []
for x in numbers {
    if complex_condition(x) {
        let processed = complex_processing(x)
        if another_condition(processed) {
            result.push(processed)
        }
    }
}
```

### 4. Use Generators for Large Data

```home
// Good - memory efficient
let sum = (x * x for x in 0..1000000).sum()

// Avoid - creates large array
let sum = [x * x for x in 0..1000000].sum()
```

### 5. Break Complex Comprehensions

```home
// Avoid - hard to read
let result = [x * y for x in range1 for y in range2 if x > 0 if y > 0 if x + y < 10]

// Good - break into steps
let positive_x = [x for x in range1 if x > 0]
let positive_y = [y for y in range2 if y > 0]
let result = [
    x * y
    for x in positive_x
    for y in positive_y
    if x + y < 10
]
```

## Common Patterns

### Filter and Map

```home
// Get lengths of long words
let words = ["a", "hello", "hi", "world", "hey"]
let long_lengths = [word.len() for word in words if word.len() > 2]
// Result: [5, 5, 3]
```

### Extract Fields

```home
struct User {
    name: string,
    age: i32,
    active: bool,
}

let users = [/* ... */]

// Extract names of active users
let active_names = [user.name for user in users if user.active]

// Extract ages
let ages = [user.age for user in users]
```

### Transform Data Structures

```home
// List of tuples to dict
let pairs = [("a", 1), ("b", 2), ("c", 3)]
let dict = {k: v for (k, v) in pairs}

// Dict to list of tuples
let items = [(k, v) for (k, v) in dict.items()]
```

### Conditional Expressions

```home
// Ternary in comprehension
let labels = [
    "even" if x % 2 == 0 else "odd"
    for x in 0..10
]
// Result: ["even", "odd", "even", "odd", ...]
```

### String Processing

```home
let text = "Hello World"

// Character codes
let codes = [c.to_code() for c in text]

// Uppercase vowels
let processed = [
    c.to_uppercase() if c in "aeiou" else c
    for c in text
]
```

## Examples

### Data Processing

```home
let data = [
    {"name": "Alice", "score": 85},
    {"name": "Bob", "score": 92},
    {"name": "Charlie", "score": 78},
    {"name": "Dave", "score": 95},
]

// High scorers
let high_scorers = [
    item["name"]
    for item in data
    if item["score"] >= 90
]
// Result: ["Bob", "Dave"]

// Score mapping
let scores = {item["name"]: item["score"] for item in data}
```

### Matrix Operations

```home
let matrix = [
    [1, 2, 3],
    [4, 5, 6],
    [7, 8, 9],
]

// Transpose
let transposed = [
    [row[i] for row in matrix]
    for i in 0..3
]
// Result: [[1, 4, 7], [2, 5, 8], [3, 6, 9]]

// Diagonal
let diagonal = [matrix[i][i] for i in 0..3]
// Result: [1, 5, 9]
```

### File Processing

```home
let lines = read_file("data.txt").lines()

// Non-empty lines
let content = [line for line in lines if line.trim().len() > 0]

// Parse numbers
let numbers = [
    line.parse::<i32>().unwrap()
    for line in lines
    if line.trim().len() > 0
]
```

## See Also

- [Iterators](ITERATORS.md) - Iterator methods
- [Closures](CLOSURES.md) - Anonymous functions
- [Collections](COLLECTIONS.md) - Arrays, sets, maps
