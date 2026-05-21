// Copied from bun/src/runtime/cli/list-of-yarn-commands.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../../cli/LICENSE.bun.md.

pub const all_yarn_commands = home_rt.ComptimeStringMap(void, .{
    // yarn v2.3 commands
    .{"add"},
    .{"bin"},
    .{"cache"},
    .{"config"},
    .{"dedupe"},
    .{"dlx"},
    .{"exec"},
    .{"explain"},
    .{"info"},
    .{"init"},
    .{"install"},
    .{"link"},
    .{"node"},
    .{"npm"},
    .{"pack"},
    .{"patch"},
    .{"plugin"},
    .{"rebuild"},
    .{"remove"},
    .{"run"},
    .{"set"},
    .{"unplug"},
    .{"up"},
    .{"why"},
    .{"workspace"},
    .{"workspaces"},

    // yarn v1 commands
    .{"access"},
    .{"add"},
    .{"audit"},
    .{"autoclean"},
    .{"bin"},
    .{"cache"},
    .{"check"},
    .{"config"},
    .{"create"},
    .{"exec"},
    .{"generate-lock-entry"},
    .{"generateLockEntry"},
    .{"global"},
    .{"help"},
    .{"import"},
    .{"info"},
    .{"init"},
    .{"install"},
    .{"licenses"},
    .{"link"},
    .{"list"},
    .{"login"},
    .{"logout"},
    .{"node"},
    .{"outdated"},
    .{"owner"},
    .{"pack"},
    .{"policies"},
    .{"publish"},
    .{"remove"},
    .{"run"},
    .{"tag"},
    .{"team"},
    .{"unlink"},
    .{"unplug"},
    .{"upgrade"},
    .{"upgrade-interactive"},
    .{"upgradeInteractive"},
    .{"version"},
    .{"versions"},
    .{"why"},
    .{"workspace"},
    .{"workspaces"},
});

const home_rt = @import("home_rt");

test "runtime cli yarn command table recognizes yarn v1 and v2 commands" {
    const std = @import("std");

    try std.testing.expect(all_yarn_commands.has("add"));
    try std.testing.expect(all_yarn_commands.has("dlx"));
    try std.testing.expect(all_yarn_commands.has("upgrade-interactive"));
    try std.testing.expect(all_yarn_commands.has("generateLockEntry"));
    try std.testing.expect(!all_yarn_commands.has("definitely-not-yarn"));
}
