const std = @import("std");

/// H.264/AVC Advanced Analysis
/// Detailed SPS, PPS, and slice header parsing for codec inspection
pub const H264Analysis = struct {
    /// NAL unit types
    pub const NalUnitType = enum(u5) {
        unspecified = 0,
        slice_non_idr = 1,
        slice_data_partition_a = 2,
        slice_data_partition_b = 3,
        slice_data_partition_c = 4,
        slice_idr = 5,
        sei = 6,
        sps = 7,
        pps = 8,
        access_unit_delimiter = 9,
        end_of_sequence = 10,
        end_of_stream = 11,
        filler_data = 12,
        sps_ext = 13,
        prefix_nal = 14,
        subset_sps = 15,
        dps = 16,
        reserved_17 = 17,
        reserved_18 = 18,
        slice_aux = 19,
        slice_extension = 20,
        slice_extension_view = 21,
        reserved_22 = 22,
        reserved_23 = 23,
        _,
    };

    /// Profile IDC values
    pub const ProfileIdc = enum(u8) {
        baseline = 66,
        main = 77,
        extended = 88,
        high = 100,
        high_10 = 110,
        high_422 = 122,
        high_444 = 244,
        cavlc_444 = 44,
        _,
    };

    /// Level IDC values (ITU-T H.264 Annex A)
    pub const LevelIdc = enum(u8) {
        level_1_0 = 10,
        level_1_b = 9, // Special case
        level_1_1 = 11,
        level_1_2 = 12,
        level_1_3 = 13,
        level_2_0 = 20,
        level_2_1 = 21,
        level_2_2 = 22,
        level_3_0 = 30,
        level_3_1 = 31,
        level_3_2 = 32,
        level_4_0 = 40,
        level_4_1 = 41,
        level_4_2 = 42,
        level_5_0 = 50,
        level_5_1 = 51,
        level_5_2 = 52,
        level_6_0 = 60,
        level_6_1 = 61,
        level_6_2 = 62,
        _,
    };

    /// Chroma format
    pub const ChromaFormat = enum(u2) {
        monochrome = 0,
        yuv420 = 1,
        yuv422 = 2,
        yuv444 = 3,
    };

    /// Slice type
    pub const SliceType = enum(u3) {
        p = 0,
        b = 1,
        i = 2,
        sp = 3,
        si = 4,
        _,
    };

    /// Sequence Parameter Set (detailed)
    pub const Sps = struct {
        profile_idc: ProfileIdc,
        constraint_flags: u8,
        level_idc: LevelIdc,
        sps_id: u32,

        // High profile fields
        chroma_format_idc: ChromaFormat,
        separate_colour_plane_flag: bool,
        bit_depth_luma: u8,
        bit_depth_chroma: u8,
        qpprime_y_zero_transform_bypass_flag: bool,
        seq_scaling_matrix_present_flag: bool,

        // Resolution
        log2_max_frame_num_minus4: u32,
        pic_order_cnt_type: u32,
        log2_max_pic_order_cnt_lsb_minus4: u32,
        delta_pic_order_always_zero_flag: bool,
        offset_for_non_ref_pic: i32,
        offset_for_top_to_bottom_field: i32,
        num_ref_frames_in_pic_order_cnt_cycle: u32,
        max_num_ref_frames: u32,
        gaps_in_frame_num_value_allowed_flag: bool,
        pic_width_in_mbs_minus1: u32,
        pic_height_in_map_units_minus1: u32,
        frame_mbs_only_flag: bool,
        mb_adaptive_frame_field_flag: bool,
        direct_8x8_inference_flag: bool,

        // Cropping
        frame_cropping_flag: bool,
        frame_crop_left_offset: u32,
        frame_crop_right_offset: u32,
        frame_crop_top_offset: u32,
        frame_crop_bottom_offset: u32,

        // VUI
        vui_parameters_present_flag: bool,
        vui: ?VuiParameters,

        /// Get actual width in pixels
        pub fn getWidth(self: *const Sps) u32 {
            const width = (self.pic_width_in_mbs_minus1 + 1) * 16;
            if (self.frame_cropping_flag) {
                const crop_unit_x = if (self.chroma_format_idc == .monochrome) 1 else 2;
                return width - (self.frame_crop_left_offset + self.frame_crop_right_offset) * crop_unit_x;
            }
            return width;
        }

        /// Get actual height in pixels
        pub fn getHeight(self: *const Sps) u32 {
            const height_in_mbs = self.pic_height_in_map_units_minus1 + 1;
            const height = height_in_mbs * 16 * (if (self.frame_mbs_only_flag) @as(u32, 1) else 2);
            if (self.frame_cropping_flag) {
                const crop_unit_y = if (self.chroma_format_idc == .monochrome) 1 else 2;
                const crop_unit_y_mult = if (self.frame_mbs_only_flag) @as(u32, 1) else 2;
                return height - (self.frame_crop_top_offset + self.frame_crop_bottom_offset) * crop_unit_y * crop_unit_y_mult;
            }
            return height;
        }

        /// Get maximum frame number
        pub fn getMaxFrameNum(self: *const Sps) u32 {
            return @as(u32, 1) << @intCast(self.log2_max_frame_num_minus4 + 4);
        }

        /// Get aspect ratio
        pub fn getAspectRatio(self: *const Sps) ?f32 {
            if (self.vui) |vui| {
                if (vui.aspect_ratio_info_present_flag) {
                    return vui.getAspectRatio();
                }
            }
            return null;
        }

        /// Get frame rate
        pub fn getFrameRate(self: *const Sps) ?f32 {
            if (self.vui) |vui| {
                if (vui.timing_info_present_flag) {
                    return vui.getFrameRate();
                }
            }
            return null;
        }
    };

    /// VUI (Video Usability Information) parameters
    pub const VuiParameters = struct {
        aspect_ratio_info_present_flag: bool,
        aspect_ratio_idc: u8,
        sar_width: u16,
        sar_height: u16,
        overscan_info_present_flag: bool,
        overscan_appropriate_flag: bool,
        video_signal_type_present_flag: bool,
        video_format: u3,
        video_full_range_flag: bool,
        colour_description_present_flag: bool,
        colour_primaries: u8,
        transfer_characteristics: u8,
        matrix_coefficients: u8,
        chroma_loc_info_present_flag: bool,
        chroma_sample_loc_type_top_field: u32,
        chroma_sample_loc_type_bottom_field: u32,
        timing_info_present_flag: bool,
        num_units_in_tick: u32,
        time_scale: u32,
        fixed_frame_rate_flag: bool,

        /// Get aspect ratio as float
        pub fn getAspectRatio(self: *const VuiParameters) f32 {
            // Standard aspect ratio IDCs
            const standard_sar: [17][2]u16 = .{
                .{ 0, 0 }, // Unspecified
                .{ 1, 1 }, // 1:1
                .{ 12, 11 }, // 12:11
                .{ 10, 11 }, // 10:11
                .{ 16, 11 }, // 16:11
                .{ 40, 33 }, // 40:33
                .{ 24, 11 }, // 24:11
                .{ 20, 11 }, // 20:11
                .{ 32, 11 }, // 32:11
                .{ 80, 33 }, // 80:33
                .{ 18, 11 }, // 18:11
                .{ 15, 11 }, // 15:11
                .{ 64, 33 }, // 64:33
                .{ 160, 99 }, // 160:99
                .{ 4, 3 }, // 4:3
                .{ 3, 2 }, // 3:2
                .{ 2, 1 }, // 2:1
            };

            if (self.aspect_ratio_idc == 255) {
                // Extended SAR
                if (self.sar_height == 0) return 1.0;
                return @as(f32, @floatFromInt(self.sar_width)) / @as(f32, @floatFromInt(self.sar_height));
            } else if (self.aspect_ratio_idc < standard_sar.len) {
                const sar = standard_sar[self.aspect_ratio_idc];
                if (sar[1] == 0) return 1.0;
                return @as(f32, @floatFromInt(sar[0])) / @as(f32, @floatFromInt(sar[1]));
            }
            return 1.0;
        }

        /// Get frame rate
        pub fn getFrameRate(self: *const VuiParameters) f32 {
            if (self.num_units_in_tick == 0) return 0.0;
            return @as(f32, @floatFromInt(self.time_scale)) / @as(f32, @floatFromInt(self.num_units_in_tick * 2));
        }
    };

    /// Picture Parameter Set
    pub const Pps = struct {
        pps_id: u32,
        sps_id: u32,
        entropy_coding_mode_flag: bool,
        bottom_field_pic_order_in_frame_present_flag: bool,
        num_slice_groups_minus1: u32,
        slice_group_map_type: u32,
        num_ref_idx_l0_default_active_minus1: u32,
        num_ref_idx_l1_default_active_minus1: u32,
        weighted_pred_flag: bool,
        weighted_bipred_idc: u2,
        pic_init_qp_minus26: i32,
        pic_init_qs_minus26: i32,
        chroma_qp_index_offset: i32,
        deblocking_filter_control_present_flag: bool,
        constrained_intra_pred_flag: bool,
        redundant_pic_cnt_present_flag: bool,

        // High profile
        transform_8x8_mode_flag: bool,
        pic_scaling_matrix_present_flag: bool,
        second_chroma_qp_index_offset: i32,
    };

    /// Slice header
    pub const SliceHeader = struct {
        first_mb_in_slice: u32,
        slice_type: SliceType,
        pps_id: u32,
        frame_num: u32,
        field_pic_flag: bool,
        bottom_field_flag: bool,
        idr_pic_id: u32,
        pic_order_cnt_lsb: u32,
        delta_pic_order_cnt_bottom: i32,
        delta_pic_order_cnt: [2]i32,
        redundant_pic_cnt: u32,
        direct_spatial_mv_pred_flag: bool,
        num_ref_idx_active_override_flag: bool,
        num_ref_idx_l0_active_minus1: u32,
        num_ref_idx_l1_active_minus1: u32,

        /// Check if this is an IDR slice
        pub fn isIdr(self: *const SliceHeader) bool {
            return self.slice_type == .i;
        }

        /// Check if this is an I slice
        pub fn isI(self: *const SliceHeader) bool {
            return self.slice_type == .i;
        }

        /// Check if this is a P slice
        pub fn isP(self: *const SliceHeader) bool {
            return self.slice_type == .p;
        }

        /// Check if this is a B slice
        pub fn isB(self: *const SliceHeader) bool {
            return self.slice_type == .b;
        }
    };

    /// NAL unit header
    pub const NalHeader = struct {
        forbidden_zero_bit: bool,
        nal_ref_idc: u2,
        nal_unit_type: NalUnitType,

        pub fn parse(byte: u8) NalHeader {
            return .{
                .forbidden_zero_bit = (byte & 0x80) != 0,
                .nal_ref_idc = @truncate((byte >> 5) & 0x03),
                .nal_unit_type = @enumFromInt(@as(u5, @truncate(byte & 0x1F))),
            };
        }

        pub fn isSlice(self: *const NalHeader) bool {
            return switch (self.nal_unit_type) {
                .slice_non_idr, .slice_idr, .slice_data_partition_a => true,
                else => false,
            };
        }
    };
};

/// Exponential-Golomb decoder for H.264 bitstream
pub const ExpGolomb = struct {
    data: []const u8,
    byte_offset: usize,
    bit_offset: u3,

    pub fn init(data: []const u8) ExpGolomb {
        return .{
            .data = data,
            .byte_offset = 0,
            .bit_offset = 0,
        };
    }

    /// Read single bit
    pub fn readBit(self: *ExpGolomb) !u1 {
        if (self.byte_offset >= self.data.len) return error.EndOfData;

        const bit: u1 = @truncate((self.data[self.byte_offset] >> (7 - self.bit_offset)) & 1);

        self.bit_offset += 1;
        if (self.bit_offset == 8) {
            self.bit_offset = 0;
            self.byte_offset += 1;
        }

        return bit;
    }

    /// Read n bits as unsigned integer
    pub fn readBits(self: *ExpGolomb, n: u32) !u32 {
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const bit = try self.readBit();
            value = (value << 1) | bit;
        }
        return value;
    }

    /// Read unsigned exponential-Golomb code
    pub fn readUe(self: *ExpGolomb) !u32 {
        var leading_zeros: u32 = 0;
        while (try self.readBit() == 0) {
            leading_zeros += 1;
            if (leading_zeros > 31) return error.InvalidExpGolomb;
        }

        if (leading_zeros == 0) return 0;

        const value = try self.readBits(leading_zeros);
        return ((@as(u32, 1) << @intCast(leading_zeros)) - 1) + value;
    }

    /// Read signed exponential-Golomb code
    pub fn readSe(self: *ExpGolomb) !i32 {
        const code = try self.readUe();
        const sign: i32 = if (code & 1 == 1) 1 else -1;
        return sign * @as(i32, @intCast((code + 1) >> 1));
    }

    /// Skip emulation prevention bytes
    pub fn skipEmulationPrevention(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);

        var i: usize = 0;
        while (i < data.len) {
            if (i + 2 < data.len and data[i] == 0x00 and data[i + 1] == 0x00 and data[i + 2] == 0x03) {
                try result.append(0x00);
                try result.append(0x00);
                i += 3; // Skip the 0x03
            } else {
                try result.append(data[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }
};

/// H.264 SPS parser
pub const SpsParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpsParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *SpsParser, nal_data: []const u8) !H264Analysis.Sps {
        // Skip NAL header
        if (nal_data.len < 2) return error.InvalidNalData;

        // Remove emulation prevention bytes
        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[1..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);

        var sps: H264Analysis.Sps = undefined;

        sps.profile_idc = @enumFromInt(@as(u8, @truncate(try eg.readBits(8))));
        sps.constraint_flags = @truncate(try eg.readBits(8));
        sps.level_idc = @enumFromInt(@as(u8, @truncate(try eg.readBits(8))));
        sps.sps_id = try eg.readUe();

        // High profile fields
        if (@intFromEnum(sps.profile_idc) == 100 or @intFromEnum(sps.profile_idc) == 110 or
            @intFromEnum(sps.profile_idc) == 122 or @intFromEnum(sps.profile_idc) == 244 or
            @intFromEnum(sps.profile_idc) == 44)
        {
            const chroma_format = try eg.readUe();
            sps.chroma_format_idc = @enumFromInt(@as(u2, @truncate(chroma_format)));

            if (sps.chroma_format_idc == .yuv444) {
                sps.separate_colour_plane_flag = (try eg.readBit()) == 1;
            } else {
                sps.separate_colour_plane_flag = false;
            }

            const bit_depth_luma_minus8 = try eg.readUe();
            sps.bit_depth_luma = @truncate(bit_depth_luma_minus8 + 8);

            const bit_depth_chroma_minus8 = try eg.readUe();
            sps.bit_depth_chroma = @truncate(bit_depth_chroma_minus8 + 8);

            sps.qpprime_y_zero_transform_bypass_flag = (try eg.readBit()) == 1;
            sps.seq_scaling_matrix_present_flag = (try eg.readBit()) == 1;

            if (sps.seq_scaling_matrix_present_flag) {
                // Skip scaling matrices
                const num_matrices = if (sps.chroma_format_idc != .yuv444) @as(u32, 8) else 12;
                var i: u32 = 0;
                while (i < num_matrices) : (i += 1) {
                    const present = try eg.readBit();
                    if (present == 1) {
                        try self.skipScalingList(&eg, if (i < 6) 16 else 64);
                    }
                }
            }
        } else {
            sps.chroma_format_idc = .yuv420;
            sps.separate_colour_plane_flag = false;
            sps.bit_depth_luma = 8;
            sps.bit_depth_chroma = 8;
            sps.qpprime_y_zero_transform_bypass_flag = false;
            sps.seq_scaling_matrix_present_flag = false;
        }

        sps.log2_max_frame_num_minus4 = try eg.readUe();
        sps.pic_order_cnt_type = try eg.readUe();

        if (sps.pic_order_cnt_type == 0) {
            sps.log2_max_pic_order_cnt_lsb_minus4 = try eg.readUe();
            sps.delta_pic_order_always_zero_flag = false;
            sps.offset_for_non_ref_pic = 0;
            sps.offset_for_top_to_bottom_field = 0;
            sps.num_ref_frames_in_pic_order_cnt_cycle = 0;
        } else if (sps.pic_order_cnt_type == 1) {
            sps.delta_pic_order_always_zero_flag = (try eg.readBit()) == 1;
            sps.offset_for_non_ref_pic = try eg.readSe();
            sps.offset_for_top_to_bottom_field = try eg.readSe();
            sps.num_ref_frames_in_pic_order_cnt_cycle = try eg.readUe();
            // Skip offset_for_ref_frame array
            var i: u32 = 0;
            while (i < sps.num_ref_frames_in_pic_order_cnt_cycle) : (i += 1) {
                _ = try eg.readSe();
            }
            sps.log2_max_pic_order_cnt_lsb_minus4 = 0;
        } else {
            sps.log2_max_pic_order_cnt_lsb_minus4 = 0;
            sps.delta_pic_order_always_zero_flag = false;
            sps.offset_for_non_ref_pic = 0;
            sps.offset_for_top_to_bottom_field = 0;
            sps.num_ref_frames_in_pic_order_cnt_cycle = 0;
        }

        sps.max_num_ref_frames = try eg.readUe();
        sps.gaps_in_frame_num_value_allowed_flag = (try eg.readBit()) == 1;
        sps.pic_width_in_mbs_minus1 = try eg.readUe();
        sps.pic_height_in_map_units_minus1 = try eg.readUe();
        sps.frame_mbs_only_flag = (try eg.readBit()) == 1;

        if (!sps.frame_mbs_only_flag) {
            sps.mb_adaptive_frame_field_flag = (try eg.readBit()) == 1;
        } else {
            sps.mb_adaptive_frame_field_flag = false;
        }

        sps.direct_8x8_inference_flag = (try eg.readBit()) == 1;
        sps.frame_cropping_flag = (try eg.readBit()) == 1;

        if (sps.frame_cropping_flag) {
            sps.frame_crop_left_offset = try eg.readUe();
            sps.frame_crop_right_offset = try eg.readUe();
            sps.frame_crop_top_offset = try eg.readUe();
            sps.frame_crop_bottom_offset = try eg.readUe();
        } else {
            sps.frame_crop_left_offset = 0;
            sps.frame_crop_right_offset = 0;
            sps.frame_crop_top_offset = 0;
            sps.frame_crop_bottom_offset = 0;
        }

        sps.vui_parameters_present_flag = (try eg.readBit()) == 1;

        if (sps.vui_parameters_present_flag) {
            sps.vui = try self.parseVui(&eg);
        } else {
            sps.vui = null;
        }

        return sps;
    }

    fn parseVui(self: *SpsParser, eg: *ExpGolomb) !H264Analysis.VuiParameters {
        _ = self;
        var vui: H264Analysis.VuiParameters = undefined;

        vui.aspect_ratio_info_present_flag = (try eg.readBit()) == 1;
        if (vui.aspect_ratio_info_present_flag) {
            vui.aspect_ratio_idc = @truncate(try eg.readBits(8));
            if (vui.aspect_ratio_idc == 255) {
                vui.sar_width = @truncate(try eg.readBits(16));
                vui.sar_height = @truncate(try eg.readBits(16));
            } else {
                vui.sar_width = 0;
                vui.sar_height = 0;
            }
        } else {
            vui.aspect_ratio_idc = 0;
            vui.sar_width = 0;
            vui.sar_height = 0;
        }

        vui.overscan_info_present_flag = (try eg.readBit()) == 1;
        if (vui.overscan_info_present_flag) {
            vui.overscan_appropriate_flag = (try eg.readBit()) == 1;
        } else {
            vui.overscan_appropriate_flag = false;
        }

        vui.video_signal_type_present_flag = (try eg.readBit()) == 1;
        if (vui.video_signal_type_present_flag) {
            vui.video_format = @truncate(try eg.readBits(3));
            vui.video_full_range_flag = (try eg.readBit()) == 1;
            vui.colour_description_present_flag = (try eg.readBit()) == 1;
            if (vui.colour_description_present_flag) {
                vui.colour_primaries = @truncate(try eg.readBits(8));
                vui.transfer_characteristics = @truncate(try eg.readBits(8));
                vui.matrix_coefficients = @truncate(try eg.readBits(8));
            } else {
                vui.colour_primaries = 2;
                vui.transfer_characteristics = 2;
                vui.matrix_coefficients = 2;
            }
        } else {
            vui.video_format = 5;
            vui.video_full_range_flag = false;
            vui.colour_description_present_flag = false;
            vui.colour_primaries = 2;
            vui.transfer_characteristics = 2;
            vui.matrix_coefficients = 2;
        }

        vui.chroma_loc_info_present_flag = (try eg.readBit()) == 1;
        if (vui.chroma_loc_info_present_flag) {
            vui.chroma_sample_loc_type_top_field = try eg.readUe();
            vui.chroma_sample_loc_type_bottom_field = try eg.readUe();
        } else {
            vui.chroma_sample_loc_type_top_field = 0;
            vui.chroma_sample_loc_type_bottom_field = 0;
        }

        vui.timing_info_present_flag = (try eg.readBit()) == 1;
        if (vui.timing_info_present_flag) {
            vui.num_units_in_tick = try eg.readBits(32);
            vui.time_scale = try eg.readBits(32);
            vui.fixed_frame_rate_flag = (try eg.readBit()) == 1;
        } else {
            vui.num_units_in_tick = 0;
            vui.time_scale = 0;
            vui.fixed_frame_rate_flag = false;
        }

        return vui;
    }

    fn skipScalingList(self: *SpsParser, eg: *ExpGolomb, size: u32) !void {
        _ = self;
        var last_scale: i32 = 8;
        var next_scale: i32 = 8;
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            if (next_scale != 0) {
                const delta_scale = try eg.readSe();
                next_scale = (last_scale + delta_scale + 256) % 256;
            }
            last_scale = if (next_scale == 0) last_scale else next_scale;
        }
    }
};

/// H.264 PPS parser
pub const PpsParser = struct {
    allocator: std.mem.Allocator;

    pub fn init(allocator: std.mem.Allocator) PpsParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *PpsParser, nal_data: []const u8) !H264Analysis.Pps {
        if (nal_data.len < 2) return error.InvalidNalData;

        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[1..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);
        var pps: H264Analysis.Pps = undefined;

        pps.pps_id = try eg.readUe();
        pps.sps_id = try eg.readUe();
        pps.entropy_coding_mode_flag = (try eg.readBit()) == 1;
        pps.bottom_field_pic_order_in_frame_present_flag = (try eg.readBit()) == 1;
        pps.num_slice_groups_minus1 = try eg.readUe();

        if (pps.num_slice_groups_minus1 > 0) {
            pps.slice_group_map_type = try eg.readUe();
            // Skip slice group details
        } else {
            pps.slice_group_map_type = 0;
        }

        pps.num_ref_idx_l0_default_active_minus1 = try eg.readUe();
        pps.num_ref_idx_l1_default_active_minus1 = try eg.readUe();
        pps.weighted_pred_flag = (try eg.readBit()) == 1;
        pps.weighted_bipred_idc = @truncate(try eg.readBits(2));
        pps.pic_init_qp_minus26 = try eg.readSe();
        pps.pic_init_qs_minus26 = try eg.readSe();
        pps.chroma_qp_index_offset = try eg.readSe();
        pps.deblocking_filter_control_present_flag = (try eg.readBit()) == 1;
        pps.constrained_intra_pred_flag = (try eg.readBit()) == 1;
        pps.redundant_pic_cnt_present_flag = (try eg.readBit()) == 1;

        // High profile fields (if more data available)
        pps.transform_8x8_mode_flag = false;
        pps.pic_scaling_matrix_present_flag = false;
        pps.second_chroma_qp_index_offset = pps.chroma_qp_index_offset;

        // Try to read more data
        const has_more = eg.readBit() catch return pps;
        if (has_more == 1) {
            eg.byte_offset -= 1; // Rewind
            eg.bit_offset = if (eg.bit_offset == 0) 7 else eg.bit_offset - 1;

            pps.transform_8x8_mode_flag = (try eg.readBit()) == 1;
            pps.pic_scaling_matrix_present_flag = (try eg.readBit()) == 1;

            if (pps.pic_scaling_matrix_present_flag) {
                // Skip scaling matrices
            }

            pps.second_chroma_qp_index_offset = try eg.readSe();
        }

        return pps;
    }
};

/// H.264 slice header parser
pub const SliceHeaderParser = struct {
    allocator: std.mem.Allocator;

    pub fn init(allocator: std.mem.Allocator) SliceHeaderParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *SliceHeaderParser, nal_data: []const u8, sps: *const H264Analysis.Sps, pps: *const H264Analysis.Pps) !H264Analysis.SliceHeader {
        if (nal_data.len < 2) return error.InvalidNalData;

        const nal_header = H264Analysis.NalHeader.parse(nal_data[0]);

        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[1..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);
        var header: H264Analysis.SliceHeader = undefined;

        header.first_mb_in_slice = try eg.readUe();

        const slice_type_val = try eg.readUe();
        header.slice_type = @enumFromInt(@as(u3, @truncate(slice_type_val % 5)));

        header.pps_id = try eg.readUe();
        header.frame_num = try eg.readBits(sps.log2_max_frame_num_minus4 + 4);

        if (!sps.frame_mbs_only_flag) {
            header.field_pic_flag = (try eg.readBit()) == 1;
            if (header.field_pic_flag) {
                header.bottom_field_flag = (try eg.readBit()) == 1;
            } else {
                header.bottom_field_flag = false;
            }
        } else {
            header.field_pic_flag = false;
            header.bottom_field_flag = false;
        }

        if (nal_header.nal_unit_type == .slice_idr) {
            header.idr_pic_id = try eg.readUe();
        } else {
            header.idr_pic_id = 0;
        }

        if (sps.pic_order_cnt_type == 0) {
            header.pic_order_cnt_lsb = try eg.readBits(sps.log2_max_pic_order_cnt_lsb_minus4 + 4);
            if (pps.bottom_field_pic_order_in_frame_present_flag and !header.field_pic_flag) {
                header.delta_pic_order_cnt_bottom = try eg.readSe();
            } else {
                header.delta_pic_order_cnt_bottom = 0;
            }
        } else {
            header.pic_order_cnt_lsb = 0;
            header.delta_pic_order_cnt_bottom = 0;
        }

        header.delta_pic_order_cnt = .{ 0, 0 };
        header.redundant_pic_cnt = 0;
        header.direct_spatial_mv_pred_flag = false;
        header.num_ref_idx_active_override_flag = false;
        header.num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
        header.num_ref_idx_l1_active_minus1 = pps.num_ref_idx_l1_default_active_minus1;

        return header;
    }
};
