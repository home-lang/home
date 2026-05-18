// Copied from bun/src/install/install.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from `install.zig` (`Features` struct + its named presets) so
// dependency parsing leaves can reference it without dragging in the full
// PackageManager. Pure Zig — `Behavior` is brought in from the sibling
// `./Behavior.zig` extraction. The original upstream file declares `Features`
// before `Behavior` and `Behavior.isEnabled(features)` closes the cycle.

const Behavior = @import("Behavior.zig").Behavior;

/// Which dependency *categories* the current install pass should treat as
/// active. A `Behavior` (read off each dependency) is matched against a
/// `Features` to decide whether the dependency should be resolved/installed
/// — see `Behavior.isEnabled`.
pub const Features = struct {
    dependencies: bool = true,
    dev_dependencies: bool = false,
    is_main: bool = false,
    optional_dependencies: bool = false,
    peer_dependencies: bool = true,
    trusted_dependencies: bool = false,
    workspaces: bool = false,
    patched_dependencies: bool = false,

    check_for_duplicate_dependencies: bool = false,

    /// Bit-pack the relevant booleans into a `Behavior` mask. Used to
    /// pre-compute "what could a matching dep look like" lookups.
    pub fn behavior(this: Features) Behavior {
        var out: u8 = 0;
        out |= @as(u8, @intFromBool(this.dependencies)) << 1;
        out |= @as(u8, @intFromBool(this.optional_dependencies)) << 2;
        out |= @as(u8, @intFromBool(this.dev_dependencies)) << 3;
        out |= @as(u8, @intFromBool(this.peer_dependencies)) << 4;
        out |= @as(u8, @intFromBool(this.workspaces)) << 5;
        return @as(Behavior, @bitCast(out));
    }

    pub const main = Features{
        .check_for_duplicate_dependencies = true,
        .dev_dependencies = true,
        .is_main = true,
        .optional_dependencies = true,
        .trusted_dependencies = true,
        .patched_dependencies = true,
        .workspaces = true,
    };

    pub const folder = Features{
        .dev_dependencies = true,
        .optional_dependencies = true,
    };

    pub const workspace = Features{
        .dev_dependencies = true,
        .optional_dependencies = true,
        .trusted_dependencies = true,
    };

    pub const link = Features{
        .dependencies = false,
        .peer_dependencies = false,
    };

    pub const npm = Features{
        .optional_dependencies = true,
    };

    pub const tarball = npm;

    pub const npm_manifest = Features{
        .optional_dependencies = true,
    };
};

test "Features.main enables every dependency category" {
    const std = @import("std");
    const m = Features.main;
    try std.testing.expect(m.dependencies);
    try std.testing.expect(m.dev_dependencies);
    try std.testing.expect(m.optional_dependencies);
    try std.testing.expect(m.peer_dependencies);
    try std.testing.expect(m.workspaces);
    try std.testing.expect(m.trusted_dependencies);
    try std.testing.expect(m.patched_dependencies);
    try std.testing.expect(m.is_main);
    try std.testing.expect(m.check_for_duplicate_dependencies);
}

test "Features.link disables prod + peer deps" {
    const std = @import("std");
    const l = Features.link;
    try std.testing.expect(!l.dependencies);
    try std.testing.expect(!l.peer_dependencies);
}

test "Features.tarball is an alias of Features.npm" {
    const std = @import("std");
    try std.testing.expectEqualDeep(Features.npm, Features.tarball);
}

test "Features.behavior packs the right bits" {
    const std = @import("std");
    const all_on = Features{
        .dependencies = true,
        .optional_dependencies = true,
        .dev_dependencies = true,
        .peer_dependencies = true,
        .workspaces = true,
    };
    const beh: u8 = @bitCast(all_on.behavior());
    // bits 1..5 set, bit 0 and 6/7 clear
    try std.testing.expectEqual(@as(u8, (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)), beh);
}
