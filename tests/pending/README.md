# Pending Tests - Features to Implement

This directory contains test files for features that are defined in the AST but not yet implemented in the interpreter. These tests serve as specifications for the expected behavior.

## Unimplemented Features

### 1. Elvis Operator (`?:`)
**File:** `elvis-operator.test.home`
**AST Node:** `ElvisExpr`
**Description:** Returns left operand if truthy, otherwise returns right operand.
```home
let result = x ?: default_value;
```

### 2. Character Literals
**File:** `char-literals.test.home`
**AST Node:** `CharLiteral`
**Description:** Single character values with escape sequences.
```home
let c = 'a';
let newline = '\n';
```

### 3. Type Casting (`as`)
**File:** `type-casting.test.home`
**AST Node:** `TypeCastExpr`
**Description:** Explicit type conversion between compatible types.
```home
let x: i32 = 42;
let y = x as i64;
```

### 4. Named Arguments
**File:** `named-arguments.test.home`
**Description:** Passing arguments by name in function calls.
```home
fn greet(name: string, greeting: string) { ... }
greet(greeting: "Hello", name: "World");
```

### 5. String Interpolation
**File:** `string-interpolation.test.home`
**Description:** Embedding expressions in strings with `${}`.
```home
let name = "World";
let msg = "Hello, ${name}!";
```

### 6. Array Repeat Syntax
**File:** `array-repeat.test.home`
**AST Node:** `ArrayRepeat`
**Description:** Creating arrays with repeated values.
```home
let arr = [0; 5];  // [0, 0, 0, 0, 0]
```

### 7. Defer Statements
**File:** `defer.test.home`
**AST Node:** `DeferStmt`
**Description:** Execute code at end of scope for cleanup.
```home
{
    defer { cleanup(); }
    // ... work ...
}  // cleanup() called here
```

### 8. Labeled Loops
**File:** `labeled-loops.test.home`
**Description:** Breaking/continuing outer loops with labels.
```home
'outer: while (true) {
    while (true) {
        break 'outer;
    }
}
```

### 9. Try Expressions (`?`)
**File:** `try-expressions.test.home`
**AST Node:** `TryExpr`
**Description:** Error propagation operator and try-else.
```home
let value = fallible_fn()?;
let safe = fallible_fn() else default;
```

### 10. Is Expressions
**File:** `is-expressions.test.home`
**AST Node:** `IsExpr`
**Description:** Type checking and pattern matching.
```home
if (x is Some(value)) { ... }
if (obj is MyType) { ... }
```

### 11. Checked/Saturating Arithmetic
**File:** `checked-arithmetic.test.home`
**Description:** Overflow-safe arithmetic operators.
```home
let checked = a +? b;    // Returns Option<T>
let saturated = a +| b;  // Clamps at bounds
```

### 12. Map/Dictionary
**File:** `map-dictionary.test.home`
**Description:** Key-value data structure.
```home
let map = { "key": "value" };
let val = map["key"];
```

## Partially Implemented Features

### Safe Index Access (`?[`)
**AST Node:** `SafeIndexExpr`
**Status:** Field access (`?.`) works, index access (`?[`) does not.
```home
let arr = [1, 2, 3];
let val = arr?[10];  // Should return null for out of bounds
```

### String Slicing
**Status:** Array slicing works, string slicing does not.
```home
let s = "Hello";
let slice = s[0..3];  // Should return "Hel"
```

## How to Run Pending Tests

To test individual files manually:
```bash
./zig-out/bin/home run tests/pending/<file>.test.home
```

When a feature is implemented, move its test file to `tests/feature/` and run the full test suite to verify.
