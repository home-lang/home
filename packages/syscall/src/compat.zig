const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
