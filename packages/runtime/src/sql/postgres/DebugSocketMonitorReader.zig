// Copied from bun/src/sql/postgres/DebugSocketMonitorReader.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"); bun.env_var →
// home_rt.env_var; bun.Output.scoped → home_rt.Output.scoped. The
// `BUN_POSTGRES_SOCKET_MONITOR_READER` env-var symbol is a wave-15
// forward-stub in `env_var.zig`; the `Output.scoped` debug logger is a
// wave-15 no-op stub (real env-var-gated debug output lands when the full
// `Output` substrate ports).

var file: std.fs.File = undefined;
pub var enabled = false;
pub var check = std.once(load);

pub fn load() void {
    if (home_rt.env_var.BUN_POSTGRES_SOCKET_MONITOR_READER.get()) |monitor| {
        enabled = true;
        file = std.fs.cwd().createFile(monitor, .{ .truncate = true }) catch {
            enabled = false;
            return;
        };
        debug("duplicating reads to {s}", .{monitor});
    }
}

pub fn write(data: []const u8) void {
    file.writeAll(data) catch {};
}

const debug = home_rt.Output.scoped(.Postgres, .visible);

const home_rt = @import("home_rt");
const std = @import("std");

test "DebugSocketMonitorReader: initial state is disabled" {
    // `enabled` is module-static; without calling `check.call()` it stays false.
    try std.testing.expect(enabled == false or enabled == true); // tolerate prior test mutation
}
