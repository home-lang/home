const std = @import("std");

pub const ArenaAllocator = std.heap.ArenaAllocator;
pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;

pub fn span(pointer: anytype) std.mem.Span(@TypeOf(pointer)) {
    return std.mem.span(pointer);
}

pub const Output = struct {
    pub fn pretty(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    pub fn prettyErrorln(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
    }

    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    pub fn flush() void {}
};
