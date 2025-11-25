/// Streaming Encoder Example
/// Demonstrates HLS/DASH output generation
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: {s} <input> <output_dir> <format>\n", .{args[0]});
        std.debug.print("\nFormats:\n", .{});
        std.debug.print("  hls   - HTTP Live Streaming (Apple)\n", .{});
        std.debug.print("  dash  - Dynamic Adaptive Streaming over HTTP\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} video.mp4 ./output hls\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    const output_dir = args[2];
    const format = args[3];

    std.debug.print("Encoding for streaming: {s}\n", .{input_path});
    std.debug.print("Output directory: {s}\n", .{output_dir});
    std.debug.print("Format: {s}\n\n", .{format});

    // Create output directory
    std.fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Load source video
    var source = try video.bindings.Video.load(allocator, input_path);
    defer source.deinit();

    std.debug.print("Source: {d}x{d}, {d:.2}s\n", .{
        source.width,
        source.height,
        source.duration(),
    });

    if (std.mem.eql(u8, format, "hls")) {
        try generateHls(allocator, &source, output_dir);
    } else if (std.mem.eql(u8, format, "dash")) {
        try generateDash(allocator, &source, output_dir);
    } else {
        std.debug.print("Unknown format: {s}\n", .{format});
        return;
    }

    std.debug.print("\nStreaming output generated successfully!\n", .{});
}

fn generateHls(allocator: std.mem.Allocator, source: *video.bindings.Video, output_dir: []const u8) !void {
    std.debug.print("\nGenerating HLS output...\n", .{});

    // Quality variants
    const variants = [_]struct { height: u32, bitrate: u32, name: []const u8 }{
        .{ .height = 1080, .bitrate = 5_000_000, .name = "1080p" },
        .{ .height = 720, .bitrate = 2_500_000, .name = "720p" },
        .{ .height = 480, .bitrate = 1_000_000, .name = "480p" },
        .{ .height = 360, .bitrate = 600_000, .name = "360p" },
    };

    // Generate master playlist
    var master = std.ArrayList(u8).init(allocator);
    defer master.deinit();

    const master_writer = master.writer();
    try master_writer.writeAll("#EXTM3U\n");
    try master_writer.writeAll("#EXT-X-VERSION:4\n\n");

    for (variants) |variant| {
        std.debug.print("  Encoding {s} variant ({d} kbps)...\n", .{
            variant.name,
            variant.bitrate / 1000,
        });

        // Add to master playlist
        try master_writer.print("#EXT-X-STREAM-INF:BANDWIDTH={d},RESOLUTION={d}x{d}\n", .{
            variant.bitrate,
            @divTrunc(source.width * variant.height, source.height),
            variant.height,
        });
        try master_writer.print("{s}/playlist.m3u8\n", .{variant.name});

        // Create variant directory
        const variant_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, variant.name });
        defer allocator.free(variant_dir);

        std.fs.cwd().makeDir(variant_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Generate variant playlist (simplified)
        var variant_playlist = std.ArrayList(u8).init(allocator);
        defer variant_playlist.deinit();

        const vp_writer = variant_playlist.writer();
        try vp_writer.writeAll("#EXTM3U\n");
        try vp_writer.writeAll("#EXT-X-VERSION:4\n");
        try vp_writer.writeAll("#EXT-X-TARGETDURATION:6\n");
        try vp_writer.writeAll("#EXT-X-MEDIA-SEQUENCE:0\n");
        try vp_writer.writeAll("#EXT-X-PLAYLIST-TYPE:VOD\n\n");

        // Generate segments (6 second each)
        const duration = source.duration();
        const segment_duration: f64 = 6.0;
        var segment_num: u32 = 0;
        var current_time: f64 = 0;

        while (current_time < duration) : (segment_num += 1) {
            const seg_dur = @min(segment_duration, duration - current_time);
            try vp_writer.print("#EXTINF:{d:.6},\n", .{seg_dur});
            try vp_writer.print("segment_{d:0>5}.ts\n", .{segment_num});
            current_time += segment_duration;
        }

        try vp_writer.writeAll("#EXT-X-ENDLIST\n");

        // Write variant playlist
        const playlist_path = try std.fmt.allocPrint(allocator, "{s}/playlist.m3u8", .{variant_dir});
        defer allocator.free(playlist_path);
        try std.fs.cwd().writeFile(playlist_path, variant_playlist.items);
    }

    // Write master playlist
    const master_path = try std.fmt.allocPrint(allocator, "{s}/master.m3u8", .{output_dir});
    defer allocator.free(master_path);
    try std.fs.cwd().writeFile(master_path, master.items);

    std.debug.print("\nHLS output:\n", .{});
    std.debug.print("  Master playlist: {s}/master.m3u8\n", .{output_dir});
    std.debug.print("  Variants: 1080p, 720p, 480p, 360p\n", .{});
}

fn generateDash(allocator: std.mem.Allocator, source: *video.bindings.Video, output_dir: []const u8) !void {
    std.debug.print("\nGenerating DASH output...\n", .{});

    // Generate MPD (Media Presentation Description)
    var mpd = std.ArrayList(u8).init(allocator);
    defer mpd.deinit();

    const writer = mpd.writer();

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try writer.writeAll("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" ");
    try writer.writeAll("type=\"static\" ");
    try writer.print("mediaPresentationDuration=\"PT{d:.3}S\" ", .{source.duration()});
    try writer.writeAll("profiles=\"urn:mpeg:dash:profile:isoff-live:2011\">\n");

    try writer.writeAll("  <Period start=\"PT0S\">\n");

    // Video AdaptationSet
    try writer.writeAll("    <AdaptationSet mimeType=\"video/mp4\" segmentAlignment=\"true\">\n");

    const video_variants = [_]struct { height: u32, bitrate: u32 }{
        .{ .height = 1080, .bitrate = 5_000_000 },
        .{ .height = 720, .bitrate = 2_500_000 },
        .{ .height = 480, .bitrate = 1_000_000 },
    };

    for (video_variants, 0..) |variant, idx| {
        const width = @divTrunc(source.width * variant.height, source.height);
        try writer.print("      <Representation id=\"video_{d}\" bandwidth=\"{d}\" ", .{ idx, variant.bitrate });
        try writer.print("width=\"{d}\" height=\"{d}\" codecs=\"avc1.64001f\">\n", .{ width, variant.height });
        try writer.writeAll("        <SegmentTemplate media=\"video_$RepresentationID$_$Number$.m4s\" ");
        try writer.writeAll("initialization=\"video_$RepresentationID$_init.m4s\" ");
        try writer.writeAll("duration=\"6000\" timescale=\"1000\"/>\n");
        try writer.writeAll("      </Representation>\n");
    }

    try writer.writeAll("    </AdaptationSet>\n");

    // Audio AdaptationSet
    try writer.writeAll("    <AdaptationSet mimeType=\"audio/mp4\" segmentAlignment=\"true\" lang=\"en\">\n");
    try writer.writeAll("      <Representation id=\"audio_0\" bandwidth=\"128000\" ");
    try writer.writeAll("codecs=\"mp4a.40.2\" audioSamplingRate=\"48000\">\n");
    try writer.writeAll("        <AudioChannelConfiguration ");
    try writer.writeAll("schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"2\"/>\n");
    try writer.writeAll("        <SegmentTemplate media=\"audio_$RepresentationID$_$Number$.m4s\" ");
    try writer.writeAll("initialization=\"audio_$RepresentationID$_init.m4s\" ");
    try writer.writeAll("duration=\"6000\" timescale=\"1000\"/>\n");
    try writer.writeAll("      </Representation>\n");
    try writer.writeAll("    </AdaptationSet>\n");

    try writer.writeAll("  </Period>\n");
    try writer.writeAll("</MPD>\n");

    // Write MPD
    const mpd_path = try std.fmt.allocPrint(allocator, "{s}/manifest.mpd", .{output_dir});
    defer allocator.free(mpd_path);
    try std.fs.cwd().writeFile(mpd_path, mpd.items);

    std.debug.print("\nDASH output:\n", .{});
    std.debug.print("  Manifest: {s}/manifest.mpd\n", .{output_dir});
    std.debug.print("  Video representations: 1080p, 720p, 480p\n", .{});
    std.debug.print("  Audio: 128 kbps AAC\n", .{});
}
