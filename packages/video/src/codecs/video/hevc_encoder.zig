// Home Video Library - HEVC/H.265 Encoder
// ITU-T H.265 / ISO/IEC 23008-2 High Efficiency Video Coding Encoder
// Main, Main10 profile support

const std = @import("std");
const hevc = @import("hevc.zig");
const frame = @import("../../core/frame.zig");
const types = @import("../../core/types.zig");

pub const VideoFrame = frame.VideoFrame;

/// HEVC Profile
pub const HEVCProfile = enum(u8) {
    main = 1,
    main10 = 2,
    main_still_picture = 3,
    rext = 4,
};

/// HEVC Tier
pub const HEVCTier = enum(u1) {
    main = 0,
    high = 1,
};

/// HEVC Level
pub const HEVCLevel = enum(u8) {
    level_1 = 30,
    level_2 = 60,
    level_2_1 = 63,
    level_3 = 90,
    level_3_1 = 93,
    level_4 = 120,
    level_4_1 = 123,
    level_5 = 150,
    level_5_1 = 153,
    level_5_2 = 156,
    level_6 = 180,
    level_6_1 = 183,
    level_6_2 = 186,
};

/// CTU (Coding Tree Unit) size
pub const CTUSize = enum(u8) {
    size_16 = 16,
    size_32 = 32,
    size_64 = 64,
};

/// HEVC Encoder Configuration
pub const HEVCEncoderConfig = struct {
    width: u32,
    height: u32,
    frame_rate: types.Rational,

    // Profile and level
    profile: HEVCProfile = .main,
    tier: HEVCTier = .main,
    level: HEVCLevel = .level_4,

    // Rate control
    bitrate: u32 = 2000000,
    crf: u8 = 28, // 0-51
    qp: u8 = 32,

    // GOP structure
    keyframe_interval: u32 = 250,
    b_frames: u8 = 3,
    ref_frames: u8 = 3,

    // CTU configuration
    ctu_size: CTUSize = .size_64,
    max_cu_depth: u8 = 4,

    // Features
    sao: bool = true, // Sample Adaptive Offset
    amp: bool = true, // Asymmetric Motion Partitioning
};

/// HEVC Encoder
pub const HEVCEncoder = struct {
    config: HEVCEncoderConfig,
    allocator: std.mem.Allocator,

    // Encoder state
    frame_num: u32 = 0,

    // Parameter sets
    vps: ?[]u8 = null,
    sps: ?[]u8 = null,
    pps: ?[]u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: HEVCEncoderConfig) !Self {
        var encoder = Self{
            .config = config,
            .allocator = allocator,
        };

        try encoder.generateParameterSets();
        return encoder;
    }

    pub fn deinit(self: *Self) void {
        if (self.vps) |vps| self.allocator.free(vps);
        if (self.sps) |sps| self.allocator.free(sps);
        if (self.pps) |pps| self.allocator.free(pps);
    }

    pub fn encode(self: *Self, input_frame: *const VideoFrame) ![]u8 {
        const is_keyframe = (self.frame_num % self.config.keyframe_interval == 0);

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // For keyframes, output VPS/SPS/PPS first
        if (is_keyframe) {
            if (self.vps) |vps| {
                try self.writeNalUnit(&output, 32, vps); // VPS NAL type
            }
            if (self.sps) |sps| {
                try self.writeNalUnit(&output, 33, sps); // SPS NAL type
            }
            if (self.pps) |pps| {
                try self.writeNalUnit(&output, 34, pps); // PPS NAL type
            }
        }

        // Encode slice
        const slice_data = try self.encodeSlice(input_frame, is_keyframe);
        defer self.allocator.free(slice_data);

        const nal_type: u8 = if (is_keyframe) 19 else 1; // IDR_W_RADL : TRAIL_R
        try self.writeNalUnit(&output, nal_type, slice_data);

        self.frame_num += 1;
        return output.toOwnedSlice();
    }

    fn generateParameterSets(self: *Self) !void {
        // Generate VPS (Video Parameter Set)
        var vps_data = std.ArrayList(u8).init(self.allocator);
        defer vps_data.deinit();
        var vps_writer = BitstreamWriter.init(&vps_data);

        try vps_writer.writeBits(0, 4); // vps_video_parameter_set_id
        try vps_writer.writeBits(3, 2); // vps_base_layer_internal_flag, vps_base_layer_available_flag
        try vps_writer.writeBits(0, 6); // vps_max_layers_minus1
        try vps_writer.writeBits(0, 3); // vps_max_sub_layers_minus1
        try vps_writer.writeBit(1); // vps_temporal_id_nesting_flag
        try vps_writer.writeBits(0xffff, 16); // vps_reserved_0xffff_16bits

        // Profile tier level
        try self.writeProfileTierLevel(&vps_writer, true, 0);

        try vps_writer.writeBit(0); // vps_sub_layer_ordering_info_present_flag
        try vps_writer.writeUE(self.config.ref_frames); // vps_max_dec_pic_buffering_minus1[0]
        try vps_writer.writeUE(self.config.ref_frames); // vps_max_num_reorder_pics[0]
        try vps_writer.writeUE(0); // vps_max_latency_increase_plus1[0]

        try vps_writer.writeBits(0, 6); // vps_max_layer_id
        try vps_writer.writeUE(0); // vps_num_layer_sets_minus1
        try vps_writer.writeBit(0); // vps_timing_info_present_flag
        try vps_writer.writeBit(0); // vps_extension_flag

        try vps_writer.flush();
        self.vps = try vps_data.toOwnedSlice();

        // Generate SPS (Sequence Parameter Set)
        var sps_data = std.ArrayList(u8).init(self.allocator);
        defer sps_data.deinit();
        var sps_writer = BitstreamWriter.init(&sps_data);

        try sps_writer.writeBits(0, 4); // sps_video_parameter_set_id
        try sps_writer.writeBits(0, 3); // sps_max_sub_layers_minus1
        try sps_writer.writeBit(1); // sps_temporal_id_nesting_flag

        try self.writeProfileTierLevel(&sps_writer, true, 0);

        try sps_writer.writeUE(0); // sps_seq_parameter_set_id
        try sps_writer.writeUE(1); // chroma_format_idc (4:2:0)
        try sps_writer.writeUE(self.config.width); // pic_width_in_luma_samples
        try sps_writer.writeUE(self.config.height); // pic_height_in_luma_samples

        try sps_writer.writeBit(0); // conformance_window_flag
        try sps_writer.writeUE(0); // bit_depth_luma_minus8
        try sps_writer.writeUE(0); // bit_depth_chroma_minus8

        const log2_max_poc = 8;
        try sps_writer.writeUE(log2_max_poc - 4); // log2_max_pic_order_cnt_lsb_minus4

        try sps_writer.writeBit(0); // sps_sub_layer_ordering_info_present_flag
        try sps_writer.writeUE(self.config.ref_frames); // sps_max_dec_pic_buffering_minus1[0]
        try sps_writer.writeUE(self.config.ref_frames); // sps_max_num_reorder_pics[0]
        try sps_writer.writeUE(0); // sps_max_latency_increase_plus1[0]

        const log2_ctu = switch (self.config.ctu_size) {
            .size_16 => 4,
            .size_32 => 5,
            .size_64 => 6,
        };
        try sps_writer.writeUE(log2_ctu - 3); // log2_min_luma_coding_block_size_minus3
        try sps_writer.writeUE(log2_ctu - 3); // log2_diff_max_min_luma_coding_block_size
        try sps_writer.writeUE(2 - 2); // log2_min_luma_transform_block_size_minus2
        try sps_writer.writeUE(5 - 2); // log2_diff_max_min_luma_transform_block_size

        try sps_writer.writeUE(2); // max_transform_hierarchy_depth_inter
        try sps_writer.writeUE(2); // max_transform_hierarchy_depth_intra

        try sps_writer.writeBit(0); // scaling_list_enabled_flag
        try sps_writer.writeBit(if (self.config.amp) 1 else 0); // amp_enabled_flag
        try sps_writer.writeBit(if (self.config.sao) 1 else 0); // sample_adaptive_offset_enabled_flag
        try sps_writer.writeBit(0); // pcm_enabled_flag
        try sps_writer.writeUE(0); // num_short_term_ref_pic_sets
        try sps_writer.writeBit(0); // long_term_ref_pics_present_flag

        try sps_writer.writeBit(1); // sps_temporal_mvp_enabled_flag
        try sps_writer.writeBit(1); // strong_intra_smoothing_enabled_flag
        try sps_writer.writeBit(1); // vui_parameters_present_flag

        try self.writeVUI(&sps_writer);
        try sps_writer.writeBit(0); // sps_extension_present_flag

        try sps_writer.flush();
        self.sps = try sps_data.toOwnedSlice();

        // Generate PPS (Picture Parameter Set)
        var pps_data = std.ArrayList(u8).init(self.allocator);
        defer pps_data.deinit();
        var pps_writer = BitstreamWriter.init(&pps_data);

        try pps_writer.writeUE(0); // pps_pic_parameter_set_id
        try pps_writer.writeUE(0); // pps_seq_parameter_set_id
        try pps_writer.writeBit(0); // dependent_slice_segments_enabled_flag
        try pps_writer.writeBit(0); // output_flag_present_flag
        try pps_writer.writeBits(0, 3); // num_extra_slice_header_bits

        try pps_writer.writeBit(0); // sign_data_hiding_enabled_flag
        try pps_writer.writeBit(0); // cabac_init_present_flag

        try pps_writer.writeUE(0); // num_ref_idx_l0_default_active_minus1
        try pps_writer.writeUE(0); // num_ref_idx_l1_default_active_minus1

        try pps_writer.writeSE(@as(i32, @intCast(self.config.qp)) - 26); // init_qp_minus26

        try pps_writer.writeBit(0); // constrained_intra_pred_flag
        try pps_writer.writeBit(0); // transform_skip_enabled_flag
        try pps_writer.writeBit(0); // cu_qp_delta_enabled_flag

        try pps_writer.writeBit(0); // pps_slice_chroma_qp_offsets_present_flag
        try pps_writer.writeBit(0); // weighted_pred_flag
        try pps_writer.writeBit(0); // weighted_bipred_flag
        try pps_writer.writeBit(0); // transquant_bypass_enabled_flag

        try pps_writer.writeBit(0); // tiles_enabled_flag
        try pps_writer.writeBit(0); // entropy_coding_sync_enabled_flag

        try pps_writer.writeBit(1); // pps_loop_filter_across_slices_enabled_flag
        try pps_writer.writeBit(0); // deblocking_filter_control_present_flag
        try pps_writer.writeBit(0); // pps_scaling_list_data_present_flag
        try pps_writer.writeBit(0); // lists_modification_present_flag

        try pps_writer.writeUE(0); // log2_parallel_merge_level_minus2
        try pps_writer.writeBit(0); // slice_segment_header_extension_present_flag
        try pps_writer.writeBit(0); // pps_extension_present_flag

        try pps_writer.flush();
        self.pps = try pps_data.toOwnedSlice();
    }

    fn writeProfileTierLevel(self: *Self, writer: *BitstreamWriter, profile_present: bool, max_sub_layers: u8) !void {
        _ = max_sub_layers;
        if (profile_present) {
            try writer.writeBits(0, 2); // general_profile_space
            try writer.writeBit(@intFromEnum(self.config.tier)); // general_tier_flag
            try writer.writeBits(@intFromEnum(self.config.profile), 5); // general_profile_idc

            // general_profile_compatibility_flag[32]
            var i: u5 = 0;
            while (i < 32) : (i += 1) {
                const compat: u1 = if (i == @intFromEnum(self.config.profile)) 1 else 0;
                try writer.writeBit(compat);
            }

            // general_progressive_source_flag, general_interlaced_source_flag
            try writer.writeBit(1);
            try writer.writeBit(0);

            // general_non_packed_constraint_flag, general_frame_only_constraint_flag
            try writer.writeBit(1);
            try writer.writeBit(1);

            // 43 reserved constraint flags
            try writer.writeBits(0, 32);
            try writer.writeBits(0, 11);
        }

        try writer.writeU8(@intFromEnum(self.config.level)); // general_level_idc
    }

    fn writeVUI(self: *Self, writer: *BitstreamWriter) !void {
        try writer.writeBit(0); // aspect_ratio_info_present_flag
        try writer.writeBit(0); // overscan_info_present_flag

        try writer.writeBit(1); // video_signal_type_present_flag
        try writer.writeBits(5, 3); // video_format (unspecified)
        try writer.writeBit(0); // video_full_range_flag
        try writer.writeBit(1); // colour_description_present_flag
        try writer.writeU8(1); // colour_primaries
        try writer.writeU8(1); // transfer_characteristics
        try writer.writeU8(1); // matrix_coeffs

        try writer.writeBit(0); // chroma_loc_info_present_flag
        try writer.writeBit(0); // neutral_chroma_indication_flag
        try writer.writeBit(0); // field_seq_flag
        try writer.writeBit(0); // frame_field_info_present_flag
        try writer.writeBit(0); // default_display_window_flag

        try writer.writeBit(1); // vui_timing_info_present_flag
        const time_scale = self.config.frame_rate.num * 2;
        const num_units = self.config.frame_rate.denom;
        try writer.writeU32(@intCast(num_units));
        try writer.writeU32(@intCast(time_scale));
        try writer.writeBit(0); // vui_poc_proportional_to_timing_flag
        try writer.writeBit(0); // vui_hrd_parameters_present_flag

        try writer.writeBit(0); // bitstream_restriction_flag
    }

    fn encodeSlice(self: *Self, input_frame: *const VideoFrame, is_idr: bool) ![]u8 {
        _ = input_frame;
        var slice_data = std.ArrayList(u8).init(self.allocator);
        defer slice_data.deinit();

        var writer = BitstreamWriter.init(&slice_data);

        // Simplified slice header
        try writer.writeBit(1); // first_slice_segment_in_pic_flag
        if (is_idr) {
            try writer.writeBit(0); // no_output_of_prior_pics_flag
        }
        try writer.writeUE(0); // slice_pic_parameter_set_id

        const slice_type: u8 = if (is_idr) 2 else 1; // I or P
        try writer.writeUE(slice_type); // slice_type

        // Simplified slice data (placeholder)
        try writer.writeUE(self.config.qp - 26); // slice_qp_delta

        try writer.flush();
        return slice_data.toOwnedSlice();
    }

    fn writeNalUnit(self: *Self, output: *std.ArrayList(u8), nal_type: u8, data: []const u8) !void {
        // Start code
        try output.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 1 });

        // NAL header (2 bytes for HEVC)
        const nal_header_byte1: u8 = (nal_type << 1);
        const nal_header_byte2: u8 = 1; // nuh_layer_id=0, nuh_temporal_id_plus1=1
        try output.append(self.allocator, nal_header_byte1);
        try output.append(self.allocator, nal_header_byte2);

        // RBSP data with emulation prevention
        for (data) |byte| {
            if (output.items.len >= 2 and
                output.items[output.items.len - 2] == 0 and
                output.items[output.items.len - 1] == 0 and
                byte <= 0x03)
            {
                try output.append(self.allocator, 0x03);
            }
            try output.append(self.allocator, byte);
        }
    }
};

const BitstreamWriter = struct {
    buffer: *std.ArrayList(u8),
    bit_buffer: u8 = 0,
    bits_in_buffer: u3 = 0,

    fn init(buffer: *std.ArrayList(u8)) BitstreamWriter {
        return .{ .buffer = buffer };
    }

    fn writeBit(self: *BitstreamWriter, bit: u1) !void {
        self.bit_buffer = (self.bit_buffer << 1) | bit;
        self.bits_in_buffer += 1;
        if (self.bits_in_buffer == 8) {
            try self.buffer.append(self.buffer.allocator, self.bit_buffer);
            self.bit_buffer = 0;
            self.bits_in_buffer = 0;
        }
    }

    fn writeBits(self: *BitstreamWriter, value: u32, num_bits: u5) !void {
        var remaining = num_bits;
        while (remaining > 0) {
            const shift = remaining - 1;
            const bit: u1 = @intCast((value >> shift) & 1);
            try self.writeBit(bit);
            remaining -= 1;
        }
    }

    fn writeU8(self: *BitstreamWriter, value: u8) !void {
        try self.writeBits(value, 8);
    }

    fn writeU32(self: *BitstreamWriter, value: u32) !void {
        try self.writeBits(value, 32);
    }

    fn writeUE(self: *BitstreamWriter, value: u32) !void {
        const val_plus_1 = value + 1;
        const leading_zeros = 31 - @clz(val_plus_1);
        var i: u5 = 0;
        while (i < leading_zeros) : (i += 1) {
            try self.writeBit(0);
        }
        try self.writeBits(val_plus_1, leading_zeros + 1);
    }

    fn writeSE(self: *BitstreamWriter, value: i32) !void {
        const mapped: u32 = if (value <= 0)
            @intCast(-value * 2)
        else
            @intCast(value * 2 - 1);
        try self.writeUE(mapped);
    }

    fn flush(self: *BitstreamWriter) !void {
        if (self.bits_in_buffer > 0) {
            const padding = 8 - self.bits_in_buffer;
            self.bit_buffer <<= @intCast(padding);
            try self.buffer.append(self.buffer.allocator, self.bit_buffer);
            self.bit_buffer = 0;
            self.bits_in_buffer = 0;
        }
    }
};
