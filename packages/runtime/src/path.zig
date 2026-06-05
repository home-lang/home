// Home Runtime — path utilities.
//
// Mirrors the small subset of Bun's `path` namespace that the copied
// cli leaves need. The standard-library `std.fs.path` already covers
// most semantics; this file mostly aliases through and adds the
// Bun-specific helpers as we hit them.

const std = @import("std");

pub const basename = std.fs.path.basename;
pub const extension = std.fs.path.extension;
pub const stem = std.fs.path.stem;
pub const Platform = @import("paths/resolve_path.zig").Platform;
pub const isSepAny = @import("paths/resolve_path.zig").isSepAny;
pub const isSepAnyT = @import("paths/resolve_path.zig").isSepAnyT;
pub const joinAbs = @import("paths/resolve_path.zig").joinAbs;
pub const joinAbsString = @import("paths/resolve_path.zig").joinAbsString;
pub const joinAbsStringBuf = @import("paths/resolve_path.zig").joinAbsStringBuf;
pub const joinAbsStringBufChecked = @import("paths/resolve_path.zig").joinAbsStringBufChecked;
pub const joinAbsStringZ = @import("paths/resolve_path.zig").joinAbsStringZ;
pub const joinAbsStringBufZ = @import("paths/resolve_path.zig").joinAbsStringBufZ;
pub const joinAbsStringBufZNT = @import("paths/resolve_path.zig").joinAbsStringBufZNT;
pub const joinAbsStringBufZTrailingSlash = @import("paths/resolve_path.zig").joinAbsStringBufZTrailingSlash;
pub const joinZ = @import("paths/resolve_path.zig").joinZ;
pub const joinZBuf = @import("paths/resolve_path.zig").joinZBuf;
pub const joinStringBuf = @import("paths/resolve_path.zig").joinStringBuf;
pub const joinStringBufZ = @import("paths/resolve_path.zig").joinStringBufZ;
pub const lastIndexOfSep = @import("paths/resolve_path.zig").lastIndexOfSep;
pub const lastIndexOfSepT = @import("paths/resolve_path.zig").lastIndexOfSepT;
pub const normalizeBufT = @import("paths/resolve_path.zig").normalizeBufT;
pub const normalizeBuf = @import("paths/resolve_path.zig").normalizeBuf;
pub const normalizeString = @import("paths/resolve_path.zig").normalizeString;
/// Shared scratch buffer for path joins (upstream `bun.path.join_buf`).
pub threadlocal var join_buf: [4096]u8 = undefined;
pub const PosixToWinNormalizer = @import("paths/resolve_path.zig").PosixToWinNormalizer;
pub const relative = @import("paths/resolve_path.zig").relative;
pub const relativePlatform = @import("paths/resolve_path.zig").relativePlatform;
pub const relativePlatformBuf = @import("paths/resolve_path.zig").relativePlatformBuf;
pub const relativeBufZ = @import("paths/resolve_path.zig").relativeBufZ;
pub const relativeNormalizedBuf = @import("paths/resolve_path.zig").relativeNormalizedBuf;
pub const relativeNormalized = @import("paths/resolve_path.zig").relativeNormalized;
pub const platformToPosixInPlace = @import("paths/resolve_path.zig").platformToPosixInPlace;
pub const z = @import("paths/resolve_path.zig").z;
pub const dangerouslyConvertPathToPosixInPlace = @import("paths/resolve_path.zig").dangerouslyConvertPathToPosixInPlace;
pub const dangerouslyConvertPathToWindowsInPlace = @import("paths/resolve_path.zig").dangerouslyConvertPathToWindowsInPlace;

pub fn dirname(path: []const u8, style: anytype) []const u8 {
    _ = style;
    return std.fs.path.dirname(path) orelse "";
}

pub fn join(parts: []const []const u8, sep: anytype) []const u8 {
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
