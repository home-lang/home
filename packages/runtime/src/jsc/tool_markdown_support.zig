//! Native primitives for the shared Markdown parser, without Bun/WebCore ABI imports.
const std = @import("std");
pub const JSError = error{ JSError, JSTerminated, OutOfMemory };
pub const StackOverflow = error{StackOverflow};
pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
pub const bit_set = std.bit_set;
pub const strings = struct {
    pub fn indexOfAny(input: []const u8, needles: []const u8) ?usize {
        return std.mem.findAny(u8, input, needles);
    }
    pub fn indexOfCharPos(input: []const u8, char: u8, position: usize) ?usize {
        return std.mem.findScalarPos(u8, input, position, char);
    }
    pub fn eqlCaseInsensitiveASCIIIgnoreLength(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
    pub fn eqlCaseInsensitiveASCIIICheckLength(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
    pub fn codepointSize(comptime T: type, first: T) u3 {
        return std.unicode.utf8ByteSequenceLength(@intCast(first)) catch 0;
    }
    pub fn decodeWTF8RuneT(bytes: *const [4]u8, length: usize, comptime T: type, replacement: T) T {
        return @intCast(std.unicode.wtf8Decode(bytes[0..length]) catch return replacement);
    }
    pub fn encodeWTF8RuneT(bytes: *[4]u8, comptime T: type, point: T) u3 {
        return std.unicode.wtf8Encode(@intCast(point), bytes) catch unreachable;
    }
};
