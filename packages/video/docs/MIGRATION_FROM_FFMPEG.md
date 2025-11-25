# Migration from FFmpeg

This guide helps you migrate from FFmpeg command-line usage to the Home Video Library.

## Basic Conversion

### FFmpeg
```bash
ffmpeg -i input.mp4 -c:v libx264 -c:a aac output.mp4
```

### Home Video Library
```zig
const video = @import("video");

var converter = try video.Converter.init(allocator, .{
    .input = "input.mp4",
    .output = "output.mp4",
    .video = .{ .codec = .h264 },
    .audio = .{ .codec = .aac },
});
try converter.run(null);
```

## Resize Video

### FFmpeg
```bash
ffmpeg -i input.mp4 -vf "scale=1280:720" output.mp4
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
_ = vid.resize(1280, 720);
try vid.save("output.mp4");
```

## Trim Video

### FFmpeg
```bash
ffmpeg -i input.mp4 -ss 00:00:10 -to 00:01:00 output.mp4
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
_ = vid.trim(10.0, 60.0);  // Start at 10s, end at 60s
try vid.save("output.mp4");
```

## Extract Audio

### FFmpeg
```bash
ffmpeg -i video.mp4 -vn -c:a aac audio.aac
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "video.mp4");
var audio = try vid.extractAudio();
try audio.save("audio.aac");
```

## Generate Thumbnails

### FFmpeg
```bash
ffmpeg -i input.mp4 -ss 00:00:05 -vframes 1 thumb.jpg
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
const frame = try vid.getFrame(5.0);
// Save frame as image
```

## Multiple Thumbnails

### FFmpeg
```bash
ffmpeg -i input.mp4 -vf "fps=1/10" thumb_%03d.jpg
```

### Home Video Library
```zig
var extractor = video.ThumbnailExtractor.init(allocator, .{
    .format = .jpeg,
    .interval = 10.0,
});
try extractor.extractAll(&vid, "thumb_%03d.jpg");
```

## Create GIF

### FFmpeg
```bash
ffmpeg -i input.mp4 -vf "fps=10,scale=320:-1" -t 5 output.gif
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
_ = vid.trim(0, 5);
const gif = try video.videoToGif(&vid, .{
    .width = 320,
    .fps = 10,
});
try std.fs.cwd().writeFile("output.gif", gif);
```

## Adjust Volume

### FFmpeg
```bash
ffmpeg -i input.mp4 -af "volume=1.5" output.mp4
```

### Home Video Library
```zig
var audio = try video.bindings.Audio.load(allocator, "input.mp4");
_ = audio.adjustVolume(3.5);  // ~1.5x = +3.5 dB
try audio.save("output.mp4");
```

## Normalize Audio

### FFmpeg
```bash
ffmpeg -i input.mp4 -af "loudnorm=I=-14:TP=-1:LRA=11" output.mp4
```

### Home Video Library
```zig
var audio = try video.bindings.Audio.load(allocator, "input.mp4");
_ = audio.normalize();  // EBU R128 to -14 LUFS
try audio.save("output.mp4");
```

## HLS Streaming

### FFmpeg
```bash
ffmpeg -i input.mp4 -c:v h264 -c:a aac \
    -hls_time 6 -hls_playlist_type vod output.m3u8
```

### Home Video Library
```zig
var hls = video.streaming.HlsWriter.init(allocator, .{
    .segment_duration = 6.0,
    .playlist_type = .vod,
});
try hls.process("input.mp4", "output.m3u8");
```

## Concatenate Videos

### FFmpeg
```bash
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```

### Home Video Library
```zig
var timeline = video.Timeline.init(allocator, 1920, 1080, .{ .num = 30, .den = 1 });
const track = try timeline.addVideoTrack("V1");

for (files) |file| {
    var clip = video.Clip{ .source_path = file, ... };
    try track.insertClip(clip, track.getDuration());
}

var renderer = video.TimelineRenderer.init(allocator, &timeline);
try renderer.render("output.mp4");
```

## Add Watermark

### FFmpeg
```bash
ffmpeg -i input.mp4 -i logo.png \
    -filter_complex "overlay=10:10" output.mp4
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");

var overlay = video.ImageOverlay.init(allocator, .{
    .image_path = "logo.png",
    .x = 10,
    .y = 10,
    .opacity = 0.8,
});
// Apply overlay during render
try vid.save("output.mp4");
```

## Color Adjustment

### FFmpeg
```bash
ffmpeg -i input.mp4 -vf "eq=brightness=0.1:contrast=1.2:saturation=0.8" output.mp4
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
_ = vid.brightness(1.1).contrast(1.2).saturation(0.8);
try vid.save("output.mp4");
```

## Speed Change

### FFmpeg
```bash
ffmpeg -i input.mp4 -filter:v "setpts=0.5*PTS" output.mp4
```

### Home Video Library
```zig
var vid = try video.bindings.Video.load(allocator, "input.mp4");
_ = vid.speed(2.0);  // 2x speed (0.5 PTS)
try vid.save("output.mp4");
```

## Format Detection

### FFmpeg
```bash
ffprobe -v error -show_format input.mp4
```

### Home Video Library
```zig
const format = video.detectFormat(data);
const info = try video.Mp4Reader.init(allocator, data);
std.debug.print("Duration: {d}s\n", .{info.duration});
```

## Key Differences

| Feature | FFmpeg | Home Video Library |
|---------|--------|-------------------|
| Language | C (command-line) | Zig (native library) |
| Dependencies | External binary | Zero dependencies |
| API Style | CLI flags | Method chaining |
| Memory | Managed | Custom allocator |
| Threading | Automatic | Configurable |
| Error Handling | Exit codes | Rich error types |

## Performance Tips

1. **Use hardware acceleration**: The library auto-detects available hardware
2. **Stream processing**: Don't load entire files into memory
3. **Batch operations**: Use BatchConverter for multiple files
4. **Lazy evaluation**: Chain operations before final render
