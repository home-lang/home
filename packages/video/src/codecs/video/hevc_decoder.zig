// Home Video Library - HEVC/H.265 Decoder
// ITU-T H.265 High Efficiency Video Coding decoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;

/// HEVC NAL unit types
pub const HEVCNALType = enum(u6) {
    TRAIL_N = 0,
    TRAIL_R = 1,
    TSA_N = 2,
    TSA_R = 3,
    STSA_N = 4,
    STSA_R = 5,
    RADL_N = 6,
    RADL_R = 7,
    RASL_N = 8,
    RASL_R = 9,
    BLA_W_LP = 16,
    BLA_W_RADL = 17,
    BLA_N_LP = 18,
    IDR_W_RADL = 19,
    IDR_N_LP = 20,
    CRA_NUT = 21,
    VPS_NUT = 32,
    SPS_NUT = 33,
    PPS_NUT = 34,
    AUD_NUT = 35,
    EOS_NUT = 36,
    EOB_NUT = 37,
    FD_NUT = 38,
    PREFIX_SEI_NUT = 39,
    SUFFIX_SEI_NUT = 40,
    _,
};

/// HEVC decoder configuration
pub const HEVCDecoderConfig = struct {
    max_ref_frames: u8 = 16,
    thread_count: u8 = 1,
    enable_mt: bool = false,
    error_concealment: bool = true,
};

/// Video Parameter Set
const VPS = struct {
    vps_id: u8,
    max_layers: u8,
    max_sub_layers: u8,
    temporal_id_nesting_flag: bool,
};

/// Sequence Parameter Set
const SPS = struct {
    sps_id: u8,
    vps_id: u8,
    max_sub_layers: u8,
    temporal_id_nesting_flag: bool,

    // Profile, tier, level
    profile_idc: u8,
    tier_flag: bool,
    level_idc: u8,

    // Resolution
    pic_width_in_luma_samples: u32,
    pic_height_in_luma_samples: u32,

    // Bit depth
    bit_depth_luma: u8,
    bit_depth_chroma: u8,

    // CTU configuration
    log2_min_luma_coding_block_size: u8,
    log2_diff_max_min_luma_coding_block_size: u8,
    log2_min_luma_transform_block_size: u8,
    log2_diff_max_min_luma_transform_block_size: u8,
    max_transform_hierarchy_depth_inter: u8,
    max_transform_hierarchy_depth_intra: u8,

    // Features
    amp_enabled_flag: bool,
    sample_adaptive_offset_enabled_flag: bool,
    pcm_enabled_flag: bool,

    // Reference frames
    sps_max_dec_pic_buffering: u8,
    sps_max_num_reorder_pics: u8,
    sps_max_latency_increase: u32,

    // Temporal
    log2_max_pic_order_cnt_lsb: u8,
};

/// Picture Parameter Set
const PPS = struct {
    pps_id: u8,
    sps_id: u8,

    // Slice configuration
    dependent_slice_segments_enabled_flag: bool,
    output_flag_present_flag: bool,
    num_extra_slice_header_bits: u8,

    // Quantization
    init_qp: i8,
    constrained_intra_pred_flag: bool,
    transform_skip_enabled_flag: bool,

    // Tiles
    tiles_enabled_flag: bool,
    num_tile_columns: u8,
    num_tile_rows: u8,
    uniform_spacing_flag: bool,

    // Deblocking
    pps_deblocking_filter_disabled_flag: bool,
    deblocking_filter_override_enabled_flag: bool,
};

/// Slice header
const SliceHeader = struct {
    first_slice_segment_in_pic_flag: bool,
    slice_type: SliceType,
    pps_id: u8,
    slice_pic_order_cnt_lsb: u32,
    num_ref_idx_l0_active: u8,
    num_ref_idx_l1_active: u8,
    slice_qp_delta: i32,
};

pub const SliceType = enum(u8) {
    B = 0,
    P = 1,
    I = 2,
};

/// Decoded picture buffer entry
const DPBEntry = struct {
    frame: *VideoFrame,
    poc: i32,
    is_reference: bool,
    is_long_term: bool,
};

/// HEVC decoder state
pub const HEVCDecoder = struct {
    config: HEVCDecoderConfig,
    allocator: std.mem.Allocator,

    // Parameter sets
    vps_list: [16]?VPS = [_]?VPS{null} ** 16,
    sps_list: [16]?SPS = [_]?SPS{null} ** 16,
    pps_list: [64]?PPS = [_]?PPS{null} ** 64,
    active_vps: ?*const VPS = null,
    active_sps: ?*const SPS = null,
    active_pps: ?*const PPS = null,

    // Decoded picture buffer
    dpb: std.ArrayList(DPBEntry),
    max_dpb_size: usize = 16,

    // Frame tracking
    prev_poc: i32 = 0,

    // Output
    output_width: u32 = 0,
    output_height: u32 = 0,
    output_format: frame.PixelFormat = .yuv420p,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: HEVCDecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .dpb = std.ArrayList(DPBEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.dpb.items) |entry| {
            entry.frame.deinit();
            self.allocator.destroy(entry.frame);
        }
        self.dpb.deinit();
    }

    /// Decode HEVC packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?*VideoFrame {
        var nal_units = try self.parseNALUnits(pkt.data);
        defer nal_units.deinit();

        var output_frame: ?*VideoFrame = null;

        for (nal_units.items) |nal| {
            const nal_type: HEVCNALType = @enumFromInt(nal.type);

            switch (nal_type) {
                .VPS_NUT => try self.decodeVPS(nal.data),
                .SPS_NUT => try self.decodeSPS(nal.data),
                .PPS_NUT => try self.decodePPS(nal.data),
                .IDR_W_RADL, .IDR_N_LP, .CRA_NUT, .TRAIL_R, .TRAIL_N => {
                    const is_idr = (nal_type == .IDR_W_RADL or nal_type == .IDR_N_LP);
                    output_frame = try self.decodeSlice(nal.data, is_idr);
                },
                .PREFIX_SEI_NUT, .SUFFIX_SEI_NUT => try self.decodeSEI(nal.data),
                .AUD_NUT => {}, // Access unit delimiter - ignore
                else => {}, // Other NAL types - skip
            }
        }

        return output_frame;
    }

    fn parseNALUnits(self: *Self, data: []const u8) !std.ArrayList(NALUnit) {
        var nal_units = std.ArrayList(NALUnit).init(self.allocator);
        errdefer nal_units.deinit();

        var pos: usize = 0;

        while (pos < data.len) {
            const start_code_len = try self.findStartCode(data[pos..]);
            if (start_code_len == 0) break;

            pos += start_code_len;
            if (pos + 1 >= data.len) break;

            // HEVC NAL unit header is 2 bytes
            const nal_header = (@as(u16, data[pos]) << 8) | data[pos + 1];
            const forbidden_zero_bit = (nal_header >> 15) & 0x1;
            const nal_type = @as(u6, @intCast((nal_header >> 9) & 0x3F));
            const nuh_layer_id = @as(u6, @intCast((nal_header >> 3) & 0x3F));
            const nuh_temporal_id_plus1 = @as(u3, @intCast(nal_header & 0x7));

            _ = forbidden_zero_bit;
            _ = nuh_layer_id;
            _ = nuh_temporal_id_plus1;

            // Find next start code
            var end_pos = pos + 2;
            while (end_pos < data.len) {
                if (self.findStartCode(data[end_pos..]) catch 0 > 0) break;
                end_pos += 1;
            }

            const nal_data = data[pos + 2 .. end_pos];

            try nal_units.append(.{
                .type = nal_type,
                .data = nal_data,
            });

            pos = end_pos;
        }

        return nal_units;
    }

    fn findStartCode(self: *Self, data: []const u8) !usize {
        _ = self;
        if (data.len < 3) return 0;

        if (data[0] == 0 and data[1] == 0 and data[2] == 1) {
            return 3;
        }

        if (data.len >= 4 and data[0] == 0 and data[1] == 0 and data[2] == 0 and data[3] == 1) {
            return 4;
        }

        return 0;
    }

    fn decodeVPS(self: *Self, data: []const u8) !void {
        var reader = BitstreamReader.init(data);

        var vps: VPS = undefined;

        vps.vps_id = try reader.readBits(u8, 4);
        _ = try reader.readBits(u8, 2); // vps_reserved_three_2bits
        vps.max_layers = try reader.readBits(u8, 6) + 1;
        vps.max_sub_layers = try reader.readBits(u8, 3) + 1;
        vps.temporal_id_nesting_flag = try reader.readBit() == 1;
        _ = try reader.readBits(u16, 16); // vps_reserved_0xffff_16bits

        // Store VPS
        self.vps_list[vps.vps_id] = vps;
        self.active_vps = &self.vps_list[vps.vps_id].?;
    }

    fn decodeSPS(self: *Self, data: []const u8) !void {
        var reader = BitstreamReader.init(data);

        var sps: SPS = undefined;

        sps.vps_id = try reader.readBits(u8, 4);
        sps.max_sub_layers = try reader.readBits(u8, 3) + 1;
        sps.temporal_id_nesting_flag = try reader.readBit() == 1;

        // Profile tier level
        sps.profile_idc = try reader.readBits(u8, 5);
        _ = try reader.readBits(u32, 32); // profile_compatibility_flags
        sps.tier_flag = try reader.readBit() == 1;
        sps.level_idc = try reader.readBits(u8, 8);

        // Skip sub-layer profile/tier/level flags
        for (0..sps.max_sub_layers - 1) |_| {
            _ = try reader.readBit(); // sub_layer_profile_present_flag
            _ = try reader.readBit(); // sub_layer_level_present_flag
        }

        sps.sps_id = try reader.readUE();

        // Chroma format
        const chroma_format_idc = try reader.readUE();
        if (chroma_format_idc == 3) {
            _ = try reader.readBit(); // separate_colour_plane_flag
        }

        // Resolution
        sps.pic_width_in_luma_samples = try reader.readUE();
        sps.pic_height_in_luma_samples = try reader.readUE();

        // Conformance window
        const conformance_window_flag = try reader.readBit();
        if (conformance_window_flag == 1) {
            _ = try reader.readUE(); // conf_win_left_offset
            _ = try reader.readUE(); // conf_win_right_offset
            _ = try reader.readUE(); // conf_win_top_offset
            _ = try reader.readUE(); // conf_win_bottom_offset
        }

        // Bit depth
        sps.bit_depth_luma = try reader.readUE() + 8;
        sps.bit_depth_chroma = try reader.readUE() + 8;

        sps.log2_max_pic_order_cnt_lsb = try reader.readUE() + 4;

        // Sub-layer ordering info
        const sps_sub_layer_ordering_info_present_flag = try reader.readBit();
        const i_start: u8 = if (sps_sub_layer_ordering_info_present_flag == 1) 0 else sps.max_sub_layers - 1;

        var i: u8 = i_start;
        while (i < sps.max_sub_layers) : (i += 1) {
            _ = try reader.readUE(); // sps_max_dec_pic_buffering
            _ = try reader.readUE(); // sps_max_num_reorder_pics
            _ = try reader.readUE(); // sps_max_latency_increase_plus1
        }

        // CTU sizes
        sps.log2_min_luma_coding_block_size = try reader.readUE() + 3;
        sps.log2_diff_max_min_luma_coding_block_size = try reader.readUE();
        sps.log2_min_luma_transform_block_size = try reader.readUE() + 2;
        sps.log2_diff_max_min_luma_transform_block_size = try reader.readUE();
        sps.max_transform_hierarchy_depth_inter = try reader.readUE();
        sps.max_transform_hierarchy_depth_intra = try reader.readUE();

        // Scaling list
        const scaling_list_enabled_flag = try reader.readBit();
        if (scaling_list_enabled_flag == 1) {
            return error.ScalingListNotSupported;
        }

        // Features
        sps.amp_enabled_flag = try reader.readBit() == 1;
        sps.sample_adaptive_offset_enabled_flag = try reader.readBit() == 1;
        sps.pcm_enabled_flag = try reader.readBit() == 1;

        if (sps.pcm_enabled_flag) {
            _ = try reader.readBits(u8, 4); // pcm_sample_bit_depth_luma
            _ = try reader.readBits(u8, 4); // pcm_sample_bit_depth_chroma
            _ = try reader.readUE(); // log2_min_pcm_luma_coding_block_size
            _ = try reader.readUE(); // log2_diff_max_min_pcm_luma_coding_block_size
            _ = try reader.readBit(); // pcm_loop_filter_disabled_flag
        }

        // Store SPS
        self.sps_list[sps.sps_id] = sps;
        self.active_sps = &self.sps_list[sps.sps_id].?;

        // Update output dimensions
        self.output_width = sps.pic_width_in_luma_samples;
        self.output_height = sps.pic_height_in_luma_samples;
    }

    fn decodePPS(self: *Self, data: []const u8) !void {
        var reader = BitstreamReader.init(data);

        var pps: PPS = undefined;

        pps.pps_id = try reader.readUE();
        pps.sps_id = try reader.readUE();
        pps.dependent_slice_segments_enabled_flag = try reader.readBit() == 1;
        pps.output_flag_present_flag = try reader.readBit() == 1;
        pps.num_extra_slice_header_bits = try reader.readBits(u8, 3);
        _ = try reader.readBit(); // sign_data_hiding_enabled_flag
        _ = try reader.readBit(); // cabac_init_present_flag

        // Reference indices
        _ = try reader.readUE(); // num_ref_idx_l0_default_active
        _ = try reader.readUE(); // num_ref_idx_l1_default_active

        // QP
        pps.init_qp = @as(i8, @intCast(try reader.readSE())) + 26;
        pps.constrained_intra_pred_flag = try reader.readBit() == 1;
        pps.transform_skip_enabled_flag = try reader.readBit() == 1;

        // CU QP delta
        const cu_qp_delta_enabled_flag = try reader.readBit();
        if (cu_qp_delta_enabled_flag == 1) {
            _ = try reader.readUE(); // diff_cu_qp_delta_depth
        }

        // Chroma QP offset
        _ = try reader.readSE(); // pps_cb_qp_offset
        _ = try reader.readSE(); // pps_cr_qp_offset

        _ = try reader.readBit(); // pps_slice_chroma_qp_offsets_present_flag
        _ = try reader.readBit(); // weighted_pred_flag
        _ = try reader.readBit(); // weighted_bipred_flag
        _ = try reader.readBit(); // transquant_bypass_enabled_flag

        // Tiles
        pps.tiles_enabled_flag = try reader.readBit() == 1;
        _ = try reader.readBit(); // entropy_coding_sync_enabled_flag

        if (pps.tiles_enabled_flag) {
            pps.num_tile_columns = try reader.readUE() + 1;
            pps.num_tile_rows = try reader.readUE() + 1;
            pps.uniform_spacing_flag = try reader.readBit() == 1;

            if (!pps.uniform_spacing_flag) {
                // Column widths
                for (0..pps.num_tile_columns - 1) |_| {
                    _ = try reader.readUE();
                }
                // Row heights
                for (0..pps.num_tile_rows - 1) |_| {
                    _ = try reader.readUE();
                }
            }

            _ = try reader.readBit(); // loop_filter_across_tiles_enabled_flag
        } else {
            pps.num_tile_columns = 1;
            pps.num_tile_rows = 1;
            pps.uniform_spacing_flag = true;
        }

        // Deblocking filter
        _ = try reader.readBit(); // pps_loop_filter_across_slices_enabled_flag
        pps.deblocking_filter_override_enabled_flag = try reader.readBit() == 1;
        pps.pps_deblocking_filter_disabled_flag = try reader.readBit() == 1;

        // Store PPS
        self.pps_list[pps.pps_id] = pps;
        self.active_pps = &self.pps_list[pps.pps_id].?;
    }

    fn decodeSlice(self: *Self, data: []const u8, is_idr: bool) !*VideoFrame {
        var reader = BitstreamReader.init(data);

        const header = try self.parseSliceHeader(&reader, is_idr);

        // Activate PPS and SPS
        if (self.pps_list[header.pps_id]) |*pps| {
            self.active_pps = pps;
            if (self.sps_list[pps.sps_id]) |*sps| {
                self.active_sps = sps;
            } else {
                return error.SPSNotFound;
            }
        } else {
            return error.PPSNotFound;
        }

        // Create output frame
        const output_frame = try self.allocator.create(VideoFrame);
        output_frame.* = try VideoFrame.init(
            self.allocator,
            self.output_width,
            self.output_height,
            self.output_format,
        );

        // Decode slice data
        try self.decodeSliceData(&reader, header, output_frame);

        // Update DPB
        try self.updateDPB(output_frame, @intCast(header.slice_pic_order_cnt_lsb), is_idr);

        return output_frame;
    }

    fn parseSliceHeader(self: *Self, reader: *BitstreamReader, is_idr: bool) !SliceHeader {
        _ = is_idr;
        var header: SliceHeader = undefined;

        header.first_slice_segment_in_pic_flag = try reader.readBit() == 1;

        // no_output_of_prior_pics_flag (for IRAP)
        _ = try reader.readBit();

        header.pps_id = try reader.readUE();

        if (!header.first_slice_segment_in_pic_flag) {
            // dependent_slice_segment_flag
            if (self.active_pps) |pps| {
                if (pps.dependent_slice_segments_enabled_flag) {
                    _ = try reader.readBit();
                }
            }
        }

        // Slice type
        const slice_type_val = try reader.readUE();
        header.slice_type = @enumFromInt(slice_type_val);

        // POC
        if (self.active_sps) |sps| {
            header.slice_pic_order_cnt_lsb = try reader.readBits(u32, sps.log2_max_pic_order_cnt_lsb);
        } else {
            return error.NoActiveSPS;
        }

        // Reference picture set (simplified - skip)

        header.num_ref_idx_l0_active = 1;
        header.num_ref_idx_l1_active = 1;
        header.slice_qp_delta = 0;

        return header;
    }

    fn decodeSliceData(self: *Self, reader: *BitstreamReader, header: SliceHeader, output_frame: *VideoFrame) !void {
        _ = reader;
        _ = header;

        // Simplified slice decoding
        const luma_size = output_frame.width * output_frame.height;
        @memset(output_frame.data[0][0..luma_size], 128);

        if (self.output_format == .yuv420p) {
            const chroma_size = (output_frame.width / 2) * (output_frame.height / 2);
            @memset(output_frame.data[1][0..chroma_size], 128);
            @memset(output_frame.data[2][0..chroma_size], 128);
        }
    }

    fn decodeSEI(self: *Self, data: []const u8) !void {
        _ = self;
        _ = data;
        // SEI parsing - skip for now
    }

    fn updateDPB(self: *Self, new_frame: *VideoFrame, poc: i32, is_reference: bool) !void {
        if (is_reference) {
            try self.dpb.append(.{
                .frame = new_frame,
                .poc = poc,
                .is_reference = true,
                .is_long_term = false,
            });

            if (self.dpb.items.len > self.max_dpb_size) {
                const removed = self.dpb.orderedRemove(0);
                removed.frame.deinit();
                self.allocator.destroy(removed.frame);
            }
        }
    }
};

const NALUnit = struct {
    type: u6,
    data: []const u8,
};

/// Bitstream reader for HEVC
const BitstreamReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    fn init(data: []const u8) BitstreamReader {
        return .{ .data = data };
    }

    fn readBit(self: *BitstreamReader) !u1 {
        if (self.byte_pos >= self.data.len) return error.EndOfStream;

        const bit: u1 = @intCast((self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1);

        self.bit_pos += 1;
        if (self.bit_pos == 8) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }

        return bit;
    }

    fn readBits(self: *BitstreamReader, comptime T: type, num_bits: u5) !T {
        var value: T = 0;
        var i: u5 = 0;
        while (i < num_bits) : (i += 1) {
            const bit = try self.readBit();
            value = (value << 1) | bit;
        }
        return value;
    }

    fn readUE(self: *BitstreamReader) !u8 {
        var leading_zeros: u32 = 0;
        while (try self.readBit() == 0) {
            leading_zeros += 1;
            if (leading_zeros > 31) return error.InvalidExpGolomb;
        }

        if (leading_zeros == 0) return 0;

        var value: u32 = 1;
        var i: u32 = 0;
        while (i < leading_zeros) : (i += 1) {
            const bit = try self.readBit();
            value = (value << 1) | bit;
        }

        return @intCast(value - 1);
    }

    fn readSE(self: *BitstreamReader) !i32 {
        const ue = try self.readUE();
        const value: i32 = @intCast(ue);
        return if (value & 1 == 1)
            (value + 1) >> 1
        else
            -(value >> 1);
    }
};
