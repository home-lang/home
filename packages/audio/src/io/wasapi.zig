// Home Audio Library - WASAPI Output (Windows)
// Real-time audio playback using Windows Audio Session API

const std = @import("std");
const Allocator = std.mem.Allocator;

/// WASAPI error codes
pub const WasapiError = error{
    DeviceNotFound,
    FormatNotSupported,
    DeviceBusy,
    DeviceInvalidated,
    BufferTooSmall,
    ExclusiveModeFailed,
    Unknown,
};

/// WASAPI share mode
pub const ShareMode = enum {
    /// Shared mode - allows multiple applications
    shared,
    /// Exclusive mode - lowest latency, single app
    exclusive,
};

/// Audio endpoint role
pub const EndpointRole = enum {
    console, // Games, system notifications
    multimedia, // Music, movies
    communications, // Voice chat
};

/// Wave format
pub const WaveFormat = struct {
    format_tag: u16,
    channels: u16,
    samples_per_sec: u32,
    avg_bytes_per_sec: u32,
    block_align: u16,
    bits_per_sample: u16,

    pub const WAVE_FORMAT_PCM: u16 = 1;
    pub const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
    pub const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

    pub fn initFloat(sample_rate: u32, channels: u16) WaveFormat {
        const bits: u16 = 32;
        const block_align = channels * (bits / 8);
        return WaveFormat{
            .format_tag = WAVE_FORMAT_IEEE_FLOAT,
            .channels = channels,
            .samples_per_sec = sample_rate,
            .avg_bytes_per_sec = sample_rate * block_align,
            .block_align = block_align,
            .bits_per_sample = bits,
        };
    }

    pub fn initPcm(sample_rate: u32, channels: u16, bits: u16) WaveFormat {
        const block_align = channels * (bits / 8);
        return WaveFormat{
            .format_tag = WAVE_FORMAT_PCM,
            .channels = channels,
            .samples_per_sec = sample_rate,
            .avg_bytes_per_sec = sample_rate * block_align,
            .block_align = block_align,
            .bits_per_sample = bits,
        };
    }
};

/// Audio device info
pub const DeviceInfo = struct {
    id: [128]u8,
    id_len: usize,
    name: [256]u8,
    name_len: usize,
    is_default: bool,

    pub fn getId(self: *const DeviceInfo) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn getName(self: *const DeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Audio callback type
pub const AudioCallback = *const fn (
    buffer: []f32,
    frames: u32,
    channels: u32,
    user_data: ?*anyopaque,
) void;

/// WASAPI audio output
pub const WasapiOutput = struct {
    allocator: Allocator,

    // Configuration
    sample_rate: u32,
    channels: u8,
    share_mode: ShareMode,
    buffer_duration_ms: u32,

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

    pub const DEFAULT_BUFFER_DURATION_MS = 20;
    pub const MIN_BUFFER_DURATION_MS = 3; // Exclusive mode minimum
    pub const RING_BUFFER_FRAMES = 8192;

    /// Initialize WASAPI output
    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return initWithMode(allocator, sample_rate, channels, .shared);
    }

    /// Initialize with specific share mode
    pub fn initWithMode(
        allocator: Allocator,
        sample_rate: u32,
        channels: u8,
        share_mode: ShareMode,
    ) !Self {
        const ring_size = RING_BUFFER_FRAMES * @as(usize, channels);

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .share_mode = share_mode,
            .buffer_duration_ms = if (share_mode == .exclusive)
                MIN_BUFFER_DURATION_MS
            else
                DEFAULT_BUFFER_DURATION_MS,
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

    /// Set buffer duration
    pub fn setBufferDuration(self: *Self, duration_ms: u32) void {
        const min = if (self.share_mode == .exclusive) MIN_BUFFER_DURATION_MS else 10;
        self.buffer_duration_ms = @max(min, duration_ms);
    }

    /// Start audio playback
    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        // In a real implementation, this would:
        // 1. CoCreateInstance(CLSID_MMDeviceEnumerator)
        // 2. GetDefaultAudioEndpoint()
        // 3. Activate() IAudioClient
        // 4. Initialize() with share mode and buffer duration
        // 5. GetService() IAudioRenderClient
        // 6. Start() the audio client

        self.is_running = true;
        self.write_pos.store(0, .release);
        self.read_pos.store(0, .release);
    }

    /// Stop audio playback
    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        // IAudioClient::Stop()
        // Release interfaces

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

    /// Get buffer size in frames
    pub fn getBufferSize(self: *Self) u32 {
        return @intFromFloat(@as(f64, @floatFromInt(self.sample_rate)) *
            @as(f64, @floatFromInt(self.buffer_duration_ms)) / 1000.0);
    }

    /// Get latency in seconds
    pub fn getLatency(self: *Self) f64 {
        return @as(f64, @floatFromInt(self.buffer_duration_ms)) / 1000.0;
    }

    /// Check if exclusive mode is available
    pub fn isExclusiveModeAvailable(self: *Self) bool {
        _ = self;
        // Would check device capabilities
        return true;
    }
};

/// List available audio devices
pub fn listDevices(allocator: Allocator) ![]DeviceInfo {
    // In real implementation, would enumerate via IMMDeviceEnumerator
    var devices = try allocator.alloc(DeviceInfo, 1);

    devices[0] = DeviceInfo{
        .id = undefined,
        .id_len = 7,
        .name = undefined,
        .name_len = 15,
        .is_default = true,
    };
    @memcpy(devices[0].id[0..7], "default");
    @memcpy(devices[0].name[0..15], "Default Device");

    return devices;
}

/// Get default output device
pub fn getDefaultDevice(role: EndpointRole) ?DeviceInfo {
    _ = role;
    var device = DeviceInfo{
        .id = undefined,
        .id_len = 7,
        .name = undefined,
        .name_len = 15,
        .is_default = true,
    };
    @memcpy(device.id[0..7], "default");
    @memcpy(device.name[0..15], "Default Device");
    return device;
}

// ============================================================================
// Tests
// ============================================================================

test "WasapiOutput init" {
    const allocator = std.testing.allocator;

    var output = try WasapiOutput.init(allocator, 48000, 2);
    defer output.deinit();

    try std.testing.expectEqual(@as(u32, 48000), output.sample_rate);
    try std.testing.expectEqual(ShareMode.shared, output.share_mode);
}

test "WasapiOutput exclusive mode" {
    const allocator = std.testing.allocator;

    var output = try WasapiOutput.initWithMode(allocator, 96000, 2, .exclusive);
    defer output.deinit();

    try std.testing.expectEqual(ShareMode.exclusive, output.share_mode);
    try std.testing.expectEqual(@as(u32, 3), output.buffer_duration_ms);
}

test "WaveFormat init" {
    const float_fmt = WaveFormat.initFloat(48000, 2);
    try std.testing.expectEqual(@as(u16, WaveFormat.WAVE_FORMAT_IEEE_FLOAT), float_fmt.format_tag);
    try std.testing.expectEqual(@as(u16, 32), float_fmt.bits_per_sample);

    const pcm_fmt = WaveFormat.initPcm(44100, 2, 16);
    try std.testing.expectEqual(@as(u16, WaveFormat.WAVE_FORMAT_PCM), pcm_fmt.format_tag);
    try std.testing.expectEqual(@as(u32, 176400), pcm_fmt.avg_bytes_per_sec);
}
