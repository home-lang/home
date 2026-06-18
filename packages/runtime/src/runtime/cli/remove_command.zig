// Copied from bun/src/runtime/cli/remove_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.cli.Command → home_rt.cli.Command
//   - bun.install.PackageManager → home_rt.install.PackageManager

pub const RemoveCommand = struct {
    pub fn exec(ctx: Command.Context) !void {
        try updatePackageJSONAndInstallCatchError(ctx, .remove);
    }
};

const home_rt = @import("home");
const std = @import("std");

const Command = home_rt.cli.Command;
const PackageManager = home_rt.install.PackageManager;
const updatePackageJSONAndInstallCatchError = PackageManager.updatePackageJSONAndInstallCatchError;

test "RemoveCommand exposes the upstream exec shape" {
    try std.testing.expect(@hasDecl(RemoveCommand, "exec"));
    try std.testing.expect(@TypeOf(updatePackageJSONAndInstallCatchError) == @TypeOf(PackageManager.updatePackageJSONAndInstallCatchError));
}
