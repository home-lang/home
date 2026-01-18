# Memory Safety

Home provides memory safety without garbage collection through an ownership system inspired by Rust, but with a gentler learning curve.

## Ownership Basics

Every value in Home has a single owner. When the owner goes out of scope, the value is automatically freed.

```home
fn main() {
  let s = "hello"  // s owns the string

  // s is valid here
  print(s)

}  // s goes out of scope, memory is freed
```

## Move Semantics

When you assign a value to another variable or pass it to a function, ownership moves:

```home
let s1 = "hello"
let s2 = s1        // s1 is moved to s2

// print(s1)       // Error: use of moved value 's1'
print(s2)          // OK: s2 now owns the string
```

### Function Arguments

Passing a value to a function moves it:

```home
fn consume(s: string) {
  print(s)
}

let msg = "hello"
consume(msg)       // msg is moved into the function

// print(msg)      // Error: use of moved value 'msg'
```

### Returning Values

Functions can transfer ownership back:

```home
fn create_greeting(): string {
  let s = "Hello, World!"
  return s         // Ownership is transferred to caller
}

let greeting = create_greeting()  // greeting now owns the string
print(greeting)
```

## Copy Types

Primitive types implement `Copy` and are copied instead of moved:

```home
let x = 42
let y = x          // x is copied, not moved

print(x)           // OK: x is still valid
print(y)           // OK: y has its own copy
```

Copy types include:
- All integer types (`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `int`)
- Floating-point types (`f32`, `f64`, `float`)
- `bool`
- `char`
- Tuples of copy types

## Borrowing

Instead of moving ownership, you can borrow a reference:

### Immutable References (`&`)

```home
fn print_length(s: &string) {
  print("Length: {s.len()}")
}

let msg = "hello"
print_length(&msg)   // Borrow msg
print(msg)           // msg is still valid
```

You can have multiple immutable references:

```home
let s = "hello"
let r1 = &s
let r2 = &s
let r3 = &s

print("{r1}, {r2}, {r3}")  // All valid
```

### Mutable References (`&mut`)

To modify borrowed data, use a mutable reference:

```home
fn append_world(s: &mut string) {
  s.push_str(", World!")
}

let mut greeting = "Hello"
append_world(&mut greeting)
print(greeting)  // "Hello, World!"
```

### Borrowing Rules

1. You can have either:
   - Any number of immutable references (`&T`), OR
   - Exactly one mutable reference (`&mut T`)

2. References must always be valid (no dangling references)

```home
let mut s = "hello"

let r1 = &s     // OK: immutable borrow
let r2 = &s     // OK: another immutable borrow
// let r3 = &mut s  // Error: cannot borrow mutably while immutably borrowed

print("{r1}, {r2}")

// Immutable borrows end here
let r3 = &mut s  // OK: now we can borrow mutably
r3.push_str("!")
```

## The Borrow Checker

Home's borrow checker ensures memory safety at compile time:

### Use After Move

```home
let s1 = "hello"
let s2 = s1        // s1 is moved

// print(s1)       // Compile Error: use of moved value
```

### Invalid References

```home
fn dangling(): &string {
  let s = "hello"
  return &s        // Compile Error: s is dropped here
}
```

### Conflicting Borrows

```home
let mut v = [1, 2, 3]
let first = &v[0]

v.push(4)          // Compile Error: cannot mutate while borrowed

print(first)
```

## Lifetimes

Lifetimes ensure references are valid for as long as they're used:

```home
fn longest<'a>(x: &'a string, y: &'a string): &'a string {
  if (x.len() > y.len()) { x } else { y }
}

let s1 = "short"
let result

{
  let s2 = "longer string"
  result = longest(&s1, &s2)
  print(result)    // OK: s2 is still valid
}

// print(result)   // Would be error: s2 is dropped
```

### Lifetime Elision

Many cases don't require explicit lifetimes:

```home
// These are equivalent:
fn first_word(s: &string): &string { ... }
fn first_word<'a>(s: &'a string): &'a string { ... }
```

## Smart Pointers

### Box - Heap Allocation

```home
let b = Box.new(5)
print(b)  // 5

// Useful for recursive types
enum List<T> {
  Cons(T, Box<List<T>>),
  Nil
}
```

### Rc - Reference Counting

For shared ownership:

```home
use std::rc::Rc

let data = Rc.new([1, 2, 3])
let data2 = data.clone()  // Increases reference count

print("Count: {Rc.strong_count(&data)}")  // 2
```

### Arc - Thread-Safe Reference Counting

For sharing across threads:

```home
use std::sync::Arc

let data = Arc.new([1, 2, 3])

spawn(|| {
  let local = data.clone()
  print(local)
})
```

## Interior Mutability

Sometimes you need to mutate through an immutable reference:

### RefCell

```home
use std::cell::RefCell

struct Counter {
  value: RefCell<int>
}

impl Counter {
  fn increment(&self) {  // Note: &self, not &mut self
    *self.value.borrow_mut() += 1
  }
}
```

### Mutex

For thread-safe interior mutability:

```home
use std::sync::Mutex

let counter = Mutex.new(0)

spawn(|| {
  let mut num = counter.lock()
  *num += 1
})
```

## Patterns for Safety

### Clone When Needed

```home
let original = "hello"
let copy = original.clone()  // Explicit copy

process(copy)
print(original)  // Still valid
```

### Take Ownership

```home
struct Config {
  data: string
}

impl Config {
  fn into_data(self): string {
    self.data  // Takes ownership of self
  }
}
```

### Temporary Borrows

```home
let mut v = [1, 2, 3]

{
  let first = &v[0]  // Borrow starts
  print(first)
}  // Borrow ends

v.push(4)  // OK: no active borrows
```

## Common Patterns

### Builder Pattern

```home
struct Request {
  url: string,
  method: string,
  body: Option<string>
}

impl Request {
  fn new(url: string): Request {
    Request { url, method: "GET", body: None }
  }

  fn method(mut self, method: string): Request {
    self.method = method
    self
  }

  fn body(mut self, body: string): Request {
    self.body = Some(body)
    self
  }
}

let req = Request.new("https://api.example.com")
  .method("POST")
  .body("{}")
```

### RAII (Resource Acquisition Is Initialization)

```home
struct File {
  handle: FileHandle
}

impl File {
  fn open(path: string): Result<File, Error> {
    let handle = open_file(path)?
    Ok(File { handle })
  }
}

impl Drop for File {
  fn drop(&mut self) {
    close_file(self.handle)
  }
}

// File is automatically closed when it goes out of scope
{
  let file = File.open("data.txt")?
  // Use file...
}  // File is closed here
```

## Next Steps

- [Async Programming](/guide/async) - Memory safety with async code
- [Traits](/guide/traits) - Clone, Copy, and Drop traits
- [Standard Library](/reference/stdlib) - Safe abstractions
