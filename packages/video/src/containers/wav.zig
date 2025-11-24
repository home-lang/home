// Home Video Library - WAV Container
// RIFF WAVE format reader and writer

const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");
const packet = @import("../core/packet.zig");
const err = @import("../core/error.zig");

pub const AudioFrame = frame.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const AudioCodec = types.AudioCodec;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Rational = types.Rational;
pub const VideoError = err.VideoError;

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
            WAVE_FORMAT_ALAW => .s16le, // Decoded to s16
            WAVE_FORMAT_MULAW => .s16le, // Decoded to s16
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

        const samples = self.data_size / @as(u32, self.block_align);
        return @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get total number of sample frames
    pub fn getTotalSamples(self: Self) u64 {
        if (self.num_samples) |samples| return samples;
        return self.data_size / @as(u32, self.block_align);
    }
};

// ============================================================================
// WAV Reader
// ============================================================================

pub const WavReader = struct {
    /// Header information
    header: WavHeader,

    /// Source data
    data: []const u8,

    /// Current read position (samples)
    position: u64,

    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open WAV from memory
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 44) return VideoError.TruncatedData;

        // Check RIFF header
        if (!std.mem.eql(u8, data[0..4], &RIFF_MAGIC)) {
            return VideoError.InvalidMagicBytes;
        }

        // Check WAVE format
        if (!std.mem.eql(u8, data[8..12], &WAVE_MAGIC)) {
            return VideoError.InvalidContainer;
        }

        // Parse chunks
        var offset: usize = 12;
        var header = WavHeader{
            .format_code = 0,
            .channels = 0,
            .sample_rate = 0,
            .byte_rate = 0,
            .block_align = 0,
            .bits_per_sample = 0,
            .data_size = 0,
            .data_offset = 0,
            .num_samples = null,
        };

        var found_fmt = false;
        var found_data = false;

        while (offset + 8 <= data.len) {
            const chunk_id = data[offset..][0..4];
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
            const chunk_data_start = offset + 8;

            if (std.mem.eql(u8, chunk_id, &FMT_CHUNK)) {
                if (chunk_size < 16) return VideoError.InvalidHeader;
                if (chunk_data_start + 16 > data.len) return VideoError.TruncatedData;

                header.format_code = std.mem.readInt(u16, data[chunk_data_start..][0..2], .little);
                header.channels = std.mem.readInt(u16, data[chunk_data_start + 2 ..][0..2], .little);
                header.sample_rate = std.mem.readInt(u32, data[chunk_data_start + 4 ..][0..4], .little);
                header.byte_rate = std.mem.readInt(u32, data[chunk_data_start + 8 ..][0..4], .little);
                header.block_align = std.mem.readInt(u16, data[chunk_data_start + 12 ..][0..2], .little);
                header.bits_per_sample = std.mem.readInt(u16, data[chunk_data_start + 14 ..][0..2], .little);

                found_fmt = true;
            } else if (std.mem.eql(u8, chunk_id, &DATA_CHUNK)) {
                header.data_size = chunk_size;
                header.data_offset = chunk_data_start;
                found_data = true;
            } else if (std.mem.eql(u8, chunk_id, &FACT_CHUNK)) {
                if (chunk_size >= 4 and chunk_data_start + 4 <= data.len) {
                    header.num_samples = std.mem.readInt(u32, data[chunk_data_start..][0..4], .little);
                }
            }

            // Move to next chunk (align to even boundary)
            offset += 8 + ((chunk_size + 1) & ~@as(u32, 1));
        }

        if (!found_fmt or !found_data) {
            return VideoError.InvalidContainer;
        }

        // Validate header
        if (header.channels == 0 or header.channels > 8) {
            return VideoError.InvalidChannelLayout;
        }

        if (header.sample_rate == 0 or header.sample_rate > 384000) {
            return VideoError.InvalidSampleRate;
        }

        if (header.getSampleFormat() == null) {
            return VideoError.UnsupportedSampleFormat;
        }

        return Self{
            .header = header,
            .data = data,
            .position = 0,
            .allocator = allocator,
        };
    }

    /// Open WAV from file
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = std.fs.cwd().openFile(path, .{}) catch return VideoError.FileNotFound;
        defer file.close();

        const data = file.readToEndAlloc(allocator, 1024 * 1024 * 1024) catch return VideoError.ReadError; // 1GB max
        errdefer allocator.free(data);

        return fromMemory(allocator, data);
    }

    /// Read audio frames
    pub fn readFrames(self: *Self, max_samples: u32) !?AudioFrame {
        const total = self.header.getTotalSamples();
        if (self.position >= total) return null;

        const remaining = total - self.position;
        const samples_to_read = @min(max_samples, @as(u32, @intCast(remaining)));

        const sample_format = self.header.getSampleFormat() orelse return VideoError.UnsupportedSampleFormat;

        var audio = try AudioFrame.init(
            self.allocator,
            samples_to_read,
            sample_format,
            @intCast(self.header.channels),
            self.header.sample_rate,
        );
        errdefer audio.deinit();

        // Calculate byte offset
        const bytes_per_sample = self.header.block_align;
        const start_byte = self.header.data_offset + self.position * bytes_per_sample;
        const bytes_to_read = @as(usize, samples_to_read) * bytes_per_sample;

        if (start_byte + bytes_to_read > self.data.len) {
            return VideoError.TruncatedData;
        }

        // Copy data
        @memcpy(audio.data[0..bytes_to_read], self.data[start_byte..][0..bytes_to_read]);

        // Set timestamp
        audio.pts = Timestamp.fromSeconds(
            @as(f64, @floatFromInt(self.position)) / @as(f64, @floatFromInt(self.header.sample_rate)),
        );

        self.position += samples_to_read;

        return audio;
    }

    /// Seek to sample position
    pub fn seek(self: *Self, sample_position: u64) !void {
        const total = self.header.getTotalSamples();
        if (sample_position > total) {
            return VideoError.SeekOutOfRange;
        }
        self.position = sample_position;
    }

    /// Seek to timestamp
    pub fn seekToTime(self: *Self, timestamp: Timestamp) !void {
        const sample_pos = @as(u64, @intFromFloat(timestamp.toSeconds() * @as(f64, @floatFromInt(self.header.sample_rate))));
        try self.seek(sample_pos);
    }

    /// Get stream info
    pub fn getStreamInfo(self: *const Self) packet.AudioStreamInfo {
        const sample_format = self.header.getSampleFormat() orelse .s16le;

        return packet.AudioStreamInfo{
            .codec = .pcm,
            .sample_rate = self.header.sample_rate,
            .channels = @intCast(self.header.channels),
            .channel_layout = self.header.getChannelLayout(),
            .sample_format = sample_format,
            .time_base = Rational{ .num = 1, .denom = @intCast(self.header.sample_rate) },
            .bit_depth = @intCast(self.header.bits_per_sample),
            .bitrate = self.header.byte_rate * 8,
            .extradata = null,
            .profile = null,
        };
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        return Duration.fromSeconds(self.header.getDuration());
    }

    /// Is at end?
    pub fn isAtEnd(self: *const Self) bool {
        return self.position >= self.header.getTotalSamples();
    }
};

// ============================================================================
// WAV Writer
// ============================================================================

pub const WavWriter = struct {
    /// Output buffer
    buffer: std.ArrayList(u8),

    /// Allocator
    allocator: std.mem.Allocator,

    /// Header information
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    format_code: u16,

    /// Number of samples written
    samples_written: u64,

    /// Data chunk start position
    data_start: usize,

    /// Is finalized?
    is_finalized: bool,

    const Self = @This();

    /// Create a new WAV writer
    pub fn init(
        allocator: std.mem.Allocator,
        channels: u8,
        sample_rate: u32,
        sample_format: SampleFormat,
    ) !Self {
        var writer = Self{
            .buffer = .empty,
            .allocator = allocator,
            .channels = channels,
            .sample_rate = sample_rate,
            .bits_per_sample = sample_format.bitDepth(),
            .format_code = if (sample_format.isFloat()) WAVE_FORMAT_IEEE_FLOAT else WAVE_FORMAT_PCM,
            .samples_written = 0,
            .data_start = 0,
            .is_finalized = false,
        };

        try writer.writeHeader();
        return writer;
    }

    fn writeHeader(self: *Self) !void {
        // RIFF header (will be updated at end)
        try self.buffer.appendSlice(self.allocator, &RIFF_MAGIC);
        try self.buffer.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }); // File size - 8 (placeholder)
        try self.buffer.appendSlice(self.allocator, &WAVE_MAGIC);

        // fmt chunk
        try self.buffer.appendSlice(self.allocator, &FMT_CHUNK);

        // Write chunk size and format data
        var fmt_data: [16]u8 = undefined;
        std.mem.writeInt(u32, fmt_data[0..4], 16, .little); // Chunk size
        std.mem.writeInt(u16, fmt_data[4..6], self.format_code, .little);
        std.mem.writeInt(u16, fmt_data[6..8], self.channels, .little);
        std.mem.writeInt(u32, fmt_data[8..12], self.sample_rate, .little);

        const block_align = self.channels * (self.bits_per_sample / 8);
        const byte_rate = self.sample_rate * block_align;

        std.mem.writeInt(u32, fmt_data[12..16], byte_rate, .little);
        try self.buffer.appendSlice(self.allocator, &fmt_data);

        var align_data: [4]u8 = undefined;
        std.mem.writeInt(u16, align_data[0..2], block_align, .little);
        std.mem.writeInt(u16, align_data[2..4], self.bits_per_sample, .little);
        try self.buffer.appendSlice(self.allocator, &align_data);

        // data chunk header
        try self.buffer.appendSlice(self.allocator, &DATA_CHUNK);
        try self.buffer.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }); // Data size (placeholder)

        self.data_start = self.buffer.items.len;
    }

    /// Write audio frame
    pub fn writeFrame(self: *Self, audio_frame: *const AudioFrame) !void {
        if (self.is_finalized) return VideoError.InvalidState;

        // Verify format compatibility
        if (audio_frame.channels != self.channels) {
            return VideoError.InvalidChannelLayout;
        }

        if (audio_frame.sample_rate != self.sample_rate) {
            return VideoError.InvalidSampleRate;
        }

        // Write raw audio data
        try self.buffer.appendSlice(self.allocator, audio_frame.data);
        self.samples_written += audio_frame.num_samples;
    }

    /// Write raw samples
    pub fn writeSamples(self: *Self, data: []const u8) !void {
        if (self.is_finalized) return VideoError.InvalidState;

        try self.buffer.appendSlice(self.allocator, data);

        const bytes_per_sample = (self.bits_per_sample / 8) * self.channels;
        self.samples_written += data.len / bytes_per_sample;
    }

    /// Finalize the file (update headers)
    pub fn finalize(self: *Self) !void {
        if (self.is_finalized) return;

        const data_size = self.buffer.items.len - self.data_start;
        const file_size = self.buffer.items.len - 8;

        // Update RIFF chunk size
        std.mem.writeInt(u32, self.buffer.items[4..8], @intCast(file_size), .little);

        // Update data chunk size
        const data_size_offset = self.data_start - 4;
        std.mem.writeInt(u32, self.buffer.items[data_size_offset..][0..4], @intCast(data_size), .little);

        self.is_finalized = true;
    }

    /// Get the encoded data
    pub fn getData(self: *Self) ![]const u8 {
        if (!self.is_finalized) {
            try self.finalize();
        }
        return self.buffer.items;
    }

    /// Write to file
    pub fn writeToFile(self: *Self, path: []const u8) !void {
        const data = try self.getData();

        const file = std.fs.cwd().createFile(path, .{}) catch return VideoError.WriteError;
        defer file.close();

        file.writeAll(data) catch return VideoError.WriteError;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Get current duration
    pub fn getDuration(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.samples_written)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Check if data is a WAV file
pub fn isWav(data: []const u8) bool {
    if (data.len < 12) return false;
    return std.mem.eql(u8, data[0..4], &RIFF_MAGIC) and std.mem.eql(u8, data[8..12], &WAVE_MAGIC);
}

/// Get WAV format from magic bytes
pub fn detectFormat(data: []const u8) ?types.AudioFormat {
    if (isWav(data)) return .wav;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "WAV magic detection" {
    const wav_header = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expect(isWav(&wav_header));

    const not_wav = [_]u8{ 'O', 'g', 'g', 'S', 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(!isWav(&not_wav));
}

test "WAV writer and reader roundtrip" {
    const allocator = std.testing.allocator;

    // Create a simple WAV
    var writer = try WavWriter.init(allocator, 2, 44100, .s16le);
    defer writer.deinit();

    // Create a test audio frame
    var audio = try AudioFrame.init(allocator, 1024, .s16le, 2, 44100);
    defer audio.deinit();

    // Fill with a simple sine wave
    for (0..1024) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        const val = @sin(t * 440.0 * 2.0 * std.math.pi);
        audio.setSampleF32(0, @intCast(i), val);
        audio.setSampleF32(1, @intCast(i), val);
    }

    try writer.writeFrame(&audio);

    // Get the encoded data
    const wav_data = try writer.getData();

    // Read it back
    var reader = try WavReader.fromMemory(allocator, wav_data);

    try std.testing.expectEqual(@as(u32, 44100), reader.header.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), reader.header.channels);
    try std.testing.expectEqual(@as(u16, 16), reader.header.bits_per_sample);

    // Read frames back
    const read_audio = try reader.readFrames(1024);
    try std.testing.expect(read_audio != null);

    if (read_audio) |a| {
        var read_frame = a;
        defer read_frame.deinit();
        try std.testing.expectEqual(@as(u32, 1024), read_frame.num_samples);
    }
}
