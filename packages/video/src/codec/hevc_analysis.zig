const std = @import("std");
const ExpGolomb = @import("h264_analysis.zig").ExpGolomb;

/// HEVC/H.265 Advanced Analysis
/// Detailed VPS, SPS, PPS, and slice header parsing
pub const HevcAnalysis = struct {
    /// NAL unit types (6 bits in HEVC)
    pub const NalUnitType = enum(u6) {
        trail_n = 0,
        trail_r = 1,
        tsa_n = 2,
        tsa_r = 3,
        stsa_n = 4,
        stsa_r = 5,
        radl_n = 6,
        radl_r = 7,
        rasl_n = 8,
        rasl_r = 9,
        reserved_10 = 10,
        reserved_15 = 15,
        bla_w_lp = 16,
        bla_w_radl = 17,
        bla_n_lp = 18,
        idr_w_radl = 19,
        idr_n_lp = 20,
        cra_nut = 21,
        reserved_22 = 22,
        reserved_23 = 23,
        vps = 32,
        sps = 33,
        pps = 34,
        access_unit_delimiter = 35,
        eos = 36,
        eob = 37,
        filler_data = 38,
        prefix_sei = 39,
        suffix_sei = 40,
        _,
    };

    /// Profile IDC
    pub const ProfileIdc = enum(u5) {
        main = 1,
        main_10 = 2,
        main_still_picture = 3,
        rext = 4,
        high_throughput = 5,
        multiview = 6,
        scalable = 7,
        @"3d" = 8,
        screen_content = 9,
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
    pub const SliceType = enum(u2) {
        b = 0,
        p = 1,
        i = 2,
        _,
    };

    /// Video Parameter Set
    pub const Vps = struct {
        vps_id: u4,
        base_layer_internal_flag: bool,
        base_layer_available_flag: bool,
        max_layers_minus1: u6,
        max_sub_layers_minus1: u3,
        temporal_id_nesting_flag: bool,
        profile_tier_level: ProfileTierLevel,
        sub_layer_ordering_info_present_flag: bool,
        max_dec_pic_buffering: [8]u32,
        max_num_reorder_pics: [8]u32,
        max_latency_increase: [8]u32,
        max_layer_id: u6,
        num_layer_sets_minus1: u32,
        timing_info_present_flag: bool,
        num_units_in_tick: u32,
        time_scale: u32,
    };

    /// Profile, tier, and level
    pub const ProfileTierLevel = struct {
        general_profile_space: u2,
        general_tier_flag: bool,
        general_profile_idc: ProfileIdc,
        general_profile_compatibility_flags: u32,
        general_progressive_source_flag: bool,
        general_interlaced_source_flag: bool,
        general_non_packed_constraint_flag: bool,
        general_frame_only_constraint_flag: bool,
        general_level_idc: u8,
    };

    /// Sequence Parameter Set
    pub const Sps = struct {
        sps_id: u4,
        vps_id: u4,
        max_sub_layers_minus1: u3,
        temporal_id_nesting_flag: bool,
        profile_tier_level: ProfileTierLevel,
        chroma_format_idc: ChromaFormat,
        separate_colour_plane_flag: bool,
        pic_width_in_luma_samples: u32,
        pic_height_in_luma_samples: u32,
        conformance_window_flag: bool,
        conf_win_left_offset: u32,
        conf_win_right_offset: u32,
        conf_win_top_offset: u32,
        conf_win_bottom_offset: u32,
        bit_depth_luma_minus8: u32,
        bit_depth_chroma_minus8: u32,
        log2_max_pic_order_cnt_lsb_minus4: u32,
        sub_layer_ordering_info_present_flag: bool,
        max_dec_pic_buffering: [8]u32,
        max_num_reorder_pics: [8]u32,
        max_latency_increase: [8]u32,
        log2_min_luma_coding_block_size_minus3: u32,
        log2_diff_max_min_luma_coding_block_size: u32,
        log2_min_transform_block_size_minus2: u32,
        log2_diff_max_min_transform_block_size: u32,
        max_transform_hierarchy_depth_inter: u32,
        max_transform_hierarchy_depth_intra: u32,
        scaling_list_enabled_flag: bool,
        amp_enabled_flag: bool,
        sample_adaptive_offset_enabled_flag: bool,
        pcm_enabled_flag: bool,
        num_short_term_ref_pic_sets: u32,
        long_term_ref_pics_present_flag: bool,
        sps_temporal_mvp_enabled_flag: bool,
        strong_intra_smoothing_enabled_flag: bool,
        vui_parameters_present_flag: bool,
        vui: ?VuiParameters,

        /// Get actual width in pixels
        pub fn getWidth(self: *const Sps) u32 {
            if (self.conformance_window_flag) {
                const sub_width_c: u32 = if (self.chroma_format_idc == .yuv420 or self.chroma_format_idc == .yuv422) 2 else 1;
                return self.pic_width_in_luma_samples - (self.conf_win_left_offset + self.conf_win_right_offset) * sub_width_c;
            }
            return self.pic_width_in_luma_samples;
        }

        /// Get actual height in pixels
        pub fn getHeight(self: *const Sps) u32 {
            if (self.conformance_window_flag) {
                const sub_height_c: u32 = if (self.chroma_format_idc == .yuv420) 2 else 1;
                return self.pic_height_in_luma_samples - (self.conf_win_top_offset + self.conf_win_bottom_offset) * sub_height_c;
            }
            return self.pic_height_in_luma_samples;
        }

        /// Get bit depth for luma
        pub fn getLumaBitDepth(self: *const Sps) u32 {
            return self.bit_depth_luma_minus8 + 8;
        }

        /// Get bit depth for chroma
        pub fn getChromaBitDepth(self: *const Sps) u32 {
            return self.bit_depth_chroma_minus8 + 8;
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

    /// VUI parameters (similar to H.264 but with HEVC differences)
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
        matrix_coeffs: u8,
        chroma_loc_info_present_flag: bool,
        chroma_sample_loc_type_top_field: u32,
        chroma_sample_loc_type_bottom_field: u32,
        neutral_chroma_indication_flag: bool,
        field_seq_flag: bool,
        frame_field_info_present_flag: bool,
        default_display_window_flag: bool,
        timing_info_present_flag: bool,
        num_units_in_tick: u32,
        time_scale: u32,
        poc_proportional_to_timing_flag: bool,
        num_ticks_poc_diff_one_minus1: u32,

        pub fn getFrameRate(self: *const VuiParameters) f32 {
            if (self.num_units_in_tick == 0) return 0.0;
            return @as(f32, @floatFromInt(self.time_scale)) / @as(f32, @floatFromInt(self.num_units_in_tick));
        }

        pub fn getAspectRatio(self: *const VuiParameters) f32 {
            if (self.aspect_ratio_idc == 255) {
                if (self.sar_height == 0) return 1.0;
                return @as(f32, @floatFromInt(self.sar_width)) / @as(f32, @floatFromInt(self.sar_height));
            }
            // Same standard SAR table as H.264
            return 1.0;
        }
    };

    /// Picture Parameter Set
    pub const Pps = struct {
        pps_id: u6,
        sps_id: u4,
        dependent_slice_segments_enabled_flag: bool,
        output_flag_present_flag: bool,
        num_extra_slice_header_bits: u3,
        sign_data_hiding_enabled_flag: bool,
        cabac_init_present_flag: bool,
        num_ref_idx_l0_default_active_minus1: u32,
        num_ref_idx_l1_default_active_minus1: u32,
        init_qp_minus26: i32,
        constrained_intra_pred_flag: bool,
        transform_skip_enabled_flag: bool,
        cu_qp_delta_enabled_flag: bool,
        diff_cu_qp_delta_depth: u32,
        cb_qp_offset: i32,
        cr_qp_offset: i32,
        slice_chroma_qp_offsets_present_flag: bool,
        weighted_pred_flag: bool,
        weighted_bipred_flag: bool,
        transquant_bypass_enabled_flag: bool,
        tiles_enabled_flag: bool,
        entropy_coding_sync_enabled_flag: bool,
        loop_filter_across_slices_enabled_flag: bool,
        deblocking_filter_control_present_flag: bool,
        deblocking_filter_override_enabled_flag: bool,
        deblocking_filter_disabled_flag: bool,
        beta_offset_div2: i32,
        tc_offset_div2: i32,
    };

    /// Slice header
    pub const SliceHeader = struct {
        first_slice_segment_in_pic_flag: bool,
        no_output_of_prior_pics_flag: bool,
        pps_id: u6,
        dependent_slice_segment_flag: bool,
        slice_segment_address: u32,
        slice_type: SliceType,
        pic_output_flag: bool,
        colour_plane_id: u2,
        slice_pic_order_cnt_lsb: u32,
        short_term_ref_pic_set_sps_flag: bool,
        num_long_term_sps: u32,
        num_long_term_pics: u32,
        slice_temporal_mvp_enabled_flag: bool,
        slice_sao_luma_flag: bool,
        slice_sao_chroma_flag: bool,
        num_ref_idx_active_override_flag: bool,
        num_ref_idx_l0_active_minus1: u32,
        num_ref_idx_l1_active_minus1: u32,
        mvd_l1_zero_flag: bool,
        cabac_init_flag: bool,
        collocated_from_l0_flag: bool,
        slice_qp_delta: i32,

        pub fn isI(self: *const SliceHeader) bool {
            return self.slice_type == .i;
        }

        pub fn isP(self: *const SliceHeader) bool {
            return self.slice_type == .p;
        }

        pub fn isB(self: *const SliceHeader) bool {
            return self.slice_type == .b;
        }
    };

    /// NAL unit header (2 bytes in HEVC)
    pub const NalHeader = struct {
        forbidden_zero_bit: bool,
        nal_unit_type: NalUnitType,
        nuh_layer_id: u6,
        nuh_temporal_id_plus1: u3,

        pub fn parse(bytes: []const u8) !NalHeader {
            if (bytes.len < 2) return error.InsufficientData;

            const byte0 = bytes[0];
            const byte1 = bytes[1];

            return .{
                .forbidden_zero_bit = (byte0 & 0x80) != 0,
                .nal_unit_type = @enumFromInt(@as(u6, @truncate((byte0 >> 1) & 0x3F))),
                .nuh_layer_id = @truncate(((byte0 & 0x01) << 5) | ((byte1 >> 3) & 0x1F)),
                .nuh_temporal_id_plus1 = @truncate(byte1 & 0x07),
            };
        }

        pub fn isSlice(self: *const NalHeader) bool {
            return switch (self.nal_unit_type) {
                .trail_n, .trail_r, .tsa_n, .tsa_r, .stsa_n, .stsa_r => true,
                .radl_n, .radl_r, .rasl_n, .rasl_r => true,
                .bla_w_lp, .bla_w_radl, .bla_n_lp => true,
                .idr_w_radl, .idr_n_lp, .cra_nut => true,
                else => false,
            };
        }

        pub fn isIrap(self: *const NalHeader) bool {
            return switch (self.nal_unit_type) {
                .bla_w_lp, .bla_w_radl, .bla_n_lp => true,
                .idr_w_radl, .idr_n_lp, .cra_nut => true,
                else => false,
            };
        }
    };
};

/// HEVC VPS parser
pub const VpsParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VpsParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *VpsParser, nal_data: []const u8) !HevcAnalysis.Vps {
        if (nal_data.len < 3) return error.InvalidNalData;

        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[2..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);
        var vps: HevcAnalysis.Vps = undefined;

        vps.vps_id = @truncate(try eg.readBits(4));
        vps.base_layer_internal_flag = (try eg.readBit()) == 1;
        vps.base_layer_available_flag = (try eg.readBit()) == 1;
        vps.max_layers_minus1 = @truncate(try eg.readBits(6));
        vps.max_sub_layers_minus1 = @truncate(try eg.readBits(3));
        vps.temporal_id_nesting_flag = (try eg.readBit()) == 1;

        _ = try eg.readBits(16); // reserved_0xffff_16bits

        vps.profile_tier_level = try self.parseProfileTierLevel(&eg, vps.max_sub_layers_minus1);

        vps.sub_layer_ordering_info_present_flag = (try eg.readBit()) == 1;

        const start_i = if (vps.sub_layer_ordering_info_present_flag) @as(u32, 0) else vps.max_sub_layers_minus1;
        for (start_i..vps.max_sub_layers_minus1 + 1) |i| {
            vps.max_dec_pic_buffering[i] = try eg.readUe();
            vps.max_num_reorder_pics[i] = try eg.readUe();
            vps.max_latency_increase[i] = try eg.readUe();
        }

        vps.max_layer_id = @truncate(try eg.readBits(6));
        vps.num_layer_sets_minus1 = try eg.readUe();

        vps.timing_info_present_flag = (try eg.readBit()) == 1;
        if (vps.timing_info_present_flag) {
            vps.num_units_in_tick = try eg.readBits(32);
            vps.time_scale = try eg.readBits(32);
        } else {
            vps.num_units_in_tick = 0;
            vps.time_scale = 0;
        }

        return vps;
    }

    fn parseProfileTierLevel(self: *VpsParser, eg: *ExpGolomb, max_sub_layers_minus1: u3) !HevcAnalysis.ProfileTierLevel {
        _ = self;
        var ptl: HevcAnalysis.ProfileTierLevel = undefined;

        ptl.general_profile_space = @truncate(try eg.readBits(2));
        ptl.general_tier_flag = (try eg.readBit()) == 1;
        ptl.general_profile_idc = @enumFromInt(@as(u5, @truncate(try eg.readBits(5))));
        ptl.general_profile_compatibility_flags = try eg.readBits(32);
        ptl.general_progressive_source_flag = (try eg.readBit()) == 1;
        ptl.general_interlaced_source_flag = (try eg.readBit()) == 1;
        ptl.general_non_packed_constraint_flag = (try eg.readBit()) == 1;
        ptl.general_frame_only_constraint_flag = (try eg.readBit()) == 1;

        // Skip 44 constraint flags
        _ = try eg.readBits(32);
        _ = try eg.readBits(12);

        ptl.general_level_idc = @truncate(try eg.readBits(8));

        // Skip sub-layer profile/tier/level info
        if (max_sub_layers_minus1 > 0) {
            for (0..max_sub_layers_minus1) |_| {
                _ = try eg.readBit(); // sub_layer_profile_present_flag
                _ = try eg.readBit(); // sub_layer_level_present_flag
            }
        }

        return ptl;
    }
};

/// HEVC SPS parser
pub const SpsParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpsParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *SpsParser, nal_data: []const u8) !HevcAnalysis.Sps {
        if (nal_data.len < 3) return error.InvalidNalData;

        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[2..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);
        var sps: HevcAnalysis.Sps = undefined;

        sps.vps_id = @truncate(try eg.readBits(4));
        sps.max_sub_layers_minus1 = @truncate(try eg.readBits(3));
        sps.temporal_id_nesting_flag = (try eg.readBit()) == 1;

        const vps_parser = VpsParser.init(self.allocator);
        sps.profile_tier_level = try vps_parser.parseProfileTierLevel(&eg, sps.max_sub_layers_minus1);

        sps.sps_id = @truncate(try eg.readUe());
        const chroma_format = try eg.readUe();
        sps.chroma_format_idc = @enumFromInt(@as(u2, @truncate(chroma_format)));

        if (sps.chroma_format_idc == .yuv444) {
            sps.separate_colour_plane_flag = (try eg.readBit()) == 1;
        } else {
            sps.separate_colour_plane_flag = false;
        }

        sps.pic_width_in_luma_samples = try eg.readUe();
        sps.pic_height_in_luma_samples = try eg.readUe();
        sps.conformance_window_flag = (try eg.readBit()) == 1;

        if (sps.conformance_window_flag) {
            sps.conf_win_left_offset = try eg.readUe();
            sps.conf_win_right_offset = try eg.readUe();
            sps.conf_win_top_offset = try eg.readUe();
            sps.conf_win_bottom_offset = try eg.readUe();
        } else {
            sps.conf_win_left_offset = 0;
            sps.conf_win_right_offset = 0;
            sps.conf_win_top_offset = 0;
            sps.conf_win_bottom_offset = 0;
        }

        sps.bit_depth_luma_minus8 = try eg.readUe();
        sps.bit_depth_chroma_minus8 = try eg.readUe();
        sps.log2_max_pic_order_cnt_lsb_minus4 = try eg.readUe();

        sps.sub_layer_ordering_info_present_flag = (try eg.readBit()) == 1;
        const start_i = if (sps.sub_layer_ordering_info_present_flag) @as(u32, 0) else sps.max_sub_layers_minus1;
        for (start_i..sps.max_sub_layers_minus1 + 1) |i| {
            sps.max_dec_pic_buffering[i] = try eg.readUe();
            sps.max_num_reorder_pics[i] = try eg.readUe();
            sps.max_latency_increase[i] = try eg.readUe();
        }

        sps.log2_min_luma_coding_block_size_minus3 = try eg.readUe();
        sps.log2_diff_max_min_luma_coding_block_size = try eg.readUe();
        sps.log2_min_transform_block_size_minus2 = try eg.readUe();
        sps.log2_diff_max_min_transform_block_size = try eg.readUe();
        sps.max_transform_hierarchy_depth_inter = try eg.readUe();
        sps.max_transform_hierarchy_depth_intra = try eg.readUe();

        sps.scaling_list_enabled_flag = (try eg.readBit()) == 1;
        sps.amp_enabled_flag = (try eg.readBit()) == 1;
        sps.sample_adaptive_offset_enabled_flag = (try eg.readBit()) == 1;
        sps.pcm_enabled_flag = (try eg.readBit()) == 1;

        if (sps.pcm_enabled_flag) {
            // Skip PCM parameters
            _ = try eg.readBits(4); // pcm_sample_bit_depth_luma_minus1
            _ = try eg.readBits(4); // pcm_sample_bit_depth_chroma_minus1
            _ = try eg.readUe(); // log2_min_pcm_luma_coding_block_size_minus3
            _ = try eg.readUe(); // log2_diff_max_min_pcm_luma_coding_block_size
            _ = try eg.readBit(); // pcm_loop_filter_disabled_flag
        }

        sps.num_short_term_ref_pic_sets = try eg.readUe();
        // Skip short term ref pic sets parsing

        sps.long_term_ref_pics_present_flag = (try eg.readBit()) == 1;
        sps.sps_temporal_mvp_enabled_flag = (try eg.readBit()) == 1;
        sps.strong_intra_smoothing_enabled_flag = (try eg.readBit()) == 1;
        sps.vui_parameters_present_flag = (try eg.readBit()) == 1;

        if (sps.vui_parameters_present_flag) {
            sps.vui = try self.parseVui(&eg);
        } else {
            sps.vui = null;
        }

        return sps;
    }

    fn parseVui(self: *SpsParser, eg: *ExpGolomb) !HevcAnalysis.VuiParameters {
        _ = self;
        var vui: HevcAnalysis.VuiParameters = undefined;

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
                vui.matrix_coeffs = @truncate(try eg.readBits(8));
            } else {
                vui.colour_primaries = 2;
                vui.transfer_characteristics = 2;
                vui.matrix_coeffs = 2;
            }
        } else {
            vui.video_format = 5;
            vui.video_full_range_flag = false;
            vui.colour_description_present_flag = false;
            vui.colour_primaries = 2;
            vui.transfer_characteristics = 2;
            vui.matrix_coeffs = 2;
        }

        vui.chroma_loc_info_present_flag = (try eg.readBit()) == 1;
        if (vui.chroma_loc_info_present_flag) {
            vui.chroma_sample_loc_type_top_field = try eg.readUe();
            vui.chroma_sample_loc_type_bottom_field = try eg.readUe();
        } else {
            vui.chroma_sample_loc_type_top_field = 0;
            vui.chroma_sample_loc_type_bottom_field = 0;
        }

        vui.neutral_chroma_indication_flag = (try eg.readBit()) == 1;
        vui.field_seq_flag = (try eg.readBit()) == 1;
        vui.frame_field_info_present_flag = (try eg.readBit()) == 1;
        vui.default_display_window_flag = (try eg.readBit()) == 1;

        if (vui.default_display_window_flag) {
            _ = try eg.readUe(); // def_disp_win_left_offset
            _ = try eg.readUe(); // def_disp_win_right_offset
            _ = try eg.readUe(); // def_disp_win_top_offset
            _ = try eg.readUe(); // def_disp_win_bottom_offset
        }

        vui.timing_info_present_flag = (try eg.readBit()) == 1;
        if (vui.timing_info_present_flag) {
            vui.num_units_in_tick = try eg.readBits(32);
            vui.time_scale = try eg.readBits(32);
            vui.poc_proportional_to_timing_flag = (try eg.readBit()) == 1;
            if (vui.poc_proportional_to_timing_flag) {
                vui.num_ticks_poc_diff_one_minus1 = try eg.readUe();
            } else {
                vui.num_ticks_poc_diff_one_minus1 = 0;
            }
        } else {
            vui.num_units_in_tick = 0;
            vui.time_scale = 0;
            vui.poc_proportional_to_timing_flag = false;
            vui.num_ticks_poc_diff_one_minus1 = 0;
        }

        return vui;
    }
};

/// HEVC PPS parser
pub const PpsParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PpsParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *PpsParser, nal_data: []const u8) !HevcAnalysis.Pps {
        if (nal_data.len < 3) return error.InvalidNalData;

        const clean_data = try ExpGolomb.skipEmulationPrevention(nal_data[2..], self.allocator);
        defer self.allocator.free(clean_data);

        var eg = ExpGolomb.init(clean_data);
        var pps: HevcAnalysis.Pps = undefined;

        pps.pps_id = @truncate(try eg.readUe());
        pps.sps_id = @truncate(try eg.readUe());
        pps.dependent_slice_segments_enabled_flag = (try eg.readBit()) == 1;
        pps.output_flag_present_flag = (try eg.readBit()) == 1;
        pps.num_extra_slice_header_bits = @truncate(try eg.readBits(3));
        pps.sign_data_hiding_enabled_flag = (try eg.readBit()) == 1;
        pps.cabac_init_present_flag = (try eg.readBit()) == 1;
        pps.num_ref_idx_l0_default_active_minus1 = try eg.readUe();
        pps.num_ref_idx_l1_default_active_minus1 = try eg.readUe();
        pps.init_qp_minus26 = try eg.readSe();
        pps.constrained_intra_pred_flag = (try eg.readBit()) == 1;
        pps.transform_skip_enabled_flag = (try eg.readBit()) == 1;
        pps.cu_qp_delta_enabled_flag = (try eg.readBit()) == 1;

        if (pps.cu_qp_delta_enabled_flag) {
            pps.diff_cu_qp_delta_depth = try eg.readUe();
        } else {
            pps.diff_cu_qp_delta_depth = 0;
        }

        pps.cb_qp_offset = try eg.readSe();
        pps.cr_qp_offset = try eg.readSe();
        pps.slice_chroma_qp_offsets_present_flag = (try eg.readBit()) == 1;
        pps.weighted_pred_flag = (try eg.readBit()) == 1;
        pps.weighted_bipred_flag = (try eg.readBit()) == 1;
        pps.transquant_bypass_enabled_flag = (try eg.readBit()) == 1;
        pps.tiles_enabled_flag = (try eg.readBit()) == 1;
        pps.entropy_coding_sync_enabled_flag = (try eg.readBit()) == 1;

        // Skip tile info if present
        if (pps.tiles_enabled_flag) {
            // Skip tiles parsing
        }

        pps.loop_filter_across_slices_enabled_flag = (try eg.readBit()) == 1;
        pps.deblocking_filter_control_present_flag = (try eg.readBit()) == 1;

        if (pps.deblocking_filter_control_present_flag) {
            pps.deblocking_filter_override_enabled_flag = (try eg.readBit()) == 1;
            pps.deblocking_filter_disabled_flag = (try eg.readBit()) == 1;
            if (!pps.deblocking_filter_disabled_flag) {
                pps.beta_offset_div2 = try eg.readSe();
                pps.tc_offset_div2 = try eg.readSe();
            } else {
                pps.beta_offset_div2 = 0;
                pps.tc_offset_div2 = 0;
            }
        } else {
            pps.deblocking_filter_override_enabled_flag = false;
            pps.deblocking_filter_disabled_flag = false;
            pps.beta_offset_div2 = 0;
            pps.tc_offset_div2 = 0;
        }

        return pps;
    }
};
