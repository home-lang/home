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
