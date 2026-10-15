const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn randomSeed(io_context: std.Io) u64 {
    var seed: u64 = undefined;
    io_context.random(std.mem.asBytes(&seed));
    return seed;
}
