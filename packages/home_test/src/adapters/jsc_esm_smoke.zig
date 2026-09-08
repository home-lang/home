const std = @import("std");

const JSModuleLoader = @import("home_rt").jsc.JSModuleLoader;
const build_options = @import("build_options");
const native_capture = @import("jsc_bootstrap.zig");

pub const native_bun_test_import_source =
    \\import { test, expect } from "bun:test";
    \\test("native bun:test import", () => expect(1 + 1).toBe(2));
;

test "native bun:test ESM smoke keeps canonical static import source" {
    try std.testing.expect(std.mem.indexOf(u8, native_bun_test_import_source, "import { test, expect } from \"bun:test\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_bun_test_import_source, "globalThis.__home_import(\"bun:test\")") == null);
}

test "native corpus execution supports unchanged bun:test ESM imports" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "native-import.test.js", .data = native_bun_test_import_source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "native-import.test.js", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var result = try native_capture.runHomeCapturedWithOptions(std.testing.allocator, "native-esm-import", &.{ "test", path }, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.timed_out and result.term.success());
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "1 pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "0 fail") != null);
}

test "native bun:test ESM smoke sees Bun-derived module loader bridge shape" {
    try std.testing.expect(@hasDecl(JSModuleLoader, "evaluate"));
    try std.testing.expect(@hasDecl(JSModuleLoader, "loadAndEvaluateModule"));
    try std.testing.expect(@hasDecl(JSModuleLoader, "import"));
}
