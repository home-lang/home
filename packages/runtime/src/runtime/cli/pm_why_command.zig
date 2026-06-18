// Copied from bun/src/runtime/cli/pm_why_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.cli.Command → home_rt.cli.Command
//   - bun.install.PackageManager → home_rt.install.PackageManager

pub const PmWhyCommand = struct {
    pub fn exec(ctx: Command.Context, pm: *PackageManager, positionals: []const string) !void {
        try WhyCommand.execFromPm(ctx, pm, positionals);
    }
};

const string = []const u8;

const home_rt = @import("home");
const std = @import("std");

const WhyCommand = @import("./why_command.zig").WhyCommand;
const Command = home_rt.cli.Command;
const PackageManager = home_rt.install.PackageManager;

test "PmWhyCommand exposes the upstream exec shape" {
    try std.testing.expect(@hasDecl(PmWhyCommand, "exec"));
    try std.testing.expect(@hasDecl(WhyCommand, "execFromPm"));
}
