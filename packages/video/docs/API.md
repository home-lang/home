# Home Video Library - API Reference

A comprehensive, dependency-free video processing library for the Home programming language.

## Core Types

### Timestamp
Represents a point in time with microsecond precision.

```zig
const ts = Timestamp.fromSeconds(1.5);
const seconds = ts.toSeconds();  // 1.5
const micros = ts.microseconds;  // 1500000
```

### Duration
Represents a time span.

```zig
const d = Duration.fromSeconds(60.0);
const ms = d.toMilliseconds();  // 60000
```

### Rational
Represents frame rates and time bases as numerator/denominator.

```zig
const frame_rate = Rational{ .num = 30000, .den = 1001 };  // 29.97 fps
const fps = frame_rate.toFloat();  // ~29.97
```

### PixelFormat
Supported pixel formats:
- `yuv420p`, `yuv422p`, `yuv444p` - Planar YUV
- `nv12`, `nv21` - Semi-planar YUV
- `rgb24`, `bgr24` - 24-bit RGB
- `rgba32`, `bgra32` - 32-bit RGBA
- `gray8`, `gray16` - Grayscale

### SampleFormat
Audio sample formats:
- `u8` - Unsigned 8-bit
- `s16le`, `s16be` - Signed 16-bit
- `s24le`, `s24be` - Signed 24-bit
- `s32le`, `s32be` - Signed 32-bit
- `f32le`, `f32be` - 32-bit float
- `f64le`, `f64be` - 64-bit float

## Container Formats

### MP4
```zig
const video = @import("video");

// Reading
var reader = try video.Mp4Reader.init(allocator, file_data);
const info = try reader.parse();

// Writing
var muxer = try video.Mp4Muxer.init(allocator, .{
    .video = .{ .codec = .h264, .width = 1920, .height = 1080 },
    .audio = .{ .codec = .aac, .sample_rate = 48000, .channels = 2 },
});
try muxer.writeVideoPacket(packet);
```

### WebM/Matroska
```zig
var reader = try video.WebmReader.init(allocator, data);
const segment = try reader.parseSegmentInfo();
```

### WAV
```zig
// Reading
var wav = try video.WavReader.fromMemory(allocator, data);
while (try wav.readFrames(4096)) |frame| {
    // Process audio frame
}

// Writing
var writer = try video.WavWriter.init(allocator, 2, 44100, .s16le);
try writer.writeFrame(&audio_frame);
try writer.writeToFile("output.wav");
```

## Video Codecs

### H.264/AVC
```zig
// Parse NAL units
var nal_iter = video.H264NalIterator{ .data = bitstream };
while (nal_iter.next()) |nal| {
    switch (nal.unit_type) {
        .sps => { /* Parse SPS */ },
        .pps => { /* Parse PPS */ },
        .idr_slice => { /* Keyframe */ },
        else => {},
    }
}
```

### H.265/HEVC
```zig
var hevc_iter = video.HevcNalIterator{ .data = bitstream };
while (hevc_iter.next()) |nal| {
    // Process HEVC NAL units
}
```

### VP9
```zig
var parser = video.Vp9FrameParser.init(frame_data);
const header = try parser.parseUncompressedHeader();
```

### AV1
```zig
var obu_iter = video.Av1ObuIterator{ .data = bitstream };
while (try obu_iter.next()) |obu| {
    // Process OBU
}
```

## Audio Codecs

### AAC
```zig
// Decoding
var decoder = video.AacDecoder.init(allocator);
const frame = try decoder.decode(adts_packet);

// Encoding
var encoder = video.AacEncoder.init(allocator, 48000, 2, 128000);
const encoded = try encoder.encodeAdts(&audio_frame);
```

### Opus
```zig
const id_header = try video.OpusIdHeader.parse(header_data);
```

### FLAC
```zig
var flac = try video.FlacReader.init(allocator, data);
const info = try flac.readStreamInfo();
```

## Video Filters

### Scale
```zig
var scaler = video.ScaleFilter.init(allocator, .{
    .output_width = 1280,
    .output_height = 720,
    .algorithm = .lanczos,
});
const scaled = try scaler.apply(&frame);
```

### Color Adjustment
```zig
var color = video.ColorFilter.init(.{
    .brightness = 1.1,
    .contrast = 1.05,
    .saturation = 0.9,
});
try color.apply(&frame);
```

### Blur/Sharpen
```zig
var blur = video.BlurFilter.init(5.0, .gaussian);
try blur.apply(&frame);

var sharpen = video.SharpenFilter.init(1.5);
try sharpen.apply(&frame);
```

### Deinterlace
```zig
var deint = video.DeinterlaceFilter.init(.yadif, .top_field_first);
const progressive = try deint.apply(&interlaced_frame);
```

## Audio Filters

### Resample
```zig
var resampler = video.ResampleFilter.init(allocator, .{
    .input_rate = 44100,
    .output_rate = 48000,
    .quality = .high,
});
const resampled = try resampler.process(&audio);
```

### Volume
```zig
var volume = video.VolumeFilter.init(-6.0);  // -6 dB
try volume.apply(&audio_frame);
```

### Normalize
```zig
var normalizer = video.NormalizeFilter.init(.{
    .target_level = -14.0,  // LUFS
    .mode = .loudness,
});
try normalizer.apply(&audio);
```

## Subtitles

### SRT
```zig
var srt = try video.SrtParser.init(allocator, srt_data);
while (try srt.nextCue()) |cue| {
    // cue.start_time, cue.end_time, cue.text
}
```

### WebVTT
```zig
var vtt = try video.VttParser.init(allocator, vtt_data);
const cues = try vtt.parseAll();
```

### ASS/SSA
```zig
var ass = try video.AssParser.init(allocator, ass_data);
const styles = ass.styles;
const dialogues = ass.dialogues;
```

## Streaming

### HLS
```zig
var playlist = try video.HlsPlaylist.parse(allocator, m3u8_data);
for (playlist.segments) |segment| {
    // segment.uri, segment.duration
}
```

### DASH
```zig
var manifest = try video.DashManifest.parse(allocator, mpd_data);
for (manifest.periods) |period| {
    for (period.adaptation_sets) |set| {
        // Process representations
    }
}
```

## Timeline/NLE

### Creating a Timeline
```zig
var timeline = video.Timeline.init(allocator, 1920, 1080, .{ .num = 30, .den = 1 });
defer timeline.deinit();

const track = try timeline.addVideoTrack("V1");
try track.insertClip(clip, 0);
```

### Export
```zig
// EDL export
const edl = try video.EdlExporter.exportEdl(&timeline, allocator);

// Final Cut Pro XML
const fcpxml = try video.FcpXmlExporter.exportFcpXml(&timeline, allocator, .{
    .project_name = "My Project",
});
```

## Metadata

### ID3 Tags
```zig
if (video.hasId3v2(data)) {
    const tag = try video.parseId3v2(allocator, data);
    // tag.title, tag.artist, tag.album
}
```

### MP4 Metadata
```zig
const meta = try video.parseMp4Metadata(allocator, mp4_data);
```

## Hardware Acceleration

### Detection
```zig
const hw = @import("video").hw;
const available = hw.detectAvailable();
if (available.videotoolbox) {
    // Use VideoToolbox
}
```

## Conversion Pipeline

### Basic Conversion
```zig
var converter = try video.Converter.init(allocator, .{
    .input = "input.mp4",
    .output = "output.webm",
    .video = .{ .codec = .vp9, .bitrate = 5000000 },
    .audio = .{ .codec = .opus, .bitrate = 128000 },
});
try converter.run(progressCallback);
```

### Presets
```zig
const options = video.Presets.webOptimized();
var converter = try video.Converter.init(allocator, options);
```

## Quality Analysis

### PSNR/SSIM
```zig
const psnr = try video.calculatePsnr(&original, &compressed);
const ssim = try video.calculateSsim(&original, &compressed);
```

### Scene Detection
```zig
var detector = video.ScenecutDetector.init(allocator, .{
    .threshold = 0.4,
    .method = .histogram,
});
const cuts = try detector.detect(&video_frames);
```

## Thumbnails

```zig
var extractor = video.ThumbnailExtractor.init(allocator, .{
    .width = 320,
    .height = 180,
    .format = .jpeg,
});

// Single thumbnail
const thumb = try extractor.extractAt(&video, 5.0);

// Sprite sheet
const sprite = try extractor.generateSpriteSheet(&video, .{
    .columns = 10,
    .rows = 10,
    .interval = 1.0,
});
```

## Home Language API

### Video Operations
```zig
const home = @import("video").bindings;

var video = try home.Video.load(allocator, "input.mp4");
defer video.deinit();

// Method chaining with lazy evaluation
_ = video.resize(1920, 1080)
    .trim(0, 60)
    .brightness(1.1)
    .grayscale();

try video.save("output.mp4");
```

### Audio Operations
```zig
var audio = try home.Audio.load(allocator, "input.wav");
defer audio.deinit();

_ = audio.resample(48000).toMono().normalize();
try audio.save("output.wav");
```

## Error Handling

All operations return `VideoError` on failure:

```zig
const result = operation() catch |err| switch (err) {
    error.InvalidFormat => // Handle invalid format
    error.CodecNotSupported => // Handle unsupported codec
    error.OutOfMemory => // Handle OOM
    else => return err,
};
```

Use `getUserMessage(err)` for human-readable error messages.
