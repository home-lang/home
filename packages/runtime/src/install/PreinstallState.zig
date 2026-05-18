// Copied from bun/src/install/install.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from `install.zig` (the upstream `PreinstallState` enum) so the
// install state machine can be referenced without depending on the full
// PackageManager. Pure Zig — no `@import("bun")` rewrite needed.

/// State of a package as it moves through extraction, patching, and the
/// `preinstall` lifecycle. Stored per-package by `PackageManager`.
///
/// Order matters: `done` is the terminal state, and the `*ing` variants
/// indicate work in flight (used to dedupe scheduling). The u4 backing type
/// matches upstream (and the `bun.lock` text encoding's nibble budget).
pub const PreinstallState = enum(u4) {
    unknown = 0,
    done,
    extract,
    extracting,
    calc_patch_hash,
    calcing_patch_hash,
    apply_patch,
    applying_patch,
};

test "PreinstallState fits in a u4" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 4), @bitSizeOf(PreinstallState));
}

test "PreinstallState ordering matches the upstream lifecycle" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u4, 0), @intFromEnum(PreinstallState.unknown));
    try std.testing.expectEqual(@as(u4, 1), @intFromEnum(PreinstallState.done));
    try std.testing.expectEqual(@as(u4, 2), @intFromEnum(PreinstallState.extract));
    try std.testing.expectEqual(@as(u4, 3), @intFromEnum(PreinstallState.extracting));
    try std.testing.expectEqual(@as(u4, 4), @intFromEnum(PreinstallState.calc_patch_hash));
    try std.testing.expectEqual(@as(u4, 5), @intFromEnum(PreinstallState.calcing_patch_hash));
    try std.testing.expectEqual(@as(u4, 6), @intFromEnum(PreinstallState.apply_patch));
    try std.testing.expectEqual(@as(u4, 7), @intFromEnum(PreinstallState.applying_patch));
}
