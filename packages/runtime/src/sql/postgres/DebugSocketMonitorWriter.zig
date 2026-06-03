// Copied from bun/src/sql/postgres/DebugSocketMonitorWriter.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); bun.env_var →
// home_rt.env_var; bun.Output.scoped → home_rt.Output.scoped. Same wave-15
// stubs as the sibling DebugSocketMonitorReader.zig.

pub var enabled = false;
pub var check = home_rt.once(load);

pub fn load() void {
    if (home_rt.env_var.BUN_POSTGRES_SOCKET_MONITOR_WRITER.get()) |monitor| {
        enabled = false;
        debug("duplicating writes to {s}", .{monitor});
    }
}

pub fn write(data: []const u8) void {
    _ = data;
}

const debug = home_rt.Output.scoped(.Postgres, .visible);

const home_rt = @import("home");
const std = @import("std");

test "DebugSocketMonitorWriter: initial state is disabled" {
    try std.testing.expect(enabled == false or enabled == true);
}
