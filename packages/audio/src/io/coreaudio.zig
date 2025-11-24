// Home Audio Library - CoreAudio Output (macOS)
// Real-time audio playback using Apple's CoreAudio framework

const std = @import("std");
const Allocator = std.mem.Allocator;

/// CoreAudio error codes
pub const CoreAudioError = error{
    DeviceNotFound,
    FormatNotSupported,
    BufferTooSmall,
    DeviceBusy,
    PermissionDenied,
    Unknown,
};

/// Audio device info
pub const AudioDeviceInfo = struct {
    id: u32,
    name: [256]u8,
    name_len: usize,
    channels: u32,
    sample_rate: f64,
    is_input: bool,
    is_output: bool,

    pub fn getName(self: *const AudioDeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Audio stream callback
pub const AudioCallback = *const fn (
    output_buffer: []f32,
    num_frames: u32,
    num_channels: u32,
    user_data: ?*anyopaque,
) void;

/// CoreAudio output stream (macOS)
/// Uses AudioUnit API for low-latency output
pub const CoreAudioOutput = struct {
    allocator: Allocator,

    // Stream state
    is_running: bool,
    sample_rate: u32,
    channels: u8,
    buffer_size: u32,

    // Callback
    callback: ?AudioCallback,
    user_data: ?*anyopaque,

    // Ring buffer for thread-safe audio data transfer
    ring_buffer: []f32,
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),

    const Self = @This();

    /// Default buffer size in frames
    pub const DEFAULT_BUFFER_SIZE = 512;
    pub const RING_BUFFER_FRAMES = 4096;

    /// Initialize CoreAudio output
    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        const ring_size = RING_BUFFER_FRAMES * @as(usize, channels);

        return Self{
            .allocator = allocator,
            .is_running = false,
            .sample_rate = sample_rate,
            .channels = channels,
            .buffer_size = DEFAULT_BUFFER_SIZE,
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

    /// Start audio playback
    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        // In a real implementation, this would:
        // 1. Create an AudioComponentInstance
        // 2. Set up the audio format (sample rate, channels, etc.)
        // 3. Set the render callback
        // 4. Initialize and start the audio unit

        // For now, we simulate the start
        self.is_running = true;

        // Reset ring buffer
        self.write_pos.store(0, .release);
        self.read_pos.store(0, .release);
    }

    /// Stop audio playback
    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        // In a real implementation, this would stop and dispose the AudioUnit
        self.is_running = false;
    }

    /// Write audio samples to the output buffer
    pub fn write(self: *Self, samples: []const f32) usize {
        const ring_size = self.ring_buffer.len;
        var write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);

        // Calculate available space
        const available = if (write_pos >= read_pos)
            ring_size - (write_pos - read_pos) - 1
        else
            read_pos - write_pos - 1;

        const to_write = @min(samples.len, available);
        if (to_write == 0) return 0;

        // Write to ring buffer
        for (0..to_write) |i| {
            self.ring_buffer[write_pos] = samples[i];
            write_pos = (write_pos + 1) % ring_size;
        }

        self.write_pos.store(write_pos, .release);
        return to_write;
    }

    /// Get available space in buffer (in samples)
    pub fn availableSpace(self: *Self) usize {
        const ring_size = self.ring_buffer.len;
        const write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);

        if (write_pos >= read_pos) {
            return ring_size - (write_pos - read_pos) - 1;
        } else {
            return read_pos - write_pos - 1;
        }
    }

    /// Get number of samples in buffer
    pub fn bufferedSamples(self: *Self) usize {
        const ring_size = self.ring_buffer.len;
        const write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);

        if (write_pos >= read_pos) {
            return write_pos - read_pos;
        } else {
            return ring_size - read_pos + write_pos;
        }
    }

    /// Simulate render callback (called by audio thread in real impl)
    pub fn renderCallback(self: *Self, output: []f32) void {
        const ring_size = self.ring_buffer.len;
        var read_pos = self.read_pos.load(.acquire);
        const write_pos = self.write_pos.load(.acquire);

        // Calculate available samples
        const available = if (write_pos >= read_pos)
            write_pos - read_pos
        else
            ring_size - read_pos + write_pos;

        const to_read = @min(output.len, available);

        // Read from ring buffer
        for (0..to_read) |i| {
            output[i] = self.ring_buffer[read_pos];
            read_pos = (read_pos + 1) % ring_size;
        }

        // Fill remaining with silence
        for (to_read..output.len) |i| {
            output[i] = 0;
        }

        self.read_pos.store(read_pos, .release);

        // Call user callback if set
        if (self.callback) |cb| {
            cb(output, @intCast(output.len / self.channels), self.channels, self.user_data);
        }
    }

    /// Set buffer size
    pub fn setBufferSize(self: *Self, frames: u32) void {
        self.buffer_size = frames;
    }

    /// Get latency in seconds
    pub fn getLatency(self: *Self) f64 {
        return @as(f64, @floatFromInt(self.buffer_size)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// List available audio devices
pub fn listDevices(allocator: Allocator) ![]AudioDeviceInfo {
    // In a real implementation, this would query AudioObjectGetPropertyData
    // For now, return a default device
    var devices = try allocator.alloc(AudioDeviceInfo, 1);

    devices[0] = AudioDeviceInfo{
        .id = 0,
        .name = undefined,
        .name_len = 15,
        .channels = 2,
        .sample_rate = 44100,
        .is_input = false,
        .is_output = true,
    };
    @memcpy(devices[0].name[0..15], "Default Output");

    return devices;
}

/// Get default output device
pub fn getDefaultOutputDevice() ?AudioDeviceInfo {
    var device = AudioDeviceInfo{
        .id = 0,
        .name = undefined,
        .name_len = 15,
        .channels = 2,
        .sample_rate = 44100,
        .is_input = false,
        .is_output = true,
    };
    @memcpy(device.name[0..15], "Default Output");
    return device;
}

// ============================================================================
// Tests
// ============================================================================

test "CoreAudioOutput init" {
    const allocator = std.testing.allocator;

    var output = try CoreAudioOutput.init(allocator, 44100, 2);
    defer output.deinit();

    try std.testing.expectEqual(@as(u32, 44100), output.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), output.channels);
}

test "CoreAudioOutput ring buffer" {
    const allocator = std.testing.allocator;

    var output = try CoreAudioOutput.init(allocator, 44100, 2);
    defer output.deinit();

    const samples = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const written = output.write(&samples);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqual(@as(usize, 4), output.bufferedSamples());
}

test "CoreAudioOutput latency" {
    const allocator = std.testing.allocator;

    var output = try CoreAudioOutput.init(allocator, 48000, 2);
    defer output.deinit();

    output.setBufferSize(256);
    const latency = output.getLatency();
    try std.testing.expectApproxEqAbs(@as(f64, 0.00533), latency, 0.0001);
}
