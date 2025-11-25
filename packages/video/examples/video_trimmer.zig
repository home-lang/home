/// Video Trimmer Example
/// Trims video files to a specified time range
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} <input> <output> <start_time> <end_time>\n", .{args[0]});
        std.debug.print("\nExample: {s} input.mp4 output.mp4 10.5 60.0\n", .{args[0]});
        std.debug.print("\nTimes are in seconds (supports decimals)\n", .{});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];
    const start_time = try std.fmt.parseFloat(f64, args[3]);
    const end_time = try std.fmt.parseFloat(f64, args[4]);

    if (start_time >= end_time) {
        std.debug.print("Error: start_time must be less than end_time\n", .{});
        return;
    }

    std.debug.print("Trimming: {s}\n", .{input_path});
    std.debug.print("Time range: {d:.2}s - {d:.2}s ({d:.2}s duration)\n", .{
        start_time,
        end_time,
        end_time - start_time,
    });

    // Use Home API for fluent interface
    var vid = try video.bindings.Video.load(allocator, input_path);
    defer vid.deinit();

    // Chain operations
    _ = vid.trim(start_time, end_time);

    // Save trimmed video
    try vid.save(output_path);

    std.debug.print("Saved to: {s}\n", .{output_path});
    std.debug.print("Done!\n", .{});
}
