/// GIF Creator Example
/// Converts video clips to animated GIFs
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <input> <output.gif> [options]\n", .{args[0]});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  --width <n>      Output width (default: 480)\n", .{});
        std.debug.print("  --fps <n>        Frame rate (default: 10)\n", .{});
        std.debug.print("  --colors <n>     Max colors 2-256 (default: 256)\n", .{});
        std.debug.print("  --start <sec>    Start time in seconds\n", .{});
        std.debug.print("  --duration <sec> Duration in seconds\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} video.mp4 output.gif --width 320 --fps 15\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    // Parse options
    var width: u32 = 480;
    var fps: u32 = 10;
    var max_colors: u8 = 255;
    var start_time: f64 = 0.0;
    var duration: ?f64 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
            width = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--fps") and i + 1 < args.len) {
            fps = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--colors") and i + 1 < args.len) {
            max_colors = try std.fmt.parseInt(u8, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--start") and i + 1 < args.len) {
            start_time = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--duration") and i + 1 < args.len) {
            duration = try std.fmt.parseFloat(f64, args[i + 1]);
            i += 1;
        }
    }

    std.debug.print("Creating GIF from: {s}\n", .{input_path});
    std.debug.print("Settings: {d}px width, {d} fps, {d} colors\n", .{ width, fps, max_colors });

    // Load video
    var vid = try video.bindings.Video.load(allocator, input_path);
    defer vid.deinit();

    // Apply trim if specified
    if (duration) |dur| {
        _ = vid.trim(start_time, start_time + dur);
        std.debug.print("Trimmed to: {d:.2}s - {d:.2}s\n", .{ start_time, start_time + dur });
    } else if (start_time > 0) {
        _ = vid.trim(start_time, vid.duration());
    }

    // Create GIF
    const gif_data = try video.videoToGif(&vid, .{
        .width = width,
        .height = null, // Auto-calculate height
        .fps = fps,
        .max_colors = max_colors,
        .dither = true,
        .loop = 0, // Infinite loop
    });
    defer allocator.free(gif_data);

    // Save GIF
    try std.fs.cwd().writeFile(output_path, gif_data);

    std.debug.print("Saved to: {s}\n", .{output_path});
    std.debug.print("Size: {d} bytes\n", .{gif_data.len});
    std.debug.print("Done!\n", .{});
}
