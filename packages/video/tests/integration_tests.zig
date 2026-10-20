// Home Video Library - Integration Tests
// Exercise complete public workflows across core media types, I/O, and formats.

const std = @import("std");
const video = @import("video");
const t = @import("test_framework");

var debug_allocator = std.heap.DebugAllocator(.{}).init;
const allocator = debug_allocator.allocator();

test "integration tests" {
    defer {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak) std.debug.print("Memory leak detected!\n", .{});
    }
    defer t.cleanupRegistry();

    try runFrameWorkflowTests();
    try runPacketWorkflowTests();
    try runMemoryIoTests();
    try runFormatDetectionTests();
    try runStreamingTests();

    const registry = t.getRegistry(allocator);
    const success = try t.runTests(allocator, registry);
    try std.testing.expect(success);
}

fn runFrameWorkflowTests() !void {
    try t.describe(allocator, "Frame Workflows", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "clones video frames with timing and color metadata", testVideoFrameClone);
            try t.it(test_allocator, "round-trips planar audio samples", testAudioFrameSamples);
        }
    }.register);
}

fn testVideoFrameClone(test_allocator: std.mem.Allocator) !void {
    var frame = try video.VideoFrame.init(allocator, 64, 36, .yuv420p);
    defer frame.deinit();
    for (frame.data, 0..) |*byte, index| byte.* = @intCast(index % 251);
    frame.pts = video.Timestamp.fromMilliseconds(1250);
    frame.duration = video.Duration.fromMilliseconds(40);
    frame.color_space = .bt709;
    frame.color_range = .limited;
    frame.color_primaries = .bt709;
    frame.color_transfer = .bt709;

    var cloned = try frame.clone();
    defer cloned.deinit();
    try t.expect(test_allocator, cloned.width).toEqual(frame.width);
    try t.expect(test_allocator, cloned.height).toEqual(frame.height);
    try t.expect(test_allocator, cloned.pts.eql(frame.pts)).toBeTruthy();
    try t.expect(test_allocator, std.mem.eql(u8, cloned.data, frame.data)).toBeTruthy();
    try t.expect(test_allocator, cloned.color_space).toEqual(.bt709);

    cloned.data[0] ^= 0xff;
    try t.expect(test_allocator, cloned.data[0] != frame.data[0]).toBeTruthy();
}

fn testAudioFrameSamples(test_allocator: std.mem.Allocator) !void {
    var frame = try video.AudioFrame.init(allocator, 480, .f32p, 2, 48_000);
    defer frame.deinit();
    frame.setSampleF32(0, 0, 0.25);
    frame.setSampleF32(1, 0, -0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), frame.getSampleF32(0, 0).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), frame.getSampleF32(1, 0).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), frame.durationSeconds(), 0.000001);
    try t.expect(test_allocator, frame.channel_layout).toEqual(.stereo);
}

fn runPacketWorkflowTests() !void {
    try t.describe(allocator, "Packet Workflows", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "clones encoded packets without aliasing storage", testPacketClone);
            try t.it(test_allocator, "falls back from invalid PTS to DTS", testPacketTimestampFallback);
        }
    }.register);
}

fn testPacketClone(test_allocator: std.mem.Allocator) !void {
    var packet = try video.Packet.fromData(allocator, .video, &.{ 0x00, 0x00, 0x01, 0x67 });
    defer packet.deinit();
    packet.flags.is_key_frame = true;
    packet.pts = video.Timestamp.fromMilliseconds(80);

    var cloned = try packet.clone();
    defer cloned.deinit();
    try t.expect(test_allocator, cloned.isKeyFrame()).toBeTruthy();
    try t.expect(test_allocator, cloned.getTimestamp().eql(packet.pts)).toBeTruthy();
    try t.expect(test_allocator, std.mem.eql(u8, cloned.data, packet.data)).toBeTruthy();

    cloned.data[3] = 0x68;
    try t.expect(test_allocator, cloned.data[3] != packet.data[3]).toBeTruthy();
}

fn testPacketTimestampFallback(test_allocator: std.mem.Allocator) !void {
    var packet = try video.Packet.init(allocator, .audio, 0);
    defer packet.deinit();
    packet.dts = video.Timestamp.fromMilliseconds(25);
    try t.expect(test_allocator, packet.pts.isValid()).toBeFalsy();
    try t.expect(test_allocator, packet.getTimestamp().eql(packet.dts)).toBeTruthy();
}

fn runMemoryIoTests() !void {
    try t.describe(allocator, "Memory I/O Workflows", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "writes and reads structured binary data", testMemoryIoRoundTrip);
            try t.it(test_allocator, "supports random-access patching", testMemoryIoPatching);
        }
    }.register);
}

fn testMemoryIoRoundTrip(test_allocator: std.mem.Allocator) !void {
    var buffer_target = video.BufferTarget.init(allocator);
    defer buffer_target.deinit();
    var target = buffer_target.target();
    try target.writeFourCC("ftyp".*);
    try target.writeU32Be(0x01020304);
    try target.writeU16Le(0x5060);

    var buffer_source = video.BufferSource.init(buffer_target.getData());
    var source = buffer_source.source();
    const fourcc = try source.readFourCC();
    try t.expect(test_allocator, std.mem.eql(u8, &fourcc, "ftyp")).toBeTruthy();
    try t.expect(test_allocator, try source.readU32Be()).toEqual(0x01020304);
    try t.expect(test_allocator, try source.readU16Le()).toEqual(0x5060);
    try t.expect(test_allocator, source.tell()).toEqual(10);
}

fn testMemoryIoPatching(test_allocator: std.mem.Allocator) !void {
    var buffer_target = video.BufferTarget.init(allocator);
    defer buffer_target.deinit();
    var target = buffer_target.target();
    try target.writeU32Be(0);
    try target.writeFourCC("mdat".*);
    _ = try target.seek(0, .start);
    try target.writeU32Be(8);
    try t.expect(test_allocator, std.mem.eql(u8, buffer_target.getData(), &.{ 0, 0, 0, 8, 'm', 'd', 'a', 't' })).toBeTruthy();
}

test "public Source.readAll respects its byte limit" {
    const data = "0123456789";
    var buffer_source = video.BufferSource.init(data);
    var source = buffer_source.source();

    const empty = try source.readAll(std.testing.allocator, 0);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(u64, 0), source.tell());

    const first = try source.readAll(std.testing.allocator, 4);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("0123", first);
    try std.testing.expectEqual(@as(u64, 4), source.tell());

    const rest = try source.readAll(std.testing.allocator, 16);
    defer std.testing.allocator.free(rest);
    try std.testing.expectEqualStrings("456789", rest);
}

test "public Source.readAll stops exactly after a partial second chunk" {
    var data: [8192 + 17]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var buffer_source = video.BufferSource.init(&data);
    var source = buffer_source.source();

    const first = try source.readAll(std.testing.allocator, 8192 + 3);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualSlices(u8, data[0 .. 8192 + 3], first);
    try std.testing.expectEqual(@as(u64, 8192 + 3), source.tell());

    const rest = try source.readAll(std.testing.allocator, 100);
    defer std.testing.allocator.free(rest);
    try std.testing.expectEqualSlices(u8, data[8192 + 3 ..], rest);
}

fn runFormatDetectionTests() !void {
    try t.describe(allocator, "Format Detection Workflows", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "maps media extensions to public formats", testExtensionDetection);
            try t.it(test_allocator, "detects EBML containers", testEbmlDetection);
        }
    }.register);
}

fn testExtensionDetection(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, video.VideoFormat.fromExtension(".MP4")).toEqual(.mp4);
    try t.expect(test_allocator, video.VideoFormat.fromExtension(".mkv")).toEqual(.mkv);
    try t.expect(test_allocator, video.AudioFormat.fromExtension(".WAV")).toEqual(.wav);
    try t.expect(test_allocator, video.VideoCodec.hevc.fourCC()).toEqual("hvc1".*);
    try t.expect(test_allocator, video.AudioCodec.flac.isLossless()).toBeTruthy();
}

fn testEbmlDetection(test_allocator: std.mem.Allocator) !void {
    const ebml_header = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x9F };
    try t.expect(test_allocator, video.isWebm(&ebml_header)).toBeTruthy();
    try t.expect(test_allocator, video.isMatroska(&ebml_header)).toBeTruthy();
    try t.expect(test_allocator, video.isWebm("not ebml")).toBeFalsy();
}

fn runStreamingTests() !void {
    try t.describe(allocator, "Streaming Workflows", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "parses a complete HLS media playlist", testHlsPlaylist);
        }
    }.register);
}

fn testHlsPlaylist(test_allocator: std.mem.Allocator) !void {
    const content =
        \\#EXTM3U
        \\#EXT-X-VERSION:3
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.0,
        \\segment0.ts
        \\#EXTINF:10.0,
        \\segment1.ts
        \\#EXT-X-ENDLIST
    ;
    var playlist = video.HlsPlaylist.init(allocator);
    defer playlist.deinit();
    try playlist.parse(content);

    try t.expect(test_allocator, playlist.segments.items.len).toEqual(2);
    try t.expect(test_allocator, playlist.end_list).toBeTruthy();
    try t.expect(test_allocator, video.isHls(content)).toBeTruthy();
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), playlist.getDuration(), 0.01);
}
