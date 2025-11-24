// Home Video Library - WAV Muxer
// RIFF WAVE audio container with Broadcast WAV and RF64 support

const std = @import("std");
const core = @import("../core.zig");

/// WAV format codes
pub const FormatCode = enum(u16) {
    pcm = 0x0001,
    adpcm = 0x0002,
    ieee_float = 0x0003,
    alaw = 0x0006,
    mulaw = 0x0007,
    extensible = 0xFFFE,
};

/// Broadcast WAV UMID (Unique Material Identifier)
pub const UMID = struct {
    basic: [32]u8,
    signature: [32]u8,
};

/// Broadcast WAV extension chunk
pub const BextChunk = struct {
    description: [256]u8 = [_]u8{0} ** 256,
    originator: [32]u8 = [_]u8{0} ** 32,
    originator_reference: [32]u8 = [_]u8{0} ** 32,
    origination_date: [10]u8 = [_]u8{0} ** 10, // YYYY-MM-DD
    origination_time: [8]u8 = [_]u8{0} ** 8,   // HH:MM:SS
    time_reference_low: u32 = 0,
    time_reference_high: u32 = 0,
    version: u16 = 1,
    umid: ?UMID = null,
    loudness_value: i16 = 0,
    loudness_range: i16 = 0,
    max_true_peak_level: i16 = 0,
    max_momentary_loudness: i16 = 0,
    max_short_term_loudness: i16 = 0,
};

/// WAV muxer
pub const WAVMuxer = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    format_code: FormatCode = .pcm,

    // Options
    enable_rf64: bool = false,  // For files >4GB
    enable_bext: bool = false,  // Broadcast WAV extension
    bext_chunk: ?BextChunk = null,

    // Data
    samples: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u16, bits_per_sample: u16) Self {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits_per_sample = bits_per_sample,
            .samples = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.samples.deinit();
    }

    pub fn addSamples(self: *Self, data: []const u8) !void {
        try self.samples.appendSlice(data);
    }

    pub fn finalize(self: *Self) ![]u8 {
        const data_size = self.samples.items.len;
        const needs_rf64 = data_size > 0xFFFFFFFF - 1000 or self.enable_rf64;

        if (needs_rf64) {
            return try self.finalizeRF64();
        } else {
            return try self.finalizeWAV();
        }
    }

    fn finalizeWAV(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const data_size: u32 = @intCast(self.samples.items.len);
        const fmt_chunk_size: u32 = 16;
        var total_size: u32 = 4 + 8 + fmt_chunk_size; // WAVE + fmt chunk

        if (self.enable_bext and self.bext_chunk != null) {
            total_size += 8 + 602; // bext chunk (minimum size)
        }

        total_size += 8 + data_size; // data chunk

        // RIFF header
        try output.appendSlice("RIFF");
        try output.writer().writeInt(u32, total_size, .little);
        try output.appendSlice("WAVE");

        // Broadcast extension (before fmt)
        if (self.enable_bext and self.bext_chunk != null) {
            try self.writeBextChunk(&output);
        }

        // fmt chunk
        try output.appendSlice("fmt ");
        try output.writer().writeInt(u32, fmt_chunk_size, .little);
        try output.writer().writeInt(u16, @intFromEnum(self.format_code), .little);
        try output.writer().writeInt(u16, self.channels, .little);
        try output.writer().writeInt(u32, self.sample_rate, .little);

        const byte_rate = self.sample_rate * self.channels * (self.bits_per_sample / 8);
        try output.writer().writeInt(u32, byte_rate, .little);

        const block_align: u16 = self.channels * (self.bits_per_sample / 8);
        try output.writer().writeInt(u16, block_align, .little);
        try output.writer().writeInt(u16, self.bits_per_sample, .little);

        // data chunk
        try output.appendSlice("data");
        try output.writer().writeInt(u32, data_size, .little);
        try output.appendSlice(self.samples.items);

        return output.toOwnedSlice();
    }

    fn finalizeRF64(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const data_size: u64 = @intCast(self.samples.items.len);

        // RF64 header (not RIFF)
        try output.appendSlice("RF64");
        try output.writer().writeInt(u32, 0xFFFFFFFF, .little); // Placeholder

        try output.appendSlice("WAVE");

        // ds64 chunk (required for RF64)
        try self.writeDS64Chunk(&output, data_size);

        // Broadcast extension
        if (self.enable_bext and self.bext_chunk != null) {
            try self.writeBextChunk(&output);
        }

        // fmt chunk
        try output.appendSlice("fmt ");
        try output.writer().writeInt(u32, 16, .little);
        try output.writer().writeInt(u16, @intFromEnum(self.format_code), .little);
        try output.writer().writeInt(u16, self.channels, .little);
        try output.writer().writeInt(u32, self.sample_rate, .little);

        const byte_rate = self.sample_rate * self.channels * (self.bits_per_sample / 8);
        try output.writer().writeInt(u32, byte_rate, .little);

        const block_align: u16 = self.channels * (self.bits_per_sample / 8);
        try output.writer().writeInt(u16, block_align, .little);
        try output.writer().writeInt(u16, self.bits_per_sample, .little);

        // data chunk
        try output.appendSlice("data");
        try output.writer().writeInt(u32, 0xFFFFFFFF, .little); // Placeholder
        try output.appendSlice(self.samples.items);

        return output.toOwnedSlice();
    }

    fn writeDS64Chunk(self: *Self, output: *std.ArrayList(u8), data_size: u64) !void {
        _ = self;

        try output.appendSlice("ds64");

        // Chunk size (28 bytes minimum)
        try output.writer().writeInt(u32, 28, .little);

        // RIFF size (64-bit)
        const riff_size = data_size + 60; // Approximate
        try output.writer().writeInt(u64, riff_size, .little);

        // Data size (64-bit)
        try output.writer().writeInt(u64, data_size, .little);

        // Sample count (64-bit) - 0 for PCM
        try output.writer().writeInt(u64, 0, .little);

        // Table length (0 = no table)
        try output.writer().writeInt(u32, 0, .little);
    }

    fn writeBextChunk(self: *Self, output: *std.ArrayList(u8)) !void {
        if (self.bext_chunk) |bext| {
            try output.appendSlice("bext");

            // Minimum chunk size is 602 bytes
            try output.writer().writeInt(u32, 602, .little);

            // Description (256 bytes)
            try output.appendSlice(&bext.description);

            // Originator (32 bytes)
            try output.appendSlice(&bext.originator);

            // Originator reference (32 bytes)
            try output.appendSlice(&bext.originator_reference);

            // Origination date (10 bytes)
            try output.appendSlice(&bext.origination_date);

            // Origination time (8 bytes)
            try output.appendSlice(&bext.origination_time);

            // Time reference
            try output.writer().writeInt(u32, bext.time_reference_low, .little);
            try output.writer().writeInt(u32, bext.time_reference_high, .little);

            // Version
            try output.writer().writeInt(u16, bext.version, .little);

            // UMID (64 bytes)
            if (bext.umid) |umid| {
                try output.appendSlice(&umid.basic);
                try output.appendSlice(&umid.signature);
            } else {
                try output.appendNTimes(0, 64);
            }

            // Loudness values (v2)
            try output.writer().writeInt(i16, bext.loudness_value, .little);
            try output.writer().writeInt(i16, bext.loudness_range, .little);
            try output.writer().writeInt(i16, bext.max_true_peak_level, .little);
            try output.writer().writeInt(i16, bext.max_momentary_loudness, .little);
            try output.writer().writeInt(i16, bext.max_short_term_loudness, .little);

            // Reserved (180 bytes)
            try output.appendNTimes(0, 180);

            // Coding history (variable, 0 for minimum)
        }
    }
};
