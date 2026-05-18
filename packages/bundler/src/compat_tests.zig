//! Tier 0 `bun_compat` shim tests — Phase 4.5 §4.5.A.2.
//!
//! Exercises `IndexStringMap.zig` and `PathToSourceIndexMap.zig`
//! (verbatim copies of upstream Bun bundler files) against the
//! Tier 0 shim defined at `bun_compat/bun.zig`. The build wires
//! `@import("bun")` to the shim so the two vendored files compile
//! without modification.
//!
//! Subsequent tiers (`Graph.zig`, `bundled_ast.zig`, `BundleThread.zig`,
//! …) plug into this same test module as they come online.

const std = @import("std");
const T = std.testing;

const bun = @import("bun");
const IndexStringMap = @import("bun/IndexStringMap.zig");
const PathToSourceIndexMap = @import("bun/PathToSourceIndexMap.zig");

test "bun_compat: shim exposes Tier 0 surface" {
    // Type-level checks: each Tier 0 symbol must exist with the right
    // shape so future bundler files compile.
    try T.expectEqual(@as(type, error{OutOfMemory}), bun.OOM);
    bun.assert(true);
    try T.expectEqual(@as(type, u32), bun.ast.Index.Int);
    const path = bun.fs.Path{ .text = "/x.ts" };
    try T.expectEqualStrings("/x.ts", path.text);
    // Allocator surface — sanity-check that allocate-then-free works
    // against the re-exported default allocator.
    const slice = try bun.default_allocator.alloc(u8, 4);
    defer bun.default_allocator.free(slice);
    try T.expectEqual(@as(usize, 4), slice.len);
}

test "bun_compat: ast.Index.init wraps + reads u32" {
    const idx = bun.ast.Index.init(7);
    try T.expectEqual(@as(u32, 7), idx.value);
}

test "bun_compat: StringHashMapUnmanaged alias works" {
    var map: bun.StringHashMapUnmanaged(u32) = .{};
    defer map.deinit(T.allocator);
    try map.put(T.allocator, "a", 1);
    try map.put(T.allocator, "b", 2);
    try T.expectEqual(@as(?u32, 1), map.get("a"));
    try T.expectEqual(@as(?u32, 2), map.get("b"));
    try T.expectEqual(@as(?u32, null), map.get("c"));
}

test "bun_compat: IndexStringMap put + get round-trips through shim" {
    var m: IndexStringMap = .{};
    defer m.deinit(T.allocator);
    try m.put(T.allocator, 0, "alpha");
    try m.put(T.allocator, 1, "beta");
    try T.expectEqualStrings("alpha", m.get(0).?);
    try T.expectEqualStrings("beta", m.get(1).?);
    try T.expectEqual(@as(?[]const u8, null), m.get(99));
}

test "bun_compat: IndexStringMap dupes the value (caller string can be freed)" {
    var m: IndexStringMap = .{};
    defer m.deinit(T.allocator);
    // Heap-allocate a string, put it, then free it. The map must
    // still return a valid (duped) copy on get.
    const owned = try T.allocator.dupe(u8, "transient");
    try m.put(T.allocator, 5, owned);
    T.allocator.free(owned);
    try T.expectEqualStrings("transient", m.get(5).?);
}

test "bun_compat: PathToSourceIndexMap put + get by raw text" {
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(T.allocator);
    try m.put(T.allocator, "/foo.ts", 42);
    try m.put(T.allocator, "/bar.ts", 7);
    try T.expectEqual(@as(?u32, 42), m.get("/foo.ts"));
    try T.expectEqual(@as(?u32, 7), m.get("/bar.ts"));
    try T.expectEqual(@as(?u32, null), m.get("/missing.ts"));
}

test "bun_compat: PathToSourceIndexMap getPath / putPath through fs.Path" {
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(T.allocator);
    const a = bun.fs.Path{ .text = "/a.ts" };
    const b = bun.fs.Path{ .text = "/b.ts" };
    try m.putPath(T.allocator, &a, 100);
    try m.putPath(T.allocator, &b, 200);
    try T.expectEqual(@as(?u32, 100), m.getPath(&a));
    try T.expectEqual(@as(?u32, 200), m.getPath(&b));
}

test "bun_compat: PathToSourceIndexMap removePath returns true on hit" {
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(T.allocator);
    const p = bun.fs.Path{ .text = "/c.ts" };
    try m.putPath(T.allocator, &p, 1);
    try T.expect(m.removePath(&p));
    try T.expectEqual(@as(?u32, null), m.getPath(&p));
    // Removing again returns false (not present).
    try T.expect(!m.removePath(&p));
}

test "bun_compat: PathToSourceIndexMap getOrPut populates first call, retrieves second" {
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(T.allocator);
    const r1 = try m.getOrPut(T.allocator, "/d.ts");
    try T.expect(!r1.found_existing);
    r1.value_ptr.* = 9;
    const r2 = try m.getOrPut(T.allocator, "/d.ts");
    try T.expect(r2.found_existing);
    try T.expectEqual(@as(u32, 9), r2.value_ptr.*);
}
