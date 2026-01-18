---
layout: home
title: Home Programming Language
hero:
  name: Home
  text: A Modern Systems Language
  tagline: Zig speed. Rust safety. TypeScript joy.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/home-lang/home
features:
  - title: Blazing Fast
    details: Compiles to native x64 code with performance rivaling C and Zig. Zero-cost abstractions and compile-time evaluation.
  - title: Memory Safe
    details: Ownership and borrowing without garbage collection. Catch use-after-move and memory errors at compile time.
  - title: Developer Joy
    details: TypeScript-inspired syntax that feels familiar and productive. Pattern matching, async/await, and modern ergonomics.
  - title: Systems Ready
    details: Build operating systems, game engines, and high-performance applications. First-class support for HomeOS.
---

# The Home Programming Language

Home is a modern programming language designed for systems programming, applications, and games. It combines the performance of Zig, the safety guarantees of Rust, and the developer experience of TypeScript.

## Quick Example

```home
fn main() {
  print("Hello, Home!")
}
```

## A Taste of Home

### Variables with Type Inference

```home
let name = "Alice"           // immutable by default
let mut counter = 0          // mutable with 'mut'
let age: int = 25            // explicit type annotation
const PI = 3.14159           // compile-time constant
```

### Functions and Generics

```home
fn add(a: int, b: int): int {
  return a + b
}

fn map<T, U>(items: []T, f: fn(T): U): []U {
  let result = []U.init(items.len)
  for (i, item in items) {
    result[i] = f(item)
  }
  return result
}
```

### Pattern Matching

```home
enum Result<T, E> {
  Ok(T),
  Err(E)
}

match read_file("config.home") {
  Ok(content) => process(content),
  Err(e) => print("Failed: {e}")
}
```

### Async/Await

```home
fn fetch_user(id: int): async Result<User> {
  let response = await http.get("/api/users/{id}")
  return await response.json()
}

fn main(): async {
  let user = await fetch_user(1)
  print("User: {user.name}")
}
```

### Memory Safety Without GC

```home
fn take_ownership(s: string): string {
  return s
}

let msg = "hello"
let msg2 = msg        // msg is moved
// print(msg)         // Compile error: use of moved value
print(msg2)           // Works fine
```

## Why Home?

| Feature | Home | Rust | Zig | TypeScript |
|---------|------|------|-----|------------|
| Memory Safety | Ownership | Ownership | Manual | GC |
| Performance | Native | Native | Native | JIT |
| Syntax | Familiar | Complex | Simple | Familiar |
| Compile Time | Fast | Slow | Fast | N/A |
| Learning Curve | Gentle | Steep | Moderate | Easy |

## Built for HomeOS

Home is the primary language for [HomeOS](https://github.com/home-lang/homeos), a modern operating system designed for the Raspberry Pi 5 and beyond. The language and OS are developed together, ensuring first-class support for systems programming.

See the [HomeOS documentation](/docs/os/) for more information on building operating system components with Home.

## Get Started

Ready to try Home? Head over to the [Getting Started](/guide/getting-started) guide to install the compiler and write your first program.

```bash
git clone https://github.com/home-lang/home.git
cd home
zig build
./zig-out/bin/home build examples/hello.home
./examples/hello
```

## Community

- [GitHub Repository](https://github.com/home-lang/home)
- [HomeOS Project](https://github.com/home-lang/homeos)
- [Contributing Guide](https://github.com/home-lang/home/blob/main/CONTRIBUTING.md)
