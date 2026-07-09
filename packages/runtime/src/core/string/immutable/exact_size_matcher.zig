// Copied verbatim from bun/src/core/string/immutable/exact_size_matcher.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// No rewrites: file is pure stdlib (only depends on @import("std")).

pub fn ExactSizeMatcher(comptime max_bytes: usize) type {
    switch (max_bytes) {
        1, 2, 4, 8, 12, 16 => {},
        else => {
            @compileError("max_bytes must be 1, 2, 4, 8, 12, or 16.");
        },
    }

    const T = @Int(
        .unsigned,
        max_bytes * 8,
    );

    return struct {
        pub fn match(str: anytype) T {
            switch (str.len) {
                1...max_bytes - 1 => {
                    var tmp: [max_bytes]u8 = undefined;
                    @memcpy(tmp[0..str.len], str);
                    @memset(tmp[str.len..], 0);

                    return std.mem.readInt(T, &tmp, .little);
                },
                max_bytes => {
                    return std.mem.readInt(T, str[0..max_bytes], .little);
                },
                0 => {
                    return 0;
                },
                else => {
                    return std.math.maxInt(T);
                },
            }
        }

        pub fn matchLower(str: anytype) T {
            switch (str.len) {
                1...max_bytes - 1 => {
                    var tmp: [max_bytes]u8 = undefined;
                    for (str, 0..) |char, i| {
                        tmp[i] = std.ascii.toLower(char);
                    }
                    @memset(tmp[str.len..], 0);
                    return std.mem.readInt(T, &tmp, .little);
                },
                max_bytes => {
                    return std.mem.readInt(T, str[0..max_bytes], .little);
                },
                0 => {
                    return 0;
                },
                else => {
                    return std.math.maxInt(T);
                },
            }
        }

        pub fn case(comptime str: []const u8) T {
            if (str.len < max_bytes) {
                var bytes = std.mem.zeroes([max_bytes]u8);
                bytes[0..str.len].* = str[0..str.len].*;
                return std.mem.readInt(T, &bytes, .little);
            } else if (str.len == max_bytes) {
                return std.mem.readInt(T, str[0..str.len], .little);
            } else {
                @compileError("str: \"" ++ str ++ "\" too long");
            }
        }
    };
}

const std = @import("std");

test "ExactSizeMatcher.match exact length returns little-endian integer" {
    const M = ExactSizeMatcher(4);
    // 'a'=0x61 'b'=0x62 'c'=0x63 'd'=0x64 → little-endian u32 = 0x64636261
    try std.testing.expectEqual(@as(u32, 0x64636261), M.match("abcd"));
}

test "ExactSizeMatcher.match empty string returns 0" {
    const M = ExactSizeMatcher(4);
    try std.testing.expectEqual(@as(u32, 0), M.match(""));
}

test "ExactSizeMatcher.match overlong string returns maxInt" {
    const M = ExactSizeMatcher(4);
    try std.testing.expectEqual(std.math.maxInt(u32), M.match("abcde"));
}

test "ExactSizeMatcher.match under-length pads with zeros" {
    const M = ExactSizeMatcher(4);
    // 'a' followed by zero padding: 0x00000061
    try std.testing.expectEqual(@as(u32, 0x61), M.match("a"));
}

test "ExactSizeMatcher.matchLower lowercases ASCII before matching" {
    const M = ExactSizeMatcher(4);
    // Under-length input exercises the lowercasing branch (exact-length branch is a fast path).
    try std.testing.expectEqual(M.match("abc"), M.matchLower("ABC"));
}

test "ExactSizeMatcher.case comptime variant matches runtime match" {
    const M = ExactSizeMatcher(4);
    try std.testing.expectEqual(M.case("abcd"), M.match("abcd"));
    try std.testing.expectEqual(M.case("ab"), M.match("ab"));
}
