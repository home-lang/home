// Home Video Library - VP9 Decoder
// Google VP9 video decoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");
const vp9_encoder = @import("vp9_encoder.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;
const VP9Profile = vp9_encoder.VP9Profile;
const VP9FrameType = vp9_encoder.VP9FrameType;
const ColorSpace = vp9_encoder.ColorSpace;
const ColorRange = vp9_encoder.ColorRange;

/// VP9 decoder configuration
pub const VP9DecoderConfig = struct {
    thread_count: u8 = 1,
    enable_postproc: bool = false,
    error_concealment: bool = true,
};

/// Decoded picture buffer entry
const DPBEntry = struct {
    frame: *VideoFrame,
    frame_index: u8,
};

/// VP9 decoder state
pub const VP9Decoder = struct {
    config: VP9DecoderConfig,
    allocator: std.mem.Allocator,

    // Reference frames (8 slots in VP9)
    ref_frames: [8]?*VideoFrame = [_]?*VideoFrame{null} ** 8,

    // Output dimensions
    output_width: u32 = 0,
    output_height: u32 = 0,
    output_format: frame.PixelFormat = .yuv420p,

    // Frame properties
    profile: VP9Profile = .profile_0,
    bit_depth: u8 = 8,
    color_space: ColorSpace = .bt709,
    color_range: ColorRange = .limited,

    // Tile configuration
    tile_cols_log2: u8 = 0,
    tile_rows_log2: u8 = 0,

    // Segmentation state
    segmentation_enabled: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VP9DecoderConfig) Self {
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

    /// Decode VP9 packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?*VideoFrame {
        // Check for superframe
        if (self.isSuperframe(pkt.data)) {
            return try self.decodeSuperframe(pkt.data);
        }

        // Decode single frame
        return try self.decodeFrame(pkt.data);
    }

    fn isSuperframe(self: *Self, data: []const u8) bool {
        _ = self;
        if (data.len < 2) return false;

        // Superframe has marker at end
        const last_byte = data[data.len - 1];
        const marker = (last_byte & 0xE0) >> 5;

        return marker == 0x06; // Superframe marker
    }

    fn decodeSuperframe(self: *Self, data: []const u8) !?*VideoFrame {
        const last_byte = data[data.len - 1];
        const bytes_per_framesize = ((last_byte >> 3) & 0x3) + 1;
        const num_frames = (last_byte & 0x7) + 1;

        // Parse frame sizes from superframe index
        const index_size = 2 + @as(usize, num_frames) * bytes_per_framesize;
        if (data.len < index_size) return error.InvalidSuperframe;

        var frame_sizes = std.ArrayList(usize).init(self.allocator);
        defer frame_sizes.deinit();

        var pos: usize = data.len - index_size;
        pos += 1; // Skip first marker byte

        for (0..num_frames) |_| {
            var size: usize = 0;
            for (0..bytes_per_framesize) |byte_idx| {
                size |= @as(usize, data[pos]) << @intCast(byte_idx * 8);
                pos += 1;
            }
            try frame_sizes.append(size);
        }

        // Decode frames
        var frame_pos: usize = 0;
        var last_frame: ?*VideoFrame = null;

        for (frame_sizes.items) |size| {
            if (frame_pos + size > data.len) return error.InvalidSuperframe;

            const frame_data = data[frame_pos .. frame_pos + size];
            const decoded = try self.decodeFrame(frame_data);

            // Keep only the last visible frame
            if (decoded) |output| {
                if (last_frame) |old_frame| {
                    old_frame.deinit();
                    self.allocator.destroy(old_frame);
                }
                last_frame = output;
            }

            frame_pos += size;
        }

        return last_frame;
    }

    fn decodeFrame(self: *Self, data: []const u8) !?*VideoFrame {
        var reader = BitstreamReader.init(data);

        // Decode uncompressed header
        try self.decodeUncompressedHeader(&reader);

        // Decode compressed header
        try self.decodeCompressedHeader(&reader);

        // Create output frame
        const output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            self.output_width,
            self.output_height,
            self.output_format,
        );

        // Decode tiles
        try self.decodeTiles(&reader, output_frame);

        // Update reference frames
        try self.updateReferenceFrames(output_frame);

        return output_frame;
    }

    fn decodeUncompressedHeader(self: *Self, reader: *BitstreamReader) !void {
        // Frame marker
        const frame_marker = try reader.readBits(u8, 2);
        if (frame_marker != 0x2) return error.InvalidFrameMarker;

        // Profile
        const profile_low_bit = try reader.readBit();
        const profile_high_bit = try reader.readBit();
        self.profile = @enumFromInt((@as(u8, profile_high_bit) << 1) | profile_low_bit);

        if (self.profile == .profile_3) {
            _ = try reader.readBit(); // reserved zero
        }

        // Show existing frame
        const show_existing_frame = try reader.readBit();
        if (show_existing_frame == 1) {
            const frame_to_show = try reader.readBits(u8, 3);
            // Copy reference frame to output
            _ = frame_to_show;
            return;
        }

        // Frame type
        const frame_type_bit = try reader.readBit();
        const frame_type: VP9FrameType = @enumFromInt(frame_type_bit);
        const show_frame = try reader.readBit();
        const error_resilient_mode = try reader.readBit();

        _ = show_frame;
        _ = error_resilient_mode;

        if (frame_type == .key_frame) {
            try self.decodeKeyframeHeader(reader);
        } else {
            try self.decodeInterframeHeader(reader);
        }

        // Refresh frame flags
        if (error_resilient_mode == 0 and frame_type != .key_frame) {
            _ = try reader.readBits(u8, 8); // refresh_frame_flags
        }
    }

    fn decodeKeyframeHeader(self: *Self, reader: *BitstreamReader) !void {
        // Frame sync code
        const sync_code = try reader.readBits(u32, 24);
        if (sync_code != 0x498342) return error.InvalidSyncCode;

        // Color config
        try self.decodeColorConfig(reader);

        // Frame size
        self.output_width = try reader.readBits(u32, 16) + 1;
        self.output_height = try reader.readBits(u32, 16) + 1;

        // Render size
        const render_and_frame_size_different = try reader.readBit();
        if (render_and_frame_size_different == 1) {
            _ = try reader.readBits(u32, 16); // render_width
            _ = try reader.readBits(u32, 16); // render_height
        }

        // Refresh all reference frames for keyframe
    }

    fn decodeInterframeHeader(self: *Self, reader: *BitstreamReader) !void {
        // Intra only
        const intra_only = try reader.readBit();
        if (intra_only == 1) return error.IntraOnlyNotSupported;

        // Reset frame context
        _ = try reader.readBits(u8, 2);

        // Reference frames
        for (0..3) |_| {
            _ = try reader.readBits(u8, 3); // ref_frame_idx
        }

        for (0..3) |_| {
            _ = try reader.readBit(); // ref_frame_sign_bias
        }

        // Frame size
        const frame_size_with_refs = try reader.readBit();
        if (frame_size_with_refs == 0) {
            self.output_width = try reader.readBits(u32, 16) + 1;
            self.output_height = try reader.readBits(u32, 16) + 1;
        }

        // Render size
        const render_and_frame_size_different = try reader.readBit();
        if (render_and_frame_size_different == 1) {
            _ = try reader.readBits(u32, 16); // render_width
            _ = try reader.readBits(u32, 16); // render_height
        }

        // High precision MV
        _ = try reader.readBit();

        // Interpolation filter
        const is_filter_switchable = try reader.readBit();
        if (is_filter_switchable == 0) {
            _ = try reader.readBits(u8, 2); // raw_interpolation_filter
        }

        // Refresh frame flags
        _ = try reader.readBits(u8, 8);
    }

    fn decodeColorConfig(self: *Self, reader: *BitstreamReader) !void {
        if (self.profile >= .profile_2) {
            const ten_or_twelve_bit = try reader.readBit();
            self.bit_depth = if (ten_or_twelve_bit == 0) 10 else 12;
        }

        // Color space
        const color_space_val = try reader.readBits(u8, 3);
        self.color_space = @enumFromInt(color_space_val);

        if (self.color_space != .srgb) {
            // Color range
            self.color_range = @enumFromInt(try reader.readBit());

            if (self.profile == .profile_1 or self.profile == .profile_3) {
                // Subsampling
                _ = try reader.readBits(u8, 2);
                _ = try reader.readBit(); // reserved zero
            }
        } else {
            // RGB
            if (self.profile == .profile_1 or self.profile == .profile_3) {
                _ = try reader.readBit(); // reserved zero
            }
        }
    }

    fn decodeCompressedHeader(self: *Self, reader: *BitstreamReader) !void {
        _ = reader;

        // Tile info
        self.decodeTileInfo(reader) catch {};

        // Quantization params
        _ = try reader.readBits(u8, 8); // base_q_idx
        _ = self.readDeltaQ(reader); // delta_q_y_dc
        _ = self.readDeltaQ(reader); // delta_q_uv_dc
        _ = self.readDeltaQ(reader); // delta_q_uv_ac

        // Segmentation
        self.segmentation_enabled = try reader.readBit() == 1;
        if (self.segmentation_enabled) {
            // Skip segmentation data for simplicity
        }

        // Loop filter params
        _ = try reader.readBits(u8, 6); // loop_filter_level
        _ = try reader.readBits(u8, 3); // loop_filter_sharpness

        const loop_filter_delta_enabled = try reader.readBit();
        if (loop_filter_delta_enabled == 1) {
            const loop_filter_delta_update = try reader.readBit();
            if (loop_filter_delta_update == 1) {
                // Skip delta updates
            }
        }
    }

    fn decodeTileInfo(self: *Self, reader: *BitstreamReader) !void {
        const sb64_cols = (self.output_width + 63) / 64;

        var min_log2_tile_cols: u8 = 0;
        var max_tiles: u32 = sb64_cols;
        while (max_tiles > 1) {
            max_tiles >>= 1;
            min_log2_tile_cols += 1;
        }

        var max_log2_tile_cols = min_log2_tile_cols;
        while (max_log2_tile_cols < 6 and (@as(u32, 1) << max_log2_tile_cols) < sb64_cols) {
            max_log2_tile_cols += 1;
        }

        self.tile_cols_log2 = min_log2_tile_cols;
        while (self.tile_cols_log2 < max_log2_tile_cols) {
            const increment = try reader.readBit();
            if (increment == 0) break;
            self.tile_cols_log2 += 1;
        }

        self.tile_rows_log2 = 0;
        const tile_rows_log2_bit1 = try reader.readBit();
        if (tile_rows_log2_bit1 == 1) {
            const tile_rows_log2_bit2 = try reader.readBit();
            self.tile_rows_log2 = if (tile_rows_log2_bit2 == 1) 2 else 1;
        }
    }

    fn readDeltaQ(self: *Self, reader: *BitstreamReader) !i8 {
        _ = self;
        const delta_coded = try reader.readBit();
        if (delta_coded == 1) {
            const value = try reader.readBits(i8, 4);
            const sign = try reader.readBit();
            return if (sign == 1) -value else value;
        }
        return 0;
    }

    fn decodeTiles(self: *Self, reader: *BitstreamReader, output_frame: *VideoFrame) !void {
        _ = reader;

        // Simplified tile decoding
        const luma_size = output_frame.width * output_frame.height;
        @memset(output_frame.data[0][0..luma_size], 128);

        if (self.output_format == .yuv420p) {
            const chroma_size = (output_frame.width / 2) * (output_frame.height / 2);
            @memset(output_frame.data[1][0..chroma_size], 128);
            @memset(output_frame.data[2][0..chroma_size], 128);
        }
    }

    fn updateReferenceFrames(self: *Self, new_frame: *const VideoFrame) !void {
        // Update LAST_FRAME (slot 0)
        if (self.ref_frames[0]) |old_frame| {
            old_frame.deinit();
            self.allocator.destroy(old_frame);
        }

        const ref_frame = try self.allocator.create(VideoFrame);
        ref_frame.* = try new_frame.clone(self.allocator);
        self.ref_frames[0] = ref_frame;
    }
};

/// Bitstream reader for VP9
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
};
