// Home Audio Library - ALSA Output (Linux)
// Real-time audio playback using ALSA (Advanced Linux Sound Architecture)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// ALSA error codes
pub const AlsaError = error{
    DeviceNotFound,
    FormatNotSupported,
    BufferTooSmall,
    DeviceBusy,
    PermissionDenied,
    Underrun,
    Unknown,
};

/// ALSA PCM format
pub const PcmFormat = enum(u32) {
    s8 = 0,
    u8 = 1,
    s16_le = 2,
    s16_be = 3,
    u16_le = 4,
    u16_be = 5,
    s24_le = 6,
    s24_be = 7,
    u24_le = 8,
    u24_be = 9,
    s32_le = 10,
    s32_be = 11,
    u32_le = 12,
    u32_be = 13,
    float_le = 14,
    float_be = 15,
    float64_le = 16,
    float64_be = 17,

    pub fn bytesPerSample(self: PcmFormat) u8 {
        return switch (self) {
            .s8, .u8 => 1,
            .s16_le, .s16_be, .u16_le, .u16_be => 2,
            .s24_le, .s24_be, .u24_le, .u24_be => 3,
            .s32_le, .s32_be, .u32_le, .u32_be, .float_le, .float_be => 4,
            .float64_le, .float64_be => 8,
        };
    }
};

/// ALSA PCM access type
pub const PcmAccess = enum {
    mmap_interleaved,
    mmap_noninterleaved,
    rw_interleaved,
    rw_noninterleaved,
};

/// ALSA stream direction
pub const StreamDirection = enum {
    playback,
    capture,
};

/// Audio callback type
pub const AudioCallback = *const fn (
    buffer: []f32,
    frames: u32,
    channels: u32,
    user_data: ?*anyopaque,
) void;

/// ALSA PCM output stream
pub const AlsaOutput = struct {
    allocator: Allocator,

    // Device info
    device_name: []const u8,

    // Stream parameters
    sample_rate: u32,
    channels: u8,
    format: PcmFormat,
    buffer_size: u32, // in frames
    period_size: u32, // in frames

    // State
    is_running: bool,

    // Callback
    callback: ?AudioCallback,
    user_data: ?*anyopaque,

    // Ring buffer
    ring_buffer: []f32,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),

    const Self = @This();

    pub const DEFAULT_DEVICE = "default";
    pub const DEFAULT_BUFFER_SIZE = 2048;
    pub const DEFAULT_PERIOD_SIZE = 512;
    pub const RING_BUFFER_FRAMES = 8192;

    /// Initialize ALSA output
    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return initWithDevice(allocator, DEFAULT_DEVICE, sample_rate, channels);
    }

    /// Initialize with specific device
    pub fn initWithDevice(
        allocator: Allocator,
        device_name: []const u8,
        sample_rate: u32,
        channels: u8,
    ) !Self {
        const ring_size = RING_BUFFER_FRAMES * @as(usize, channels);

        return Self{
            .allocator = allocator,
            .device_name = device_name,
            .sample_rate = sample_rate,
            .channels = channels,
            .format = .float_le,
            .buffer_size = DEFAULT_BUFFER_SIZE,
            .period_size = DEFAULT_PERIOD_SIZE,
            .is_running = false,
            .callback = null,
            .user_data = null,
            .ring_buffer = try allocator.alloc(f32, ring_size),
            .write_pos = std.atomic.Value(usize).init(0),
            .read_pos = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_running) {
            self.stop();
        }
        self.allocator.free(self.ring_buffer);
    }

    /// Set audio callback
    pub fn setCallback(self: *Self, callback: AudioCallback, user_data: ?*anyopaque) void {
        self.callback = callback;
        self.user_data = user_data;
    }

    /// Configure hardware parameters
    pub fn configure(
        self: *Self,
        buffer_size: u32,
        period_size: u32,
        format: PcmFormat,
    ) void {
        self.buffer_size = buffer_size;
        self.period_size = period_size;
        self.format = format;
    }

    /// Start audio playback
    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        // In a real implementation, this would:
        // 1. Call snd_pcm_open()
        // 2. Configure hardware params (format, rate, channels, buffer size)
        // 3. Configure software params
        // 4. Call snd_pcm_prepare()
        // 5. Start the playback thread

        self.is_running = true;
        self.write_pos.store(0, .release);
        self.read_pos.store(0, .release);
    }

    /// Stop audio playback
    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        // In a real implementation:
        // snd_pcm_drop() or snd_pcm_drain()
        // snd_pcm_close()

        self.is_running = false;
    }

    /// Write audio samples
    pub fn write(self: *Self, samples: []const f32) usize {
        const ring_size = self.ring_buffer.len;
        var write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);

        const available = if (write_pos >= read_pos)
            ring_size - (write_pos - read_pos) - 1
        else
            read_pos - write_pos - 1;

        const to_write = @min(samples.len, available);
        if (to_write == 0) return 0;

        for (0..to_write) |i| {
            self.ring_buffer[write_pos] = samples[i];
            write_pos = (write_pos + 1) % ring_size;
        }

        self.write_pos.store(write_pos, .release);
        return to_write;
    }

    /// Get buffer underrun count
    pub fn getUnderruns(self: *Self) u32 {
        _ = self;
        // Would track actual underruns in real implementation
        return 0;
    }

    /// Recover from underrun
    pub fn recover(self: *Self) !void {
        // In real implementation: snd_pcm_recover() or snd_pcm_prepare()
        _ = self;
    }

    /// Get available space in frames
    pub fn availableFrames(self: *Self) usize {
        const ring_size = self.ring_buffer.len;
        const write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);

        const available_samples = if (write_pos >= read_pos)
            ring_size - (write_pos - read_pos) - 1
        else
            read_pos - write_pos - 1;

        return available_samples / self.channels;
    }

    /// Get latency in frames
    pub fn getLatency(self: *Self) u32 {
        return self.buffer_size;
    }

    /// Get latency in seconds
    pub fn getLatencySeconds(self: *Self) f64 {
        return @as(f64, @floatFromInt(self.buffer_size)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// List available ALSA devices
pub fn listDevices(allocator: Allocator) ![][]const u8 {
    // In real implementation, would use snd_device_name_hint()
    var devices = try allocator.alloc([]const u8, 3);
    devices[0] = "default";
    devices[1] = "hw:0,0";
    devices[2] = "plughw:0,0";
    return devices;
}

// ============================================================================
// Tests
// ============================================================================

test "AlsaOutput init" {
    const allocator = std.testing.allocator;

    var output = try AlsaOutput.init(allocator, 48000, 2);
    defer output.deinit();

    try std.testing.expectEqual(@as(u32, 48000), output.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), output.channels);
}

test "PcmFormat bytes per sample" {
    try std.testing.expectEqual(@as(u8, 2), PcmFormat.s16_le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 4), PcmFormat.float_le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 3), PcmFormat.s24_le.bytesPerSample());
}

test "AlsaOutput latency" {
    const allocator = std.testing.allocator;

    var output = try AlsaOutput.init(allocator, 48000, 2);
    defer output.deinit();

    output.buffer_size = 1024;
    const latency = output.getLatencySeconds();
    try std.testing.expectApproxEqAbs(@as(f64, 0.02133), latency, 0.001);
}
