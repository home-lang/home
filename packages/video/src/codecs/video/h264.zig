// Home Video Library - H.264/AVC Codec
// ITU-T H.264 / ISO/IEC 14496-10 (MPEG-4 AVC)

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");
const bitstream = @import("../../util/bitstream.zig");

pub const VideoError = err.VideoError;
pub const VideoFrame = frame.VideoFrame;
pub const PixelFormat = types.PixelFormat;
pub const BitstreamReader = bitstream.BitstreamReader;

// ============================================================================
// H.264 Constants
// ============================================================================

/// NAL Unit Types
pub const NalUnitType = enum(u5) {
    unspecified = 0,
    slice_non_idr = 1, // Coded slice of non-IDR picture
    slice_data_a = 2, // Coded slice data partition A
    slice_data_b = 3, // Coded slice data partition B
    slice_data_c = 4, // Coded slice data partition C
    slice_idr = 5, // Coded slice of IDR picture
    sei = 6, // Supplemental enhancement information
    sps = 7, // Sequence parameter set
    pps = 8, // Picture parameter set
    access_unit_delimiter = 9, // Access unit delimiter
    end_of_seq = 10, // End of sequence
    end_of_stream = 11, // End of stream
    filler_data = 12, // Filler data
    sps_extension = 13, // Sequence parameter set extension
    prefix_nal_unit = 14, // Prefix NAL unit
    subset_sps = 15, // Subset sequence parameter set
    depth_param_set = 16, // Depth parameter set
    // 17-18 reserved
    slice_aux = 19, // Coded slice of auxiliary picture
    slice_extension = 20, // Coded slice extension
    slice_3d_extension = 21, // Coded slice extension for 3D
    // 22-23 reserved
    // 24-31 unspecified

    _,

    pub fn isVcl(self: NalUnitType) bool {
        const val = @intFromEnum(self);
        return val >= 1 and val <= 5;
    }

    pub fn isKeyframe(self: NalUnitType) bool {
        return self == .slice_idr;
    }
};

/// Slice Types
pub const SliceType = enum(u8) {
    p = 0, // P slice
    b = 1, // B slice
    i = 2, // I slice
    sp = 3, // SP slice
    si = 4, // SI slice
    p_only = 5, // P slice (all in picture)
    b_only = 6, // B slice (all in picture)
    i_only = 7, // I slice (all in picture)
    sp_only = 8, // SP slice (all in picture)
    si_only = 9, // SI slice (all in picture)

    _,

    pub fn isIntra(self: SliceType) bool {
        const val = @intFromEnum(self);
        return val == 2 or val == 4 or val == 7 or val == 9;
    }
};

/// Profile IDC values
pub const Profile = enum(u8) {
    baseline = 66,
    main = 77,
    extended = 88,
    high = 100,
    high_10 = 110,
    high_422 = 122,
    high_444 = 244,
    cavlc_444 = 44,
    scalable_baseline = 83,
    scalable_high = 86,
    multiview_high = 118,
    stereo_high = 128,
    mfc_high = 134,
    multiview_depth_high = 138,
    enhanced_multiview_depth_high = 139,

    _,
};

/// Level IDC values
pub const Level = enum(u8) {
    level_1 = 10,
    level_1b = 9, // Special case
    level_1_1 = 11,
    level_1_2 = 12,
    level_1_3 = 13,
    level_2 = 20,
    level_2_1 = 21,
    level_2_2 = 22,
    level_3 = 30,
    level_3_1 = 31,
    level_3_2 = 32,
    level_4 = 40,
    level_4_1 = 41,
    level_4_2 = 42,
    level_5 = 50,
    level_5_1 = 51,
    level_5_2 = 52,
    level_6 = 60,
    level_6_1 = 61,
    level_6_2 = 62,

    _,
};

// ============================================================================
// NAL Unit Header
// ============================================================================

pub const NalUnitHeader = struct {
    forbidden_zero_bit: u1,
    nal_ref_idc: u2, // Reference importance
    nal_unit_type: NalUnitType,

    const Self = @This();

    pub fn parse(byte: u8) Self {
        return Self{
            .forbidden_zero_bit = @intCast((byte >> 7) & 0x01),
            .nal_ref_idc = @intCast((byte >> 5) & 0x03),
            .nal_unit_type = @enumFromInt(@as(u5, @truncate(byte & 0x1F))),
        };
    }

    pub fn toByte(self: *const Self) u8 {
        return (@as(u8, self.forbidden_zero_bit) << 7) |
            (@as(u8, self.nal_ref_idc) << 5) |
            @as(u8, @intFromEnum(self.nal_unit_type));
    }

    pub fn isReference(self: *const Self) bool {
        return self.nal_ref_idc != 0;
    }
};

// ============================================================================
// Sequence Parameter Set (SPS)
// ============================================================================

pub const Sps = struct {
    // Profile and level
    profile_idc: u8,
    constraint_set_flags: u8, // constraint_set0-5_flag packed
    level_idc: u8,
    seq_parameter_set_id: u8,

    // Chroma format (for high profiles)
    chroma_format_idc: u8,
    separate_colour_plane_flag: bool,
    bit_depth_luma: u8,
    bit_depth_chroma: u8,
    qpprime_y_zero_transform_bypass_flag: bool,

    // Scaling matrices
    seq_scaling_matrix_present_flag: bool,

    // Frame numbering
    log2_max_frame_num: u8,
    pic_order_cnt_type: u8,
    log2_max_pic_order_cnt_lsb: u8,
    delta_pic_order_always_zero_flag: bool,
    offset_for_non_ref_pic: i32,
    offset_for_top_to_bottom_field: i32,
    num_ref_frames_in_pic_order_cnt_cycle: u8,
    offset_for_ref_frame: [256]i32,

    // Reference frames
    max_num_ref_frames: u8,
    gaps_in_frame_num_value_allowed_flag: bool,

    // Picture dimensions
    pic_width_in_mbs: u16,
    pic_height_in_map_units: u16,
    frame_mbs_only_flag: bool,
    mb_adaptive_frame_field_flag: bool,

    // Cropping
    frame_cropping_flag: bool,
    frame_crop_left_offset: u16,
    frame_crop_right_offset: u16,
    frame_crop_top_offset: u16,
    frame_crop_bottom_offset: u16,

    // VUI
    vui_parameters_present_flag: bool,
    vui: ?VuiParameters,

    const Self = @This();

    /// Parse SPS from RBSP data (after removing emulation prevention bytes)
    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        var sps = Self{
            .profile_idc = @intCast(try reader.readBits(8)),
            .constraint_set_flags = @intCast(try reader.readBits(8)),
            .level_idc = @intCast(try reader.readBits(8)),
            .seq_parameter_set_id = @intCast(try reader.readUE()),
            .chroma_format_idc = 1, // Default 4:2:0
            .separate_colour_plane_flag = false,
            .bit_depth_luma = 8,
            .bit_depth_chroma = 8,
            .qpprime_y_zero_transform_bypass_flag = false,
            .seq_scaling_matrix_present_flag = false,
            .log2_max_frame_num = 0,
            .pic_order_cnt_type = 0,
            .log2_max_pic_order_cnt_lsb = 0,
            .delta_pic_order_always_zero_flag = false,
            .offset_for_non_ref_pic = 0,
            .offset_for_top_to_bottom_field = 0,
            .num_ref_frames_in_pic_order_cnt_cycle = 0,
            .offset_for_ref_frame = [_]i32{0} ** 256,
            .max_num_ref_frames = 0,
            .gaps_in_frame_num_value_allowed_flag = false,
            .pic_width_in_mbs = 0,
            .pic_height_in_map_units = 0,
            .frame_mbs_only_flag = false,
            .mb_adaptive_frame_field_flag = false,
            .frame_cropping_flag = false,
            .frame_crop_left_offset = 0,
            .frame_crop_right_offset = 0,
            .frame_crop_top_offset = 0,
            .frame_crop_bottom_offset = 0,
            .vui_parameters_present_flag = false,
            .vui = null,
        };

        // High profiles have additional fields
        if (sps.profile_idc == 100 or sps.profile_idc == 110 or
            sps.profile_idc == 122 or sps.profile_idc == 244 or
            sps.profile_idc == 44 or sps.profile_idc == 83 or
            sps.profile_idc == 86 or sps.profile_idc == 118 or
            sps.profile_idc == 128 or sps.profile_idc == 138 or
            sps.profile_idc == 139 or sps.profile_idc == 134)
        {
            sps.chroma_format_idc = @intCast(try reader.readUE());
            if (sps.chroma_format_idc == 3) {
                sps.separate_colour_plane_flag = try reader.readBit() == 1;
            }
            sps.bit_depth_luma = @intCast(try reader.readUE() + 8);
            sps.bit_depth_chroma = @intCast(try reader.readUE() + 8);
            sps.qpprime_y_zero_transform_bypass_flag = try reader.readBit() == 1;

            // Scaling matrix
            sps.seq_scaling_matrix_present_flag = try reader.readBit() == 1;
            if (sps.seq_scaling_matrix_present_flag) {
                // Skip scaling lists for now
                const num_lists: u8 = if (sps.chroma_format_idc != 3) 8 else 12;
                var i: u8 = 0;
                while (i < num_lists) : (i += 1) {
                    const present = try reader.readBit();
                    if (present == 1) {
                        try skipScalingList(&reader, if (i < 6) 16 else 64);
                    }
                }
            }
        }

        sps.log2_max_frame_num = @intCast(try reader.readUE() + 4);
        sps.pic_order_cnt_type = @intCast(try reader.readUE());

        if (sps.pic_order_cnt_type == 0) {
            sps.log2_max_pic_order_cnt_lsb = @intCast(try reader.readUE() + 4);
        } else if (sps.pic_order_cnt_type == 1) {
            sps.delta_pic_order_always_zero_flag = try reader.readBit() == 1;
            sps.offset_for_non_ref_pic = try reader.readSE();
            sps.offset_for_top_to_bottom_field = try reader.readSE();
            sps.num_ref_frames_in_pic_order_cnt_cycle = @intCast(try reader.readUE());
            var i: u8 = 0;
            while (i < sps.num_ref_frames_in_pic_order_cnt_cycle) : (i += 1) {
                sps.offset_for_ref_frame[i] = try reader.readSE();
            }
        }

        sps.max_num_ref_frames = @intCast(try reader.readUE());
        sps.gaps_in_frame_num_value_allowed_flag = try reader.readBit() == 1;
        sps.pic_width_in_mbs = @intCast(try reader.readUE() + 1);
        sps.pic_height_in_map_units = @intCast(try reader.readUE() + 1);
        sps.frame_mbs_only_flag = try reader.readBit() == 1;

        if (!sps.frame_mbs_only_flag) {
            sps.mb_adaptive_frame_field_flag = try reader.readBit() == 1;
        }

        _ = try reader.readBit(); // direct_8x8_inference_flag

        sps.frame_cropping_flag = try reader.readBit() == 1;
        if (sps.frame_cropping_flag) {
            sps.frame_crop_left_offset = @intCast(try reader.readUE());
            sps.frame_crop_right_offset = @intCast(try reader.readUE());
            sps.frame_crop_top_offset = @intCast(try reader.readUE());
            sps.frame_crop_bottom_offset = @intCast(try reader.readUE());
        }

        sps.vui_parameters_present_flag = try reader.readBit() == 1;
        if (sps.vui_parameters_present_flag) {
            sps.vui = try VuiParameters.parse(&reader);
        }

        return sps;
    }

    fn skipScalingList(reader: *BitstreamReader, size: u8) !void {
        var last_scale: i32 = 8;
        var next_scale: i32 = 8;
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            if (next_scale != 0) {
                const delta = try reader.readSE();
                next_scale = @mod(last_scale + delta + 256, 256);
            }
            last_scale = if (next_scale == 0) last_scale else next_scale;
        }
    }

    /// Get width in pixels
    pub fn width(self: *const Self) u32 {
        const crop_unit_x: u32 = if (self.chroma_format_idc == 0) 1 else if (self.chroma_format_idc == 3 and self.separate_colour_plane_flag) 1 else 2;
        const raw_width = @as(u32, self.pic_width_in_mbs) * 16;
        const crop = (self.frame_crop_left_offset + self.frame_crop_right_offset) * crop_unit_x;
        return raw_width - crop;
    }

    /// Get height in pixels
    pub fn height(self: *const Self) u32 {
        const crop_unit_y: u32 = if (self.chroma_format_idc == 0) 1 else if (self.chroma_format_idc == 3 and self.separate_colour_plane_flag) 1 else 2;
        const frame_height_factor: u32 = if (self.frame_mbs_only_flag) 1 else 2;
        const raw_height = @as(u32, self.pic_height_in_map_units) * 16 * frame_height_factor;
        const crop = (self.frame_crop_top_offset + self.frame_crop_bottom_offset) * crop_unit_y * frame_height_factor;
        return raw_height - crop;
    }

    /// Get pixel format
    pub fn pixelFormat(self: *const Self) PixelFormat {
        if (self.bit_depth_luma > 8 or self.bit_depth_chroma > 8) {
            return switch (self.chroma_format_idc) {
                0 => .gray16,
                1 => .yuv420p10le,
                2 => .yuv422p10le,
                3 => .yuv444p10le,
                else => .yuv420p,
            };
        }
        return switch (self.chroma_format_idc) {
            0 => .gray8,
            1 => .yuv420p,
            2 => .yuv422p,
            3 => .yuv444p,
            else => .yuv420p,
        };
    }

    /// Get frame rate from VUI (if present)
    pub fn frameRate(self: *const Self) ?types.Rational {
        if (self.vui) |vui| {
            if (vui.timing_info_present_flag) {
                return types.Rational{
                    .num = vui.time_scale,
                    .den = vui.num_units_in_tick * 2, // Field timing
                };
            }
        }
        return null;
    }

    /// Get profile name
    pub fn profileName(self: *const Self) []const u8 {
        return switch (self.profile_idc) {
            66 => "Baseline",
            77 => "Main",
            88 => "Extended",
            100 => "High",
            110 => "High 10",
            122 => "High 4:2:2",
            244 => "High 4:4:4 Predictive",
            else => "Unknown",
        };
    }
};

// ============================================================================
// Picture Parameter Set (PPS)
// ============================================================================

pub const Pps = struct {
    pic_parameter_set_id: u8,
    seq_parameter_set_id: u8,
    entropy_coding_mode_flag: bool, // CABAC if true, CAVLC if false
    bottom_field_pic_order_in_frame_present_flag: bool,

    // Slice groups
    num_slice_groups: u8,
    slice_group_map_type: u8,

    // Reference picture settings
    num_ref_idx_l0_default_active: u8,
    num_ref_idx_l1_default_active: u8,

    // Weighted prediction
    weighted_pred_flag: bool,
    weighted_bipred_idc: u8,

    // Quantization
    pic_init_qp: i8,
    pic_init_qs: i8,
    chroma_qp_index_offset: i8,

    // Deblocking
    deblocking_filter_control_present_flag: bool,
    constrained_intra_pred_flag: bool,
    redundant_pic_cnt_present_flag: bool,

    // 8x8 transform (high profiles)
    transform_8x8_mode_flag: bool,
    pic_scaling_matrix_present_flag: bool,
    second_chroma_qp_index_offset: i8,

    const Self = @This();

    /// Parse PPS from RBSP data
    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        var pps = Self{
            .pic_parameter_set_id = @intCast(try reader.readUE()),
            .seq_parameter_set_id = @intCast(try reader.readUE()),
            .entropy_coding_mode_flag = try reader.readBit() == 1,
            .bottom_field_pic_order_in_frame_present_flag = try reader.readBit() == 1,
            .num_slice_groups = 1,
            .slice_group_map_type = 0,
            .num_ref_idx_l0_default_active = 0,
            .num_ref_idx_l1_default_active = 0,
            .weighted_pred_flag = false,
            .weighted_bipred_idc = 0,
            .pic_init_qp = 0,
            .pic_init_qs = 0,
            .chroma_qp_index_offset = 0,
            .deblocking_filter_control_present_flag = false,
            .constrained_intra_pred_flag = false,
            .redundant_pic_cnt_present_flag = false,
            .transform_8x8_mode_flag = false,
            .pic_scaling_matrix_present_flag = false,
            .second_chroma_qp_index_offset = 0,
        };

        pps.num_slice_groups = @intCast(try reader.readUE() + 1);
        if (pps.num_slice_groups > 1) {
            pps.slice_group_map_type = @intCast(try reader.readUE());
            // Skip slice group mapping - complex and rarely used
        }

        pps.num_ref_idx_l0_default_active = @intCast(try reader.readUE() + 1);
        pps.num_ref_idx_l1_default_active = @intCast(try reader.readUE() + 1);
        pps.weighted_pred_flag = try reader.readBit() == 1;
        pps.weighted_bipred_idc = @intCast(try reader.readBits(2));
        pps.pic_init_qp = @intCast(try reader.readSE() + 26);
        pps.pic_init_qs = @intCast(try reader.readSE() + 26);
        pps.chroma_qp_index_offset = @intCast(try reader.readSE());
        pps.deblocking_filter_control_present_flag = try reader.readBit() == 1;
        pps.constrained_intra_pred_flag = try reader.readBit() == 1;
        pps.redundant_pic_cnt_present_flag = try reader.readBit() == 1;

        // Check for more RBSP data (8x8 transform for high profiles)
        if (reader.hasMoreData()) {
            pps.transform_8x8_mode_flag = try reader.readBit() == 1;
            pps.pic_scaling_matrix_present_flag = try reader.readBit() == 1;
            if (pps.pic_scaling_matrix_present_flag) {
                // Skip scaling matrices
            }
            pps.second_chroma_qp_index_offset = @intCast(try reader.readSE());
        }

        return pps;
    }

    /// Is CABAC entropy coding used?
    pub fn isCabac(self: *const Self) bool {
        return self.entropy_coding_mode_flag;
    }
};

// ============================================================================
// VUI Parameters
// ============================================================================

pub const VuiParameters = struct {
    aspect_ratio_info_present_flag: bool,
    aspect_ratio_idc: u8,
    sar_width: u16,
    sar_height: u16,

    overscan_info_present_flag: bool,
    overscan_appropriate_flag: bool,

    video_signal_type_present_flag: bool,
    video_format: u8,
    video_full_range_flag: bool,
    colour_description_present_flag: bool,
    colour_primaries: u8,
    transfer_characteristics: u8,
    matrix_coefficients: u8,

    chroma_loc_info_present_flag: bool,
    chroma_sample_loc_type_top_field: u8,
    chroma_sample_loc_type_bottom_field: u8,

    timing_info_present_flag: bool,
    num_units_in_tick: u32,
    time_scale: u32,
    fixed_frame_rate_flag: bool,

    const Self = @This();

    pub fn parse(reader: *BitstreamReader) !Self {
        var vui = Self{
            .aspect_ratio_info_present_flag = false,
            .aspect_ratio_idc = 0,
            .sar_width = 1,
            .sar_height = 1,
            .overscan_info_present_flag = false,
            .overscan_appropriate_flag = false,
            .video_signal_type_present_flag = false,
            .video_format = 5,
            .video_full_range_flag = false,
            .colour_description_present_flag = false,
            .colour_primaries = 2,
            .transfer_characteristics = 2,
            .matrix_coefficients = 2,
            .chroma_loc_info_present_flag = false,
            .chroma_sample_loc_type_top_field = 0,
            .chroma_sample_loc_type_bottom_field = 0,
            .timing_info_present_flag = false,
            .num_units_in_tick = 0,
            .time_scale = 0,
            .fixed_frame_rate_flag = false,
        };

        vui.aspect_ratio_info_present_flag = try reader.readBit() == 1;
        if (vui.aspect_ratio_info_present_flag) {
            vui.aspect_ratio_idc = @intCast(try reader.readBits(8));
            if (vui.aspect_ratio_idc == 255) { // Extended_SAR
                vui.sar_width = @intCast(try reader.readBits(16));
                vui.sar_height = @intCast(try reader.readBits(16));
            }
        }

        vui.overscan_info_present_flag = try reader.readBit() == 1;
        if (vui.overscan_info_present_flag) {
            vui.overscan_appropriate_flag = try reader.readBit() == 1;
        }

        vui.video_signal_type_present_flag = try reader.readBit() == 1;
        if (vui.video_signal_type_present_flag) {
            vui.video_format = @intCast(try reader.readBits(3));
            vui.video_full_range_flag = try reader.readBit() == 1;
            vui.colour_description_present_flag = try reader.readBit() == 1;
            if (vui.colour_description_present_flag) {
                vui.colour_primaries = @intCast(try reader.readBits(8));
                vui.transfer_characteristics = @intCast(try reader.readBits(8));
                vui.matrix_coefficients = @intCast(try reader.readBits(8));
            }
        }

        vui.chroma_loc_info_present_flag = try reader.readBit() == 1;
        if (vui.chroma_loc_info_present_flag) {
            vui.chroma_sample_loc_type_top_field = @intCast(try reader.readUE());
            vui.chroma_sample_loc_type_bottom_field = @intCast(try reader.readUE());
        }

        vui.timing_info_present_flag = try reader.readBit() == 1;
        if (vui.timing_info_present_flag) {
            vui.num_units_in_tick = try reader.readBits(32);
            vui.time_scale = try reader.readBits(32);
            vui.fixed_frame_rate_flag = try reader.readBit() == 1;
        }

        // Skip remaining VUI fields (NAL HRD, VCL HRD, etc.)

        return vui;
    }
};

// ============================================================================
// AVC Decoder Configuration Record (from avcC box)
// ============================================================================

pub const AvcDecoderConfigRecord = struct {
    configuration_version: u8,
    avc_profile_indication: u8,
    profile_compatibility: u8,
    avc_level_indication: u8,
    length_size_minus_one: u2, // NAL unit length field size - 1

    sps_list: std.ArrayList([]const u8),
    pps_list: std.ArrayList([]const u8),

    // High profile extensions
    chroma_format: u8,
    bit_depth_luma: u8,
    bit_depth_chroma: u8,
    sps_ext_list: ?std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 7) return VideoError.TruncatedData;

        var config = Self{
            .configuration_version = data[0],
            .avc_profile_indication = data[1],
            .profile_compatibility = data[2],
            .avc_level_indication = data[3],
            .length_size_minus_one = @intCast(data[4] & 0x03),
            .sps_list = .empty,
            .pps_list = .empty,
            .chroma_format = 1,
            .bit_depth_luma = 8,
            .bit_depth_chroma = 8,
            .sps_ext_list = null,
            .allocator = allocator,
        };

        var offset: usize = 5;

        // Parse SPS
        const num_sps = data[offset] & 0x1F;
        offset += 1;

        var i: u8 = 0;
        while (i < num_sps) : (i += 1) {
            if (offset + 2 > data.len) return VideoError.TruncatedData;
            const sps_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            if (offset + sps_len > data.len) return VideoError.TruncatedData;

            const sps_data = try allocator.dupe(u8, data[offset .. offset + sps_len]);
            try config.sps_list.append(allocator, sps_data);
            offset += sps_len;
        }

        // Parse PPS
        if (offset >= data.len) return VideoError.TruncatedData;
        const num_pps = data[offset];
        offset += 1;

        i = 0;
        while (i < num_pps) : (i += 1) {
            if (offset + 2 > data.len) return VideoError.TruncatedData;
            const pps_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            if (offset + pps_len > data.len) return VideoError.TruncatedData;

            const pps_data = try allocator.dupe(u8, data[offset .. offset + pps_len]);
            try config.pps_list.append(allocator, pps_data);
            offset += pps_len;
        }

        // High profile extensions
        if (config.avc_profile_indication == 100 or
            config.avc_profile_indication == 110 or
            config.avc_profile_indication == 122 or
            config.avc_profile_indication == 144)
        {
            if (offset + 4 <= data.len) {
                config.chroma_format = data[offset] & 0x03;
                config.bit_depth_luma = (data[offset + 1] & 0x07) + 8;
                config.bit_depth_chroma = (data[offset + 2] & 0x07) + 8;
                // offset + 3 has number of SPS extensions
            }
        }

        return config;
    }

    pub fn deinit(self: *Self) void {
        for (self.sps_list.items) |sps| {
            self.allocator.free(sps);
        }
        self.sps_list.deinit(self.allocator);

        for (self.pps_list.items) |pps| {
            self.allocator.free(pps);
        }
        self.pps_list.deinit(self.allocator);

        if (self.sps_ext_list) |*ext| {
            for (ext.items) |sps_ext| {
                self.allocator.free(sps_ext);
            }
            ext.deinit(self.allocator);
        }
    }

    /// Get NAL unit length field size (1, 2, 3, or 4 bytes)
    pub fn nalLengthSize(self: *const Self) u8 {
        return @as(u8, self.length_size_minus_one) + 1;
    }

    /// Get first SPS (parsed)
    pub fn getSps(self: *const Self) !?Sps {
        if (self.sps_list.items.len == 0) return null;
        const rbsp = try bitstream.removeEmulationPrevention(self.allocator, self.sps_list.items[0][1..]); // Skip NAL header
        defer self.allocator.free(rbsp);
        return try Sps.parse(rbsp);
    }

    /// Get first PPS (parsed)
    pub fn getPps(self: *const Self) !?Pps {
        if (self.pps_list.items.len == 0) return null;
        const rbsp = try bitstream.removeEmulationPrevention(self.allocator, self.pps_list.items[0][1..]); // Skip NAL header
        defer self.allocator.free(rbsp);
        return try Pps.parse(rbsp);
    }
};

// ============================================================================
// H.264 NAL Unit Iterator (for Annex B streams)
// ============================================================================

pub const H264NalIterator = struct {
    data: []const u8,
    offset: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .offset = 0,
        };
    }

    pub fn next(self: *Self) ?struct { header: NalUnitHeader, data: []const u8 } {
        // Find start code
        while (self.offset + 4 < self.data.len) {
            if (self.data[self.offset] == 0 and
                self.data[self.offset + 1] == 0)
            {
                const start_code_len: usize = if (self.data[self.offset + 2] == 1)
                    3
                else if (self.data[self.offset + 2] == 0 and self.data[self.offset + 3] == 1)
                    4
                else {
                    self.offset += 1;
                    continue;
                };

                const nal_start = self.offset + start_code_len;
                if (nal_start >= self.data.len) return null;

                // Find next start code or end
                var nal_end = nal_start + 1;
                while (nal_end + 3 < self.data.len) {
                    if (self.data[nal_end] == 0 and
                        self.data[nal_end + 1] == 0 and
                        (self.data[nal_end + 2] == 1 or
                        (self.data[nal_end + 2] == 0 and self.data[nal_end + 3] == 1)))
                    {
                        break;
                    }
                    nal_end += 1;
                }
                if (nal_end + 3 >= self.data.len) {
                    nal_end = self.data.len;
                }

                const header = NalUnitHeader.parse(self.data[nal_start]);
                self.offset = nal_end;

                return .{
                    .header = header,
                    .data = self.data[nal_start..nal_end],
                };
            }
            self.offset += 1;
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NalUnitType" {
    try std.testing.expect(NalUnitType.slice_idr.isKeyframe());
    try std.testing.expect(NalUnitType.slice_non_idr.isVcl());
    try std.testing.expect(!NalUnitType.sps.isVcl());
}

test "NalUnitHeader parse" {
    const header = NalUnitHeader.parse(0x67); // SPS with nal_ref_idc=3
    try std.testing.expectEqual(NalUnitType.sps, header.nal_unit_type);
    try std.testing.expectEqual(@as(u2, 3), header.nal_ref_idc);
    try std.testing.expectEqual(@as(u1, 0), header.forbidden_zero_bit);
}

test "NalUnitHeader roundtrip" {
    const original: u8 = 0x65; // IDR slice
    const header = NalUnitHeader.parse(original);
    try std.testing.expectEqual(original, header.toByte());
}

test "SliceType" {
    try std.testing.expect(SliceType.i.isIntra());
    try std.testing.expect(SliceType.i_only.isIntra());
    try std.testing.expect(!SliceType.p.isIntra());
    try std.testing.expect(!SliceType.b.isIntra());
}
