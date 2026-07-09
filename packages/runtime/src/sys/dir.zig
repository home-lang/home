// Copied from bun/src/sys/dir.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Tiny wrapper struct that pairs an open directory file descriptor with the
// rest of the `sys` namespace. FD is opaque-stubbed until `sys/fd.zig` ports.

pub const Dir = struct {
    fd: FD,
};

/// stubbed: re-attaches when sys/fd.zig lands. Real FD is a packed struct
/// over `c_int` (POSIX) / `u64` (Windows); we use a `u64` placeholder so the
/// outer `Dir` has a stable size until the real type ports.
const FD = u64;

test "Dir struct carries an FD field" {
    const std = @import("std");
    // Compile-time structural check — we can't construct an opaque FD value,
    // but the field name + type must exist so downstream callers compile.
    const info = @typeInfo(Dir).@"struct";
    try std.testing.expectEqual(@as(usize, 1), info.field_names.len);
    try std.testing.expectEqualStrings("fd", info.field_names[0]);
}
