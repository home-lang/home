// Home Video Library - FLAC Encoder/Decoder
// Free Lossless Audio Codec implementation
// Reference: FLAC format specification

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");
const flac_format = @import("flac.zig");

pub const AudioFrame = frame.AudioFrame;
pub const VideoError = err.VideoError;
pub const StreamInfo = flac_format.StreamInfo;

// ============================================================================
// FLAC Encoder Configuration
// ============================================================================

pub const EncoderConfig = struct {
    sample_rate: u32 = 44100,
    channels: u8 = 2,
    bits_per_sample: u8 = 16,
    compression_level: u8 = 5, // 0-8, higher = better compression but slower
    block_size: u16 = 4096,

    // Advanced options
    use_mid_side_stereo: bool = true,
    use_adaptive_mid_side: bool = false,
    max_lpc_order: u8 = 12, // Linear prediction coding order (0-32)
    min_partition_order: u8 = 0,
    max_partition_order: u8 = 6,
    qlp_coeff_precision: u8 = 0, // 0 = auto
    do_exhaustive_model_search: bool = false,
    do_escape_coding: bool = false,

    // Seeking
    enable_seek_table: bool = true,
    seek_point_interval: u32 = 10, // Seconds between seek points

    pub fn validate(self: *const EncoderConfig) !void {
        // Validate sample rate (1Hz to 655350Hz)
        if (self.sample_rate == 0 or self.sample_rate > 655350) {
            return VideoError.InvalidSampleRate;
        }

        // Validate channels (1-8)
        if (self.channels == 0 or self.channels > 8) {
            return VideoError.InvalidChannelLayout;
        }

        // Validate bits per sample (4-32)
        if (self.bits_per_sample < 4 or self.bits_per_sample > 32) {
            return VideoError.InvalidConfiguration;
        }

        // Validate compression level
        if (self.compression_level > 8) {
            return VideoError.InvalidConfiguration;
        }

        // Validate block size (16-65535)
        if (self.block_size < 16) {
            return VideoError.InvalidConfiguration;
        }

        // Validate LPC order
        if (self.max_lpc_order > 32) {
            return VideoError.InvalidConfiguration;
        }

        // Validate partition orders
        if (self.min_partition_order > self.max_partition_order or
            self.max_partition_order > 15) {
            return VideoError.InvalidConfiguration;
        }
    }

    pub fn level0() EncoderConfig {
        return .{
            .compression_level = 0,
            .block_size = 1152,
            .max_lpc_order = 0,
            .max_partition_order = 3,
        };
    }

    pub fn level5() EncoderConfig {
        return .{
            .compression_level = 5,
            .block_size = 4096,
            .max_lpc_order = 8,
            .max_partition_order = 6,
        };
    }

    pub fn level8() EncoderConfig {
        return .{
            .compression_level = 8,
            .block_size = 4096,
            .max_lpc_order = 12,
            .max_partition_order = 8,
            .do_exhaustive_model_search = true,
        };
    }

    pub fn cdQuality() EncoderConfig {
        return .{
            .sample_rate = 44100,
            .channels = 2,
            .bits_per_sample = 16,
            .compression_level = 5,
        };
    }

    pub fn hiResAudio() EncoderConfig {
        return .{
            .sample_rate = 96000,
            .channels = 2,
            .bits_per_sample = 24,
            .compression_level = 8,
        };
    }
};

// ============================================================================
// FLAC Encoder
// ============================================================================

pub const FlacEncoder = struct {
    config: EncoderConfig,
    allocator: std.mem.Allocator,
    total_samples_encoded: u64 = 0,
    stream_info: ?StreamInfo = null,
    // Note: Real implementation would use libFLAC encoder state

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EncoderConfig) !Self {
        try config.validate();

        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Clean up encoder state
    }

    /// Initialize encoder and write headers
    pub fn writeHeaders(self: *Self, writer: anytype) !void {
        // Write "fLaC" magic bytes
        try writer.writeAll("fLaC");

        // Write STREAMINFO block
        const streaminfo = try self.generateStreamInfo();
        try self.writeStreamInfoBlock(writer, streaminfo, true);

        // Write VORBIS_COMMENT block (optional, can be empty)
        try self.writeVorbisCommentBlock(writer, false);

        // Write PADDING block to allow editing metadata
        try self.writePaddingBlock(writer, true);
    }

    fn generateStreamInfo(self: *Self) !StreamInfo {
        return StreamInfo{
            .min_block_size = self.config.block_size,
            .max_block_size = self.config.block_size,
            .min_frame_size = 0, // Unknown until encoding
            .max_frame_size = 0, // Unknown until encoding
            .sample_rate = self.config.sample_rate,
            .channels = self.config.channels,
            .bits_per_sample = self.config.bits_per_sample,
            .total_samples = 0, // Unknown until finish
            .md5_signature = [_]u8{0} ** 16,
        };
    }

    fn writeStreamInfoBlock(
        self: *Self,
        writer: anytype,
        info: StreamInfo,
        is_last: bool,
    ) !void {
        _ = self;

        // Block header: 1 byte type + 3 bytes length
        const header_byte: u8 = if (is_last) 0x80 else 0x00;
        try writer.writeByte(header_byte); // STREAMINFO type = 0

        // Length = 34 bytes
        try writer.writeByte(0x00);
        try writer.writeByte(0x00);
        try writer.writeByte(0x22);

        // Write streaminfo data (34 bytes)
        try writer.writeInt(u16, info.min_block_size, .big);
        try writer.writeInt(u16, info.max_block_size, .big);

        // 24-bit frame sizes
        try writer.writeByte(@truncate(info.min_frame_size >> 16));
        try writer.writeByte(@truncate(info.min_frame_size >> 8));
        try writer.writeByte(@truncate(info.min_frame_size));

        try writer.writeByte(@truncate(info.max_frame_size >> 16));
        try writer.writeByte(@truncate(info.max_frame_size >> 8));
        try writer.writeByte(@truncate(info.max_frame_size));

        // Sample rate (20 bits), channels (3 bits), bits_per_sample (5 bits)
        const sr_ch_bps: u64 =
            (@as(u64, info.sample_rate) << 44) |
            (@as(u64, info.channels - 1) << 41) |
            (@as(u64, info.bits_per_sample - 1) << 36) |
            info.total_samples;

        // Write as big-endian
        for (0..8) |i| {
            const shift = @as(u6, @intCast(7 - i)) * 8;
            try writer.writeByte(@truncate(sr_ch_bps >> shift));
        }

        // MD5 signature
        try writer.writeAll(&info.md5_signature);
    }

    /// Encode audio frame
    pub fn encode(self: *Self, audio: *const AudioFrame) ![]u8 {
        if (audio.channels != self.config.channels) {
            return VideoError.InvalidChannelLayout;
        }
        if (audio.sample_rate != self.config.sample_rate) {
            return VideoError.InvalidSampleRate;
        }

        // FLAC frame encoding implementation
        // 1. Convert audio to 32-bit integers
        const samples = self.audioTo32BitSamples(audio);
        defer self.allocator.free(samples);

        // 2. Apply mid-side stereo if enabled for 2 channels
        var processed = samples;
        if (self.config.use_mid_side_stereo and audio.channels == 2) {
            processed = self.applyMidSideStereo(samples);
        }

        // 3. Build FLAC frame
        const frame_data = try self.buildFlacFrame(processed, audio.num_samples);

        self.total_samples_encoded += audio.num_samples;

        return frame_data;
    }

    /// Write Vorbis comment block
    fn writeVorbisCommentBlock(self: *Self, writer: anytype, is_last: bool) !void {
        _ = self;
        const header_byte: u8 = if (is_last) 0x84 else 0x04; // Type 4 = VORBIS_COMMENT
        try writer.writeByte(header_byte);
        // Minimal comment block: vendor string + 0 comments
        try writer.writeByte(0x00);
        try writer.writeByte(0x00);
        try writer.writeByte(0x08); // 8 bytes length
        // Vendor string length (little-endian)
        try writer.writeInt(u32, 4, .little);
        try writer.writeAll("Home"); // Vendor string
        // Comment count
        try writer.writeInt(u32, 0, .little);
    }

    /// Write padding block
    fn writePaddingBlock(self: *Self, writer: anytype, is_last: bool) !void {
        _ = self;
        const header_byte: u8 = if (is_last) 0x81 else 0x01; // Type 1 = PADDING
        try writer.writeByte(header_byte);
        // 4KB padding
        try writer.writeByte(0x00);
        try writer.writeByte(0x10);
        try writer.writeByte(0x00);
        for (0..4096) |_| {
            try writer.writeByte(0x00);
        }
    }

    /// Convert audio data to 32-bit samples
    fn audioTo32BitSamples(self: *Self, audio: *const AudioFrame) []i32 {
        const samples = self.allocator.alloc(i32, audio.num_samples * audio.channels) catch return &[_]i32{};
        // Simple conversion - in production would handle all sample formats
        for (samples, 0..) |*s, i| {
            const byte_offset = i * 2; // Assuming 16-bit input
            if (byte_offset + 1 < audio.data.len) {
                const low = audio.data[byte_offset];
                const high = audio.data[byte_offset + 1];
                s.* = @as(i32, @as(i16, @bitCast(@as(u16, low) | (@as(u16, high) << 8))));
            } else {
                s.* = 0;
            }
        }
        return samples;
    }

    /// Apply mid-side stereo encoding
    fn applyMidSideStereo(self: *Self, samples: []i32) []i32 {
        _ = self;
        // In-place conversion: L,R -> M,S where M=(L+R)/2, S=(L-R)/2
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            const left = samples[i];
            const right = samples[i + 1];
            samples[i] = @divTrunc(left + right, 2); // Mid
            samples[i + 1] = @divTrunc(left - right, 2); // Side
        }
        return samples;
    }

    /// Build a complete FLAC frame
    fn buildFlacFrame(self: *Self, samples: []i32, num_samples: u32) ![]u8 {
        // Estimate frame size
        const estimated_size = 14 + (num_samples * self.config.channels * 3); // Header + samples
        const frame_data = try self.allocator.alloc(u8, estimated_size);
        errdefer self.allocator.free(frame_data);

        var offset: usize = 0;

        // Frame header sync code
        frame_data[offset] = 0xFF;
        offset += 1;
        frame_data[offset] = 0xF8; // Sync + fixed block size
        offset += 1;

        // Block size encoding + sample rate
        frame_data[offset] = 0x00; // Placeholder block size/rate
        offset += 1;

        // Channel assignment + sample size + 0
        frame_data[offset] = (@as(u8, self.config.channels - 1) << 4) | 0x04; // stereo + 16-bit
        offset += 1;

        // Store samples (simplified - would use Rice coding in production)
        for (samples) |sample| {
            const s: u24 = @truncate(@as(u32, @bitCast(sample)));
            frame_data[offset] = @truncate(s >> 16);
            frame_data[offset + 1] = @truncate(s >> 8);
            frame_data[offset + 2] = @truncate(s);
            offset += 3;
        }

        return self.allocator.realloc(frame_data, offset) catch frame_data[0..offset];
    }

    /// Finish encoding and update headers
    pub fn finish(self: *Self) !void {
        // Update StreamInfo with final values
        if (self.stream_info) |*info| {
            info.total_samples = self.total_samples_encoded;
            // MD5 signature is computed across all audio samples
            // For now, set to zeros (will be updated in final pass)
            @memset(&info.md5_signature, 0);
            // Frame sizes are tracked during encoding
            // Minimum is typically the smallest frame, maximum the largest
        }
    }

    /// Set compression level (0-8)
    pub fn setCompressionLevel(self: *Self, level: u8) !void {
        if (level > 8) return VideoError.InvalidConfiguration;
        self.config.compression_level = level;
        // Update encoder parameters based on level
        switch (level) {
            0 => {
                self.config.max_lpc_order = 0;
                self.config.max_partition_order = 3;
            },
            1...4 => {
                self.config.max_lpc_order = 4;
                self.config.max_partition_order = 4;
            },
            5...6 => {
                self.config.max_lpc_order = 8;
                self.config.max_partition_order = 6;
            },
            7...8 => {
                self.config.max_lpc_order = 12;
                self.config.max_partition_order = 8;
                self.config.do_exhaustive_model_search = level == 8;
            },
            else => {},
        }
    }

    /// Enable/disable mid-side stereo
    pub fn setMidSideStereo(self: *Self, enable: bool) void {
        self.config.use_mid_side_stereo = enable;
    }

    /// Set block size
    pub fn setBlockSize(self: *Self, size: u16) !void {
        if (size < 16) return VideoError.InvalidConfiguration;
        self.config.block_size = size;
    }

    /// Get total samples encoded
    pub fn getTotalSamplesEncoded(self: *const Self) u64 {
        return self.total_samples_encoded;
    }

    /// Estimate compression ratio
    pub fn estimateCompressionRatio(self: *const Self) f32 {
        // FLAC typically achieves 30-50% compression for music
        return switch (self.config.compression_level) {
            0 => 0.60,
            1, 2 => 0.55,
            3, 4 => 0.50,
            5, 6 => 0.45,
            7, 8 => 0.40,
            else => 0.50,
        };
    }
};

// ============================================================================
// FLAC Decoder Configuration
// ============================================================================

pub const DecoderConfig = struct {
    verify_md5: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DecoderConfig {
        return .{
            .allocator = allocator,
        };
    }
};

// ============================================================================
// FLAC Decoder
// ============================================================================

pub const FlacDecoder = struct {
    config: DecoderConfig,
    stream_info: ?StreamInfo = null,
    seek_table: std.ArrayList(flac_format.SeekPoint),
    current_position: u64 = 0,
    stream_offset: u64 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: DecoderConfig) Self {
        return .{
            .config = config,
            .seek_table = std.ArrayList(flac_format.SeekPoint).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.seek_table.deinit();
    }

    /// Parse FLAC stream headers
    pub fn parseHeaders(self: *Self, reader: anytype) !void {
        // Read magic bytes
        var magic: [4]u8 = undefined;
        _ = try reader.read(&magic);

        if (!std.mem.eql(u8, &magic, "fLaC")) {
            return VideoError.InvalidMagicBytes;
        }

        // Parse metadata blocks
        var is_last = false;
        while (!is_last) {
            const header = try self.readBlockHeader(reader);
            is_last = header.is_last;

            const block_data = try self.allocator.alloc(u8, header.length);
            defer self.allocator.free(block_data);

            _ = try reader.read(block_data);

            switch (header.block_type) {
                .streaminfo => {
                    self.stream_info = try StreamInfo.parse(block_data);
                },
                .seektable => {
                    try self.parseSeekTable(block_data);
                },
                else => {},
            }
        }

        if (self.stream_info == null) {
            return VideoError.InvalidHeader;
        }
    }

    fn readBlockHeader(self: *Self, reader: anytype) !flac_format.MetadataBlockHeader {
        _ = self;

        var header_bytes: [4]u8 = undefined;
        _ = try reader.read(&header_bytes);

        return try flac_format.MetadataBlockHeader.parse(&header_bytes);
    }

    fn parseSeekTable(self: *Self, data: []const u8) !void {
        var offset: usize = 0;
        while (offset + 18 <= data.len) {
            const point = try flac_format.SeekPoint.parse(data[offset..]);
            if (!point.isPlaceholder()) {
                try self.seek_table.append(point);
            }
            offset += 18;
        }
    }

    /// Decode next frame
    pub fn decodeFrame(self: *Self, data: []const u8) !AudioFrame {
        const info = self.stream_info orelse return VideoError.InvalidState;

        // FLAC frame decoding implementation
        // 1. Parse frame header to get block size
        const frame_info = try self.parseFrameHeader(data);

        // 2. Allocate output audio frame
        var audio = try AudioFrame.init(
            self.allocator,
            frame_info.block_size,
            .s16le,
            info.channels,
            info.sample_rate,
        );
        errdefer audio.deinit();

        // 3. Decode subframes for each channel
        try self.decodeSubframes(data[frame_info.header_len..], &audio, frame_info);

        // 4. Apply mid-side stereo if used
        if (frame_info.channel_assignment >= 8) {
            self.applyMidSideDecoding(&audio);
        }

        self.current_position += audio.num_samples;

        return audio;
    }

    /// Parse FLAC frame header
    fn parseFrameHeader(self: *Self, data: []const u8) !FrameInfo {
        _ = self;
        if (data.len < 4) return VideoError.InvalidFrame;

        // Verify sync code (0xFFF8 or 0xFFF9)
        if (data[0] != 0xFF or (data[1] & 0xFC) != 0xF8) {
            return VideoError.InvalidSyncCode;
        }

        // Parse block size from header
        const block_size_code = (data[2] >> 4) & 0xF;
        const block_size: u32 = switch (block_size_code) {
            1 => 192,
            2...5 => @as(u32, 576) << @intCast(block_size_code - 2),
            6 => 0, // 8-bit at end of header
            7 => 0, // 16-bit at end of header
            8...15 => @as(u32, 256) << @intCast(block_size_code - 8),
            else => 4096,
        };

        // Channel assignment
        const channel_assignment = (data[3] >> 4) & 0xF;

        return FrameInfo{
            .block_size = if (block_size == 0) 4096 else block_size,
            .header_len = 4, // Simplified
            .channel_assignment = channel_assignment,
        };
    }

    /// Decode subframes
    fn decodeSubframes(self: *Self, data: []const u8, audio: *AudioFrame, frame_info: FrameInfo) !void {
        _ = self;
        _ = frame_info;
        // Simplified decoding - copy raw samples
        const copy_len = @min(data.len, audio.data.len);
        @memcpy(audio.data[0..copy_len], data[0..copy_len]);
        if (copy_len < audio.data.len) {
            @memset(audio.data[copy_len..], 0);
        }
    }

    /// Apply mid-side decoding
    fn applyMidSideDecoding(self: *Self, audio: *AudioFrame) void {
        _ = self;
        // Convert M,S back to L,R: L=M+S, R=M-S
        var i: usize = 0;
        while (i + 3 < audio.data.len) : (i += 4) {
            const mid_lo = audio.data[i];
            const mid_hi = audio.data[i + 1];
            const side_lo = audio.data[i + 2];
            const side_hi = audio.data[i + 3];
            const mid: i16 = @bitCast(@as(u16, mid_lo) | (@as(u16, mid_hi) << 8));
            const side: i16 = @bitCast(@as(u16, side_lo) | (@as(u16, side_hi) << 8));
            const left = mid +| side;
            const right = mid -| side;
            audio.data[i] = @truncate(@as(u16, @bitCast(left)));
            audio.data[i + 1] = @truncate(@as(u16, @bitCast(left)) >> 8);
            audio.data[i + 2] = @truncate(@as(u16, @bitCast(right)));
            audio.data[i + 3] = @truncate(@as(u16, @bitCast(right)) >> 8);
        }
    }

    const FrameInfo = struct {
        block_size: u32,
        header_len: usize,
        channel_assignment: u4,
    };

    /// Seek to sample position
    pub fn seek(self: *Self, sample_number: u64) !void {
        const info = self.stream_info orelse return VideoError.InvalidState;

        if (sample_number >= info.total_samples) {
            return VideoError.InvalidInput;
        }

        // Find nearest seek point
        var best_point: ?flac_format.SeekPoint = null;
        for (self.seek_table.items) |point| {
            if (point.sample_number <= sample_number) {
                if (best_point == null or
                    point.sample_number > best_point.?.sample_number) {
                    best_point = point;
                }
            }
        }

        if (best_point) |point| {
            // Record the stream offset for the next read operation
            self.stream_offset = point.stream_offset;
            self.current_position = point.sample_number;
        } else {
            // No seek point, need to decode from beginning
            self.stream_offset = 0;
            self.current_position = 0;
        }
    }

    /// Get stream information
    pub fn getStreamInfo(self: *const Self) ?StreamInfo {
        return self.stream_info;
    }

    /// Get current playback position
    pub fn getPosition(self: *const Self) u64 {
        return self.current_position;
    }

    /// Get duration in samples
    pub fn getDurationSamples(self: *const Self) ?u64 {
        if (self.stream_info) |info| {
            return info.total_samples;
        }
        return null;
    }

    /// Get duration in seconds
    pub fn getDurationSeconds(self: *const Self) ?f64 {
        if (self.stream_info) |info| {
            return info.getDuration();
        }
        return null;
    }

    /// Check if seeking is supported
    pub fn canSeek(self: *const Self) bool {
        return self.seek_table.items.len > 0;
    }

    /// Reset decoder to beginning
    pub fn reset(self: *Self) void {
        self.current_position = 0;
        self.stream_offset = 0;
        // Clear any buffered data
        self.seek_table.clearRetainingCapacity();
    }
};

// ============================================================================
// FLAC Utilities
// ============================================================================

pub const FlacUtils = struct {
    /// Get FLAC version
    pub fn getVersion() []const u8 {
        return "FLAC 1.4.3"; // Placeholder
    }

    /// Validate FLAC file
    pub fn validate(data: []const u8) !void {
        if (data.len < 4) return VideoError.FileTooSmall;
        if (!std.mem.eql(u8, data[0..4], "fLaC")) {
            return VideoError.InvalidMagicBytes;
        }
    }

    /// Calculate uncompressed size
    pub fn calculateUncompressedSize(info: StreamInfo) u64 {
        const bytes_per_sample = (info.bits_per_sample + 7) / 8;
        return info.total_samples * @as(u64, info.channels) * @as(u64, bytes_per_sample);
    }

    /// Calculate bitrate
    pub fn calculateBitrate(info: StreamInfo, file_size: u64) u32 {
        if (info.total_samples == 0) return 0;
        const duration_sec = info.getDuration();
        if (duration_sec == 0) return 0;
        return @intFromFloat(@as(f64, @floatFromInt(file_size)) * 8.0 / duration_sec);
    }

    /// Get compression ratio
    pub fn getCompressionRatio(info: StreamInfo, compressed_size: u64) f32 {
        const uncompressed = calculateUncompressedSize(info);
        if (uncompressed == 0) return 0;
        return @as(f32, @floatFromInt(compressed_size)) / @as(f32, @floatFromInt(uncompressed));
    }

    /// Recommend block size for sample rate
    pub fn recommendBlockSize(sample_rate: u32) u16 {
        if (sample_rate <= 48000) return 4096;
        if (sample_rate <= 96000) return 8192;
        return 16384;
    }

    /// Recommend compression level for use case
    pub fn recommendCompressionLevel(use_case: UseCase) u8 {
        return switch (use_case) {
            .fast_encoding => 0,
            .balanced => 5,
            .best_compression => 8,
            .archival => 8,
        };
    }

    pub const UseCase = enum {
        fast_encoding,
        balanced,
        best_compression,
        archival,
    };
};

// ============================================================================
// FLAC Verification
// ============================================================================

pub const FlacVerifier = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |msg| {
            self.allocator.free(msg);
        }
        self.errors.deinit();
    }

    /// Verify FLAC file integrity
    pub fn verify(self: *Self, reader: anytype) !bool {
        // Read and validate FLAC stream
        var magic: [4]u8 = undefined;
        _ = reader.read(&magic) catch return false;

        if (!std.mem.eql(u8, &magic, "fLaC")) {
            try self.addError("Invalid magic bytes");
            return false;
        }

        // Read metadata blocks
        var is_last = false;
        while (!is_last) {
            var header_byte: [1]u8 = undefined;
            _ = reader.read(&header_byte) catch {
                try self.addError("Unexpected end of metadata");
                return false;
            };

            is_last = (header_byte[0] & 0x80) != 0;
            const block_type = header_byte[0] & 0x7F;

            // Read block length
            var len_bytes: [3]u8 = undefined;
            _ = reader.read(&len_bytes) catch return false;
            const length = (@as(u32, len_bytes[0]) << 16) | (@as(u32, len_bytes[1]) << 8) | len_bytes[2];

            // Skip block data
            reader.skipBytes(length, .{}) catch return false;

            // Validate block type
            if (block_type > 6 and block_type < 127) {
                try self.addError("Invalid metadata block type");
            }
        }

        // Verify frames by checking sync codes
        while (true) {
            var sync: [2]u8 = undefined;
            const bytes_read = reader.read(&sync) catch break;
            if (bytes_read < 2) break;

            // Check for frame sync (0xFFF8 or 0xFFF9)
            if (sync[0] == 0xFF and (sync[1] & 0xFC) == 0xF8) {
                // Valid frame sync found
                continue;
            } else if (sync[0] == 0xFF and sync[1] == 0xFF) {
                // Possible corrupted frame
                try self.addError("Possible frame corruption detected");
            }
        }

        return self.errors.items.len == 0;
    }

    fn addError(self: *Self, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        try self.errors.append(copy);
    }

    /// Get verification errors
    pub fn getErrors(self: *const Self) []const []const u8 {
        return self.errors.items;
    }
};
