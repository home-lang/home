// Copied from bun/src/install/dependency.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from `dependency.zig` (`pub const Behavior = packed struct(u8) { … }`)
// so other ported install leaves can reason about dependency *categories*
// without dragging in the full `Dependency` value. The original upstream
// file co-locates this with the `Dependency` extern struct; the rest of
// `dependency.zig` pulls in Semver/Repository/HostedGitInfo and can't move
// until those are ported.
// Imports rewritten: @import("bun") → @import("home_rt"); `bun.assert`
// becomes `home_rt.assert`. `Features` is brought in from the sibling
// `./Features.zig` extraction. The upstream `@Type(.enum_literal)` builtin
// spelling was removed in Zig 0.17-dev; `@TypeOf(.enum_literal)` is the
// 0.17 replacement and produces an identical type at use-sites.

const std = @import("std");
const home_rt = @import("home_rt");
const Features = @import("Features.zig").Features;

/// Bit-packed view of *which dependency categories a single dependency
/// belongs to*. Stored alongside each `Dependency` in the lockfile.
///
/// The unused bits (`_unused_1`, `_unused_2`) are present so that
/// `@as(u8, @bitCast(Behavior{ .prod = true })) == (1 << 1)` and likewise
/// for the other slots — the comptime assertions below pin those layout
/// expectations down. The empty slots leave room for future categories
/// without renumbering existing lockfiles.
pub const Behavior = packed struct(u8) {
    _unused_1: u1 = 0,
    prod: bool = false,
    optional: bool = false,
    dev: bool = false,
    peer: bool = false,
    workspace: bool = false,
    /// Is not set for transitive bundled dependencies
    bundled: bool = false,
    _unused_2: u1 = 0,

    pub inline fn isProd(this: Behavior) bool {
        return this.prod;
    }

    pub inline fn isOptional(this: Behavior) bool {
        return this.optional and !this.peer;
    }

    pub inline fn isOptionalPeer(this: Behavior) bool {
        return this.optional and this.peer;
    }

    pub inline fn isDev(this: Behavior) bool {
        return this.dev;
    }

    pub inline fn isPeer(this: Behavior) bool {
        return this.peer;
    }

    pub inline fn isWorkspace(this: Behavior) bool {
        return this.workspace;
    }

    pub inline fn isBundled(this: Behavior) bool {
        return this.bundled;
    }

    pub inline fn eq(lhs: Behavior, rhs: Behavior) bool {
        return @as(u8, @bitCast(lhs)) == @as(u8, @bitCast(rhs));
    }

    pub inline fn includes(lhs: Behavior, rhs: Behavior) bool {
        return @as(u8, @bitCast(lhs)) & @as(u8, @bitCast(rhs)) != 0;
    }

    pub inline fn add(this: Behavior, kind: @TypeOf(.enum_literal)) Behavior {
        var new = this;
        @field(new, @tagName(kind)) = true;
        return new;
    }

    pub inline fn set(this: Behavior, kind: @TypeOf(.enum_literal), value: bool) Behavior {
        var new = this;
        @field(new, @tagName(kind)) = value;
        return new;
    }

    /// Stable ordering used when sorting dependencies for lockfile output.
    /// Workspaces first, then dev, then optional, then prod, then peer.
    pub inline fn cmp(lhs: Behavior, rhs: Behavior) std.math.Order {
        if (eq(lhs, rhs)) {
            return .eq;
        }

        if (lhs.isWorkspace() != rhs.isWorkspace()) {
            return if (lhs.isWorkspace()) .lt else .gt;
        }

        if (lhs.isDev() != rhs.isDev()) {
            return if (lhs.isDev()) .lt else .gt;
        }

        if (lhs.isOptional() != rhs.isOptional()) {
            return if (lhs.isOptional()) .lt else .gt;
        }

        if (lhs.isProd() != rhs.isProd()) {
            return if (lhs.isProd()) .lt else .gt;
        }

        if (lhs.isPeer() != rhs.isPeer()) {
            return if (lhs.isPeer()) .lt else .gt;
        }

        return .eq;
    }

    pub inline fn isRequired(this: Behavior) bool {
        return !isOptional(this);
    }

    /// Returns true if this dependency category should be installed under
    /// the supplied `Features` mask. Prod dependencies are always enabled;
    /// every other category is gated on the corresponding flag.
    pub fn isEnabled(this: Behavior, features: Features) bool {
        return this.isProd() or
            (features.optional_dependencies and this.isOptional()) or
            (features.dev_dependencies and this.isDev()) or
            (features.peer_dependencies and this.isPeer()) or
            (features.workspaces and this.isWorkspace());
    }

    comptime {
        home_rt.assert(@as(u8, @bitCast(Behavior{ .prod = true })) == (1 << 1));
        home_rt.assert(@as(u8, @bitCast(Behavior{ .optional = true })) == (1 << 2));
        home_rt.assert(@as(u8, @bitCast(Behavior{ .dev = true })) == (1 << 3));
        home_rt.assert(@as(u8, @bitCast(Behavior{ .peer = true })) == (1 << 4));
        home_rt.assert(@as(u8, @bitCast(Behavior{ .workspace = true })) == (1 << 5));
    }
};

test "Behavior.eq compares the underlying byte" {
    const a = Behavior{ .prod = true };
    const b = Behavior{ .prod = true };
    const c = Behavior{ .dev = true };
    try std.testing.expect(Behavior.eq(a, b));
    try std.testing.expect(!Behavior.eq(a, c));
}

test "Behavior.isOptional excludes optional-peer" {
    const opt_only = Behavior{ .optional = true };
    const opt_peer = Behavior{ .optional = true, .peer = true };
    try std.testing.expect(opt_only.isOptional());
    try std.testing.expect(!opt_peer.isOptional());
    try std.testing.expect(opt_peer.isOptionalPeer());
}

test "Behavior.cmp puts workspaces first, peers last" {
    const ws = Behavior{ .workspace = true };
    const dev = Behavior{ .dev = true };
    const prod = Behavior{ .prod = true };
    const peer = Behavior{ .peer = true };

    try std.testing.expectEqual(std.math.Order.lt, Behavior.cmp(ws, dev));
    try std.testing.expectEqual(std.math.Order.lt, Behavior.cmp(dev, prod));
    try std.testing.expectEqual(std.math.Order.lt, Behavior.cmp(prod, peer));
}

test "Behavior.isEnabled gates by Features mask" {
    const dev = Behavior{ .dev = true };
    const optional = Behavior{ .optional = true };

    try std.testing.expect(!dev.isEnabled(Features.npm));
    try std.testing.expect(dev.isEnabled(Features.main));
    try std.testing.expect(optional.isEnabled(Features.npm));

    // prod is always enabled
    const prod = Behavior{ .prod = true };
    try std.testing.expect(prod.isEnabled(Features.link));
}

test "Behavior.includes is bitwise-AND non-zero" {
    const mixed = Behavior{ .prod = true, .dev = true };
    try std.testing.expect(mixed.includes(Behavior{ .prod = true }));
    try std.testing.expect(mixed.includes(Behavior{ .dev = true }));
    try std.testing.expect(!mixed.includes(Behavior{ .peer = true }));
}

test "Behavior.add sets one named flag" {
    const start = Behavior{ .prod = true };
    const with_dev = start.add(.dev);
    try std.testing.expect(with_dev.prod);
    try std.testing.expect(with_dev.dev);
}
