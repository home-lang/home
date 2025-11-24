// VP9 Video Codec
// Implements VP9 bitstream parsing for WebM/MP4 containers
// Reference: VP9 Bitstream & Decoding Process Specification

const std = @import("std");
const types = @import("../../core/types.zig");
const err = @import("../../core/error.zig");
const bitstream = @import("../../util/bitstream.zig");

const VideoError = err.VideoError;
const BitstreamReader = bitstream.BitstreamReader;

// ============================================================================
// VP9 Profile
// ============================================================================

pub const Profile = enum(u3) {
    profile0 = 0, // 8-bit, 4:2:0
    profile1 = 1, // 8-bit, 4:2:2, 4:4:4
    profile2 = 2, // 10/12-bit, 4:2:0
    profile3 = 3, // 10/12-bit, 4:2:2, 4:4:4

    pub fn getBitDepth(self: Profile) u8 {
        return switch (self) {
            .profile0, .profile1 => 8,
            .profile2, .profile3 => 10, // Can be 10 or 12
        };
    }

    pub fn getChromaSubsampling(self: Profile) []const u8 {
        return switch (self) {
            .profile0, .profile2 => "4:2:0",
            .profile1, .profile3 => "4:2:2/4:4:4",
        };
    }
};

// ============================================================================
// VP9 Color Space
// ============================================================================

pub const ColorSpace = enum(u3) {
    cs_unknown = 0,
    bt_601 = 1,
    bt_709 = 2,
    smpte_170 = 3,
    smpte_240 = 4,
    bt_2020 = 5,
    reserved = 6,
    srgb = 7,
};

// ============================================================================
// VP9 Frame Type
// ============================================================================

pub const FrameType = enum(u1) {
    key_frame = 0,
    inter_frame = 1,
};

// ============================================================================
// VP9 Interpolation Filter
// ============================================================================

pub const InterpolationFilter = enum(u3) {
    eighttap_smooth = 0,
    eighttap = 1,
    eighttap_sharp = 2,
    bilinear = 3,
    switchable = 4,
};

// ============================================================================
// VP9 Reference Frame Type
// ============================================================================

pub const ReferenceFrame = enum(u2) {
    intra_frame = 0,
    last_frame = 1,
    golden_frame = 2,
    altref_frame = 3,
};

// ============================================================================
// VP9 Uncompressed Header
// ============================================================================

pub const UncompressedHeader = struct {
    frame_marker: u2,
    profile: Profile,
    show_existing_frame: bool,
    frame_to_show_map_idx: ?u3,
    frame_type: FrameType,
    show_frame: bool,
    error_resilient_mode: bool,

    // Key frame specific
    color_space: ?ColorSpace,
    color_range: ?bool, // false = studio swing, true = full swing
    subsampling_x: ?bool,
    subsampling_y: ?bool,
    bit_depth: u8,

    // Frame size
    width: u16,
    height: u16,
    render_width: ?u16,
    render_height: ?u16,

    // Inter frame specific
    intra_only: bool,
    reset_frame_context: u2,
    refresh_frame_flags: u8,
    ref_frame_idx: [3]u3,
    ref_frame_sign_bias: [4]bool,
    allow_high_precision_mv: bool,
    interpolation_filter: InterpolationFilter,

    // Loop filter
    loop_filter_level: u6,
    loop_filter_sharpness: u3,
    loop_filter_delta_enabled: bool,

    // Quantization
    base_q_idx: u8,
    delta_q_y_dc: i8,
    delta_q_uv_dc: i8,
    delta_q_uv_ac: i8,

    // Segmentation
    segmentation_enabled: bool,

    // Tile info
    tile_cols_log2: u6,
    tile_rows_log2: u6,

    header_size_in_bytes: u16,

    pub fn isKeyFrame(self: *const UncompressedHeader) bool {
        return self.frame_type == .key_frame;
    }

    pub fn isIntraOnly(self: *const UncompressedHeader) bool {
        return self.frame_type == .key_frame or self.intra_only;
    }

    pub fn getDisplaySize(self: *const UncompressedHeader) struct { width: u16, height: u16 } {
        return .{
            .width = self.render_width orelse self.width,
            .height = self.render_height orelse self.height,
        };
    }
};

// ============================================================================
// VP9 Superframe Index
// ============================================================================

/// VP9 superframes contain multiple frames in a single packet
pub const SuperframeIndex = struct {
    frame_count: u8,
    frame_sizes: [8]u32,
    total_size: u32,

    pub fn init() SuperframeIndex {
        return .{
            .frame_count = 0,
            .frame_sizes = [_]u32{0} ** 8,
            .total_size = 0,
        };
    }
};

// ============================================================================
// VP9 Codec Configuration Record (vpcC box)
// ============================================================================

/// VP9 configuration for MP4/WebM containers
pub const VpcCRecord = struct {
    version: u8,
    profile: Profile,
    level: u8,
    bit_depth: u8,
    chroma_subsampling: u8, // 0=4:2:0 vertical, 1=4:2:0 colocated, 2=4:2:2, 3=4:4:4
    color_primaries: u8,
    transfer_characteristics: u8,
    matrix_coefficients: u8,
    video_full_range_flag: bool,
    codec_initialization_data: ?[]const u8,

    pub fn parse(data: []const u8) !VpcCRecord {
        if (data.len < 8) {
            return VideoError.TruncatedData;
        }

        const version = data[0];
        if (version != 1) {
            return VideoError.UnsupportedCodec;
        }

        const flags = data[1];
        const profile: Profile = @enumFromInt(@as(u3, @truncate(flags >> 4)));
        const level = data[2];
        const bit_depth_byte = data[3];
        const bit_depth: u8 = @truncate(bit_depth_byte >> 4);
        const chroma_subsampling: u8 = @truncate((bit_depth_byte >> 1) & 0x07);
        const video_full_range_flag = (bit_depth_byte & 0x01) != 0;

        const color_primaries = data[4];
        const transfer_characteristics = data[5];
        const matrix_coefficients = data[6];

        const init_data_size: u16 = (@as(u16, data[7]) << 8) | data[8];

        var codec_init_data: ?[]const u8 = null;
        if (init_data_size > 0 and data.len >= 9 + init_data_size) {
            codec_init_data = data[9..][0..init_data_size];
        }

        return VpcCRecord{
            .version = version,
            .profile = profile,
            .level = level,
            .bit_depth = bit_depth,
            .chroma_subsampling = chroma_subsampling,
            .color_primaries = color_primaries,
            .transfer_characteristics = transfer_characteristics,
            .matrix_coefficients = matrix_coefficients,
            .video_full_range_flag = video_full_range_flag,
            .codec_initialization_data = codec_init_data,
        };
    }

    pub fn getChromaSubsamplingString(self: *const VpcCRecord) []const u8 {
        return switch (self.chroma_subsampling) {
            0, 1 => "4:2:0",
            2 => "4:2:2",
            3 => "4:4:4",
            else => "unknown",
        };
    }
};

// ============================================================================
// VP9 Frame Parser
// ============================================================================

pub const FrameParser = struct {
    data: []const u8,
    pos: usize,
    bit_pos: u4,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
            .pos = 0,
            .bit_pos = 0,
        };
    }

    /// Parse uncompressed header from frame data
    pub fn parseUncompressedHeader(self: *Self) !UncompressedHeader {
        var header: UncompressedHeader = undefined;
        header.color_space = null;
        header.color_range = null;
        header.subsampling_x = null;
        header.subsampling_y = null;
        header.render_width = null;
        header.render_height = null;
        header.bit_depth = 8;
        header.intra_only = false;
        header.reset_frame_context = 0;
        header.refresh_frame_flags = 0;
        header.ref_frame_idx = [_]u3{0} ** 3;
        header.ref_frame_sign_bias = [_]bool{false} ** 4;
        header.allow_high_precision_mv = false;
        header.interpolation_filter = .eighttap;
        header.delta_q_y_dc = 0;
        header.delta_q_uv_dc = 0;
        header.delta_q_uv_ac = 0;
        header.segmentation_enabled = false;
        header.tile_cols_log2 = 0;
        header.tile_rows_log2 = 0;

        // frame_marker (2 bits) - must be 2
        header.frame_marker = try self.readBits(2);
        if (header.frame_marker != 2) {
            return VideoError.InvalidHeader;
        }

        // profile_low_bit + profile_high_bit
        const profile_low = try self.readBits(1);
        const profile_high = try self.readBits(1);
        const profile_val: u3 = @as(u3, profile_high) << 1 | @as(u3, profile_low);
        header.profile = @enumFromInt(profile_val);

        if (header.profile == .profile3) {
            // reserved_zero (1 bit)
            _ = try self.readBits(1);
        }

        // show_existing_frame
        header.show_existing_frame = try self.readBit();
        if (header.show_existing_frame) {
            header.frame_to_show_map_idx = try self.readBits(3);
            header.frame_type = .inter_frame;
            header.show_frame = true;
            header.error_resilient_mode = false;
            header.width = 0;
            header.height = 0;
            header.loop_filter_level = 0;
            header.loop_filter_sharpness = 0;
            header.loop_filter_delta_enabled = false;
            header.base_q_idx = 0;
            header.header_size_in_bytes = 0;
            return header;
        }
        header.frame_to_show_map_idx = null;

        // frame_type
        header.frame_type = @enumFromInt(try self.readBits(1));

        // show_frame
        header.show_frame = try self.readBit();

        // error_resilient_mode
        header.error_resilient_mode = try self.readBit();

        if (header.frame_type == .key_frame) {
            // frame_sync_code (24 bits) - must be 0x498342
            const sync_code = try self.readBitsU24();
            if (sync_code != 0x498342) {
                return VideoError.InvalidHeader;
            }

            // Color config
            try self.parseColorConfig(&header);

            // Frame size
            try self.parseFrameSize(&header);
        } else {
            // Inter frame
            if (!header.show_frame) {
                header.intra_only = try self.readBit();
            }

            if (!header.error_resilient_mode) {
                header.reset_frame_context = try self.readBits(2);
            }

            if (header.intra_only) {
                // frame_sync_code
                const sync_code = try self.readBitsU24();
                if (sync_code != 0x498342) {
                    return VideoError.InvalidHeader;
                }

                if (header.profile != .profile0) {
                    try self.parseColorConfig(&header);
                } else {
                    header.color_space = .bt_601;
                    header.subsampling_x = true;
                    header.subsampling_y = true;
                    header.bit_depth = 8;
                }

                header.refresh_frame_flags = try self.readBitsU8();
                try self.parseFrameSize(&header);
            } else {
                header.refresh_frame_flags = try self.readBitsU8();

                for (0..3) |i| {
                    header.ref_frame_idx[i] = try self.readBits(3);
                    header.ref_frame_sign_bias[i + 1] = try self.readBit();
                }

                // frame_size_with_refs
                var found_ref = false;
                for (0..3) |_| {
                    if (try self.readBit()) {
                        found_ref = true;
                        break;
                    }
                }

                if (!found_ref) {
                    try self.parseFrameSize(&header);
                } else {
                    // Size from reference - we'd need reference frame info
                    header.width = 0;
                    header.height = 0;
                }

                header.allow_high_precision_mv = try self.readBit();

                // interpolation_filter
                if (try self.readBit()) {
                    header.interpolation_filter = .switchable;
                } else {
                    header.interpolation_filter = @enumFromInt(try self.readBits(2));
                }
            }
        }

        // loop_filter_params
        header.loop_filter_level = try self.readBits(6);
        header.loop_filter_sharpness = try self.readBits(3);
        header.loop_filter_delta_enabled = try self.readBit();

        if (header.loop_filter_delta_enabled) {
            if (try self.readBit()) { // loop_filter_delta_update
                for (0..4) |_| {
                    if (try self.readBit()) {
                        _ = try self.readBits(6); // delta magnitude
                        _ = try self.readBit(); // delta sign
                    }
                }
                for (0..2) |_| {
                    if (try self.readBit()) {
                        _ = try self.readBits(6);
                        _ = try self.readBit();
                    }
                }
            }
        }

        // quantization_params
        header.base_q_idx = try self.readBitsU8();
        header.delta_q_y_dc = try self.readDeltaQ();
        header.delta_q_uv_dc = try self.readDeltaQ();
        header.delta_q_uv_ac = try self.readDeltaQ();

        // segmentation_params
        header.segmentation_enabled = try self.readBit();
        if (header.segmentation_enabled) {
            // Skip segmentation parsing for now - complex
            // Would need to parse segment feature data
        }

        // tile_info
        const min_log2_tile_cols = self.tileLog2(64, header.width);
        const max_log2_tile_cols = self.tileLog2(1, header.width);
        header.tile_cols_log2 = min_log2_tile_cols;

        while (header.tile_cols_log2 < max_log2_tile_cols) {
            if (try self.readBit()) {
                header.tile_cols_log2 += 1;
            } else {
                break;
            }
        }

        header.tile_rows_log2 = if (try self.readBit()) 1 else 0;
        if (header.tile_rows_log2 == 1) {
            if (try self.readBit()) {
                header.tile_rows_log2 = 2;
            }
        }

        // header_size_in_bytes (16 bits)
        header.header_size_in_bytes = try self.readBitsU16();

        return header;
    }

    fn parseColorConfig(self: *Self, header: *UncompressedHeader) !void {
        if (header.profile == .profile2 or header.profile == .profile3) {
            if (try self.readBit()) {
                header.bit_depth = 12;
            } else {
                header.bit_depth = 10;
            }
        } else {
            header.bit_depth = 8;
        }

        const color_space_val: u3 = try self.readBits(3);
        header.color_space = @enumFromInt(color_space_val);

        if (header.color_space != .srgb) {
            header.color_range = try self.readBit();

            if (header.profile == .profile1 or header.profile == .profile3) {
                header.subsampling_x = try self.readBit();
                header.subsampling_y = try self.readBit();
                _ = try self.readBit(); // reserved
            } else {
                header.subsampling_x = true;
                header.subsampling_y = true;
            }
        } else {
            header.color_range = true;
            if (header.profile == .profile1 or header.profile == .profile3) {
                header.subsampling_x = false;
                header.subsampling_y = false;
                _ = try self.readBit(); // reserved
            }
        }
    }

    fn parseFrameSize(self: *Self, header: *UncompressedHeader) !void {
        const width_minus_1: u16 = try self.readBitsU16();
        const height_minus_1: u16 = try self.readBitsU16();
        header.width = width_minus_1 + 1;
        header.height = height_minus_1 + 1;

        // render_size
        if (try self.readBit()) {
            const render_width_minus_1: u16 = try self.readBitsU16();
            const render_height_minus_1: u16 = try self.readBitsU16();
            header.render_width = render_width_minus_1 + 1;
            header.render_height = render_height_minus_1 + 1;
        }
    }

    fn readDeltaQ(self: *Self) !i8 {
        if (try self.readBit()) {
            const magnitude = try self.readBits(4);
            const sign = try self.readBit();
            const value: i8 = @intCast(magnitude);
            return if (sign) -value else value;
        }
        return 0;
    }

    fn tileLog2(_: *Self, blk_size: u16, target: u16) u6 {
        var k: u6 = 0;
        while ((@as(u32, blk_size) << k) < target) {
            k += 1;
        }
        return k;
    }

    // Bit reading helpers
    fn readBit(self: *Self) !bool {
        return try self.readBits(1) == 1;
    }

    fn readBits(self: *Self, comptime n: comptime_int) !std.meta.Int(.unsigned, n) {
        const T = std.meta.Int(.unsigned, n);
        var result: T = 0;

        for (0..n) |_| {
            if (self.pos >= self.data.len) {
                return VideoError.TruncatedData;
            }

            const bit: T = @intCast((self.data[self.pos] >> (7 - @as(u3, @intCast(self.bit_pos)))) & 1);
            result = (result << 1) | bit;

            self.bit_pos += 1;
            if (self.bit_pos >= 8) {
                self.bit_pos = 0;
                self.pos += 1;
            }
        }

        return result;
    }

    fn readBitsU8(self: *Self) !u8 {
        return try self.readBits(8);
    }

    fn readBitsU16(self: *Self) !u16 {
        return try self.readBits(16);
    }

    fn readBitsU24(self: *Self) !u24 {
        return try self.readBits(24);
    }
};

// ============================================================================
// VP9 Superframe Parser
// ============================================================================

/// Parse VP9 superframe index to extract individual frame sizes
pub fn parseSuperframeIndex(data: []const u8) !SuperframeIndex {
    var index = SuperframeIndex.init();

    if (data.len < 1) {
        index.frame_count = 1;
        index.frame_sizes[0] = @intCast(data.len);
        index.total_size = @intCast(data.len);
        return index;
    }

    // Check for superframe marker at end of data
    const marker = data[data.len - 1];

    // Marker format: 110xxxxx where xxxxx encodes frame_count-1 and bytes_per_size
    if ((marker & 0xE0) != 0xC0) {
        // Not a superframe, single frame
        index.frame_count = 1;
        index.frame_sizes[0] = @intCast(data.len);
        index.total_size = @intCast(data.len);
        return index;
    }

    const frames_in_superframe: u8 = (marker & 0x07) + 1;
    const bytes_per_size: u8 = ((marker >> 3) & 0x03) + 1;
    const index_size: usize = 2 + @as(usize, frames_in_superframe) * @as(usize, bytes_per_size);

    if (data.len < index_size) {
        return VideoError.InvalidHeader;
    }

    // Verify marker at start of index
    const start_marker = data[data.len - index_size];
    if (start_marker != marker) {
        return VideoError.InvalidHeader;
    }

    index.frame_count = frames_in_superframe;
    var offset = data.len - index_size + 1;

    for (0..frames_in_superframe) |i| {
        var frame_size: u32 = 0;
        for (0..bytes_per_size) |j| {
            frame_size |= @as(u32, data[offset + j]) << @intCast(j * 8);
        }
        index.frame_sizes[i] = frame_size;
        index.total_size += frame_size;
        offset += bytes_per_size;
    }

    return index;
}

/// Iterator over frames in a VP9 superframe
pub const SuperframeIterator = struct {
    data: []const u8,
    index: SuperframeIndex,
    current_frame: u8,
    current_offset: usize,

    const Self = @This();

    pub fn init(data: []const u8) !Self {
        const index = try parseSuperframeIndex(data);
        return .{
            .data = data,
            .index = index,
            .current_frame = 0,
            .current_offset = 0,
        };
    }

    pub fn next(self: *Self) ?[]const u8 {
        if (self.current_frame >= self.index.frame_count) {
            return null;
        }

        const frame_size = self.index.frame_sizes[self.current_frame];
        if (self.current_offset + frame_size > self.data.len) {
            return null;
        }

        const frame_data = self.data[self.current_offset..][0..frame_size];
        self.current_offset += frame_size;
        self.current_frame += 1;

        return frame_data;
    }

    pub fn reset(self: *Self) void {
        self.current_frame = 0;
        self.current_offset = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Profile properties" {
    try std.testing.expectEqual(@as(u8, 8), Profile.profile0.getBitDepth());
    try std.testing.expectEqual(@as(u8, 10), Profile.profile2.getBitDepth());
    try std.testing.expectEqualStrings("4:2:0", Profile.profile0.getChromaSubsampling());
    try std.testing.expectEqualStrings("4:2:2/4:4:4", Profile.profile1.getChromaSubsampling());
}

test "VpcC record parsing" {
    // Valid vpcC record (version 1)
    const vpcc_data = [_]u8{
        0x01, // version
        0x00, // profile 0
        0x10, // level
        0x81, // bit_depth=8, chroma=0, full_range=1
        0x01, // color_primaries
        0x01, // transfer_characteristics
        0x01, // matrix_coefficients
        0x00, 0x00, // init_data_size = 0
    };

    const record = try VpcCRecord.parse(&vpcc_data);
    try std.testing.expectEqual(Profile.profile0, record.profile);
    try std.testing.expectEqual(@as(u8, 8), record.bit_depth);
    try std.testing.expect(record.video_full_range_flag);
    try std.testing.expectEqualStrings("4:2:0", record.getChromaSubsamplingString());
}

test "Superframe index - single frame" {
    // Regular frame without superframe marker
    const frame_data = [_]u8{ 0x82, 0x00, 0x00 }; // Simple frame data (starts with 10xxxxxx)
    const index = try parseSuperframeIndex(&frame_data);
    try std.testing.expectEqual(@as(u8, 1), index.frame_count);
    try std.testing.expectEqual(@as(u32, 3), index.frame_sizes[0]);
}

test "Superframe iterator" {
    // Single frame case
    const frame_data = [_]u8{ 0x82, 0x00, 0x00 };
    var iter = try SuperframeIterator.init(&frame_data);

    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(usize, 3), first.?.len);

    const second = iter.next();
    try std.testing.expect(second == null);
}

test "Frame parser initialization" {
    const frame_data = [_]u8{ 0x82, 0x00, 0x00, 0x00 };
    var parser = FrameParser.init(&frame_data);
    try std.testing.expectEqual(@as(usize, 0), parser.pos);
    try std.testing.expectEqual(@as(u4, 0), parser.bit_pos);
}

test "UncompressedHeader methods" {
    var header: UncompressedHeader = undefined;
    header.frame_type = .key_frame;
    header.intra_only = false;
    header.width = 1920;
    header.height = 1080;
    header.render_width = null;
    header.render_height = null;

    try std.testing.expect(header.isKeyFrame());
    try std.testing.expect(header.isIntraOnly());

    const size = header.getDisplaySize();
    try std.testing.expectEqual(@as(u16, 1920), size.width);
    try std.testing.expectEqual(@as(u16, 1080), size.height);

    // With render size
    header.render_width = 1280;
    header.render_height = 720;
    const render_size = header.getDisplaySize();
    try std.testing.expectEqual(@as(u16, 1280), render_size.width);
    try std.testing.expectEqual(@as(u16, 720), render_size.height);
}
