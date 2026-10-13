const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io()).toSeconds();
}

pub fn randomSecure(buffer: []u8) !void {
    try std.Io.randomSecure(io(), buffer);
}

pub fn sleepMilliseconds(milliseconds: u64) !void {
    const duration = std.math.cast(i64, milliseconds) orelse return error.DurationOverflow;
    try std.Io.sleep(io(), .fromMilliseconds(duration), .awake);
}
