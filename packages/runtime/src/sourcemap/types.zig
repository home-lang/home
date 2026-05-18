// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from the inline declarations in upstream `sourcemap.zig` (that
// aggregator is parked because it transitively pulls in MutableString /
// Logger / StringJoiner / URL / Ordinal / JSC). These three types are
// dependency-free leaf enums/structs.

//! Loader hint enums and source-content payload shared by the broader
//! source-map machinery. The full loader (parseUrl / parseJSON / the
//! getSourceMap multiplexer) re-attaches once Logger + MutableString +
//! ParsedSourceMap port — these tag types can land independently because
//! they are pure data.

/// For some sourcemap loading code, this enum is used as a hint if it should
/// bother loading source code into memory. Most uses of source maps only care
/// about filenames and source mappings, and we should avoid loading contents
/// whenever possible.
pub const SourceContentHandling = enum(u1) {
    no_source_contents,
    source_contents,
};

/// For some sourcemap loading code, this enum is used as a hint if we already
/// know if the sourcemap is located on disk or inline in the source code.
pub const SourceMapLoadHint = enum(u2) {
    none,
    is_inline_map,
    is_external_map,
};

pub const SourceContent = struct {
    value: []const u16 = &[_]u16{},
    quoted: []const u8 = &[_]u8{},
};

test "SourceContentHandling default tag values match upstream layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u1, 0), @intFromEnum(SourceContentHandling.no_source_contents));
    try std.testing.expectEqual(@as(u1, 1), @intFromEnum(SourceContentHandling.source_contents));
}

test "SourceMapLoadHint default tag values match upstream layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(SourceMapLoadHint.none));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(SourceMapLoadHint.is_inline_map));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(SourceMapLoadHint.is_external_map));
}

test "SourceContent default is empty" {
    const std = @import("std");
    const sc: SourceContent = .{};
    try std.testing.expectEqual(@as(usize, 0), sc.value.len);
    try std.testing.expectEqual(@as(usize, 0), sc.quoted.len);
}
