// Copied from bun/src/install/ConfigVersion.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"). The original
// `fromExpr(bun.ast.Expr)` constructor is omitted because `home_rt.ast` is
// not yet ported; callers should funnel through `fromInt` until the AST
// surface lands. `fromInt` matches upstream semantics byte-for-byte.

pub const ConfigVersion = enum {
    v0,
    v1,

    pub const current: ConfigVersion = .v1;

    pub fn fromInt(int: u64) ?ConfigVersion {
        return switch (int) {
            0 => .v0,
            1 => .v1,
            else => {
                if (int > @intFromEnum(current)) {
                    return current;
                }

                return null;
            },
        };
    }
};

test "ConfigVersion.fromInt maps known integers" {
    const std = @import("std");
    try std.testing.expectEqual(ConfigVersion.v0, ConfigVersion.fromInt(0).?);
    try std.testing.expectEqual(ConfigVersion.v1, ConfigVersion.fromInt(1).?);
}

test "ConfigVersion.fromInt clamps higher integers to current" {
    const std = @import("std");
    // Any integer strictly greater than @intFromEnum(current) returns `current`.
    try std.testing.expectEqual(ConfigVersion.current, ConfigVersion.fromInt(2).?);
    try std.testing.expectEqual(ConfigVersion.current, ConfigVersion.fromInt(99).?);
}

test "ConfigVersion.current points to the newest variant" {
    const std = @import("std");
    try std.testing.expectEqual(ConfigVersion.v1, ConfigVersion.current);
}
