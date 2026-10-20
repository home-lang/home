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

test "public file source and target preserve relative and end seeks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator_tmp = std.testing.allocator;
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator_tmp);
    defer allocator_tmp.free(root_path);
    const path = try std.fs.path.join(allocator_tmp, &.{ root_path, "sample.bin" });
    defer allocator_tmp.free(path);
    try std.testing.expectError(video.VideoError.FileNotFound, video.FileSource.open(io, path));

    {
        var file_target = try video.FileTarget.create(io, path);
        defer file_target.close();
        var target = file_target.target();
        try target.write("abcde");
        try std.testing.expectEqual(@as(u64, 3), try target.seek(-2, .current));
        try target.write("XY");
        try std.testing.expectEqual(@as(u64, 5), try target.seek(0, .end));
        try target.write("!");
        try std.testing.expectEqual(@as(u64, 6), target.tell());
        try std.testing.expectError(video.VideoError.SeekOutOfRange, target.seek(-1, .start));
        try target.flush();
    }

    var file_source = try video.FileSource.open(io, path);
    defer file_source.close();
    var source = file_source.source();
    try std.testing.expectEqual(@as(?u64, 6), source.size());
    var first: [3]u8 = undefined;
    try source.readExact(&first);
    try std.testing.expectEqualStrings("abc", &first);
    try std.testing.expectEqual(@as(u64, 2), try source.seek(-1, .current));
    var middle: [3]u8 = undefined;
    try source.readExact(&middle);
    try std.testing.expectEqualStrings("cXY", &middle);
    try std.testing.expectEqual(@as(u64, 4), try source.seek(-2, .end));
    var last: [2]u8 = undefined;
    try source.readExact(&last);
    try std.testing.expectEqualStrings("Y!", &last);
    var eof: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try source.read(&eof));
    try std.testing.expectError(video.VideoError.SeekOutOfRange, source.seek(-1, .start));
}

test "public WAV disk APIs round trip owned samples" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "samples.wav" });
    defer gpa.free(path);
    const copy_path = try std.fs.path.join(gpa, &.{ root, "copy.wav" });
    defer gpa.free(copy_path);
    const missing = try std.fs.path.join(gpa, &.{ root, "missing.wav" });
    defer gpa.free(missing);

    try std.testing.expectError(video.VideoError.FileNotFound, video.WavReader.fromFileWithIo(gpa, io, missing));

    var writer = try video.WavWriter.init(gpa, 1, 8_000, .s16le);
    defer writer.deinit();
    const samples = [_]u8{ 0x01, 0x00, 0xfe, 0xff };
    try writer.writeSamples(&samples);
    try writer.writeToFileWithIo(io, path);

    var borrowed_reader = try video.WavReader.fromMemory(gpa, try writer.getData());
    borrowed_reader.deinit();

    var reader = try video.WavReader.fromFileWithIo(gpa, io, path);
    defer reader.deinit();
    try std.testing.expectEqual(@as(u64, 2), reader.header.getTotalSamples());
    var frame = (try reader.readFrames(2)) orelse return error.MissingAudioFrame;
    defer frame.deinit();
    try std.testing.expectEqualSlices(u8, &samples, frame.data);

    var audio = try video.Audio.loadWithIo(gpa, io, path);
    defer audio.deinit();
    try std.testing.expectEqual(@as(usize, 1), audio.frames.items.len);
    try std.testing.expectEqualSlices(u8, &samples, audio.frames.items[0].data);

    var memory_audio = try video.Audio.loadFromMemory(gpa, try writer.getData());
    defer memory_audio.deinit();
    try std.testing.expectEqualSlices(u8, &samples, memory_audio.frames.items[0].data);

    try audio.saveWithIo(io, copy_path);
    var copied = try video.Audio.load(gpa, copy_path);
    defer copied.deinit();
    try std.testing.expectEqualSlices(u8, &samples, copied.frames.items[0].data);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = copy_path, .data = "invalid WAV data" });
    try std.testing.expectError(video.VideoError.TruncatedData, video.WavReader.fromFileWithIo(gpa, io, copy_path));
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
