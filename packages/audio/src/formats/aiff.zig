// Home Audio Library - AIFF Format
// Audio Interchange File Format decoder/encoder

const std = @import("std");
const types = @import("../core/types.zig");
const frame_mod = @import("../core/frame.zig");
const err = @import("../core/error.zig");

pub const AudioFrame = frame_mod.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const AudioError = err.AudioError;

// ============================================================================
// AIFF Constants
// ============================================================================

const FORM_MAGIC = "FORM".*;
const AIFF_MAGIC = "AIFF".*;
const AIFC_MAGIC = "AIFC".*; // AIFF-C (compressed)

const COMM_CHUNK = "COMM".*;
const SSND_CHUNK = "SSND".*;
const MARK_CHUNK = "MARK".*;
const INST_CHUNK = "INST".*;
const NAME_CHUNK = "NAME".*;
const AUTH_CHUNK = "AUTH".*;
const COPY_CHUNK = "(c) ".*;
const ANNO_CHUNK = "ANNO".*;

// AIFF-C compression types
const NONE_COMPRESSION = "NONE".*;
const SOWT_COMPRESSION = "sowt".*; // Little-endian PCM
const FL32_COMPRESSION = "fl32".*; // 32-bit float
const FL64_COMPRESSION = "fl64".*; // 64-bit float

// ============================================================================
// Extended Precision Float
// ============================================================================

/// Convert 80-bit extended precision float to f64
fn extendedToDouble(bytes: [10]u8) f64 {
    // 80-bit format: 1 sign bit, 15 exponent bits, 64 mantissa bits
    const sign: u64 = bytes[0] >> 7;
    const exponent: u16 = (@as(u16, bytes[0] & 0x7F) << 8) | bytes[1];
    const mantissa: u64 = (@as(u64, bytes[2]) << 56) |
        (@as(u64, bytes[3]) << 48) |
        (@as(u64, bytes[4]) << 40) |
        (@as(u64, bytes[5]) << 32) |
        (@as(u64, bytes[6]) << 24) |
        (@as(u64, bytes[7]) << 16) |
        (@as(u64, bytes[8]) << 8) |
        @as(u64, bytes[9]);

    if (exponent == 0 and mantissa == 0) {
        return if (sign != 0) -0.0 else 0.0;
    }

    if (exponent == 0x7FFF) {
        // Infinity or NaN
        return if (mantissa == 0) (if (sign != 0) -std.math.inf(f64) else std.math.inf(f64)) else std.math.nan(f64);
    }

    // Normal number
    const e: i32 = @as(i32, exponent) - 16383; // Bias is 16383
    const m: f64 = @as(f64, @floatFromInt(mantissa)) / 9223372036854775808.0; // 2^63

    var result = m * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(e)));
    if (sign != 0) result = -result;

    return result;
}

/// Convert f64 to 80-bit extended precision float
fn doubleToExtended(value: f64) [10]u8 {
    var bytes: [10]u8 = .{0} ** 10;

    if (value == 0.0) {
        return bytes;
    }

    var v = value;
    var sign: u8 = 0;
    if (v < 0) {
        sign = 0x80;
        v = -v;
    }

    // Calculate exponent
    var exponent: i32 = 0;
    var mantissa = v;

    if (mantissa >= 1.0) {
        while (mantissa >= 2.0) {
            mantissa /= 2.0;
            exponent += 1;
        }
    } else {
        while (mantissa < 1.0) {
            mantissa *= 2.0;
            exponent -= 1;
        }
    }

    // Convert to 80-bit format
    const biased_exp: u16 = @intCast(exponent + 16383);
    const mant: u64 = @intFromFloat(mantissa * 9223372036854775808.0);

    bytes[0] = sign | @as(u8, @truncate(biased_exp >> 8));
    bytes[1] = @truncate(biased_exp);
    bytes[2] = @truncate(mant >> 56);
    bytes[3] = @truncate(mant >> 48);
    bytes[4] = @truncate(mant >> 40);
    bytes[5] = @truncate(mant >> 32);
    bytes[6] = @truncate(mant >> 24);
    bytes[7] = @truncate(mant >> 16);
    bytes[8] = @truncate(mant >> 8);
    bytes[9] = @truncate(mant);

    return bytes;
}

// ============================================================================
// AIFF Header
// ============================================================================

pub const AiffHeader = struct {
    /// Is AIFF-C (compressed) format
    is_aifc: bool,

    /// Number of channels
    channels: i16,

    /// Number of sample frames
    num_frames: u32,

    /// Bits per sample
    bits_per_sample: i16,

    /// Sample rate
    sample_rate: f64,

    /// Compression type (AIFF-C only)
    compression_type: ?[4]u8,

    /// Data offset in file
    data_offset: u64,

    /// Data size in bytes
    data_size: u32,

    /// Data block offset (usually 0)
    block_offset: u32,

    /// Data block size (usually 0)
    block_size: u32,

    const Self = @This();

    /// Get sample format
    pub fn getSampleFormat(self: Self) ?SampleFormat {
        if (self.is_aifc) {
            if (self.compression_type) |ct| {
                if (std.mem.eql(u8, &ct, &SOWT_COMPRESSION)) {
                    return switch (self.bits_per_sample) {
                        8 => .u8,
                        16 => .s16le,
                        24 => .s24le,
                        32 => .s32le,
                        else => null,
                    };
                }
                if (std.mem.eql(u8, &ct, &FL32_COMPRESSION)) {
                    return .f32be;
                }
                if (std.mem.eql(u8, &ct, &FL64_COMPRESSION)) {
                    return .f64be;
                }
            }
        }

        // Standard AIFF uses big-endian
        return switch (self.bits_per_sample) {
            8 => .u8,
            16 => .s16be,
            24 => .s24be,
            32 => .s32be,
            else => null,
        };
    }

    /// Get channel layout
    pub fn getChannelLayout(self: Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(@intCast(self.channels));
    }

    /// Get duration in seconds
    pub fn getDuration(self: Self) f64 {
        if (self.sample_rate <= 0) return 0;
        return @as(f64, @floatFromInt(self.num_frames)) / self.sample_rate;
    }
};

// ============================================================================
// AIFF Reader
// ============================================================================

pub const AiffReader = struct {
    data: []const u8,
    pos: usize,
    header: AiffHeader,
    samples_read: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 12) return AudioError.TruncatedData;

        // Verify FORM header
        if (!std.mem.eql(u8, data[0..4], &FORM_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        // Check for AIFF or AIFC
        const is_aifc = std.mem.eql(u8, data[8..12], &AIFC_MAGIC);
        if (!is_aifc and !std.mem.eql(u8, data[8..12], &AIFF_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        var reader = Self{
            .data = data,
            .pos = 12,
            .header = AiffHeader{
                .is_aifc = is_aifc,
                .channels = 0,
                .num_frames = 0,
                .bits_per_sample = 0,
                .sample_rate = 0,
                .compression_type = null,
                .data_offset = 0,
                .data_size = 0,
                .block_offset = 0,
                .block_size = 0,
            },
            .samples_read = 0,
            .allocator = allocator,
        };

        try reader.parseChunks();
        return reader;
    }

    fn parseChunks(self: *Self) !void {
        var found_comm = false;
        var found_ssnd = false;

        while (self.pos + 8 <= self.data.len) {
            const chunk_id = self.data[self.pos..][0..4];
            const chunk_size = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..4], .big);
            self.pos += 8;

            if (std.mem.eql(u8, chunk_id, &COMM_CHUNK)) {
                try self.parseCommChunk(chunk_size);
                found_comm = true;
            } else if (std.mem.eql(u8, chunk_id, &SSND_CHUNK)) {
                try self.parseSsndChunk(chunk_size);
                found_ssnd = true;
            } else {
                // Skip unknown chunks
                self.pos += chunk_size;
                // Align to word boundary
                if (chunk_size % 2 != 0) self.pos += 1;
            }
        }

        if (!found_comm) return AudioError.InvalidHeader;
        if (!found_ssnd) return AudioError.InvalidHeader;
    }

    fn parseCommChunk(self: *Self, size: u32) !void {
        const min_size: u32 = if (self.header.is_aifc) 22 else 18;
        if (size < min_size) return AudioError.InvalidHeader;

        self.header.channels = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
        self.header.num_frames = std.mem.readInt(u32, self.data[self.pos + 2 ..][0..6], .big);
        self.header.bits_per_sample = std.mem.readInt(i16, self.data[self.pos + 6 ..][0..2], .big);

        // Sample rate is 80-bit extended precision
        self.header.sample_rate = extendedToDouble(self.data[self.pos + 8 ..][0..10].*);

        if (self.header.is_aifc and size >= 22) {
            self.header.compression_type = self.data[self.pos + 18 ..][0..4].*;
        }

        self.pos += size;
        if (size % 2 != 0) self.pos += 1;
    }

    fn parseSsndChunk(self: *Self, size: u32) !void {
        if (size < 8) return AudioError.InvalidHeader;

        self.header.block_offset = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.header.block_size = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..8], .big);

        self.pos += 8;
        self.header.data_offset = self.pos + self.header.block_offset;
        self.header.data_size = size - 8;

        self.pos += size - 8;
        if ((size - 8) % 2 != 0) self.pos += 1;
    }

    /// Read audio frames
    pub fn readFrames(self: *Self, max_samples: u64) !?AudioFrame {
        const sample_format = self.header.getSampleFormat() orelse return AudioError.UnsupportedFormat;
        const bytes_per_sample = sample_format.bytesPerSample();
        const channels: u8 = @intCast(self.header.channels);

        if (self.samples_read >= self.header.num_frames) return null;

        const remaining = self.header.num_frames - @as(u32, @intCast(self.samples_read));
        const samples_to_read: u64 = @min(max_samples, remaining);

        const data_start: usize = @intCast(self.header.data_offset + self.samples_read * channels * bytes_per_sample);
        const data_len: usize = @intCast(samples_to_read * channels * bytes_per_sample);

        if (data_start + data_len > self.data.len) {
            return AudioError.TruncatedData;
        }

        const frame_data = try self.allocator.alloc(u8, data_len);
        @memcpy(frame_data, self.data[data_start..][0..data_len]);

        var audio_frame = AudioFrame.initFromData(
            self.allocator,
            frame_data,
            samples_to_read,
            sample_format,
            channels,
            @intFromFloat(self.header.sample_rate),
        );

        audio_frame.pts = Timestamp.fromSamples(self.samples_read, @intFromFloat(self.header.sample_rate));
        self.samples_read += samples_to_read;

        return audio_frame;
    }

    /// Read all frames at once
    pub fn readAll(self: *Self) !AudioFrame {
        return (try self.readFrames(self.header.num_frames)) orelse AudioError.EndOfStream;
    }

    /// Seek to sample position
    pub fn seek(self: *Self, sample_pos: u64) !void {
        if (sample_pos > self.header.num_frames) return AudioError.SeekError;
        self.samples_read = sample_pos;
    }
};

// ============================================================================
// AIFF Writer
// ============================================================================

pub const AiffWriter = struct {
    buffer: std.ArrayList(u8),
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,
    samples_written: u64,
    ssnd_size_offset: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new AIFF writer
    pub fn init(allocator: std.mem.Allocator, channels: u8, sample_rate: u32, bits_per_sample: u8) !Self {
        var writer = Self{
            .buffer = .init(allocator),
            .channels = channels,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .samples_written = 0,
            .ssnd_size_offset = 0,
            .allocator = allocator,
        };

        try writer.writeHeader();
        return writer;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    fn writeHeader(self: *Self) !void {
        // FORM header (placeholder for size)
        try self.buffer.appendSlice(&FORM_MAGIC);
        try self.buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // Size placeholder
        try self.buffer.appendSlice(&AIFF_MAGIC);

        // COMM chunk
        try self.buffer.appendSlice(&COMM_CHUNK);
        try self.writeU32Big(18); // Chunk size

        try self.writeI16Big(self.channels);
        try self.writeU32Big(0); // Num frames placeholder
        try self.writeI16Big(@intCast(self.bits_per_sample));

        // Sample rate as 80-bit extended precision
        const sr_extended = doubleToExtended(@floatFromInt(self.sample_rate));
        try self.buffer.appendSlice(&sr_extended);

        // SSND chunk
        try self.buffer.appendSlice(&SSND_CHUNK);
        self.ssnd_size_offset = self.buffer.items.len;
        try self.writeU32Big(8); // Chunk size placeholder (minimum 8 for offset+blocksize)
        try self.writeU32Big(0); // Offset
        try self.writeU32Big(0); // Block size
    }

    fn writeU32Big(self: *Self, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.buffer.appendSlice(&bytes);
    }

    fn writeI16Big(self: *Self, value: i16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, value, .big);
        try self.buffer.appendSlice(&bytes);
    }

    /// Write an audio frame
    pub fn writeFrame(self: *Self, audio_frame: *const AudioFrame) !void {
        const bytes_per_sample = self.bits_per_sample / 8;

        // Write samples (converting to big-endian if needed)
        for (0..@intCast(audio_frame.num_samples)) |s| {
            for (0..self.channels) |c| {
                const src_channel: u8 = @intCast(if (c < audio_frame.channels) c else 0);
                const sample = audio_frame.getSampleF32(@intCast(s), src_channel);
                try self.writeSampleBigEndian(sample);
            }
        }

        self.samples_written += audio_frame.num_samples;
        _ = bytes_per_sample;
    }

    fn writeSampleBigEndian(self: *Self, value: f32) !void {
        const clamped = std.math.clamp(value, -1.0, 1.0);

        switch (self.bits_per_sample) {
            8 => {
                const val: u8 = @intFromFloat((clamped + 1.0) * 127.5);
                try self.buffer.append(val);
            },
            16 => {
                const val: i16 = @intFromFloat(clamped * 32767.0);
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(i16, &bytes, val, .big);
                try self.buffer.appendSlice(&bytes);
            },
            24 => {
                const val: i32 = @intFromFloat(clamped * 8388607.0);
                try self.buffer.append(@truncate(@as(u32, @bitCast(val)) >> 16));
                try self.buffer.append(@truncate(@as(u32, @bitCast(val)) >> 8));
                try self.buffer.append(@truncate(@as(u32, @bitCast(val))));
            },
            32 => {
                const val: i32 = @intFromFloat(clamped * 2147483647.0);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, val, .big);
                try self.buffer.appendSlice(&bytes);
            },
            else => return AudioError.UnsupportedBitDepth,
        }
    }

    /// Finalize and get the AIFF data
    pub fn finalize(self: *Self) ![]u8 {
        const data = self.buffer.items;

        // Update FORM chunk size
        const form_size: u32 = @intCast(data.len - 8);
        std.mem.writeInt(u32, data[4..8], form_size, .big);

        // Update COMM chunk num frames (at offset 22)
        const num_frames: u32 = @intCast(self.samples_written);
        std.mem.writeInt(u32, data[22..26], num_frames, .big);

        // Update SSND chunk size
        const ssnd_data_size: u32 = @intCast(data.len - self.ssnd_size_offset - 4);
        std.mem.writeInt(u32, data[self.ssnd_size_offset..][0..4], ssnd_data_size, .big);

        return try self.allocator.dupe(u8, data);
    }

    /// Write to file
    pub fn writeToFile(self: *Self, path: []const u8) !void {
        const data = try self.finalize();
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is an AIFF file
pub fn isAiff(data: []const u8) bool {
    if (data.len < 12) return false;
    if (!std.mem.eql(u8, data[0..4], "FORM")) return false;
    return std.mem.eql(u8, data[8..12], "AIFF") or std.mem.eql(u8, data[8..12], "AIFC");
}

/// Decode AIFF from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    var reader = try AiffReader.fromMemory(allocator, data);
    return try reader.readAll();
}

/// Encode to AIFF format
pub fn encode(allocator: std.mem.Allocator, audio_frame: *const AudioFrame) ![]u8 {
    const bits = audio_frame.format.bitsPerSample();
    var writer = try AiffWriter.init(allocator, audio_frame.channels, audio_frame.sample_rate, bits);
    defer writer.deinit();

    try writer.writeFrame(audio_frame);
    return try writer.finalize();
}

// ============================================================================
// Tests
// ============================================================================

test "AIFF detection" {
    var aiff_data: [12]u8 = undefined;
    @memcpy(aiff_data[0..4], "FORM");
    @memset(aiff_data[4..8], 0);
    @memcpy(aiff_data[8..12], "AIFF");

    try std.testing.expect(isAiff(&aiff_data));

    var aifc_data: [12]u8 = undefined;
    @memcpy(aifc_data[0..4], "FORM");
    @memset(aifc_data[4..8], 0);
    @memcpy(aifc_data[8..12], "AIFC");

    try std.testing.expect(isAiff(&aifc_data));

    const not_aiff = [_]u8{ 'R', 'I', 'F', 'F' } ++ [_]u8{0} ** 8;
    try std.testing.expect(!isAiff(&not_aiff));
}

test "Extended precision conversion" {
    // Test common sample rates
    const rate_44100 = doubleToExtended(44100.0);
    const back_44100 = extendedToDouble(rate_44100);
    try std.testing.expectApproxEqAbs(@as(f64, 44100.0), back_44100, 0.1);

    const rate_48000 = doubleToExtended(48000.0);
    const back_48000 = extendedToDouble(rate_48000);
    try std.testing.expectApproxEqAbs(@as(f64, 48000.0), back_48000, 0.1);
}

test "AIFF writer" {
    var writer = try AiffWriter.init(std.testing.allocator, 2, 44100, 16);
    defer writer.deinit();

    const data = try writer.finalize();
    defer std.testing.allocator.free(data);

    try std.testing.expect(isAiff(data));
}
