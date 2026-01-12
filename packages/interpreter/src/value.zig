const std = @import("std");

const ast = @import("ast");

/// Function value representation for closures and function declarations.
///
/// Stores the runtime representation of a function, including its name,
/// parameter list, and body. This is used both for user-defined functions
/// and for closures that capture their environment.
pub const FunctionValue = struct {
    /// Function name (for display and debugging)
    name: []const u8,
    /// Parameter declarations (names and types)
    params: []const ast.Parameter,
    /// Function body as a block statement
    body: *ast.BlockStmt,
};

/// Reference value (for mutable borrows)
pub const ReferenceValue = struct {
    /// The name of the variable being referenced
    var_name: []const u8,
    /// Whether this is a mutable reference
    is_mutable: bool,
};

/// Future value for async/await
pub const FutureValue = struct {
    /// The resolved value (null if pending) - uses pointer to avoid self-reference
    resolved: ?*const Value,
    /// Whether the future has been resolved
    is_resolved: bool,
};

/// Closure value representation with captured environment.
///
/// Stores an anonymous function along with the values it captured
/// from its defining scope.
pub const ClosureValue = struct {
    /// Parameter names for the closure
    param_names: []const []const u8,
    /// Closure body - either an expression or block
    body_expr: ?*ast.Expr,
    body_block: ?*ast.BlockStmt,
    /// Captured variable names and their values
    captured_names: []const []const u8,
    captured_values: []const Value,
};

/// Struct instance value at runtime.
///
/// Represents an instance of a struct type with its field values.
/// Fields are stored in a hash map for O(1) access by name.
pub const StructValue = struct {
    /// Name of the struct type this is an instance of
    type_name: []const u8,
    /// Field name -> value mapping
    fields: std.StringHashMap(Value),
};

/// Range value at runtime.
///
/// Represents a range of integers from start to end.
/// Used for iteration and range methods.
pub const RangeValue = struct {
    /// Start of the range (inclusive)
    start: i64,
    /// End of the range
    end: i64,
    /// Whether end is inclusive (..= vs ..)
    inclusive: bool,
    /// Step size for iteration (default 1)
    step: i64,
};

/// Enum variant info for runtime.
pub const EnumVariantInfo = struct {
    name: []const u8,
    has_data: bool,
};

/// Enum type value at runtime.
///
/// Represents an enum type definition that can be used to access variants.
pub const EnumTypeValue = struct {
    /// Name of the enum type
    name: []const u8,
    /// Variant names and info
    variants: []const EnumVariantInfo,
};

/// Runtime value types for the Home interpreter
///
/// MEMORY OWNERSHIP MODEL:
/// -----------------------
/// The Home interpreter uses an arena allocator for all runtime values.
/// This provides several benefits:
/// 1. No need to track individual allocations or reference counts
/// 2. All memory is freed at once when the interpreter is deinitialized
/// 3. No risk of use-after-free or double-free bugs
/// 4. Excellent performance for short-lived interpreter sessions
///
/// All heap-allocated data (strings, arrays, struct fields) use the
/// arena allocator from Interpreter.arena. The arena is freed when
/// Interpreter.deinit() is called.
///
/// Trade-offs:
/// - Memory usage grows during execution (cannot free individual values)
/// - Best suited for scripts and short-running programs
/// - Long-running REPL sessions may need periodic arena reset
pub const Value = union(enum) {
    /// 64-bit signed integer
    Int: i64,
    /// 64-bit floating-point number
    Float: f64,
    /// Boolean value (true/false)
    Bool: bool,
    /// String value (UTF-8 encoded)
    String: []const u8,
    /// Dynamic array of values
    Array: []const Value,
    /// Struct instance with named fields
    Struct: StructValue,
    /// Function or closure
    Function: FunctionValue,
    /// Anonymous closure with captures
    Closure: ClosureValue,
    /// Range for iteration
    Range: RangeValue,
    /// Enum type (for accessing enum variants like Color.Red)
    EnumType: EnumTypeValue,
    /// Unit/void value (no value)
    Void,
    /// Reference to a variable (for mutable borrows)
    Reference: ReferenceValue,
    /// Future value for async operations
    Future: FutureValue,

    /// Format this value for display (implements std.fmt formatting).
    ///
    /// Produces a human-readable string representation of the value.
    /// Arrays are shown as `[elem1, elem2, ...]`, structs as `<TypeName instance>`,
    /// and functions as `<fn name>`.
    ///
    /// Parameters:
    ///   - self: The value to format
    ///   - writer: Output writer
    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Int => |v| try writer.print("{d}", .{v}),
            .Float => |v| try writer.print("{d}", .{v}),
            .Bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .String => |v| try writer.print("{s}", .{v}),
            .Array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try elem.format(writer);
                }
                try writer.writeAll("]");
            },
            .Struct => |s| try writer.print("<{s} instance>", .{s.type_name}),
            .Function => |f| try writer.print("<fn {s}>", .{f.name}),
            .Closure => try writer.writeAll("<closure>"),
            .Range => |r| {
                if (r.inclusive) {
                    try writer.print("{d}..={d}", .{ r.start, r.end });
                } else {
                    try writer.print("{d}..{d}", .{ r.start, r.end });
                }
                if (r.step != 1) {
                    try writer.print(" step {d}", .{r.step});
                }
            },
            .Void => try writer.writeAll("void"),
            .Reference => |r| try writer.print("&{s}", .{r.var_name}),
            .Future => |f| {
                if (f.is_resolved) {
                    try writer.writeAll("<resolved future>");
                } else {
                    try writer.writeAll("<pending future>");
                }
            },
        }
    }

    /// Determine the truthiness of a value for conditional expressions.
    ///
    /// Used by if statements, while loops, and logical operators to
    /// convert any value to a boolean. The rules are:
    /// - Bool: Use the boolean value directly
    /// - Int: True if non-zero
    /// - Float: True if non-zero
    /// - String: True if non-empty
    /// - Array: True if non-empty
    /// - Struct: Always true
    /// - Function: Always true
    /// - Void: Always false
    ///
    /// Parameters:
    ///   - self: The value to test
    ///
    /// Returns: true if the value is considered "truthy", false otherwise
    pub fn isTrue(self: Value) bool {
        return switch (self) {
            .Bool => |b| b,
            .Int => |i| i != 0,
            .Float => |f| f != 0.0,
            .String => |s| s.len > 0,
            .Array => |arr| arr.len > 0,
            .Struct => true,
            .Void => false,
            .Function => true,
            .Closure => true,
            .Range => true,
            .EnumType => true,
            .Reference => true,
            .Future => |f| f.is_resolved,
        };
    }

    /// Deallocate resources used by this value (no-op with arena allocator).
    ///
    /// NOTE: This function is a no-op because Home uses an arena allocator
    /// for all runtime values. Memory is freed in bulk when the interpreter
    /// is deinitialized, not on a per-value basis. This function exists
    /// for API consistency and future compatibility.
    ///
    /// Parameters:
    ///   - self: The value (unused)
    ///   - allocator: The allocator (unused)
    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Memory management is handled by the interpreter's arena allocator
        // All values are freed when the arena is deinitialized
        // This function is kept for API compatibility but is a no-op
    }
};

// =============================================================================
// Tests
// =============================================================================

test "value: Int creation and equality" {
    const testing = std.testing;

    const v1 = Value{ .Int = 42 };
    const v2 = Value{ .Int = 42 };
    const v3 = Value{ .Int = 100 };

    try testing.expectEqual(v1.Int, v2.Int);
    try testing.expect(v1.Int != v3.Int);
}

test "value: Float creation" {
    const testing = std.testing;

    const v = Value{ .Float = 3.14 };
    try testing.expectApproxEqAbs(@as(f64, 3.14), v.Float, 0.001);
}

test "value: Bool creation" {
    const testing = std.testing;

    const t = Value{ .Bool = true };
    const f = Value{ .Bool = false };

    try testing.expect(t.Bool == true);
    try testing.expect(f.Bool == false);
}

test "value: String creation" {
    const testing = std.testing;

    const v = Value{ .String = "hello" };
    try testing.expectEqualStrings("hello", v.String);
}

test "value: Void type" {
    const testing = std.testing;

    const v = Value{ .Void = {} };
    try testing.expect(v == .Void);
}

test "value: Array creation" {
    const testing = std.testing;

    const elements = [_]Value{ Value{ .Int = 1 }, Value{ .Int = 2 }, Value{ .Int = 3 } };
    const v = Value{ .Array = &elements };

    try testing.expectEqual(@as(usize, 3), v.Array.len);
    try testing.expectEqual(@as(i64, 1), v.Array[0].Int);
    try testing.expectEqual(@as(i64, 2), v.Array[1].Int);
    try testing.expectEqual(@as(i64, 3), v.Array[2].Int);
}

test "value: RangeValue creation" {
    const testing = std.testing;

    const range = RangeValue{
        .start = 1,
        .end = 10,
        .inclusive = true,
        .step = 1,
    };

    try testing.expectEqual(@as(i64, 1), range.start);
    try testing.expectEqual(@as(i64, 10), range.end);
    try testing.expect(range.inclusive == true);
    try testing.expectEqual(@as(i64, 1), range.step);
}

test "value: Range value in Value union" {
    const testing = std.testing;

    const v = Value{ .Range = .{
        .start = 0,
        .end = 5,
        .inclusive = false,
        .step = 2,
    } };

    try testing.expectEqual(@as(i64, 0), v.Range.start);
    try testing.expectEqual(@as(i64, 5), v.Range.end);
    try testing.expect(v.Range.inclusive == false);
    try testing.expectEqual(@as(i64, 2), v.Range.step);
}

test "value: discriminate union types" {
    const testing = std.testing;

    const int_val = Value{ .Int = 42 };
    const float_val = Value{ .Float = 3.14 };
    const bool_val = Value{ .Bool = true };
    const string_val = Value{ .String = "test" };
    const void_val = Value{ .Void = {} };

    try testing.expect(int_val == .Int);
    try testing.expect(float_val == .Float);
    try testing.expect(bool_val == .Bool);
    try testing.expect(string_val == .String);
    try testing.expect(void_val == .Void);

    try testing.expect(int_val != .Float);
    try testing.expect(float_val != .Int);
}

test "value: deinit is no-op" {
    const testing = std.testing;

    // Just verify deinit doesn't crash - it's a no-op
    const v = Value{ .Int = 42 };
    v.deinit(testing.allocator);
}
