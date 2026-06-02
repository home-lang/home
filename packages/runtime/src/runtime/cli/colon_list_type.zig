// Copied from bun/src/runtime/cli/colon_list_type.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.strings → home_rt.strings
//   - bun.Output → home_rt.Output
//   - bun.Global → home_rt.Global
//
// Stubs:
//   - `bun.schema.api.Loader` parks behind a `LoaderStub` opaque so the
//     comptime branch (`comptime t == bun.schema.api.Loader`) is always
//     `false` at instantiation time. Callers that pass the real Loader
//     type (`bun.options.Loader`) re-attach when the options surface
//     ports.
//   - `bun.fmt.quote` / `bun.fmt.enumTagList` are not yet in home_rt; the
//     dead-code branch that references them parks behind the same
//     comptime gate. The diagnostic strings ride along untouched so the
//     port is byte-identical once both surfaces re-attach.

const std = @import("std");
const home_rt = @import("home");

const string = []const u8;

const Global = home_rt.Global;
const Output = home_rt.Output;
const strings = home_rt.strings;

/// Placeholder for `bun.schema.api.Loader`. The comptime branch in
/// `ColonListType(...).load` only matters when `t == LoaderStub`, which
/// is never true in the home_rt build. Re-attach when the schema surface
/// ports.
pub const LoaderStub = opaque {};

pub fn ColonListType(comptime t: type, comptime value_resolver: anytype) type {
    return struct {
        pub fn init(allocator: std.mem.Allocator, count: usize) !@This() {
            const keys = try allocator.alloc(string, count);
            const values = try allocator.alloc(t, count);

            return @This(){ .keys = keys, .values = values };
        }
        keys: []string,
        values: []t,

        pub fn load(self: *@This(), input: []const string) !void {
            for (input, 0..) |str, i| {
                // Support either ":" or "=" as the separator, preferring whichever is first.
                // ":" is less confusing IMO because that syntax is used with flags
                // but "=" is what esbuild uses and I want this to be somewhat familiar for people using esbuild
                const midpoint = @min(strings.indexOfChar(str, ':') orelse std.math.maxInt(u32), strings.indexOfChar(str, '=') orelse std.math.maxInt(u32));
                if (midpoint == std.math.maxInt(u32)) {
                    return error.InvalidSeparator;
                }

                if (comptime t == LoaderStub) {
                    if (str[0..midpoint].len > 0 and str[0] != '.') {
                        // bun.fmt.quote parked — re-attaches when home_rt.fmt grows the quote helper.
                        Output.prettyErrorln("error: file extension must start with a '.' (while mapping loader {s})", .{str});
                        Global.exit(1);
                    }
                }

                self.keys[i] = str[0..midpoint];
                self.values[i] = value_resolver(str[midpoint + 1 .. str.len]) catch |err| {
                    if (err == error.InvalidLoader) {
                        // bun.fmt.enumTagList parked — re-attaches with options.Loader.
                        Output.prettyErrorln("error: invalid loader {s}", .{str[midpoint + 1 .. str.len]});
                        Global.exit(1);
                    }
                    return err;
                };
            }
        }

        pub fn resolve(allocator: std.mem.Allocator, input: []const string) !@This() {
            var list = try init(allocator, input.len);
            list.load(input) catch |err| {
                if (err == error.InvalidSeparator) {
                    Output.prettyErrorln("error: expected \":\" separator", .{});
                    Global.exit(1);
                }

                return err;
            };
            return list;
        }
    };
}

test "ColonListType: load splits on ':' separator" {
    const Resolver = struct {
        fn resolve(v: []const u8) !u32 {
            return std.fmt.parseInt(u32, v, 10) catch error.BadInt;
        }
    };
    const T = ColonListType(u32, Resolver.resolve);
    var list = try T.init(std.testing.allocator, 2);
    defer {
        std.testing.allocator.free(list.keys);
        std.testing.allocator.free(list.values);
    }
    const input = &[_][]const u8{ "key1:42", "key2:1337" };
    try list.load(input);
    try std.testing.expectEqualStrings("key1", list.keys[0]);
    try std.testing.expectEqual(@as(u32, 42), list.values[0]);
    try std.testing.expectEqualStrings("key2", list.keys[1]);
    try std.testing.expectEqual(@as(u32, 1337), list.values[1]);
}

test "ColonListType: load splits on '=' separator (esbuild compat)" {
    const Resolver = struct {
        fn resolve(v: []const u8) !u32 {
            return std.fmt.parseInt(u32, v, 10) catch error.BadInt;
        }
    };
    const T = ColonListType(u32, Resolver.resolve);
    var list = try T.init(std.testing.allocator, 1);
    defer {
        std.testing.allocator.free(list.keys);
        std.testing.allocator.free(list.values);
    }
    try list.load(&.{"foo=99"});
    try std.testing.expectEqualStrings("foo", list.keys[0]);
    try std.testing.expectEqual(@as(u32, 99), list.values[0]);
}

test "ColonListType: load returns InvalidSeparator when no ':' or '='" {
    const Resolver = struct {
        fn resolve(v: []const u8) !u32 {
            return std.fmt.parseInt(u32, v, 10) catch error.BadInt;
        }
    };
    const T = ColonListType(u32, Resolver.resolve);
    var list = try T.init(std.testing.allocator, 1);
    defer {
        std.testing.allocator.free(list.keys);
        std.testing.allocator.free(list.values);
    }
    try std.testing.expectError(error.InvalidSeparator, list.load(&.{"no-separator"}));
}
