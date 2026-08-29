test {
    _ = @import("./shell_parser/braces.zig");
    _ = @import("./runtime/node/assert/myers_diff.zig");
}

test "basic string usage" {
    var s = home_rt.String.cloneUTF8("hi");
    defer s.deref();
    try t.expect(s.tag != .Dead and s.tag != .Empty);
    try t.expectEqual(s.length(), 2);
    try t.expectEqualStrings(s.asUTF8().?, "hi");
}

test "generated Node error discriminants match the linked C++ ABI" {
    const Error = home_rt.jsc.Error;
    try t.expectEqual(@as(u16, 121), @backingInt(Error.INVALID_ARG_VALUE_RangeError));
    try t.expectEqual(@as(u16, 159), @backingInt(Error.OPERATION_FAILED));
    try t.expectEqual(@as(u16, 233), @backingInt(Error.STREAM_ITER_MISSING_FLAG));
    try t.expectEqual(@as(u16, 327), @backingInt(Error.DIR_CONCURRENT_OPERATION));
}

test "dotenv expansion preserves the inherited boundary and releases same-file replacements" {
    const allocator = t.allocator;
    var map = home_rt.DotEnv.Map.init(allocator);
    defer map.map.deinit();
    defer for (map.map.keys(), map.map.values()) |key, value| {
        if (!std.mem.eql(u8, key, "INHERITED")) allocator.free(value.value);
    };
    try map.put("INHERITED", "$BASE");
    var loader = home_rt.DotEnv.Loader.init(&map, allocator);
    defer loader.custom_files_loaded.deinit();
    try loader.loadFromString("BASE=first\nCHAIN=$BASE\nBASE=last\nFINAL=${CHAIN}:${MISSING:-fallback}\nINHERITED=ignored\nESCAPED=\\$BASE", false, true);
    try t.expectEqualStrings("last", map.get("BASE").?);
    try t.expectEqualStrings("last", map.get("CHAIN").?);
    try t.expectEqualStrings("last:fallback", map.get("FINAL").?);
    try t.expectEqualStrings("$BASE", map.get("INHERITED").?);
    try t.expectEqualStrings("$BASE", map.get("ESCAPED").?);
    try loader.loadFromString("BASE=ignored\nNEXT=$FINAL", false, true);
    try t.expectEqualStrings("last", map.get("BASE").?);
    try t.expectEqualStrings("last:fallback", map.get("NEXT").?);
}

fn dotenvAllocationFailure(allocator: std.mem.Allocator) !void {
    const borrowed: []const u8 = "borrowed";
    var map = home_rt.DotEnv.Map.init(allocator);
    defer map.map.deinit();
    defer for (map.map.values()) |value| {
        if (value.value.ptr != borrowed.ptr) allocator.free(value.value);
    };
    try map.put("OLD", borrowed);
    var loader = home_rt.DotEnv.Loader.init(&map, allocator);
    defer loader.custom_files_loaded.deinit();
    // Overriding a borrowed entry must not free it. Repeated definitions and
    // expansion must leave valid map values even if their next allocation fails.
    try loader.loadFromString("OLD=first\nOLD=last\nNEW=one\nNEW=two\nEXPANDED=${NEW}:suffix", true, true);
    try t.expectEqualStrings("last", map.get("OLD").?);
    try t.expectEqualStrings("two:suffix", map.get("EXPANDED").?);
}

test "dotenv parser is safe at every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, dotenvAllocationFailure, .{});
}

const home_rt = @import("home");

// The CLI's bootstrap adapter supplies this dispatch symbol in executable
// builds. The substrate test root has no bootstrap realm, so link registration
// directly to the same complete native N-API implementation.
extern fn HomeNative_napi_module_register(module: ?*anyopaque) void;
fn registerNativeNapiModule(module: ?*anyopaque) callconv(.c) void {
    HomeNative_napi_module_register(module);
}
comptime {
    if (@import("builtin").is_test and @import("build_options").enable_jsc) {
        @export(&registerNativeNapiModule, .{ .name = "napi_module_register" });
    }
}

const std = @import("std");
const t = std.testing;
