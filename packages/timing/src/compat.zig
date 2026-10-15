const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn monotonicNanoseconds(io_context: std.Io) u64 {
    const nanoseconds = std.Io.Clock.awake.now(io_context).toNanoseconds();
    return @intCast(@max(0, nanoseconds));
}
