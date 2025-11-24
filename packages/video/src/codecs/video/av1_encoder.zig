// Home Video Library - AV1 Encoder
// Alliance for Open Media AV1 video codec encoder implementation

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;

/// AV1 profile
pub const AV1Profile = enum(u3) {
    main = 0,      // 4:2:0 8-10 bit
    high = 1,      // 4:4:4 8-10 bit
    professional = 2, // 4:2:2 8-12 bit, 4:2:0/4:4:4 12 bit
};

/// AV1 encoder configuration
pub const AV1EncoderConfig = struct {
    width: u32,
    height: u32,
    profile: AV1Profile = .main,
    bit_depth: u8 = 8,

    // Rate control
    target_bitrate: u32,
    max_bitrate: u32 = 0,
    min_bitrate: u32 = 0,
    cq_level: u8 = 30, // Constant quality level (0-63)

    // GOP structure
    keyframe_interval: u32 = 128,
    min_gop_size: u32 = 0,

    // Advanced features
    enable_cdef: bool = true,           // Constrained Directional Enhancement Filter
    enable_restoration: bool = true,     // Loop restoration filter
    enable_superres: bool = false,       // Super-resolution
    enable_film_grain: bool = false,     // Film grain synthesis
    enable_intra_edge_filter: bool = true,
    enable_interintra_compound: bool = true,
    enable_masked_compound: bool = true,
    enable_warped_motion: bool = true,
    enable_dual_filter: bool = true,

    // Tiles
    tile_columns: u8 = 0, // Number of tile columns (log2)
    tile_rows: u8 = 0,    // Number of tile rows (log2)

    // Threading
    threads: u8 = 1,

    // Color
    color_primaries: ColorPrimaries = .bt709,
    transfer_characteristics: TransferCharacteristics = .bt709,
    matrix_coefficients: MatrixCoefficients = .bt709,
    color_range: ColorRange = .limited,

    // Performance
    speed: u8 = 6, // 0-9, higher is faster
    lag_in_frames: u32 = 35,

    // Screen content
    tune_content: ContentTune = .default,
    enable_palette: bool = false,
};

pub const ColorPrimaries = enum(u8) {
    bt709 = 1,
    unspecified = 2,
    bt470m = 4,
    bt470bg = 5,
    bt601 = 6,
    smpte240 = 7,
    film = 8,
    bt2020 = 9,
    xyz = 10,
    smpte431 = 11,
    smpte432 = 12,
    ebu3213 = 22,
};

pub const TransferCharacteristics = enum(u8) {
    bt709 = 1,
    unspecified = 2,
    bt470m = 4,
    bt470bg = 5,
    bt601 = 6,
    smpte240 = 7,
    linear = 8,
    log100 = 9,
    log100_sqrt10 = 10,
    iec61966 = 11,
    bt1361 = 12,
    srgb = 13,
    bt2020_10bit = 14,
    bt2020_12bit = 15,
    smpte2084 = 16, // PQ
    smpte428 = 17,
    hlg = 18,       // Hybrid Log-Gamma
};

pub const MatrixCoefficients = enum(u8) {
    identity = 0,
    bt709 = 1,
    unspecified = 2,
    fcc = 4,
    bt470bg = 5,
    bt601 = 6,
    smpte240 = 7,
    ycgco = 8,
    bt2020_ncl = 9,
    bt2020_cl = 10,
    smpte2085 = 11,
    chroma_ncl = 12,
    chroma_cl = 13,
    ictcp = 14,
};

pub const ColorRange = enum(u1) {
    limited = 0,
    full = 1,
};

pub const ContentTune = enum {
    default,
    screen,
};

/// AV1 frame type
pub const AV1FrameType = enum(u2) {
    key_frame = 0,
    inter_frame = 1,
    intra_only_frame = 2,
    switch_frame = 3,
};

/// OBU (Open Bitstream Unit) type
pub const OBUType = enum(u4) {
    sequence_header = 1,
    temporal_delimiter = 2,
    frame_header = 3,
    tile_group = 4,
    metadata = 5,
    frame = 6,
    redundant_frame_header = 7,
    tile_list = 8,
    padding = 15,
};

/// AV1 encoder state
pub const AV1Encoder = struct {
    config: AV1EncoderConfig,
    allocator: std.mem.Allocator,

    // Frame tracking
    frame_count: u64 = 0,
    last_keyframe: u64 = 0,
    order_hint: u32 = 0,

    // Sequence header
    sequence_header: ?[]u8 = null,

    // Reference frames (8 slots in AV1)
    ref_frames: [8]?*VideoFrame = [_]?*VideoFrame{null} ** 8,

    // Rate control
    rc_state: RateControlState,

    // Temporal delimiter flag
    output_temporal_delimiter: bool = true,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: AV1EncoderConfig) !Self {
        var self = Self{
            .config = config,
            .allocator = allocator,
            .rc_state = RateControlState.init(config.target_bitrate),
        };

        // Generate sequence header
        self.sequence_header = try self.generateSequenceHeader();

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.sequence_header) |header| {
            self.allocator.free(header);
        }

        for (self.ref_frames) |maybe_frame| {
            if (maybe_frame) |ref_frame| {
                ref_frame.deinit();
                self.allocator.destroy(ref_frame);
            }
        }
    }

    /// Encode a video frame to AV1
    pub fn encode(self: *Self, input_frame: *const VideoFrame) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Temporal delimiter (optional, for first frame in temporal unit)
        if (self.output_temporal_delimiter) {
            const td_obu = try self.writeOBU(.temporal_delimiter, &[_]u8{});
            defer self.allocator.free(td_obu);
            try output.appendSlice(td_obu);
        }

        // Sequence header (for keyframes)
        const is_keyframe = self.shouldInsertKeyframe();
        if (is_keyframe and self.sequence_header != null) {
            try output.appendSlice(self.sequence_header.?);
        }

        // Frame OBU
        const frame_data = try self.encodeFrame(input_frame, is_keyframe);
        defer self.allocator.free(frame_data);

        const frame_obu = try self.writeOBU(.frame, frame_data);
        defer self.allocator.free(frame_obu);

        try output.appendSlice(frame_obu);

        // Update state
        if (is_keyframe) {
            try self.updateReferenceFrames(input_frame);
            self.last_keyframe = self.frame_count;
        }

        self.frame_count += 1;
        self.order_hint = (self.order_hint + 1) & 0xFF;

        return output.toOwnedSlice();
    }

    fn shouldInsertKeyframe(self: *Self) bool {
        if (self.frame_count == 0) return true;
        if (self.frame_count - self.last_keyframe >= self.config.keyframe_interval) return true;
        return false;
    }

    fn generateSequenceHeader(self: *Self) ![]u8 {
        var payload = std.ArrayList(u8).init(self.allocator);
        errdefer payload.deinit();

        var writer = BitstreamWriter.init(&payload);

        // Profile
        try writer.writeBits(@intFromEnum(self.config.profile), 3);

        // Still picture
        try writer.writeBit(0);

        // Reduced still picture header
        try writer.writeBit(0);

        // Timing info present
        try writer.writeBit(0);

        // Initial display delay present
        try writer.writeBit(0);

        // Operating points
        try writer.writeBits(0, 5); // operating_points_cnt_minus_1 = 0 (1 operating point)

        // Operating point 0
        try writer.writeBits(0, 12); // operating_point_idc[0]
        try writer.writeBits(0, 5);  // seq_level_idx[0] (level 2.0)
        try writer.writeBit(0);       // seq_tier[0]

        // Frame dimensions
        const width_bits = self.bitWidth(self.config.width - 1);
        const height_bits = self.bitWidth(self.config.height - 1);

        try writer.writeBits(width_bits - 1, 4);
        try writer.writeBits(height_bits - 1, 4);
        try writer.writeBits(self.config.width - 1, width_bits);
        try writer.writeBits(self.config.height - 1, height_bits);

        // use_128x128_superblock
        try writer.writeBit(0);

        // enable features
        try writer.writeBit(if (self.config.enable_dual_filter) 1 else 0);
        try writer.writeBit(if (self.config.enable_intra_edge_filter) 1 else 0);
        try writer.writeBit(if (self.config.enable_interintra_compound) 1 else 0);
        try writer.writeBit(if (self.config.enable_masked_compound) 1 else 0);
        try writer.writeBit(if (self.config.enable_warped_motion) 1 else 0);
        try writer.writeBit(0); // enable_order_hint
        try writer.writeBit(0); // enable_ref_frame_mvs
        try writer.writeBit(1); // seq_force_screen_content_tools = SELECT
        try writer.writeBit(1); // seq_force_integer_mv = SELECT

        // Color config
        try self.writeColorConfig(&writer);

        // Film grain params present
        try writer.writeBit(if (self.config.enable_film_grain) 1 else 0);

        try writer.byteAlign();

        const payload_data = try payload.toOwnedSlice();
        return try self.writeOBU(.sequence_header, payload_data);
    }

    fn writeColorConfig(self: *Self, writer: *BitstreamWriter) !void {
        // High bitdepth flag
        const high_bitdepth = self.config.bit_depth > 8;
        try writer.writeBit(if (high_bitdepth) 1 else 0);

        if (self.config.profile == .professional and high_bitdepth) {
            // Twelve bit
            try writer.writeBit(if (self.config.bit_depth == 12) 1 else 0);
        }

        // Mono chrome
        try writer.writeBit(0);

        // Color description present
        try writer.writeBit(1);

        // Color primaries
        try writer.writeBits(@intFromEnum(self.config.color_primaries), 8);

        // Transfer characteristics
        try writer.writeBits(@intFromEnum(self.config.transfer_characteristics), 8);

        // Matrix coefficients
        try writer.writeBits(@intFromEnum(self.config.matrix_coefficients), 8);

        // Color range
        try writer.writeBit(@intFromEnum(self.config.color_range));

        // Subsampling (4:2:0 for main profile)
        if (self.config.profile == .main) {
            try writer.writeBit(1); // subsampling_x
            try writer.writeBit(1); // subsampling_y
        } else {
            try writer.writeBit(0); // subsampling_x
            try writer.writeBit(0); // subsampling_y
        }

        // Chroma sample position (0 = unknown)
        try writer.writeBits(0, 2);

        // Separate uv delta q
        try writer.writeBit(0);
    }

    fn encodeFrame(self: *Self, input_frame: *const VideoFrame, is_keyframe: bool) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        var writer = BitstreamWriter.init(&output);

        // Frame header
        try self.writeFrameHeader(&writer, is_keyframe);

        // Tile group
        try self.writeTileGroup(&writer, input_frame, is_keyframe);

        try writer.byteAlign();

        return output.toOwnedSlice();
    }

    fn writeFrameHeader(self: *Self, writer: *BitstreamWriter, is_keyframe: bool) !void {
        // show_existing_frame
        try writer.writeBit(0);

        // Frame type
        const frame_type: AV1FrameType = if (is_keyframe) .key_frame else .inter_frame;
        try writer.writeBits(@intFromEnum(frame_type), 2);

        // show_frame
        try writer.writeBit(1);

        if (frame_type == .switch_frame or (frame_type == .key_frame and !is_keyframe)) {
            // error_resilient_mode
            try writer.writeBit(0);
        }

        // disable_cdf_update
        try writer.writeBit(0);

        // allow_screen_content_tools
        try writer.writeBit(if (self.config.tune_content == .screen) 1 else 0);

        if (frame_type == .key_frame) {
            try self.writeKeyFrameHeader(writer);
        } else {
            try self.writeInterFrameHeader(writer);
        }

        // Quantization params
        try self.writeQuantizationParams(writer);

        // Segmentation params
        try writer.writeBit(0); // segmentation_enabled = false

        // Delta Q params
        try writer.writeBit(0); // delta_q_present = false

        // Loop filter params
        try self.writeLoopFilterParams(writer);

        // CDEF params
        if (self.config.enable_cdef) {
            try self.writeCDEFParams(writer);
        }

        // Loop restoration params
        if (self.config.enable_restoration) {
            try self.writeLoopRestorationParams(writer);
        }

        // TX mode
        try writer.writeBit(1); // tx_mode_select = true

        // Reference select (for inter frames)
        if (frame_type != .key_frame and frame_type != .intra_only_frame) {
            try writer.writeBit(0); // reference_select = false
        }

        // Allow high precision mv
        try writer.writeBit(0);

        // Interpolation filter
        try writer.writeBit(1); // is_filter_switchable = true

        // Motion mode switchable
        try writer.writeBit(1);

        // Tile info
        try self.writeTileInfo(writer);
    }

    fn writeKeyFrameHeader(self: *Self, writer: *BitstreamWriter) !void {
        // refresh_frame_flags (refresh all 8 slots)
        try writer.writeBits(0xFF, 8);

        // Frame width/height (already in sequence header, but can override)
        // render_and_frame_size_different
        try writer.writeBit(0);

        // allow_intrabc
        try writer.writeBit(if (self.config.enable_palette) 1 else 0);
    }

    fn writeInterFrameHeader(self: *Self, writer: *BitstreamWriter) !void {
        // refresh_frame_flags
        try writer.writeBits(0x01, 8); // Refresh LAST_FRAME only

        // ref_frame_idx for 7 reference frames
        for (0..7) |i| {
            try writer.writeBits(@intCast(i), 3);
        }

        // allow_high_precision_mv
        try writer.writeBit(0);

        // Interpolation filter
        try writer.writeBit(1); // is_filter_switchable

        // motion_mode_switchable
        try writer.writeBit(1);

        // use_ref_frame_mvs
        try writer.writeBit(0);
    }

    fn writeQuantizationParams(self: *Self, writer: *BitstreamWriter) !void {
        // base_q_idx
        const q_idx = self.calculateQIndex();
        try writer.writeBits(q_idx, 8);

        // DeltaQYDc
        try writer.writeBit(0);

        // DeltaQUDc, DeltaQUAc
        try writer.writeBit(0);
        try writer.writeBit(0);

        // DeltaQVDc, DeltaQVAc
        try writer.writeBit(0);
        try writer.writeBit(0);

        // using_qmatrix
        try writer.writeBit(0);
    }

    fn writeLoopFilterParams(self: *Self, writer: *BitstreamWriter) !void {
        // loop_filter_level[0], loop_filter_level[1]
        try writer.writeBits(8, 6);
        try writer.writeBits(8, 6);

        // loop_filter_level[2], loop_filter_level[3] (for chroma)
        try writer.writeBits(8, 6);
        try writer.writeBits(8, 6);

        // loop_filter_sharpness
        try writer.writeBits(0, 3);

        // loop_filter_delta_enabled
        try writer.writeBit(1);

        // loop_filter_delta_update
        try writer.writeBit(0);
    }

    fn writeCDEFParams(self: *Self, writer: *BitstreamWriter) !void {
        // cdef_damping
        try writer.writeBits(3, 2);

        // cdef_bits (number of CDEF parameter sets)
        try writer.writeBits(0, 2); // 1 parameter set

        // CDEF parameters
        try writer.writeBits(0, 6); // cdef_y_pri_strength[0]
        try writer.writeBits(0, 4); // cdef_y_sec_strength[0]
        try writer.writeBits(0, 6); // cdef_uv_pri_strength[0]
        try writer.writeBits(0, 4); // cdef_uv_sec_strength[0]
    }

    fn writeLoopRestorationParams(self: *Self, writer: *BitstreamWriter) !void {
        // Y plane
        try writer.writeBits(0, 2); // lr_type = RESTORE_NONE

        // U plane
        try writer.writeBits(0, 2);

        // V plane
        try writer.writeBits(0, 2);
    }

    fn writeTileInfo(self: *Self, writer: *BitstreamWriter) !void {
        // uniform_tile_spacing_flag
        try writer.writeBit(1);

        // Tile columns
        if (self.config.tile_columns > 0) {
            const sb_cols = (self.config.width + 63) / 64;
            var i: u8 = 0;
            while (i < self.config.tile_columns) : (i += 1) {
                try writer.writeBit(1);
            }
            try writer.writeBit(0);
            _ = sb_cols;
        } else {
            try writer.writeBit(0);
        }

        // Tile rows
        if (self.config.tile_rows > 0) {
            const sb_rows = (self.config.height + 63) / 64;
            var i: u8 = 0;
            while (i < self.config.tile_rows) : (i += 1) {
                try writer.writeBit(1);
            }
            try writer.writeBit(0);
            _ = sb_rows;
        } else {
            try writer.writeBit(0);
        }

        // context_update_tile_id
        const num_tiles = (@as(u32, 1) << self.config.tile_columns) * (@as(u32, 1) << self.config.tile_rows);
        if (num_tiles > 1) {
            const tile_bits = self.bitWidth(num_tiles - 1);
            try writer.writeBits(0, tile_bits);
        }

        // tile_size_bytes_minus_1
        try writer.writeBits(3, 2); // 4 bytes for tile size
    }

    fn writeTileGroup(self: *Self, writer: *BitstreamWriter, input_frame: *const VideoFrame, is_keyframe: bool) !void {
        const num_tiles = (@as(u32, 1) << self.config.tile_columns) * (@as(u32, 1) << self.config.tile_rows);

        // tile_start_and_end_present_flag
        try writer.writeBit(0);

        // Encode tiles
        for (0..num_tiles) |tile_idx| {
            const tile_data = try self.encodeTile(input_frame, is_keyframe, @intCast(tile_idx));
            defer self.allocator.free(tile_data);

            // Write tile size (except for last tile)
            if (tile_idx < num_tiles - 1) {
                const size: u32 = @intCast(tile_data.len);
                // Write as 4 bytes (tile_size_bytes_minus_1 = 3)
                try writer.byteAlign();
                try writer.writeBits((size >> 24) & 0xFF, 8);
                try writer.writeBits((size >> 16) & 0xFF, 8);
                try writer.writeBits((size >> 8) & 0xFF, 8);
                try writer.writeBits(size & 0xFF, 8);
            }

            // Write tile data
            for (tile_data) |byte| {
                try writer.writeBits(byte, 8);
            }
        }
    }

    fn encodeTile(self: *Self, input_frame: *const VideoFrame, is_keyframe: bool, tile_idx: u32) ![]u8 {
        _ = tile_idx;

        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Simplified tile encoding
        // Real implementation would perform:
        // - Superblock partitioning (64x64 or 128x128)
        // - Intra/inter prediction
        // - Transform (DCT, ADST, identity)
        // - Quantization
        // - Entropy coding with symbol contexts

        const tile_size = if (is_keyframe)
            self.config.width * self.config.height / 20
        else
            self.config.width * self.config.height / 40;

        try output.appendNTimes(0, tile_size);

        self.rc_state.updateAfterFrame(tile_size * 8);

        _ = input_frame;
        return output.toOwnedSlice();
    }

    fn writeOBU(self: *Self, obu_type: OBUType, payload: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // OBU header
        var header: u8 = 0;
        header |= (@as(u8, @intFromEnum(obu_type)) << 3);
        header |= 0x04; // obu_has_size_field = true
        try output.append(header);

        // OBU size (LEB128 encoding)
        try self.writeLEB128(&output, payload.len);

        // OBU payload
        try output.appendSlice(payload);

        return output.toOwnedSlice();
    }

    fn writeLEB128(self: *Self, output: *std.ArrayList(u8), value_in: usize) !void {
        _ = self;
        var value = value_in;
        while (true) {
            var byte: u8 = @intCast(value & 0x7F);
            value >>= 7;
            if (value != 0) {
                byte |= 0x80; // More bytes follow
            }
            try output.append(byte);
            if (value == 0) break;
        }
    }

    fn calculateQIndex(self: *Self) u8 {
        // Map cq_level (0-63) to AV1 quantizer index (0-255)
        const cq = std.math.clamp(self.config.cq_level, 0, 63);
        return @intCast((255 * cq) / 63);
    }

    fn bitWidth(self: *Self, n: u32) u5 {
        _ = self;
        if (n == 0) return 1;
        return @intCast(32 - @clz(n));
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

/// Rate control state for AV1
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

/// Bitstream writer for AV1
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
