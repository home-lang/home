// Home Video Library - Codec Tests
// Unit tests for video and audio codecs

const std = @import("std");
const testing = std.testing;
const video = @import("video");

// ============================================================================
// H.264/AVC Tests
// ============================================================================

test "H.264 - NAL unit type detection" {
    const nal_sps: u8 = 0x67; // NAL header for SPS
    const nal_type = video.H264NalUnitType.fromByte(nal_sps);
    try testing.expectEqual(video.H264NalUnitType.sps, nal_type);

    const nal_pps: u8 = 0x68; // NAL header for PPS
    const pps_type = video.H264NalUnitType.fromByte(nal_pps);
    try testing.expectEqual(video.H264NalUnitType.pps, pps_type);

    const nal_idr: u8 = 0x65; // NAL header for IDR
    const idr_type = video.H264NalUnitType.fromByte(nal_idr);
    try testing.expectEqual(video.H264NalUnitType.coded_slice_idr, idr_type);
}

test "H.264 - Start code detection" {
    const data_with_start = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x67 };
    const pos = video.findStartCode(&data_with_start, 0);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 0), pos.?);

    const data_no_start = [_]u8{ 0x00, 0x00, 0x01, 0x67 }; // 3-byte start code
    const pos2 = video.findStartCode(&data_no_start, 0);
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(usize, 0), pos2.?);
}

test "H.264 - Emulation prevention" {
    const allocator = testing.allocator;

    const input = [_]u8{ 0x00, 0x00, 0x03, 0x00 };
    const output = try video.removeEmulationPrevention(allocator, &input);
    defer allocator.free(output);

    // Should remove the 0x03 byte
    try testing.expectEqual(@as(usize, 3), output.len);
    try testing.expectEqual(@as(u8, 0x00), output[0]);
    try testing.expectEqual(@as(u8, 0x00), output[1]);
    try testing.expectEqual(@as(u8, 0x00), output[2]);
}

test "H.264 - Add emulation prevention" {
    const allocator = testing.allocator;

    const input = [_]u8{ 0x00, 0x00, 0x00 };
    const output = try video.addEmulationPrevention(allocator, &input);
    defer allocator.free(output);

    // Should add 0x03 byte
    try testing.expectEqual(@as(usize, 4), output.len);
    try testing.expectEqual(@as(u8, 0x00), output[0]);
    try testing.expectEqual(@as(u8, 0x00), output[1]);
    try testing.expectEqual(@as(u8, 0x03), output[2]);
    try testing.expectEqual(@as(u8, 0x00), output[3]);
}

// ============================================================================
// H.265/HEVC Tests
// ============================================================================

test "HEVC - NAL unit type detection" {
    // HEVC VPS NAL unit header (2 bytes)
    const nal_vps: u16 = (32 << 9); // Type 32 = VPS
    const nal_type = video.HevcNalUnitType.fromHeader(nal_vps);
    try testing.expectEqual(video.HevcNalUnitType.vps, nal_type);

    const nal_sps: u16 = (33 << 9); // Type 33 = SPS
    const sps_type = video.HevcNalUnitType.fromHeader(nal_sps);
    try testing.expectEqual(video.HevcNalUnitType.sps, sps_type);

    const nal_idr: u16 = (19 << 9); // Type 19 = IDR_W_RADL
    const idr_type = video.HevcNalUnitType.fromHeader(nal_idr);
    try testing.expectEqual(video.HevcNalUnitType.idr_w_radl, idr_type);
}

// ============================================================================
// VP9 Tests
// ============================================================================

test "VP9 - Superframe index parsing" {
    // Superframe with 2 frames
    const superframe_marker: u8 = 0xc0 | (2 - 1); // 2 frames
    const frame_sizes = [_]u8{
        100, 0, 0, // Frame 1 size (100 bytes, 3-byte encoding)
        200, 0, 0, // Frame 2 size (200 bytes)
        superframe_marker,
    };

    const index = video.parseSuperframeIndex(&frame_sizes) catch |err| {
        std.debug.print("Failed to parse superframe: {}\n", .{err});
        return err;
    };

    try testing.expectEqual(@as(u8, 2), index.frame_count);
    try testing.expectEqual(@as(u32, 100), index.frame_sizes[0]);
    try testing.expectEqual(@as(u32, 200), index.frame_sizes[1]);
}

test "VP9 - Frame type detection" {
    // Key frame marker
    const key_frame: u8 = 0x00; // bit 0 = 0 means key frame
    try testing.expect((key_frame & 0x01) == 0);

    // Inter frame marker
    const inter_frame: u8 = 0x01; // bit 0 = 1 means inter frame
    try testing.expect((inter_frame & 0x01) == 1);
}

// ============================================================================
// AV1 Tests
// ============================================================================

test "AV1 - OBU type detection" {
    const obu_seq_header: u8 = (1 << 3); // OBU_SEQUENCE_HEADER = 1
    const obu_type: video.Av1ObuType = @enumFromInt((obu_seq_header >> 3) & 0x0f);
    try testing.expectEqual(video.Av1ObuType.sequence_header, obu_type);

    const obu_frame: u8 = (6 << 3); // OBU_FRAME = 6
    const frame_type: video.Av1ObuType = @enumFromInt((obu_frame >> 3) & 0x0f);
    try testing.expectEqual(video.Av1ObuType.frame, frame_type);
}

test "AV1 - Level detection" {
    try testing.expectEqual(video.Av1Level.level_2_0, video.Av1Level.fromValue(0));
    try testing.expectEqual(video.Av1Level.level_4_0, video.Av1Level.fromValue(4));
    try testing.expectEqual(video.Av1Level.level_6_0, video.Av1Level.fromValue(12));
}

// ============================================================================
// VVC/H.266 Tests
// ============================================================================

test "VVC - NAL unit type detection" {
    // VVC VPS (type 14)
    const nal_vps: u8 = (14 << 3);
    const vps_type = video.VvcNalUnitType.fromByte(nal_vps);
    try testing.expectEqual(video.VvcNalUnitType.vps, vps_type);

    // VVC SPS (type 15)
    const nal_sps: u8 = (15 << 3);
    const sps_type = video.VvcNalUnitType.fromByte(nal_sps);
    try testing.expectEqual(video.VvcNalUnitType.sps, sps_type);

    // VVC IDR (type 8)
    const nal_idr: u8 = (8 << 3);
    const idr_type = video.VvcNalUnitType.fromByte(nal_idr);
    try testing.expectEqual(video.VvcNalUnitType.idr_n_lp, idr_type);
}

test "VVC - Profile detection" {
    try testing.expectEqual(video.VvcProfile.main_10, video.VvcProfile.fromValue(1));
    try testing.expectEqual(video.VvcProfile.main_10_444, video.VvcProfile.fromValue(3));
}

// ============================================================================
// Container Format Tests
// ============================================================================

test "MP4 - Box type parsing" {
    const ftyp_bytes = "ftyp";
    var box_type: video.BoxType = undefined;
    @memcpy(&box_type, ftyp_bytes[0..4]);

    try testing.expect(std.mem.eql(u8, &box_type, "ftyp"));
}

test "WebM - Element ID detection" {
    try testing.expectEqual(video.WebmElementId.ebml, video.WebmElementId.fromValue(0x1a45dfa3));
    try testing.expectEqual(video.WebmElementId.segment, video.WebmElementId.fromValue(0x18538067));
    try testing.expectEqual(video.WebmElementId.cluster, video.WebmElementId.fromValue(0x1f43b675));
}

test "WebM - Magic detection" {
    const webm_magic = "\x1a\x45\xdf\xa3"; // EBML header
    try testing.expect(video.isWebm(webm_magic[0..4]));

    const not_webm = "NotWebM!";
    try testing.expect(!video.isWebm(not_webm[0..8]));
}

test "Ogg - Magic detection" {
    const ogg_magic = "OggS\x00";
    try testing.expect(video.isOgg(ogg_magic[0..5]));

    const not_ogg = "NotOgg!";
    try testing.expect(!video.isOgg(not_ogg[0..7]));
}

test "MPEG-TS - Sync byte detection" {
    const ts_packet = [_]u8{0x47}; // 0x47 is sync byte
    try testing.expectEqual(@as(u8, 0x47), ts_packet[0]);

    const data = "\x47\x40\x00\x10"; // TS packet start
    try testing.expect(video.isMpegTs(data[0..4]));
}

test "FLV - Magic detection" {
    const flv_header = "FLV\x01";
    const data = flv_header[0..4];

    try testing.expect(std.mem.eql(u8, data[0..3], "FLV"));
    try testing.expectEqual(@as(u8, 0x01), data[3]);
}

test "AVI - RIFF header detection" {
    const avi_header = "RIFF\x00\x00\x00\x00AVI ";
    try testing.expect(video.isAvi(avi_header[0..12]));

    const not_avi = "NotAVI!!";
    try testing.expect(!video.isAvi(not_avi[0..8]));
}

// ============================================================================
// Bitstream Reader Tests
// ============================================================================

test "Bitstream - Read bits" {
    const allocator = testing.allocator;

    const data = [_]u8{ 0b10110011, 0b01001101 };
    var reader = video.BitstreamReader.init(allocator, &data);

    const bit1 = try reader.readBit();
    try testing.expectEqual(@as(u1, 1), bit1);

    const bits3 = try reader.readBits(u3, 3);
    try testing.expectEqual(@as(u3, 0b011), bits3);

    const bits4 = try reader.readBits(u4, 4);
    try testing.expectEqual(@as(u4, 0b0011), bits4);
}

test "Bitstream - Exp-Golomb unsigned" {
    const allocator = testing.allocator;

    // Exp-Golomb code for 0: "1"
    const data_0 = [_]u8{0x80}; // 1000_0000
    var reader_0 = video.BitstreamReader.init(allocator, &data_0);
    const val_0 = try reader_0.readExpGolomb(u32);
    try testing.expectEqual(@as(u32, 0), val_0);

    // Exp-Golomb code for 1: "010"
    const data_1 = [_]u8{0x40}; // 0100_0000
    var reader_1 = video.BitstreamReader.init(allocator, &data_1);
    const val_1 = try reader_1.readExpGolomb(u32);
    try testing.expectEqual(@as(u32, 1), val_1);

    // Exp-Golomb code for 2: "011"
    const data_2 = [_]u8{0x60}; // 0110_0000
    var reader_2 = video.BitstreamReader.init(allocator, &data_2);
    const val_2 = try reader_2.readExpGolomb(u32);
    try testing.expectEqual(@as(u32, 2), val_2);
}

test "Bitstream - Write bits" {
    const allocator = testing.allocator;

    var writer = video.BitstreamWriter.init(allocator);
    defer writer.deinit();

    try writer.writeBit(1);
    try writer.writeBits(u3, 0b011, 3);
    try writer.writeBits(u4, 0b0011, 4);

    const data = try writer.finalize();
    defer allocator.free(data);

    try testing.expectEqual(@as(u8, 0b10110011), data[0]);
}
