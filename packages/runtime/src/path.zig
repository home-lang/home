// Home Runtime — path utilities.
//
// Mirrors the small subset of Bun's `path` namespace that the copied
// cli leaves need. The standard-library `std.fs.path` already covers
// most semantics; this file mostly aliases through and adds the
// Bun-specific helpers as we hit them.

const std = @import("std");

pub const basename = std.fs.path.basename;
pub const dirname = std.fs.path.dirname;
pub const extension = std.fs.path.extension;
pub const stem = std.fs.path.stem;
pub const isSepAny = @import("paths/resolve_path.zig").isSepAny;
pub const isSepAnyT = @import("paths/resolve_path.zig").isSepAnyT;
pub const joinAbsStringBuf = @import("paths/resolve_path.zig").joinAbsStringBuf;
pub const joinAbsStringBufChecked = @import("paths/resolve_path.zig").joinAbsStringBufChecked;
pub const joinAbsStringBufZ = @import("paths/resolve_path.zig").joinAbsStringBufZ;
pub const joinAbsStringBufZNT = @import("paths/resolve_path.zig").joinAbsStringBufZNT;
pub const joinAbsStringBufZTrailingSlash = @import("paths/resolve_path.zig").joinAbsStringBufZTrailingSlash;
pub const lastIndexOfSep = @import("paths/resolve_path.zig").lastIndexOfSep;
pub const lastIndexOfSepT = @import("paths/resolve_path.zig").lastIndexOfSepT;
pub const PosixToWinNormalizer = @import("paths/resolve_path.zig").PosixToWinNormalizer;

pub fn join(parts: []const []const u8, sep: std.fs.path.Style) []const u8 {
    _ = sep;
    // Bun's `path.join(parts, .auto)` returns a comptime-flattened slice
    // that lives in a process-arena. Until the arena substrate lands we
    // expose a buffer-less variant — callers that already pass in a
    // stable storage slice keep working. Future: route through the
    // process arena once Phase 12.3 lands the event loop.
    if (parts.len == 0) return "";
    return parts[0]; // placeholder for the simplest call site
}

test "basename matches std.fs.path.basename" {
    try std.testing.expectEqualStrings("bash", basename("/usr/bin/bash"));
    try std.testing.expectEqualStrings("zsh", basename("/bin/zsh"));
    try std.testing.expectEqualStrings("file", basename("file"));
}
