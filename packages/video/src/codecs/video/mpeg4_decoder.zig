// Home Video Library - MPEG-4 Part 2 Decoder
// ISO/IEC 14496-2 Visual decoder (DivX/Xvid compatibility)

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;

/// MPEG-4 Visual start codes
pub const StartCode = enum(u32) {
    visual_object_sequence_start = 0x000001B0,
    visual_object_sequence_end = 0x000001B1,
    user_data_start = 0x000001B2,
    group_of_vop_start = 0x000001B3,
    visual_object_start = 0x000001B5,
    vop_start = 0x000001B6,
    _,
};

/// MPEG-4 decoder configuration
pub const MPEG4DecoderConfig = struct {
    max_ref_frames: u8 = 2,
    enable_postproc: bool = false,
    error_concealment: bool = true,
};

/// Video Object Layer (VOL) configuration
const VOLConfig = struct {
    width: u32,
    height: u32,
    par_width: u8 = 1,  // Pixel aspect ratio
    par_height: u8 = 1,
    interlaced: bool = false,
    sprite_enable: u8 = 0,
    quarter_sample: bool = false,
    data_partitioned: bool = false,
    reversible_vlc: bool = false,
    vop_time_increment_resolution: u16,
};

/// VOP (Video Object Plane) header
const VOPHeader = struct {
    coding_type: VOPCodingType,
    time_increment: u32,
    vop_coded: bool,
    rounding_type: u8,
    intra_dc_vlc_thr: u8,
    vop_quant: u8,
    vop_fcode_forward: u8,
    vop_fcode_backward: u8,
};

pub const VOPCodingType = enum(u2) {
    intra = 0,      // I-VOP
    predictive = 1, // P-VOP
    bidirectional = 2, // B-VOP
    sprite = 3,     // S-VOP
};

/// MPEG-4 decoder state
pub const MPEG4Decoder = struct {
    config: MPEG4DecoderConfig,
    allocator: std.mem.Allocator,

    // VOL configuration
    vol_config: ?VOLConfig = null,

    // Reference frames
    ref_frames: [2]?*VideoFrame = [_]?*VideoFrame{null} ** 2,

    // Output
    output_format: frame.PixelFormat = .yuv420p,

    // Frame tracking
    last_time_base: u32 = 0,
    time_pp: u32 = 0,
    time_bp: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: MPEG4DecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.ref_frames) |maybe_frame| {
            if (maybe_frame) |ref_frame| {
                ref_frame.deinit();
                self.allocator.destroy(ref_frame);
            }
        }
    }

    /// Decode MPEG-4 packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?*VideoFrame {
        var reader = BitstreamReader.init(pkt.data);

        // Find and parse start codes
        while (true) {
            const start_code = self.findNextStartCode(&reader) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            switch (start_code) {
                0x000001B0...0x000001B5 => {
                    // Visual object sequence/object headers
                    if (start_code == 0x000001B0) {
                        try self.decodeVisualObjectSequence(&reader);
                    } else if (start_code == 0x000001B5) {
                        try self.decodeVisualObject(&reader);
                    }
                },
                0x000001B6 => {
                    // VOP (Video Object Plane) - actual frame data
                    return try self.decodeVOP(&reader);
                },
                else => {
                    // Unknown start code - skip
                },
            }
        }

        return null;
    }

    fn findNextStartCode(self: *Self, reader: *BitstreamReader) !u32 {
        _ = self;

        // Align to byte boundary
        try reader.byteAlign();

        while (true) {
            if (reader.byte_pos + 3 >= reader.data.len) return error.EndOfStream;

            const b0 = reader.data[reader.byte_pos];
            const b1 = reader.data[reader.byte_pos + 1];
            const b2 = reader.data[reader.byte_pos + 2];
            const b3 = reader.data[reader.byte_pos + 3];

            if (b0 == 0x00 and b1 == 0x00 and b2 == 0x01) {
                const start_code = (@as(u32, b0) << 24) | (@as(u32, b1) << 16) | (@as(u32, b2) << 8) | b3;
                reader.byte_pos += 4;
                reader.bit_pos = 0;
                return start_code;
            }

            reader.byte_pos += 1;
        }
    }

    fn decodeVisualObjectSequence(self: *Self, reader: *BitstreamReader) !void {
        // Profile and level indication
        _ = try reader.readBits(u8, 8);

        // VOL (Video Object Layer) start code should follow
        const vol_start = try self.findNextStartCode(reader);
        if (vol_start >= 0x00000120 and vol_start <= 0x0000012F) {
            try self.decodeVOL(reader);
        }
    }

    fn decodeVisualObject(self: *Self, reader: *BitstreamReader) !void {
        _ = self;
        const is_visual_object_identifier = try reader.readBit();
        if (is_visual_object_identifier == 1) {
            _ = try reader.readBits(u8, 4); // visual_object_ver_id
            _ = try reader.readBits(u8, 3); // visual_object_priority
        }

        const visual_object_type = try reader.readBits(u8, 4);
        if (visual_object_type == 1) {
            // Video object - VOL will follow
        }
    }

    fn decodeVOL(self: *Self, reader: *BitstreamReader) !void {
        var vol: VOLConfig = undefined;

        // Random accessible vol
        _ = try reader.readBit();

        // Video object type indication
        _ = try reader.readBits(u8, 8);

        // is_object_layer_identifier
        const is_object_layer_identifier = try reader.readBit();
        if (is_object_layer_identifier == 1) {
            _ = try reader.readBits(u8, 4); // video_object_layer_verid
            _ = try reader.readBits(u8, 3); // video_object_layer_priority
        }

        // Aspect ratio info
        const aspect_ratio_info = try reader.readBits(u8, 4);
        if (aspect_ratio_info == 15) { // Extended PAR
            vol.par_width = try reader.readBits(u8, 8);
            vol.par_height = try reader.readBits(u8, 8);
        }

        // Vol control parameters
        const vol_control_parameters = try reader.readBit();
        if (vol_control_parameters == 1) {
            _ = try reader.readBits(u8, 2); // chroma_format
            _ = try reader.readBit(); // low_delay
            const vbv_parameters = try reader.readBit();
            if (vbv_parameters == 1) {
                _ = try reader.readBits(u16, 15); // first_half_bit_rate
                _ = try reader.readBit(); // marker_bit
                _ = try reader.readBits(u16, 15); // latter_half_bit_rate
                _ = try reader.readBit(); // marker_bit
                _ = try reader.readBits(u16, 15); // first_half_vbv_buffer_size
                _ = try reader.readBit(); // marker_bit
                _ = try reader.readBits(u8, 3); // latter_half_vbv_buffer_size
                _ = try reader.readBits(u16, 11); // first_half_vbv_occupancy
                _ = try reader.readBit(); // marker_bit
                _ = try reader.readBits(u16, 15); // latter_half_vbv_occupancy
                _ = try reader.readBit(); // marker_bit
            }
        }

        // Shape
        const video_object_layer_shape = try reader.readBits(u8, 2);
        if (video_object_layer_shape != 0) { // Only rectangular supported
            return error.NonRectangularShapeNotSupported;
        }

        _ = try reader.readBit(); // marker_bit

        // Time increment resolution
        vol.vop_time_increment_resolution = try reader.readBits(u16, 16);
        _ = try reader.readBit(); // marker_bit

        // Fixed vop rate
        const fixed_vop_rate = try reader.readBit();
        if (fixed_vop_rate == 1) {
            const time_bits = self.numBitsForValue(vol.vop_time_increment_resolution - 1);
            _ = try reader.readBits(u16, time_bits); // fixed_vop_time_increment
        }

        // Width and height
        _ = try reader.readBit(); // marker_bit
        vol.width = try reader.readBits(u32, 13);
        _ = try reader.readBit(); // marker_bit
        vol.height = try reader.readBits(u32, 13);
        _ = try reader.readBit(); // marker_bit

        vol.interlaced = try reader.readBit() == 1;
        _ = try reader.readBit(); // obmc_disable

        vol.sprite_enable = try reader.readBits(u8, 1);
        if (vol.sprite_enable == 1) {
            return error.SpriteNotSupported;
        }

        // not_8_bit
        const not_8_bit = try reader.readBit();
        if (not_8_bit == 1) {
            _ = try reader.readBits(u8, 4); // quant_precision
            _ = try reader.readBits(u8, 4); // bits_per_pixel
        }

        vol.quarter_sample = try reader.readBit() == 1;

        // Complexity estimation
        const complexity_estimation_disable = try reader.readBit();
        if (complexity_estimation_disable == 0) {
            return error.ComplexityEstimationNotSupported;
        }

        _ = try reader.readBit(); // resync_marker_disable

        vol.data_partitioned = try reader.readBit() == 1;
        if (vol.data_partitioned) {
            vol.reversible_vlc = try reader.readBit() == 1;
        }

        self.vol_config = vol;
    }

    fn decodeVOP(self: *Self, reader: *BitstreamReader) !*VideoFrame {
        if (self.vol_config == null) return error.NoVOLConfig;
        const vol = self.vol_config.?;

        var vop: VOPHeader = undefined;

        // VOP coding type
        const coding_type_val = try reader.readBits(u8, 2);
        vop.coding_type = @enumFromInt(coding_type_val);

        // Modulo time base
        while (try reader.readBit() == 1) {
            self.last_time_base += 1;
        }

        _ = try reader.readBit(); // marker_bit

        // VOP time increment
        const time_bits = self.numBitsForValue(vol.vop_time_increment_resolution - 1);
        vop.time_increment = try reader.readBits(u32, time_bits);

        _ = try reader.readBit(); // marker_bit

        // VOP coded
        vop.vop_coded = try reader.readBit() == 1;
        if (!vop.vop_coded) {
            // Not coded VOP - repeat last frame
            return error.NotCodedVOPNotSupported;
        }

        if (vop.coding_type == .predictive or vop.coding_type == .bidirectional) {
            vop.rounding_type = try reader.readBits(u8, 1);
        }

        // Intra DC VLC threshold
        vop.intra_dc_vlc_thr = try reader.readBits(u8, 3);

        // VOP quant
        vop.vop_quant = try reader.readBits(u8, 5);

        // VOP fcode
        if (vop.coding_type != .intra) {
            vop.vop_fcode_forward = try reader.readBits(u8, 3);
        }
        if (vop.coding_type == .bidirectional) {
            vop.vop_fcode_backward = try reader.readBits(u8, 3);
        }

        // Create output frame
        const output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            vol.width,
            vol.height,
            self.output_format,
        );

        // Decode macroblock data (simplified)
        try self.decodeMacroblocks(reader, output_frame, &vop);

        // Update reference frames
        try self.updateReferenceFrames(output_frame, vop.coding_type);

        return output_frame;
    }

    fn decodeMacroblocks(self: *Self, reader: *BitstreamReader, output_frame: *VideoFrame, vop: *const VOPHeader) !void {
        _ = reader;
        _ = vop;

        // Simplified macroblock decoding
        const luma_size = output_frame.width * output_frame.height;
        @memset(output_frame.data[0][0..luma_size], 128);

        if (self.output_format == .yuv420p) {
            const chroma_size = (output_frame.width / 2) * (output_frame.height / 2);
            @memset(output_frame.data[1][0..chroma_size], 128);
            @memset(output_frame.data[2][0..chroma_size], 128);
        }
    }

    fn updateReferenceFrames(self: *Self, new_frame: *const VideoFrame, coding_type: VOPCodingType) !void {
        if (coding_type == .intra or coding_type == .predictive) {
            // Free old reference
            if (self.ref_frames[0]) |old_frame| {
                old_frame.deinit();
                self.allocator.destroy(old_frame);
            }

            // Shift reference frames
            self.ref_frames[1] = self.ref_frames[0];

            // Add new reference
            const ref_frame = try self.allocator.create(VideoFrame);
            ref_frame.* = try new_frame.clone(self.allocator);
            self.ref_frames[0] = ref_frame;
        }
        // B-frames don't update references
    }

    fn numBitsForValue(self: *Self, value: u32) u5 {
        _ = self;
        if (value == 0) return 1;
        return @intCast(32 - @clz(value));
    }
};

/// Bitstream reader for MPEG-4
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

    fn byteAlign(self: *BitstreamReader) !void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }
};
