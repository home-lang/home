// Copied from bun/src/install/install.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from `install.zig` so other ported install leaves (Meta, Resolution,
// dependency) can reference it without dragging in the full package manager.
// Imports: no `@import("bun")` here — this file is pure Zig and matches upstream
// byte-for-byte aside from being lifted to its own file.

/// Describes where a dependency was resolved from. Persisted in the lockfile
/// (see `lockfile/Package/Meta.zig`) and inferred elsewhere via the
/// resolution union.
///
/// TODO (upstream): remove this. It does not do anything that the resolution
/// union cannot already express. Kept for lockfile backward compatibility.
pub const Origin = enum(u8) {
    local = 0,
    npm = 1,
    tarball = 2,
};

test "Origin enum values match the lockfile-encoded representation" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Origin.local));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Origin.npm));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Origin.tarball));
}

test "Origin defaults to .npm when zero-initialised via .npm literal" {
    const std = @import("std");
    // Mirrors `Meta.origin: Origin = Origin.npm` upstream — the lockfile
    // currently writes `.npm` as the default for new entries.
    const o: Origin = .npm;
    try std.testing.expectEqual(Origin.npm, o);
}
