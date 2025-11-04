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

// ==================== Additional Traits ====================

/// Checks if a type can be hashed for use in HashMaps
pub fn Hashable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type has natural hashing
        pub const has_natural_hash = switch (@typeInfo(T)) {
            .int, .float, .bool, .@"enum" => true,
            .pointer => |ptr| ptr.size == .one or ptr.size == .many or ptr.size == .slice,
            else => false,
        };

        /// Check if type has custom hash method
        pub const has_hash = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "hash"),
            else => false,
        };

        /// Verify type is hashable
        pub fn verify() void {
            if (!has_natural_hash and !has_hash) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not hashable. " ++
                    "Add a 'hash(self: " ++ @typeName(T) ++ ") u64' method.");
            }
        }

        /// Get hash of value
        pub fn hash(val: T) u64 {
            if (has_hash) {
                return T.hash(val);
            } else if (has_natural_hash) {
                return switch (@typeInfo(T)) {
                    .int => @as(u64, @bitCast(@as(i64, @intCast(val)))),
                    .float => @as(u64, @bitCast(val)),
                    .bool => if (val) 1 else 0,
                    .@"enum" => @intFromEnum(val),
                    .pointer => @intFromPtr(val),
                    else => 0,
                };
            } else {
                @compileError("Type is not hashable");
            }
        }
    };
}

/// Checks if a type can be displayed/formatted
pub fn Displayable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type is primitive (auto-displayable)
        pub const is_primitive = switch (@typeInfo(T)) {
            .int, .float, .bool => true,
            else => false,
        };

        /// Check if type has format method
        pub const has_format = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "format"),
            else => false,
        };

        /// Check if type has toString method
        pub const has_toString = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "toString"),
            else => false,
        };

        /// Verify type is displayable
        pub fn verify() void {
            if (!is_primitive and !has_format and !has_toString) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not displayable. " ++
                    "Add a 'format' or 'toString' method.");
            }
        }
    };
}

/// Checks if a type is equatable (can check equality)
pub fn Equatable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type has natural equality
        pub const has_natural_equality = switch (@typeInfo(T)) {
            .int, .float, .bool, .@"enum" => true,
            .pointer => true,
            else => false,
        };

        /// Check if type has eql method
        pub const has_eql = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "eql"),
            else => false,
        };

        /// Verify type is equatable
        pub fn verify() void {
            if (!has_natural_equality and !has_eql) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not equatable. " ++
                    "Add an 'eql(self: " ++ @typeName(T) ++ ", other: " ++ @typeName(T) ++ ") bool' method.");
            }
        }

        /// Check if two values are equal
        pub fn eql(a: T, b: T) bool {
            if (has_eql) {
                return T.eql(a, b);
            } else if (has_natural_equality) {
                return a == b;
            } else {
                @compileError("Type is not equatable");
            }
        }

        /// Check if two values are not equal
        pub fn notEql(a: T, b: T) bool {
            return !eql(a, b);
        }
    };
}

/// Checks if a type can be cloned
pub fn Cloneable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type is trivially copyable
        pub const is_copyable = switch (@typeInfo(T)) {
            .int, .float, .bool, .@"enum" => true,
            .@"struct" => !@hasDecl(T, "deinit"),
            else => false,
        };

        /// Check if type has clone method
        pub const has_clone = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "clone"),
            else => false,
        };

        /// Verify type is cloneable
        pub fn verify() void {
            if (!is_copyable and !has_clone) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not cloneable. " ++
                    "Add a 'clone(self: " ++ @typeName(T) ++ ", allocator: std.mem.Allocator) !" ++ @typeName(T) ++ "' method.");
            }
        }
    };
}

/// Checks if a type is serializable
pub fn Serializable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type is primitive (auto-serializable)
        pub const is_primitive = switch (@typeInfo(T)) {
            .int, .float, .bool => true,
            else => false,
        };

        /// Check if type has serialize method
        pub const has_serialize = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "serialize"),
            else => false,
        };

        /// Check if type has toJson method
        pub const has_toJson = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "toJson"),
            else => false,
        };

        /// Verify type is serializable
        pub fn verify() void {
            if (!is_primitive and !has_serialize and !has_toJson) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not serializable. " ++
                    "Add a 'serialize' or 'toJson' method.");
            }
        }
    };
}

/// Checks if a type can be iterated
pub fn Iterable(comptime T: type) type {
    return struct {
        pub const Type = T;

        /// Check if type is array-like
        pub const is_array = switch (@typeInfo(T)) {
            .pointer => |ptr| ptr.size == .slice or ptr.size == .many,
            .array => true,
            else => false,
        };

        /// Check if type has iterator method
        pub const has_iterator = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "iterator"),
            else => false,
        };

        /// Verify type is iterable
        pub fn verify() void {
            if (!is_array and !has_iterator) {
                @compileError("Type '" ++ @typeName(T) ++ "' is not iterable. " ++
                    "Add an 'iterator()' method that returns an iterator type.");
            }
        }
    };
}

// ==================== Additional Trait Helpers ====================

/// Helper to verify a type satisfies Hashable trait
pub fn verifyHashable(comptime T: type) void {
    Hashable(T).verify();
}

/// Helper to verify a type satisfies Displayable trait
pub fn verifyDisplayable(comptime T: type) void {
    Displayable(T).verify();
}

/// Helper to verify a type satisfies Equatable trait
pub fn verifyEquatable(comptime T: type) void {
    Equatable(T).verify();
}

/// Helper to verify a type satisfies Cloneable trait
pub fn verifyCloneable(comptime T: type) void {
    Cloneable(T).verify();
}

/// Helper to verify a type satisfies Serializable trait
pub fn verifySerializable(comptime T: type) void {
    Serializable(T).verify();
}

/// Helper to verify a type satisfies Iterable trait
pub fn verifyIterable(comptime T: type) void {
    Iterable(T).verify();
}

/// Check if type is hashable
pub fn isHashable(comptime T: type) bool {
    const trait = Hashable(T);
    return trait.has_natural_hash or trait.has_hash;
}

/// Check if type is displayable
pub fn isDisplayable(comptime T: type) bool {
    const trait = Displayable(T);
    return trait.is_primitive or trait.has_format or trait.has_toString;
}

/// Check if type is equatable
pub fn isEquatable(comptime T: type) bool {
    const trait = Equatable(T);
    return trait.has_natural_equality or trait.has_eql;
}

/// Check if type is cloneable
pub fn isCloneable(comptime T: type) bool {
    const trait = Cloneable(T);
    return trait.is_copyable or trait.has_clone;
}

/// Check if type is serializable
pub fn isSerializable(comptime T: type) bool {
    const trait = Serializable(T);
    return trait.is_primitive or trait.has_serialize or trait.has_toJson;
}

/// Check if type is iterable
pub fn isIterable(comptime T: type) bool {
    const trait = Iterable(T);
    return trait.is_array or trait.has_iterator;
}
