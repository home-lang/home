# Type Inference in Home

This document describes the comprehensive type inference system implemented for the Home programming language.

## Overview

Home uses a **Hindley-Milner style type inference** system with the following features:

- **Automatic type inference**: Types are inferred without explicit annotations in most cases
- **Let-polymorphism**: Polymorphic functions can be used at multiple types
- **Constraint-based**: Types are inferred by collecting and solving constraints
- **Bidirectional**: Information flows both up and down the AST
- **Sound**: The type system prevents type errors at runtime

## Architecture

The type inference system is implemented in `packages/types/src/type_inference.zig` and consists of three main phases:

### 1. Constraint Generation

During this phase, the type inferencer walks the AST and generates type constraints. Each expression is assigned a type (either concrete or a type variable), and constraints are collected that must be satisfied.

```zig
var inferencer = TypeInferencer.init(allocator);
const inferred_type = try inferencer.inferExpression(expr, &env);
```

### 2. Constraint Solving

Constraints are solved using **unification**, which finds a most general substitution that satisfies all constraints. The unification algorithm includes:

- **Occurs check**: Prevents infinite types (e.g., `T = [T]`)
- **Structural matching**: Recursively unifies composite types
- **Type variable binding**: Records substitutions for type variables

```zig
try inferencer.solve();
```

### 3. Type Substitution

After solving, the substitution is applied to get the final concrete types:

```zig
const final_type = try inferencer.applySubstitution(inferred_type);
```

## Key Components

### Type Variables

Type variables represent unknown types during inference. They are later unified with concrete types:

```zig
pub const TypeVar = struct {
    id: usize,              // Unique identifier
    name: ?[]const u8,      // Optional name for debugging
};
```

Example: When inferring `let x = []`, the element type is a type variable `'a`, giving us `[' a]`.

### Type Schemes

Type schemes represent polymorphic types with quantified type variables (∀):

```zig
pub const TypeScheme = struct {
    forall: []const usize,  // Quantified variables
    ty: *Type,              // The type with free variables
};
```

Example: The identity function `fn id(x) = x` has type scheme `∀a. a: a`.

### Constraints

Constraints express relationships between types:

```zig
pub const Constraint = union(enum) {
    // Two types must be equal
    Equality: struct {
        lhs: *Type,
        rhs: *Type,
    },
    // Type must implement a trait
    TraitBound: struct {
        ty: *Type,
        trait_name: []const u8,
    },
};
```

### Substitution

A substitution maps type variables to types:

```zig
pub const Substitution = struct {
    bindings: std.AutoHashMap(usize, *Type),

    pub fn apply(self: *Substitution, ty: *Type, allocator: Allocator) !*Type;
    pub fn bind(self: *Substitution, var_id: usize, ty: *Type) !void;
};
```

## Supported Inferences

### Literals

```home
let x = 42          // inferred as Int
let y = 42i32       // inferred as I32
let z = 3.14        // inferred as Float
let s = "hello"     // inferred as String
let b = true        // inferred as Bool
```

### Binary Operations

```home
let sum = 1 + 2              // Int
let compare = x < y          // Bool
let logical = true && false  // Bool
let bitwise = 5 & 3          // Int
```

### Arrays

```home
let nums = [1, 2, 3]         // [Int]
let empty = []               // ['a] (polymorphic)
let mixed = [1, 2.5]         // Error: type mismatch
```

### Tuples

```home
let pair = (42, "hello")     // (Int, String)
let triple = (1, true, 3.14) // (Int, Bool, Float)
```

### Functions and Closures

```home
// Identity function: ∀a. a: a
fn id(x) = x

// Closure with inferred types
let add = |x, y| x + y       // fn(Int, Int): Int

// Polymorphic usage
let n = id(42)               // Int
let s = id("hello")          // String
```

### Function Calls

```home
fn double(x) = x * 2

let result = double(21)      // Infers: fn(Int): Int, result is Int
```

### Index Operations

```home
let arr = [1, 2, 3]
let elem = arr[0]            // Int (inferred from array element type)
```

### Ternary Expressions

```home
let max = if x > y then x else y  // Both branches must match
```

## Type Unification

The unification algorithm finds a substitution that makes two types equal:

```
unify(Int, Int) = ∅                      // Success: same type
unify('a, Int) = {'a → Int}              // Bind type variable
unify([Int], [Float]) = Error            // Mismatch
unify(fn(Int): Bool, fn(Int): Bool) = ∅  // Success
unify('a, ['a]) = Error                  // Occurs check failure
```

### Occurs Check

The occurs check prevents infinite types:

```home
// This would create T = [T] which is infinite
let impossible = [impossible]  // Error: infinite type
```

## Let-Polymorphism

Let-polymorphism allows polymorphic functions to be used at multiple types:

```home
fn identity(x) = x

// identity is generalized to: ∀a. a: a
let n: Int = identity(42)
let s: String = identity("hello")
let b: Bool = identity(true)
```

**Generalization**: When binding a variable, free type variables are quantified:
- Occurs during `let` bindings
- Creates type schemes (∀a. type)

**Instantiation**: When using a polymorphic value, fresh type variables are created:
- Each use gets fresh type variables
- Allows different types at different call sites

## Error Handling

The type inference system can produce the following errors:

- `error.UndefinedVariable`: Variable not in scope
- `error.TypeMismatch`: Types cannot be unified
- `error.InfiniteType`: Occurs check failed
- `error.InvalidOperation`: Operation not supported for type

## Integration with Type Checker

The type inference system integrates with the existing type checker:

1. **Type inference** runs first to infer types
2. **Type checking** validates the inferred types against annotations
3. **Trait checking** ensures trait bounds are satisfied

## Examples

### Example 1: Simple Inference

```home
let x = 42        // x: Int
let y = x + 10    // y: Int (from x: Int and 10: Int)
```

**Constraints generated**:
- `x = Int`
- `10 = Int`
- `y = Int` (result of `+`)

### Example 2: Array Inference

```home
let nums = [1, 2, 3]
let first = nums[0]
```

**Constraints generated**:
- `1 = Int`, `2 = Int`, `3 = Int`
- `nums = [Int]`
- `0 = Int` (index)
- `first = Int` (element type)

### Example 3: Function Inference

```home
fn apply(f, x) = f(x)
```

**Constraints generated**:
- `f = 'a: 'b` (function type)
- `x = 'a` (parameter type)
- `f(x) = 'b` (return type)
- Final type: `∀a b. (a: b, a): b`

### Example 4: Higher-Order Functions

```home
fn map(f, arr) = {
    let result = []
    for x in arr {
        result.push(f(x))
    }
    return result
}
```

**Inferred type**: `∀a b. (fn(a): b, [a]): [b]`

## Performance Considerations

- **Type variable generation**: O(1) with counter
- **Constraint collection**: O(n) where n is AST size
- **Unification**: O(n × α(n)) where α is inverse Ackermann (nearly O(n))
- **Substitution application**: O(n) per application

## Future Enhancements

Potential improvements to the type inference system:

1. **Rank-N types**: Higher-rank polymorphism
2. **Type classes**: Multi-parameter type classes
3. **GADTs**: Generalized algebraic data types
4. **Refinement types**: Types with predicates
5. **Effect inference**: Tracking side effects in types
6. **Incremental inference**: Reuse previous results
7. **Better error messages**: Show inference steps
8. **Implicit parameters**: Auto-resolution of constraints

## References

- [Hindley-Milner Type Inference](https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system)
- [Algorithm W](https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system#Algorithm_W)
- [Damas-Milner Type System](https://dl.acm.org/doi/10.1145/582153.582176)
- [Types and Programming Languages (Pierce)](https://www.cis.upenn.edu/~bcpierce/tapl/)

## Testing

The type inference system has comprehensive tests in `packages/types/tests/type_inference_test.zig`:

- Integer literal inference
- Binary expression inference
- Array literal inference (homogeneous and empty)
- Tuple inference (heterogeneous types)
- Type variable unification
- Occurs check
- Function type unification
- Let-polymorphism
- Substitution transitivity
- Comparison operators
- Type suffix handling

Run tests with: `zig build test`
