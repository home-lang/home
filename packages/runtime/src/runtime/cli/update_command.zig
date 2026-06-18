// Copied from bun/src/runtime/cli/update_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.cli.Command → home_rt.cli.Command
//   - bun.install.PackageManager → home_rt.install.PackageManager
//
// The interactive branch still imports `update_interactive_command.zig` lazily
// from the same runtime/cli subtree; that larger TUI command ports separately.

pub const UpdateCommand = struct {
    pub fn exec(ctx: Command.Context) !void {
        const cli = try PackageManager.CommandLineArguments.parse(ctx.allocator, .update);

        if (cli.interactive) {
            const UpdateInteractiveCommand = @import("./update_interactive_command.zig").UpdateInteractiveCommand;
            try UpdateInteractiveCommand.exec(ctx);
        } else {
            try updatePackageJSONAndInstallCatchError(ctx, .update);
        }
    }
};

const home_rt = @import("home");
const std = @import("std");

const Command = home_rt.cli.Command;
const PackageManager = home_rt.install.PackageManager;
const updatePackageJSONAndInstallCatchError = PackageManager.updatePackageJSONAndInstallCatchError;

test "UpdateCommand exposes the upstream exec shape" {
    try std.testing.expect(@hasDecl(UpdateCommand, "exec"));
    try std.testing.expect(@hasDecl(PackageManager, "CommandLineArguments"));
    try std.testing.expect(@TypeOf(updatePackageJSONAndInstallCatchError) == @TypeOf(PackageManager.updatePackageJSONAndInstallCatchError));
}
