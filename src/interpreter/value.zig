const std = @import("std");

/// Function value representation
pub const FunctionValue = struct {
    name: []const u8,
    params: []const []const u8,
    // We'll store the body as an index into the program's statements
    body_index: usize,
};

/// Runtime value types for the Ion interpreter
pub const Value = union(enum) {
    Int: i64,
    Float: f64,
    Bool: bool,
    String: []const u8,
    Function: FunctionValue,
    Void,

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Int => |v| try writer.print("{d}", .{v}),
            .Float => |v| try writer.print("{d}", .{v}),
            .Bool => |v| try writer.print("{}", .{v}),
            .String => |v| try writer.print("{s}", .{v}),
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
            .Void => false,
            .Function => true,
        };
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .String => |s| allocator.free(s),
            else => {},
        }
    }
};
