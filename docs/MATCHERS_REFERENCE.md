# Ion Testing Matchers Reference

Complete reference for all available matchers in Ion's modern testing framework.

## Table of Contents

1. [Equality Matchers](#equality-matchers)
2. [Truthiness Matchers](#truthiness-matchers)
3. [Numeric Comparison Matchers](#numeric-comparison-matchers)
4. [Numeric Property Matchers](#numeric-property-matchers)
5. [String Matchers](#string-matchers)
6. [Special Matchers](#special-matchers)
7. [Negation](#negation)

---

## Equality Matchers

### `toBe(expected)`

Strict equality check (reference equality for objects).

```zig
expect.* = test.expect(allocator, 42, failures);
try expect.toBe(42); // ✓ Pass

expect.* = test.expect(allocator, "hello", failures);
try expect.toBe("hello"); // ✓ Pass
```

**Use case:** Primitive values, exact matching

---

### `toEqual(expected)`

Deep equality check (compares values recursively).

```zig
expect.* = test.expect(allocator, 100, failures);
try expect.toEqual(100); // ✓ Pass
```

**Use case:** Objects, arrays, nested structures

---

## Truthiness Matchers

### `toBeTruthy()`

Checks if value is truthy (non-zero, non-empty, non-null).

```zig
expect.* = test.expect(allocator, true, failures);
try expect.toBeTruthy(); // ✓ Pass

expect.* = test.expect(allocator, 42, failures);
try expect.toBeTruthy(); // ✓ Pass

expect.* = test.expect(allocator, "text", failures);
try expect.toBeTruthy(); // ✓ Pass

expect.* = test.expect(allocator, false, failures);
try expect.toBeTruthy(); // ✗ Fail
```

**Truthy values:** `true`, non-zero numbers, non-empty strings

---

### `toBeFalsy()`

Checks if value is falsy (zero, empty, null, false).

```zig
expect.* = test.expect(allocator, false, failures);
try expect.toBeFalsy(); // ✓ Pass

expect.* = test.expect(allocator, 0, failures);
try expect.toBeFalsy(); // ✓ Pass

expect.* = test.expect(allocator, "", failures);
try expect.toBeFalsy(); // ✓ Pass
```

**Falsy values:** `false`, `0`, `""`, `null`

---

### `toBeNull()`

Checks if value is null.

```zig
expect.* = test.expect(allocator, null, failures);
try expect.toBeNull(); // ✓ Pass
```

---

### `toBeDefined()`

Checks if value is defined (not null/undefined).

```zig
expect.* = test.expect(allocator, 42, failures);
try expect.toBeDefined(); // ✓ Pass

expect.* = test.expect(allocator, null, failures);
try expect.toBeDefined(); // ✗ Fail
```

---

### `toBeUndefined()`

Checks if value is undefined/null.

```zig
expect.* = test.expect(allocator, null, failures);
try expect.toBeUndefined(); // ✓ Pass
```

---

## Numeric Comparison Matchers

### `toBeGreaterThan(threshold)`

Value must be strictly greater than threshold.

```zig
expect.* = test.expect(allocator, 10, failures);
try expect.toBeGreaterThan(5); // ✓ Pass (10 > 5)

expect.* = test.expect(allocator, 5, failures);
try expect.toBeGreaterThan(5); // ✗ Fail (5 is not > 5)
```

---

### `toBeLessThan(threshold)`

Value must be strictly less than threshold.

```zig
expect.* = test.expect(allocator, 3, failures);
try expect.toBeLessThan(10); // ✓ Pass (3 < 10)
```

---

### `toBeGreaterThanOrEqual(threshold)`

Value must be greater than or equal to threshold.

```zig
expect.* = test.expect(allocator, 10, failures);
try expect.toBeGreaterThanOrEqual(10); // ✓ Pass (10 >= 10)

expect.* = test.expect(allocator, 15, failures);
try expect.toBeGreaterThanOrEqual(10); // ✓ Pass (15 >= 10)
```

---

### `toBeLessThanOrEqual(threshold)`

Value must be less than or equal to threshold.

```zig
expect.* = test.expect(allocator, 10, failures);
try expect.toBeLessThanOrEqual(10); // ✓ Pass (10 <= 10)

expect.* = test.expect(allocator, 5, failures);
try expect.toBeLessThanOrEqual(10); // ✓ Pass (5 <= 10)
```

---

### `toBeCloseTo(expected, precision)`

Floating-point comparison with specified precision.

```zig
const pi: f64 = 3.14159;
expect.* = test.expect(allocator, pi, failures);
try expect.toBeCloseTo(3.14, 2); // ✓ Pass (matches to 2 decimals)

// Handles floating point precision issues
const value: f64 = 0.1 + 0.2; // = 0.30000000000000004
expect.* = test.expect(allocator, value, failures);
try expect.toBeCloseTo(0.3, 1); // ✓ Pass (matches to 1 decimal)
```

**Parameters:**
- `expected`: Expected floating-point value
- `precision`: Number of decimal places (default: 2)

---

### `toBeBetween(min, max)`

Value must be within range [min, max] (inclusive).

```zig
expect.* = test.expect(allocator, 5, failures);
try expect.toBeBetween(1, 10); // ✓ Pass (1 <= 5 <= 10)

expect.* = test.expect(allocator, 10, failures);
try expect.toBeBetween(10, 20); // ✓ Pass (inclusive bounds)

expect.* = test.expect(allocator, 0, failures);
try expect.toBeBetween(1, 10); // ✗ Fail (0 < 1)
```

---

## Numeric Property Matchers

### `toBePositive()`

Value must be greater than zero.

```zig
expect.* = test.expect(allocator, 42, failures);
try expect.toBePositive(); // ✓ Pass

expect.* = test.expect(allocator, -5, failures);
try expect.toBePositive(); // ✗ Fail
```

---

### `toBeNegative()`

Value must be less than zero.

```zig
expect.* = test.expect(allocator, -5, failures);
try expect.toBeNegative(); // ✓ Pass

expect.* = test.expect(allocator, 0, failures);
try expect.toBeNegative(); // ✗ Fail
```

---

### `toBeZero()`

Value must equal zero.

```zig
expect.* = test.expect(allocator, 0, failures);
try expect.toBeZero(); // ✓ Pass

expect.* = test.expect(allocator, 0.0, failures);
try expect.toBeZero(); // ✓ Pass
```

---

### `toBeEven()`

Integer value must be even.

```zig
expect.* = test.expect(allocator, 4, failures);
try expect.toBeEven(); // ✓ Pass

expect.* = test.expect(allocator, 100, failures);
try expect.toBeEven(); // ✓ Pass

expect.* = test.expect(allocator, 3, failures);
try expect.toBeEven(); // ✗ Fail
```

**Note:** Only works with integer types

---

### `toBeOdd()`

Integer value must be odd.

```zig
expect.* = test.expect(allocator, 3, failures);
try expect.toBeOdd(); // ✓ Pass

expect.* = test.expect(allocator, 99, failures);
try expect.toBeOdd(); // ✓ Pass

expect.* = test.expect(allocator, 4, failures);
try expect.toBeOdd(); // ✗ Fail
```

---

### `toBeNaN()`

Value must be NaN (Not a Number).

```zig
const nan_value = std.math.nan(f64);
expect.* = test.expect(allocator, nan_value, failures);
try expect.toBeNaN(); // ✓ Pass

expect.* = test.expect(allocator, 42.0, failures);
try expect.toBeNaN(); // ✗ Fail
```

**Use case:** Testing invalid mathematical operations

---

### `toBeInfinite()`

Value must be positive or negative infinity.

```zig
const inf_value = std.math.inf(f64);
expect.* = test.expect(allocator, inf_value, failures);
try expect.toBeInfinite(); // ✓ Pass

const neg_inf = -std.math.inf(f64);
expect.* = test.expect(allocator, neg_inf, failures);
try expect.toBeInfinite(); // ✓ Pass
```

---

## String Matchers

### `toContain(substring)`

String must contain the given substring.

```zig
expect.* = test.expect(allocator, "hello world", failures);
try expect.toContain("world"); // ✓ Pass

expect.* = test.expect(allocator, "The quick brown fox", failures);
try expect.toContain("quick"); // ✓ Pass

expect.* = test.expect(allocator, "hello", failures);
try expect.toContain("xyz"); // ✗ Fail
```

---

### `toStartWith(prefix)`

String must start with the given prefix.

```zig
expect.* = test.expect(allocator, "hello world", failures);
try expect.toStartWith("hello"); // ✓ Pass

expect.* = test.expect(allocator, "hello world", failures);
try expect.toStartWith("world"); // ✗ Fail
```

---

### `toEndWith(suffix)`

String must end with the given suffix.

```zig
expect.* = test.expect(allocator, "hello world", failures);
try expect.toEndWith("world"); // ✓ Pass

expect.* = test.expect(allocator, "test.txt", failures);
try expect.toEndWith(".txt"); // ✓ Pass
```

---

### `toHaveLength(length)`

String/array must have the specified length.

```zig
expect.* = test.expect(allocator, "hello", failures);
try expect.toHaveLength(5); // ✓ Pass

expect.* = test.expect(allocator, "", failures);
try expect.toHaveLength(0); // ✓ Pass
```

---

### `toBeEmpty()`

String/array must be empty.

```zig
expect.* = test.expect(allocator, "", failures);
try expect.toBeEmpty(); // ✓ Pass

expect.* = test.expect(allocator, "text", failures);
try expect.toBeEmpty(); // ✗ Fail
```

---

### `toMatch(pattern)`

String must match glob pattern (`*` for wildcards).

```zig
expect.* = test.expect(allocator, "hello world", failures);
try expect.toMatch("hello*"); // ✓ Pass

expect.* = test.expect(allocator, "test123", failures);
try expect.toMatch("test*"); // ✓ Pass

expect.* = test.expect(allocator, "file.txt", failures);
try expect.toMatch("*.txt"); // ✓ Pass
```

**Pattern syntax:**
- `*` matches any sequence of characters
- Literal characters must match exactly

---

## Special Matchers

### `toMatchSnapshot(name, snapshots)`

Compare value against saved snapshot.

```zig
expect.* = test.expect(allocator, output, failures);
try expect.toMatchSnapshot("component_render", &framework.snapshots);
```

**First run:** Creates snapshot
**Subsequent runs:** Compares against saved snapshot

---

### `toHaveBeenCalled()` (Mock)

Mock/spy must have been called at least once.

```zig
var mock = testing.ModernTest.Mock.init(allocator);
defer mock.deinit();

// ... call mock ...

if (mock.toHaveBeenCalled()) {
    // Mock was called
}
```

---

### `toHaveBeenCalledTimes(count)` (Mock)

Mock/spy must have been called exactly N times.

```zig
if (mock.toHaveBeenCalledTimes(3)) {
    // Mock was called exactly 3 times
}
```

---

### `toHaveBeenCalledWith(args)` (Mock)

Mock/spy must have been called with specific arguments.

```zig
if (mock.toHaveBeenCalledWith(&.{arg1, arg2})) {
    // Mock was called with these arguments
}
```

---

## Negation

All matchers support negation via the `.not` modifier.

### Basic Negation

```zig
expect.* = test.expect(allocator, 42, failures);
expect.not = true;
try expect.toBe(99); // ✓ Pass (42 != 99)
```

### Negation Examples

**Not equal:**
```zig
expect.not = true;
try expect.toBe(value); // Fails if equal
```

**Not contain:**
```zig
expect.* = test.expect(allocator, "hello world", failures);
expect.not = true;
try expect.toContain("xyz"); // ✓ Pass (doesn't contain "xyz")
```

**Not positive:**
```zig
expect.* = test.expect(allocator, -5, failures);
expect.not = true;
try expect.toBePositive(); // ✓ Pass (-5 is not positive)
```

**Not in range:**
```zig
expect.* = test.expect(allocator, 50, failures);
expect.not = true;
try expect.toBeBetween(1, 10); // ✓ Pass (50 not in [1,10])
```

### Pattern: Reset Negation

Always reset `.not` after use if reusing expect:

```zig
expect.not = true;
try expect.toBe(99);
expect.not = false; // Reset for next assertion
```

---

## Matcher Categories Summary

| Category | Count | Examples |
|----------|-------|----------|
| **Equality** | 2 | `toBe`, `toEqual` |
| **Truthiness** | 5 | `toBeTruthy`, `toBeFalsy`, `toBeNull`, `toBeDefined`, `toBeUndefined` |
| **Numeric Comparison** | 6 | `toBeGreaterThan`, `toBeLessThan`, `toBeCloseTo`, `toBeBetween` |
| **Numeric Properties** | 7 | `toBePositive`, `toBeNegative`, `toBeZero`, `toBeEven`, `toBeOdd`, `toBeNaN`, `toBeInfinite` |
| **String** | 6 | `toContain`, `toStartWith`, `toEndWith`, `toHaveLength`, `toBeEmpty`, `toMatch` |
| **Special** | 4 | `toMatchSnapshot`, `toHaveBeenCalled`, `toHaveBeenCalledTimes`, `toHaveBeenCalledWith` |

**Total: 30+ matchers**

---

## Quick Reference Chart

### When to Use Which Matcher

| Scenario | Matcher | Example |
|----------|---------|---------|
| Exact equality | `toBe` | `try expect.toBe(42)` |
| Deep equality | `toEqual` | `try expect.toEqual(obj)` |
| Check if true/non-zero | `toBeTruthy` | `try expect.toBeTruthy()` |
| Check if false/zero | `toBeFalsy` | `try expect.toBeFalsy()` |
| Check null | `toBeNull` | `try expect.toBeNull()` |
| Number > threshold | `toBeGreaterThan` | `try expect.toBeGreaterThan(10)` |
| Number < threshold | `toBeLessThan` | `try expect.toBeLessThan(100)` |
| Float comparison | `toBeCloseTo` | `try expect.toBeCloseTo(3.14, 2)` |
| Range check | `toBeBetween` | `try expect.toBeBetween(1, 10)` |
| Positive number | `toBePositive` | `try expect.toBePositive()` |
| Negative number | `toBeNegative` | `try expect.toBeNegative()` |
| Even number | `toBeEven` | `try expect.toBeEven()` |
| Odd number | `toBeOdd` | `try expect.toBeOdd()` |
| Contains substring | `toContain` | `try expect.toContain("hello")` |
| Starts with prefix | `toStartWith` | `try expect.toStartWith("Mr.")` |
| Ends with suffix | `toEndWith` | `try expect.toEndWith(".txt")` |
| String length | `toHaveLength` | `try expect.toHaveLength(5)` |
| Empty string/array | `toBeEmpty` | `try expect.toBeEmpty()` |
| Pattern match | `toMatch` | `try expect.toMatch("*.json")` |

---

## Best Practices

### 1. Choose the Right Matcher

✅ **Good:**
```zig
expect.toBePositive(); // Clear intent
```

❌ **Bad:**
```zig
expect.toBeGreaterThan(0); // Less clear
```

### 2. Use Specific Matchers

✅ **Good:**
```zig
expect.toStartWith("Error:");
```

❌ **Bad:**
```zig
expect.toMatch("Error:*"); // More complex
```

### 3. Handle Floating Point Correctly

✅ **Good:**
```zig
expect.toBeCloseTo(0.3, 1); // Handles 0.1 + 0.2
```

❌ **Bad:**
```zig
expect.toBe(0.3); // May fail due to precision
```

### 4. Use Negation Sparingly

✅ **Good:**
```zig
expect.not = true;
try expect.toContain("error");
```

✅ **Also Good (when available):**
```zig
// Use opposite matcher if available
try expect.toBePositive(); // Instead of not.toBeNegative()
```

---

## Error Messages

All matchers provide clear error messages:

```
✗ validates email format
  Expected value to contain substring
  Expected: "@example.com"
  Actual:   "invalidemail"
```

```
✗ checks range
  Expected value to be between range
  Expected: { 1, 10 }
  Actual:   15
```

---

## See Also

- [Quick Start Guide](TESTING_QUICK_START.md)
- [Complete Testing Guide](MODERN_TESTING_GUIDE.md)
- [Examples](../packages/testing/examples/)
