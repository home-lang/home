# Closures in Home

Closures are anonymous functions that can capture variables from their surrounding scope. Home's closure system is inspired by Rust, providing powerful capture semantics with compile-time safety.

## Table of Contents

- [Basic Syntax](#basic-syntax)
- [Capture Modes](#capture-modes)
- [Closure Traits](#closure-traits)
- [Type Inference](#type-inference)
- [Move Closures](#move-closures)
- [Returning Closures](#returning-closures)
- [Higher-Order Functions](#higher-order-functions)
- [Async Closures](#async-closures)
- [Best Practices](#best-practices)

## Basic Syntax

### Simple Closures

```home
// No parameters
let greet = || println("Hello!")
greet()

// Single parameter
let double = |x| x * 2
let result = double(5)  // 10

// Multiple parameters
let add = |a, b| a + b
let sum = add(3, 4)  // 7

// With block body
let complex = |x| {
    let y = x * 2
    y + 1
}
```

### With Type Annotations

```home
// Parameter types
let add: fn(i32, i32) -> i32 = |a: i32, b: i32| a + b

// Return type
let double = |x: i32| -> i32 { x * 2 }

// Full annotation
let multiply = |a: f64, b: f64| -> f64 {
    a * b
}
```

## Capture Modes

Home closures can capture variables in different ways:

### By Reference (Immutable)

Default capture mode - borrows variables immutably.

```home
let x = 42
let print_x = || println("x = {}", x)  // Captures &x
print_x()
println("{}", x)  // x is still accessible
```

### By Mutable Reference

Captures variables mutably when needed.

```home
let mut count = 0
let increment = || {
    count += 1  // Captures &mut count
}
increment()
increment()
println("{}", count)  // 2
```

### By Move

Takes ownership of captured variables using the `move` keyword.

```home
let data = vec![1, 2, 3]
let consume = move || {
    println("{:?}", data)  // Owns data
}
consume()
// data is no longer accessible here
```

### By Value (Copy)

For types that implement `Copy`, captures create a copy.

```home
let x = 42  // i32 implements Copy
let closure = || x + 1  // Captures copy of x
println("{}", x)  // x is still accessible
```

## Closure Traits

Home uses three closure traits (like Rust) to represent different calling conventions:

### Fn - Immutable Borrow

Can be called multiple times, captures by reference.

```home
trait Fn<Args> {
    type Output
    fn call(&self, args: Args) -> Self::Output
}

// Example
let x = 10
let add_x: impl Fn(i32) -> i32 = |y| x + y
println("{}", add_x(5))  // 15
println("{}", add_x(10)) // 20
```

### FnMut - Mutable Borrow

Can be called multiple times, captures by mutable reference.

```home
trait FnMut<Args>: Fn<Args> {
    fn call_mut(&mut self, args: Args) -> Self::Output
}

// Example
let mut count = 0
let mut increment: impl FnMut() = || {
    count += 1
}
increment()
increment()
println("{}", count)  // 2
```

### FnOnce - Consume

Can be called only once, takes ownership of captures.

```home
trait FnOnce<Args> {
    type Output
    fn call_once(self, args: Args) -> Self::Output
}

// Example
let data = String::from("Hello")
let consume: impl FnOnce() = move || {
    println("{}", data)
    // data is consumed here
}
consume()
// consume() // Error: already called
```

## Type Inference

Home infers closure types from usage:

```home
// Type inferred from usage
let numbers = vec![1, 2, 3, 4, 5]
let doubled = numbers.map(|x| x * 2)

// Explicit types when needed
let parse: fn(&str) -> Result<i32, Error> = |s| {
    s.parse()
}

// Generic closures
fn apply<F>(f: F, x: i32) -> i32 
where 
    F: Fn(i32) -> i32
{
    f(x)
}

let result = apply(|x| x + 1, 5)  // 6
```

## Move Closures

Use `move` to transfer ownership of captured variables:

```home
fn create_closure() -> impl Fn() -> i32 {
    let x = 42
    move || x  // x is moved into closure
}

let closure = create_closure()
println("{}", closure())  // 42
```

### When to Use Move

1. **Returning closures** - Must move captures to avoid dangling references
2. **Threading** - Send closures to other threads
3. **Ownership transfer** - When you want the closure to own its data

```home
// Threading example
let data = vec![1, 2, 3]
let handle = thread::spawn(move || {
    println("{:?}", data)  // Owns data
})
handle.join()
```

## Returning Closures

Closures can be returned using trait objects or `impl Trait`:

### Using impl Trait

```home
fn make_adder(x: i32) -> impl Fn(i32) -> i32 {
    move |y| x + y
}

let add_5 = make_adder(5)
println("{}", add_5(10))  // 15
```

### Using Box<dyn Fn>

```home
fn make_closure(choice: bool) -> Box<dyn Fn(i32) -> i32> {
    if choice {
        Box::new(|x| x * 2)
    } else {
        Box::new(|x| x + 10)
    }
}

let closure = make_closure(true)
println("{}", closure(5))  // 10
```

## Higher-Order Functions

Closures enable functional programming patterns:

### Map, Filter, Reduce

```home
let numbers = vec![1, 2, 3, 4, 5]

// Map
let doubled = numbers.iter()
    .map(|x| x * 2)
    .collect()

// Filter
let evens = numbers.iter()
    .filter(|x| x % 2 == 0)
    .collect()

// Reduce (fold)
let sum = numbers.iter()
    .fold(0, |acc, x| acc + x)
```

### Custom Higher-Order Functions

```home
fn apply_twice<F>(f: F, x: i32) -> i32 
where 
    F: Fn(i32) -> i32
{
    f(f(x))
}

let result = apply_twice(|x| x + 1, 5)  // 7

fn compose<F, G, A, B, C>(f: F, g: G) -> impl Fn(A) -> C
where
    F: Fn(B) -> C,
    G: Fn(A) -> B,
{
    move |x| f(g(x))
}

let add_one = |x| x + 1
let double = |x| x * 2
let add_then_double = compose(double, add_one)
println("{}", add_then_double(5))  // 12
```

## Async Closures

Closures can be async for asynchronous operations:

```home
// Async closure
let fetch = async || {
    let response = http::get("https://api.example.com").await?
    response.json().await
}

// Using async closures
async fn process_data<F, Fut>(f: F) -> Result<()>
where
    F: Fn() -> Fut,
    Fut: Future<Output = Result<Data>>,
{
    let data = f().await?
    // Process data
    Ok(())
}

process_data(async || {
    fetch_from_api().await
}).await?
```

## Best Practices

### 1. Prefer Borrowing Over Moving

```home
// Good - borrows
let x = vec![1, 2, 3]
let print = || println("{:?}", x)
print()
println("{:?}", x)  // x still accessible

// Only use move when necessary
let consume = move || println("{:?}", x)
```

### 2. Use Type Inference

```home
// Good - let compiler infer
numbers.map(|x| x * 2)

// Unnecessary - explicit types
numbers.map(|x: i32| -> i32 { x * 2 })
```

### 3. Keep Closures Small

```home
// Good - focused closure
let is_even = |x| x % 2 == 0
numbers.filter(is_even)

// Avoid - too complex
numbers.filter(|x| {
    let result = complex_calculation(x)
    let adjusted = adjust_value(result)
    validate(adjusted) && check_bounds(adjusted)
})
```

### 4. Name Closures for Clarity

```home
// Good - named for reuse
let is_positive = |x| x > 0
let is_even = |x| x % 2 == 0

numbers.filter(is_positive).filter(is_even)

// Avoid - inline everything
numbers.filter(|x| x > 0).filter(|x| x % 2 == 0)
```

### 5. Use Move for Thread Safety

```home
// Good - move for threads
let data = vec![1, 2, 3]
thread::spawn(move || {
    process(data)
})

// Error - can't borrow across threads
thread::spawn(|| {
    process(data)  // Error!
})
```

## Limitations

Current limitations of Home closures:

1. **No recursive closures** - Closures cannot directly call themselves
2. **Limited type inference** - Some complex cases require explicit types
3. **No closure in const** - Closures cannot be used in const contexts

### Workarounds

```home
// Recursive function instead of recursive closure
fn factorial(n: i32) -> i32 {
    if n <= 1 { 1 } else { n * factorial(n - 1) }
}

// Use Y-combinator for recursive closures (advanced)
let factorial = fix(|f| move |n| {
    if n <= 1 { 1 } else { n * f(n - 1) }
})
```

## Examples

### Event Handlers

```home
struct Button {
    on_click: Box<dyn FnMut()>,
}

impl Button {
    fn new<F>(handler: F) -> Button 
    where 
        F: FnMut() + 'static
    {
        Button {
            on_click: Box::new(handler),
        }
    }
    
    fn click(&mut self) {
        (self.on_click)()
    }
}

let mut count = 0
let mut button = Button::new(move || {
    count += 1
    println("Clicked {} times", count)
})

button.click()  // Clicked 1 times
button.click()  // Clicked 2 times
```

### Lazy Evaluation

```home
struct Lazy<T, F>
where
    F: FnOnce() -> T,
{
    init: Option<F>,
    value: Option<T>,
}

impl<T, F> Lazy<T, F>
where
    F: FnOnce() -> T,
{
    fn new(init: F) -> Lazy<T, F> {
        Lazy {
            init: Some(init),
            value: None,
        }
    }
    
    fn get(&mut self) -> &T {
        if self.value.is_none() {
            let init = self.init.take().unwrap()
            self.value = Some(init())
        }
        self.value.as_ref().unwrap()
    }
}

let mut lazy = Lazy::new(|| {
    println("Computing...")
    expensive_computation()
})

// Not computed yet
println("Before")
let value = lazy.get()  // Prints "Computing..."
let value2 = lazy.get() // Uses cached value
```

### Builder Pattern with Closures

```home
struct QueryBuilder {
    filters: Vec<Box<dyn Fn(&Record) -> bool>>,
}

impl QueryBuilder {
    fn new() -> QueryBuilder {
        QueryBuilder { filters: vec![] }
    }
    
    fn filter<F>(mut self, f: F) -> QueryBuilder
    where
        F: Fn(&Record) -> bool + 'static,
    {
        self.filters.push(Box::new(f))
        self
    }
    
    fn execute(&self, records: &[Record]) -> Vec<&Record> {
        records.iter()
            .filter(|r| self.filters.iter().all(|f| f(r)))
            .collect()
    }
}

let results = QueryBuilder::new()
    .filter(|r| r.age > 18)
    .filter(|r| r.active)
    .filter(|r| r.score > 50)
    .execute(&records)
```

## See Also

- [Functions](FUNCTIONS.md) - Regular function definitions
- [Traits](TRAITS.md) - Fn, FnMut, FnOnce traits
- [Generics](GENERICS.md) - Generic closures
- [Async](ASYNC.md) - Async closures
