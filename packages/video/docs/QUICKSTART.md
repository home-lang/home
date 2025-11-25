# Home Video Library - Quick Start Guide

## Installation

Add the video library to your project's `build.zig`:

```zig
const video = b.dependency("video", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("video", video.module("video"));
```

## Basic Usage

### Import the Library

```zig
const video = @import("video");
const std = @import("std");
```

### Read Video Information

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read MP4 file
    const file = try std.fs.cwd().openFile("input.mp4", .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

    // Parse MP4
    var reader = try video.Mp4Reader.init(allocator, data);
    const info = try reader.parse();

    std.debug.print("Duration: {d} seconds\n", .{info.duration});
    std.debug.print("Tracks: {d}\n", .{info.tracks.len});
}
```

### Read Audio File

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load WAV file
    var audio = try video.Audio.load(allocator, "input.wav");
    defer audio.deinit();

    std.debug.print("Sample Rate: {d} Hz\n", .{audio.sample_rate});
    std.debug.print("Channels: {d}\n", .{audio.channels});
    std.debug.print("Duration: {d} seconds\n", .{audio.duration()});
}
```

### Video Filtering

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a video frame (in practice, this comes from a decoder)
    var frame = try video.VideoFrame.init(allocator, 1920, 1080, .rgb24);
    defer frame.deinit();

    // Apply filters
    var scaler = video.ScaleFilter.init(allocator, .{
        .output_width = 1280,
        .output_height = 720,
        .algorithm = .lanczos,
    });

    const scaled = try scaler.apply(&frame);
    defer scaled.deinit();
}
```

### Audio Processing

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read WAV
    const data = try std.fs.cwd().readFileAlloc(allocator, "input.wav", 100 * 1024 * 1024);
    defer allocator.free(data);

    var reader = try video.WavReader.fromMemory(allocator, data);

    // Process and write
    var writer = try video.WavWriter.init(allocator, 2, 44100, .s16le);
    defer writer.deinit();

    while (try reader.readFrames(4096)) |frame| {
        // Apply volume adjustment
        var volume_filter = video.VolumeFilter.init(-3.0);  // -3 dB
        try volume_filter.apply(&frame);

        try writer.writeFrame(&frame);
    }

    try writer.writeToFile("output.wav");
}
```

### Parse Subtitles

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const srt_data = try std.fs.cwd().readFileAlloc(allocator, "subtitles.srt", 1024 * 1024);
    defer allocator.free(srt_data);

    var parser = try video.SrtParser.init(allocator, srt_data);
    defer parser.deinit();

    while (try parser.nextCue()) |cue| {
        std.debug.print("{d:.2} -> {d:.2}: {s}\n", .{
            cue.start_time,
            cue.end_time,
            cue.text,
        });
    }
}
```

### Timeline Editing

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create timeline at 1080p30
    var timeline = video.Timeline.init(allocator, 1920, 1080, .{ .num = 30, .den = 1 });
    defer timeline.deinit();

    // Add video track
    const video_track = try timeline.addVideoTrack("V1");

    // Create and insert clips
    const clip1 = video.Clip{
        .allocator = allocator,
        .source_path = "/path/to/clip1.mp4",
        .source_in = 0,
        .source_out = 5_000_000,  // 5 seconds in microseconds
        .timeline_in = 0,
        .timeline_out = 5_000_000,
        .speed = 1.0,
        .volume = 1.0,
        .transition_in = null,
        .transition_out = null,
    };

    try video_track.insertClip(clip1, 0);

    // Export to EDL
    const edl = try video.EdlExporter.exportEdl(&timeline, allocator);
    defer allocator.free(edl);

    try std.fs.cwd().writeFile("timeline.edl", edl);

    // Export to Final Cut Pro XML
    const fcpxml = try video.FcpXmlExporter.exportFcpXml(&timeline, allocator, .{
        .project_name = "My Project",
        .event_name = "Event 1",
    });
    defer allocator.free(fcpxml);

    try std.fs.cwd().writeFile("timeline.fcpxml", fcpxml);
}
```

### Home Language Style API

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home = video.bindings;

    // Video with method chaining
    var vid = try home.Video.load(allocator, "input.mp4");
    defer vid.deinit();

    _ = vid.resize(1280, 720)
           .trim(0, 30)
           .brightness(1.1)
           .contrast(1.05)
           .fadeIn(1.0)
           .fadeOut(1.0);

    try vid.save("output.mp4");

    // Audio with method chaining
    var aud = try home.Audio.load(allocator, "input.wav");
    defer aud.deinit();

    _ = aud.resample(48000)
           .toStereo()
           .normalize()
           .fadeIn(0.5);

    try aud.save("output.wav");
}
```

## Common Operations

### Convert Video Format

```zig
var converter = try video.Converter.init(allocator, .{
    .input = "input.avi",
    .output = "output.mp4",
    .video = .{
        .codec = .h264,
        .bitrate = 5_000_000,
        .preset = .medium,
    },
    .audio = .{
        .codec = .aac,
        .bitrate = 192_000,
    },
});
defer converter.deinit();

try converter.run(null);
```

### Generate Thumbnails

```zig
var extractor = video.ThumbnailExtractor.init(allocator, .{
    .width = 320,
    .height = 180,
    .format = .jpeg,
    .quality = 85,
});

// Single thumbnail at 5 seconds
const thumb = try extractor.extractAt(&source, 5.0);
defer allocator.free(thumb);

try std.fs.cwd().writeFile("thumb.jpg", thumb);
```

### Parse HLS Playlist

```zig
const m3u8 = try std.fs.cwd().readFileAlloc(allocator, "playlist.m3u8", 1024 * 1024);
defer allocator.free(m3u8);

var playlist = try video.HlsPlaylist.parse(allocator, m3u8);
defer playlist.deinit();

for (playlist.segments) |segment| {
    std.debug.print("Segment: {s} ({d}s)\n", .{ segment.uri, segment.duration });
}
```

## Next Steps

- Read the [API Reference](API.md) for complete documentation
- Check the [examples](../examples/) directory for more code samples
- See the [Error Handling Guide](ERROR_HANDLING.md) for robust error management
