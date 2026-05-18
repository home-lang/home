// Copied from bun/src/css/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("./css_parser.zig") and @import("./values/values.zig")
// dropped — neither was used internally; the file only re-exported
// `Error = css.Error` (also unused). Every struct below is pure data, so the
// upstream dependencies fall away cleanly. When css_parser.zig lands, the
// `Error` alias can be reinstated without rippling into callers.

pub const SourceMap = struct {
    project_root: []const u8,
    inner: SourceMapInner,
};

pub const SourceMapInner = struct {
    sources: ArrayList([]const u8),
    sources_content: ArrayList([]const u8),
    names: ArrayList([]const u8),
    mapping_lines: ArrayList(MappingLine),
};

pub const MappingLine = struct { mappings: ArrayList(LineMapping), last_column: u32, is_sorted: bool };

pub const LineMapping = struct { generated_column: u32, original: ?OriginalLocation };

pub const OriginalLocation = struct {
    original_line: u32,
    original_column: u32,
    source: u32,
    name: ?u32,
};

test "SourceMap holds project root and inner struct" {
    const empty: SourceMapInner = .{
        .sources = .empty,
        .sources_content = .empty,
        .names = .empty,
        .mapping_lines = .empty,
    };
    const sm: SourceMap = .{ .project_root = "/tmp/proj", .inner = empty };
    try std.testing.expectEqualStrings("/tmp/proj", sm.project_root);
    try std.testing.expectEqual(@as(usize, 0), sm.inner.sources.items.len);
}

test "LineMapping carries optional original location" {
    const orig: OriginalLocation = .{
        .original_line = 12,
        .original_column = 4,
        .source = 0,
        .name = null,
    };
    const lm: LineMapping = .{ .generated_column = 9, .original = orig };
    try std.testing.expectEqual(@as(u32, 9), lm.generated_column);
    try std.testing.expectEqual(@as(u32, 12), lm.original.?.original_line);
    try std.testing.expect(lm.original.?.name == null);
}

test "MappingLine starts empty and unsorted" {
    const ml: MappingLine = .{
        .mappings = .empty,
        .last_column = 0,
        .is_sorted = false,
    };
    try std.testing.expectEqual(@as(u32, 0), ml.last_column);
    try std.testing.expect(!ml.is_sorted);
}

const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
