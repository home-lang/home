// Ported from Bun's shell-completion implementation and generated assets at
// upstream SHA 4982b91e3702094330f3be3883354c52b8c01323. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.Output → home_rt.Output
//   - bun.strings → home_rt.strings
//
// Assets:
//   - The generated completion scripts are copied from Bun's top-level
//     `completions/bun.{bash,zsh,fish}` files at the pinned upstream SHA.

const std = @import("std");
const home_rt = @import("home");

const Output = home_rt.Output;
const strings = home_rt.strings;

pub const Shell = enum {
    unknown,
    bash,
    zsh,
    fish,
    pwsh,

    const bash_completions = @embedFile("completions-bash");
    const zsh_completions = @embedFile("completions-zsh");
    const fish_completions = @embedFile("completions-fish");

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

test "Shell.completions embeds each generated script" {
    try std.testing.expect(std.mem.startsWith(u8, Shell.bash.completions(), "#/usr/bin/env bash"));
    try std.testing.expect(std.mem.startsWith(u8, Shell.zsh.completions(), "#compdef bun"));
    try std.testing.expect(std.mem.startsWith(u8, Shell.fish.completions(), "# This is terribly complicated"));
}
