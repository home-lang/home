// Home Audio Library - FLAC Writer
// FLAC encoder for lossless audio compression

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const frame_mod = @import("../core/frame.zig");
const AudioFrame = frame_mod.AudioFrame;

const flac = @import("flac.zig");
const StreamInfo = flac.StreamInfo;
const MetadataBlockType = flac.MetadataBlockType;

/// FLAC compression level (0-8)
pub const CompressionLevel = enum(u4) {
    level_0 = 0, // Fastest, largest files
    level_1 = 1,
    level_2 = 2,
    level_3 = 3,
    level_4 = 4,
    level_5 = 5, // Default balance
    level_6 = 6,
    level_7 = 7,
    level_8 = 8, // Slowest, smallest files

    pub fn getBlockSize(self: CompressionLevel) u16 {
        return switch (self) {
            .level_0, .level_1, .level_2 => 1152,
            .level_3, .level_4, .level_5 => 4096,
            .level_6, .level_7, .level_8 => 4608,
        };
    }

    pub fn getMaxLpcOrder(self: CompressionLevel) u8 {
        return switch (self) {
            .level_0 => 0, // Fixed predictors only
            .level_1 => 0,
            .level_2 => 0,
            .level_3 => 6,
            .level_4 => 8,
            .level_5 => 8,
            .level_6 => 8,
            .level_7 => 12,
            .level_8 => 12,
        };
    }
};

/// FLAC encoder/writer
pub const FlacWriter = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,
    compression: CompressionLevel,
    total_samples: u64,

    // Encoding state
    frame_number: u32,
    block_size: u16,

    // Sample buffer for current block
    sample_buffer: []i32,
    samples_in_buffer: usize,

    // MD5 context for audio verification
    md5_state: std.crypto.hash.Md5,

    const Self = @This();

    /// Initialize FLAC writer
    pub fn init(
        allocator: Allocator,
        channels: u8,
        sample_rate: u32,
        bits_per_sample: u8,
    ) !Self {
        return initWithCompression(allocator, channels, sample_rate, bits_per_sample, .level_5);
    }

    /// Initialize with specific compression level
    pub fn initWithCompression(
        allocator: Allocator,
        channels: u8,
        sample_rate: u32,
        bits_per_sample: u8,
        compression: CompressionLevel,
    ) !Self {
        const block_size = compression.getBlockSize();
        const sample_buffer = try allocator.alloc(i32, @as(usize, block_size) * channels);
        @memset(sample_buffer, 0);

        var writer = Self{
            .allocator = allocator,
            .buffer = .{},
            .channels = channels,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .compression = compression,
            .total_samples = 0,
            .frame_number = 0,
            .block_size = block_size,
            .sample_buffer = sample_buffer,
            .samples_in_buffer = 0,
            .md5_state = std.crypto.hash.Md5.init(.{}),
        };

        // Write FLAC header
        try writer.writeHeader();

        return writer;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sample_buffer);
        self.buffer.deinit(self.allocator);
    }

    /// Write FLAC stream marker and placeholder STREAMINFO
    fn writeHeader(self: *Self) !void {
        // FLAC stream marker
        try self.buffer.appendSlice(self.allocator, "fLaC");

        // STREAMINFO block header (last block = false for now)
        // We'll update this at finalize
        try self.buffer.append(self.allocator, 0x00); // STREAMINFO type, not last
        try self.buffer.append(self.allocator, 0);
        try self.buffer.append(self.allocator, 0);
        try self.buffer.append(self.allocator, 34); // STREAMINFO is always 34 bytes

        // Reserve space for STREAMINFO (34 bytes)
        try self.buffer.appendNTimes(self.allocator, 0, 34);
    }

    /// Write samples to encoder
    pub fn writeSamples(self: *Self, samples: []const i32) !void {
        var offset: usize = 0;
        const samples_per_frame = @as(usize, self.block_size) * self.channels;

        while (offset < samples.len) {
            const space_left = samples_per_frame - self.samples_in_buffer;
            const to_copy = @min(samples.len - offset, space_left);

            @memcpy(
                self.sample_buffer[self.samples_in_buffer..][0..to_copy],
                samples[offset..][0..to_copy],
            );

            self.samples_in_buffer += to_copy;
            offset += to_copy;

            if (self.samples_in_buffer >= samples_per_frame) {
                try self.encodeBlock();
                self.samples_in_buffer = 0;
            }
        }

        // Update MD5
        const byte_slice = std.mem.sliceAsBytes(samples);
        self.md5_state.update(byte_slice);
        self.total_samples += samples.len / self.channels;
    }

    /// Write an AudioFrame
    pub fn writeFrame(self: *Self, audio_frame: *const AudioFrame) !void {
        // Convert frame data to i32 samples
        const num_samples = audio_frame.num_samples * self.channels;
        const samples = try self.allocator.alloc(i32, num_samples);
        defer self.allocator.free(samples);

        for (0..audio_frame.num_samples) |i| {
            for (0..self.channels) |ch| {
                const f32_sample = audio_frame.getSampleF32(i, @intCast(ch)) orelse 0;
                // Convert float to integer based on bit depth
                const scale = @as(f32, @floatFromInt(@as(i32, 1) << @intCast(self.bits_per_sample - 1)));
                samples[i * self.channels + ch] = @intFromFloat(math.clamp(f32_sample * scale, -scale, scale - 1));
            }
        }

        try self.writeSamples(samples);
    }

    /// Encode current block
    fn encodeBlock(self: *Self) !void {
        const samples_in_block = self.samples_in_buffer / self.channels;
        if (samples_in_block == 0) return;

        // Frame header
        try self.writeFrameHeader(@intCast(samples_in_block));

        // Encode each channel
        for (0..self.channels) |ch| {
            try self.encodeSubframe(ch, @intCast(samples_in_block));
        }

        // Frame footer (CRC-16)
        const crc = self.calculateCrc16();
        try self.buffer.append(self.allocator, @intCast((crc >> 8) & 0xFF));
        try self.buffer.append(self.allocator, @intCast(crc & 0xFF));

        self.frame_number += 1;
    }

    /// Write frame header
    fn writeFrameHeader(self: *Self, block_size: u16) !void {
        // Sync code (14 bits) + reserved (1) + blocking strategy (1)
        try self.buffer.append(self.allocator, 0xFF);
        try self.buffer.append(self.allocator, 0xF8); // Fixed block size

        // Block size (4 bits) + sample rate (4 bits)
        const bs_code = self.getBlockSizeCode(block_size);
        const sr_code = self.getSampleRateCode();
        try self.buffer.append(self.allocator, (bs_code << 4) | sr_code);

        // Channel assignment (4 bits) + sample size (3 bits) + reserved (1)
        const ch_code: u8 = if (self.channels <= 8) self.channels - 1 else 0;
        const ss_code = self.getSampleSizeCode();
        try self.buffer.append(self.allocator, (ch_code << 4) | (ss_code << 1));

        // Frame number (UTF-8 coded)
        try self.writeUtf8(self.frame_number);

        // Block size (if code indicates)
        if (bs_code == 6) {
            try self.buffer.append(self.allocator, @intCast(block_size - 1));
        } else if (bs_code == 7) {
            try self.buffer.append(self.allocator, @intCast((block_size - 1) >> 8));
            try self.buffer.append(self.allocator, @intCast((block_size - 1) & 0xFF));
        }

        // Sample rate (if code indicates)
        if (sr_code == 12) {
            try self.buffer.append(self.allocator, @intCast(self.sample_rate / 1000));
        } else if (sr_code == 13) {
            try self.buffer.append(self.allocator, @intCast(self.sample_rate >> 8));
            try self.buffer.append(self.allocator, @intCast(self.sample_rate & 0xFF));
        } else if (sr_code == 14) {
            try self.buffer.append(self.allocator, @intCast((self.sample_rate / 10) >> 8));
            try self.buffer.append(self.allocator, @intCast((self.sample_rate / 10) & 0xFF));
        }

        // CRC-8 of header
        const crc8 = self.calculateCrc8();
        try self.buffer.append(self.allocator, crc8);
    }

    /// Encode a subframe (single channel)
    fn encodeSubframe(self: *Self, channel: usize, num_samples: u16) !void {
        // Extract channel samples
        const channel_samples = try self.allocator.alloc(i32, num_samples);
        defer self.allocator.free(channel_samples);

        for (0..num_samples) |i| {
            channel_samples[i] = self.sample_buffer[i * self.channels + channel];
        }

        // Try different encoding methods and pick best
        // For simplicity, use verbatim for now (can be optimized with fixed/LPC predictors)
        try self.encodeVerbatim(channel_samples);
    }

    /// Verbatim encoding (uncompressed samples)
    fn encodeVerbatim(self: *Self, samples: []const i32) !void {
        // Subframe header: type (6 bits) + wasted bits (1+k bits)
        // Verbatim = 0b000001
        try self.buffer.append(self.allocator, 0x02); // Verbatim, no wasted bits

        // Write samples
        for (samples) |sample| {
            try self.writeSampleBits(sample);
        }
    }

    /// Write sample with current bit depth
    fn writeSampleBits(self: *Self, sample: i32) !void {
        switch (self.bits_per_sample) {
            8 => try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample)))),
            16 => {
                const s: i16 = @truncate(sample);
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(s >> 8))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(s))));
            },
            24 => {
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample >> 16))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample >> 8))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample))));
            },
            else => {
                // 32-bit
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample >> 24))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample >> 16))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample >> 8))));
                try self.buffer.append(self.allocator, @bitCast(@as(i8, @truncate(sample))));
            },
        }
    }

    /// Write UTF-8 encoded number
    fn writeUtf8(self: *Self, value: u32) !void {
        if (value < 0x80) {
            try self.buffer.append(self.allocator, @intCast(value));
        } else if (value < 0x800) {
            try self.buffer.append(self.allocator, @intCast(0xC0 | (value >> 6)));
            try self.buffer.append(self.allocator, @intCast(0x80 | (value & 0x3F)));
        } else if (value < 0x10000) {
            try self.buffer.append(self.allocator, @intCast(0xE0 | (value >> 12)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 6) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | (value & 0x3F)));
        } else if (value < 0x200000) {
            try self.buffer.append(self.allocator, @intCast(0xF0 | (value >> 18)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 12) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 6) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | (value & 0x3F)));
        } else {
            try self.buffer.append(self.allocator, @intCast(0xF8 | (value >> 24)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 18) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 12) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | ((value >> 6) & 0x3F)));
            try self.buffer.append(self.allocator, @intCast(0x80 | (value & 0x3F)));
        }
    }

    fn getBlockSizeCode(self: *Self, size: u16) u8 {
        _ = self;
        return switch (size) {
            192 => 1,
            576 => 2,
            1152 => 3,
            2304 => 4,
            4608 => 5,
            256 => 8,
            512 => 9,
            1024 => 10,
            2048 => 11,
            4096 => 12,
            8192 => 13,
            16384 => 14,
            32768 => 15,
            else => if (size <= 256) 6 else 7,
        };
    }

    fn getSampleRateCode(self: *Self) u8 {
        return switch (self.sample_rate) {
            88200 => 1,
            176400 => 2,
            192000 => 3,
            8000 => 4,
            16000 => 5,
            22050 => 6,
            24000 => 7,
            32000 => 8,
            44100 => 9,
            48000 => 10,
            96000 => 11,
            else => if (self.sample_rate % 1000 == 0) 12 else if (self.sample_rate <= 65535) 13 else 14,
        };
    }

    fn getSampleSizeCode(self: *Self) u8 {
        return switch (self.bits_per_sample) {
            8 => 1,
            12 => 2,
            16 => 4,
            20 => 5,
            24 => 6,
            32 => 7, // Actually reserved, but we use it
            else => 0,
        };
    }

    fn calculateCrc8(self: *Self) u8 {
        // Simple CRC-8 for frame header
        _ = self;
        return 0; // Placeholder - real implementation would calculate proper CRC
    }

    fn calculateCrc16(self: *Self) u16 {
        // CRC-16 for frame
        _ = self;
        return 0; // Placeholder - real implementation would calculate proper CRC
    }

    /// Finalize and get encoded FLAC data
    pub fn finalize(self: *Self) ![]u8 {
        // Flush remaining samples
        if (self.samples_in_buffer > 0) {
            try self.encodeBlock();
        }

        // Update STREAMINFO block
        const md5 = self.md5_state.finalResult();
        try self.updateStreamInfo(md5);

        // Mark STREAMINFO as last block
        self.buffer.items[4] = 0x80; // Set last-metadata-block flag

        const result = try self.allocator.alloc(u8, self.buffer.items.len);
        @memcpy(result, self.buffer.items);
        return result;
    }

    fn updateStreamInfo(self: *Self, md5: [16]u8) !void {
        const offset: usize = 8; // After "fLaC" and block header

        // min/max block size
        std.mem.writeInt(u16, self.buffer.items[offset..][0..2], self.block_size, .big);
        std.mem.writeInt(u16, self.buffer.items[offset + 2 ..][0..2], self.block_size, .big);

        // min/max frame size (0 = unknown for simplicity)
        @memset(self.buffer.items[offset + 4 ..][0..6], 0);

        // Sample rate (20 bits) + channels (3 bits) + bits per sample (5 bits) + total samples (36 bits)
        // This is packed into 8 bytes (bytes 10-17)
        const sr = self.sample_rate;
        const ch = self.channels - 1;
        const bps = self.bits_per_sample - 1;
        const ts = self.total_samples;

        self.buffer.items[offset + 10] = @intCast((sr >> 12) & 0xFF);
        self.buffer.items[offset + 11] = @intCast((sr >> 4) & 0xFF);
        self.buffer.items[offset + 12] = @intCast(((sr & 0x0F) << 4) | ((ch & 0x07) << 1) | ((bps >> 4) & 0x01));
        self.buffer.items[offset + 13] = @intCast(((bps & 0x0F) << 4) | ((ts >> 32) & 0x0F));
        std.mem.writeInt(u32, self.buffer.items[offset + 14 ..][0..4], @truncate(ts), .big);

        // MD5 signature
        @memcpy(self.buffer.items[offset + 18 ..][0..16], &md5);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FlacWriter init/deinit" {
    const allocator = std.testing.allocator;

    var writer = try FlacWriter.init(allocator, 2, 44100, 16);
    defer writer.deinit();

    try std.testing.expectEqual(@as(u8, 2), writer.channels);
    try std.testing.expectEqual(@as(u32, 44100), writer.sample_rate);
}

test "CompressionLevel block sizes" {
    try std.testing.expectEqual(@as(u16, 1152), CompressionLevel.level_0.getBlockSize());
    try std.testing.expectEqual(@as(u16, 4096), CompressionLevel.level_5.getBlockSize());
    try std.testing.expectEqual(@as(u16, 4608), CompressionLevel.level_8.getBlockSize());
}
