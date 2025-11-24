// Home Video Library - VP9 Encoder
// Google's VP9 video codec encoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;

/// VP9 profile
pub const VP9Profile = enum(u8) {
    profile_0 = 0, // 8-bit 4:2:0
    profile_1 = 1, // 8-bit 4:2:2, 4:4:4
    profile_2 = 2, // 10/12-bit 4:2:0
    profile_3 = 3, // 10/12-bit 4:2:2, 4:4:4
};

/// VP9 encoder configuration
pub const VP9EncoderConfig = struct {
    width: u32,
    height: u32,
    profile: VP9Profile = .profile_0,
    bit_depth: u8 = 8,

    // Rate control
    target_bitrate: u32,
    max_bitrate: u32 = 0,
    min_bitrate: u32 = 0,
    quality: u8 = 30, // 0-63, lower is better quality

    // GOP structure
    keyframe_interval: u32 = 128,
    max_keyframe_interval: u32 = 9999,

    // Threading and tiles
    threads: u8 = 1,
    tile_columns: u8 = 0, // log2 of tile columns
    tile_rows: u8 = 0,    // log2 of tile rows

    // Features
    enable_cdef: bool = true,  // Constrained Directional Enhancement Filter
    enable_loop_restoration: bool = true,
    frame_parallel: bool = false,

    // Color
    color_space: ColorSpace = .bt709,
    color_range: ColorRange = .limited,

    // Performance
    speed: u8 = 5, // 0-8, higher is faster encoding
    lag_in_frames: u32 = 25,

    // Alpha channel
    enable_alpha: bool = false,
};

pub const ColorSpace = enum(u8) {
    unknown = 0,
    bt601 = 1,
    bt709 = 2,
    smpte170 = 3,
    smpte240 = 4,
    bt2020 = 5,
    srgb = 7,
};

pub const ColorRange = enum(u1) {
    limited = 0,
    full = 1,
};

/// VP9 frame type
pub const VP9FrameType = enum(u1) {
    key_frame = 0,
    inter_frame = 1,
};

/// VP9 encoder state
pub const VP9Encoder = struct {
    config: VP9EncoderConfig,
    allocator: std.mem.Allocator,

    // Frame tracking
    frame_count: u64 = 0,
    last_keyframe: u64 = 0,

    // Reference frames
    ref_frames: [8]?*VideoFrame = [_]?*VideoFrame{null} ** 8,

    // Rate control
    rc_state: RateControlState,

    // Superframe support
    superframe_buffer: std.ArrayList([]u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VP9EncoderConfig) !Self {
        return .{
            .config = config,
            .allocator = allocator,
            .rc_state = RateControlState.init(config.target_bitrate),
            .superframe_buffer = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Release reference frames
        for (self.ref_frames) |maybe_frame| {
            if (maybe_frame) |ref_frame| {
                ref_frame.deinit();
                self.allocator.destroy(ref_frame);
            }
        }

        // Free superframe buffers
        for (self.superframe_buffer.items) |buf| {
            self.allocator.free(buf);
        }
        self.superframe_buffer.deinit();
    }

    /// Encode a video frame to VP9
    pub fn encode(self: *Self, input_frame: *const VideoFrame) ![]u8 {
        // Determine frame type
        const is_keyframe = self.shouldInsertKeyframe();
        const frame_type: VP9FrameType = if (is_keyframe) .key_frame else .inter_frame;

        // Prepare frame header
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var writer = BitstreamWriter.init(&output);

        // Write uncompressed header
        try self.writeUncompressedHeader(&writer, frame_type);

        // Encode frame data
        const frame_data = try self.encodeFrameData(input_frame, frame_type);
        defer self.allocator.free(frame_data);

        try output.appendSlice(frame_data);

        // Update reference frames
        if (is_keyframe) {
            try self.updateReferenceFrames(input_frame);
            self.last_keyframe = self.frame_count;
        }

        self.frame_count += 1;

        return output.toOwnedSlice();
    }

    /// Encode multiple frames into a superframe
    pub fn encodeSuperframe(self: *Self, frames: []const *VideoFrame) ![]u8 {
        // Clear previous superframe
        for (self.superframe_buffer.items) |buf| {
            self.allocator.free(buf);
        }
        self.superframe_buffer.clearRetainingCapacity();

        // Encode each frame
        for (frames) |input_frame| {
            const frame_data = try self.encode(input_frame);
            try self.superframe_buffer.append(frame_data);
        }

        // Build superframe with index
        return try self.buildSuperframe();
    }

    fn buildSuperframe(self: *Self) ![]u8 {
        const num_frames = self.superframe_buffer.items.len;
        if (num_frames == 0) return error.NoFrames;
        if (num_frames == 1) return self.superframe_buffer.items[0]; // No superframe for single frame

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Calculate total size and frame sizes
        var total_size: usize = 0;
        var frame_sizes = std.ArrayList(u32).init(self.allocator);
        defer frame_sizes.deinit();

        for (self.superframe_buffer.items) |frame_data| {
            try frame_sizes.append(@intCast(frame_data.len));
            total_size += frame_data.len;
        }

        // Determine bytes needed for frame sizes
        const max_frame_size = frame_sizes.items[0]; // First frame is typically largest
        const bytes_per_size: u8 = if (max_frame_size < 256) 1
                                   else if (max_frame_size < 65536) 2
                                   else if (max_frame_size < 16777216) 3
                                   else 4;

        // Write superframe marker
        const marker: u8 = 0xC0 | ((bytes_per_size - 1) << 3) | (@as(u8, @intCast(num_frames - 1)));
        try output.append(marker);

        // Write frame sizes
        for (frame_sizes.items) |size| {
            var i: u8 = 0;
            while (i < bytes_per_size) : (i += 1) {
                try output.append(@intCast((size >> (@as(u5, @intCast(i * 8)))) & 0xFF));
            }
        }

        // Write all frame data
        for (self.superframe_buffer.items) |frame_data| {
            try output.appendSlice(frame_data);
        }

        // Write superframe marker again at end
        try output.append(marker);

        return output.toOwnedSlice();
    }

    fn shouldInsertKeyframe(self: *Self) bool {
        if (self.frame_count == 0) return true;
        if (self.frame_count - self.last_keyframe >= self.config.keyframe_interval) return true;
        return false;
    }

    fn writeUncompressedHeader(self: *Self, writer: *BitstreamWriter, frame_type: VP9FrameType) !void {
        // Frame marker (2 bits) - always 0b10
        try writer.writeBits(2, 2);

        // Profile (2 bits for profile 0-3)
        try writer.writeBits(@intFromEnum(self.config.profile) & 0x3, 2);

        if (self.config.profile >= .profile_2) {
            // Bit depth indicator
            try writer.writeBit(if (self.config.bit_depth == 10) 0 else 1);
        }

        // Show existing frame flag
        try writer.writeBit(0);

        // Frame type
        try writer.writeBit(@intFromEnum(frame_type));

        // Show frame flag
        try writer.writeBit(1);

        // Error resilient mode
        try writer.writeBit(0);

        if (frame_type == .key_frame) {
            try self.writeKeyframeHeader(writer);
        } else {
            try self.writeInterframeHeader(writer);
        }

        // Tile info
        try self.writeTileInfo(writer);

        // Quantization parameters
        try self.writeQuantizationParams(writer);

        // Segmentation
        try writer.writeBit(0); // segmentation_enabled = false

        // Loop filter params
        try self.writeLoopFilterParams(writer);

        // Align to byte boundary
        try writer.byteAlign();
    }

    fn writeKeyframeHeader(self: *Self, writer: *BitstreamWriter) !void {
        // Frame sync code (0x498342)
        try writer.writeBits(0x49, 8);
        try writer.writeBits(0x83, 8);
        try writer.writeBits(0x42, 8);

        // Color config
        try self.writeColorConfig(writer);

        // Frame size
        try writer.writeBits(self.config.width - 1, 16);
        try writer.writeBits(self.config.height - 1, 16);

        // Render size
        try writer.writeBit(0); // render_and_frame_size_different = false

        // Refresh frame flags (refresh all 8 reference frames)
        try writer.writeBits(0xFF, 8);
    }

    fn writeInterframeHeader(self: *Self, writer: *BitstreamWriter) !void {
        // Intra only flag
        try writer.writeBit(0);

        // Reset frame context
        try writer.writeBits(0, 2);

        // Reference frame selection
        // ref_frame_idx[0], ref_frame_idx[1], ref_frame_idx[2]
        try writer.writeBits(0, 3); // LAST_FRAME
        try writer.writeBits(1, 3); // GOLDEN_FRAME
        try writer.writeBits(2, 3); // ALTREF_FRAME

        // Reference frame sign bias
        for (0..3) |_| {
            try writer.writeBit(0);
        }

        // Frame size
        try writer.writeBit(0); // frame_size_with_refs = false
        try writer.writeBits(self.config.width - 1, 16);
        try writer.writeBits(self.config.height - 1, 16);

        // Render size
        try writer.writeBit(0);

        // High precision motion vectors
        try writer.writeBit(0);

        // Interpolation filter
        try writer.writeBit(1); // is_filter_switchable = true

        // Refresh frame flags
        try writer.writeBits(0x01, 8); // Refresh LAST_FRAME
    }

    fn writeColorConfig(self: *Self, writer: *BitstreamWriter) !void {
        if (self.config.profile >= .profile_2) {
            // Bit depth
            if (self.config.bit_depth == 10) {
                try writer.writeBits(0, 1); // BIT_DEPTH_10
            } else if (self.config.bit_depth == 12) {
                try writer.writeBits(1, 1); // BIT_DEPTH_12
            }
        }

        // Color space
        try writer.writeBits(@intFromEnum(self.config.color_space), 3);

        if (self.config.color_space != .srgb) {
            // Color range
            try writer.writeBit(@intFromEnum(self.config.color_range));

            if (self.config.profile == .profile_1 or self.config.profile == .profile_3) {
                // Subsampling
                try writer.writeBits(0, 2); // 4:2:0 for profile 0/2
            }
        }
    }

    fn writeTileInfo(self: *Self, writer: *BitstreamWriter) !void {
        // Calculate tile dimensions based on frame size
        const sb64_cols = (self.config.width + 63) / 64;
        const sb64_rows = (self.config.height + 63) / 64;

        // Tile columns
        var min_log2_tile_cols: u8 = 0;
        var max_log2_tile_cols: u8 = 0;

        var max_tiles: u32 = sb64_cols;
        while (max_tiles > 1) {
            max_tiles >>= 1;
            max_log2_tile_cols += 1;
        }

        const tile_cols_log2 = std.math.clamp(self.config.tile_columns, min_log2_tile_cols, max_log2_tile_cols);

        var i: u8 = min_log2_tile_cols;
        while (i < max_log2_tile_cols) : (i += 1) {
            try writer.writeBit(if (i < tile_cols_log2) 1 else 0);
        }

        // Tile rows
        const tile_rows_log2 = std.math.min(self.config.tile_rows, 2);
        if (tile_rows_log2 > 0) {
            try writer.writeBit(1);
            if (tile_rows_log2 > 1) {
                try writer.writeBit(1);
            } else {
                try writer.writeBit(0);
            }
        } else {
            try writer.writeBit(0);
        }
    }

    fn writeQuantizationParams(self: *Self, writer: *BitstreamWriter) !void {
        // Base Q index
        const q_index = self.calculateQIndex();
        try writer.writeBits(q_index, 8);

        // Delta Q for Y DC
        try writer.writeBit(0); // delta_coded = false

        // Delta Q for UV DC
        try writer.writeBit(0);

        // Delta Q for UV AC
        try writer.writeBit(0);

        // Lossless mode
        const lossless = (q_index == 0);
        _ = lossless;
    }

    fn writeLoopFilterParams(self: *Self, writer: *BitstreamWriter) !void {
        // Loop filter level
        try writer.writeBits(8, 6); // Moderate filtering

        // Loop filter sharpness
        try writer.writeBits(0, 3);

        // Loop filter delta enabled
        try writer.writeBit(1);

        // Loop filter delta update
        try writer.writeBit(0);
    }

    fn calculateQIndex(self: *Self) u8 {
        // Map quality (0-63) to quantizer index (0-255)
        const quality = std.math.clamp(self.config.quality, 0, 63);
        return @intCast((255 * quality) / 63);
    }

    fn encodeFrameData(self: *Self, input_frame: *const VideoFrame, frame_type: VP9FrameType) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // For now, implement basic frame encoding structure
        // In a full implementation, this would perform:
        // - Superblock partitioning (64x64)
        // - Transform (DCT/ADST)
        // - Quantization
        // - Entropy coding
        // - Motion estimation (for inter frames)
        // - Loop filtering

        const num_tiles = (@as(u32, 1) << self.config.tile_columns) * (@as(u32, 1) << self.config.tile_rows);

        for (0..num_tiles) |tile_idx| {
            const tile_data = try self.encodeTile(input_frame, frame_type, @intCast(tile_idx));
            defer self.allocator.free(tile_data);

            // Write tile size for all tiles except the last
            if (tile_idx < num_tiles - 1) {
                const size: u32 = @intCast(tile_data.len);
                try output.append(@intCast(size & 0xFF));
                try output.append(@intCast((size >> 8) & 0xFF));
                try output.append(@intCast((size >> 16) & 0xFF));
                try output.append(@intCast((size >> 24) & 0xFF));
            }

            try output.appendSlice(tile_data);
        }

        return output.toOwnedSlice();
    }

    fn encodeTile(self: *Self, input_frame: *const VideoFrame, frame_type: VP9FrameType, tile_idx: u32) ![]u8 {
        _ = tile_idx;

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Simplified tile encoding - placeholder for full implementation
        // Real implementation would:
        // - Partition tile into superblocks
        // - For each superblock: motion estimation, transform, quantization
        // - Entropy code using VP9's context-based coding

        const tile_data_size = if (frame_type == .key_frame)
            self.config.width * self.config.height / 16 // Rough estimate for keyframe
        else
            self.config.width * self.config.height / 32; // Inter frames compress better

        try output.appendNTimes(0, tile_data_size);

        // Update rate control
        self.rc_state.updateAfterFrame(tile_data_size * 8);

        _ = input_frame;
        return output.toOwnedSlice();
    }

    fn updateReferenceFrames(self: *Self, new_frame: *const VideoFrame) !void {
        // For keyframes, update all reference frame slots
        // Simplified: just update LAST_FRAME (slot 0)
        if (self.ref_frames[0]) |old_frame| {
            old_frame.deinit();
            self.allocator.destroy(old_frame);
        }

        const ref_frame = try self.allocator.create(VideoFrame);
        ref_frame.* = try new_frame.clone(self.allocator);
        self.ref_frames[0] = ref_frame;
    }
};

/// Rate control state for VP9
const RateControlState = struct {
    target_bitrate: u32,
    current_bitrate: f64 = 0,
    buffer_level: f64 = 0,

    fn init(target_bitrate: u32) RateControlState {
        return .{
            .target_bitrate = target_bitrate,
            .buffer_level = @as(f64, @floatFromInt(target_bitrate)) * 0.5,
        };
    }

    fn updateAfterFrame(self: *RateControlState, frame_bits: usize) void {
        const bits_f: f64 = @floatFromInt(frame_bits);
        self.current_bitrate = self.current_bitrate * 0.9 + bits_f * 0.1;
        self.buffer_level = self.buffer_level - bits_f + @as(f64, @floatFromInt(self.target_bitrate));
    }
};

/// Bitstream writer for VP9
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
            try self.buffer.append(self.bit_buffer);
            self.bit_buffer = 0;
            self.bits_in_buffer = 0;
        }
    }

    fn writeBits(self: *BitstreamWriter, value: u32, num_bits: u5) !void {
        var i: u5 = num_bits;
        while (i > 0) {
            i -= 1;
            const bit: u1 = @intCast((value >> i) & 1);
            try self.writeBit(bit);
        }
    }

    fn byteAlign(self: *BitstreamWriter) !void {
        while (self.bits_in_buffer != 0) {
            try self.writeBit(0);
        }
    }

    fn flush(self: *BitstreamWriter) !void {
        if (self.bits_in_buffer > 0) {
            const remaining_bits = 8 - self.bits_in_buffer;
            self.bit_buffer <<= @intCast(remaining_bits);
            try self.buffer.append(self.bit_buffer);
            self.bit_buffer = 0;
            self.bits_in_buffer = 0;
        }
    }
};
