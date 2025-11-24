// Home Audio Library - WAV Format
// RIFF WAVE format reader and writer

const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");
const err = @import("../core/error.zig");

pub const AudioFrame = frame.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const AudioCodec = types.AudioCodec;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const AudioError = err.AudioError;

// ============================================================================
// WAV Constants
// ============================================================================

const RIFF_MAGIC = "RIFF".*;
const WAVE_MAGIC = "WAVE".*;
const FMT_CHUNK = "fmt ".*;
const DATA_CHUNK = "data".*;
const FACT_CHUNK = "fact".*;
const LIST_CHUNK = "LIST".*;
const INFO_CHUNK = "INFO".*;

// Audio format codes
const WAVE_FORMAT_PCM: u16 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_ALAW: u16 = 0x0006;
const WAVE_FORMAT_MULAW: u16 = 0x0007;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

// ============================================================================
// WAV Header
// ============================================================================

pub const WavHeader = struct {
    /// Audio format code
    format_code: u16,

    /// Number of channels
    channels: u16,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Bytes per second
    byte_rate: u32,

    /// Block align (bytes per sample frame)
    block_align: u16,

    /// Bits per sample
    bits_per_sample: u16,

    /// Data chunk size in bytes
    data_size: u32,

    /// Data chunk offset in file
    data_offset: u64,

    /// Number of samples (per channel)
    num_samples: ?u64,

    const Self = @This();

    /// Get sample format
    pub fn getSampleFormat(self: Self) ?SampleFormat {
        return switch (self.format_code) {
            WAVE_FORMAT_PCM => switch (self.bits_per_sample) {
                8 => .u8,
                16 => .s16le,
                24 => .s24le,
                32 => .s32le,
                else => null,
            },
            WAVE_FORMAT_IEEE_FLOAT => switch (self.bits_per_sample) {
                32 => .f32le,
                64 => .f64le,
                else => null,
            },
            WAVE_FORMAT_ALAW => .alaw,
            WAVE_FORMAT_MULAW => .ulaw,
            else => null,
        };
    }

    /// Get channel layout
    pub fn getChannelLayout(self: Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(@intCast(self.channels));
    }

    /// Get duration in seconds
    pub fn getDuration(self: Self) f64 {
        if (self.num_samples) |samples| {
            return @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(self.sample_rate));
        }
        // Calculate from data size
        const bytes_per_sample = self.bits_per_sample / 8;
        const total_samples = self.data_size / (self.channels * bytes_per_sample);
        return @as(f64, @floatFromInt(total_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get audio codec
    pub fn getCodec(self: Self) AudioCodec {
        return switch (self.format_code) {
            WAVE_FORMAT_PCM => switch (self.bits_per_sample) {
                8 => .pcm_u8,
                16 => .pcm_s16le,
                24 => .pcm_s24le,
                32 => .pcm_s32le,
                else => .unknown,
            },
            WAVE_FORMAT_IEEE_FLOAT => switch (self.bits_per_sample) {
                32 => .pcm_f32le,
                64 => .pcm_f64le,
                else => .unknown,
            },
            WAVE_FORMAT_ALAW => .pcm_alaw,
            WAVE_FORMAT_MULAW => .pcm_ulaw,
            else => .unknown,
        };
    }
};

// ============================================================================
// WAV Reader
// ============================================================================

pub const WavReader = struct {
    data: []const u8,
    pos: usize,
    header: WavHeader,
    samples_read: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 44) return AudioError.TruncatedData;

        // Verify RIFF header
        if (!std.mem.eql(u8, data[0..4], &RIFF_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        // Verify WAVE format
        if (!std.mem.eql(u8, data[8..12], &WAVE_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        var reader = Self{
            .data = data,
            .pos = 12,
            .header = undefined,
            .samples_read = 0,
            .allocator = allocator,
        };

        try reader.parseChunks();
        return reader;
    }

    /// Create reader from file
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = std.fs.cwd().openFile(path, .{}) catch return AudioError.FileNotFound;
        defer file.close();

        const data = file.readToEndAlloc(allocator, 1024 * 1024 * 1024) catch return AudioError.ReadError;
        errdefer allocator.free(data);

        const reader = try fromMemory(allocator, data);
        return reader;
    }

    fn parseChunks(self: *Self) !void {
        var found_fmt = false;
        var found_data = false;

        while (self.pos + 8 <= self.data.len) {
            const chunk_id = self.data[self.pos..][0..4];
            const chunk_size = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..4], .little);
            self.pos += 8;

            if (std.mem.eql(u8, chunk_id, &FMT_CHUNK)) {
                try self.parseFmtChunk(chunk_size);
                found_fmt = true;
            } else if (std.mem.eql(u8, chunk_id, &DATA_CHUNK)) {
                self.header.data_size = chunk_size;
                self.header.data_offset = self.pos;
                found_data = true;
                break; // Data chunk is typically last
            } else {
                // Skip unknown chunks
                self.pos += chunk_size;
                // Align to word boundary
                if (chunk_size % 2 != 0) self.pos += 1;
            }
        }

        if (!found_fmt) return AudioError.InvalidHeader;
        if (!found_data) return AudioError.InvalidHeader;

        // Calculate number of samples
        const bytes_per_sample = self.header.bits_per_sample / 8;
        if (bytes_per_sample > 0 and self.header.channels > 0) {
            self.header.num_samples = self.header.data_size / (self.header.channels * bytes_per_sample);
        }
    }

    fn parseFmtChunk(self: *Self, size: u32) !void {
        if (size < 16) return AudioError.InvalidHeader;

        self.header.format_code = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.header.channels = std.mem.readInt(u16, self.data[self.pos + 2 ..][0..2], .little);
        self.header.sample_rate = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..4], .little);
        self.header.byte_rate = std.mem.readInt(u32, self.data[self.pos + 8 ..][0..4], .little);
        self.header.block_align = std.mem.readInt(u16, self.data[self.pos + 12 ..][0..2], .little);
        self.header.bits_per_sample = std.mem.readInt(u16, self.data[self.pos + 14 ..][0..2], .little);

        self.pos += size;
        if (size % 2 != 0) self.pos += 1;
    }

    /// Read audio frames
    pub fn readFrames(self: *Self, max_samples: u64) !?AudioFrame {
        const sample_format = self.header.getSampleFormat() orelse return AudioError.UnsupportedFormat;
        const bytes_per_sample = sample_format.bytesPerSample();
        const total_samples = self.header.num_samples orelse return AudioError.InvalidHeader;

        if (self.samples_read >= total_samples) return null;

        const remaining = total_samples - self.samples_read;
        const samples_to_read = @min(max_samples, remaining);

        const data_start: usize = @intCast(self.header.data_offset + self.samples_read * self.header.channels * bytes_per_sample);
        const data_len: usize = @intCast(samples_to_read * self.header.channels * bytes_per_sample);

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
            @intCast(self.header.channels),
            self.header.sample_rate,
        );

        audio_frame.pts = Timestamp.fromSamples(self.samples_read, self.header.sample_rate);
        self.samples_read += samples_to_read;

        return audio_frame;
    }

    /// Read all frames at once
    pub fn readAll(self: *Self) !AudioFrame {
        const total = self.header.num_samples orelse return AudioError.InvalidHeader;
        return (try self.readFrames(total)) orelse AudioError.EndOfStream;
    }

    /// Seek to sample position
    pub fn seek(self: *Self, sample_pos: u64) !void {
        const total = self.header.num_samples orelse return;
        if (sample_pos > total) return AudioError.SeekError;
        self.samples_read = sample_pos;
    }

    /// Get remaining samples
    pub fn remainingSamples(self: *const Self) u64 {
        const total = self.header.num_samples orelse return 0;
        if (self.samples_read >= total) return 0;
        return total - self.samples_read;
    }
};

// ============================================================================
// WAV Writer
// ============================================================================

pub const WavWriter = struct {
    buffer: std.ArrayList(u8),
    channels: u8,
    sample_rate: u32,
    format: SampleFormat,
    samples_written: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new WAV writer
    pub fn init(allocator: std.mem.Allocator, channels: u8, sample_rate: u32, format: SampleFormat) !Self {
        var writer = Self{
            .buffer = .init(allocator),
            .channels = channels,
            .sample_rate = sample_rate,
            .format = format,
            .samples_written = 0,
            .allocator = allocator,
        };

        // Write placeholder header (will be updated on finalize)
        try writer.writeHeader();

        return writer;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    fn writeHeader(self: *Self) !void {
        // RIFF header
        try self.buffer.appendSlice("RIFF");
        try self.buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // File size (placeholder)
        try self.buffer.appendSlice("WAVE");

        // fmt chunk
        try self.buffer.appendSlice("fmt ");
        try self.writeU32(16); // Chunk size

        const format_code: u16 = if (self.format.isFloat()) WAVE_FORMAT_IEEE_FLOAT else WAVE_FORMAT_PCM;
        try self.writeU16(format_code);
        try self.writeU16(self.channels);
        try self.writeU32(self.sample_rate);

        const bytes_per_sample = self.format.bytesPerSample();
        const byte_rate = @as(u32, self.sample_rate) * self.channels * bytes_per_sample;
        const block_align = @as(u16, self.channels) * bytes_per_sample;
        const bits_per_sample = @as(u16, bytes_per_sample) * 8;

        try self.writeU32(byte_rate);
        try self.writeU16(block_align);
        try self.writeU16(bits_per_sample);

        // data chunk header
        try self.buffer.appendSlice("data");
        try self.writeU32(0); // Data size (placeholder)
    }

    fn writeU16(self: *Self, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }

    fn writeU32(self: *Self, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Write an audio frame
    pub fn writeFrame(self: *Self, audio_frame: *const AudioFrame) !void {
        // Convert format if necessary
        if (audio_frame.format == self.format and audio_frame.channels == self.channels) {
            try self.buffer.appendSlice(audio_frame.data);
            self.samples_written += audio_frame.num_samples;
        } else {
            // Convert samples
            for (0..@intCast(audio_frame.num_samples)) |s| {
                for (0..self.channels) |c| {
                    const src_channel: u8 = @intCast(if (c < audio_frame.channels) c else 0);
                    const sample = audio_frame.getSampleF32(@intCast(s), src_channel);

                    try self.writeSample(sample);
                }
            }
            self.samples_written += audio_frame.num_samples;
        }
    }

    fn writeSample(self: *Self, value: f32) !void {
        const clamped = std.math.clamp(value, -1.0, 1.0);

        switch (self.format) {
            .u8 => {
                const val: u8 = @intFromFloat((clamped + 1.0) * 127.5);
                try self.buffer.append(val);
            },
            .s16le => {
                const val: i16 = @intFromFloat(clamped * 32767.0);
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(i16, &bytes, val, .little);
                try self.buffer.appendSlice(&bytes);
            },
            .s24le => {
                const val: i32 = @intFromFloat(clamped * 8388607.0);
                try self.buffer.append(@truncate(@as(u32, @bitCast(val))));
                try self.buffer.append(@truncate(@as(u32, @bitCast(val)) >> 8));
                try self.buffer.append(@truncate(@as(u32, @bitCast(val)) >> 16));
            },
            .s32le => {
                const val: i32 = @intFromFloat(clamped * 2147483647.0);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, val, .little);
                try self.buffer.appendSlice(&bytes);
            },
            .f32le => {
                const bits: u32 = @bitCast(clamped);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, bits, .little);
                try self.buffer.appendSlice(&bytes);
            },
            else => return AudioError.UnsupportedFormat,
        }
    }

    /// Finalize and get the WAV data
    pub fn finalize(self: *Self) ![]u8 {
        const data = self.buffer.items;

        // Update RIFF chunk size (file size - 8)
        const riff_size: u32 = @intCast(data.len - 8);
        std.mem.writeInt(u32, data[4..8], riff_size, .little);

        // Update data chunk size
        const data_size: u32 = @intCast(data.len - 44);
        std.mem.writeInt(u32, data[40..44], data_size, .little);

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

/// Check if data is a WAV file
pub fn isWav(data: []const u8) bool {
    if (data.len < 12) return false;
    return std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WAVE");
}

/// Decode WAV from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    var reader = try WavReader.fromMemory(allocator, data);
    return try reader.readAll();
}

/// Encode to WAV format
pub fn encode(allocator: std.mem.Allocator, audio_frame: *const AudioFrame) ![]u8 {
    var writer = try WavWriter.init(allocator, audio_frame.channels, audio_frame.sample_rate, audio_frame.format);
    defer writer.deinit();

    try writer.writeFrame(audio_frame);
    return try writer.finalize();
}

// ============================================================================
// Tests
// ============================================================================

test "WAV header parsing" {
    // Minimal WAV header
    const wav_data = [_]u8{
        'R', 'I', 'F', 'F', // RIFF
        36,  0,   0,   0, // File size - 8
        'W', 'A', 'V', 'E', // WAVE
        'f', 'm', 't', ' ', // fmt chunk
        16,  0,   0,   0, // fmt chunk size
        1,   0, // PCM format
        2,   0, // 2 channels
        0x44, 0xAC, 0,   0, // 44100 Hz
        0x10, 0xB1, 0x02, 0, // Byte rate
        4,   0, // Block align
        16,  0, // Bits per sample
        'd', 'a', 't', 'a', // data chunk
        0,   0,   0,   0, // Data size
    };

    var reader = try WavReader.fromMemory(std.testing.allocator, &wav_data);
    try std.testing.expectEqual(@as(u16, 2), reader.header.channels);
    try std.testing.expectEqual(@as(u32, 44100), reader.header.sample_rate);
    try std.testing.expectEqual(@as(u16, 16), reader.header.bits_per_sample);
}

test "WAV writer" {
    var writer = try WavWriter.init(std.testing.allocator, 2, 44100, .s16le);
    defer writer.deinit();

    const data = try writer.finalize();
    defer std.testing.allocator.free(data);

    try std.testing.expect(isWav(data));
}

test "WAV round-trip" {
    // Create a frame
    var original = try AudioFrame.init(std.testing.allocator, 100, .s16le, 2, 44100);
    defer original.deinit();

    // Set some test samples
    original.setSampleF32(0, 0, 0.5);
    original.setSampleF32(0, 1, -0.5);

    // Encode to WAV
    const wav_data = try encode(std.testing.allocator, &original);
    defer std.testing.allocator.free(wav_data);

    // Decode back
    var decoded = try decode(std.testing.allocator, wav_data);
    defer decoded.deinit();

    // Verify
    try std.testing.expectEqual(original.num_samples, decoded.num_samples);
    try std.testing.expectEqual(original.channels, decoded.channels);
    try std.testing.expectEqual(original.sample_rate, decoded.sample_rate);
}
