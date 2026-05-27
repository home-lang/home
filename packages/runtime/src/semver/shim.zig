const std = @import("std");

pub const Environment = struct {
    pub const isDebug = @import("builtin").mode == .Debug;
    pub const allow_assert = isDebug;
};

pub const Output = struct {
    pub const enable_ansi_colors_stdout = false;

    pub inline fn prettyFmt(comptime fmt: []const u8, comptime _: bool) []const u8 {
        return fmt;
    }

    pub fn prettyErrorln(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
    }
};

pub const OOM = std.mem.Allocator.Error;
pub const default_allocator = std.heap.smp_allocator;

pub fn assert(ok: bool) void {
    if (Environment.allow_assert) std.debug.assert(ok);
}

pub fn copy(comptime T: type, dest: []T, src: []const T) void {
    @memcpy(dest[0..src.len], src);
}

/// Faithful to `bun.IdentityContext(u64)`: a HashMap context whose `hash`
/// is the identity function over a `u64` key (the key is already a hash).
pub fn IdentityContext(comptime Key: type) type {
    return struct {
        pub fn hash(_: @This(), key: Key) u64 {
            return key;
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a == b;
        }
    };
}

pub const strings = struct {
    pub const whitespace_chars = [_]u8{ ' ', '\t', '\n', '\r', std.ascii.control_code.vt, std.ascii.control_code.ff };

    pub fn isAllASCII(input: []const u8) bool {
        for (input) |c| {
            if (c > 127) return false;
        }
        return true;
    }

    pub inline fn trim(input: []const u8, values: []const u8) []const u8 {
        return std.mem.trim(u8, input, values);
    }

    pub inline fn containsChar(input: []const u8, char: u8) bool {
        return std.mem.indexOfScalar(u8, input, char) != null;
    }

    pub inline fn split(input: []const u8, delimiter: []const u8) std.mem.SplitIterator(u8, .sequence) {
        return std.mem.splitSequence(u8, input, delimiter);
    }

    pub inline fn order(lhs: []const u8, rhs: []const u8) std.math.Order {
        return std.mem.order(u8, lhs, rhs);
    }

    pub fn lengthOfLeadingWhitespaceASCII(input: []const u8) usize {
        var i: usize = 0;
        while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
        return i;
    }
};

