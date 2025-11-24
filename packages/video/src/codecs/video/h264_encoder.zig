// Home Video Library - H.264/AVC Encoder
// ITU-T H.264 / ISO/IEC 14496-10 Advanced Video Coding Encoder
// Baseline, Main, and High profile support

const std = @import("std");
const h264 = @import("h264.zig");
const frame = @import("../../core/frame.zig");
const types = @import("../../core/types.zig");

pub const VideoFrame = frame.VideoFrame;
pub const NalUnitType = h264.NalUnitType;
pub const SliceType = h264.SliceType;

/// H.264 Profile
pub const H264Profile = enum(u8) {
    baseline = 66,
    main = 77,
    high = 100,
    high10 = 110,
    high422 = 122,
    high444 = 244,
};

/// H.264 Level
pub const H264Level = enum(u8) {
    level_1 = 10,
    level_1b = 11,
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
};

/// Rate control mode
pub const RateControlMode = enum {
    cbr, // Constant bitrate
    vbr, // Variable bitrate
    crf, // Constant rate factor (quality-based)
    cqp, // Constant quantization parameter
};

/// Encoding preset (speed/quality tradeoff)
pub const EncodingPreset = enum {
    ultrafast,
    superfast,
    veryfast,
    faster,
    fast,
    medium,
    slow,
    slower,
    veryslow,
    placebo,
};

/// H.264 Encoder Configuration
pub const H264EncoderConfig = struct {
    width: u32,
    height: u32,
    frame_rate: types.Rational,

    // Profile and level
    profile: H264Profile = .main,
    level: H264Level = .level_4,

    // Rate control
    rate_control: RateControlMode = .crf,
    bitrate: u32 = 2000000, // bits/second (for CBR/VBR)
    max_bitrate: u32 = 0, // for VBR (0 = 1.5x bitrate)
    crf: u8 = 23, // 0-51, lower = better quality
    qp: u8 = 28, // for CQP mode

    // GOP structure
    keyframe_interval: u32 = 250, // Max frames between I-frames
    min_keyframe_interval: u32 = 25,
    b_frames: u8 = 3, // Number of B-frames between P/I frames
    ref_frames: u8 = 3, // Reference frames

    // Encoding options
    preset: EncodingPreset = .medium,
    threads: u8 = 0, // 0 = auto

    // Features
    cabac: bool = true, // Use CABAC entropy coding (Main/High profiles)
    deblock: bool = true, // Deblocking filter

    // Advanced
    me_range: u16 = 16, // Motion estimation search range
    subpel_refine: u8 = 7, // Subpixel refinement quality (1-11)
};

/// H.264 Encoder
pub const H264Encoder = struct {
    config: H264EncoderConfig,
    allocator: std.mem.Allocator,

    // Encoder state
    frame_num: u32 = 0,
    idr_pic_id: u8 = 0,

    // SPS/PPS
    sps: ?[]u8 = null,
    pps: ?[]u8 = null,

    // Reference frames
    ref_frames: std.ArrayList(EncodedFrame),

    // Rate control state
    rc_state: RateControlState,

    const Self = @This();

    const EncodedFrame = struct {
        frame_num: u32,
        poc: i32, // Picture order count
        is_reference: bool,
        reconstructed: ?*VideoFrame,
    };

    const RateControlState = struct {
        target_bits_per_frame: u32,
        buffer_fullness: i64,
        qp_avg: f32,

        fn init(config: *const H264EncoderConfig) RateControlState {
            const fps = config.frame_rate.toFloat();
            const target_bpf = if (fps > 0)
                @as(u32, @intFromFloat(@as(f64, @floatFromInt(config.bitrate)) / fps))
            else
                0;

            return .{
                .target_bits_per_frame = target_bpf,
                .buffer_fullness = 0,
                .qp_avg = @floatFromInt(config.qp),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: H264EncoderConfig) !Self {
        var encoder = Self{
            .config = config,
            .allocator = allocator,
            .ref_frames = std.ArrayList(EncodedFrame).init(allocator),
            .rc_state = RateControlState.init(&config),
        };

        // Generate SPS and PPS
        try encoder.generateParameterSets();

        return encoder;
    }

    pub fn deinit(self: *Self) void {
        if (self.sps) |sps| self.allocator.free(sps);
        if (self.pps) |pps| self.allocator.free(pps);

        for (self.ref_frames.items) |*ref| {
            if (ref.reconstructed) |recon| {
                recon.deinit();
                self.allocator.destroy(recon);
            }
        }
        self.ref_frames.deinit();
    }

    /// Encode a video frame to H.264 NAL units
    pub fn encode(self: *Self, input_frame: *const VideoFrame) ![]u8 {
        // Determine slice type
        const is_keyframe = (self.frame_num % self.config.keyframe_interval == 0);
        const slice_type: SliceType = if (is_keyframe)
            .i
        else if (self.frame_num % (self.config.b_frames + 1) == 0)
            .p
        else
            .b;

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // For keyframes, output SPS and PPS first
        if (is_keyframe) {
            if (self.sps) |sps| {
                try self.writeNalUnit(&output, .sps, sps);
            }
            if (self.pps) |pps| {
                try self.writeNalUnit(&output, .pps, pps);
            }
        }

        // Encode slice
        const slice_data = try self.encodeSlice(input_frame, slice_type, is_keyframe);
        defer self.allocator.free(slice_data);

        const nal_type: NalUnitType = if (is_keyframe) .slice_idr else .slice_non_idr;
        try self.writeNalUnit(&output, nal_type, slice_data);

        self.frame_num += 1;
        if (is_keyframe) {
            self.idr_pic_id = (self.idr_pic_id + 1) % 256;
        }

        return output.toOwnedSlice();
    }

    fn generateParameterSets(self: *Self) !void {
        // Generate SPS (Sequence Parameter Set)
        var sps_data = std.ArrayList(u8).init(self.allocator);
        defer sps_data.deinit();

        var sps_writer = BitstreamWriter.init(&sps_data);

        // profile_idc
        try sps_writer.writeU8(@intFromEnum(self.config.profile));

        // constraint flags
        const constraint_flags: u8 = switch (self.config.profile) {
            .baseline => 0b11000000, // constraint_set0_flag, constraint_set1_flag
            .main => 0b01000000,
            .high => 0b00000000,
            else => 0b00000000,
        };
        try sps_writer.writeU8(constraint_flags);

        // level_idc
        try sps_writer.writeU8(@intFromEnum(self.config.level));

        // seq_parameter_set_id
        try sps_writer.writeUE(0);

        // High profile: chroma format and bit depth
        if (self.config.profile == .high or
            self.config.profile == .high10 or
            self.config.profile == .high422 or
            self.config.profile == .high444)
        {
            try sps_writer.writeUE(1); // chroma_format_idc (4:2:0)
            try sps_writer.writeUE(0); // bit_depth_luma_minus8
            try sps_writer.writeUE(0); // bit_depth_chroma_minus8
            try sps_writer.writeBit(0); // qpprime_y_zero_transform_bypass_flag
            try sps_writer.writeBit(0); // seq_scaling_matrix_present_flag
        }

        // log2_max_frame_num_minus4
        try sps_writer.writeUE(4); // max_frame_num = 2^(4+4) = 256

        // pic_order_cnt_type
        try sps_writer.writeUE(0);
        try sps_writer.writeUE(4); // log2_max_pic_order_cnt_lsb_minus4

        // max_num_ref_frames
        try sps_writer.writeUE(self.config.ref_frames);

        // gaps_in_frame_num_value_allowed_flag
        try sps_writer.writeBit(0);

        // pic_width_in_mbs_minus1
        const mb_width = (self.config.width + 15) / 16;
        try sps_writer.writeUE(mb_width - 1);

        // pic_height_in_map_units_minus1
        const mb_height = (self.config.height + 15) / 16;
        try sps_writer.writeUE(mb_height - 1);

        // frame_mbs_only_flag (progressive)
        try sps_writer.writeBit(1);

        // direct_8x8_inference_flag
        try sps_writer.writeBit(1);

        // frame_cropping
        const crop_right = (mb_width * 16) - self.config.width;
        const crop_bottom = (mb_height * 16) - self.config.height;
        if (crop_right > 0 or crop_bottom > 0) {
            try sps_writer.writeBit(1); // frame_cropping_flag
            try sps_writer.writeUE(0); // crop_left
            try sps_writer.writeUE(crop_right / 2);
            try sps_writer.writeUE(0); // crop_top
            try sps_writer.writeUE(crop_bottom / 2);
        } else {
            try sps_writer.writeBit(0);
        }

        // vui_parameters_present_flag
        try sps_writer.writeBit(1);
        try self.writeVUI(&sps_writer);

        try sps_writer.flush();
        self.sps = try sps_data.toOwnedSlice();

        // Generate PPS (Picture Parameter Set)
        var pps_data = std.ArrayList(u8).init(self.allocator);
        defer pps_data.deinit();

        var pps_writer = BitstreamWriter.init(&pps_data);

        // pic_parameter_set_id
        try pps_writer.writeUE(0);
        // seq_parameter_set_id
        try pps_writer.writeUE(0);

        // entropy_coding_mode_flag (CABAC vs CAVLC)
        try pps_writer.writeBit(if (self.config.cabac) 1 else 0);

        // bottom_field_pic_order_in_frame_present_flag
        try pps_writer.writeBit(0);

        // num_slice_groups_minus1
        try pps_writer.writeUE(0);

        // num_ref_idx_l0_default_active_minus1
        try pps_writer.writeUE(self.config.ref_frames - 1);
        // num_ref_idx_l1_default_active_minus1
        try pps_writer.writeUE(0);

        // weighted_pred_flag
        try pps_writer.writeBit(0);
        // weighted_bipred_idc
        try pps_writer.writeBits(0, 2);

        // pic_init_qp_minus26
        try pps_writer.writeSE(@as(i32, @intCast(self.config.qp)) - 26);
        // pic_init_qs_minus26
        try pps_writer.writeSE(0);

        // chroma_qp_index_offset
        try pps_writer.writeSE(0);

        // deblocking_filter_control_present_flag
        try pps_writer.writeBit(if (self.config.deblock) 1 else 0);

        // constrained_intra_pred_flag
        try pps_writer.writeBit(0);

        // redundant_pic_cnt_present_flag
        try pps_writer.writeBit(0);

        try pps_writer.flush();
        self.pps = try pps_data.toOwnedSlice();
    }

    fn writeVUI(self: *Self, writer: *BitstreamWriter) !void {
        // aspect_ratio_info_present_flag
        try writer.writeBit(0);

        // overscan_info_present_flag
        try writer.writeBit(0);

        // video_signal_type_present_flag
        try writer.writeBit(1);
        try writer.writeBits(5, 3); // video_format (unspecified)
        try writer.writeBit(1); // video_full_range_flag
        try writer.writeBit(1); // colour_description_present_flag
        try writer.writeU8(1); // colour_primaries (BT.709)
        try writer.writeU8(1); // transfer_characteristics
        try writer.writeU8(1); // matrix_coefficients

        // chroma_loc_info_present_flag
        try writer.writeBit(0);

        // timing_info_present_flag
        try writer.writeBit(1);
        const time_scale = self.config.frame_rate.num * 2;
        const num_units = self.config.frame_rate.denom;
        try writer.writeU32(@intCast(num_units)); // num_units_in_tick
        try writer.writeU32(@intCast(time_scale)); // time_scale
        try writer.writeBit(1); // fixed_frame_rate_flag

        // nal_hrd_parameters_present_flag
        try writer.writeBit(0);
        // vcl_hrd_parameters_present_flag
        try writer.writeBit(0);

        // pic_struct_present_flag
        try writer.writeBit(0);

        // bitstream_restriction_flag
        try writer.writeBit(0);
    }

    fn encodeSlice(self: *Self, input_frame: *const VideoFrame, slice_type: SliceType, is_idr: bool) ![]u8 {
        var slice_data = std.ArrayList(u8).init(self.allocator);
        errdefer slice_data.deinit();

        var writer = BitstreamWriter.init(&slice_data);

        // Slice header
        try self.writeSliceHeader(&writer, slice_type, is_idr);

        // Slice data (simplified - actual implementation would do macroblock encoding)
        const mb_width = (self.config.width + 15) / 16;
        const mb_height = (self.config.height + 15) / 16;
        const num_mbs = mb_width * mb_height;

        // Simplified: write placeholder macroblock data
        const qp = try self.calculateQP(slice_type);

        for (0..num_mbs) |_| {
            // In real implementation: encode macroblock with motion estimation,
            // transform, quantization, entropy coding
            try writer.writeUE(0); // mb_type (simplified)
            try writer.writeSE(0); // mb_qp_delta
        }

        try writer.flush();
        return slice_data.toOwnedSlice();
    }

    fn writeSliceHeader(self: *Self, writer: *BitstreamWriter, slice_type: SliceType, is_idr: bool) !void {
        // first_mb_in_slice
        try writer.writeUE(0);

        // slice_type
        try writer.writeUE(@intFromEnum(slice_type));

        // pic_parameter_set_id
        try writer.writeUE(0);

        // frame_num
        try writer.writeBits(self.frame_num & 0xFF, 8);

        if (is_idr) {
            // idr_pic_id
            try writer.writeUE(self.idr_pic_id);
        }

        // pic_order_cnt_lsb
        try writer.writeBits(self.frame_num & 0xFF, 8);

        if (slice_type == .p or slice_type == .b) {
            // num_ref_idx_active_override_flag
            try writer.writeBit(0);
        }

        // ref_pic_list_modification_flag
        try writer.writeBit(0);

        if (is_idr) {
            // no_output_of_prior_pics_flag
            try writer.writeBit(0);
            // long_term_reference_flag
            try writer.writeBit(0);
        }

        // dec_ref_pic_marking
        if (!is_idr) {
            // adaptive_ref_pic_marking_mode_flag
            try writer.writeBit(0);
        }

        if (self.config.cabac and slice_type != .i) {
            // cabac_init_idc
            try writer.writeUE(0);
        }

        // slice_qp_delta
        try writer.writeSE(0);

        if (self.config.deblock) {
            // disable_deblocking_filter_idc
            try writer.writeUE(0);
        }
    }

    fn calculateQP(self: *Self, slice_type: SliceType) !u8 {
        return switch (self.config.rate_control) {
            .cqp => self.config.qp,
            .crf => blk: {
                // CRF mode: adjust QP based on content complexity
                const base_qp = self.config.crf;
                const adjust: i8 = switch (slice_type) {
                    .i => -2,
                    .p => 0,
                    .b => 2,
                    else => 0,
                };
                const qp = @as(i16, base_qp) + adjust;
                break :blk @intCast(std.math.clamp(qp, 0, 51));
            },
            .cbr, .vbr => blk: {
                // Rate control: adjust QP to meet target bitrate
                const target_qp = self.rc_state.qp_avg;
                break :blk @intFromFloat(std.math.clamp(target_qp, 0.0, 51.0));
            },
        };
    }

    fn writeNalUnit(self: *Self, output: *std.ArrayList(u8), nal_type: NalUnitType, data: []const u8) !void {
        // Write start code
        try output.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 1 });

        // Write NAL header
        const nal_ref_idc: u2 = if (nal_type.isKeyframe() or nal_type == .sps or nal_type == .pps) 3 else 0;
        const nal_header: u8 = (@as(u8, nal_ref_idc) << 5) | @intFromEnum(nal_type);
        try output.append(self.allocator, nal_header);

        // Write RBSP data with emulation prevention
        for (data) |byte| {
            if (output.items.len >= 2 and
                output.items[output.items.len - 2] == 0 and
                output.items[output.items.len - 1] == 0 and
                byte <= 0x03)
            {
                // Insert emulation prevention byte
                try output.append(self.allocator, 0x03);
            }
            try output.append(self.allocator, byte);
        }
    }
};

/// Bitstream writer for H.264 syntax elements
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
        // Exp-Golomb coding
        const val_plus_1 = value + 1;
        const leading_zeros = 31 - @clz(val_plus_1);

        // Write leading zeros
        var i: u5 = 0;
        while (i < leading_zeros) : (i += 1) {
            try self.writeBit(0);
        }

        // Write value
        try self.writeBits(val_plus_1, leading_zeros + 1);
    }

    fn writeSE(self: *BitstreamWriter, value: i32) !void {
        // Signed Exp-Golomb
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
