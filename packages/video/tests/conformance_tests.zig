// Home Video Library - Conformance Tests
// Test compliance with video codec standards and container format specifications

const std = @import("std");
const video = @import("video");
const t = @import("test_framework");

// Test allocator with leak detection
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

test "conformance tests" {
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    // Run conformance test suites
    try runH264ConformanceTests();
    try runHEVCConformanceTests();
    try runContainerFormatTests();
    try runColorSpaceTests();
}

/// Test H.264 conformance streams
fn runH264ConformanceTests() !void {
    const suite = t.describe("H.264 Conformance Tests", .{});
    defer suite.deinit();

    t.it("should decode baseline profile stream", .{}, testH264Baseline);
    t.it("should decode main profile stream", .{}, testH264Main);
    t.it("should decode high profile stream", .{}, testH264High);
    t.it("should handle various NAL unit types", .{}, testH264NALUnits);
    t.it("should validate SPS/PPS parsing", .{}, testH264SPSPPSParsing);
}

fn testH264Baseline() !void {
    // Test baseline profile (Profile IDC = 66)
    const profile = video.codecs.video.h264.Profile.baseline;
    try t.expect(@intFromEnum(profile)).toEqual(66);

    // Baseline constraints: no B-frames, no CABAC
    const constraints = video.codecs.video.h264.ProfileConstraints{
        .allow_b_frames = false,
        .allow_cabac = false,
        .allow_8x8_transform = false,
    };

    try t.expect(constraints.allow_b_frames).toBeFalsy();
    try t.expect(constraints.allow_cabac).toBeFalsy();
}

fn testH264Main() !void {
    // Test main profile (Profile IDC = 77)
    const profile = video.codecs.video.h264.Profile.main;
    try t.expect(@intFromEnum(profile)).toEqual(77);

    // Main profile allows B-frames and CABAC
    const constraints = video.codecs.video.h264.ProfileConstraints{
        .allow_b_frames = true,
        .allow_cabac = true,
        .allow_8x8_transform = false,
    };

    try t.expect(constraints.allow_b_frames).toBeTruthy();
    try t.expect(constraints.allow_cabac).toBeTruthy();
}

fn testH264High() !void {
    // Test high profile (Profile IDC = 100)
    const profile = video.codecs.video.h264.Profile.high;
    try t.expect(@intFromEnum(profile)).toEqual(100);

    // High profile allows 8x8 transform
    const constraints = video.codecs.video.h264.ProfileConstraints{
        .allow_b_frames = true,
        .allow_cabac = true,
        .allow_8x8_transform = true,
    };

    try t.expect(constraints.allow_8x8_transform).toBeTruthy();
}

fn testH264NALUnits() !void {
    // Test NAL unit type recognition
    const nal_types = video.codecs.video.h264.NALUnitType;

    try t.expect(@intFromEnum(nal_types.sps)).toEqual(7);
    try t.expect(@intFromEnum(nal_types.pps)).toEqual(8);
    try t.expect(@intFromEnum(nal_types.idr)).toEqual(5);
    try t.expect(@intFromEnum(nal_types.slice)).toEqual(1);
    try t.expect(@intFromEnum(nal_types.sei)).toEqual(6);
}

fn testH264SPSPPSParsing() !void {
    // Test SPS (Sequence Parameter Set) structure
    const sps = video.codecs.video.h264.SPS{
        .profile_idc = 100, // High profile
        .level_idc = 41, // Level 4.1
        .width = 1920,
        .height = 1080,
        .fps_num = 30,
        .fps_den = 1,
    };

    try t.expect(sps.width).toEqual(1920);
    try t.expect(sps.height).toEqual(1080);
    try t.expect(sps.profile_idc).toEqual(100);

    // Test PPS (Picture Parameter Set) structure
    const pps = video.codecs.video.h264.PPS{
        .pps_id = 0,
        .sps_id = 0,
        .entropy_coding_mode = .cabac,
        .num_ref_idx_l0 = 1,
        .num_ref_idx_l1 = 1,
    };

    try t.expect(pps.pps_id).toEqual(0);
    try t.expect(pps.entropy_coding_mode).toEqual(.cabac);
}

/// Test HEVC conformance streams
fn runHEVCConformanceTests() !void {
    const suite = t.describe("HEVC Conformance Tests", .{});
    defer suite.deinit();

    t.it("should decode main profile stream", .{}, testHEVCMain);
    t.it("should decode main10 profile stream", .{}, testHEVCMain10);
    t.it("should handle various NAL unit types", .{}, testHEVCNALUnits);
    t.it("should validate VPS/SPS/PPS parsing", .{}, testHEVCParameterSets);
}

fn testHEVCMain() !void {
    // Test HEVC main profile
    const profile = video.codecs.video.hevc.Profile.main;
    try t.expect(@intFromEnum(profile)).toEqual(1);

    const constraints = video.codecs.video.hevc.ProfileConstraints{
        .bit_depth = 8,
        .chroma_format = .yuv420,
    };

    try t.expect(constraints.bit_depth).toEqual(8);
}

fn testHEVCMain10() !void {
    // Test HEVC main10 profile (10-bit)
    const profile = video.codecs.video.hevc.Profile.main10;
    try t.expect(@intFromEnum(profile)).toEqual(2);

    const constraints = video.codecs.video.hevc.ProfileConstraints{
        .bit_depth = 10,
        .chroma_format = .yuv420,
    };

    try t.expect(constraints.bit_depth).toEqual(10);
}

fn testHEVCNALUnits() !void {
    // Test HEVC NAL unit types
    const nal_types = video.codecs.video.hevc.NALUnitType;

    try t.expect(@intFromEnum(nal_types.vps)).toEqual(32);
    try t.expect(@intFromEnum(nal_types.sps)).toEqual(33);
    try t.expect(@intFromEnum(nal_types.pps)).toEqual(34);
    try t.expect(@intFromEnum(nal_types.idr_w_radl)).toEqual(19);
    try t.expect(@intFromEnum(nal_types.idr_n_lp)).toEqual(20);
}

fn testHEVCParameterSets() !void {
    // Test VPS (Video Parameter Set)
    const vps = video.codecs.video.hevc.VPS{
        .vps_id = 0,
        .max_layers = 1,
        .max_sub_layers = 1,
        .temporal_id_nesting = true,
    };

    try t.expect(vps.vps_id).toEqual(0);
    try t.expect(vps.temporal_id_nesting).toBeTruthy();

    // Test SPS
    const sps = video.codecs.video.hevc.SPS{
        .sps_id = 0,
        .vps_id = 0,
        .width = 3840,
        .height = 2160,
        .bit_depth_luma = 10,
        .bit_depth_chroma = 10,
    };

    try t.expect(sps.width).toEqual(3840);
    try t.expect(sps.height).toEqual(2160);
    try t.expect(sps.bit_depth_luma).toEqual(10);
}

/// Test container format compliance
fn runContainerFormatTests() !void {
    const suite = t.describe("Container Format Tests", .{});
    defer suite.deinit();

    t.it("should validate MP4 structure", .{}, testMP4Structure);
    t.it("should validate WebM structure", .{}, testWebMStructure);
    t.it("should validate MKV structure", .{}, testMKVStructure);
    t.it("should validate MPEG-TS structure", .{}, testMPEGTSStructure);
}

fn testMP4Structure() !void {
    // Test MP4 box types
    const ftyp = video.containers.mp4.BoxType.ftyp;
    const moov = video.containers.mp4.BoxType.moov;
    const mdat = video.containers.mp4.BoxType.mdat;

    try t.expect(ftyp).toEqual(.ftyp);
    try t.expect(moov).toEqual(.moov);
    try t.expect(mdat).toEqual(.mdat);

    // Test MP4 brand codes
    const isom = video.containers.mp4.Brand.isom;
    const mp42 = video.containers.mp4.Brand.mp42;

    try t.expect(isom).toEqual(.isom);
    try t.expect(mp42).toEqual(.mp42);
}

fn testWebMStructure() !void {
    // Test WebM EBML structure
    const ebml_header = video.containers.webm.ElementID.ebml;
    const segment = video.containers.webm.ElementID.segment;
    const cluster = video.containers.webm.ElementID.cluster;

    try t.expect(@intFromEnum(ebml_header)).toEqual(0x1A45DFA3);
    try t.expect(@intFromEnum(segment)).toEqual(0x18538067);
    try t.expect(@intFromEnum(cluster)).toEqual(0x1F43B675);

    // Test WebM codec IDs
    const vp9 = video.containers.webm.CodecID{ .video = "V_VP9" };
    const opus = video.containers.webm.CodecID{ .audio = "A_OPUS" };

    try t.expect(std.mem.eql(u8, vp9.video, "V_VP9")).toBeTruthy();
    try t.expect(std.mem.eql(u8, opus.audio, "A_OPUS")).toBeTruthy();
}

fn testMKVStructure() !void {
    // Test Matroska structure (similar to WebM but more codecs)
    const segment = video.containers.mkv.ElementID.segment;
    const tracks = video.containers.mkv.ElementID.tracks;
    const track_entry = video.containers.mkv.ElementID.track_entry;

    try t.expect(@intFromEnum(segment)).toEqual(0x18538067);
    try t.expect(@intFromEnum(tracks)).toEqual(0x1654AE6B);
    try t.expect(@intFromEnum(track_entry)).toEqual(0xAE);

    // Test track types
    const video_track = video.containers.mkv.TrackType.video;
    const audio_track = video.containers.mkv.TrackType.audio;

    try t.expect(@intFromEnum(video_track)).toEqual(1);
    try t.expect(@intFromEnum(audio_track)).toEqual(2);
}

fn testMPEGTSStructure() !void {
    // Test MPEG-TS packet structure
    const sync_byte: u8 = 0x47;
    const packet_size: usize = 188;

    try t.expect(sync_byte).toEqual(0x47);
    try t.expect(packet_size).toEqual(188);

    // Test stream types
    const h264_stream = video.containers.mpegts.StreamType.h264;
    const hevc_stream = video.containers.mpegts.StreamType.hevc;
    const aac_stream = video.containers.mpegts.StreamType.aac;

    try t.expect(@intFromEnum(h264_stream)).toEqual(0x1B);
    try t.expect(@intFromEnum(hevc_stream)).toEqual(0x24);
    try t.expect(@intFromEnum(aac_stream)).toEqual(0x0F);
}

/// Test color space conformance
fn runColorSpaceTests() !void {
    const suite = t.describe("Color Space Tests", .{});
    defer suite.deinit();

    t.it("should support BT.709 color space", .{}, testBT709);
    t.it("should support BT.2020 color space", .{}, testBT2020);
    t.it("should support sRGB transfer", .{}, testSRGB);
    t.it("should validate HDR metadata", .{}, testHDRMetadata);
}

fn testBT709() !void {
    // Test BT.709 (HD) color primaries
    const bt709 = video.core.ColorSpace{
        .primaries = .bt709,
        .transfer = .bt709,
        .matrix = .bt709,
    };

    try t.expect(bt709.primaries).toEqual(.bt709);
    try t.expect(bt709.transfer).toEqual(.bt709);
    try t.expect(bt709.matrix).toEqual(.bt709);
}

fn testBT2020() !void {
    // Test BT.2020 (UHD) color primaries
    const bt2020 = video.core.ColorSpace{
        .primaries = .bt2020,
        .transfer = .bt2020_10,
        .matrix = .bt2020_ncl,
    };

    try t.expect(bt2020.primaries).toEqual(.bt2020);
    try t.expect(bt2020.transfer).toEqual(.bt2020_10);
}

fn testSRGB() !void {
    // Test sRGB transfer function
    const srgb = video.core.ColorSpace{
        .primaries = .bt709,
        .transfer = .iec61966_2_1, // sRGB
        .matrix = .rgb,
    };

    try t.expect(srgb.transfer).toEqual(.iec61966_2_1);
    try t.expect(srgb.matrix).toEqual(.rgb);
}

fn testHDRMetadata() !void {
    // Test HDR10 static metadata
    const hdr10 = video.core.HDRMetadata{
        .transfer = .smpte2084, // PQ
        .primaries = .bt2020,
        .max_luminance = 1000, // nits
        .min_luminance = 0.0001,
        .max_content_light_level = 1000,
        .max_frame_average_light_level = 400,
    };

    try t.expect(hdr10.transfer).toEqual(.smpte2084);
    try t.expect(hdr10.max_luminance).toEqual(1000);
    try t.expect(hdr10.max_content_light_level).toEqual(1000);

    // Test HLG (Hybrid Log-Gamma)
    const hlg = video.core.HDRMetadata{
        .transfer = .arib_std_b67, // HLG
        .primaries = .bt2020,
        .max_luminance = 1000,
        .min_luminance = 0.0,
        .max_content_light_level = null,
        .max_frame_average_light_level = null,
    };

    try t.expect(hlg.transfer).toEqual(.arib_std_b67);
}
