// String Manipulation Types for Home Type System
//
// String manipulation types for type-level string transformations.
// Uppercase, Lowercase, Capitalize, Trim, etc.

const std = @import("std");
const Type = @import("type_system.zig").Type;

/// String manipulation types for type-level string transformations
pub const StringManipulationType = union(enum) {
    /// Uppercase<S> - converts string literal to uppercase
    uppercase: *const Type,
    /// Lowercase<S> - converts string literal to lowercase
    lowercase: *const Type,
    /// Capitalize<S> - capitalizes first letter
    capitalize: *const Type,
    /// Uncapitalize<S> - lowercases first letter
    uncapitalize: *const Type,
    /// Trim<S> - removes leading/trailing whitespace
    trim: *const Type,
    /// TrimStart<S> - removes leading whitespace
    trim_start: *const Type,
    /// TrimEnd<S> - removes trailing whitespace
    trim_end: *const Type,
    /// Replace<S, Search, Replacement>
    replace: ReplaceInfo,
    /// Split<S, Delimiter> - splits string into tuple
    split: SplitInfo,
    /// Join<Tuple, Delimiter> - joins tuple into string
    join: JoinInfo,

    pub const ReplaceInfo = struct {
        source: *const Type,
        search: []const u8,
        replacement: []const u8,
    };

    pub const SplitInfo = struct {
        source: *const Type,
        delimiter: []const u8,
    };

    pub const JoinInfo = struct {
        source: *const Type,
        delimiter: []const u8,
    };

    /// Evaluate the string manipulation
    pub fn evaluate(self: StringManipulationType, allocator: std.mem.Allocator) !*Type {
        const result = try allocator.create(Type);

        switch (self) {
            .uppercase => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    var upper = try allocator.alloc(u8, ty.Literal.string.len);
                    for (ty.Literal.string, 0..) |c, i| {
                        upper[i] = std.ascii.toUpper(c);
                    }
                    result.* = Type{ .Literal = .{ .string = upper } };
                    return result;
                }
                result.* = Type.String; // Non-literal returns string
            },
            .lowercase => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    var lower = try allocator.alloc(u8, ty.Literal.string.len);
                    for (ty.Literal.string, 0..) |c, i| {
                        lower[i] = std.ascii.toLower(c);
                    }
                    result.* = Type{ .Literal = .{ .string = lower } };
                    return result;
                }
                result.* = Type.String;
            },
            .capitalize => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    const str = ty.Literal.string;
                    if (str.len > 0) {
                        var cap = try allocator.alloc(u8, str.len);
                        cap[0] = std.ascii.toUpper(str[0]);
                        @memcpy(cap[1..], str[1..]);
                        result.* = Type{ .Literal = .{ .string = cap } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .uncapitalize => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    const str = ty.Literal.string;
                    if (str.len > 0) {
                        var uncap = try allocator.alloc(u8, str.len);
                        uncap[0] = std.ascii.toLower(str[0]);
                        @memcpy(uncap[1..], str[1..]);
                        result.* = Type{ .Literal = .{ .string = uncap } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .trim => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trim(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .trim_start => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trimLeft(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .trim_end => |ty| {
                if (std.meta.activeTag(ty.*) == .Literal and ty.Literal == .string) {
                    const trimmed = std.mem.trimRight(u8, ty.Literal.string, " \t\n\r");
                    result.* = Type{ .Literal = .{ .string = trimmed } };
                    return result;
                }
                result.* = Type.String;
            },
            .replace => |info| {
                if (std.meta.activeTag(info.source.*) == .Literal and info.source.Literal == .string) {
                    const str = info.source.Literal.string;
                    // Count replacements needed
                    var count: usize = 0;
                    var i: usize = 0;
                    while (i <= str.len - info.search.len) {
                        if (std.mem.eql(u8, str[i..][0..info.search.len], info.search)) {
                            count += 1;
                            i += info.search.len;
                        } else {
                            i += 1;
                        }
                    }
                    if (count > 0) {
                        const new_len = str.len - (count * info.search.len) + (count * info.replacement.len);
                        var replaced = try allocator.alloc(u8, new_len);
                        var src_idx: usize = 0;
                        var dst_idx: usize = 0;
                        while (src_idx < str.len) {
                            if (src_idx <= str.len - info.search.len and
                                std.mem.eql(u8, str[src_idx..][0..info.search.len], info.search))
                            {
                                @memcpy(replaced[dst_idx..][0..info.replacement.len], info.replacement);
                                dst_idx += info.replacement.len;
                                src_idx += info.search.len;
                            } else {
                                replaced[dst_idx] = str[src_idx];
                                dst_idx += 1;
                                src_idx += 1;
                            }
                        }
                        result.* = Type{ .Literal = .{ .string = replaced } };
                        return result;
                    }
                }
                result.* = Type.String;
            },
            .split, .join => {
                // These produce more complex types - return string for now
                result.* = Type.String;
            },
        }
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "string manipulation - uppercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .uppercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("HELLO", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - lowercase" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "HELLO" } };

    const manip = StringManipulationType{ .lowercase = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - capitalize" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "hello" } };

    const manip = StringManipulationType{ .capitalize = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("Hello", result.Literal.string);
    allocator.free(@constCast(result.Literal.string));
}

test "string manipulation - trim" {
    const allocator = std.testing.allocator;

    const hello = try allocator.create(Type);
    defer allocator.destroy(hello);
    hello.* = Type{ .Literal = .{ .string = "  hello  " } };

    const manip = StringManipulationType{ .trim = hello };
    const result = try manip.evaluate(allocator);
    defer allocator.destroy(result);

    try std.testing.expectEqualStrings("hello", result.Literal.string);
}
