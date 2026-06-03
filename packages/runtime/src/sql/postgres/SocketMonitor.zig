pub fn write(data: []const u8) void {
    debug("SocketMonitor: write {x}", .{data});
    if (comptime home_rt.Environment.isDebug) {
        DebugSocketMonitorWriter.check.call(.{});
        if (DebugSocketMonitorWriter.enabled) {
            DebugSocketMonitorWriter.write(data);
        }
    }
}

pub fn read(data: []const u8) void {
    debug("SocketMonitor: read {x}", .{data});
    if (comptime home_rt.Environment.isDebug) {
        DebugSocketMonitorReader.check.call(.{});
        if (DebugSocketMonitorReader.enabled) {
            DebugSocketMonitorReader.write(data);
        }
    }
}

const debug = home_rt.Output.scoped(.SocketMonitor, .visible);

const DebugSocketMonitorReader = @import("./DebugSocketMonitorReader.zig");
const DebugSocketMonitorWriter = @import("./DebugSocketMonitorWriter.zig");
const home_rt = @import("home");

test "SocketMonitor.write/read accept arbitrary byte slices" {
    // The functions are no-ops outside debug mode + with no env var set,
    // but invoking them exercises the comptime branch and the import.
    write("hello");
    read("world");
}
