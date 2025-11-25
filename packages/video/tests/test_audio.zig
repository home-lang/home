// Home Video Library - Audio Tests
// Unit tests for audio processing functionality

const std = @import("std");
const testing = std.testing;
const video = @import("video");

test "Audio - WAV header parsing" {
    const allocator = testing.allocator;

    // Create minimal WAV header
    const wav_header = [_]u8{
        'R', 'I', 'F', 'F', // ChunkID
        36, 0, 0, 0, // ChunkSize (36 + data size)
        'W', 'A', 'V', 'E', // Format
        'f', 'm', 't', ' ', // Subchunk1ID
        16, 0, 0, 0, // Subchunk1Size
        1, 0, // AudioFormat (PCM)
        2, 0, // NumChannels (stereo)
        0x44, 0xac, 0, 0, // SampleRate (44100)
        0x10, 0xb1, 0x02, 0, // ByteRate
        4, 0, // BlockAlign
        16, 0, // BitsPerSample
        'd', 'a', 't', 'a', // Subchunk2ID
        0, 0, 0, 0, // Subchunk2Size
    };

    var reader = try video.WavReader.fromMemory(allocator, &wav_header);
    defer reader.deinit();

    try testing.expectEqual(@as(u32, 44100), reader.header.sample_rate);
    try testing.expectEqual(@as(u16, 2), reader.header.channels);
    try testing.expectEqual(@as(u16, 16), reader.header.bits_per_sample);
}

test "Audio - PCM sample conversion" {
    const allocator = testing.allocator;

    // Test S16LE to F32LE conversion
    const input: [4]i16 = .{ 0, 16384, -16384, 32767 };
    const output = try allocator.alloc(f32, 4);
    defer allocator.free(output);

    try video.convertSamples(
        @ptrCast(&input),
        output.ptr,
        4,
        video.SampleFormat.s16le,
        video.SampleFormat.f32le,
    );

    try testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), output[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[3], 0.001);
}

test "Audio - A-law encoding/decoding" {
    // Test A-law compression
    const sample: i16 = 1000;
    const alaw = video.encodeAlaw(sample);
    const decoded = video.decodeAlaw(alaw);

    // A-law is lossy, so allow some error
    const diff = @abs(sample - decoded);
    try testing.expect(diff < 100);
}

test "Audio - μ-law encoding/decoding" {
    // Test μ-law compression
    const sample: i16 = -2000;
    const ulaw = video.encodeUlaw(sample);
    const decoded = video.decodeUlaw(ulaw);

    // μ-law is lossy, so allow some error
    const diff = @abs(sample - decoded);
    try testing.expect(diff < 100);
}

test "Audio - Interleaved to planar conversion" {
    const allocator = testing.allocator;

    // Stereo interleaved: L R L R
    const interleaved = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const planar = try allocator.alloc(f32, 4);
    defer allocator.free(planar);

    video.interleavedToPlanar(f32, &interleaved, planar, 2, 2);

    // Expected planar: L L R R
    try testing.expectEqual(@as(f32, 1.0), planar[0]);
    try testing.expectEqual(@as(f32, 3.0), planar[1]);
    try testing.expectEqual(@as(f32, 2.0), planar[2]);
    try testing.expectEqual(@as(f32, 4.0), planar[3]);
}

test "Audio - Planar to interleaved conversion" {
    const allocator = testing.allocator;

    // Stereo planar: L L R R
    const planar = [_]f32{ 1.0, 3.0, 2.0, 4.0 };
    const interleaved = try allocator.alloc(f32, 4);
    defer allocator.free(interleaved);

    video.planarToInterleaved(f32, &planar, interleaved, 2, 2);

    // Expected interleaved: L R L R
    try testing.expectEqual(@as(f32, 1.0), interleaved[0]);
    try testing.expectEqual(@as(f32, 2.0), interleaved[1]);
    try testing.expectEqual(@as(f32, 3.0), interleaved[2]);
    try testing.expectEqual(@as(f32, 4.0), interleaved[3]);
}

test "Audio - AAC ADTS header parsing" {
    const adts_header = [_]u8{
        0xff, // Sync word (12 bits)
        0xf1, // Sync + ID + layer + protection
        0x50, // Profile + freq + channel
        0x80, // Channel + frame length
        0x00, // Frame length
        0x1f, // Frame length + buffer
        0xfc, // Buffer + frames
    };

    var parser = video.AdtsParser{};
    const header = parser.parse(&adts_header) catch |err| {
        std.debug.print("Failed to parse ADTS: {}\n", .{err});
        return err;
    };

    try testing.expectEqual(video.AudioObjectType.aac_lc, header.profile);
    try testing.expectEqual(@as(u8, 2), header.channels);
}

test "Audio - Opus packet TOC parsing" {
    // Opus packet with TOC byte
    const opus_packet = [_]u8{
        0x78, // TOC byte: config=15, stereo=0, frame_count=0
        0x00, // Payload...
    };

    const toc = video.OpusPacketToc.parse(opus_packet[0]);

    try testing.expectEqual(@as(u5, 15), toc.config);
    try testing.expect(!toc.is_stereo);
    try testing.expectEqual(@as(u2, 0), toc.frame_count_code);
}

test "Audio - FLAC magic detection" {
    const valid_flac = "fLaC\x00\x00\x00\x22";
    const invalid_data = "NotFLAC\x00\x00";

    try testing.expect(video.isFlac(valid_flac[0..8]));
    try testing.expect(!video.isFlac(invalid_data[0..8]));
}

test "Audio - MP3 magic detection" {
    // MP3 with ID3v2
    const mp3_id3 = "ID3\x04\x00\x00\x00\x00\x00\x00";
    try testing.expect(video.isMp3(mp3_id3[0..10]));

    // MP3 frame sync
    const mp3_frame = "\xff\xfb\x90\x00\x00\x00\x00\x00";
    try testing.expect(video.isMp3(mp3_frame[0..8]));
}

test "Audio - Channel layout mono" {
    const layout = video.ChannelLayout.mono;
    try testing.expectEqual(@as(u8, 1), layout.channelCount());
}

test "Audio - Channel layout stereo" {
    const layout = video.ChannelLayout.stereo;
    try testing.expectEqual(@as(u8, 2), layout.channelCount());
}

test "Audio - Channel layout 5.1" {
    const layout = video.ChannelLayout.surround_5_1;
    try testing.expectEqual(@as(u8, 6), layout.channelCount());
}

test "Audio - Sample format byte size" {
    try testing.expectEqual(@as(u8, 1), video.SampleFormat.u8.bytesPerSample());
    try testing.expectEqual(@as(u8, 2), video.SampleFormat.s16le.bytesPerSample());
    try testing.expectEqual(@as(u8, 4), video.SampleFormat.s32le.bytesPerSample());
    try testing.expectEqual(@as(u8, 4), video.SampleFormat.f32le.bytesPerSample());
    try testing.expectEqual(@as(u8, 8), video.SampleFormat.f64le.bytesPerSample());
}

test "Audio - Volume filter" {
    const allocator = testing.allocator;

    var frame = try video.AudioFrame.init(allocator, 1, 100, video.SampleFormat.f32le, 48000);
    defer frame.deinit();

    // Fill with test data
    const data: [*]f32 = @ptrCast(@alignCast(frame.data[0].ptr));
    for (0..100) |i| {
        data[i] = 0.5;
    }

    var filter = video.VolumeFilter{ .gain_db = 6.0 };
    var result = try filter.apply(allocator, &frame);
    defer result.deinit();

    // 6dB = 2x amplitude
    const result_data: [*]f32 = @ptrCast(@alignCast(result.data[0].ptr));
    try testing.expectApproxEqAbs(@as(f32, 1.0), result_data[0], 0.01);
}

test "Audio - Normalize filter" {
    const allocator = testing.allocator;

    var frame = try video.AudioFrame.init(allocator, 1, 100, video.SampleFormat.f32le, 48000);
    defer frame.deinit();

    // Fill with test data (peak at 0.5)
    const data: [*]f32 = @ptrCast(@alignCast(frame.data[0].ptr));
    for (0..100) |i| {
        data[i] = if (i == 50) 0.5 else 0.1;
    }

    var filter = video.NormalizeFilter{ .target_peak = 1.0 };
    var result = try filter.apply(allocator, &frame);
    defer result.deinit();

    // Should scale to peak of 1.0
    const result_data: [*]f32 = @ptrCast(@alignCast(result.data[0].ptr));
    try testing.expectApproxEqAbs(@as(f32, 1.0), result_data[50], 0.01);
}
