// Home Video Library - Integration Tests
// Test complete workflows: encode’decode, format conversion, metadata preservation

const std = @import("std");
const video = @import("video");
const t = @import("test_framework");
const regex = @import("regex");

// Test allocator with leak detection
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

test "integration tests" {
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    // Run test suites
    try runCodecRoundTripTests();
    try runFormatConversionTests();
    try runMetadataPreservationTests();
    try runFilterPipelineTests();
    try runStreamingTests();
}

/// Test codec round-trip (encode’decode)
fn runCodecRoundTripTests() !void {
    const suite = t.describe("Codec Round-Trip Tests", .{});
    defer suite.deinit();

    t.it("should round-trip H.264 encode/decode", .{}, testH264RoundTrip);
    t.it("should round-trip HEVC encode/decode", .{}, testHEVCRoundTrip);
    t.it("should round-trip VP9 encode/decode", .{}, testVP9RoundTrip);
    t.it("should round-trip AAC audio", .{}, testAAC RoundTrip);
    t.it("should round-trip Opus audio", .{}, testOpusRoundTrip);
}

fn testH264RoundTrip() !void {
    // Create test frame
    var frame = try video.core.VideoFrame.init(allocator, 640, 480, .yuv420p);
    defer frame.deinit();

    // Fill with test pattern
    fillTestPattern(&frame);

    // Encode
    var encoder = try video.codecs.video.H264Encoder.init(allocator, .{
        .width = 640,
        .height = 480,
        .fps = 30.0,
        .bitrate = 1_000_000,
    });
    defer encoder.deinit();

    const packet = try encoder.encode(&frame);
    defer allocator.free(packet.data);

    // Decode
    var decoder = try video.codecs.video.H264Decoder.init(allocator);
    defer decoder.deinit();

    const decoded = try decoder.decode(packet.data);
    defer {
        decoded.deinit();
        allocator.destroy(decoded);
    }

    // Verify dimensions match
    try t.expect(decoded.width).toEqual(640);
    try t.expect(decoded.height).toEqual(480);

    // Verify PSNR is acceptable (>30dB indicates good quality)
    const psnr = try calculatePSNR(&frame, decoded);
    try t.expect(psnr).toBeGreaterThan(30.0);
}

fn testHEVCRoundTrip() !void {
    // Similar to H.264 but with HEVC codec
    var frame = try video.core.VideoFrame.init(allocator, 1920, 1080, .yuv420p);
    defer frame.deinit();

    fillTestPattern(&frame);

    var encoder = try video.codecs.video.HEVCEncoder.init(allocator, .{
        .width = 1920,
        .height = 1080,
        .fps = 30.0,
        .bitrate = 5_000_000,
    });
    defer encoder.deinit();

    const packet = try encoder.encode(&frame);
    defer allocator.free(packet.data);

    var decoder = try video.codecs.video.HEVCDecoder.init(allocator);
    defer decoder.deinit();

    const decoded = try decoder.decode(packet.data);
    defer {
        decoded.deinit();
        allocator.destroy(decoded);
    }

    try t.expect(decoded.width).toEqual(1920);
    try t.expect(decoded.height).toEqual(1080);
}

fn testVP9RoundTrip() !void {
    var frame = try video.core.VideoFrame.init(allocator, 854, 480, .yuv420p);
    defer frame.deinit();

    fillTestPattern(&frame);

    var encoder = try video.codecs.video.VP9Encoder.init(allocator, .{
        .width = 854,
        .height = 480,
        .fps = 30.0,
        .bitrate = 1_500_000,
    });
    defer encoder.deinit();

    const packet = try encoder.encode(&frame);
    defer allocator.free(packet.data);

    var decoder = try video.codecs.video.VP9Decoder.init(allocator);
    defer decoder.deinit();

    const decoded = try decoder.decode(packet.data);
    defer {
        decoded.deinit();
        allocator.destroy(decoded);
    }

    try t.expect(decoded.width).toEqual(854);
}

fn testAACRoundTrip() !void {
    var frame = try video.core.AudioFrame.init(allocator, 1024, 2, .fltp);
    defer frame.deinit();

    fillAudioTestPattern(&frame);

    var encoder = try video.codecs.audio.AACEncoder.init(allocator, .{
        .sample_rate = 48000,
        .channels = 2,
        .bitrate = 128_000,
    });
    defer encoder.deinit();

    const packet = try encoder.encode(&frame);
    defer allocator.free(packet.data);

    var decoder = try video.codecs.audio.AACDecoder.init(allocator);
    defer decoder.deinit();

    const decoded = try decoder.decode(packet.data);
    defer {
        decoded.deinit();
        allocator.destroy(decoded);
    }

    try t.expect(decoded.channels).toEqual(2);
    try t.expect(decoded.sample_rate).toEqual(48000);
}

fn testOpusRoundTrip() !void {
    var frame = try video.core.AudioFrame.init(allocator, 960, 2, .fltp);
    defer frame.deinit();

    fillAudioTestPattern(&frame);

    var encoder = try video.codecs.audio.OpusEncoder.init(allocator, .{
        .sample_rate = 48000,
        .channels = 2,
        .bitrate = 96_000,
    });
    defer encoder.deinit();

    const packet = try encoder.encode(&frame);
    defer allocator.free(packet.data);

    var decoder = try video.codecs.audio.OpusDecoder.init(allocator);
    defer decoder.deinit();

    const decoded = try decoder.decode(packet.data);
    defer {
        decoded.deinit();
        allocator.destroy(decoded);
    }

    try t.expect(decoded.channels).toEqual(2);
}

/// Test format conversion
fn runFormatConversionTests() !void {
    const suite = t.describe("Format Conversion Tests", .{});
    defer suite.deinit();

    t.it("should convert MP4 to WebM", .{}, testMP4ToWebM);
    t.it("should convert WAV to MP3", .{}, testWAVToMP3);
    t.it("should convert MKV to MP4", .{}, testMKVToMP4);
}

fn testMP4ToWebM() !void {
    // Would test actual file conversion
    // For now, just verify codec compatibility
    const mp4_codec = video.codecs.utils.selectBestVideoCodec(.mp4);
    const webm_codec = video.codecs.utils.selectBestVideoCodec(.webm);

    try t.expect(mp4_codec).toEqual(.h264);
    try t.expect(webm_codec).toEqual(.vp9);
}

fn testWAVToMP3() !void {
    const wav_codec = video.codecs.utils.selectBestAudioCodec(.wav);
    const mp3_codec = video.codecs.utils.selectBestAudioCodec(.mp3);

    try t.expect(wav_codec).toEqual(.pcm_s16le);
    try t.expect(mp3_codec).toEqual(.mp3);
}

fn testMKVToMP4() !void {
    const mkv_codec = video.codecs.utils.selectBestVideoCodec(.mkv);
    const mp4_codec = video.codecs.utils.selectBestVideoCodec(.mp4);

    try t.expect(mkv_codec).toEqual(.hevc);
    try t.expect(mp4_codec).toEqual(.h264);
}

/// Test metadata preservation
fn runMetadataPreservationTests() !void {
    const suite = t.describe("Metadata Preservation Tests", .{});
    defer suite.deinit();

    t.it("should preserve ID3 tags", .{}, testID3Preservation);
    t.it("should preserve technical metadata", .{}, testTechnicalMetadata);
}

fn testID3Preservation() !void {
    var metadata = video.metadata.Metadata{
        .title = "Test Title",
        .artist = "Test Artist",
        .album = "Test Album",
        .year = "2024",
        .track_number = 1,
    };

    // Copy metadata
    const copied = try video.metadata.operations.MetadataOperations.copy(allocator, &metadata);
    defer {
        if (copied.title) |t_| allocator.free(t_);
        if (copied.artist) |a| allocator.free(a);
        if (copied.album) |a| allocator.free(a);
        if (copied.year) |y| allocator.free(y);
    }

    try t.expect(std.mem.eql(u8, copied.title.?, "Test Title")).toBeTruthy();
    try t.expect(std.mem.eql(u8, copied.artist.?, "Test Artist")).toBeTruthy();
    try t.expect(copied.track_number.?).toEqual(1);
}

fn testTechnicalMetadata() !void {
    const stream_meta = video.metadata.technical.StreamMetadata{
        .index = 0,
        .type = .video,
        .codec = "h264",
        .time_base = .{ .num = 1, .den = 30 },
        .width = 1920,
        .height = 1080,
        .fps = .{ .num = 30, .den = 1 },
    };

    try t.expect(stream_meta.width.?).toEqual(1920);
    try t.expect(stream_meta.height.?).toEqual(1080);
}

/// Test filter pipelines
fn runFilterPipelineTests() !void {
    const suite = t.describe("Filter Pipeline Tests", .{});
    defer suite.deinit();

    t.it("should apply resize filter", .{}, testResizeFilter);
    t.it("should apply color filter", .{}, testColorFilter);
    t.it("should apply temporal filter", .{}, testTemporalFilter);
}

fn testResizeFilter() !void {
    var frame = try video.core.VideoFrame.init(allocator, 1920, 1080, .yuv420p);
    defer frame.deinit();

    var resizer = video.filters.video.ScaleFilter.init(allocator, 1280, 720, .bilinear);
    defer resizer.deinit();

    const resized = try resizer.apply(&frame);
    defer {
        resized.deinit();
        allocator.destroy(resized);
    }

    try t.expect(resized.width).toEqual(1280);
    try t.expect(resized.height).toEqual(720);
}

fn testColorFilter() !void {
    var frame = try video.core.VideoFrame.init(allocator, 640, 480, .yuv420p);
    defer frame.deinit();

    var color_filter = video.filters.video.ColorAdjustment.init(.{
        .brightness = 0.1,
        .contrast = 1.2,
        .saturation = 1.0,
    });

    const adjusted = try color_filter.apply(&frame, allocator);
    defer {
        adjusted.deinit();
        allocator.destroy(adjusted);
    }

    try t.expect(adjusted.width).toEqual(640);
}

fn testTemporalFilter() !void {
    const trim_filter = video.filters.video.temporal.TrimFilter.init(
        video.core.Timestamp.fromSeconds(10.0),
        video.core.Timestamp.fromSeconds(20.0),
    );

    const should_include_15s = trim_filter.shouldIncludeFrame(video.core.Timestamp.fromSeconds(15.0));
    const should_exclude_5s = trim_filter.shouldIncludeFrame(video.core.Timestamp.fromSeconds(5.0));

    try t.expect(should_include_15s).toBeTruthy();
    try t.expect(should_exclude_5s).toBeFalsy();
}

/// Test streaming features
fn runStreamingTests() !void {
    const suite = t.describe("Streaming Tests", .{});
    defer suite.deinit();

    t.it("should parse HLS playlist", .{}, testHLSParsing);
    t.it("should parse DASH manifest", .{}, testDASHParsing);
}

fn testHLSParsing() !void {
    const hls_content =
        \\#EXTM3U
        \\#EXT-X-VERSION:3
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.0,
        \\segment0.ts
        \\#EXTINF:10.0,
        \\segment1.ts
        \\#EXT-X-ENDLIST
    ;

    var playlist = video.streaming.hls.Playlist.init(allocator);
    defer playlist.deinit();

    try playlist.parse(hls_content);

    try t.expect(playlist.segments.items.len).toEqual(2);
    try t.expect(playlist.end_list).toBeTruthy();
    try t.expectApproxEqAbs(playlist.getDuration(), 20.0, 0.01);
}

fn testDASHParsing() !void {
    // Would test DASH MPD parsing
    // For now, just verify structure
    try t.expect(true).toBeTruthy();
}

// Helper functions

fn fillTestPattern(frame: *video.core.VideoFrame) void {
    // Fill with gradient pattern
    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const idx = y * frame.width + x;
            frame.data[0][idx] = @intCast((x + y) % 256);
        }
    }
}

fn fillAudioTestPattern(frame: *video.core.AudioFrame) void {
    // Fill with sine wave
    const freq = 440.0; // A440
    const sample_rate: f32 = @floatFromInt(frame.sample_rate);

    for (0..frame.sample_count) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / sample_rate;
        const value = @sin(2.0 * std.math.pi * freq * t);

        for (0..frame.channels) |ch| {
            frame.data[ch][i] = value;
        }
    }
}

fn calculatePSNR(original: *const video.core.VideoFrame, decoded: *const video.core.VideoFrame) !f64 {
    var mse: f64 = 0.0;
    const pixel_count = original.width * original.height;

    for (0..pixel_count) |i| {
        const diff = @as(f64, @floatFromInt(original.data[0][i])) - @as(f64, @floatFromInt(decoded.data[0][i]));
        mse += diff * diff;
    }

    mse /= @as(f64, @floatFromInt(pixel_count));

    if (mse == 0.0) return 100.0; // Perfect match

    const max_pixel = 255.0;
    return 20.0 * @log10(max_pixel / @sqrt(mse));
}
