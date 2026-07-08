// Home Runtime — path utilities.
//
// Mirrors the small subset of Bun's `path` namespace that the copied
// cli leaves need. The standard-library `std.fs.path` already covers
// most semantics; this file mostly aliases through and adds the
// Bun-specific helpers as we hit them.

const std = @import("std");

// `basename`/`dirname` delegate to resolve_path.zig — the same implementation
// upstream exposes as `bun.path.*`. std.fs.path.basename/dirname diverge from
// Bun (and POSIX coreutils) on the root and trailing-slash cases: e.g.
// basename("/") is "" in std but "/" in Bun, and std.fs.path.dirname ignores
// the platform argument every caller passes. This drove the shell
// basename/dirname builtins to emit "" instead of "/" for `basename /`.
pub const basename = @import("paths/resolve_path.zig").basename;
pub const dirname = @import("paths/resolve_path.zig").dirname;
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
pub const relativeNormalized = @import("paths/resolve_path.zig").relativeNormalized;
pub const relativeNormalizedBuf = @import("paths/resolve_path.zig").relativeNormalizedBuf;
pub const relativePlatform = @import("paths/resolve_path.zig").relativePlatform;
pub const relativePlatformBuf = @import("paths/resolve_path.zig").relativePlatformBuf;
pub const relativeBufZ = @import("paths/resolve_path.zig").relativeBufZ;
pub const pathToPosixBuf = @import("paths/resolve_path.zig").pathToPosixBuf;
pub const platformToPosixInPlace = @import("paths/resolve_path.zig").platformToPosixInPlace;
pub const z = @import("paths/resolve_path.zig").z;

pub fn dangerouslyConvertPathToPosixInPlace(comptime T: type, path: []T) []T {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

pub fn join(parts: []const []const u8, comptime sep: Platform) []const u8 {
    // Join + normalize into the thread-local `join_buf`, matching upstream
    // `bun.path.join`. The previous placeholder returned `parts[0]` and dropped
    // every other component, so e.g. `join("/a/b", "c/d.txt")` returned "/a/b" —
    // which broke recursive `readdirSync(dir, {withFileTypes:true, recursive:
    // true})` (every Dirent.parentPath collapsed to dirname(root)).
    return joinStringBuf(&join_buf, parts, sep);
}

pub fn relativeAlloc(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    return std.fs.path.relative(allocator, from, null, from, to);
}

test "basename matches Bun's bun.path.basename (resolve_path)" {
    try std.testing.expectEqualStrings("bash", basename("/usr/bin/bash"));
    try std.testing.expectEqualStrings("zsh", basename("/bin/zsh"));
    try std.testing.expectEqualStrings("file", basename("file"));
    // Root/trailing-slash cases where std.fs.path.basename diverges from Bun.
    try std.testing.expectEqualStrings("/", basename("/"));
}

test "dirname matches Bun's bun.path.dirname (resolve_path)" {
    try std.testing.expectEqualStrings("/usr/bin", dirname("/usr/bin/bash", .posix));
    try std.testing.expectEqualStrings("/", dirname("/", .posix));
    try std.testing.expectEqualStrings("a/b", dirname("a/b/c", .posix));
}
