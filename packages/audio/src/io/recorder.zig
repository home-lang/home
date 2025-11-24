// Home Audio Library - Audio Input/Recording
// Cross-platform audio input capture

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Recording state
pub const RecordingState = enum {
    stopped,
    recording,
    paused,
};

/// Input device info
pub const InputDeviceInfo = struct {
    id: u32,
    name: [256]u8,
    name_len: usize,
    channels: u8,
    sample_rate: u32,
    is_default: bool,

    pub fn getName(self: *const InputDeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Audio input callback
pub const InputCallback = *const fn (
    input_buffer: []const f32,
    num_frames: u32,
    num_channels: u32,
    user_data: ?*anyopaque,
) void;

/// Audio recorder
pub const AudioRecorder = struct {
    allocator: Allocator,

    // Configuration
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,

    // State
    state: RecordingState,

    // Callback
    callback: ?InputCallback,
    user_data: ?*anyopaque,

    // Recording buffer
    buffer: std.ArrayList(f32),
    max_duration_samples: ?usize,

    // Stats
    samples_recorded: usize,
    peak_level: f32,
    rms_level: f32,
    clip_count: u32,

    const Self = @This();

    /// Initialize recorder
    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits_per_sample = 32,
            .state = .stopped,
            .callback = null,
            .user_data = null,
            .buffer = .{},
            .max_duration_samples = null,
            .samples_recorded = 0,
            .peak_level = 0,
            .rms_level = 0,
            .clip_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.state != .stopped) {
            self.stop();
        }
        self.buffer.deinit(self.allocator);
    }

    /// Set input callback
    pub fn setCallback(self: *Self, callback: InputCallback, user_data: ?*anyopaque) void {
        self.callback = callback;
        self.user_data = user_data;
    }

    /// Set maximum recording duration in seconds
    pub fn setMaxDuration(self: *Self, seconds: f32) void {
        self.max_duration_samples = @intFromFloat(seconds * @as(f32, @floatFromInt(self.sample_rate)) * @as(f32, @floatFromInt(self.channels)));
    }

    /// Start recording
    pub fn start(self: *Self) !void {
        if (self.state == .recording) return;

        // In a real implementation, this would:
        // 1. Open the input device
        // 2. Configure input format
        // 3. Start capturing

        self.state = .recording;
        self.samples_recorded = 0;
        self.peak_level = 0;
        self.rms_level = 0;
        self.clip_count = 0;
        self.buffer.clearRetainingCapacity();
    }

    /// Stop recording
    pub fn stop(self: *Self) void {
        if (self.state == .stopped) return;
        self.state = .stopped;
    }

    /// Pause recording
    pub fn pause(self: *Self) void {
        if (self.state != .recording) return;
        self.state = .paused;
    }

    /// Resume recording
    pub fn resumeRecording(self: *Self) void {
        if (self.state != .paused) return;
        self.state = .recording;
    }

    /// Process input samples (called from audio input callback)
    pub fn processInput(self: *Self, samples: []const f32) !void {
        if (self.state != .recording) return;

        // Check max duration
        if (self.max_duration_samples) |max| {
            if (self.samples_recorded >= max) {
                self.stop();
                return;
            }
        }

        // Update levels
        var sum_squared: f32 = 0;
        for (samples) |s| {
            const abs_s = @abs(s);
            if (abs_s > self.peak_level) {
                self.peak_level = abs_s;
            }
            if (abs_s >= 1.0) {
                self.clip_count += 1;
            }
            sum_squared += s * s;
        }
        self.rms_level = @sqrt(sum_squared / @as(f32, @floatFromInt(samples.len)));

        // Store samples
        try self.buffer.appendSlice(self.allocator, samples);
        self.samples_recorded += samples.len;

        // Call user callback
        if (self.callback) |cb| {
            cb(samples, @intCast(samples.len / self.channels), self.channels, self.user_data);
        }
    }

    /// Get recorded audio
    pub fn getRecording(self: *Self) []const f32 {
        return self.buffer.items;
    }

    /// Get recording duration in seconds
    pub fn getDuration(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.samples_recorded)) /
            @as(f32, @floatFromInt(self.sample_rate * self.channels));
    }

    /// Get peak level in dB
    pub fn getPeakDb(self: *Self) f32 {
        if (self.peak_level <= 0) return -100;
        return 20.0 * @log10(self.peak_level);
    }

    /// Get RMS level in dB
    pub fn getRmsDb(self: *Self) f32 {
        if (self.rms_level <= 0) return -100;
        return 20.0 * @log10(self.rms_level);
    }

    /// Check if clipping occurred
    pub fn hasClipped(self: *Self) bool {
        return self.clip_count > 0;
    }

    /// Clear recording buffer
    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.samples_recorded = 0;
        self.peak_level = 0;
        self.rms_level = 0;
        self.clip_count = 0;
    }
};

/// Voice activity detector for recording
pub const VoiceActivityDetector = struct {
    threshold_db: f32,
    hold_time_ms: u32,
    sample_rate: u32,

    // State
    samples_since_voice: u32,
    is_voice_active: bool,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        return Self{
            .threshold_db = -40,
            .hold_time_ms = 500,
            .sample_rate = sample_rate,
            .samples_since_voice = 0,
            .is_voice_active = false,
        };
    }

    /// Process audio and detect voice
    pub fn process(self: *Self, samples: []const f32) bool {
        // Calculate RMS
        var sum_squared: f32 = 0;
        for (samples) |s| {
            sum_squared += s * s;
        }
        const rms = @sqrt(sum_squared / @as(f32, @floatFromInt(samples.len)));
        const level_db = if (rms > 0) 20.0 * @log10(rms) else -100;

        // Check against threshold
        if (level_db > self.threshold_db) {
            self.is_voice_active = true;
            self.samples_since_voice = 0;
        } else {
            self.samples_since_voice += @intCast(samples.len);
            const hold_samples = self.hold_time_ms * self.sample_rate / 1000;
            if (self.samples_since_voice > hold_samples) {
                self.is_voice_active = false;
            }
        }

        return self.is_voice_active;
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
    }

    /// Set hold time in milliseconds
    pub fn setHoldTime(self: *Self, ms: u32) void {
        self.hold_time_ms = ms;
    }
};

/// List available input devices
pub fn listInputDevices(allocator: Allocator) ![]InputDeviceInfo {
    // Platform-specific implementation would go here
    var devices = try allocator.alloc(InputDeviceInfo, 1);

    devices[0] = InputDeviceInfo{
        .id = 0,
        .name = undefined,
        .name_len = 13,
        .channels = 2,
        .sample_rate = 44100,
        .is_default = true,
    };
    @memcpy(devices[0].name[0..13], "Default Input");

    return devices;
}

// ============================================================================
// Tests
// ============================================================================

test "AudioRecorder init" {
    const allocator = std.testing.allocator;

    var recorder = try AudioRecorder.init(allocator, 44100, 2);
    defer recorder.deinit();

    try std.testing.expectEqual(RecordingState.stopped, recorder.state);
}

test "AudioRecorder process" {
    const allocator = std.testing.allocator;

    var recorder = try AudioRecorder.init(allocator, 44100, 1);
    defer recorder.deinit();

    try recorder.start();
    try std.testing.expectEqual(RecordingState.recording, recorder.state);

    const samples = [_]f32{ 0.5, -0.5, 0.3, -0.3 };
    try recorder.processInput(&samples);

    try std.testing.expectEqual(@as(usize, 4), recorder.samples_recorded);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), recorder.peak_level, 0.001);
}

test "VoiceActivityDetector" {
    var vad = VoiceActivityDetector.init(44100);
    vad.setThreshold(-30);

    // Loud signal
    const loud = [_]f32{0.5} ** 100;
    try std.testing.expect(vad.process(&loud));

    // Quiet signal
    const quiet = [_]f32{0.001} ** 100;
    // Still active due to hold time
    try std.testing.expect(vad.process(&quiet));
}
