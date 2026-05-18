// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from the inline `pub const SourceMapState = struct { ... }` in
// upstream sourcemap.zig — that file is parked because it transitively pulls in
// MutableString / Logger / StringJoiner / URL / Ordinal / JSC. This struct is
// pure data with no `bun.*` dependencies, so the bundler's `Builder` (in
// `Chunk.zig`) and `appendMappingToBuffer` can name it once those re-attach.

//! Coordinates in source maps are stored using relative offsets for size
//! reasons. When joining together chunks of a source map that were emitted
//! in parallel for different parts of a file, we need to fix up the first
//! segment of each chunk to be relative to the end of the previous chunk.

pub const SourceMapState = struct {
    /// This isn't stored in the source map. It's only used by the bundler to join
    /// source map chunks together correctly.
    generated_line: i32 = 0,

    /// These are stored in the source map in VLQ format.
    generated_column: i32 = 0,
    source_index: i32 = 0,
    original_line: i32 = 0,
    original_column: i32 = 0,
};

test "SourceMapState default is all-zero" {
    const std = @import("std");
    const s: SourceMapState = .{};
    try std.testing.expectEqual(@as(i32, 0), s.generated_line);
    try std.testing.expectEqual(@as(i32, 0), s.generated_column);
    try std.testing.expectEqual(@as(i32, 0), s.source_index);
    try std.testing.expectEqual(@as(i32, 0), s.original_line);
    try std.testing.expectEqual(@as(i32, 0), s.original_column);
}

test "SourceMapState fields are independently assignable" {
    const std = @import("std");
    var s: SourceMapState = .{
        .generated_line = 3,
        .generated_column = 17,
        .source_index = 2,
        .original_line = 4,
        .original_column = 8,
    };
    try std.testing.expectEqual(@as(i32, 3), s.generated_line);
    try std.testing.expectEqual(@as(i32, 17), s.generated_column);
    try std.testing.expectEqual(@as(i32, 2), s.source_index);
    try std.testing.expectEqual(@as(i32, 4), s.original_line);
    try std.testing.expectEqual(@as(i32, 8), s.original_column);
    s.generated_column = 99;
    try std.testing.expectEqual(@as(i32, 99), s.generated_column);
}
