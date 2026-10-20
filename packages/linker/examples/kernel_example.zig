// Example: Generate a simple kernel linker script

const std = @import("std");
const linker = @import("linker");

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Create a simple kernel script at 1MB
    var script = try linker.LinkerScript.kernelScript(
        allocator,
        "simple-kernel",
        0x10_0000, // 1MB
    );
    defer script.deinit();

    // Generate to stdout
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try script.generate(&stdout.interface, .{
        .validate = true,
        .include_comments = true,
        .verbose = true,
    });
    try stdout.interface.flush();
}
