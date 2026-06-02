// Copied from bun/src/collections/comptime_string_map.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").
//
// The `fromJS` / `fromJSCaseInsensitive` / `fromString` methods are
// intentionally omitted from this copy — they pull in JSC + bun.String
// which haven't been brought across yet. They'll be re-added under
// `src/jsc/` once Phase 12.2 lands.

/// Comptime string map optimized for small sets of disparate string keys.
/// Works by separating the keys by length at comptime and only checking strings of
/// equal length at runtime.
pub fn ComptimeStringMapWithKeyType(comptime KeyType: type, comptime V: type, comptime kvs_list: anytype) type {
    const KV = struct {
        key: []const KeyType,
        value: V,
    };

    const precomputed = comptime blk: {
        @setEvalBranchQuota(99999);

        var sorted_kvs: [kvs_list.len]KV = undefined;
        const lenAsc = (struct {
            fn lenAsc(context: void, a: KV, b: KV) bool {
                _ = context;
                if (a.key.len != b.key.len) {
                    return a.key.len < b.key.len;
                }
                @setEvalBranchQuota(999999);
                return std.mem.order(KeyType, a.key, b.key) == .lt;
            }
        }).lenAsc;
        if (KeyType == u8) {
            for (kvs_list, 0..) |kv, i| {
                if (V != void) {
                    sorted_kvs[i] = .{ .key = kv.@"0", .value = kv.@"1" };
                } else {
                    sorted_kvs[i] = .{ .key = kv.@"0", .value = {} };
                }
            }
        } else {
            @compileError("Not implemented for this key type");
        }
        std.sort.pdq(KV, &sorted_kvs, {}, lenAsc);
        const min_len = sorted_kvs[0].key.len;
        const max_len = sorted_kvs[sorted_kvs.len - 1].key.len;
        var len_indexes: [max_len + 1]usize = undefined;
        var len: usize = 0;
        var i: usize = 0;

        while (len <= max_len) : (len += 1) {
            @setEvalBranchQuota(99999);
            while (len > sorted_kvs[i].key.len) {
                i += 1;
            }
            len_indexes[len] = i;
        }
        break :blk .{
            .min_len = min_len,
            .max_len = max_len,
            .sorted_kvs = sorted_kvs,
            .len_indexes = len_indexes,
        };
    };

    return struct {
        const len_indexes = precomputed.len_indexes;
        pub const kvs = precomputed.sorted_kvs;

        const keys_list: []const []const KeyType = blk: {
            var k: [kvs.len][]const KeyType = undefined;
            for (kvs, 0..) |kv, i| {
                k[i] = kv.key;
            }
            const final = k;
            break :blk &final;
        };

        pub const Value = V;

        pub fn keys() []const []const KeyType {
            return keys_list;
        }

        pub fn has(str: []const KeyType) bool {
            return get(str) != null;
        }

        pub fn getWithLength(str: []const KeyType, comptime len: usize) ?V {
            const end = comptime brk: {
                var i = len_indexes[len];
                @setEvalBranchQuota(99999);
                while (i < kvs.len and kvs[i].key.len == len) : (i += 1) {}
                break :brk i;
            };
            inline for (len_indexes[len]..end) |i| {
                if (strings.eqlComptimeCheckLenWithType(KeyType, str, kvs[i].key, false)) {
                    return kvs[i].value;
                }
            }
            return null;
        }

        pub fn get(str: []const KeyType) ?V {
            if (str.len < precomputed.min_len or str.len > precomputed.max_len)
                return null;
            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (str.len == i) {
                    return getWithLength(str, i);
                }
            }
            return null;
        }

        /// Faithful to upstream `comptime_string_map.zig:195`. Delegates to the
        /// JSC helper now that `src/jsc/comptime_string_map_jsc.zig` is present.
        pub fn fromJS(globalThis: anytype, input: anytype) home_rt.JSError!?V {
            return @import("../jsc/comptime_string_map_jsc.zig").fromJS(@This(), globalThis, input);
        }

        /// Throws if toString() throws.
        pub fn fromJSCaseInsensitive(globalThis: anytype, input: anytype) home_rt.JSError!?V {
            return @import("../jsc/comptime_string_map_jsc.zig").fromJSCaseInsensitive(@This(), globalThis, input);
        }

        pub fn fromString(str: home_rt.String) ?V {
            return getWithEql(str, home_rt.String.eqlComptime);
        }

        /// Faithful to upstream `comptime_string_map.zig:108`.
        pub fn getWithLengthAndEql(str: anytype, comptime len: usize, comptime eqls: anytype) ?V {
            const end = comptime brk: {
                var i = len_indexes[len];
                @setEvalBranchQuota(99999);
                while (i < kvs.len and kvs[i].key.len == len) : (i += 1) {}
                break :brk i;
            };
            // This benchmarked faster for both small and large lists of strings than using a big switch statement
            // But only so long as the keys are a sorted list.
            inline for (len_indexes[len]..end) |i| {
                if (eqls(str, kvs[i].key)) {
                    return kvs[i].value;
                }
            }
            return null;
        }

        /// Faithful to upstream `comptime_string_map.zig:236`. Accepts a `[]const u8`
        /// slice or any type with a `len` field / `length()` method (e.g. `bun.String`).
        pub fn getWithEql(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len")) input.len else input.length();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;

            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    return getWithLengthAndEql(input, i, eql);
                }
            }
            return null;
        }

        /// Faithful to upstream `comptime_string_map.zig:129`.
        pub fn getWithLengthAndEqlList(str: anytype, comptime len: usize, comptime eqls: anytype) ?V {
            const end = comptime brk: {
                var i = len_indexes[len];
                @setEvalBranchQuota(99999);
                while (i < kvs.len and kvs[i].key.len == len) : (i += 1) {}
                break :brk i;
            };
            const start = comptime len_indexes[len];
            const range = comptime keys()[start..end];
            if (eqls(str, range)) |k| {
                return kvs[start + k].value;
            }
            return null;
        }

        pub fn getWithEqlList(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len")) input.len else input.length();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;
            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    return getWithLengthAndEqlList(input, i, eql);
                }
            }
            return null;
        }

        pub fn getWithEqlLowercase(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len")) input.len else input.length();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;
            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    const lowerbuf: [i]u8 = brk: {
                        var buf: [i]u8 = undefined;
                        for (input, &buf) |c, *j| {
                            j.* = std.ascii.toLower(c);
                        }
                        break :brk buf;
                    };
                    return getWithLengthAndEql(&lowerbuf, i, eql);
                }
            }
            return null;
        }

        pub fn getASCIIICaseInsensitive(input: anytype) ?V {
            return getWithEqlLowercase(input, home_rt.strings.eqlComptimeIgnoreLen);
        }

        pub fn getCaseInsensitiveWithEql(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len")) input.len else input.length();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;
            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    const lowercased: [i]u8 = brk: {
                        var buf: [i]u8 = undefined;
                        for (input[0..i], &buf) |c, *b| {
                            b.* = switch (c) {
                                'A'...'Z' => c + 32,
                                else => c,
                            };
                        }
                        break :brk buf;
                    };
                    return getWithLengthAndEql(&lowercased, i, eql);
                }
            }
            return null;
        }

        pub fn getAnyCase(input: anytype) ?V {
            return getCaseInsensitiveWithEql(input, home_rt.strings.eqlComptimeIgnoreLen);
        }

        /// Returns the index of the key in the sorted list of keys.
        pub fn indexOf(str: []const KeyType) ?usize {
            if (str.len < precomputed.min_len or str.len > precomputed.max_len)
                return null;
            comptime var len: usize = precomputed.min_len;
            inline while (len <= precomputed.max_len) : (len += 1) {
                if (str.len == len) {
                    const end = comptime brk: {
                        var i = len_indexes[len];
                        @setEvalBranchQuota(99999);
                        while (i < kvs.len and kvs[i].key.len == len) : (i += 1) {}
                        break :brk i;
                    };
                    inline for (len_indexes[len]..end) |i| {
                        if (strings.eqlComptimeCheckLenWithType(KeyType, str, kvs[i].key, false)) {
                            return i;
                        }
                    }
                    return null;
                }
            }
            return null;
        }

        /// Lookup the first-defined string key for a given value.
        pub fn getKey(value: V) ?[]const KeyType {
            inline for (kvs) |kv| {
                if (kv.value == value) return kv.key;
            }
            return null;
        }
    };
}

pub fn ComptimeStringMap(comptime V: type, comptime kvs_list: anytype) type {
    return ComptimeStringMapWithKeyType(u8, V, kvs_list);
}

pub fn ComptimeStringMap16(comptime V: type, comptime kvs_list: anytype) type {
    return ComptimeStringMapWithKeyType(u16, V, kvs_list);
}

const TestEnum = enum { A, B, C, D, E };

test "ComptimeStringMap list literal of list literals" {
    const map = ComptimeStringMap(TestEnum, .{
        .{ "these", .D },
        .{ "have", .A },
        .{ "nothing", .B },
        .{ "incommon", .C },
        .{ "samelen", .E },
    });

    try testMap(map);
}

fn testMap(comptime map: anytype) !void {
    try std.testing.expectEqual(TestEnum.A, map.get("have").?);
    try std.testing.expectEqual(TestEnum.B, map.get("nothing").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expectEqual(TestEnum.D, map.get("these").?);
    try std.testing.expectEqual(TestEnum.E, map.get("samelen").?);
    try std.testing.expect(!map.has("missing"));
    try std.testing.expect(map.has("these"));
}

test "ComptimeStringMap void value type" {
    const map = ComptimeStringMap(void, .{
        .{"these"},
        .{"have"},
        .{"nothing"},
        .{"incommon"},
        .{"samelen"},
    });
    try std.testing.expectEqual({}, map.get("have").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expect(!map.has("missing"));
    try std.testing.expect(map.has("these"));
}

const std = @import("std");
const home_rt = @import("home");
const strings = home_rt.strings;
