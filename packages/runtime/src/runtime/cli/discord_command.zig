// Copied from bun/src/runtime/cli/discord_command.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - `BunCommand`-equivalent surface: upstream exports `DiscordCommand`
//     (no `Bun…` prefix); preserved verbatim.
//   - discord_url: rebranded from `https://bun.com/discord` to
//     `https://home.lang/discord` — this is Home's CLI surface, not
//     a runtime API contract, so the URL changes with the brand.
//   - `open.openURL(...)` is PARKED: `bun/src/runtime/cli/open.zig`
//     drags in `bun.spawnSync` + `bun.jsc.EventLoopHandle`, neither of
//     which is in the allow-list. The fallback path (an `Output.prettyln`
//     pointing the user at the URL) is inlined here so the CLI command
//     still works end-to-end on Home; the spawn-based opener re-attaches
//     in Phase 12.5 once the spawn substrate lands.
//   - @import("bun") → @import("home_rt").

pub const DiscordCommand = struct {
    const discord_url = "https://home.lang/discord";

    pub fn exec(_: std.mem.Allocator) !void {
        // Parked: `open.openURL(discord_url)` (see banner). For now the
        // fallback path — print the URL — runs unconditionally. This
        // matches what upstream falls back to on Wasi and when its
        // spawn pipeline errors.
        home_rt.Output.prettyln("-> {s}", .{discord_url});
        home_rt.Output.flush();
    }
};

const home_rt = @import("home_rt");
const std = @import("std");

test "DiscordCommand.exec emits the discord URL without crashing" {
    // The implementation only writes to the global Output sink, so
    // calling it from a test just exercises the print path.
    try DiscordCommand.exec(std.testing.allocator);
}

test "DiscordCommand.discord_url points at the Home brand" {
    // The URL is the load-bearing public-facing string; pin it so a
    // future rebrand has to walk past a failing test rather than ship
    // silently.
    const url = @field(DiscordCommand, "discord_url");
    try std.testing.expectEqualStrings("https://home.lang/discord", url);
}
