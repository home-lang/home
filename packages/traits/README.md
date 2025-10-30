# Home Trait System

## Overview

Complete trait system implementation for the Home programming language, providing Rust-like traits with TypeScript-like interfaces.

## Features

- ✅ **Trait Definitions** - Define interfaces with methods and associated types
- ✅ **Trait Implementations** - Implement traits for types
- ✅ **Trait Inheritance** - Super traits and trait composition
- ✅ **Generic Traits** - Traits with type parameters
- ✅ **Associated Types** - Type members in traits
- ✅ **Default Implementations** - Default method implementations
- ✅ **Trait Bounds** - Constrain generic types
- ✅ **Where Clauses** - Complex trait bounds
- ✅ **Trait Objects** - Dynamic dispatch via `dyn Trait`
- ✅ **VTables** - Efficient virtual method dispatch
- ✅ **Operator Overloading** - 21 operator traits (Add, Sub, Mul, etc.)
- ✅ **Built-in Traits** - Clone, Copy, Debug, Display, Iterator, etc.

## Structure

```
packages/traits/
├── src/
│   ├── traits.zig              # Core trait system
│   ├── operator_traits.zig     # Operator overloading traits
│   └── trait_system.zig        # Trait system implementation
├── tests/
│   └── trait_system_test.zig   # Comprehensive tests
├── README.md
└── INTEGRATION_PLAN.md         # Integration status
```

## Usage

### Defining a Trait

```zig
const trait_system = TraitSystem.init(allocator);

const methods = [_]TraitSystem.TraitDef.MethodSignature{
    .{
        .name = "draw",
        .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
            .{ .name = "self", .type_name = "&Self" },
        },
        .return_type = "void",
        .is_async = false,
        .is_required = true,
    },
};

try trait_system.defineTrait(
    "Drawable",
    &methods,
    &[_]TraitSystem.TraitDef.AssociatedType{},
    &[_][]const u8{},  // super_traits
    &[_][]const u8{},  // generic_params
);
```

### Implementing a Trait

```zig
try trait_system.implementTrait(
    "Drawable",
    "Circle",
    &impl_methods,
);

// Check implementation
const implements = trait_system.implementsTrait("Circle", "Drawable");
```

### Checking Trait Bounds

```zig
const bounds = [_][]const u8{ "Clone", "Debug" };
const satisfies = trait_system.checkBounds("MyType", &bounds);
```

## Home Language Syntax

### Basic Trait

```home
trait Drawable {
    fn draw(&self) -> void
    fn bounds(&self) -> Rect
}
```

### Trait Implementation

```home
impl Drawable for Circle {
    fn draw(&self) -> void {
        println("Drawing circle")
    }
    
    fn bounds(&self) -> Rect {
        Rect { x: self.x, y: self.y, w: self.radius * 2, h: self.radius * 2 }
    }
}
```

### Generic Trait

```home
trait Add<Rhs = Self> {
    type Output
    fn add(self, rhs: Rhs) -> Self::Output
}
```

### Trait with Super Traits

```home
trait ColoredShape: Shape + Colored {
    fn describe(&self) -> string
}
```

### Trait Objects

```home
fn render(shapes: &[dyn Drawable]) -> void {
    for shape in shapes {
        shape.draw()
    }
}
```

## Built-in Traits

### Core Traits
- `Clone` - Duplicate values
- `Copy` - Bitwise copy (marker trait)
- `Debug` - Debug formatting
- `Display` - User-facing formatting
- `Default` - Default values

### Comparison Traits
- `PartialEq` - Equality comparison
- `Eq` - Full equality
- `PartialOrd` - Partial ordering
- `Ord` - Total ordering

### Conversion Traits
- `From<T>` - Value conversion
- `Into<T>` - Consuming conversion

### Iterator Trait
- `Iterator` - Iteration protocol

### Operator Traits (21 total)

**Arithmetic:**
- `Add`, `Sub`, `Mul`, `Div`, `Rem`
- `Neg` (unary -)

**Bitwise:**
- `BitAnd`, `BitOr`, `BitXor`
- `Shl`, `Shr`
- `Not` (unary !)

**Compound Assignment:**
- `AddAssign`, `SubAssign`, `MulAssign`, `DivAssign`, `RemAssign`

**Indexing:**
- `Index`, `IndexMut`

**Dereferencing:**
- `Deref`, `DerefMut`

## Type Checking Integration

The trait system integrates with the type checker via `TraitChecker`:

```zig
const trait_checker = TraitChecker.init(allocator, &trait_system);

// Check trait declaration
try trait_checker.checkTraitDecl(trait_decl);

// Check impl declaration
try trait_checker.checkImplDecl(impl_decl);

// Get errors
if (trait_checker.hasErrors()) {
    for (trait_checker.getErrors()) |err| {
        // Handle error
    }
}
```

## Operator Resolution

Operators are automatically resolved to trait methods:

```zig
const resolver = OperatorResolver.init(allocator, &trait_system);

// Resolve a + b
const resolution = try resolver.resolveBinaryOp(.Add, "Vector", "Vector");

// Desugar to method call
const desugarer = OperatorDesugarer.init(allocator, &resolver);
const call_expr = try desugarer.desugarBinaryExpr(binary_expr, "Vector", "Vector");
```

## Testing

Run tests:

```bash
zig build test
```

## Examples

See comprehensive examples in:
- `/examples/traits.home` - Basic trait usage
- `/examples/operator_overloading.home` - Operator traits
- `/docs/TRAITS.md` - Full documentation
- `/docs/OPERATOR_OVERLOADING.md` - Operator overloading guide

## Integration Status

✅ **Phase 1: Core Integration (Complete)**
- Lexer keywords (trait, impl, where, dyn, Self, self)
- AST nodes (TraitDecl, ImplDecl, WhereClause, etc.)
- Parser implementation
- Build system integration

✅ **Phase 2: Type Checking (Complete)**
- TraitChecker implementation
- Trait bounds verification
- Associated types resolution
- Super trait checking

✅ **Phase 3: Operator Overloading (Complete)**
- 21 operator traits defined
- Operator resolution
- Expression desugaring
- Full integration

🔄 **Phase 4: Runtime (In Progress)**
- VTable generation ✅
- Dynamic dispatch ✅
- Trait method calls (needs codegen)

## Performance

- **Static Dispatch**: Zero-cost abstraction, inlined at compile time
- **Dynamic Dispatch**: Single vtable lookup, minimal overhead
- **Monomorphization**: Generic traits specialized per type
- **VTable Caching**: Vtables generated once and reused

## See Also

- [Traits Documentation](/docs/TRAITS.md)
- [Operator Overloading](/docs/OPERATOR_OVERLOADING.md)
- [Integration Plan](INTEGRATION_PLAN.md)
