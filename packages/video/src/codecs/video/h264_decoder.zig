// Home Video Library - H.264/AVC Decoder
// ITU-T H.264 video decoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");
const h264_encoder = @import("h264_encoder.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;
const NALUnitType = h264_encoder.NALUnitType;

/// H.264 decoder configuration
pub const H264DecoderConfig = struct {
    max_ref_frames: u8 = 16,
    thread_count: u8 = 1,
    enable_mt: bool = false, // Multithreaded decoding
    error_concealment: bool = true,
};

/// Decoded picture buffer entry
const DPBEntry = struct {
    frame: *VideoFrame,
    frame_num: u32,
    poc: i32, // Picture Order Count
    is_reference: bool,
    is_long_term: bool,
};

/// H.264 Sequence Parameter Set
const SPS = struct {
    profile_idc: u8,
    level_idc: u8,
    sps_id: u8,
    chroma_format_idc: u8,
    bit_depth_luma: u8,
    bit_depth_chroma: u8,
    log2_max_frame_num: u8,
    pic_order_cnt_type: u8,
    log2_max_pic_order_cnt_lsb: u8,
    max_num_ref_frames: u8,
    pic_width_in_mbs: u16,
    pic_height_in_map_units: u16,
    frame_mbs_only_flag: bool,
    direct_8x8_inference_flag: bool,
};

/// H.264 Picture Parameter Set
const PPS = struct {
    pps_id: u8,
    sps_id: u8,
    entropy_coding_mode_flag: bool, // false = CAVLC, true = CABAC
    pic_order_present_flag: bool,
    num_slice_groups: u8,
    num_ref_idx_l0_active: u8,
    num_ref_idx_l1_active: u8,
    weighted_pred_flag: bool,
    weighted_bipred_idc: u8,
    pic_init_qp: i8,
    deblocking_filter_control_present_flag: bool,
};

/// Slice header information
const SliceHeader = struct {
    first_mb_in_slice: u32,
    slice_type: SliceType,
    pps_id: u8,
    frame_num: u32,
    idr_pic_id: u8,
    pic_order_cnt_lsb: u32,
    num_ref_idx_l0_active: u8,
    num_ref_idx_l1_active: u8,
    slice_qp_delta: i32,
};

pub const SliceType = enum(u8) {
    P = 0,
    B = 1,
    I = 2,
    SP = 3,
    SI = 4,
};

/// H.264 decoder state
pub const H264Decoder = struct {
    config: H264DecoderConfig,
    allocator: std.mem.Allocator,

    // Parameter sets
    sps_list: [32]?SPS = [_]?SPS{null} ** 32,
    pps_list: [256]?PPS = [_]?PPS{null} ** 256,
    active_sps: ?*const SPS = null,
    active_pps: ?*const PPS = null,

    // Decoded picture buffer
    dpb: std.ArrayList(DPBEntry),
    max_dpb_size: usize = 16,

    // Frame tracking
    prev_frame_num: u32 = 0,
    prev_poc: i32 = 0,

    // Output
    output_width: u32 = 0,
    output_height: u32 = 0,
    output_format: frame.PixelFormat = .yuv420p,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: H264DecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .dpb = std.ArrayList(DPBEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all frames in DPB
        for (self.dpb.items) |entry| {
            entry.frame.deinit();
            self.allocator.destroy(entry.frame);
        }
        self.dpb.deinit();
    }

    /// Decode H.264 packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?*VideoFrame {
        // Parse NAL units from packet
        var nal_units = try self.parseNALUnits(pkt.data);
        defer nal_units.deinit();

        var output_frame: ?*VideoFrame = null;

        // Process each NAL unit
        for (nal_units.items) |nal| {
            const nal_type: NALUnitType = @enumFromInt(nal.type);

            switch (nal_type) {
                .sps => try self.decodeSPS(nal.data),
                .pps => try self.decodePPS(nal.data),
                .slice_idr, .slice_non_idr => {
                    output_frame = try self.decodeSlice(nal.data, nal_type == .slice_idr);
                },
                .sei => try self.decodeSEI(nal.data),
                .aud => {}, // Access unit delimiter - ignore
                else => {}, // Unknown NAL type - skip
            }
        }

        return output_frame;
    }

    fn parseNALUnits(self: *Self, data: []const u8) !std.ArrayList(NALUnit) {
        var nal_units = std.ArrayList(NALUnit).init(self.allocator);
        errdefer nal_units.deinit();

        var pos: usize = 0;

        while (pos < data.len) {
            // Find start code (0x000001 or 0x00000001)
            const start_code_len = try self.findStartCode(data[pos..]);
            if (start_code_len == 0) break;

            pos += start_code_len;
            if (pos >= data.len) break;

            // Parse NAL unit header
            const nal_header = data[pos];
            const nal_ref_idc = (nal_header >> 5) & 0x3;
            const nal_type = nal_header & 0x1F;

            // Find next start code to determine NAL unit length
            var end_pos = pos + 1;
            while (end_pos < data.len) {
                if (self.findStartCode(data[end_pos..]) catch 0 > 0) break;
                end_pos += 1;
            }

            const nal_data = data[pos + 1 .. end_pos];

            try nal_units.append(.{
                .type = nal_type,
                .ref_idc = nal_ref_idc,
                .data = nal_data,
            });

            pos = end_pos;
        }

        return nal_units;
    }

    fn findStartCode(self: *Self, data: []const u8) !usize {
        _ = self;
        if (data.len < 3) return 0;

        // Check for 0x000001
        if (data[0] == 0 and data[1] == 0 and data[2] == 1) {
            return 3;
        }

        // Check for 0x00000001
        if (data.len >= 4 and data[0] == 0 and data[1] == 0 and data[2] == 0 and data[3] == 1) {
            return 4;
        }

        return 0;
    }

    fn decodeSPS(self: *Self, data: []const u8) !void {
        var reader = BitstreamReader.init(data);

        var sps: SPS = undefined;

        sps.profile_idc = try reader.readBits(u8, 8);
        _ = try reader.readBits(u8, 8); // constraint_set_flags
        sps.level_idc = try reader.readBits(u8, 8);
        sps.sps_id = try reader.readUE();

        // Chroma format
        if (sps.profile_idc == 100 or sps.profile_idc == 110 or
            sps.profile_idc == 122 or sps.profile_idc == 244 or
            sps.profile_idc == 44 or sps.profile_idc == 83 or
            sps.profile_idc == 86 or sps.profile_idc == 118)
        {
            sps.chroma_format_idc = try reader.readUE();
            if (sps.chroma_format_idc == 3) {
                _ = try reader.readBit(); // separate_colour_plane_flag
            }
            sps.bit_depth_luma = try reader.readUE() + 8;
            sps.bit_depth_chroma = try reader.readUE() + 8;
            _ = try reader.readBit(); // qpprime_y_zero_transform_bypass_flag
            const seq_scaling_matrix_present = try reader.readBit();
            if (seq_scaling_matrix_present == 1) {
                // Skip scaling matrices for simplicity
                return error.ScalingMatricesNotSupported;
            }
        } else {
            sps.chroma_format_idc = 1; // 4:2:0
            sps.bit_depth_luma = 8;
            sps.bit_depth_chroma = 8;
        }

        sps.log2_max_frame_num = try reader.readUE() + 4;
        sps.pic_order_cnt_type = try reader.readUE();

        if (sps.pic_order_cnt_type == 0) {
            sps.log2_max_pic_order_cnt_lsb = try reader.readUE() + 4;
        } else if (sps.pic_order_cnt_type == 1) {
            // POC type 1 parsing - skip for simplicity
            return error.POCType1NotSupported;
        }

        sps.max_num_ref_frames = try reader.readUE();
        _ = try reader.readBit(); // gaps_in_frame_num_value_allowed_flag

        sps.pic_width_in_mbs = try reader.readUE() + 1;
        sps.pic_height_in_map_units = try reader.readUE() + 1;
        sps.frame_mbs_only_flag = try reader.readBit() == 1;

        if (!sps.frame_mbs_only_flag) {
            _ = try reader.readBit(); // mb_adaptive_frame_field_flag
        }

        sps.direct_8x8_inference_flag = try reader.readBit() == 1;

        // Store SPS
        self.sps_list[sps.sps_id] = sps;
        self.active_sps = &self.sps_list[sps.sps_id].?;

        // Update output dimensions
        self.output_width = @as(u32, sps.pic_width_in_mbs) * 16;
        self.output_height = @as(u32, sps.pic_height_in_map_units) * 16;
        if (!sps.frame_mbs_only_flag) {
            self.output_height *= 2;
        }
    }

    fn decodePPS(self: *Self, data: []const u8) !void {
        var reader = BitstreamReader.init(data);

        var pps: PPS = undefined;

        pps.pps_id = try reader.readUE();
        pps.sps_id = try reader.readUE();
        pps.entropy_coding_mode_flag = try reader.readBit() == 1;
        pps.pic_order_present_flag = try reader.readBit() == 1;

        pps.num_slice_groups = try reader.readUE() + 1;
        if (pps.num_slice_groups > 1) {
            return error.FMONotSupported; // Flexible Macroblock Ordering not supported
        }

        pps.num_ref_idx_l0_active = try reader.readUE() + 1;
        pps.num_ref_idx_l1_active = try reader.readUE() + 1;
        pps.weighted_pred_flag = try reader.readBit() == 1;
        pps.weighted_bipred_idc = try reader.readBits(u8, 2);
        pps.pic_init_qp = @as(i8, @intCast(try reader.readSE())) + 26;
        _ = try reader.readSE(); // pic_init_qs
        _ = try reader.readSE(); // chroma_qp_index_offset

        pps.deblocking_filter_control_present_flag = try reader.readBit() == 1;

        // Store PPS
        self.pps_list[pps.pps_id] = pps;
        self.active_pps = &self.pps_list[pps.pps_id].?;
    }

    fn decodeSlice(self: *Self, data: []const u8, is_idr: bool) !*VideoFrame {
        var reader = BitstreamReader.init(data);

        // Parse slice header
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
        try self.updateDPB(output_frame, header.frame_num, is_idr);

        return output_frame;
    }

    fn parseSliceHeader(self: *Self, reader: *BitstreamReader, is_idr: bool) !SliceHeader {
        var header: SliceHeader = undefined;

        header.first_mb_in_slice = try reader.readUE();
        const slice_type_val = try reader.readUE();
        header.slice_type = @enumFromInt(slice_type_val % 5);
        header.pps_id = try reader.readUE();

        if (self.active_sps) |sps| {
            header.frame_num = try reader.readBits(u32, sps.log2_max_frame_num);
        } else {
            return error.NoActiveSPS;
        }

        if (is_idr) {
            header.idr_pic_id = try reader.readUE();
        }

        if (self.active_sps) |sps| {
            if (sps.pic_order_cnt_type == 0) {
                header.pic_order_cnt_lsb = try reader.readBits(u32, sps.log2_max_pic_order_cnt_lsb);
            }
        }

        // Reference picture list modifications (skip)
        if (header.slice_type != .I and header.slice_type != .SI) {
            const ref_pic_list_modification_flag_l0 = try reader.readBit();
            if (ref_pic_list_modification_flag_l0 == 1) {
                // Skip modification commands
            }
        }

        // Decode reference picture marking (skip for simplicity)

        // Slice QP
        header.slice_qp_delta = try reader.readSE();

        header.num_ref_idx_l0_active = if (self.active_pps) |pps| pps.num_ref_idx_l0_active else 1;
        header.num_ref_idx_l1_active = if (self.active_pps) |pps| pps.num_ref_idx_l1_active else 1;

        return header;
    }

    fn decodeSliceData(self: *Self, reader: *BitstreamReader, header: SliceHeader, output_frame: *VideoFrame) !void {
        _ = reader;
        _ = header;

        // Simplified slice decoding - in a full decoder, this would:
        // - Parse macroblock data
        // - Perform intra/inter prediction
        // - Apply transforms and quantization
        // - Perform deblocking filter

        // For now, just clear the frame to a default color
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
        // SEI (Supplemental Enhancement Information) parsing
        // Skip for now - contains metadata like timecode, closed captions, etc.
    }

    fn updateDPB(self: *Self, new_frame: *VideoFrame, frame_num: u32, is_reference: bool) !void {
        // Simplified DPB management
        if (is_reference) {
            // Add to DPB
            try self.dpb.append(.{
                .frame = new_frame,
                .frame_num = frame_num,
                .poc = 0, // Simplified POC
                .is_reference = true,
                .is_long_term = false,
            });

            // Limit DPB size
            if (self.dpb.items.len > self.max_dpb_size) {
                const removed = self.dpb.orderedRemove(0);
                removed.frame.deinit();
                self.allocator.destroy(removed.frame);
            }
        }
    }
};

const NALUnit = struct {
    type: u8,
    ref_idc: u8,
    data: []const u8,
};

/// Bitstream reader for H.264
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
        // Exp-Golomb unsigned
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
        // Exp-Golomb signed
        const ue = try self.readUE();
        const value: i32 = @intCast(ue);
        return if (value & 1 == 1)
            (value + 1) >> 1
        else
            -(value >> 1);
    }
};
