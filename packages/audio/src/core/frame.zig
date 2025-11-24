// Home Audio Library - Audio Frame
// Audio frame representation for PCM audio data

const std = @import("std");
const types = @import("types.zig");

pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;

// ============================================================================
// Audio Frame
// ============================================================================

/// Represents a frame of audio samples
pub const AudioFrame = struct {
    /// Sample data - may be interleaved or planar
    data: []u8,

    /// Number of samples per channel
    num_samples: u64,

    /// Sample format
    format: SampleFormat,

    /// Number of audio channels
    channels: u8,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Channel layout
    channel_layout: ChannelLayout,

    /// Whether data is planar (separate buffer per channel)
    is_planar: bool,

    /// Presentation timestamp
    pts: Timestamp,

    /// Duration
    duration: Duration,

    /// Allocator used for memory management
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new audio frame with allocated memory
    pub fn init(
        allocator: std.mem.Allocator,
        num_samples: u64,
        format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) !Self {
        const bytes_per_sample = format.bytesPerSample();
        const total_bytes = num_samples * channels * bytes_per_sample;

        const data = try allocator.alloc(u8, @intCast(total_bytes));
        @memset(data, 0);

        return Self{
            .data = data,
            .num_samples = num_samples,
            .format = format,
            .channels = channels,
            .sample_rate = sample_rate,
            .channel_layout = ChannelLayout.fromChannelCount(channels),
            .is_planar = false,
            .pts = Timestamp.ZERO,
            .duration = Duration.fromSamples(num_samples, sample_rate),
            .allocator = allocator,
        };
    }

    /// Initialize from existing data (takes ownership)
    pub fn initFromData(
        allocator: std.mem.Allocator,
        data: []u8,
        num_samples: u64,
        format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) Self {
        return Self{
            .data = data,
            .num_samples = num_samples,
            .format = format,
            .channels = channels,
            .sample_rate = sample_rate,
            .channel_layout = ChannelLayout.fromChannelCount(channels),
            .is_planar = false,
            .pts = Timestamp.ZERO,
            .duration = Duration.fromSamples(num_samples, sample_rate),
            .allocator = allocator,
        };
    }

    /// Free the frame's resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Clone the frame
    pub fn clone(self: *const Self) !Self {
        const new_data = try self.allocator.alloc(u8, self.data.len);
        @memcpy(new_data, self.data);

        return Self{
            .data = new_data,
            .num_samples = self.num_samples,
            .format = self.format,
            .channels = self.channels,
            .sample_rate = self.sample_rate,
            .channel_layout = self.channel_layout,
            .is_planar = self.is_planar,
            .pts = self.pts,
            .duration = self.duration,
            .allocator = self.allocator,
        };
    }

    // ========================================================================
    // Sample Access
    // ========================================================================

    /// Get a sample value as f32 (normalized to -1.0 to 1.0)
    pub fn getSampleF32(self: *const Self, sample_idx: u64, channel: u8) f32 {
        if (sample_idx >= self.num_samples or channel >= self.channels) {
            return 0.0;
        }

        const bps = self.format.bytesPerSample();
        const idx = if (self.is_planar)
            channel * self.num_samples * bps + sample_idx * bps
        else
            (sample_idx * self.channels + channel) * bps;

        const offset: usize = @intCast(idx);

        return switch (self.format) {
            .u8 => {
                const val = self.data[offset];
                return (@as(f32, @floatFromInt(val)) - 128.0) / 128.0;
            },
            .s16le => {
                const val = std.mem.readInt(i16, self.data[offset..][0..2], .little);
                return @as(f32, @floatFromInt(val)) / 32768.0;
            },
            .s16be => {
                const val = std.mem.readInt(i16, self.data[offset..][0..2], .big);
                return @as(f32, @floatFromInt(val)) / 32768.0;
            },
            .s24le => {
                var bytes: [4]u8 = .{ self.data[offset], self.data[offset + 1], self.data[offset + 2], 0 };
                if (bytes[2] & 0x80 != 0) bytes[3] = 0xFF; // Sign extend
                const val = std.mem.readInt(i32, &bytes, .little);
                return @as(f32, @floatFromInt(val)) / 8388608.0;
            },
            .s24be => {
                var bytes: [4]u8 = .{ 0, self.data[offset], self.data[offset + 1], self.data[offset + 2] };
                if (bytes[1] & 0x80 != 0) bytes[0] = 0xFF;
                const val = std.mem.readInt(i32, &bytes, .big);
                return @as(f32, @floatFromInt(val)) / 8388608.0;
            },
            .s32le => {
                const val = std.mem.readInt(i32, self.data[offset..][0..4], .little);
                return @as(f32, @floatFromInt(val)) / 2147483648.0;
            },
            .s32be => {
                const val = std.mem.readInt(i32, self.data[offset..][0..4], .big);
                return @as(f32, @floatFromInt(val)) / 2147483648.0;
            },
            .f32le => {
                const bytes = self.data[offset..][0..4];
                return @bitCast(std.mem.readInt(u32, bytes, .little));
            },
            .f32be => {
                const bytes = self.data[offset..][0..4];
                return @bitCast(std.mem.readInt(u32, bytes, .big));
            },
            .f64le => {
                const bytes = self.data[offset..][0..8];
                const val: f64 = @bitCast(std.mem.readInt(u64, bytes, .little));
                return @floatCast(val);
            },
            .f64be => {
                const bytes = self.data[offset..][0..8];
                const val: f64 = @bitCast(std.mem.readInt(u64, bytes, .big));
                return @floatCast(val);
            },
            else => 0.0,
        };
    }

    /// Set a sample value from f32 (normalized -1.0 to 1.0)
    pub fn setSampleF32(self: *Self, sample_idx: u64, channel: u8, value: f32) void {
        if (sample_idx >= self.num_samples or channel >= self.channels) {
            return;
        }

        const bps = self.format.bytesPerSample();
        const idx = if (self.is_planar)
            channel * self.num_samples * bps + sample_idx * bps
        else
            (sample_idx * self.channels + channel) * bps;

        const offset: usize = @intCast(idx);
        const clamped = std.math.clamp(value, -1.0, 1.0);

        switch (self.format) {
            .u8 => {
                const val: u8 = @intFromFloat((clamped + 1.0) * 127.5);
                self.data[offset] = val;
            },
            .s16le => {
                const val: i16 = @intFromFloat(clamped * 32767.0);
                std.mem.writeInt(i16, self.data[offset..][0..2], val, .little);
            },
            .s16be => {
                const val: i16 = @intFromFloat(clamped * 32767.0);
                std.mem.writeInt(i16, self.data[offset..][0..2], val, .big);
            },
            .s32le => {
                const val: i32 = @intFromFloat(clamped * 2147483647.0);
                std.mem.writeInt(i32, self.data[offset..][0..4], val, .little);
            },
            .s32be => {
                const val: i32 = @intFromFloat(clamped * 2147483647.0);
                std.mem.writeInt(i32, self.data[offset..][0..4], val, .big);
            },
            .f32le => {
                const bits: u32 = @bitCast(clamped);
                std.mem.writeInt(u32, self.data[offset..][0..4], bits, .little);
            },
            .f32be => {
                const bits: u32 = @bitCast(clamped);
                std.mem.writeInt(u32, self.data[offset..][0..4], bits, .big);
            },
            else => {},
        }
    }

    // ========================================================================
    // Channel Operations
    // ========================================================================

    /// Get data for a specific channel (only valid for planar audio)
    pub fn getChannelData(self: *const Self, channel: u8) ?[]u8 {
        if (!self.is_planar or channel >= self.channels) {
            return null;
        }

        const samples_per_channel: usize = @intCast(self.num_samples);
        const bytes_per_channel = samples_per_channel * self.format.bytesPerSample();
        const start = channel * bytes_per_channel;
        const end = start + bytes_per_channel;

        return self.data[start..end];
    }

    /// Convert interleaved to planar format
    pub fn toPlanar(self: *Self) !void {
        if (self.is_planar) return;

        const bps = self.format.bytesPerSample();
        const samples: usize = @intCast(self.num_samples);
        const new_data = try self.allocator.alloc(u8, self.data.len);

        for (0..samples) |s| {
            for (0..self.channels) |c| {
                const src_offset = (s * self.channels + c) * bps;
                const dst_offset = (c * samples + s) * bps;
                @memcpy(new_data[dst_offset..][0..bps], self.data[src_offset..][0..bps]);
            }
        }

        self.allocator.free(self.data);
        self.data = new_data;
        self.is_planar = true;
    }

    /// Convert planar to interleaved format
    pub fn toInterleaved(self: *Self) !void {
        if (!self.is_planar) return;

        const bps = self.format.bytesPerSample();
        const samples: usize = @intCast(self.num_samples);
        const new_data = try self.allocator.alloc(u8, self.data.len);

        for (0..samples) |s| {
            for (0..self.channels) |c| {
                const src_offset = (c * samples + s) * bps;
                const dst_offset = (s * self.channels + c) * bps;
                @memcpy(new_data[dst_offset..][0..bps], self.data[src_offset..][0..bps]);
            }
        }

        self.allocator.free(self.data);
        self.data = new_data;
        self.is_planar = false;
    }

    // ========================================================================
    // Frame Information
    // ========================================================================

    /// Get the size of the frame data in bytes
    pub fn byteSize(self: *const Self) usize {
        return self.data.len;
    }

    /// Get duration in seconds
    pub fn durationSeconds(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.num_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Calculate RMS (Root Mean Square) level for a channel
    pub fn getRmsLevel(self: *const Self, channel: u8) f32 {
        if (channel >= self.channels or self.num_samples == 0) {
            return 0.0;
        }

        var sum: f64 = 0.0;
        for (0..@intCast(self.num_samples)) |i| {
            const sample = self.getSampleF32(@intCast(i), channel);
            sum += @as(f64, sample) * @as(f64, sample);
        }

        return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(self.num_samples))));
    }

    /// Calculate peak level for a channel
    pub fn getPeakLevel(self: *const Self, channel: u8) f32 {
        if (channel >= self.channels or self.num_samples == 0) {
            return 0.0;
        }

        var peak: f32 = 0.0;
        for (0..@intCast(self.num_samples)) |i| {
            const sample = @abs(self.getSampleF32(@intCast(i), channel));
            if (sample > peak) peak = sample;
        }

        return peak;
    }

    /// Mix down to mono
    pub fn mixToMono(self: *Self) !void {
        if (self.channels == 1) return;

        const bps = self.format.bytesPerSample();
        const samples: usize = @intCast(self.num_samples);
        const new_data = try self.allocator.alloc(u8, samples * bps);

        for (0..samples) |s| {
            var sum: f32 = 0.0;
            for (0..self.channels) |c| {
                sum += self.getSampleF32(@intCast(s), @intCast(c));
            }
            const avg = sum / @as(f32, @floatFromInt(self.channels));

            // Write to temp frame
            var temp = Self{
                .data = new_data,
                .num_samples = self.num_samples,
                .format = self.format,
                .channels = 1,
                .sample_rate = self.sample_rate,
                .channel_layout = .mono,
                .is_planar = false,
                .pts = self.pts,
                .duration = self.duration,
                .allocator = self.allocator,
            };
            temp.setSampleF32(@intCast(s), 0, avg);
        }

        self.allocator.free(self.data);
        self.data = new_data;
        self.channels = 1;
        self.channel_layout = .mono;
        self.is_planar = false;
    }
};

// ============================================================================
// Audio Buffer
// ============================================================================

/// Ring buffer for streaming audio
pub const AudioBuffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,
    capacity: usize,
    format: SampleFormat,
    channels: u8,
    sample_rate: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        capacity_samples: usize,
        format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) !Self {
        const byte_capacity = capacity_samples * channels * format.bytesPerSample();
        const data = try allocator.alloc(u8, byte_capacity);
        @memset(data, 0);

        return Self{
            .data = data,
            .read_pos = 0,
            .write_pos = 0,
            .capacity = byte_capacity,
            .format = format,
            .channels = channels,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Get number of bytes available to read
    pub fn available(self: *const Self) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.capacity - self.read_pos + self.write_pos;
        }
    }

    /// Get number of bytes free for writing
    pub fn free(self: *const Self) usize {
        return self.capacity - self.available() - 1;
    }

    /// Write data to buffer
    pub fn write(self: *Self, data: []const u8) usize {
        const to_write = @min(data.len, self.free());
        if (to_write == 0) return 0;

        const first_part = @min(to_write, self.capacity - self.write_pos);
        @memcpy(self.data[self.write_pos..][0..first_part], data[0..first_part]);

        if (to_write > first_part) {
            const second_part = to_write - first_part;
            @memcpy(self.data[0..second_part], data[first_part..][0..second_part]);
        }

        self.write_pos = (self.write_pos + to_write) % self.capacity;
        return to_write;
    }

    /// Read data from buffer
    pub fn read(self: *Self, dest: []u8) usize {
        const to_read = @min(dest.len, self.available());
        if (to_read == 0) return 0;

        const first_part = @min(to_read, self.capacity - self.read_pos);
        @memcpy(dest[0..first_part], self.data[self.read_pos..][0..first_part]);

        if (to_read > first_part) {
            const second_part = to_read - first_part;
            @memcpy(dest[first_part..][0..second_part], self.data[0..second_part]);
        }

        self.read_pos = (self.read_pos + to_read) % self.capacity;
        return to_read;
    }

    /// Clear the buffer
    pub fn clear(self: *Self) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AudioFrame creation" {
    var frame_obj = try AudioFrame.init(std.testing.allocator, 1024, .s16le, 2, 44100);
    defer frame_obj.deinit();

    try std.testing.expectEqual(@as(u64, 1024), frame_obj.num_samples);
    try std.testing.expectEqual(@as(u8, 2), frame_obj.channels);
    try std.testing.expectEqual(@as(u32, 44100), frame_obj.sample_rate);
}

test "AudioFrame sample access" {
    var frame_obj = try AudioFrame.init(std.testing.allocator, 100, .s16le, 2, 44100);
    defer frame_obj.deinit();

    frame_obj.setSampleF32(0, 0, 0.5);
    const sample = frame_obj.getSampleF32(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sample, 0.001);
}

test "AudioBuffer operations" {
    var buffer = try AudioBuffer.init(std.testing.allocator, 1024, .s16le, 2, 44100);
    defer buffer.deinit();

    const test_data = [_]u8{ 1, 2, 3, 4 };
    const written = buffer.write(&test_data);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqual(@as(usize, 4), buffer.available());

    var read_data: [4]u8 = undefined;
    const bytes_read = buffer.read(&read_data);
    try std.testing.expectEqual(@as(usize, 4), bytes_read);
    try std.testing.expectEqualSlices(u8, &test_data, &read_data);
}
