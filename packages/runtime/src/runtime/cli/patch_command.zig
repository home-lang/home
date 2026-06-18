// Copied from bun/src/runtime/cli/patch_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.cli.Command → home_rt.cli.Command
//   - bun.install.PackageManager → home_rt.install.PackageManager

//! parse dependency of positional arg string (may include name@version for example)
//! get the precise version from the lockfile (there may be multiple)
//! copy the contents into a temp folder

pub const PatchCommand = struct {
    pub fn exec(ctx: Command.Context) !void {
        try updatePackageJSONAndInstallCatchError(ctx, .patch);
    }
};

const string = []const u8;

const home_rt = @import("home");
const std = @import("std");

const Command = home_rt.cli.Command;
const PackageManager = home_rt.install.PackageManager;
const updatePackageJSONAndInstallCatchError = PackageManager.updatePackageJSONAndInstallCatchError;

test "PatchCommand exposes the upstream exec shape" {
    _ = string;
    try std.testing.expect(@hasDecl(PatchCommand, "exec"));
    try std.testing.expect(@TypeOf(updatePackageJSONAndInstallCatchError) == @TypeOf(PackageManager.updatePackageJSONAndInstallCatchError));
}
