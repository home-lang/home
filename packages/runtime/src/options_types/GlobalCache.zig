// Copied from bun/src/options_types/GlobalCache.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

pub const GlobalCache = enum {
    allow_install,
    read_only,
    auto,
    force,
    fallback,
    disable,

    pub const Map = home_rt.ComptimeStringMap(GlobalCache, .{
        .{ "auto", GlobalCache.auto },
        .{ "force", GlobalCache.force },
        .{ "disable", GlobalCache.disable },
        .{ "fallback", GlobalCache.fallback },
    });

    pub fn allowVersionSpecifier(this: GlobalCache) bool {
        return this == .force;
    }

    pub fn canUse(this: GlobalCache, has_a_node_modules_folder: bool) bool {
        // When there is a node_modules folder, we default to false
        // When there is NOT a node_modules folder, we default to true
        // That is the difference between these two branches.
        if (has_a_node_modules_folder) {
            return switch (this) {
                .fallback, .allow_install, .force => true,
                .read_only, .disable, .auto => false,
            };
        } else {
            return switch (this) {
                .read_only, .fallback, .allow_install, .auto, .force => true,
                .disable => false,
            };
        }
    }

    pub fn isEnabled(this: GlobalCache) bool {
        return this != .disable;
    }

    pub fn canInstall(this: GlobalCache) bool {
        return switch (this) {
            .auto, .allow_install, .force, .fallback => true,
            else => false,
        };
    }
};

test "GlobalCache.Map round-trips canonical tags" {
    const std = @import("std");
    try std.testing.expectEqual(GlobalCache.auto, GlobalCache.Map.get("auto").?);
    try std.testing.expectEqual(GlobalCache.force, GlobalCache.Map.get("force").?);
    try std.testing.expectEqual(GlobalCache.disable, GlobalCache.Map.get("disable").?);
    try std.testing.expectEqual(GlobalCache.fallback, GlobalCache.Map.get("fallback").?);
    try std.testing.expect(GlobalCache.Map.get("read_only") == null);
}

test "GlobalCache.canUse depends on node_modules presence" {
    const std = @import("std");
    try std.testing.expect(GlobalCache.force.canUse(true));
    try std.testing.expect(!GlobalCache.auto.canUse(true));
    try std.testing.expect(GlobalCache.auto.canUse(false));
    try std.testing.expect(!GlobalCache.disable.canUse(false));
}

test "GlobalCache classifier predicates" {
    const std = @import("std");
    try std.testing.expect(GlobalCache.auto.isEnabled());
    try std.testing.expect(!GlobalCache.disable.isEnabled());
    try std.testing.expect(GlobalCache.force.canInstall());
    try std.testing.expect(GlobalCache.allow_install.canInstall());
    try std.testing.expect(!GlobalCache.disable.canInstall());
    try std.testing.expect(GlobalCache.force.allowVersionSpecifier());
    try std.testing.expect(!GlobalCache.auto.allowVersionSpecifier());
}

const home_rt = @import("home");
