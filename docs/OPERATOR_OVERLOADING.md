# Operator Overloading in Home

Home supports operator overloading through a trait-based system, similar to Rust. This provides type-safe, explicit operator overloading that integrates seamlessly with the trait system.

## Overview

Operators in Home are implemented via special traits. When you use an operator like `+`, the compiler looks for an implementation of the `Add` trait and desugars the expression into a method call.

```home
// This expression:
let result = a + b

// Is desugared to:
let result = a.add(b)
```

## Arithmetic Operators

### Add (+)

```home
trait Add<Rhs = Self> {
    type Output
    fn add(self, rhs: Rhs): Self::Output
}

// Example implementation
struct Vector2 {
    x: f64,
    y: f64,
}

impl Add for Vector2 {
    type Output = Vector2
    
    fn add(self, rhs: Vector2): Vector2 {
        Vector2 {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
        }
    }
}

// Usage
let v1 = Vector2 { x: 1.0, y: 2.0 }
let v2 = Vector2 { x: 3.0, y: 4.0 }
let v3 = v1 + v2  // Calls v1.add(v2)
```

### Sub (-), Mul (*), Div (/), Rem (%)

Similar to `Add`, these traits allow overloading subtraction, multiplication, division, and remainder operations.

```home
impl Sub for Vector2 {
    type Output = Vector2
    fn sub(self, rhs: Vector2): Vector2 { ... }
}

impl Mul<f64> for Vector2 {
    type Output = Vector2
    fn mul(self, scalar: f64): Vector2 {
        Vector2 {
            x: self.x * scalar,
            y: self.y * scalar,
        }
    }
}
```

## Unary Operators

### Neg (unary -)

```home
trait Neg {
    type Output
    fn neg(self): Self::Output
}

impl Neg for Vector2 {
    type Output = Vector2
    fn neg(self): Vector2 {
        Vector2 { x: -self.x, y: -self.y }
    }
}

let v = Vector2 { x: 1.0, y: 2.0 }
let negated = -v  // Calls v.neg()
```

### Not (!)

```home
trait Not {
    type Output
    fn not(self): Self::Output
}

impl Not for bool {
    type Output = bool
    fn not(self): bool {
        !self  // Built-in implementation
    }
}
```

## Bitwise Operators

### BitAnd (&), BitOr (|), BitXor (^)

```home
struct Flags {
    bits: u32,
}

impl BitOr for Flags {
    type Output = Flags
    fn bitor(self, rhs: Flags): Flags {
        Flags { bits: self.bits | rhs.bits }
    }
}

let flags = FLAG_READ | FLAG_WRITE  // Calls FLAG_READ.bitor(FLAG_WRITE)
```

### Shl (<<), Shr (>>)

```home
impl Shl<u32> for u64 {
    type Output = u64
    fn shl(self, rhs: u32): u64 {
        self << rhs  // Built-in implementation
    }
}
```

## Compound Assignment Operators

### AddAssign (+=), SubAssign (-=), etc.

```home
trait AddAssign<Rhs = Self> {
    fn add_assign(&mut self, rhs: Rhs): void
}

impl AddAssign for Vector2 {
    fn add_assign(&mut self, rhs: Vector2): void {
        self.x += rhs.x
        self.y += rhs.y
    }
}

let mut v = Vector2 { x: 1.0, y: 2.0 }
v += Vector2 { x: 3.0, y: 4.0 }  // Calls v.add_assign(...)
```

## Indexing Operators

### Index ([])

```home
trait Index<Idx> {
    type Output
    fn index(&self, index: Idx): &Self::Output
}

trait IndexMut<Idx>: Index<Idx> {
    fn index_mut(&mut self, index: Idx): &mut Self::Output
}

// Example: Custom array type
struct MyArray<T> {
    data: [T; 10],
}

impl<T> Index<usize> for MyArray<T> {
    type Output = T
    
    fn index(&self, index: usize): &T {
        &self.data[index]
    }
}

impl<T> IndexMut<usize> for MyArray<T> {
    fn index_mut(&mut self, index: usize): &mut T {
        &mut self.data[index]
    }
}

let arr = MyArray { data: [1, 2, 3, ...] }
let value = arr[0]  // Calls arr.index(0)
arr[1] = 42         // Calls arr.index_mut(1)
```

## Deref Operator

### Deref (*), DerefMut

```home
trait Deref {
    type Target
    fn deref(&self): &Self::Target
}

trait DerefMut: Deref {
    fn deref_mut(&mut self): &mut Self::Target
}

// Smart pointer example
struct Box<T> {
    ptr: *T,
}

impl<T> Deref for Box<T> {
    type Target = T
    
    fn deref(&self): &T {
        unsafe { &*self.ptr }
    }
}

let boxed = Box::new(42)
let value = *boxed  // Calls boxed.deref()
```

## Generic Operator Implementations

You can implement operators for different right-hand side types:

```home
// Vector + Vector
impl Add for Vector2 {
    type Output = Vector2
    fn add(self, rhs: Vector2): Vector2 { ... }
}

// Vector + scalar
impl Add<f64> for Vector2 {
    type Output = Vector2
    fn add(self, scalar: f64): Vector2 {
        Vector2 {
            x: self.x + scalar,
            y: self.y + scalar,
        }
    }
}

let v = Vector2 { x: 1.0, y: 2.0 }
let v2 = v + Vector2 { x: 3.0, y: 4.0 }  // Vector + Vector
let v3 = v + 5.0                          // Vector + f64
```

## Operator Trait Reference

### Binary Operators

| Operator | Trait | Method | Description |
|----------|-------|--------|-------------|
| `+` | `Add<Rhs>` | `add(self, rhs: Rhs): Output` | Addition |
| `-` | `Sub<Rhs>` | `sub(self, rhs: Rhs): Output` | Subtraction |
| `*` | `Mul<Rhs>` | `mul(self, rhs: Rhs): Output` | Multiplication |
| `/` | `Div<Rhs>` | `div(self, rhs: Rhs): Output` | Division |
| `%` | `Rem<Rhs>` | `rem(self, rhs: Rhs): Output` | Remainder |
| `&` | `BitAnd<Rhs>` | `bitand(self, rhs: Rhs): Output` | Bitwise AND |
| `\|` | `BitOr<Rhs>` | `bitor(self, rhs: Rhs): Output` | Bitwise OR |
| `^` | `BitXor<Rhs>` | `bitxor(self, rhs: Rhs): Output` | Bitwise XOR |
| `<<` | `Shl<Rhs>` | `shl(self, rhs: Rhs): Output` | Left shift |
| `>>` | `Shr<Rhs>` | `shr(self, rhs: Rhs): Output` | Right shift |

### Unary Operators

| Operator | Trait | Method | Description |
|----------|-------|--------|-------------|
| `-` | `Neg` | `neg(self): Output` | Negation |
| `!` | `Not` | `not(self): Output` | Logical NOT |
| `*` | `Deref` | `deref(&self): &Target` | Dereference |

### Compound Assignment

| Operator | Trait | Method | Description |
|----------|-------|--------|-------------|
| `+=` | `AddAssign<Rhs>` | `add_assign(&mut self, rhs: Rhs)` | Add and assign |
| `-=` | `SubAssign<Rhs>` | `sub_assign(&mut self, rhs: Rhs)` | Subtract and assign |
| `*=` | `MulAssign<Rhs>` | `mul_assign(&mut self, rhs: Rhs)` | Multiply and assign |
| `/=` | `DivAssign<Rhs>` | `div_assign(&mut self, rhs: Rhs)` | Divide and assign |
| `%=` | `RemAssign<Rhs>` | `rem_assign(&mut self, rhs: Rhs)` | Remainder and assign |

### Indexing

| Operator | Trait | Method | Description |
|----------|-------|--------|-------------|
| `[]` | `Index<Idx>` | `index(&self, index: Idx): &Output` | Immutable indexing |
| `[]` | `IndexMut<Idx>` | `index_mut(&mut self, index: Idx): &mut Output` | Mutable indexing |

## Best Practices

1. **Implement related traits together**: If you implement `Add`, consider implementing `AddAssign` as well.

2. **Use sensible Output types**: The `Output` associated type should make semantic sense for the operation.

3. **Follow mathematical properties**: If possible, make your operators follow expected properties (commutativity, associativity, etc.).

4. **Don't surprise users**: Operators should do what users expect. Don't make `+` do something completely unrelated to addition.

5. **Consider generic implementations**: Use generic parameters to support operations with different types.

## Compiler Desugaring

The Home compiler automatically desugars operator expressions:

```home
// Source code
let result = a + b * c

// After desugaring
let temp = b.mul(c)
let result = a.add(temp)
```

This happens during type checking, allowing the compiler to:
- Verify trait implementations exist
- Resolve the correct method to call
- Determine the result type
- Generate efficient code

## Integration with Type System

Operator overloading is fully integrated with Home's type system:

```home
fn add_vectors<T>(a: T, b: T): T::Output 
where 
    T: Add<T>
{
    a + b  // Compiler knows T implements Add
}
```

The type checker verifies that all operator trait bounds are satisfied at compile time, ensuring type safety.
