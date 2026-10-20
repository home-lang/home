const std = @import("std");
const video = @import("video");

test "public buffer and file sinks preserve byte order and ownership" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "sink.bin" });
    defer gpa.free(path);

    var buffer = video.BufferSink.init(gpa);
    defer buffer.deinit();
    try buffer.write("ab");
    try buffer.write("cd");
    try std.testing.expectEqualStrings("abcd", buffer.getBuffer());
    try std.testing.expectEqual(@as(usize, 4), buffer.getSize());

    var file = try video.FileSink.initWithIo(gpa, io, path);
    defer file.deinit();
    try file.write(buffer.getBuffer()[0..2]);
    try file.write(buffer.getBuffer()[2..]);
    try std.testing.expectEqual(@as(u64, 4), file.getBytesWritten());
    file.deinit();
    try std.testing.expectError(error.NotOpen, file.write("closed"));

    const actual = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(5));
    defer gpa.free(actual);
    try std.testing.expectEqualStrings("abcd", actual);

    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.getSize());
    try buffer.write("next");
    try std.testing.expectEqualStrings("next", buffer.getBuffer());

    var default_io_file = try video.FileSink.init(gpa, path);
    defer default_io_file.deinit();
    try default_io_file.write("z");
    try std.testing.expectEqual(@as(u64, 1), default_io_file.getBytesWritten());
    default_io_file.deinit();
    const replaced = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2));
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("z", replaced);
}

test "public frame and packet sinks retain ordered values" {
    const gpa = std.testing.allocator;
    var video_frame = try video.VideoFrame.init(gpa, 2, 2, .rgb24);
    defer video_frame.deinit();
    var frames = video.VideoFrameSink.init(gpa);
    defer frames.deinit();
    try frames.asVideoSink().writeFrame(video_frame);
    try std.testing.expectEqual(@as(usize, 1), frames.getFrames().len);
    try std.testing.expect(frames.getFrame(0).?.data.ptr == video_frame.data.ptr);
    try std.testing.expect(frames.getFrame(1) == null);

    var encoded = try video.Packet.fromData(gpa, .video, &.{ 0, 0, 1, 0x67 });
    defer encoded.deinit();
    var packets = video.EncodedPacketSink.init(gpa);
    defer packets.deinit();
    try packets.writePacket(encoded);
    try std.testing.expectEqual(@as(usize, 1), packets.getPackets().len);
    try std.testing.expectEqualSlices(u8, encoded.data, packets.getPacket(0).?.data);
    try std.testing.expect(packets.getPacket(1) == null);
}

test "public audio and waveform sinks preserve samples" {
    const gpa = std.testing.allocator;
    var audio_frame = try video.AudioFrame.init(gpa, 2, .f32p, 1, 8_000);
    defer audio_frame.deinit();
    audio_frame.setSampleF32(0, 0, 0.25);
    audio_frame.setSampleF32(0, 1, -0.5);

    var samples = video.AudioSampleSink.init(gpa, 8_000, 1);
    defer samples.deinit();
    try samples.asAudioSink().writeSamples(audio_frame);
    try std.testing.expectEqual(@as(usize, 2), samples.getFrameCount());
    try std.testing.expectEqualSlices(f32, &.{ 0.25, -0.5 }, samples.getSamples());

    var waveform = video.WaveformSink.init(gpa, 8_000, 1, 2);
    defer waveform.deinit();
    try waveform.asAudioSink().writeSamples(audio_frame);
    try std.testing.expectEqual(@as(usize, 1), waveform.getPeaks().len);
    try std.testing.expectEqual(@as(f32, -0.5), waveform.getPeaks()[0].min);
    try std.testing.expectEqual(@as(f32, 0.25), waveform.getPeaks()[0].max);
}
