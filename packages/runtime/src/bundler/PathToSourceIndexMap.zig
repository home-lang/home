// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/bundler/PathToSourceIndexMap.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - `@import("bun")`              -> `@import("home_rt")`
//   - `bun.OOM`                     -> `home_rt.OOM`
//   - `bun.ast.Index`               -> `home_rt.ast.Index`
//   - `bun.StringHashMapUnmanaged`  -> local `StringHashMapUnmanaged` alias
//     mirroring upstream's flat `std.HashMapUnmanaged([]const u8, V,
//     std.hash_map.StringContext, std.hash_map.default_max_load_percentage)`
//     (upstream's `bun.zig` line 1128).
//
// **Symbol-dependent surface dropped**: upstream's `getPath`/`putPath`/
// `getOrPutPath`/`removePath` helpers each unwrap a `bun.fs.Path` (= the
// resolver's `Path` struct in `src/resolver/fs.zig`). The resolver tree
// hasn't been ported yet, so we drop those four wrappers and keep only the
// `text`-based core (which is what they delegate to anyway). They
// re-attach trivially once `home_rt.fs.Path` lands.

const PathToSourceIndexMap = @This();

/// The lifetime of the keys are not owned by this map.
///
/// We assume it's arena allocated.
map: Map = .{},

const Map = StringHashMapUnmanaged(Index.Int);

pub fn get(this: *const PathToSourceIndexMap, text: []const u8) ?Index.Int {
    return this.map.get(text);
}

pub fn put(this: *PathToSourceIndexMap, allocator: std.mem.Allocator, text: []const u8, value: Index.Int) home_rt.OOM!void {
    try this.map.put(allocator, text, value);
}

pub fn getOrPut(this: *PathToSourceIndexMap, allocator: std.mem.Allocator, text: []const u8) home_rt.OOM!Map.GetOrPutResult {
    return try this.map.getOrPut(allocator, text);
}

pub fn remove(this: *PathToSourceIndexMap, text: []const u8) bool {
    return this.map.remove(text);
}

/// Mirrors `bun.StringHashMapUnmanaged` in `bun.zig` (line 1128) —
/// `std.HashMapUnmanaged([]const u8, V, ..., default_max_load_percentage)`
/// with the canonical `StringContext`.
fn StringHashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged(
        []const u8,
        V,
        std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
    );
}

const std = @import("std");

const home_rt = @import("home_rt");
const Index = home_rt.ast.Index;

test "PathToSourceIndexMap: put + get round-trip" {
    const allocator = std.testing.allocator;
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(allocator);

    try m.put(allocator, "src/index.ts", 7);
    try m.put(allocator, "src/foo.ts", 42);

    try std.testing.expectEqual(@as(?Index.Int, 7), m.get("src/index.ts"));
    try std.testing.expectEqual(@as(?Index.Int, 42), m.get("src/foo.ts"));
    try std.testing.expect(m.get("does/not/exist.ts") == null);
}

test "PathToSourceIndexMap: getOrPut finds existing + inserts new" {
    const allocator = std.testing.allocator;
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(allocator);

    try m.put(allocator, "a.ts", 1);

    const r1 = try m.getOrPut(allocator, "a.ts");
    try std.testing.expect(r1.found_existing);
    try std.testing.expectEqual(@as(Index.Int, 1), r1.value_ptr.*);

    const r2 = try m.getOrPut(allocator, "b.ts");
    try std.testing.expect(!r2.found_existing);
    r2.value_ptr.* = 2;
    try std.testing.expectEqual(@as(?Index.Int, 2), m.get("b.ts"));
}

test "PathToSourceIndexMap: remove drops the entry" {
    const allocator = std.testing.allocator;
    var m: PathToSourceIndexMap = .{};
    defer m.map.deinit(allocator);

    try m.put(allocator, "drop.me", 99);
    try std.testing.expect(m.remove("drop.me"));
    try std.testing.expect(m.get("drop.me") == null);
    try std.testing.expect(!m.remove("never-there"));
}
