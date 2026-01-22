// Home Media Library - Unit Tests
// Comprehensive tests for all media package functionality

const std = @import("std");
const testing = std.testing;
const media = @import("media");

// ============================================================================
// Core Type Tests
// ============================================================================

test "MediaType enum values" {
    try testing.expectEqual(@intFromEnum(media.MediaType.video), 0);
    try testing.expectEqual(@intFromEnum(media.MediaType.audio), 1);
    try testing.expectEqual(@intFromEnum(media.MediaType.image), 2);
}

test "VideoCodec enum completeness" {
    // Ensure all codecs are defined
    const codecs = [_]media.VideoCodec{
        .h264, .hevc, .vp8, .vp9, .av1, .vvc,
        .mpeg2, .mpeg4, .mjpeg, .prores, .dnxhd,
        .theora, .wmv, .copy, .none, .unknown,
    };
    try testing.expectEqual(codecs.len, 16);
}

test "AudioCodec enum completeness" {
    const codecs = [_]media.AudioCodec{
        .aac, .mp3, .opus, .vorbis, .flac, .ac3,
        .eac3, .dts, .pcm_s16le, .pcm_s24le, .pcm_f32le,
        .alac, .wma, .copy, .none, .unknown,
    };
    try testing.expectEqual(codecs.len, 16);
}

test "ContainerFormat from extension" {
    try testing.expectEqual(media.ContainerFormat.mp4, media.ContainerFormat.fromExtension(".mp4"));
    try testing.expectEqual(media.ContainerFormat.webm, media.ContainerFormat.fromExtension(".webm"));
    try testing.expectEqual(media.ContainerFormat.mkv, media.ContainerFormat.fromExtension(".mkv"));
    try testing.expectEqual(media.ContainerFormat.avi, media.ContainerFormat.fromExtension(".avi"));
    try testing.expectEqual(media.ContainerFormat.mov, media.ContainerFormat.fromExtension(".mov"));
    try testing.expectEqual(media.ContainerFormat.flv, media.ContainerFormat.fromExtension(".flv"));
    try testing.expectEqual(media.ContainerFormat.ogg, media.ContainerFormat.fromExtension(".ogg"));
    try testing.expectEqual(media.ContainerFormat.wav, media.ContainerFormat.fromExtension(".wav"));
    try testing.expectEqual(media.ContainerFormat.mp3, media.ContainerFormat.fromExtension(".mp3"));
    try testing.expectEqual(media.ContainerFormat.flac, media.ContainerFormat.fromExtension(".flac"));
}

test "ContainerFormat case insensitivity" {
    try testing.expectEqual(media.ContainerFormat.mp4, media.ContainerFormat.fromExtension(".MP4"));
    try testing.expectEqual(media.ContainerFormat.webm, media.ContainerFormat.fromExtension(".WEBM"));
}

// ============================================================================
// Timestamp Tests
// ============================================================================

test "Timestamp from seconds" {
    const ts = media.Timestamp.fromSeconds(1.5);
    try testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
}

test "Timestamp from milliseconds" {
    const ts = media.Timestamp.fromMilliseconds(2500);
    try testing.expectEqual(@as(u64, 2500), ts.toMilliseconds());
    try testing.expectApproxEqAbs(@as(f64, 2.5), ts.toSeconds(), 0.0001);
}

test "Timestamp from microseconds" {
    const ts = media.Timestamp.fromMicroseconds(1500000);
    try testing.expectEqual(@as(u64, 1500000), ts.pts);
    try testing.expectEqual(@as(u64, 1500), ts.toMilliseconds());
}

test "Timestamp arithmetic" {
    const ts1 = media.Timestamp.fromSeconds(1.0);
    const ts2 = media.Timestamp.fromSeconds(0.5);

    const sum = ts1.add(ts2);
    try testing.expectApproxEqAbs(@as(f64, 1.5), sum.toSeconds(), 0.0001);

    const diff = ts1.subtract(ts2);
    try testing.expectApproxEqAbs(@as(f64, 0.5), diff.toSeconds(), 0.0001);
}

test "Timestamp comparison" {
    const ts1 = media.Timestamp.fromSeconds(1.0);
    const ts2 = media.Timestamp.fromSeconds(2.0);
    const ts3 = media.Timestamp.fromSeconds(1.0);

    try testing.expect(ts1.lessThan(ts2));
    try testing.expect(!ts2.lessThan(ts1));
    try testing.expect(ts1.equals(ts3));
}

// ============================================================================
// Duration Tests
// ============================================================================

test "Duration from seconds" {
    const d = media.Duration.fromSeconds(60.0);
    try testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
    try testing.expectApproxEqAbs(@as(f64, 60.0), d.toSeconds(), 0.0001);
}

test "Duration from milliseconds" {
    const d = media.Duration.fromMilliseconds(5000);
    try testing.expectApproxEqAbs(@as(f64, 5.0), d.toSeconds(), 0.0001);
}

test "Duration zero" {
    const d = media.Duration.zero();
    try testing.expectEqual(@as(u64, 0), d.microseconds);
}

// ============================================================================
// Rational Tests
// ============================================================================

test "Rational to f64" {
    const r = media.Rational{ .num = 30, .den = 1 };
    try testing.expectApproxEqAbs(@as(f64, 30.0), r.toF64(), 0.0001);

    const r2 = media.Rational{ .num = 30000, .den = 1001 };
    try testing.expectApproxEqAbs(@as(f64, 29.97), r2.toF64(), 0.01);
}

test "Rational common frame rates" {
    const fps24 = media.Rational.fps24();
    try testing.expectApproxEqAbs(@as(f64, 23.976), fps24.toF64(), 0.001);

    const fps30 = media.Rational.fps30();
    try testing.expectApproxEqAbs(@as(f64, 29.97), fps30.toF64(), 0.001);

    const fps60 = media.Rational.fps60();
    try testing.expectApproxEqAbs(@as(f64, 59.94), fps60.toF64(), 0.01);
}

// ============================================================================
// QualityPreset Tests
// ============================================================================

test "QualityPreset video settings" {
    const low = media.QualityPreset.low.videoSettings();
    try testing.expectEqual(@as(u8, 28), low.crf);

    const medium = media.QualityPreset.medium.videoSettings();
    try testing.expectEqual(@as(u8, 23), medium.crf);

    const high = media.QualityPreset.high.videoSettings();
    try testing.expectEqual(@as(u8, 18), high.crf);

    const ultra = media.QualityPreset.ultra.videoSettings();
    try testing.expectEqual(@as(u8, 15), ultra.crf);
}

test "QualityPreset audio settings" {
    const low = media.QualityPreset.low.audioSettings();
    try testing.expectEqual(@as(u32, 96), low.bitrate);

    const medium = media.QualityPreset.medium.audioSettings();
    try testing.expectEqual(@as(u32, 128), medium.bitrate);

    const high = media.QualityPreset.high.audioSettings();
    try testing.expectEqual(@as(u32, 192), high.bitrate);
}

// ============================================================================
// Error Tests
// ============================================================================

test "MediaError to ErrorCode" {
    try testing.expectEqual(media.ErrorCode.ok, media.MediaError.none.toCode());
    try testing.expectEqual(media.ErrorCode.invalid_input, media.MediaError.InvalidInput.toCode());
    try testing.expectEqual(media.ErrorCode.unsupported_codec, media.MediaError.UnsupportedCodec.toCode());
}

test "ErrorCode to MediaError" {
    try testing.expectEqual(media.MediaError.none, media.ErrorCode.ok.toError());
    try testing.expectEqual(media.MediaError.InvalidInput, media.ErrorCode.invalid_input.toError());
    try testing.expectEqual(media.MediaError.OutOfMemory, media.ErrorCode.out_of_memory.toError());
}

test "Error recovery check" {
    try testing.expect(media.isRecoverable(media.MediaError.Timeout));
    try testing.expect(media.isRecoverable(media.MediaError.ResourceBusy));
    try testing.expect(!media.isRecoverable(media.MediaError.OutOfMemory));
    try testing.expect(!media.isRecoverable(media.MediaError.InvalidInput));
}

test "User error messages" {
    const msg1 = media.getUserMessage(media.MediaError.InvalidInput);
    try testing.expect(msg1.len > 0);

    const msg2 = media.getUserMessage(media.MediaError.UnsupportedCodec);
    try testing.expect(msg2.len > 0);
}

// ============================================================================
// Pipeline Tests
// ============================================================================

test "Pipeline initialization" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    try testing.expectEqual(media.VideoCodec.h264, p.video_options.codec);
    try testing.expectEqual(media.AudioCodec.aac, p.audio_options.codec);
}

test "Pipeline input/output" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = try p.input("test.mp4");
    _ = try p.output("output.webm");

    try testing.expect(p.input_path != null);
    try testing.expect(p.output_path != null);
}

test "Pipeline video codec" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.videoCodec(.vp9);
    try testing.expectEqual(media.VideoCodec.vp9, p.video_options.codec);

    _ = p.videoCodec(.hevc);
    try testing.expectEqual(media.VideoCodec.hevc, p.video_options.codec);
}

test "Pipeline audio codec" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.audioCodec(.opus);
    try testing.expectEqual(media.AudioCodec.opus, p.audio_options.codec);
}

test "Pipeline video options" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.videoBitrate(5000);
    _ = p.crf(18);
    _ = p.fps(60.0);

    try testing.expectEqual(@as(u32, 5000), p.video_options.bitrate);
    try testing.expectEqual(@as(u8, 18), p.video_options.crf);
}

test "Pipeline audio options" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.audioBitrate(192);
    _ = p.sampleRate(48000);
    _ = p.channels(2);

    try testing.expectEqual(@as(u32, 192), p.audio_options.bitrate);
    try testing.expectEqual(@as(u32, 48000), p.audio_options.sample_rate);
    try testing.expectEqual(@as(u8, 2), p.audio_options.channels);
}

test "Pipeline filters" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = try p.resize(1920, 1080);
    _ = try p.blur(0.5);
    _ = try p.grayscale();

    try testing.expectEqual(@as(usize, 3), p.video_filters.items.len);
}

test "Pipeline quality preset" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.quality(.high);
    try testing.expectEqual(@as(u8, 18), p.video_options.crf);
}

test "Pipeline time operations" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.seek(10.0);
    _ = p.duration(60.0);
    _ = p.to(70.0);

    try testing.expect(p.start_time != null);
    try testing.expect(p.duration_time != null);
    try testing.expect(p.end_time != null);
}

test "Pipeline stream copy" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.copyVideo();
    _ = p.copyAudio();

    try testing.expect(p.copy_video);
    try testing.expect(p.copy_audio);
}

test "Pipeline no streams" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    _ = p.noVideo();
    _ = p.noAudio();

    try testing.expect(p.no_video);
    try testing.expect(p.no_audio);
}

// ============================================================================
// Filter Graph Tests
// ============================================================================

test "FilterGraph initialization" {
    const allocator = testing.allocator;
    var fg = media.FilterGraph.init(allocator);
    defer fg.deinit();

    try testing.expectEqual(@as(usize, 0), fg.filters.items.len);
}

test "FilterGraph add video filter" {
    const allocator = testing.allocator;
    var fg = media.FilterGraph.init(allocator);
    defer fg.deinit();

    try fg.addVideoFilter(.{ .scale = .{ .width = 1920, .height = 1080 } });
    try fg.addVideoFilter(.{ .blur = .{ .sigma = 1.0 } });

    try testing.expectEqual(@as(usize, 2), fg.filters.items.len);
}

test "FilterGraph add audio filter" {
    const allocator = testing.allocator;
    var fg = media.FilterGraph.init(allocator);
    defer fg.deinit();

    try fg.addAudioFilter(.{ .volume = .{ .level = 1.5 } });
    try fg.addAudioFilter(.{ .normalize = .{} });

    try testing.expectEqual(@as(usize, 2), fg.filters.items.len);
}

// ============================================================================
// Transcoder Tests
// ============================================================================

test "Transcoder initialization" {
    const allocator = testing.allocator;

    const config = media.TranscoderConfig{
        .input_path = "test.mp4",
        .output_path = "test.webm",
    };

    var transcoder = media.Transcoder.init(allocator, config);
    defer transcoder.deinit();

    try testing.expectEqual(media.transcoder_mod.TranscoderState.idle, transcoder.state);
}

test "TranscoderStats duration" {
    var stats = media.TranscoderStats{
        .start_time_ns = 0,
        .end_time_ns = 5_000_000_000, // 5 seconds
    };

    try testing.expectEqual(@as(u64, 5000), stats.duration_ms());
}

test "TranscoderStats avgFps" {
    var stats = media.TranscoderStats{
        .frames_encoded = 300,
        .start_time_ns = 0,
        .end_time_ns = 10_000_000_000, // 10 seconds
    };

    try testing.expectApproxEqAbs(@as(f32, 30.0), stats.avgFps(), 0.1);
}

// ============================================================================
// BatchTranscoder Tests
// ============================================================================

test "BatchTranscoder initialization" {
    const allocator = testing.allocator;

    var batch = media.BatchTranscoder.init(allocator);
    defer batch.deinit();

    try testing.expectEqual(@as(usize, 0), batch.jobs.items.len);
}

test "BatchTranscoder add jobs" {
    const allocator = testing.allocator;

    var batch = media.BatchTranscoder.init(allocator);
    defer batch.deinit();

    try batch.addJob(.{
        .input_path = "video1.mp4",
        .output_path = "video1.webm",
    });
    try batch.addJob(.{
        .input_path = "video2.mp4",
        .output_path = "video2.webm",
    });

    try testing.expectEqual(@as(usize, 2), batch.jobs.items.len);
}

test "BatchTranscoder set parallel" {
    const allocator = testing.allocator;

    var batch = media.BatchTranscoder.init(allocator);
    defer batch.deinit();

    batch.setMaxParallel(4);
    try testing.expectEqual(@as(u32, 4), batch.max_parallel);
}

// ============================================================================
// Registry Tests
// ============================================================================

test "Registry format info" {
    const mp4_info = media.Registry.getFormatInfo(.mp4);
    try testing.expect(mp4_info != null);
    try testing.expect(mp4_info.?.supports_video);
    try testing.expect(mp4_info.?.supports_audio);

    const mkv_info = media.Registry.getFormatInfo(.mkv);
    try testing.expect(mkv_info != null);
    try testing.expect(mkv_info.?.supports_subtitles);
}

test "Registry video codec info" {
    const h264_info = media.Registry.getVideoCodecInfo(.h264);
    try testing.expect(h264_info != null);
    try testing.expect(h264_info.?.lossy);

    const av1_info = media.Registry.getVideoCodecInfo(.av1);
    try testing.expect(av1_info != null);
}

test "Registry audio codec info" {
    const aac_info = media.Registry.getAudioCodecInfo(.aac);
    try testing.expect(aac_info != null);
    try testing.expect(aac_info.?.lossy);

    const flac_info = media.Registry.getAudioCodecInfo(.flac);
    try testing.expect(flac_info != null);
    try testing.expect(!flac_info.?.lossy);
}

test "Registry codec compatibility" {
    // MP4 supports H.264, HEVC, AV1
    try testing.expect(media.Registry.isCodecCompatible(.mp4, .h264));
    try testing.expect(media.Registry.isCodecCompatible(.mp4, .hevc));
    try testing.expect(media.Registry.isCodecCompatible(.mp4, .av1));
    try testing.expect(!media.Registry.isCodecCompatible(.mp4, .vp9));

    // WebM supports VP8, VP9, AV1
    try testing.expect(media.Registry.isCodecCompatible(.webm, .vp8));
    try testing.expect(media.Registry.isCodecCompatible(.webm, .vp9));
    try testing.expect(media.Registry.isCodecCompatible(.webm, .av1));
    try testing.expect(!media.Registry.isCodecCompatible(.webm, .h264));

    // MKV supports everything
    try testing.expect(media.Registry.isCodecCompatible(.mkv, .h264));
    try testing.expect(media.Registry.isCodecCompatible(.mkv, .vp9));
    try testing.expect(media.Registry.isCodecCompatible(.mkv, .av1));
}

// ============================================================================
// Presets Tests
// ============================================================================

test "Presets webVideo" {
    const preset = media.Presets.webVideo();
    try testing.expectEqual(media.VideoCodec.h264, preset.codec);
    try testing.expectEqual(@as(u8, 23), preset.crf);
}

test "Presets hqVideo" {
    const preset = media.Presets.hqVideo();
    try testing.expectEqual(media.VideoCodec.hevc, preset.codec);
    try testing.expectEqual(@as(u8, 18), preset.crf);
}

test "Presets standardAudio" {
    const preset = media.Presets.standardAudio();
    try testing.expectEqual(media.AudioCodec.aac, preset.codec);
    try testing.expectEqual(@as(u32, 128), preset.bitrate);
}

test "Presets losslessAudio" {
    const preset = media.Presets.losslessAudio();
    try testing.expectEqual(media.AudioCodec.flac, preset.codec);
}

// ============================================================================
// Version Tests
// ============================================================================

test "Version information" {
    try testing.expectEqual(@as(u32, 0), media.VERSION.MAJOR);
    try testing.expectEqual(@as(u32, 1), media.VERSION.MINOR);
    try testing.expectEqual(@as(u32, 0), media.VERSION.PATCH);

    const version_str = media.VERSION.string();
    try testing.expect(version_str.len > 0);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "Full pipeline configuration" {
    const allocator = testing.allocator;
    var p = media.Pipeline.init(allocator);
    defer p.deinit();

    // Configure a complete pipeline
    _ = try p.input("test.mp4");
    _ = try p.output("output.webm");
    _ = p.videoCodec(.vp9);
    _ = p.audioCodec(.opus);
    _ = p.quality(.high);
    _ = try p.resize(1920, 1080);
    _ = try p.blur(0.5);
    _ = p.seek(10.0);
    _ = p.duration(60.0);

    try testing.expectEqual(media.VideoCodec.vp9, p.video_options.codec);
    try testing.expectEqual(media.AudioCodec.opus, p.audio_options.codec);
    try testing.expectEqual(@as(usize, 2), p.video_filters.items.len);
}

test "Media struct initialization" {
    // Test that Media struct can be initialized with default values
    var m = media.Media{
        .allocator = testing.allocator,
        .path = null,
        .info = null,
        .data = null,
    };
    defer m.deinit();

    try testing.expect(!m.hasVideo());
    try testing.expect(!m.hasAudio());
    try testing.expectApproxEqAbs(@as(f64, 0), m.duration(), 0.0001);
}
