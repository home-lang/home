// Example: Generate a simple kernel linker script

const std = @import("std");
const linker = @import("linker");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a simple kernel script at 1MB
    var script = try linker.LinkerScript.kernelScript(
        allocator,
        "simple-kernel",
        0x10_0000, // 1MB
    );
    defer script.deinit();

    // Generate to stdout
    const stdout = std.io.getStdOut().writer();
    try script.generate(stdout, .{
        .validate = true,
        .include_comments = true,
        .verbose = true,
    });
}
