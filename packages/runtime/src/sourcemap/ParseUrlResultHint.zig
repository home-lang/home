// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Extracted from the inline `pub const ParseUrlResultHint = union(enum)` in
// upstream `sourcemap.zig` (line ~26). The parent aggregator is parked
// (MutableString / Logger / StringJoiner / URL / JSC pull-ins); this tagged
// union is pure data and lands on its own so callers (`parseUrl` /
// `parseJSON` / source provider `getSourceMap`) can refer to it before
// the heavy machinery re-attaches.
//
// Imports rewritten: this file has no `bun.*` dependencies — only std.

//! `ParseUrlResultHint` tells the source-map loader how much work to do
//! when decoding an inline `data:application/json...` URL or external
//! source map. The loader can skip materializing the full mapping table
//! when only source contents are needed, or skip source contents when
//! only the line/column mapping is needed.

pub const ParseUrlResultHint = union(enum) {
    mappings_only,
    /// Source Index to fetch
    source_only: u32,
    /// In order to fetch source contents, you need to know the
    /// index, but you cant know the index until the mappings
    /// are loaded. So pass in line+col.
    all: struct {
        line: i32,
        column: i32,
        include_names: bool = false,
    },
};

const std = @import("std");

test "ParseUrlResultHint tag values" {
    const h1: ParseUrlResultHint = .mappings_only;
    try std.testing.expect(h1 == .mappings_only);

    const h2: ParseUrlResultHint = .{ .source_only = 42 };
    try std.testing.expect(h2 == .source_only);
    try std.testing.expectEqual(@as(u32, 42), h2.source_only);

    const h3: ParseUrlResultHint = .{ .all = .{ .line = 10, .column = 7 } };
    try std.testing.expect(h3 == .all);
    try std.testing.expectEqual(@as(i32, 10), h3.all.line);
    try std.testing.expectEqual(@as(i32, 7), h3.all.column);
    try std.testing.expectEqual(false, h3.all.include_names);
}

test "ParseUrlResultHint all.include_names defaults to false" {
    const h: ParseUrlResultHint = .{ .all = .{ .line = 0, .column = 0 } };
    try std.testing.expectEqual(false, h.all.include_names);
}

test "ParseUrlResultHint all.include_names can be set to true" {
    const h: ParseUrlResultHint = .{ .all = .{ .line = 0, .column = 0, .include_names = true } };
    try std.testing.expectEqual(true, h.all.include_names);
}
