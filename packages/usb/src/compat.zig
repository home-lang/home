const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn nowSeconds(io_context: std.Io) i64 {
    return std.Io.Clock.real.now(io_context).toSeconds();
}
