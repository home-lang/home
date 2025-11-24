// Home Video Library - AV1 Decoder
// Alliance for Open Media AV1 decoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");
const av1_encoder = @import("av1_encoder.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;
const AV1Profile = av1_encoder.AV1Profile;
const AV1FrameType = av1_encoder.AV1FrameType;
const OBUType = av1_encoder.OBUType;
const ColorPrimaries = av1_encoder.ColorPrimaries;
const TransferCharacteristics = av1_encoder.TransferCharacteristics;
const MatrixCoefficients = av1_encoder.MatrixCoefficients;
const ColorRange = av1_encoder.ColorRange;

/// AV1 decoder configuration
pub const AV1DecoderConfig = struct {
    thread_count: u8 = 1,
    enable_cdef: bool = true,
    enable_restoration: bool = true,
    error_concealment: bool = true,
};

/// Sequence header state
const SequenceHeader = struct {
    profile: AV1Profile,
    still_picture: bool,
    max_frame_width: u32,
    max_frame_height: u32,
    bit_depth: u8,
    use_128x128_superblock: bool,
    enable_order_hint: bool,
    order_hint_bits: u8,
    enable_cdef: bool,
    enable_restoration: bool,
    color_primaries: ColorPrimaries,
    transfer_characteristics: TransferCharacteristics,
    matrix_coefficients: MatrixCoefficients,
    color_range: ColorRange,
};

/// Frame header state
const FrameHeader = struct {
    frame_type: AV1FrameType,
    show_frame: bool,
    show_existing_frame: bool,
    frame_to_show_map_idx: u8,
    frame_width: u32,
    frame_height: u32,
    render_width: u32,
    render_height: u32,
    refresh_frame_flags: u8,
    order_hint: u32,

    // Quantization
    base_q_idx: u8,

    // Tile info
    tile_cols: u8,
    tile_rows: u8,
};

/// Decoded picture buffer entry
const DPBEntry = struct {
    frame: *VideoFrame,
    order_hint: u32,
    ref_valid: bool,
};

/// AV1 decoder state
pub const AV1Decoder = struct {
    config: AV1DecoderConfig,
    allocator: std.mem.Allocator,

    // Sequence header
    sequence_header: ?SequenceHeader = null,

    // Reference frames (8 slots in AV1)
    ref_frames: [8]?DPBEntry = [_]?DPBEntry{null} ** 8,

    // Current frame state
    current_frame_header: ?FrameHeader = null,

    // Output format
    output_format: frame.PixelFormat = .yuv420p,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: AV1DecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.ref_frames) |maybe_entry| {
            if (maybe_entry) |entry| {
                entry.frame.deinit();
                self.allocator.destroy(entry.frame);
            }
        }
    }

    /// Decode AV1 packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?*VideoFrame {
        var obu_list = try self.parseOBUs(pkt.data);
        defer obu_list.deinit();

        var output_frame: ?*VideoFrame = null;

        for (obu_list.items) |obu| {
            switch (obu.obu_type) {
                .sequence_header => try self.decodeSequenceHeader(obu.payload),
                .temporal_delimiter => {}, // Just a marker
                .frame_header => {
                    try self.decodeFrameHeader(obu.payload);
                },
                .tile_group => {
                    if (self.current_frame_header) |header| {
                        output_frame = try self.decodeTileGroup(obu.payload, &header);
                    }
                },
                .frame => {
                    // Combined frame header + tile group
                    output_frame = try self.decodeFrame(obu.payload);
                },
                .metadata => try self.decodeMetadata(obu.payload),
                .padding => {}, // Skip padding
                else => {}, // Unknown OBU type
            }
        }

        return output_frame;
    }

    fn parseOBUs(self: *Self, data: []const u8) !std.ArrayList(OBU) {
        var obu_list = std.ArrayList(OBU).init(self.allocator);
        errdefer obu_list.deinit();

        var pos: usize = 0;

        while (pos < data.len) {
            if (pos >= data.len) break;

            // Parse OBU header
            const header_byte = data[pos];
            pos += 1;

            const obu_forbidden_bit = (header_byte >> 7) & 0x1;
            const obu_type_val = @as(u4, @intCast((header_byte >> 3) & 0xF));
            const obu_extension_flag = (header_byte >> 2) & 0x1;
            const obu_has_size_field = (header_byte >> 1) & 0x1;

            if (obu_forbidden_bit != 0) return error.InvalidOBU;

            const obu_type: OBUType = @enumFromInt(obu_type_val);

            // Extension header (optional)
            if (obu_extension_flag == 1) {
                if (pos >= data.len) break;
                _ = data[pos]; // extension_header_byte
                pos += 1;
            }

            // OBU size
            var obu_size: usize = 0;
            if (obu_has_size_field == 1) {
                const size_result = try self.readLEB128(data[pos..]);
                obu_size = size_result.value;
                pos += size_result.bytes_read;
            } else {
                // Size is rest of data
                obu_size = data.len - pos;
            }

            if (pos + obu_size > data.len) break;

            const payload = data[pos .. pos + obu_size];
            try obu_list.append(.{
                .obu_type = obu_type,
                .payload = payload,
            });

            pos += obu_size;
        }

        return obu_list;
    }

    fn readLEB128(self: *Self, data: []const u8) !struct { value: usize, bytes_read: usize } {
        _ = self;
        var value: usize = 0;
        var bytes_read: usize = 0;

        for (data, 0..) |byte, i| {
            value |= @as(usize, byte & 0x7F) << @intCast(i * 7);
            bytes_read += 1;
            if ((byte & 0x80) == 0) break;
            if (bytes_read >= 8) return error.InvalidLEB128;
        }

        return .{ .value = value, .bytes_read = bytes_read };
    }

    fn decodeSequenceHeader(self: *Self, payload: []const u8) !void {
        var reader = BitstreamReader.init(payload);

        var seq: SequenceHeader = undefined;

        // Profile
        const profile_val = try reader.readBits(u8, 3);
        seq.profile = @enumFromInt(profile_val);

        // Still picture
        seq.still_picture = try reader.readBit() == 1;

        // Reduced still picture header
        const reduced_still_picture_header = try reader.readBit();
        if (reduced_still_picture_header == 1) {
            // Simplified header for still pictures
            return error.StillPictureNotSupported;
        }

        // Timing info present
        const timing_info_present_flag = try reader.readBit();
        if (timing_info_present_flag == 1) {
            // Skip timing info
            _ = try reader.readBits(u32, 32); // num_units_in_display_tick
            _ = try reader.readBits(u32, 32); // time_scale
            const equal_picture_interval = try reader.readBit();
            if (equal_picture_interval == 1) {
                _ = try reader.readUVLC(); // num_ticks_per_picture
            }
        }

        // Initial display delay present
        const initial_display_delay_present_flag = try reader.readBit();
        _ = initial_display_delay_present_flag;

        // Operating points
        const operating_points_cnt_minus_1 = try reader.readBits(u8, 5);
        for (0..operating_points_cnt_minus_1 + 1) |_| {
            _ = try reader.readBits(u16, 12); // operating_point_idc
            const seq_level_idx = try reader.readBits(u8, 5);
            if (seq_level_idx > 7) {
                _ = try reader.readBit(); // seq_tier
            }
        }

        // Frame size
        const frame_width_bits_minus_1 = try reader.readBits(u8, 4);
        const frame_height_bits_minus_1 = try reader.readBits(u8, 4);
        const max_frame_width_minus_1 = try reader.readBits(u32, frame_width_bits_minus_1 + 1);
        const max_frame_height_minus_1 = try reader.readBits(u32, frame_height_bits_minus_1 + 1);

        seq.max_frame_width = max_frame_width_minus_1 + 1;
        seq.max_frame_height = max_frame_height_minus_1 + 1;

        // Use 128x128 superblock
        seq.use_128x128_superblock = try reader.readBit() == 1;

        // Enable features
        _ = try reader.readBit(); // enable_filter_intra
        _ = try reader.readBit(); // enable_intra_edge_filter
        _ = try reader.readBit(); // enable_interintra_compound
        _ = try reader.readBit(); // enable_masked_compound
        _ = try reader.readBit(); // enable_warped_motion

        seq.enable_order_hint = try reader.readBit() == 1;
        if (seq.enable_order_hint) {
            _ = try reader.readBit(); // enable_jnt_comp
            _ = try reader.readBit(); // enable_ref_frame_mvs
        }

        _ = try reader.readBit(); // seq_choose_screen_content_tools
        _ = try reader.readBit(); // seq_choose_integer_mv

        if (seq.enable_order_hint) {
            seq.order_hint_bits = try reader.readBits(u8, 3) + 1;
        } else {
            seq.order_hint_bits = 0;
        }

        // Color config
        try self.decodeColorConfig(&reader, &seq);

        // Film grain params present
        _ = try reader.readBit();

        self.sequence_header = seq;
    }

    fn decodeColorConfig(self: *Self, reader: *BitstreamReader, seq: *SequenceHeader) !void {
        _ = self;

        // High bitdepth
        const high_bitdepth = try reader.readBit();
        if (seq.profile == .professional and high_bitdepth == 1) {
            const twelve_bit = try reader.readBit();
            seq.bit_depth = if (twelve_bit == 1) 12 else 10;
        } else if (high_bitdepth == 1) {
            seq.bit_depth = 10;
        } else {
            seq.bit_depth = 8;
        }

        // Mono chrome
        const mono_chrome = try reader.readBit();
        if (mono_chrome == 1) return error.MonochromeNotSupported;

        // Color description present
        const color_description_present_flag = try reader.readBit();
        if (color_description_present_flag == 1) {
            const cp = try reader.readBits(u8, 8);
            const tc = try reader.readBits(u8, 8);
            const mc = try reader.readBits(u8, 8);
            seq.color_primaries = @enumFromInt(cp);
            seq.transfer_characteristics = @enumFromInt(tc);
            seq.matrix_coefficients = @enumFromInt(mc);
        } else {
            seq.color_primaries = .unspecified;
            seq.transfer_characteristics = .unspecified;
            seq.matrix_coefficients = .unspecified;
        }

        // Color range
        seq.color_range = @enumFromInt(try reader.readBit());

        // Subsampling
        if (seq.profile == .main) {
            _ = try reader.readBit(); // subsampling_x
            _ = try reader.readBit(); // subsampling_y
        }

        // Chroma sample position
        _ = try reader.readBits(u8, 2);

        // Separate uv delta q
        _ = try reader.readBit();
    }

    fn decodeFrameHeader(self: *Self, payload: []const u8) !void {
        var reader = BitstreamReader.init(payload);

        var header: FrameHeader = undefined;

        if (self.sequence_header == null) return error.NoSequenceHeader;
        const seq = self.sequence_header.?;

        // Show existing frame
        header.show_existing_frame = try reader.readBit() == 1;
        if (header.show_existing_frame) {
            header.frame_to_show_map_idx = try reader.readBits(u8, 3);
            // Display existing frame
            self.current_frame_header = header;
            return;
        }

        // Frame type
        const frame_type_val = try reader.readBits(u8, 2);
        header.frame_type = @enumFromInt(frame_type_val);
        header.show_frame = try reader.readBit() == 1;

        if (header.show_frame and seq.still_picture) {
            return error.InvalidStillPicture;
        }

        // Error resilient mode
        const error_resilient_mode = try reader.readBit();
        _ = error_resilient_mode;

        // Disable CDF update
        _ = try reader.readBit();

        // Allow screen content tools
        _ = try reader.readBit();

        // Frame size
        if (header.frame_type == .key_frame or header.frame_type == .intra_only_frame) {
            header.frame_width = seq.max_frame_width;
            header.frame_height = seq.max_frame_height;
            header.render_width = header.frame_width;
            header.render_height = header.frame_height;
        } else {
            // Inter frame - may have different size
            header.frame_width = seq.max_frame_width;
            header.frame_height = seq.max_frame_height;
            header.render_width = header.frame_width;
            header.render_height = header.frame_height;
        }

        // Refresh frame flags
        if (header.frame_type == .key_frame) {
            header.refresh_frame_flags = 0xFF; // Refresh all
        } else {
            header.refresh_frame_flags = try reader.readBits(u8, 8);
        }

        // Order hint
        if (seq.enable_order_hint) {
            header.order_hint = try reader.readBits(u32, seq.order_hint_bits);
        } else {
            header.order_hint = 0;
        }

        // Quantization params
        header.base_q_idx = try reader.readBits(u8, 8);

        // Tile info
        try self.decodeTileInfo(&reader, &header);

        self.current_frame_header = header;
    }

    fn decodeTileInfo(self: *Self, reader: *BitstreamReader, header: *FrameHeader) !void {
        _ = self;

        // Uniform tile spacing
        const uniform_tile_spacing_flag = try reader.readBit();

        if (uniform_tile_spacing_flag == 1) {
            // Count tile columns
            header.tile_cols = 1;
            while (header.tile_cols < 64) {
                const increment_tile_cols_log2 = try reader.readBit();
                if (increment_tile_cols_log2 == 0) break;
                header.tile_cols *= 2;
            }

            // Count tile rows
            header.tile_rows = 1;
            while (header.tile_rows < 64) {
                const increment_tile_rows_log2 = try reader.readBit();
                if (increment_tile_rows_log2 == 0) break;
                header.tile_rows *= 2;
            }
        } else {
            header.tile_cols = 1;
            header.tile_rows = 1;
        }

        // Context update tile id
        if (header.tile_cols * header.tile_rows > 1) {
            const tile_bits = self.bitWidth(@as(u32, header.tile_cols) * @as(u32, header.tile_rows) - 1);
            _ = try reader.readBits(u8, tile_bits);
        }

        // Tile size bytes
        _ = try reader.readBits(u8, 2); // tile_size_bytes_minus_1
    }

    fn decodeTileGroup(self: *Self, payload: []const u8, header: *const FrameHeader) !*VideoFrame {
        _ = payload;

        // Create output frame
        const output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            header.frame_width,
            header.frame_height,
            self.output_format,
        );

        // Simplified tile decoding - clear to gray
        const luma_size = output_frame.width * output_frame.height;
        @memset(output_frame.data[0][0..luma_size], 128);

        if (self.output_format == .yuv420p) {
            const chroma_size = (output_frame.width / 2) * (output_frame.height / 2);
            @memset(output_frame.data[1][0..chroma_size], 128);
            @memset(output_frame.data[2][0..chroma_size], 128);
        }

        // Update reference frames
        try self.updateReferenceFrames(output_frame, header);

        return output_frame;
    }

    fn decodeFrame(self: *Self, payload: []const u8) !*VideoFrame {
        // Decode combined frame header + tile group
        try self.decodeFrameHeader(payload);

        if (self.current_frame_header) |header| {
            // Find where tile group starts (after frame header)
            // For simplicity, assume tile data starts at a byte boundary
            return try self.decodeTileGroup(payload, &header);
        }

        return error.NoFrameHeader;
    }

    fn decodeMetadata(self: *Self, payload: []const u8) !void {
        _ = self;
        _ = payload;
        // Metadata OBU - skip for now
    }

    fn updateReferenceFrames(self: *Self, new_frame: *const VideoFrame, header: *const FrameHeader) !void {
        // Update reference frames based on refresh_frame_flags
        var i: u3 = 0;
        while (i < 8) : (i += 1) {
            if ((header.refresh_frame_flags & (@as(u8, 1) << i)) != 0) {
                // Free old reference
                if (self.ref_frames[i]) |old_entry| {
                    old_entry.frame.deinit();
                    self.allocator.destroy(old_entry.frame);
                }

                // Clone new frame as reference
                const ref_frame = try self.allocator.create(VideoFrame);
                ref_frame.* = try new_frame.clone(self.allocator);

                self.ref_frames[i] = .{
                    .frame = ref_frame,
                    .order_hint = header.order_hint,
                    .ref_valid = true,
                };
            }
        }
    }

    fn bitWidth(self: *Self, n: u32) u5 {
        _ = self;
        if (n == 0) return 1;
        return @intCast(32 - @clz(n));
    }
};

const OBU = struct {
    obu_type: OBUType,
    payload: []const u8,
};

/// Bitstream reader for AV1
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

    fn readUVLC(self: *BitstreamReader) !u32 {
        // Unsigned variable length code
        var leading_zeros: u32 = 0;
        while (try self.readBit() == 0) {
            leading_zeros += 1;
            if (leading_zeros > 31) return error.InvalidUVLC;
        }

        if (leading_zeros == 0) return 0;

        var value: u32 = 1;
        var i: u32 = 0;
        while (i < leading_zeros) : (i += 1) {
            const bit = try self.readBit();
            value = (value << 1) | bit;
        }

        return value - 1;
    }
};
