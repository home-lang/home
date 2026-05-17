// Home Runtime aggregator.
//
// This module is the single import surface used by every other Home Runtime
// subsystem. Copied-from-Bun source files have their `@import("bun")` calls
// rewritten to `@import("home_rt")` at copy time, so this aggregator is the
// canonical replacement for Bun's `bun.zig` namespace inside Home.
//
// Each sub-phase appends its public surface here as the matching directory
// under `src/` is populated. Phase 12 status + per-file porting tables live
// in the subdirectory `PORTING_STATUS.md` files.

const std = @import("std");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";

// ---- src/cli/ ----------------------------------------------------------
// Bun's CLI surface. Copy-in-progress; see src/cli/PORTING_STATUS.md.
pub const cli = struct {
    pub const which_npm_client = @import("cli/which_npm_client.zig");
};

test "home_rt: substrate compiles" {
    try std.testing.expectEqualStrings(
        "fd0b6f1a271fca0b8124b69f230b100f4d636af6",
        upstream_sha,
    );
}

test "home_rt: cli.which_npm_client surface is exported" {
    const NPMClient = cli.which_npm_client.NPMClient;
    const c: NPMClient = .{ .bin = "home", .tag = .home };
    try std.testing.expectEqualStrings("home", c.bin);
    try std.testing.expect(c.tag == .home);
}
