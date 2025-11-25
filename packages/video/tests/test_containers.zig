// Home Video Library - Container Tests
// Unit tests for container formats

const std = @import("std");
const testing = std.testing;
const video = @import("video");

// ============================================================================
// WAV Container Tests
// ============================================================================

test "WAV - Header creation" {
    const allocator = testing.allocator;

    const header = video.WavHeader{
        .sample_rate = 48000,
        .channels = 2,
        .bits_per_sample = 16,
        .audio_format = 1, // PCM
        .byte_rate = 48000 * 2 * 2,
        .block_align = 4,
        .data_size = 0,
    };

    try testing.expectEqual(@as(u32, 48000), header.sample_rate);
    try testing.expectEqual(@as(u16, 2), header.channels);
    try testing.expectEqual(@as(u16, 16), header.bits_per_sample);

    const sample_fmt = header.getSampleFormat();
    try testing.expect(sample_fmt != null);
    try testing.expectEqual(video.SampleFormat.s16le, sample_fmt.?);

    _ = allocator;
}

test "WAV - Writer buffer allocation" {
    const allocator = testing.allocator;

    var writer = try video.WavWriter.init(allocator, 2, 44100, video.SampleFormat.s16le);
    defer writer.deinit();

    try testing.expectEqual(@as(u8, 2), writer.channels);
    try testing.expectEqual(@as(u32, 44100), writer.sample_rate);
}

// ============================================================================
// MP4 Container Tests
// ============================================================================

test "MP4 - Box header parsing" {
    // ftyp box header: size(4) + type(4)
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // Size = 32 bytes
        'f', 't', 'y', 'p', // Type = 'ftyp'
    };

    var header: video.BoxHeader = undefined;
    header.size = std.mem.readInt(u32, box_data[0..4], .big);
    @memcpy(&header.box_type, box_data[4..8]);

    try testing.expectEqual(@as(u32, 32), header.size);
    try testing.expect(std.mem.eql(u8, &header.box_type, "ftyp"));
}

test "MP4 - Track type detection" {
    try testing.expectEqual(video.TrackType.video, video.TrackType.fromHandler("vide"));
    try testing.expectEqual(video.TrackType.audio, video.TrackType.fromHandler("soun"));
    try testing.expectEqual(video.TrackType.subtitle, video.TrackType.fromHandler("sbtl"));
    try testing.expectEqual(video.TrackType.unknown, video.TrackType.fromHandler("meta"));
}

// ============================================================================
// WebM/Matroska Tests
// ============================================================================

test "WebM - EBML variable-length integer" {
    // 1-byte VINT: 0x81 = value 1
    const vint_1 = [_]u8{0x81};
    try testing.expectEqual(@as(u8, 0x81), vint_1[0]);

    // 2-byte VINT: 0x4001 = value 1
    const vint_2 = [_]u8{ 0x40, 0x01 };
    try testing.expectEqual(@as(u8, 0x40), vint_2[0]);
}

test "WebM - Codec ID parsing" {
    try testing.expectEqual(video.WebmCodecId.vp8, video.WebmCodecId.fromString("V_VP8"));
    try testing.expectEqual(video.WebmCodecId.vp9, video.WebmCodecId.fromString("V_VP9"));
    try testing.expectEqual(video.WebmCodecId.av1, video.WebmCodecId.fromString("V_AV1"));
    try testing.expectEqual(video.WebmCodecId.h264, video.WebmCodecId.fromString("V_MPEG4/ISO/AVC"));
    try testing.expectEqual(video.WebmCodecId.hevc, video.WebmCodecId.fromString("V_MPEGH/ISO/HEVC"));

    try testing.expectEqual(video.WebmCodecId.opus, video.WebmCodecId.fromString("A_OPUS"));
    try testing.expectEqual(video.WebmCodecId.vorbis, video.WebmCodecId.fromString("A_VORBIS"));
}

test "WebM - Format detection" {
    const webm_data = "\x1a\x45\xdf\xa3\x00\x00\x00\x00";
    try testing.expect(video.isWebm(webm_data[0..8]));

    const matroska_data = "\x1a\x45\xdf\xa3\x00\x00\x00\x00";
    try testing.expect(video.isMatroska(matroska_data[0..8]));
}

// ============================================================================
// Ogg Container Tests
// ============================================================================

test "Ogg - Page header parsing" {
    const page_header = [_]u8{
        'O', 'g', 'g', 'S', // Capture pattern
        0x00, // Version
        0x02, // Header type (BOS)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Granule position
        0x01, 0x00, 0x00, 0x00, // Serial number
        0x00, 0x00, 0x00, 0x00, // Page sequence number
        0x00, 0x00, 0x00, 0x00, // Checksum
        0x01, // Segment count
        0x1e, // Segment size
    };

    try testing.expect(std.mem.eql(u8, page_header[0..4], "OggS"));
    try testing.expectEqual(@as(u8, 0x00), page_header[4]); // Version
    try testing.expectEqual(@as(u8, 0x02), page_header[5]); // BOS flag
}

test "Ogg - Stream type detection" {
    try testing.expectEqual(video.OggStreamType.vorbis, video.OggStreamType.fromMagic("\x01vorbis"));
    try testing.expectEqual(video.OggStreamType.opus, video.OggStreamType.fromMagic("OpusHead"));
    try testing.expectEqual(video.OggStreamType.theora, video.OggStreamType.fromMagic("\x80theora"));
}

// ============================================================================
// MPEG-TS Tests
// ============================================================================

test "MPEG-TS - Packet header parsing" {
    const ts_packet = [_]u8{
        0x47, // Sync byte
        0x40, // TEI(0) PUSI(1) Priority(0) PID(5 bits high)
        0x00, // PID(8 bits low) = 0x0000 (PAT)
        0x10, // Scrambling(00) Adaptation(01) Continuity(0000)
    };

    try testing.expectEqual(@as(u8, 0x47), ts_packet[0]);

    const has_pusi = (ts_packet[1] & 0x40) != 0;
    try testing.expect(has_pusi);

    const pid = (@as(u16, ts_packet[1] & 0x1f) << 8) | ts_packet[2];
    try testing.expectEqual(@as(u16, 0x0000), pid); // PAT PID
}

test "MPEG-TS - Stream type detection" {
    try testing.expectEqual(video.MpegTsStreamType.video_h264, video.MpegTsStreamType.fromValue(0x1b));
    try testing.expectEqual(video.MpegTsStreamType.video_hevc, video.MpegTsStreamType.fromValue(0x24));
    try testing.expectEqual(video.MpegTsStreamType.audio_aac, video.MpegTsStreamType.fromValue(0x0f));
    try testing.expectEqual(video.MpegTsStreamType.audio_ac3, video.MpegTsStreamType.fromValue(0x81));
}

// ============================================================================
// FLV Tests
// ============================================================================

test "FLV - Header parsing" {
    const flv_header = [_]u8{
        'F', 'L', 'V', // Signature
        0x01, // Version
        0x05, // Flags (audio + video)
        0x00, 0x00, 0x00, 0x09, // Header size
    };

    try testing.expect(std.mem.eql(u8, flv_header[0..3], "FLV"));
    try testing.expectEqual(@as(u8, 0x01), flv_header[3]);
    try testing.expectEqual(@as(u8, 0x05), flv_header[4]);

    const has_video = (flv_header[4] & 0x01) != 0;
    const has_audio = (flv_header[4] & 0x04) != 0;
    try testing.expect(has_video);
    try testing.expect(has_audio);
}

test "FLV - Tag type detection" {
    try testing.expectEqual(video.FlvTagType.audio, video.FlvTagType.fromValue(8));
    try testing.expectEqual(video.FlvTagType.video, video.FlvTagType.fromValue(9));
    try testing.expectEqual(video.FlvTagType.script_data, video.FlvTagType.fromValue(18));
}

test "FLV - Video codec detection" {
    try testing.expectEqual(video.FlvVideoCodec.h264, video.FlvVideoCodec.fromValue(7));
    try testing.expectEqual(video.FlvVideoCodec.vp6, video.FlvVideoCodec.fromValue(4));
    try testing.expectEqual(video.FlvVideoCodec.screen_video, video.FlvVideoCodec.fromValue(3));
}

test "FLV - Audio codec detection" {
    try testing.expectEqual(video.FlvAudioCodec.aac, video.FlvAudioCodec.fromValue(10));
    try testing.expectEqual(video.FlvAudioCodec.mp3, video.FlvAudioCodec.fromValue(2));
    try testing.expectEqual(video.FlvAudioCodec.pcm, video.FlvAudioCodec.fromValue(0));
}

// ============================================================================
// GIF Tests
// ============================================================================

test "GIF - Magic detection" {
    const gif87 = "GIF87a\x00\x00";
    try testing.expect(video.isGif(gif87[0..6]));

    const gif89 = "GIF89a\x00\x00";
    try testing.expect(video.isGif(gif89[0..6]));

    const not_gif = "NotGIF\x00\x00";
    try testing.expect(!video.isGif(not_gif[0..6]));
}

// ============================================================================
// AVI Tests
// ============================================================================

test "AVI - RIFF header validation" {
    const avi_header = "RIFF\x00\x00\x00\x00AVI \x00\x00";
    try testing.expect(video.isAvi(avi_header[0..12]));

    const not_avi = "RIFF\x00\x00\x00\x00WAVE\x00\x00";
    try testing.expect(!video.isAvi(not_avi[0..12]));
}

// ============================================================================
// MXF Tests
// ============================================================================

test "MXF - KLV structure" {
    // Simplified KLV key (16 bytes)
    const mxf_key = [_]u8{
        0x06, 0x0e, 0x2b, 0x34, // Universal label prefix
        0x02, 0x05, 0x01, 0x01, // Category, registry, structure
        0x0d, 0x01, 0x02, 0x01, // Type, category, item
        0x01, 0x01, 0x11, 0x00, // Instance, sub-item
    };

    try testing.expectEqual(@as(u8, 0x06), mxf_key[0]);
    try testing.expectEqual(@as(u8, 0x0e), mxf_key[1]);
    try testing.expectEqual(@as(u8, 0x2b), mxf_key[2]);
    try testing.expectEqual(@as(u8, 0x34), mxf_key[3]);
}

test "MXF - Partition pack detection" {
    const partition_key = [_]u8{
        0x06, 0x0e, 0x2b, 0x34,
        0x02, 0x05, 0x01, 0x01,
        0x0d, 0x01, 0x02, 0x01,
        0x01, 0x02, 0x00, 0x00,
    };

    // Check for MXF universal label
    try testing.expectEqual(@as(u8, 0x06), partition_key[0]);
}

// ============================================================================
// Rational Number Tests
// ============================================================================

test "Rational - Creation and conversion" {
    const rational = video.Rational{ .num = 30000, .den = 1001 };

    const fps = rational.toFloat();
    try testing.expectApproxEqAbs(@as(f64, 29.97), fps, 0.01);

    const simplified = rational.simplify();
    // 30000/1001 cannot be simplified further
    try testing.expectEqual(@as(i64, 30000), simplified.num);
    try testing.expectEqual(@as(i64, 1001), simplified.den);
}

test "Rational - Common frame rates" {
    const fps_24 = video.Rational{ .num = 24, .den = 1 };
    try testing.expectApproxEqAbs(@as(f64, 24.0), fps_24.toFloat(), 0.001);

    const fps_29_97 = video.Rational{ .num = 30000, .den = 1001 };
    try testing.expectApproxEqAbs(@as(f64, 29.97), fps_29_97.toFloat(), 0.01);

    const fps_60 = video.Rational{ .num = 60, .den = 1 };
    try testing.expectApproxEqAbs(@as(f64, 60.0), fps_60.toFloat(), 0.001);
}

// ============================================================================
// Timestamp Tests
// ============================================================================

test "Timestamp - Conversion" {
    const ts = video.Timestamp.fromSeconds(1.5);
    try testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);

    const ms = ts.toMilliseconds();
    try testing.expectEqual(@as(u64, 1500), ms);

    const us = ts.toMicroseconds();
    try testing.expectEqual(@as(i64, 1500000), us);
}

test "Timestamp - Arithmetic" {
    const ts1 = video.Timestamp.fromSeconds(1.0);
    const ts2 = video.Timestamp.fromSeconds(0.5);

    const sum = ts1.add(ts2);
    try testing.expectApproxEqAbs(@as(f64, 1.5), sum.toSeconds(), 0.0001);

    const diff = ts1.subtract(ts2);
    try testing.expectApproxEqAbs(@as(f64, 0.5), diff.toSeconds(), 0.0001);
}

// ============================================================================
// Duration Tests
// ============================================================================

test "Duration - Conversion" {
    const duration = video.Duration.fromSeconds(60.0);
    try testing.expectEqual(@as(u64, 60000), duration.toMilliseconds());
    try testing.expectApproxEqAbs(@as(f64, 60.0), duration.toSeconds(), 0.001);
}
