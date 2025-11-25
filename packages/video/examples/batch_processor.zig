/// Batch Processor Example
/// Processes multiple video files with the same settings
const std = @import("std");
const video = @import("video");

const ProcessingOptions = struct {
    output_dir: []const u8,
    output_format: video.VideoFormat = .mp4,
    video_codec: video.VideoCodec = .h264,
    video_bitrate: u32 = 5_000_000,
    audio_codec: video.AudioCodec = .aac,
    audio_bitrate: u32 = 192_000,
    resize_width: ?u32 = null,
    resize_height: ?u32 = null,
    normalize_audio: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage(args[0]);
        return;
    }

    // Parse options
    var options = ProcessingOptions{
        .output_dir = "output",
    };

    var input_files = std.ArrayList([]const u8).init(allocator);
    defer input_files.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
                options.output_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
                options.output_format = parseFormat(args[i + 1]);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--vbitrate") and i + 1 < args.len) {
                options.video_bitrate = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--abitrate") and i + 1 < args.len) {
                options.audio_bitrate = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--width") and i + 1 < args.len) {
                options.resize_width = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
                options.resize_height = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--normalize")) {
                options.normalize_audio = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage(args[0]);
                return;
            }
        } else {
            try input_files.append(arg);
        }
    }

    if (input_files.items.len == 0) {
        std.debug.print("Error: No input files specified\n", .{});
        printUsage(args[0]);
        return;
    }

    // Create output directory
    std.fs.cwd().makeDir(options.output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.debug.print("=== Batch Video Processor ===\n\n", .{});
    std.debug.print("Output directory: {s}\n", .{options.output_dir});
    std.debug.print("Output format: {s}\n", .{@tagName(options.output_format)});
    std.debug.print("Video: {s} @ {d} kbps\n", .{ @tagName(options.video_codec), options.video_bitrate / 1000 });
    std.debug.print("Audio: {s} @ {d} kbps\n", .{ @tagName(options.audio_codec), options.audio_bitrate / 1000 });
    if (options.resize_width) |w| {
        std.debug.print("Resize: {d}x{d}\n", .{ w, options.resize_height orelse 0 });
    }
    std.debug.print("\nProcessing {d} files...\n\n", .{input_files.items.len});

    // Process each file
    var success_count: u32 = 0;
    var error_count: u32 = 0;

    for (input_files.items, 0..) |input_path, idx| {
        std.debug.print("[{d}/{d}] {s}\n", .{ idx + 1, input_files.items.len, input_path });

        processFile(allocator, input_path, &options) catch |err| {
            std.debug.print("  ERROR: {}\n", .{err});
            error_count += 1;
            continue;
        };

        success_count += 1;
        std.debug.print("  OK\n", .{});
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Processed: {d}\n", .{success_count});
    std.debug.print("Errors: {d}\n", .{error_count});
    std.debug.print("Output: {s}/\n", .{options.output_dir});
}

fn processFile(allocator: std.mem.Allocator, input_path: []const u8, options: *const ProcessingOptions) !void {
    // Load video
    var vid = try video.bindings.Video.load(allocator, input_path);
    defer vid.deinit();

    // Apply resize if specified
    if (options.resize_width) |w| {
        const h = options.resize_height orelse @divTrunc(vid.height * w, vid.width);
        _ = vid.resize(w, h);
    }

    // Generate output filename
    const basename = std.fs.path.basename(input_path);
    const stem = std.fs.path.stem(basename);
    const ext = getExtension(options.output_format);
    const output_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{
        options.output_dir,
        stem,
        ext,
    });
    defer allocator.free(output_filename);

    // Save
    try vid.save(output_filename);
}

fn parseFormat(str: []const u8) video.VideoFormat {
    if (std.mem.eql(u8, str, "webm")) return .webm;
    if (std.mem.eql(u8, str, "mkv")) return .mkv;
    if (std.mem.eql(u8, str, "mov")) return .mov;
    if (std.mem.eql(u8, str, "avi")) return .avi;
    return .mp4;
}

fn getExtension(format: video.VideoFormat) []const u8 {
    return switch (format) {
        .webm => "webm",
        .mkv => "mkv",
        .mov => "mov",
        .avi => "avi",
        else => "mp4",
    };
}

fn printUsage(prog: []const u8) void {
    std.debug.print("Usage: {s} [options] <input_files...>\n", .{prog});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  --output <dir>      Output directory (default: output)\n", .{});
    std.debug.print("  --format <fmt>      Output format: mp4, webm, mkv, mov (default: mp4)\n", .{});
    std.debug.print("  --vbitrate <bps>    Video bitrate in bps (default: 5000000)\n", .{});
    std.debug.print("  --abitrate <bps>    Audio bitrate in bps (default: 192000)\n", .{});
    std.debug.print("  --width <px>        Resize width\n", .{});
    std.debug.print("  --height <px>       Resize height\n", .{});
    std.debug.print("  --normalize         Normalize audio levels\n", .{});
    std.debug.print("  --help              Show this help\n", .{});
    std.debug.print("\nExample:\n", .{});
    std.debug.print("  {s} --output converted --format webm *.mp4\n", .{prog});
}
