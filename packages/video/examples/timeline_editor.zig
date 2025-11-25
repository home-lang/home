/// Timeline Editor Example
/// Mini Non-Linear Editor demonstrating timeline functionality
const std = @import("std");
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Mini Timeline Editor ===\n\n", .{});

    // Create a 1080p30 timeline
    var timeline = video.Timeline.init(allocator, 1920, 1080, .{ .num = 30, .den = 1 });
    defer timeline.deinit();

    // Add tracks
    const v1 = try timeline.addVideoTrack("V1");
    const v2 = try timeline.addVideoTrack("V2");
    const a1 = try timeline.addAudioTrack("A1");
    _ = v2;
    _ = a1;

    std.debug.print("Created timeline: 1920x1080 @ 30fps\n", .{});
    std.debug.print("Tracks: {d} video, {d} audio\n\n", .{
        timeline.video_tracks.items.len,
        timeline.audio_tracks.items.len,
    });

    // Add clips to V1
    std.debug.print("Adding clips to timeline...\n", .{});

    // Clip 1: 0-5 seconds
    const clip1 = video.Clip{
        .allocator = allocator,
        .source_path = "/path/to/intro.mp4",
        .source_in = 0,
        .source_out = 5_000_000, // 5 seconds
        .timeline_in = 0,
        .timeline_out = 5_000_000,
        .speed = 1.0,
        .volume = 1.0,
        .transition_in = null,
        .transition_out = video.Transition{
            .transition_type = .crossfade,
            .duration_us = 500_000, // 0.5 seconds
            .easing = .ease_in_out,
        },
    };
    try v1.insertClip(clip1, 0);
    std.debug.print("  Clip 1: intro.mp4 (0:00 - 0:05)\n", .{});

    // Clip 2: 5-15 seconds
    const clip2 = video.Clip{
        .allocator = allocator,
        .source_path = "/path/to/main.mp4",
        .source_in = 10_000_000, // Start at 10 seconds of source
        .source_out = 20_000_000, // End at 20 seconds of source
        .timeline_in = 5_000_000,
        .timeline_out = 15_000_000,
        .speed = 1.0,
        .volume = 1.0,
        .transition_in = null,
        .transition_out = null,
    };
    try v1.insertClip(clip2, 5_000_000);
    std.debug.print("  Clip 2: main.mp4 (0:05 - 0:15)\n", .{});

    // Clip 3: 15-20 seconds
    const clip3 = video.Clip{
        .allocator = allocator,
        .source_path = "/path/to/outro.mp4",
        .source_in = 0,
        .source_out = 5_000_000,
        .timeline_in = 15_000_000,
        .timeline_out = 20_000_000,
        .speed = 1.0,
        .volume = 1.0,
        .transition_in = video.Transition{
            .transition_type = .fade,
            .duration_us = 1_000_000, // 1 second
            .easing = .linear,
        },
        .transition_out = null,
    };
    try v1.insertClip(clip3, 15_000_000);
    std.debug.print("  Clip 3: outro.mp4 (0:15 - 0:20)\n", .{});

    std.debug.print("\nTimeline duration: {d:.2} seconds\n", .{
        @as(f64, @floatFromInt(timeline.getDuration())) / 1_000_000.0,
    });

    // Export to various formats
    std.debug.print("\n=== Exporting Timeline ===\n\n", .{});

    // EDL Export
    const edl = try video.EdlExporter.exportEdl(&timeline, allocator);
    defer allocator.free(edl);
    try std.fs.cwd().writeFile("project.edl", edl);
    std.debug.print("Exported: project.edl\n", .{});

    // Final Cut Pro XML Export
    const fcpxml = try video.FcpXmlExporter.exportFcpXml(&timeline, allocator, .{
        .project_name = "My Project",
        .event_name = "Timeline Editor Demo",
    });
    defer allocator.free(fcpxml);
    try std.fs.cwd().writeFile("project.fcpxml", fcpxml);
    std.debug.print("Exported: project.fcpxml\n", .{});

    // Premiere XML Export
    const premiere = try video.FcpXmlExporter.exportPremiereXml(&timeline, allocator, .{
        .project_name = "My Project",
        .sequence_name = "Sequence 01",
    });
    defer allocator.free(premiere);
    try std.fs.cwd().writeFile("project.xml", premiere);
    std.debug.print("Exported: project.xml (Premiere)\n", .{});

    // JSON Project Export
    const project = video.timeline.TimelineProject{
        .timeline = timeline,
        .project_name = "Timeline Editor Demo",
        .created_date = std.time.timestamp(),
    };
    const json = try project.save(allocator);
    defer allocator.free(json);
    try std.fs.cwd().writeFile("project.json", json);
    std.debug.print("Exported: project.json\n", .{});

    std.debug.print("\nDone! Check the exported files.\n", .{});
}
