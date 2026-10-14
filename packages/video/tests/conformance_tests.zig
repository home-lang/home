// Home Video Library - Conformance Tests
// Validate public codec and container constants against their specifications.

const std = @import("std");
const video = @import("video");
const t = @import("test_framework");

var debug_allocator = std.heap.DebugAllocator(.{}).init;
const allocator = debug_allocator.allocator();

test "conformance tests" {
    defer {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak) std.debug.print("Memory leak detected!\n", .{});
    }
    defer t.cleanupRegistry();

    try runH264ConformanceTests();
    try runHevcConformanceTests();
    try runContainerConformanceTests();
    try runColorConformanceTests();

    const registry = t.getRegistry(allocator);
    const success = try t.runTests(allocator, registry);
    try std.testing.expect(success);
}

fn runH264ConformanceTests() !void {
    try t.describe(allocator, "H.264 Conformance Tests", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "uses standardized profile identifiers", testH264Profiles);
            try t.it(test_allocator, "uses standardized NAL unit identifiers", testH264NalUnitTypes);
            try t.it(test_allocator, "round-trips NAL unit headers", testH264NalHeader);
        }
    }.register);
}

fn testH264Profiles(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, @intFromEnum(video.h264.Profile.baseline)).toEqual(66);
    try t.expect(test_allocator, @intFromEnum(video.h264.Profile.main)).toEqual(77);
    try t.expect(test_allocator, @intFromEnum(video.h264.Profile.high)).toEqual(100);
    try t.expect(test_allocator, @intFromEnum(video.h264.Profile.high_10)).toEqual(110);
}

fn testH264NalUnitTypes(test_allocator: std.mem.Allocator) !void {
    const nal = video.h264.NalUnitType;
    try t.expect(test_allocator, @intFromEnum(nal.slice_non_idr)).toEqual(1);
    try t.expect(test_allocator, @intFromEnum(nal.slice_idr)).toEqual(5);
    try t.expect(test_allocator, @intFromEnum(nal.sei)).toEqual(6);
    try t.expect(test_allocator, @intFromEnum(nal.sps)).toEqual(7);
    try t.expect(test_allocator, @intFromEnum(nal.pps)).toEqual(8);
    try t.expect(test_allocator, nal.slice_idr.isKeyframe()).toBeTruthy();
    try t.expect(test_allocator, nal.sps.isVcl()).toBeFalsy();
}

fn testH264NalHeader(test_allocator: std.mem.Allocator) !void {
    var header = video.h264.NalUnitHeader.parse(0x67);
    try t.expect(test_allocator, header.forbidden_zero_bit).toEqual(0);
    try t.expect(test_allocator, header.nal_ref_idc).toEqual(3);
    try t.expect(test_allocator, header.nal_unit_type).toEqual(.sps);
    try t.expect(test_allocator, header.isReference()).toBeTruthy();
    try t.expect(test_allocator, header.toByte()).toEqual(0x67);
}

fn runHevcConformanceTests() !void {
    try t.describe(allocator, "HEVC Conformance Tests", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "uses standardized profile identifiers", testHevcProfiles);
            try t.it(test_allocator, "uses standardized NAL unit identifiers", testHevcNalUnitTypes);
            try t.it(test_allocator, "round-trips NAL unit headers", testHevcNalHeader);
        }
    }.register);
}

fn testHevcProfiles(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, @intFromEnum(video.hevc.Profile.main)).toEqual(1);
    try t.expect(test_allocator, @intFromEnum(video.hevc.Profile.main_10)).toEqual(2);
    try t.expect(test_allocator, @intFromEnum(video.hevc.Profile.main_still_picture)).toEqual(3);
}

fn testHevcNalUnitTypes(test_allocator: std.mem.Allocator) !void {
    const nal = video.hevc.NalUnitType;
    try t.expect(test_allocator, @intFromEnum(nal.idr_w_radl)).toEqual(19);
    try t.expect(test_allocator, @intFromEnum(nal.idr_n_lp)).toEqual(20);
    try t.expect(test_allocator, @intFromEnum(nal.vps)).toEqual(32);
    try t.expect(test_allocator, @intFromEnum(nal.sps)).toEqual(33);
    try t.expect(test_allocator, @intFromEnum(nal.pps)).toEqual(34);
    try t.expect(test_allocator, nal.idr_w_radl.isKeyframe()).toBeTruthy();
    try t.expect(test_allocator, nal.sps.isVcl()).toBeFalsy();
}

fn testHevcNalHeader(test_allocator: std.mem.Allocator) !void {
    var header = try video.hevc.NalUnitHeader.parse(&.{ 0x40, 0x01 });
    const bytes = header.toBytes();
    try t.expect(test_allocator, header.forbidden_zero_bit).toEqual(0);
    try t.expect(test_allocator, header.nal_unit_type).toEqual(.vps);
    try t.expect(test_allocator, header.nuh_layer_id).toEqual(0);
    try t.expect(test_allocator, header.temporalId()).toEqual(0);
    try t.expect(test_allocator, std.mem.eql(u8, &bytes, &.{ 0x40, 0x01 })).toBeTruthy();
}

fn runContainerConformanceTests() !void {
    try t.describe(allocator, "Container Conformance Tests", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "round-trips ISO BMFF FourCC values", testMp4BoxTypes);
            try t.it(test_allocator, "uses EBML element identifiers", testEbmlElementIds);
            try t.it(test_allocator, "uses Matroska track and codec identifiers", testMatroskaIdentifiers);
            try t.it(test_allocator, "uses MPEG-TS packet and stream identifiers", testMpegTsIdentifiers);
        }
    }.register);
}

fn testMp4BoxTypes(test_allocator: std.mem.Allocator) !void {
    const box_types = [_]video.mp4.BoxType{ .ftyp, .moov, .mdat, .trak, .stbl };
    for (box_types) |box_type| {
        const bytes = box_type.toBytes();
        try t.expect(test_allocator, video.mp4.BoxType.fromBytes(bytes)).toEqual(box_type);
    }
    const ftyp = video.mp4.BoxType.ftyp.toBytes();
    try t.expect(test_allocator, std.mem.eql(u8, &ftyp, "ftyp")).toBeTruthy();
}

fn testEbmlElementIds(test_allocator: std.mem.Allocator) !void {
    const element = video.webm.ElementId;
    try t.expect(test_allocator, @intFromEnum(element.ebml)).toEqual(0x1A45DFA3);
    try t.expect(test_allocator, @intFromEnum(element.segment)).toEqual(0x18538067);
    try t.expect(test_allocator, @intFromEnum(element.tracks)).toEqual(0x1654AE6B);
    try t.expect(test_allocator, @intFromEnum(element.track_entry)).toEqual(0xAE);
}

fn testMatroskaIdentifiers(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, @intFromEnum(video.webm.TrackType.video)).toEqual(1);
    try t.expect(test_allocator, @intFromEnum(video.webm.TrackType.audio)).toEqual(2);
    try t.expect(test_allocator, std.mem.eql(u8, video.webm.CodecId.V_VP9, "V_VP9")).toBeTruthy();
    try t.expect(test_allocator, std.mem.eql(u8, video.webm.CodecId.A_OPUS, "A_OPUS")).toBeTruthy();
}

fn testMpegTsIdentifiers(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, video.mpegts.TS_SYNC_BYTE).toEqual(0x47);
    try t.expect(test_allocator, video.mpegts.TS_PACKET_SIZE).toEqual(188);
    try t.expect(test_allocator, @intFromEnum(video.mpegts.StreamType.h264)).toEqual(0x1B);
    try t.expect(test_allocator, @intFromEnum(video.mpegts.StreamType.h265)).toEqual(0x24);
    try t.expect(test_allocator, @intFromEnum(video.mpegts.StreamType.aac)).toEqual(0x0F);
}

fn runColorConformanceTests() !void {
    try t.describe(allocator, "Color and HDR Conformance Tests", struct {
        fn register(test_allocator: std.mem.Allocator) !void {
            try t.it(test_allocator, "classifies standard color spaces", testColorSpaces);
            try t.it(test_allocator, "detects HDR10 characteristics", testHdr10Detection);
            try t.it(test_allocator, "detects HLG characteristics", testHlgDetection);
        }
    }.register);
}

fn testColorSpaces(test_allocator: std.mem.Allocator) !void {
    try t.expect(test_allocator, video.ColorSpace.bt709.isHDR()).toBeFalsy();
    try t.expect(test_allocator, video.ColorSpace.bt2020.isHDR()).toBeTruthy();
    try t.expect(test_allocator, video.ColorTransfer.iec61966_2_1).toEqual(.iec61966_2_1);
    try t.expect(test_allocator, video.ColorPrimaries.bt2020).toEqual(.bt2020);
}

fn testHdr10Detection(test_allocator: std.mem.Allocator) !void {
    var metadata = video.HdrMetadata{
        .color_primaries = 9,
        .transfer_characteristics = 16,
        .matrix_coefficients = 9,
    };
    metadata.detectFormat();
    try t.expect(test_allocator, metadata.format).toEqual(.hdr10);
    try t.expect(test_allocator, metadata.isHdr()).toBeTruthy();
}

fn testHlgDetection(test_allocator: std.mem.Allocator) !void {
    var metadata = video.HdrMetadata{
        .color_primaries = 9,
        .transfer_characteristics = 18,
        .matrix_coefficients = 9,
    };
    metadata.detectFormat();
    try t.expect(test_allocator, metadata.format).toEqual(.hlg);
    try t.expect(test_allocator, metadata.isHdr()).toBeTruthy();
}
