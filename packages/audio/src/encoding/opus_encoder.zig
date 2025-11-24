// Home Audio Library - Opus Encoder
// Pure Zig Opus encoder implementation
// Simplified encoder suitable for basic Opus output

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Opus application mode
pub const OpusApplication = enum {
    voip, // Optimized for voice
    audio, // Optimized for music
    low_delay, // Restricted low-delay mode
};

/// Opus bandwidth
pub const OpusBandwidth = enum(u8) {
    narrowband = 0, // 4 kHz
    mediumband = 1, // 6 kHz
    wideband = 2, // 8 kHz
    superwideband = 3, // 12 kHz
    fullband = 4, // 20 kHz
};

/// Opus frame size
pub const OpusFrameSize = enum {
    ms_2_5,
    ms_5,
    ms_10,
    ms_20,
    ms_40,
    ms_60,

    pub fn samples(self: OpusFrameSize, sample_rate: u32) usize {
        const ms: f64 = switch (self) {
            .ms_2_5 => 2.5,
            .ms_5 => 5.0,
            .ms_10 => 10.0,
            .ms_20 => 20.0,
            .ms_40 => 40.0,
            .ms_60 => 60.0,
        };
        return @intFromFloat(ms * @as(f64, @floatFromInt(sample_rate)) / 1000.0);
    }
};

/// Opus quality preset
pub const OpusQuality = enum {
    voice_low, // ~16 kbps
    voice_medium, // ~24 kbps
    voice_high, // ~32 kbps
    music_low, // ~64 kbps
    music_medium, // ~96 kbps
    music_high, // ~128 kbps
    music_best, // ~192 kbps

    pub fn getBitrate(self: OpusQuality) u32 {
        return switch (self) {
            .voice_low => 16,
            .voice_medium => 24,
            .voice_high => 32,
            .music_low => 64,
            .music_medium => 96,
            .music_high => 128,
            .music_best => 192,
        };
    }

    pub fn getApplication(self: OpusQuality) OpusApplication {
        return switch (self) {
            .voice_low, .voice_medium, .voice_high => .voip,
            else => .audio,
        };
    }
};

/// Opus packet TOC (Table of Contents) byte
pub const OpusToc = struct {
    config: u5, // Configuration number
    stereo: bool,
    frame_count_code: u2, // 0=1, 1=2, 2=2 (equal), 3=arbitrary

    pub fn encode(self: OpusToc) u8 {
        var toc: u8 = @as(u8, self.config) << 3;
        toc |= if (self.stereo) 4 else 0;
        toc |= self.frame_count_code;
        return toc;
    }

    /// Get config from bandwidth and frame size
    pub fn getConfig(bandwidth: OpusBandwidth, frame_size: OpusFrameSize, is_silk: bool) u5 {
        const band_base: u5 = @truncate(@as(u8, @intFromEnum(bandwidth)) * 4);
        const size_offset: u5 = switch (frame_size) {
            .ms_2_5 => 0,
            .ms_5 => 1,
            .ms_10 => 2,
            .ms_20 => 3,
            .ms_40 => 2, // Uses 20ms config
            .ms_60 => 2, // Uses 20ms config
        };

        if (is_silk) {
            return band_base + size_offset;
        } else {
            // CELT mode
            return @as(u5, 16) + @min(@as(u5, 3), size_offset);
        }
    }
};

/// Opus encoder
pub const OpusEncoder = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    bitrate: u32,
    application: OpusApplication,
    bandwidth: OpusBandwidth,
    frame_size: OpusFrameSize,

    // Output buffer
    output: std.ArrayList(u8),

    // SILK/CELT state
    prev_samples: []f32,
    lpc_coeffs: []f32,

    // Frame counter
    frame_count: u32,

    // Internal state
    use_silk: bool,
    use_celt: bool,

    const Self = @This();

    pub const MAX_FRAME_SIZE = 5760; // 120ms at 48kHz
    pub const LPC_ORDER = 16;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8, quality: OpusQuality) !Self {
        // Opus requires 48000, 24000, 16000, 12000, or 8000 Hz
        const valid_rate = switch (sample_rate) {
            8000, 12000, 16000, 24000, 48000 => sample_rate,
            44100 => 48000, // Resample required
            else => 48000,
        };

        return Self{
            .allocator = allocator,
            .sample_rate = valid_rate,
            .channels = channels,
            .bitrate = quality.getBitrate(),
            .application = quality.getApplication(),
            .bandwidth = if (quality.getApplication() == .voip) .wideband else .fullband,
            .frame_size = .ms_20,
            .output = .{},
            .prev_samples = try allocator.alloc(f32, MAX_FRAME_SIZE * @as(usize, channels)),
            .lpc_coeffs = try allocator.alloc(f32, LPC_ORDER),
            .frame_count = 0,
            .use_silk = quality.getApplication() == .voip,
            .use_celt = quality.getApplication() != .voip,
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.allocator.free(self.prev_samples);
        self.allocator.free(self.lpc_coeffs);
    }

    /// Set bitrate in kbps
    pub fn setBitrate(self: *Self, kbps: u32) void {
        self.bitrate = std.math.clamp(kbps, 6, 510);
    }

    /// Set frame size
    pub fn setFrameSize(self: *Self, size: OpusFrameSize) void {
        self.frame_size = size;
    }

    /// Set bandwidth
    pub fn setBandwidth(self: *Self, bandwidth: OpusBandwidth) void {
        self.bandwidth = bandwidth;
    }

    /// Encode PCM samples to Opus packets
    pub fn encode(self: *Self, samples: []const f32) !void {
        const frame_samples = self.frame_size.samples(self.sample_rate) * self.channels;
        var pos: usize = 0;

        while (pos + frame_samples <= samples.len) {
            try self.encodeFrame(samples[pos .. pos + frame_samples]);
            pos += frame_samples;
        }
    }

    /// Encode a single Opus frame
    fn encodeFrame(self: *Self, samples: []const f32) !void {
        // Create TOC byte
        const toc = OpusToc{
            .config = OpusToc.getConfig(self.bandwidth, self.frame_size, self.use_silk),
            .stereo = self.channels == 2,
            .frame_count_code = 0, // Single frame
        };

        try self.output.append(self.allocator, toc.encode());

        // Encode frame data
        if (self.use_silk) {
            try self.encodeSilk(samples);
        } else {
            try self.encodeCelt(samples);
        }

        self.frame_count += 1;
    }

    /// Simplified SILK encoding (linear prediction based)
    fn encodeSilk(self: *Self, samples: []const f32) !void {
        // SILK uses linear prediction for voice coding
        // Simplified implementation: store LPC coefficients + residual

        const frame_samples = samples.len / self.channels;

        // Mix to mono
        var mono: [MAX_FRAME_SIZE]f32 = undefined;
        for (0..frame_samples) |i| {
            if (self.channels == 2) {
                mono[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5;
            } else {
                mono[i] = samples[i];
            }
        }

        // Compute simple LPC coefficients using autocorrelation
        var autocorr: [LPC_ORDER + 1]f64 = undefined;
        for (0..LPC_ORDER + 1) |lag| {
            var sum: f64 = 0;
            for (0..frame_samples - lag) |i| {
                sum += @as(f64, mono[i]) * @as(f64, mono[i + lag]);
            }
            autocorr[lag] = sum;
        }

        // Levinson-Durbin for LPC (simplified)
        if (autocorr[0] > 0.0001) {
            for (0..LPC_ORDER) |i| {
                self.lpc_coeffs[i] = @floatCast(autocorr[i + 1] / autocorr[0]);
            }
        } else {
            @memset(self.lpc_coeffs, 0);
        }

        // Calculate target bytes based on bitrate
        const target_bytes = @max(10, self.bitrate * frame_samples / self.sample_rate / 8);

        // Write LPC coefficients (quantized)
        for (0..@min(LPC_ORDER, target_bytes)) |i| {
            const coeff = self.lpc_coeffs[i];
            const quantized: i8 = @intFromFloat(std.math.clamp(coeff * 64.0, -128, 127));
            try self.output.append(self.allocator, @bitCast(quantized));
        }

        // Write residual energy (simplified)
        const remaining_bytes = target_bytes - @min(LPC_ORDER, target_bytes);
        for (0..remaining_bytes) |i| {
            const sample_idx = i * frame_samples / remaining_bytes;
            if (sample_idx < frame_samples) {
                const quantized: i8 = @intFromFloat(std.math.clamp(mono[sample_idx] * 127.0, -128, 127));
                try self.output.append(self.allocator, @bitCast(quantized));
            }
        }
    }

    /// Simplified CELT encoding (MDCT based)
    fn encodeCelt(self: *Self, samples: []const f32) !void {
        // CELT uses MDCT for audio coding
        // Simplified implementation: store quantized spectral data

        const frame_samples = samples.len / self.channels;

        // Mix to mono
        var mono: [MAX_FRAME_SIZE]f32 = undefined;
        for (0..frame_samples) |i| {
            if (self.channels == 2) {
                mono[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5;
            } else {
                mono[i] = samples[i];
            }
        }

        // Apply window
        for (0..frame_samples) |i| {
            const w = @sin(math.pi * (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(frame_samples)));
            mono[i] *= w;
        }

        // Calculate target bytes
        const target_bytes = @max(20, self.bitrate * frame_samples / self.sample_rate / 8);

        // Simple spectral representation (sub-bands)
        const num_bands = @min(21, target_bytes);
        const samples_per_band = frame_samples / num_bands;

        for (0..num_bands) |band| {
            var energy: f32 = 0;
            const start = band * samples_per_band;
            const end = @min(start + samples_per_band, frame_samples);

            for (start..end) |i| {
                energy += mono[i] * mono[i];
            }
            energy = @sqrt(energy / @as(f32, @floatFromInt(end - start)));

            // Quantize and store
            const quantized: u8 = @intFromFloat(std.math.clamp(energy * 255.0, 0, 255));
            try self.output.append(self.allocator, quantized);
        }

        // Pad remaining bytes
        for (num_bands..target_bytes) |_| {
            try self.output.append(self.allocator, 0);
        }
    }

    /// Finalize and return encoded data
    pub fn finalize(self: *Self) ![]u8 {
        return try self.allocator.dupe(u8, self.output.items);
    }

    /// Get encoded data
    pub fn getData(self: *Self) []const u8 {
        return self.output.items;
    }

    /// Reset encoder
    pub fn reset(self: *Self) void {
        self.output.clearRetainingCapacity();
        @memset(self.prev_samples, 0);
        @memset(self.lpc_coeffs, 0);
        self.frame_count = 0;
    }

    /// Get frame count
    pub fn getFrameCount(self: *Self) u32 {
        return self.frame_count;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *Self) f64 {
        const samples_per_frame = self.frame_size.samples(self.sample_rate);
        return @as(f64, @floatFromInt(self.frame_count * samples_per_frame)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Ogg Opus writer for creating .opus files
pub const OggOpusWriter = struct {
    allocator: Allocator,
    encoder: OpusEncoder,
    serial_number: u32,
    page_sequence: u32,
    granule_position: u64,
    header_written: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8, quality: OpusQuality) !Self {
        return Self{
            .allocator = allocator,
            .encoder = try OpusEncoder.init(allocator, sample_rate, channels, quality),
            .serial_number = @truncate(@intFromPtr(allocator.ptr)),
            .page_sequence = 0,
            .granule_position = 0,
            .header_written = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.encoder.deinit();
    }

    /// Write to Ogg container
    pub fn write(self: *Self, samples: []const f32) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write Ogg headers on first call
        if (!self.header_written) {
            try self.writeOpusHead(&output);
            try self.writeOpusTags(&output);
            self.header_written = true;
        }

        // Encode audio
        try self.encoder.encode(samples);

        // Get encoded data and wrap in Ogg pages
        const opus_data = self.encoder.getData();
        try self.writeOggPage(&output, opus_data, false);

        // Update granule position
        self.granule_position += samples.len / self.encoder.channels;

        return output.toOwnedSlice(self.allocator);
    }

    fn writeOpusHead(self: *Self, output: *std.ArrayList(u8)) !void {
        // OpusHead packet
        var head: [19]u8 = undefined;
        @memcpy(head[0..8], "OpusHead");
        head[8] = 1; // Version
        head[9] = self.encoder.channels;
        head[10] = 0; // Pre-skip low
        head[11] = 0; // Pre-skip high
        // Sample rate (little-endian)
        const rate = self.encoder.sample_rate;
        head[12] = @truncate(rate);
        head[13] = @truncate(rate >> 8);
        head[14] = @truncate(rate >> 16);
        head[15] = @truncate(rate >> 24);
        head[16] = 0; // Gain low
        head[17] = 0; // Gain high
        head[18] = 0; // Channel mapping family

        try self.writeOggPage(output, &head, false);
    }

    fn writeOpusTags(self: *Self, output: *std.ArrayList(u8)) !void {
        // OpusTags packet
        const vendor = "Home Audio Lib";
        const tags_size = 8 + 4 + vendor.len + 4;
        var tags = try self.allocator.alloc(u8, tags_size);
        defer self.allocator.free(tags);

        @memcpy(tags[0..8], "OpusTags");
        // Vendor string length (little-endian)
        tags[8] = @truncate(vendor.len);
        tags[9] = 0;
        tags[10] = 0;
        tags[11] = 0;
        // Vendor string
        @memcpy(tags[12 .. 12 + vendor.len], vendor);
        // User comment list length
        tags[12 + vendor.len] = 0;
        tags[13 + vendor.len] = 0;
        tags[14 + vendor.len] = 0;
        tags[15 + vendor.len] = 0;

        try self.writeOggPage(output, tags, false);
    }

    fn writeOggPage(self: *Self, output: *std.ArrayList(u8), data: []const u8, is_eos: bool) !void {
        // Ogg page header
        try output.appendSlice(self.allocator, "OggS"); // Capture pattern
        try output.append(self.allocator, 0); // Version
        try output.append(self.allocator, if (is_eos) 4 else if (self.page_sequence == 0) 2 else 0); // Flags

        // Granule position (8 bytes, little-endian)
        var gp = self.granule_position;
        for (0..8) |_| {
            try output.append(self.allocator, @truncate(gp));
            gp >>= 8;
        }

        // Serial number (4 bytes)
        var sn = self.serial_number;
        for (0..4) |_| {
            try output.append(self.allocator, @truncate(sn));
            sn >>= 8;
        }

        // Page sequence number (4 bytes)
        var ps = self.page_sequence;
        for (0..4) |_| {
            try output.append(self.allocator, @truncate(ps));
            ps >>= 8;
        }
        self.page_sequence += 1;

        // CRC placeholder (4 bytes)
        const crc_pos = output.items.len;
        try output.appendNTimes(self.allocator, 0, 4);

        // Segment count and table
        const num_segments = (data.len + 254) / 255;
        try output.append(self.allocator, @intCast(num_segments));

        var remaining = data.len;
        for (0..num_segments) |_| {
            const seg_size: u8 = @intCast(@min(remaining, 255));
            try output.append(self.allocator, seg_size);
            remaining -= seg_size;
        }

        // Page data
        try output.appendSlice(self.allocator, data);

        // Calculate CRC32 (simplified - zeros for now)
        // Real implementation would calculate actual CRC
        output.items[crc_pos] = 0;
        output.items[crc_pos + 1] = 0;
        output.items[crc_pos + 2] = 0;
        output.items[crc_pos + 3] = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OpusEncoder init" {
    const allocator = std.testing.allocator;

    var encoder = try OpusEncoder.init(allocator, 48000, 2, .music_medium);
    defer encoder.deinit();

    try std.testing.expectEqual(@as(u32, 96), encoder.bitrate);
}

test "OpusEncoder encode" {
    const allocator = std.testing.allocator;

    var encoder = try OpusEncoder.init(allocator, 48000, 1, .music_medium);
    defer encoder.deinit();

    const frame_size = OpusFrameSize.ms_20.samples(48000);
    var samples: [960]f32 = undefined; // 20ms at 48kHz
    for (0..frame_size) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        samples[i] = @sin(t * 440 * 2 * math.pi);
    }

    try encoder.encode(&samples);
    try std.testing.expect(encoder.getFrameCount() > 0);
}

test "OpusToc encode" {
    const toc = OpusToc{
        .config = 15, // Fullband, 20ms, SILK
        .stereo = true,
        .frame_count_code = 0,
    };

    const byte = toc.encode();
    try std.testing.expect(byte != 0);
}

test "OggOpusWriter init" {
    const allocator = std.testing.allocator;

    var writer = try OggOpusWriter.init(allocator, 48000, 2, .music_medium);
    defer writer.deinit();
}
