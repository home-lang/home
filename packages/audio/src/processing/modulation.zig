// Home Audio Library - Modulation Effects
// Tremolo, vibrato, ring modulator, phaser, flanger

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Tremolo effect (amplitude modulation)
pub const Tremolo = struct {
    sample_rate: u32,
    rate_hz: f32, // LFO rate
    depth: f32, // 0.0 - 1.0
    phase: f32,

    const Self = @This();

    pub fn init(sample_rate: u32, rate_hz: f32, depth: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .rate_hz = rate_hz,
            .depth = depth,
            .phase = 0,
        };
    }

    pub fn setRate(self: *Self, rate_hz: f32) void {
        self.rate_hz = rate_hz;
    }

    pub fn setDepth(self: *Self, depth: f32) void {
        self.depth = math.clamp(depth, 0, 1);
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Sine wave LFO
        const lfo = @sin(self.phase);
        const modulation = 1.0 - (self.depth * (1.0 - lfo) / 2.0);

        // Advance phase
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.phase += 2.0 * math.pi * self.rate_hz / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        return sample * modulation;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }
};

/// Vibrato effect (pitch modulation via delay)
pub const Vibrato = struct {
    allocator: Allocator,
    sample_rate: u32,
    rate_hz: f32,
    depth_samples: f32, // Modulation depth in samples
    phase: f32,

    // Delay line
    delay_buffer: []f32,
    write_pos: usize,

    const Self = @This();
    const MAX_DELAY_MS: f32 = 20.0; // Maximum vibrato delay

    pub fn init(allocator: Allocator, sample_rate: u32, rate_hz: f32, depth_ms: f32) !Self {
        const sr = @as(f32, @floatFromInt(sample_rate));
        const buffer_size = @as(usize, @intFromFloat(MAX_DELAY_MS * sr / 1000.0));
        const delay_buffer = try allocator.alloc(f32, buffer_size);
        @memset(delay_buffer, 0);

        const depth_samples = depth_ms * sr / 1000.0;

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .rate_hz = rate_hz,
            .depth_samples = depth_samples,
            .phase = 0,
            .delay_buffer = delay_buffer,
            .write_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.delay_buffer);
    }

    pub fn setRate(self: *Self, rate_hz: f32) void {
        self.rate_hz = rate_hz;
    }

    pub fn setDepth(self: *Self, depth_ms: f32) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.depth_samples = depth_ms * sr / 1000.0;
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Write to delay buffer
        self.delay_buffer[self.write_pos] = sample;

        // Calculate read position with LFO modulation
        const lfo = @sin(self.phase);
        const delay_samples = self.depth_samples * (1.0 + lfo) / 2.0;

        // Fractional delay with linear interpolation
        const read_pos_f = @as(f32, @floatFromInt(self.write_pos)) - delay_samples;
        const read_pos_wrapped = if (read_pos_f < 0)
            read_pos_f + @as(f32, @floatFromInt(self.delay_buffer.len))
        else
            read_pos_f;

        const read_pos_int = @as(usize, @intFromFloat(read_pos_wrapped)) % self.delay_buffer.len;
        const read_pos_next = (read_pos_int + 1) % self.delay_buffer.len;
        const frac = read_pos_wrapped - @floor(read_pos_wrapped);

        const s1 = self.delay_buffer[read_pos_int];
        const s2 = self.delay_buffer[read_pos_next];
        const output_sample = s1 + frac * (s2 - s1);

        // Advance write position
        self.write_pos = (self.write_pos + 1) % self.delay_buffer.len;

        // Advance phase
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.phase += 2.0 * math.pi * self.rate_hz / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        return output_sample;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }
};

/// Ring modulator (frequency modulation)
pub const RingModulator = struct {
    sample_rate: u32,
    carrier_freq: f32,
    phase: f32,
    mix: f32, // 0.0 = dry, 1.0 = fully modulated

    const Self = @This();

    pub fn init(sample_rate: u32, carrier_freq: f32, mix: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .carrier_freq = carrier_freq,
            .phase = 0,
            .mix = math.clamp(mix, 0, 1),
        };
    }

    pub fn setCarrierFreq(self: *Self, freq: f32) void {
        self.carrier_freq = freq;
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Generate carrier
        const carrier = @sin(self.phase);

        // Ring modulation is simple multiplication
        const modulated = sample * carrier;

        // Advance phase
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.phase += 2.0 * math.pi * self.carrier_freq / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        // Mix dry and wet
        return sample * (1.0 - self.mix) + modulated * self.mix;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }
};

/// Flanger effect (short delay with feedback)
pub const Flanger = struct {
    allocator: Allocator,
    sample_rate: u32,
    rate_hz: f32, // LFO rate
    depth_samples: f32,
    feedback: f32, // -1.0 to 1.0
    mix: f32, // Dry/wet mix
    phase: f32,

    // Delay line
    delay_buffer: []f32,
    write_pos: usize,

    const Self = @This();
    const MAX_DELAY_MS: f32 = 15.0;

    pub fn init(allocator: Allocator, sample_rate: u32, rate_hz: f32, depth_ms: f32, feedback: f32, mix: f32) !Self {
        const sr = @as(f32, @floatFromInt(sample_rate));
        const buffer_size = @as(usize, @intFromFloat(MAX_DELAY_MS * sr / 1000.0));
        const delay_buffer = try allocator.alloc(f32, buffer_size);
        @memset(delay_buffer, 0);

        const depth_samples = depth_ms * sr / 1000.0;

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .rate_hz = rate_hz,
            .depth_samples = depth_samples,
            .feedback = math.clamp(feedback, -1, 1),
            .mix = math.clamp(mix, 0, 1),
            .phase = 0,
            .delay_buffer = delay_buffer,
            .write_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.delay_buffer);
    }

    pub fn setRate(self: *Self, rate_hz: f32) void {
        self.rate_hz = rate_hz;
    }

    pub fn setDepth(self: *Self, depth_ms: f32) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.depth_samples = depth_ms * sr / 1000.0;
    }

    pub fn setFeedback(self: *Self, feedback: f32) void {
        self.feedback = math.clamp(feedback, -1, 1);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Calculate read position with LFO
        const lfo = @sin(self.phase);
        const delay_samples = self.depth_samples * (1.0 + lfo) / 2.0;

        // Fractional delay with linear interpolation
        const read_pos_f = @as(f32, @floatFromInt(self.write_pos)) - delay_samples;
        const read_pos_wrapped = if (read_pos_f < 0)
            read_pos_f + @as(f32, @floatFromInt(self.delay_buffer.len))
        else
            read_pos_f;

        const read_pos_int = @as(usize, @intFromFloat(read_pos_wrapped)) % self.delay_buffer.len;
        const read_pos_next = (read_pos_int + 1) % self.delay_buffer.len;
        const frac = read_pos_wrapped - @floor(read_pos_wrapped);

        const s1 = self.delay_buffer[read_pos_int];
        const s2 = self.delay_buffer[read_pos_next];
        const delayed = s1 + frac * (s2 - s1);

        // Write to buffer with feedback
        const to_write = sample + delayed * self.feedback;
        self.delay_buffer[self.write_pos] = to_write;

        // Advance write position
        self.write_pos = (self.write_pos + 1) % self.delay_buffer.len;

        // Advance phase
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.phase += 2.0 * math.pi * self.rate_hz / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        // Mix dry and wet
        return sample * (1.0 - self.mix) + delayed * self.mix;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }
};

/// Phaser effect (all-pass filter with LFO)
pub const Phaser = struct {
    allocator: Allocator,
    sample_rate: u32,
    rate_hz: f32,
    depth: f32,
    feedback: f32,
    mix: f32,
    num_stages: usize,
    phase: f32,

    // All-pass filter stages
    stages: []AllPassStage,

    const Self = @This();

    const AllPassStage = struct {
        a1: f32 = 0,
        zm1: f32 = 0,
    };

    pub fn init(allocator: Allocator, sample_rate: u32, num_stages: usize, rate_hz: f32, depth: f32, feedback: f32, mix: f32) !Self {
        const stages = try allocator.alloc(AllPassStage, num_stages);
        for (stages) |*stage| {
            stage.* = .{};
        }

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .rate_hz = rate_hz,
            .depth = math.clamp(depth, 0, 1),
            .feedback = math.clamp(feedback, -1, 1),
            .mix = math.clamp(mix, 0, 1),
            .num_stages = num_stages,
            .phase = 0,
            .stages = stages,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stages);
    }

    pub fn setRate(self: *Self, rate_hz: f32) void {
        self.rate_hz = rate_hz;
    }

    pub fn setDepth(self: *Self, depth: f32) void {
        self.depth = math.clamp(depth, 0, 1);
    }

    pub fn setFeedback(self: *Self, feedback: f32) void {
        self.feedback = math.clamp(feedback, -1, 1);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    fn processAllPass(stage: *AllPassStage, sample: f32, a1: f32) f32 {
        const output = a1 * sample + stage.zm1;
        stage.zm1 = sample - a1 * output;
        return output;
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // LFO controls all-pass frequency
        const lfo = @sin(self.phase);
        const min_freq = 200.0;
        const max_freq = 2000.0;
        const freq = min_freq + (max_freq - min_freq) * (1.0 + lfo * self.depth) / 2.0;

        // Calculate all-pass coefficient
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const tan_val = @tan(math.pi * freq / sr);
        const a1 = (tan_val - 1.0) / (tan_val + 1.0);

        // Process through all-pass stages
        var filtered = sample;
        for (self.stages) |*stage| {
            filtered = processAllPass(stage, filtered, a1);
        }

        // Add feedback
        filtered = filtered * (1.0 + self.feedback);

        // Advance phase
        self.phase += 2.0 * math.pi * self.rate_hz / sr;
        if (self.phase >= 2.0 * math.pi) {
            self.phase -= 2.0 * math.pi;
        }

        // Mix dry and wet
        return sample * (1.0 - self.mix) + filtered * self.mix;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Tremolo basic" {
    var tremolo = Tremolo.init(44100, 5.0, 0.5);

    const input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;

    tremolo.process(&input, &output);

    // Check that amplitude varies
    var min: f32 = 1.0;
    var max: f32 = 0.0;
    for (output) |sample| {
        min = @min(min, @abs(sample));
        max = @max(max, @abs(sample));
    }

    try std.testing.expect(max > min); // Amplitude should vary
    try std.testing.expect(max <= 1.0); // Should not exceed input
}

test "Vibrato init" {
    const allocator = std.testing.allocator;

    var vibrato = try Vibrato.init(allocator, 44100, 5.0, 2.0);
    defer vibrato.deinit();

    try std.testing.expectEqual(@as(u32, 44100), vibrato.sample_rate);
}

test "RingModulator basic" {
    var ring_mod = RingModulator.init(44100, 440.0, 0.5);

    const input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;

    ring_mod.process(&input, &output);

    // Output should be different from input
    var different = false;
    for (input, output) |i, o| {
        if (@abs(i - o) > 0.01) {
            different = true;
            break;
        }
    }
    try std.testing.expect(different);
}

test "Flanger init" {
    const allocator = std.testing.allocator;

    var flanger = try Flanger.init(allocator, 44100, 0.5, 2.0, 0.5, 0.5);
    defer flanger.deinit();

    try std.testing.expectEqual(@as(u32, 44100), flanger.sample_rate);
}

test "Phaser init" {
    const allocator = std.testing.allocator;

    var phaser = try Phaser.init(allocator, 44100, 4, 0.5, 0.8, 0.5, 0.5);
    defer phaser.deinit();

    try std.testing.expectEqual(@as(usize, 4), phaser.num_stages);
}
