// Copied from bun/src/runtime/cli/shell_completions.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//   - bun.Output → home_rt.Output
//   - bun.strings → home_rt.strings
//
// Stubs:
//   - The three `@embedFile("completions-{bash,zsh,fish}")` files are not
//     yet present in the home_rt tree (they live under
//     `bun/src/runtime/cli/completions-{bash,zsh,fish}` upstream). They're
//     replaced by empty literals so the type compiles; the real strings
//     re-attach when the completions tree ports.

const std = @import("std");
const home_rt = @import("home_rt");

const Output = home_rt.Output;
const strings = home_rt.strings;

pub const Shell = enum {
    unknown,
    bash,
    zsh,
    fish,
    pwsh,

    // Home stub: real upstream `@embedFile`s the completions tree. The
    // empty literals re-attach when the completions tree ports.
    const bash_completions: []const u8 = "";
    const zsh_completions: []const u8 = "";
    const fish_completions: []const u8 = "";

    pub fn completions(this: Shell) []const u8 {
        return switch (this) {
            .bash => bash_completions,
            .zsh => zsh_completions,
            .fish => fish_completions,
            else => "",
        };
    }

    pub fn fromEnv(comptime Type: type, SHELL: Type) Shell {
        const basename = std.fs.path.basename(SHELL);
        if (strings.eqlComptime(basename, "bash")) {
            return .bash;
        } else if (strings.eqlComptime(basename, "zsh")) {
            return .zsh;
        } else if (strings.eqlComptime(basename, "fish")) {
            return .fish;
        } else if (strings.eqlComptime(basename, "pwsh") or
            strings.eqlComptime(basename, "powershell"))
        {
            return .pwsh;
        } else {
            return .unknown;
        }
    }
};

commands: []const []const u8 = &[_][]u8{},
descriptions: []const []const u8 = &[_][]u8{},
flags: []const []const u8 = &[_][]u8{},
shell: Shell = Shell.unknown,

pub fn print(this: @This()) void {
    defer Output.flush();
    var w = Output.writer();

    if (this.commands.len == 0) return;
    const delimiter = if (this.shell == Shell.fish) " " else "\n";

    w.writeAll(this.commands[0]) catch return;

    if (this.descriptions.len > 0) {
        w.writeAll("\t") catch return;
        w.writeAll(this.descriptions[0]) catch return;
    }

    if (this.commands.len > 1) {
        for (this.commands[1..], 0..) |cmd, i| {
            w.writeAll(delimiter) catch return;

            w.writeAll(cmd) catch return;
            if (this.descriptions.len > 0) {
                w.writeAll("\t") catch return;
                w.writeAll(this.descriptions[i]) catch return;
            }
        }
    }
}

test "Shell.fromEnv maps the canonical shell basenames" {
    try std.testing.expectEqual(Shell.bash, Shell.fromEnv([]const u8, "/bin/bash"));
    try std.testing.expectEqual(Shell.zsh, Shell.fromEnv([]const u8, "/usr/bin/zsh"));
    try std.testing.expectEqual(Shell.fish, Shell.fromEnv([]const u8, "/opt/homebrew/bin/fish"));
    try std.testing.expectEqual(Shell.pwsh, Shell.fromEnv([]const u8, "/usr/local/bin/pwsh"));
    try std.testing.expectEqual(Shell.pwsh, Shell.fromEnv([]const u8, "powershell"));
    try std.testing.expectEqual(Shell.unknown, Shell.fromEnv([]const u8, "tcsh"));
}

test "Shell.completions returns empty bytes for unknown" {
    try std.testing.expectEqualStrings("", Shell.unknown.completions());
    try std.testing.expectEqualStrings("", Shell.pwsh.completions());
}
