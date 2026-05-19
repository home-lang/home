// Wave-26 port (2026-05-19). Copied from
// bun/src/runtime/cli/which_npm_client.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../cli/LICENSE.bun.md.
//
// Pure descriptor for the result of `which-npm-client` detection.
// Imports rewritten: the upstream `@import("bun")` was unused (no
// references to `bun.*` in the file body) and is dropped.

pub const NPMClient = struct {
    bin: string,
    tag: Tag,

    pub const Tag = enum {
        bun,
    };
};

const string = []const u8;

test "NPMClient defaults to .bun tag" {
    const std = @import("std");
    const c: NPMClient = .{ .bin = "bun", .tag = .bun };
    try std.testing.expectEqualStrings("bun", c.bin);
    try std.testing.expectEqual(NPMClient.Tag.bun, c.tag);
}
