const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn milliTimestamp(io_context: std.Io) i64 {
    return std.Io.Clock.real.now(io_context).toMilliseconds();
}

pub fn netReadLength(result: anytype) usize {
    if (@TypeOf(result) == usize) return result;
    return result.data_len;
}

pub fn timeoutMilliseconds(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .fromMilliseconds(milliseconds),
        .clock = .awake,
    } };
}
