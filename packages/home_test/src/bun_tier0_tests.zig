const std = @import("std");
const bun = @import("bun");

const diff_match_patch = @import("bun/diff/diff_match_patch.zig");
const fixtures = @import("bun/harness/fixtures.zig");
const recover = @import("bun/harness/recover.zig");

test "copied Bun diff_match_patch compiles and diffs" {
    const DMP = diff_match_patch.DMP(u8);
    var diffs = try DMP.default.diff(std.testing.allocator, "hello", "hallo", false);
    defer DMP.deinitDiffList(std.testing.allocator, &diffs);

    try std.testing.expect(diffs.items.len >= 1);
}

test "copied Bun fixtures embed common harness files" {
    const package_json = fixtures.fixtures.get("package.json") orelse return error.MissingPackageJsonFixture;
    const tsconfig_json = fixtures.fixtures.get("tsconfig.json") orelse return error.MissingTsconfigFixture;

    try std.testing.expect(package_json.len > 0);
    try std.testing.expect(tsconfig_json.len > 0);
}

test "copied Bun recover exposes panic recovery hooks" {
    try std.testing.expect(@hasDecl(recover, "callForTest"));
    try std.testing.expect(@hasDecl(recover, "call"));
    try std.testing.expect(@hasDecl(recover, "panic"));
}

test "copied Bun compat shim supports runner string maps" {
    var map: bun.StringHashMapUnmanaged(u32) = .{};
    defer map.deinit(std.testing.allocator);

    try map.put(std.testing.allocator, "runner", 1);
    try std.testing.expectEqual(@as(?u32, 1), map.get("runner"));
}
