// Collection Traits System
// Provides compile-time type constraints for collection operations
//
// Traits:
// - Collectible: Types that can be stored in collections
// - Comparable: Types that can be compared and sorted
// - Aggregatable: Numeric types that support mathematical operations

const std = @import("std");

/// Checks if a type can be stored in a collection
/// All types are collectible, but some may have special requirements
pub fn Collectible(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type needs deinit
        pub const needs_deinit = switch (@typeInfo(T)) {
            .pointer => true,
            .@"struct" => @hasDecl(T, "deinit"),
            .@"union" => @hasDecl(T, "deinit"),
            else => false,
        };

        /// Check if type is copyable
        pub const is_copyable = switch (@typeInfo(T)) {
            .pointer => false,
            .@"struct" => !@hasDecl(T, "deinit"),
            .@"union" => !@hasDecl(T, "deinit"),
            else => true,
        };

        /// Verify type can be collected
        pub fn verify() void {
            // Compile-time verification
            _ = @sizeOf(T); // Ensure size is known
        }
    };
}

/// Checks if a type can be compared for ordering
/// Required for: sort, sortBy, min, max, median
pub fn Comparable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type has natural ordering
        pub const has_natural_order = switch (@typeInfo(T)) {
            .int, .float => true,
            .bool => true,
            .@"enum" => true,
            else => false,
        };

        /// Check if type has custom compare method
        pub const has_compare = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "compare"),
            else => false,
        };

        /// Check if type has order method
        pub const has_order = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "order"),
            else => false,
        };

        /// Verify type is comparable
        pub fn verify() void {
            if (!has_natural_order and !has_compare and !has_order) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not comparable. " ++
                    "Add a 'compare(self: " ++ @typeName(T) ++ ", other: " ++ @typeName(T) ++ ") std.math.Order' method.");
            }
        }

        /// Compare two values
        pub fn compare(a: T, b: T) std.math.Order {
            if (has_compare) {
                return T.compare(a, b);
            } else if (has_order) {
                return T.order(a, b);
            } else if (has_natural_order) {
                return std.math.order(a, b);
            } else {
                @compileError("Type is not comparable");
            }
        }

        /// Check if a < b
        pub fn lessThan(a: T, b: T) bool {
            return compare(a, b) == .lt;
        }

        /// Check if a > b
        pub fn greaterThan(a: T, b: T) bool {
            return compare(a, b) == .gt;
        }

        /// Check if a == b
        pub fn equal(a: T, b: T) bool {
            return compare(a, b) == .eq;
        }
    };
}

/// Checks if a type supports mathematical aggregation
/// Required for: sum, avg, median, min, max
pub fn Aggregatable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type is numeric
        pub const is_numeric = switch (@typeInfo(T)) {
            .int, .float, .comptime_int, .comptime_float => true,
            else => false,
        };

        /// Check if type has add method
        pub const has_add = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "add"),
            else => false,
        };

        /// Check if type has sub method
        pub const has_sub = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "sub"),
            else => false,
        };

        /// Check if type has mul method
        pub const has_mul = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "mul"),
            else => false,
        };

        /// Check if type has div method
        pub const has_div = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "div"),
            else => false,
        };

        /// Verify type is aggregatable
        pub fn verify() void {
            if (!is_numeric and !has_add) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not aggregatable. " ++
                    "It must be a numeric type or implement add/sub/mul/div methods.");
            }
        }

        /// Add two values
        pub fn add(a: T, b: T) T {
            if (has_add) {
                return T.add(a, b);
            } else if (is_numeric) {
                return a + b;
            } else {
                @compileError("Type does not support addition");
            }
        }

        /// Subtract two values
        pub fn sub(a: T, b: T) T {
            if (has_sub) {
                return T.sub(a, b);
            } else if (is_numeric) {
                return a - b;
            } else {
                @compileError("Type does not support subtraction");
            }
        }

        /// Multiply two values
        pub fn mul(a: T, b: T) T {
            if (has_mul) {
                return T.mul(a, b);
            } else if (is_numeric) {
                return a * b;
            } else {
                @compileError("Type does not support multiplication");
            }
        }

        /// Divide two values
        pub fn div(a: T, b: T) T {
            if (has_div) {
                return T.div(a, b);
            } else if (is_numeric) {
                return switch (@typeInfo(T)) {
                    .int => @divTrunc(a, b),
                    .float => a / b,
                    else => @compileError("Cannot divide this type"),
                };
            } else {
                @compileError("Type does not support division");
            }
        }

        /// Get zero value
        pub fn zero() T {
            const has_zero = switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "zero"),
                else => false,
            };
            if (has_zero) {
                return T.zero();
            } else if (is_numeric) {
                return 0;
            } else {
                @compileError("Type does not have a zero value");
            }
        }

        /// Convert to f64 for averaging
        pub fn toFloat(val: T) f64 {
            const has_toFloat = switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "toFloat"),
                else => false,
            };
            if (has_toFloat) {
                return T.toFloat(val);
            } else if (is_numeric) {
                return switch (@typeInfo(T)) {
                    .int => @floatFromInt(val),
                    .float => @floatCast(val),
                    .comptime_int => @as(f64, @floatFromInt(val)),
                    .comptime_float => @as(f64, @floatCast(val)),
                    else => @compileError("Cannot convert to float"),
                };
            } else {
                @compileError("Type cannot be converted to float");
            }
        }

        /// Convert from f64
        pub fn fromFloat(val: f64) T {
            const has_fromFloat = switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "fromFloat"),
                else => false,
            };
            if (has_fromFloat) {
                return T.fromFloat(val);
            } else if (is_numeric) {
                return switch (@typeInfo(T)) {
                    .int => @intFromFloat(val),
                    .float => @floatCast(val),
                    else => @compileError("Cannot convert from float"),
                };
            } else {
                @compileError("Type cannot be created from float");
            }
        }
    };
}

/// Helper to verify a type satisfies Collectible trait
pub fn verifyCollectible(comptime T: type) void {
    Collectible(T).verify();
}

/// Helper to verify a type satisfies Comparable trait
pub fn verifyComparable(comptime T: type) void {
    Comparable(T).verify();
}

/// Helper to verify a type satisfies Aggregatable trait
pub fn verifyAggregatable(comptime T: type) void {
    Aggregatable(T).verify();
}

/// Check if type is collectible (always true, but may have requirements)
pub fn isCollectible(comptime T: type) bool {
    _ = T;
    return true; // All types can be collected
}

/// Check if type is comparable
pub fn isComparable(comptime T: type) bool {
    const trait = Comparable(T);
    return trait.has_natural_order or trait.has_compare or trait.has_order;
}

/// Check if type is aggregatable
pub fn isAggregatable(comptime T: type) bool {
    const trait = Aggregatable(T);
    return trait.is_numeric or trait.has_add;
}
