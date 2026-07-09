// Copied from bun/src/meta/traits.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure-Zig leaf file; no @import("bun") rewrite needed. Zig 0.17 compat:
// uppercase TypeInfo tags (.One/.Slice/.Array) lowercased to (.one/.slice/.array)
// and a missing `info.` qualifier in isSingleItemPtr fixed.

/// Returns true if the passed type will coerce to []const u8.
/// Any of the following are considered strings:
/// ```
/// []const u8, [:S]const u8, *const [N]u8, *const [N:S]u8,
/// []u8, [:S]u8, *[:S]u8, *[N:S]u8.
/// ```
/// These types are not considered strings:
/// ```
/// u8, [N]u8, [*]const u8, [*:0]const u8,
/// [*]const [N]u8, []const u16, []const i8,
/// *const u8, ?[]const u8, ?*const [N]u8.
/// ```
pub inline fn isZigString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals
        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;

        const ptr = &info.pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.attrs.@"volatile" or ptr.attrs.@"allowzero") break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .one) {
            const child = @typeInfo(ptr.child);
            if (child == .array) {
                const arr = &child.array;
                break :blk arr.child == u8;
            }
        }

        break :blk false;
    };
}

pub inline fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

pub inline fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

pub inline fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"opaque", .@"union" => true,
        else => false,
    };
}

pub inline fn isSingleItemPtr(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .one;
}

pub fn isExternContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.layout == .@"extern",
        .@"union" => |u| u.layout == .@"extern",
        else => false,
    };
}

pub fn isConstPtr(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.attrs.@"const";
}

pub fn isIndexable(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr| switch (ptr.size) {
            .one => @typeInfo(ptr.child) == .array,
            else => true,
        },
        .array, .vector => true,
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

const std = @import("std");

test "isContainer / isIndexable / isSlice classifiers" {
    const S = struct { x: u32 };
    try std.testing.expect(isContainer(S));
    try std.testing.expect(!isContainer(u32));

    try std.testing.expect(isIndexable([4]u8));
    try std.testing.expect(isIndexable([]const u8));
    try std.testing.expect(!isIndexable(u32));

    try std.testing.expect(isSlice([]const u8));
    try std.testing.expect(!isSlice(*const u8));

    try std.testing.expect(isZigString([]const u8));
    try std.testing.expect(isZigString(*const [4]u8));
    try std.testing.expect(!isZigString([*]const u8));
    try std.testing.expect(isNumber(comptime_int));
    try std.testing.expect(isNumber(f64));
    try std.testing.expect(isSingleItemPtr(*const u8));
    try std.testing.expect(isConstPtr(*const u8));
    try std.testing.expect(!isConstPtr(*u8));

    const Extern = extern struct { x: u8 };
    try std.testing.expect(isExternContainer(Extern));
}
