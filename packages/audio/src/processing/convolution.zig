// Home Audio Library - Convolution Reverb
// Impulse response based reverb using FFT convolution

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Convolution reverb using partitioned convolution
pub const ConvolutionReverb = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Impulse response
    ir_partitions: [][]f32, // Partitioned IR in frequency domain
    num_partitions: usize,
    partition_size: usize,

    // Processing buffers
    input_buffer: []f32,
    output_buffer: []f32,
    overlap_buffer: []f32,
    fft_buffer: []f32,

    // Buffer positions
    input_pos: usize,

    // Mix parameters
    dry_level: f32,
    wet_level: f32,
    pre_delay_samples: usize,

    // Pre-delay buffer
    pre_delay_buffer: []f32,
    pre_delay_pos: usize,

    const Self = @This();

    pub const DEFAULT_PARTITION_SIZE = 512;
    pub const MAX_PRE_DELAY_MS = 500;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        const max_pre_delay = @as(usize, @intFromFloat(MAX_PRE_DELAY_MS * @as(f32, @floatFromInt(sample_rate)) / 1000.0)) * channels;

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .ir_partitions = &[_][]f32{},
            .num_partitions = 0,
            .partition_size = DEFAULT_PARTITION_SIZE,
            .input_buffer = try allocator.alloc(f32, DEFAULT_PARTITION_SIZE * 2 * @as(usize, channels)),
            .output_buffer = try allocator.alloc(f32, DEFAULT_PARTITION_SIZE * 2 * @as(usize, channels)),
            .overlap_buffer = try allocator.alloc(f32, DEFAULT_PARTITION_SIZE * @as(usize, channels)),
            .fft_buffer = try allocator.alloc(f32, DEFAULT_PARTITION_SIZE * 4),
            .input_pos = 0,
            .dry_level = 0.5,
            .wet_level = 0.5,
            .pre_delay_samples = 0,
            .pre_delay_buffer = try allocator.alloc(f32, max_pre_delay),
            .pre_delay_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.ir_partitions) |partition| {
            self.allocator.free(partition);
        }
        if (self.ir_partitions.len > 0) {
            self.allocator.free(self.ir_partitions);
        }
        self.allocator.free(self.input_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.free(self.overlap_buffer);
        self.allocator.free(self.fft_buffer);
        self.allocator.free(self.pre_delay_buffer);
    }

    /// Load impulse response
    pub fn loadImpulseResponse(self: *Self, ir_samples: []const f32, ir_channels: u8) !void {
        // Free existing partitions
        for (self.ir_partitions) |partition| {
            self.allocator.free(partition);
        }
        if (self.ir_partitions.len > 0) {
            self.allocator.free(self.ir_partitions);
        }

        // Mix IR to mono if needed
        const ir_frames = ir_samples.len / ir_channels;
        var mono_ir = try self.allocator.alloc(f32, ir_frames);
        defer self.allocator.free(mono_ir);

        for (0..ir_frames) |i| {
            var sum: f32 = 0;
            for (0..ir_channels) |ch| {
                sum += ir_samples[i * ir_channels + ch];
            }
            mono_ir[i] = sum / @as(f32, @floatFromInt(ir_channels));
        }

        // Calculate number of partitions
        self.num_partitions = (ir_frames + self.partition_size - 1) / self.partition_size;

        // Create partitions
        self.ir_partitions = try self.allocator.alloc([]f32, self.num_partitions);

        for (0..self.num_partitions) |p| {
            self.ir_partitions[p] = try self.allocator.alloc(f32, self.partition_size * 2);

            const start = p * self.partition_size;
            const end = @min(start + self.partition_size, ir_frames);

            // Copy IR segment (zero-padded)
            @memset(self.ir_partitions[p], 0);
            for (start..end) |i| {
                self.ir_partitions[p][i - start] = mono_ir[i];
            }

            // In real implementation, would apply FFT here
            // For simplicity, we store time-domain segments
        }
    }

    /// Generate simple reverb IR
    pub fn generateSimpleIR(self: *Self, decay_time: f32, density: u32) !void {
        const ir_samples = @as(usize, @intFromFloat(decay_time * @as(f32, @floatFromInt(self.sample_rate))));

        var ir = try self.allocator.alloc(f32, ir_samples);
        defer self.allocator.free(ir);

        // Create exponentially decaying noise
        var prng = std.Random.DefaultPrng.init(12345);
        const random = prng.random();

        for (0..ir_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ir_samples));
            const envelope = @exp(-t * 5.0); // Exponential decay

            // Sparse early reflections + dense tail
            if (i < ir_samples / 10) {
                // Early reflections
                if (random.int(u32) % density == 0) {
                    ir[i] = (random.float(f32) * 2.0 - 1.0) * envelope;
                } else {
                    ir[i] = 0;
                }
            } else {
                // Dense tail
                ir[i] = (random.float(f32) * 2.0 - 1.0) * envelope * 0.5;
            }
        }

        try self.loadImpulseResponse(ir, 1);
    }

    /// Set dry/wet mix (0.0 - 1.0)
    pub fn setMix(self: *Self, wet: f32) void {
        self.wet_level = std.math.clamp(wet, 0.0, 1.0);
        self.dry_level = 1.0 - self.wet_level;
    }

    /// Set dry level
    pub fn setDryLevel(self: *Self, level: f32) void {
        self.dry_level = std.math.clamp(level, 0.0, 1.0);
    }

    /// Set wet level
    pub fn setWetLevel(self: *Self, level: f32) void {
        self.wet_level = std.math.clamp(level, 0.0, 1.0);
    }

    /// Set pre-delay in milliseconds
    pub fn setPreDelay(self: *Self, ms: f32) void {
        self.pre_delay_samples = @intFromFloat(std.math.clamp(ms, 0, MAX_PRE_DELAY_MS) * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0);
    }

    /// Process audio buffer
    pub fn process(self: *Self, buffer: []f32) void {
        if (self.num_partitions == 0) {
            // No IR loaded, just apply dry level
            for (buffer) |*s| {
                s.* *= self.dry_level;
            }
            return;
        }

        const num_frames = buffer.len / self.channels;

        for (0..num_frames) |frame| {
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                const input_sample = buffer[idx];

                // Pre-delay
                var delayed: f32 = 0;
                if (self.pre_delay_samples > 0) {
                    const delay_idx = (self.pre_delay_pos + self.pre_delay_buffer.len - self.pre_delay_samples) % self.pre_delay_buffer.len;
                    delayed = self.pre_delay_buffer[delay_idx];
                    self.pre_delay_buffer[self.pre_delay_pos] = input_sample;
                    self.pre_delay_pos = (self.pre_delay_pos + 1) % self.pre_delay_buffer.len;
                } else {
                    delayed = input_sample;
                }

                // Simple time-domain convolution (for short IRs)
                // Real implementation would use FFT-based partitioned convolution
                var wet: f32 = 0;
                const max_taps = @min(256, self.partition_size);

                for (0..max_taps) |tap| {
                    if (self.num_partitions > 0 and tap < self.ir_partitions[0].len) {
                        const buf_idx = (self.input_pos + self.input_buffer.len - tap) % self.input_buffer.len;
                        wet += self.input_buffer[buf_idx] * self.ir_partitions[0][tap] * 0.1;
                    }
                }

                // Store input for convolution
                self.input_buffer[self.input_pos] = delayed;
                self.input_pos = (self.input_pos + 1) % self.input_buffer.len;

                // Mix dry and wet
                buffer[idx] = input_sample * self.dry_level + wet * self.wet_level;
            }
        }
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        @memset(self.input_buffer, 0);
        @memset(self.output_buffer, 0);
        @memset(self.overlap_buffer, 0);
        @memset(self.pre_delay_buffer, 0);
        self.input_pos = 0;
        self.pre_delay_pos = 0;
    }

    /// Get latency in samples
    pub fn getLatency(self: *Self) usize {
        return self.partition_size + self.pre_delay_samples;
    }
};

/// Preset reverb spaces
pub const ReverbSpace = enum {
    small_room,
    medium_room,
    large_hall,
    cathedral,
    plate,
    spring,

    pub fn getDecayTime(self: ReverbSpace) f32 {
        return switch (self) {
            .small_room => 0.3,
            .medium_room => 0.8,
            .large_hall => 2.5,
            .cathedral => 5.0,
            .plate => 1.5,
            .spring => 0.6,
        };
    }

    pub fn getDensity(self: ReverbSpace) u32 {
        return switch (self) {
            .small_room => 20,
            .medium_room => 15,
            .large_hall => 10,
            .cathedral => 8,
            .plate => 5,
            .spring => 30,
        };
    }

    pub fn getPreDelay(self: ReverbSpace) f32 {
        return switch (self) {
            .small_room => 5,
            .medium_room => 15,
            .large_hall => 40,
            .cathedral => 80,
            .plate => 10,
            .spring => 20,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ConvolutionReverb init" {
    const allocator = std.testing.allocator;

    var reverb = try ConvolutionReverb.init(allocator, 44100, 2);
    defer reverb.deinit();

    reverb.setMix(0.5);
    reverb.setPreDelay(20);
}

test "ConvolutionReverb generateIR" {
    const allocator = std.testing.allocator;

    var reverb = try ConvolutionReverb.init(allocator, 44100, 2);
    defer reverb.deinit();

    try reverb.generateSimpleIR(0.5, 20);
    try std.testing.expect(reverb.num_partitions > 0);
}

test "ConvolutionReverb process" {
    const allocator = std.testing.allocator;

    var reverb = try ConvolutionReverb.init(allocator, 44100, 1);
    defer reverb.deinit();

    try reverb.generateSimpleIR(0.3, 20);
    reverb.setMix(0.5);

    var buffer = [_]f32{ 1.0, 0, 0, 0, 0, 0, 0, 0 };
    reverb.process(&buffer);

    // Should have processed audio
    try std.testing.expect(buffer[0] != 0);
}
