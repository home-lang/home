const std = @import("std");

const ast = @import("ast");

/// Function value representation
pub const FunctionValue = struct {
    name: []const u8,
    params: []const ast.Parameter,
    body: *ast.BlockStmt,
};

/// Struct value representation
pub const StructValue = struct {
    type_name: []const u8,
    fields: std.StringHashMap(Value),
};

/// Runtime value types for the Ion interpreter
///
/// MEMORY OWNERSHIP MODEL:
/// -----------------------
/// The Ion interpreter uses an arena allocator for all runtime values.
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
    Int: i64,
    Float: f64,
    Bool: bool,
    String: []const u8,
    Array: []const Value,
    Struct: StructValue,
    Function: FunctionValue,
    Void,

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

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Memory management is handled by the interpreter's arena allocator
        // All values are freed when the arena is deinitialized
        // This function is kept for API compatibility but is a no-op
    }
};
