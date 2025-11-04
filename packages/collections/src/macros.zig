// Collection Macros System - Simplified
// Allows users to apply custom transformations to collections
//
// Usage:
//   _ = collection.macro(doubleFn);
//   _ = collection.macroChain(&[_]TransformFn{doubleFn, addOneFn});

const std = @import("std");

/// Built-in macro: Double all values (for numeric types)
pub fn doubleMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* * 2;
        }
    }.call;
}

/// Built-in macro: Increment all values by 1 (for numeric types)
pub fn incrementMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* + 1;
        }
    }.call;
}

/// Built-in macro: Reset all values to zero (for numeric types)
pub fn zeroMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = 0;
        }
    }.call;
}

/// Built-in macro: Negate all values (for numeric types)
pub fn negateMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = -item.*;
        }
    }.call;
}

/// Built-in macro: Square all values (for numeric types)
pub fn squareMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* * item.*;
        }
    }.call;
}

/// Helper to create a custom transform macro
pub fn transformMacro(comptime T: type, comptime transform_fn: fn (T) T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = transform_fn(item.*);
        }
    }.call;
}

// ==================== Additional Numeric Macros ====================

/// Built-in macro: Decrement all values by 1 (for numeric types)
pub fn decrementMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* - 1;
        }
    }.call;
}

/// Built-in macro: Halve all values (for numeric types)
pub fn halveMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            const info = @typeInfo(T);
            if (info == .int) {
                item.* = @divTrunc(item.*, 2);
            } else {
                item.* = item.* / 2;
            }
        }
    }.call;
}

/// Built-in macro: Triple all values (for numeric types)
pub fn tripleMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* * 3;
        }
    }.call;
}

/// Built-in macro: Absolute value (for signed numeric types)
pub fn absMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            if (item.* < 0) {
                item.* = -item.*;
            }
        }
    }.call;
}

/// Built-in macro: Cube all values (for numeric types)
pub fn cubeMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* * item.* * item.*;
        }
    }.call;
}

/// Built-in macro: Multiply by scalar
pub fn multiplyByMacro(comptime T: type, comptime scalar: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* * scalar;
        }
    }.call;
}

/// Built-in macro: Add scalar
pub fn addMacro(comptime T: type, comptime scalar: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* + scalar;
        }
    }.call;
}

/// Built-in macro: Subtract scalar
pub fn subtractMacro(comptime T: type, comptime scalar: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = item.* - scalar;
        }
    }.call;
}

/// Built-in macro: Divide by scalar
pub fn divideByMacro(comptime T: type, comptime scalar: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            const info = @typeInfo(T);
            if (info == .int) {
                item.* = @divTrunc(item.*, scalar);
            } else {
                item.* = item.* / scalar;
            }
        }
    }.call;
}

/// Built-in macro: Modulo scalar
pub fn moduloMacro(comptime T: type, comptime scalar: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @mod(item.*, scalar);
        }
    }.call;
}

// ==================== Clamping & Range Macros ====================

/// Built-in macro: Clamp to maximum value
pub fn clampMaxMacro(comptime T: type, comptime max_val: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            if (item.* > max_val) {
                item.* = max_val;
            }
        }
    }.call;
}

/// Built-in macro: Clamp to minimum value
pub fn clampMinMacro(comptime T: type, comptime min_val: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            if (item.* < min_val) {
                item.* = min_val;
            }
        }
    }.call;
}

/// Built-in macro: Clamp to range [min, max]
pub fn clampRangeMacro(comptime T: type, comptime min_val: T, comptime max_val: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            if (item.* < min_val) {
                item.* = min_val;
            } else if (item.* > max_val) {
                item.* = max_val;
            }
        }
    }.call;
}

// ==================== Rounding Macros (for floats) ====================

/// Built-in macro: Round to nearest integer
pub fn roundMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @round(item.*);
        }
    }.call;
}

/// Built-in macro: Floor (round down)
pub fn floorMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @floor(item.*);
        }
    }.call;
}

/// Built-in macro: Ceiling (round up)
pub fn ceilMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @ceil(item.*);
        }
    }.call;
}

/// Built-in macro: Truncate (remove decimal part)
pub fn truncMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @trunc(item.*);
        }
    }.call;
}

// ==================== Boolean Macros ====================

/// Built-in macro: Negate boolean values
pub fn notMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = !item.*;
        }
    }.call;
}

// ==================== Power & Root Macros ====================

/// Built-in macro: Square root (for float types)
pub fn sqrtMacro(comptime T: type) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = @sqrt(item.*);
        }
    }.call;
}

/// Built-in macro: Power of n
pub fn powMacro(comptime T: type, comptime n: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            item.* = std.math.pow(T, item.*, n);
        }
    }.call;
}

// ==================== Normalization Macros ====================

/// Built-in macro: Normalize to 0-1 range (requires min and max)
pub fn normalizeMacro(comptime T: type, comptime min_val: T, comptime max_val: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            const range = max_val - min_val;
            if (range != 0) {
                const info = @typeInfo(T);
                if (info == .float) {
                    item.* = (item.* - min_val) / range;
                } else {
                    // For integers, scale to preserve precision
                    item.* = @divTrunc((item.* - min_val) * 100, range);
                }
            }
        }
    }.call;
}

/// Built-in macro: Denormalize from 0-1 range to original range
pub fn denormalizeMacro(comptime T: type, comptime min_val: T, comptime max_val: T) fn (item: *T) void {
    return struct {
        fn call(item: *T) void {
            const range = max_val - min_val;
            const info = @typeInfo(T);
            if (info == .float) {
                item.* = item.* * range + min_val;
            } else {
                item.* = @divTrunc(item.* * range, 100) + min_val;
            }
        }
    }.call;
}
