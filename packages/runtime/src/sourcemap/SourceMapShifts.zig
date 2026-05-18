// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Extracted from the inline `pub const SourceMapShifts = struct { ... }` in
// upstream `sourcemap.zig` (line ~667). The parent aggregator is parked
// (MutableString / Logger / StringJoiner / URL / JSC pull-ins); this struct
// is pure data, so it lands on its own next to the already-ported
// `LineColumnOffset.zig`.
//
// Imports rewritten:
//   `@import("bun")` → relative `@import("LineColumnOffset.zig")`. The
//   parent `home_rt` aggregator only re-exports the sourcemap leaf enums
//   (SourceContentHandling / SourceMapLoadHint / SourceContent) and not
//   LineColumnOffset, so we reach the sibling file directly. This file
//   does NOT import `home_rt` to keep the per-file `zig build-obj` step
//   from seeing `LineColumnOffset.zig` once via `home_rt`'s test-imports
//   block and again via the relative path.

//! `SourceMapShifts` records a single `(before → after)` LineColumnOffset
//! delta used during second-pass source-map fix-up: when the bundler's
//! parallel chunk-printer rewrites mappings to be relative to the previous
//! chunk's end-state, it stores the shifts here so the VLQ "mappings"
//! stream can be patched without redecoding the entire payload.

const SourceMapShifts = @This();

before: LineColumnOffset,
after: LineColumnOffset,

const LineColumnOffset = @import("LineColumnOffset.zig");
const std = @import("std");

test "SourceMapShifts default is zero-initialized via LineColumnOffset.start" {
    const s = SourceMapShifts{ .before = .{}, .after = .{} };
    try std.testing.expectEqual(@as(i32, 0), s.before.lines.zeroBased());
    try std.testing.expectEqual(@as(i32, 0), s.before.columns.zeroBased());
    try std.testing.expectEqual(@as(i32, 0), s.after.lines.zeroBased());
    try std.testing.expectEqual(@as(i32, 0), s.after.columns.zeroBased());
}

test "SourceMapShifts records a before→after column delta" {
    const before: LineColumnOffset = .{ .lines = @enumFromInt(1), .columns = @enumFromInt(4) };
    const after: LineColumnOffset = .{ .lines = @enumFromInt(1), .columns = @enumFromInt(10) };
    const s = SourceMapShifts{ .before = before, .after = after };
    try std.testing.expectEqual(@as(i32, 1), s.before.lines.zeroBased());
    try std.testing.expectEqual(@as(i32, 4), s.before.columns.zeroBased());
    try std.testing.expectEqual(@as(i32, 10), s.after.columns.zeroBased());
    try std.testing.expectEqual(@as(i32, 6), s.after.columns.zeroBased() - s.before.columns.zeroBased());
}

test "SourceMapShifts layout is two LineColumnOffsets back-to-back" {
    try std.testing.expectEqual(2 * @sizeOf(LineColumnOffset), @sizeOf(SourceMapShifts));
}
