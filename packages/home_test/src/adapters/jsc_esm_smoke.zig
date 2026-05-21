const std = @import("std");

const JSModuleLoader = @import("home_rt").jsc.JSModuleLoader;
const corpus_runner = @import("../corpus_runner.zig");

pub const native_bun_test_import_source =
    \\import { test, expect } from "bun:test";
    \\test("native bun:test import", () => expect(1 + 1).toBe(2));
;

pub const blocked_reason = "native-esm-loader-missing";

test "native bun:test ESM smoke keeps canonical static import source" {
    try std.testing.expect(std.mem.indexOf(u8, native_bun_test_import_source, "import { test, expect } from \"bun:test\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_bun_test_import_source, "globalThis.__home_import(\"bun:test\")") == null);
    try std.testing.expectEqualStrings("native-esm-loader-missing", blocked_reason);
}

test "native bun:test ESM smoke documents bootstrap rewrite bridge" {
    const rewritten = try corpus_runner.rewriteBunTestImport(std.testing.allocator, native_bun_test_import_source, "native/bun-test-esm-smoke.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { test, expect } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "import { test, expect } from \"bun:test\";") == null);
}

test "native bun:test ESM smoke sees Bun-derived module loader bridge shape" {
    try std.testing.expect(@hasDecl(JSModuleLoader, "evaluate"));
    try std.testing.expect(@hasDecl(JSModuleLoader, "loadAndEvaluateModule"));
    try std.testing.expect(@hasDecl(JSModuleLoader, "import"));
}
