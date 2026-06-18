// Copied from bun/src/runtime/cli/add_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.cli.Command → home_rt.cli.Command
//   - bun.install.PackageManager → home_rt.install.PackageManager

pub const AddCommand = struct {
    pub fn exec(ctx: Command.Context) !void {
        try updatePackageJSONAndInstallCatchError(ctx, .add);
    }
};

const home_rt = @import("home");
const std = @import("std");

const Command = home_rt.cli.Command;
const PackageManager = home_rt.install.PackageManager;
const updatePackageJSONAndInstallCatchError = PackageManager.updatePackageJSONAndInstallCatchError;

test "AddCommand exposes the upstream exec shape" {
    try std.testing.expect(@hasDecl(AddCommand, "exec"));
    try std.testing.expect(@TypeOf(updatePackageJSONAndInstallCatchError) == @TypeOf(PackageManager.updatePackageJSONAndInstallCatchError));
}
