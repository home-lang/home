# Generics

Generics enable writing flexible, reusable code that works with multiple types while maintaining full type safety. Home's generics are monomorphized at compile time, providing zero runtime overhead.

## Overview

Home's generic system provides:

- **Type parameters**: Abstract over types in functions, structs, and traits
- **Trait bounds**: Constrain type parameters to types implementing specific traits
- **Associated types**: Define types within traits that implementors specify
- **Const generics**: Parameterize over compile-time constant values
- **Zero-cost abstraction**: Full monomorphization eliminates runtime dispatch

## Generic Functions

### Basic Generic Functions

```home
fn identity<T>(value: T) -> T {
    value
}

let int_val = identity(42)        // T = i32
let str_val = identity("hello")   // T = string
```

### Multiple Type Parameters

```home
fn pair<A, B>(first: A, second: B) -> (A, B) {
    (first, second)
}

let p = pair(1, "one")  // (i32, string)
```

### Type Inference

The compiler infers type parameters when possible:

```home
fn first<T>(items: []T) -> ?T {
    if items.len() > 0 {
        Some(items[0])
    } else {
        null
    }
}

let numbers = [1, 2, 3]
let f = first(numbers)  // T inferred as i32
```

### Explicit Type Annotation

When inference is insufficient:

```home
fn create<T: Default>() -> T {
    T.default()
}

// Must specify type explicitly
let n: i32 = create()
let s: string = create()

// Or use turbofish syntax
let n = create::<i32>()
let s = create::<string>()
```

## Generic Structs

### Basic Generic Structs

```home
struct Box<T> {
    value: T,
}

impl<T> Box<T> {
    fn new(value: T) -> Self {
        Box { value }
    }

    fn get(self) -> T {
        self.value
    }

    fn get_ref(&self) -> &T {
        &self.value
    }
}

let int_box = Box.new(42)
let str_box = Box.new("hello")
```

### Multiple Type Parameters in Structs

```home
struct Pair<A, B> {
    first: A,
    second: B,
}

impl<A, B> Pair<A, B> {
    fn new(first: A, second: B) -> Self {
        Pair { first, second }
    }

    fn swap(self) -> Pair<B, A> {
        Pair { first: self.second, second: self.first }
    }
}

let pair = Pair.new(1, "one")
let swapped = pair.swap()  // Pair<string, i32>
```

## Generic Enums

```home
enum Option<T> {
    Some(T),
    None,
}

enum Result<T, E> {
    Ok(T),
    Err(E),
}

impl<T, E> Result<T, E> {
    fn is_ok(self) -> bool {
        match self {
            Result.Ok(_) => true,
            Result.Err(_) => false,
        }
    }

    fn map<U>(self, f: fn(T) -> U) -> Result<U, E> {
        match self {
            Result.Ok(value) => Result.Ok(f(value)),
            Result.Err(error) => Result.Err(error),
        }
    }
}
```

## Trait Bounds

### Single Trait Bound

```home
trait Display {
    fn to_string(self) -> string
}

fn print_value<T: Display>(value: T) {
    print(value.to_string())
}
```

### Multiple Trait Bounds

```home
fn clone_and_print<T: Clone + Display>(value: T) {
    let copy = value.clone()
    print(copy.to_string())
}
```

### Where Clauses

For complex bounds, use where clauses:

```home
fn process<T, U>(a: T, b: U) -> T
where
    T: Clone + From<U>,
    U: Display + Into<T>,
{
    if a.clone().to_string() == b.to_string() {
        a
    } else {
        b.into()
    }
}
```

### Bound Propagation

Bounds in struct definitions propagate to implementations:

```home
struct SortedList<T: Ord> {
    items: Vec<T>,
}

impl<T: Ord> SortedList<T> {
    fn insert(mut self, item: T) {
        let pos = self.items.binary_search(&item).unwrap_or_else(|i| i)
        self.items.insert(pos, item)
    }
}
```

## Associated Types

### Defining Associated Types

```home
trait Iterator {
    type Item

    fn next(mut self) -> ?Self.Item
}

trait Container {
    type Element
    type Iter: Iterator<Item = Self.Element>

    fn iter(&self) -> Self.Iter
    fn len(&self) -> usize
}
```

### Implementing Associated Types

```home
struct Counter {
    current: i32,
    max: i32,
}

impl Iterator for Counter {
    type Item = i32

    fn next(mut self) -> ?i32 {
        if self.current < self.max {
            let value = self.current
            self.current += 1
            Some(value)
        } else {
            null
        }
    }
}
```

### Associated Type Bounds

```home
fn sum_iterator<I>(iter: I) -> i32
where
    I: Iterator<Item = i32>,
{
    let mut total = 0
    while let Some(n) = iter.next() {
        total += n
    }
    total
}
```

## Const Generics

### Basic Const Generics

```home
struct Array<T, const N: usize> {
    data: [T; N],
}

impl<T: Default + Copy, const N: usize> Array<T, N> {
    fn new() -> Self {
        Array { data: [T.default(); N] }
    }

    fn len(self) -> usize {
        N
    }

    fn get(&self, index: usize) -> ?&T {
        if index < N {
            Some(&self.data[index])
        } else {
            null
        }
    }
}

let arr: Array<i32, 5> = Array.new()
assert(arr.len() == 5)
```

### Const Generic Expressions

```home
fn concat<T, const A: usize, const B: usize>(
    first: [T; A],
    second: [T; B]
) -> [T; A + B] {
    let mut result: [T; A + B] = undefined

    for i in 0..A {
        result[i] = first[i]
    }
    for i in 0..B {
        result[A + i] = second[i]
    }

    result
}

let a = [1, 2, 3]
let b = [4, 5]
let c = concat(a, b)  // [1, 2, 3, 4, 5]: [i32; 5]
```

### Const Generic Bounds

```home
struct Matrix<T, const ROWS: usize, const COLS: usize>
where
    const ROWS > 0,
    const COLS > 0,
{
    data: [[T; COLS]; ROWS],
}

impl<T: Default + Copy, const R: usize, const C: usize> Matrix<T, R, C>
where
    const R > 0,
    const C > 0,
{
    fn identity() -> Self where T: From<i32>, const R == C {
        let mut data = [[T.default(); C]; R]
        for i in 0..R {
            data[i][i] = T.from(1)
        }
        Matrix { data }
    }
}
```

## Generic Traits

### Traits with Type Parameters

```home
trait From<T> {
    fn from(value: T) -> Self
}

trait Into<T> {
    fn into(self) -> T
}

// Blanket implementation
impl<T, U: From<T>> Into<U> for T {
    fn into(self) -> U {
        U.from(self)
    }
}
```

### Generic Method Traits

```home
trait Convertible {
    fn convert<T>(self) -> T where Self: Into<T>
}

impl<U> Convertible for U {
    fn convert<T>(self) -> T where Self: Into<T> {
        self.into()
    }
}
```

## Higher-Kinded Type Patterns

While Home doesn't have first-class HKTs, patterns can achieve similar results:

### Functor Pattern

```home
trait Functor {
    type Inner

    fn map<U>(self, f: fn(Self.Inner) -> U) -> Self with Inner = U
}

impl<T> Functor for Option<T> {
    type Inner = T

    fn map<U>(self, f: fn(T) -> U) -> Option<U> {
        match self {
            Some(value) => Some(f(value)),
            None => None,
        }
    }
}
```

### Monad Pattern

```home
trait Monad: Functor {
    fn pure(value: Self.Inner) -> Self
    fn flat_map<U>(self, f: fn(Self.Inner) -> Self with Inner = U) -> Self with Inner = U
}

impl<T> Monad for Option<T> {
    fn pure(value: T) -> Option<T> {
        Some(value)
    }

    fn flat_map<U>(self, f: fn(T) -> Option<U>) -> Option<U> {
        match self {
            Some(value) => f(value),
            None => None,
        }
    }
}
```

## Phantom Types

Use type parameters without storing them:

```home
struct Id<T, phantom Entity> {
    value: T,
}

struct User {}
struct Order {}

type UserId = Id<u64, User>
type OrderId = Id<u64, Order>

fn get_user(id: UserId) -> User { /* ... */ }
fn get_order(id: OrderId) -> Order { /* ... */ }

let user_id: UserId = Id { value: 1 }
let order_id: OrderId = Id { value: 1 }

// Type error: cannot pass OrderId where UserId expected
// get_user(order_id)  // Compile error
```

## Generic Impl Blocks

### Conditional Implementations

```home
struct Wrapper<T> {
    value: T,
}

// Always available
impl<T> Wrapper<T> {
    fn new(value: T) -> Self {
        Wrapper { value }
    }
}

// Only for Display types
impl<T: Display> Wrapper<T> {
    fn print(&self) {
        print(self.value.to_string())
    }
}

// Only for numeric types
impl<T: Add<Output = T> + Copy> Wrapper<T> {
    fn double(&self) -> T {
        self.value + self.value
    }
}
```

### Specialization (Limited)

```home
trait Process {
    fn process(self) -> string
}

// Default implementation
impl<T: Display> Process for T {
    fn process(self) -> string {
        self.to_string()
    }
}

// Specialized for specific types
impl Process for i32 {
    fn process(self) -> string {
        "integer: " + self.to_string()
    }
}
```

## Edge Cases

### Recursive Bounds

```home
trait Comparable<T> {
    fn compare(self, other: T) -> Ordering
}

// Self-referential bound
impl<T: Comparable<T>> Sortable for Vec<T> {
    fn sort(mut self) {
        // Can compare elements to each other
    }
}
```

### Inference Limitations

```home
fn problematic<T, U>(value: T) -> U
where
    T: Into<U>,
{
    value.into()
}

// Must annotate - can't infer U from context alone
let result: f64 = problematic(42i32)
```

### Type Parameter Ordering

```home
// Good: most important/frequently specified first
fn collect<T, I: Iterator<Item = T>>(iter: I) -> Vec<T>

// Usage: only need to specify T
let v = collect::<i32, _>(iter)
```

## Best Practices

1. **Use trait bounds judiciously**:
   ```home
   // Only bound what you actually use
   fn process<T: Clone>(value: T) -> T {
       value.clone()
   }

   // Don't over-constrain
   fn just_hold<T>(value: T) -> T {
       value  // No bounds needed
   }
   ```

2. **Prefer associated types for unique mappings**:
   ```home
   // Good: each Iterator has one Item type
   trait Iterator {
       type Item
       fn next(mut self) -> ?Self.Item
   }

   // Use generic params for multiple implementations
   trait From<T> {
       fn from(value: T) -> Self
   }
   ```

3. **Use where clauses for readability**:
   ```home
   // Hard to read
   fn foo<T: Clone + Debug + Send + Sync, U: From<T> + Default>(a: T, b: U)

   // Better
   fn foo<T, U>(a: T, b: U)
   where
       T: Clone + Debug + Send + Sync,
       U: From<T> + Default,
   ```

4. **Consider turbofish for explicit instantiation**:
   ```home
   // When type inference fails
   let parsed = parse::<i32>("42")
   let collected = iter.collect::<Vec<_>>()
   ```

5. **Document type parameter meanings**:
   ```home
   /// A mapping from keys to values.
   ///
   /// # Type Parameters
   /// * `K` - The key type, must be hashable and comparable
   /// * `V` - The value type
   struct HashMap<K: Hash + Eq, V> { /* ... */ }
   ```
