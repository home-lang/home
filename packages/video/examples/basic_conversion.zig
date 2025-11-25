/// Basic Video Conversion Example
/// Demonstrates converting video between formats using the Home Video Library
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <input> <output>\n", .{args[0]});
        std.debug.print("\nExample: {s} input.avi output.mp4\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    std.debug.print("Converting: {s} -> {s}\n", .{ input_path, output_path });

    // Detect output format from extension
    const output_format = detectOutputFormat(output_path);

    // Create converter
    var converter = try video.Converter.init(allocator, .{
        .input = input_path,
        .output = output_path,
        .video = switch (output_format) {
            .webm => .{ .codec = .vp9, .bitrate = 5_000_000, .preset = .medium },
            .mp4, .mov => .{ .codec = .h264, .bitrate = 5_000_000, .preset = .medium },
            else => .{ .codec = .h264, .bitrate = 5_000_000, .preset = .medium },
        },
        .audio = switch (output_format) {
            .webm => .{ .codec = .opus, .bitrate = 128_000 },
            else => .{ .codec = .aac, .bitrate = 192_000 },
        },
    });
    defer converter.deinit();

    // Run conversion with progress callback
    try converter.run(struct {
        fn callback(progress: f32) void {
            const percent = @as(u32, @intFromFloat(progress * 100));
            std.debug.print("\rProgress: {d}%", .{percent});
        }
    }.callback);

    std.debug.print("\nConversion complete!\n", .{});
}

fn detectOutputFormat(path: []const u8) video.VideoFormat {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".webm")) return .webm;
    if (std.mem.eql(u8, ext, ".mkv")) return .mkv;
    if (std.mem.eql(u8, ext, ".mov")) return .mov;
    if (std.mem.eql(u8, ext, ".avi")) return .avi;
    return .mp4;
}
