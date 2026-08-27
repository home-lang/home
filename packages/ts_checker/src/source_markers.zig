//! Exact first-occurrence searches for fixed source markers in one byte pass.
//! This is not a lexer: comments, strings, and identifier substrings retain
//! the same meaning as independent `std.mem.indexOf` calls.
const std = @import("std");

pub const patterns = &[_][]const u8{
    "@filename:", "@Filename:", "export",  "namespace",   "as",        "declare", "var",    ":",      "any",
    "import",     "=",          "@import", "require",     "module",    "global",  "class",  "enum",   "type",
    "prototype",  "[",          "{",       ".prototype",  "protected", "@",       "@noLib", "@nolib", "@ts-check",
    "@check",     "@allow",     "@lib",    "import.meta",
};

pub const Index = Matcher(patterns);

/// A compiled Aho-Corasick automaton. Byte equivalence classes keep the
/// transition table small; bytes absent from every pattern share class zero.
/// Only first occurrences are recorded, including overlapping/suffix matches.
pub fn Matcher(comptime needles: []const []const u8) type {
    if (needles.len == 0 or needles.len > 64) @compileError("source marker count must be between 1 and 64");
    const max_states = blk: {
        var count: usize = 1;
        for (needles) |needle| {
            if (needle.len == 0) @compileError("source markers must be nonempty");
            count += needle.len;
        }
        if (count > std.math.maxInt(u16)) @compileError("source marker automaton is too large");
        break :blk count;
    };
    const alphabet = blk: {
        var classes: [256]u16 = @splat(0);
        var count: usize = 1;
        for (needles) |needle| {
            for (needle) |byte| {
                if (classes[byte] != 0) continue;
                classes[byte] = @intCast(count);
                count += 1;
            }
        }
        break :blk .{ .classes = classes, .count = count };
    };
    return struct {
        const Self = @This();
        const absent = std.math.maxInt(usize);
        positions: [needles.len]usize = @splat(absent),

        const Automaton = struct {
            transitions: [max_states][alphabet.count]u16 = std.mem.zeroes([max_states][alphabet.count]u16),
            outputs: [max_states]u64 = @splat(0),
        };

        const automaton = blk: {
            @setEvalBranchQuota(1_000_000);
            var result: Automaton = .{};
            var state_count: usize = 1;
            for (needles, 0..) |needle, i| {
                var state: u16 = 0;
                for (needle) |byte| {
                    const symbol = alphabet.classes[byte];
                    if (result.transitions[state][symbol] == 0) {
                        result.transitions[state][symbol] = @intCast(state_count);
                        state_count += 1;
                    }
                    state = result.transitions[state][symbol];
                }
                result.outputs[state] |= @as(u64, 1) << @intCast(i);
            }
            var failures: [max_states]u16 = @splat(0);
            var queue: [max_states]u16 = undefined;
            var head: usize = 0;
            var tail: usize = 0;
            for (result.transitions[0]) |next| {
                if (next == 0) continue;
                queue[tail] = next;
                tail += 1;
            }
            while (head < tail) : (head += 1) {
                const state = queue[head];
                for (0..alphabet.count) |symbol| {
                    const next = result.transitions[state][symbol];
                    const fallback = result.transitions[failures[state]][symbol];
                    if (next == 0) {
                        result.transitions[state][symbol] = fallback;
                    } else {
                        failures[next] = fallback;
                        result.outputs[next] |= result.outputs[fallback];
                        queue[tail] = next;
                        tail += 1;
                    }
                }
            }
            break :blk result;
        };

        pub fn scan(source: []const u8) Self {
            var result: Self = .{};
            var state: u16 = 0;
            var seen: u64 = 0;
            for (source, 0..) |byte, i| {
                state = automaton.transitions[state][alphabet.classes[byte]];
                var fresh = automaton.outputs[state] & ~seen;
                seen |= fresh;
                while (fresh != 0) {
                    const index = @ctz(fresh);
                    result.positions[index] = i + 1 - needles[index].len;
                    fresh &= fresh - 1;
                }
            }
            return result;
        }

        pub fn indexOf(self: *const Self, comptime needle: []const u8) ?usize {
            inline for (needles, 0..) |candidate, i| {
                if (comptime std.mem.eql(u8, candidate, needle)) {
                    return if (self.positions[i] == absent) null else self.positions[i];
                }
            }
            @compileError("unregistered source marker: " ++ needle);
        }

        pub fn contains(self: *const Self, comptime needle: []const u8) bool {
            return self.indexOf(needle) != null;
        }
    };
}

fn expectEquivalent(comptime needles: []const []const u8, source: []const u8) !void {
    const index = Matcher(needles).scan(source);
    inline for (needles) |needle| {
        try std.testing.expectEqual(std.mem.indexOf(u8, source, needle), index.indexOf(needle));
    }
}

test "source markers: exact substrings include comments strings and EOF" {
    for ([_][]const u8{
        "",                                                                         "export const value = 1;",                                      "// @Filename: a.ts\n// @filename: b.ts",
        "myclassify enumtype namespaceas .prototype prototype @import import.meta", "\"@noLib true\" /* @checkJs:false */ @ts-check @allowJs:true", "\x00\xffrequire\xc3\xa9@lib\x00<reference/**protected",
    }) |source| try expectEquivalent(patterns, source);
    inline for (patterns) |needle| {
        try expectEquivalent(patterns, needle);
        try expectEquivalent(patterns, "x" ++ needle ++ needle ++ "y");
        try expectEquivalent(patterns, needle[0 .. needle.len - 1]);
    }
}

test "source markers: overlapping suffixes and byte classes" {
    const needles = &[_][]const u8{ "a", "aa", "aaa", "ba", "aba", "bab", "bc", "bca", "c", "caa", "\xffa", "\x00" };
    for ([_][]const u8{ "", "ababa", "aaaa", "bcaaabcbab", "\xffaaaa\x00caa", "caa\xffa" }) |source| {
        try expectEquivalent(needles, source);
    }
}

test "source markers: generated bytes agree with independent searches" {
    var seed: u32 = 0x5eeda11;
    var buffer: [384]u8 = undefined;
    for (0..1024) |round| {
        const len = round % buffer.len;
        for (buffer[0..len]) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @truncate(seed >> 24);
        }
        const needle = patterns[round % patterns.len];
        if (len >= needle.len) {
            const offset = seed % (len - needle.len + 1);
            @memcpy(buffer[offset..][0..needle.len], needle);
        }
        try expectEquivalent(patterns, buffer[0..len]);
    }
}
