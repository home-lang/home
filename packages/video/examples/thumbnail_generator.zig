/// Thumbnail Generator Example
/// Generates thumbnails from video files
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <video_file> [output_prefix]\n", .{args[0]});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  video_file     Input video file\n", .{});
        std.debug.print("  output_prefix  Output filename prefix (default: 'thumb')\n", .{});
        return;
    }

    const input_path = args[1];
    const output_prefix = if (args.len > 2) args[2] else "thumb";

    std.debug.print("Generating thumbnails from: {s}\n", .{input_path});

    // Initialize thumbnail extractor
    var extractor = video.ThumbnailExtractor.init(allocator, .{
        .width = 320,
        .height = 180,
        .format = .jpeg,
        .quality = 85,
        .skip_black_frames = true,
    });

    // Load video using Home API
    var vid = try video.bindings.Video.load(allocator, input_path);
    defer vid.deinit();

    const duration = vid.duration();
    std.debug.print("Video duration: {d:.2} seconds\n", .{duration});

    // Generate thumbnails at different timestamps
    const timestamps = [_]f64{ 0.0, duration * 0.25, duration * 0.5, duration * 0.75 };

    for (timestamps, 0..) |ts, i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}_{d}.jpg", .{ output_prefix, i });
        defer allocator.free(filename);

        std.debug.print("Generating thumbnail at {d:.2}s -> {s}\n", .{ ts, filename });

        const thumb = try extractor.extractAt(&vid, ts);
        defer allocator.free(thumb);

        try std.fs.cwd().writeFile(filename, thumb);
    }

    // Generate sprite sheet
    std.debug.print("Generating sprite sheet...\n", .{});

    const sprite = try extractor.generateSpriteSheet(&vid, .{
        .columns = 10,
        .rows = 10,
        .interval = duration / 100.0,
    });
    defer allocator.free(sprite.image);
    defer allocator.free(sprite.webvtt);

    const sprite_filename = try std.fmt.allocPrint(allocator, "{s}_sprite.jpg", .{output_prefix});
    defer allocator.free(sprite_filename);

    const vtt_filename = try std.fmt.allocPrint(allocator, "{s}_sprite.vtt", .{output_prefix});
    defer allocator.free(vtt_filename);

    try std.fs.cwd().writeFile(sprite_filename, sprite.image);
    try std.fs.cwd().writeFile(vtt_filename, sprite.webvtt);

    std.debug.print("Sprite sheet: {s}\n", .{sprite_filename});
    std.debug.print("WebVTT file: {s}\n", .{vtt_filename});
    std.debug.print("Done!\n", .{});
}
