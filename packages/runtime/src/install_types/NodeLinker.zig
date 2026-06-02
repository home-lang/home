// Copied from bun/src/install_types/NodeLinker.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

//! Extracted from `install/PackageManager/PackageManagerOptions.zig` so
//! `options_types/schema.zig`, `cli/bunfig.zig`, and `ini/` can name the
//! linker mode without depending on the full package manager.
pub const NodeLinker = enum(u8) {
    // If workspaces are used: isolated
    // If not: hoisted
    // Used when nodeLinker is absent from package.json/bun.lock/bun.lockb
    auto,

    hoisted,
    isolated,

    pub fn fromStr(input: []const u8) ?NodeLinker {
        if (strings.eqlComptime(input, "hoisted")) {
            return .hoisted;
        }
        if (strings.eqlComptime(input, "isolated")) {
            return .isolated;
        }
        return null;
    }
};

test "NodeLinker.fromStr maps canonical strings" {
    const std = @import("std");
    try std.testing.expectEqual(NodeLinker.hoisted, NodeLinker.fromStr("hoisted").?);
    try std.testing.expectEqual(NodeLinker.isolated, NodeLinker.fromStr("isolated").?);
    try std.testing.expect(NodeLinker.fromStr("auto") == null);
    try std.testing.expect(NodeLinker.fromStr("nope") == null);
}

const home_rt = @import("home");
const strings = home_rt.strings;
