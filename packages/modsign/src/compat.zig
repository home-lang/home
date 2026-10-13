const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn randomSecure(buffer: []u8) !void {
    try std.Io.randomSecure(io(), buffer);
}
