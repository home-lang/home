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
    /// Unit/void value (no value)
    Void,

    /// Format this value for display (implements std.fmt formatting).
    ///
    /// Produces a human-readable string representation of the value.
    /// Arrays are shown as `[elem1, elem2, ...]`, structs as `<TypeName instance>`,
    /// and functions as `<fn name>`.
    ///
    /// Parameters:
    ///   - self: The value to format
    ///   - writer: Output writer
    pub fn format(
        self: Value,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .Int => |v| try writer.print("{d}", .{v}),
            .Float => |v| try writer.print("{d}", .{v}),
            .Bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .String => |v| try writer.print("{s}", .{v}),
            .Array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try elem.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .Struct => |s| try writer.print("<{s} instance>", .{s.type_name}),
            .Function => |f| try writer.print("<fn {s}>", .{f.name}),
            .Void => try writer.writeAll("void"),
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
