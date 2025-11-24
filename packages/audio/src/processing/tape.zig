// Home Audio Library - Tape Saturation & Warmth
// Analog tape emulation effects

const std = @import("std");
const math = std.math;

/// Tape saturation/warmth effect
pub const TapeSaturation = struct {
    sample_rate: u32,

    // Saturation parameters
    drive: f32, // Input gain (1.0 - 10.0)
    saturation: f32, // Saturation amount (0.0 - 1.0)
    warmth: f32, // Low-frequency emphasis (0.0 - 1.0)
    bias: f32, // Tape bias (asymmetry)

    // Filtering state (tape head resonance)
    hp_z1: f32,
    hp_z2: f32,
    lp_z1: f32,
    lp_z2: f32,

    // Wow and flutter
    wow_phase: f32,
    flutter_phase: f32,
    wow_depth: f32,
    flutter_depth: f32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        return Self{
            .sample_rate = sample_rate,
            .drive = 1.0,
            .saturation = 0.5,
            .warmth = 0.3,
            .bias = 0.0,
            .hp_z1 = 0,
            .hp_z2 = 0,
            .lp_z1 = 0,
            .lp_z2 = 0,
            .wow_phase = 0,
            .flutter_phase = 0,
            .wow_depth = 0.002, // Slight pitch variation
            .flutter_depth = 0.001,
        };
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = math.clamp(drive, 1, 10);
    }

    pub fn setSaturation(self: *Self, saturation: f32) void {
        self.saturation = math.clamp(saturation, 0, 1);
    }

    pub fn setWarmth(self: *Self, warmth: f32) void {
        self.warmth = math.clamp(warmth, 0, 1);
    }

    pub fn setBias(self: *Self, bias: f32) void {
        self.bias = math.clamp(bias, -1, 1);
    }

    pub fn setWowFlutter(self: *Self, wow_depth: f32, flutter_depth: f32) void {
        self.wow_depth = math.clamp(wow_depth, 0, 0.01);
        self.flutter_depth = math.clamp(flutter_depth, 0, 0.01);
    }

    /// Soft clipping using tanh-based saturation
    fn softClip(x: f32, amount: f32) f32 {
        if (amount < 0.01) return x;

        // Tanh saturation: tanh(x) = (e^(2x) - 1) / (e^(2x) + 1)
        const driven = x * (1.0 + amount * 2.0);
        const exp_2x = @exp(2.0 * driven);
        const limited = (exp_2x - 1.0) / (exp_2x + 1.0);
        return limited / (1.0 + amount * 0.5);
    }

    /// Asymmetric saturation (tape bias)
    fn asymmetricSaturation(x: f32, bias: f32) f32 {
        const shifted = x + bias;
        // tanh(x) = (e^(2x) - 1) / (e^(2x) + 1)
        const exp_shift = @exp(2.0 * shifted * 1.5);
        const saturated = (exp_shift - 1.0) / (exp_shift + 1.0);
        const exp_bias = @exp(2.0 * bias * 1.5);
        const bias_tanh = (exp_bias - 1.0) / (exp_bias + 1.0);
        return saturated - bias_tanh;
    }

    /// High-pass filter (tape head bump removal)
    fn highPass(self: *Self, sample: f32) f32 {
        // Simple 1-pole HPF at ~20 Hz
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const fc = 20.0;
        const omega = 2.0 * math.pi * fc / sr;
        const alpha = 1.0 / (1.0 + omega);

        const output = alpha * (self.hp_z1 + sample - self.hp_z2);
        self.hp_z2 = self.hp_z1;
        self.hp_z1 = sample;

        return output;
    }

    /// Low-pass filter with resonance (tape head response)
    fn lowPass(self: *Self, sample: f32, warmth: f32) f32 {
        // Resonant low-pass at ~12 kHz, more resonance = more warmth
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const fc = 12000.0 - warmth * 6000.0; // Lower cutoff with more warmth
        const omega = 2.0 * math.pi * fc / sr;
        const q = 0.5 + warmth * 1.5; // More resonance with warmth
        const alpha = @sin(omega) / (2.0 * q);

        const cos_omega = @cos(omega);
        const b0 = (1.0 - cos_omega) / 2.0;
        const b1 = 1.0 - cos_omega;
        const b2 = (1.0 - cos_omega) / 2.0;
        const a0 = 1.0 + alpha;
        const a1 = -2.0 * cos_omega;
        const a2 = 1.0 - alpha;

        const output = (b0 * sample + b1 * self.lp_z1 + b2 * self.lp_z2 - a1 * self.lp_z1 - a2 * self.lp_z2) / a0;
        self.lp_z2 = self.lp_z1;
        self.lp_z1 = output;

        return output;
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Apply drive
        var output = sample * self.drive;

        // Tape saturation (soft clipping)
        output = softClip(output, self.saturation);

        // Asymmetric saturation (bias)
        if (@abs(self.bias) > 0.01) {
            output = asymmetricSaturation(output, self.bias);
        }

        // High-pass filter (remove DC)
        output = self.highPass(output);

        // Low-pass filter with warmth
        output = self.lowPass(output, self.warmth);

        // Wow and flutter (very subtle pitch modulation)
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const wow_lfo = @sin(self.wow_phase) * self.wow_depth;
        const flutter_lfo = @sin(self.flutter_phase) * self.flutter_depth;

        // Advance wow/flutter phases
        self.wow_phase += 2.0 * math.pi * 0.5 / sr; // 0.5 Hz wow
        self.flutter_phase += 2.0 * math.pi * 8.0 / sr; // 8 Hz flutter

        if (self.wow_phase >= 2.0 * math.pi) self.wow_phase -= 2.0 * math.pi;
        if (self.flutter_phase >= 2.0 * math.pi) self.flutter_phase -= 2.0 * math.pi;

        // Apply very subtle amplitude modulation to simulate pitch variation
        output *= 1.0 + wow_lfo + flutter_lfo;

        // Normalize output
        output /= self.drive * 0.8;

        return output;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }

    pub fn reset(self: *Self) void {
        self.hp_z1 = 0;
        self.hp_z2 = 0;
        self.lp_z1 = 0;
        self.lp_z2 = 0;
        self.wow_phase = 0;
        self.flutter_phase = 0;
    }
};

/// Vintage tape presets
pub const TapePreset = enum {
    clean_modern, // Minimal saturation, clean sound
    vintage_warm, // Classic analog warmth
    driven_tape, // Pushed tape, heavy saturation
    lo_fi, // Degraded tape sound

    pub fn apply(self: TapePreset, tape: *TapeSaturation) void {
        switch (self) {
            .clean_modern => {
                tape.setDrive(1.2);
                tape.setSaturation(0.2);
                tape.setWarmth(0.2);
                tape.setBias(0.0);
                tape.setWowFlutter(0.0005, 0.0002);
            },
            .vintage_warm => {
                tape.setDrive(1.8);
                tape.setSaturation(0.5);
                tape.setWarmth(0.6);
                tape.setBias(0.1);
                tape.setWowFlutter(0.002, 0.001);
            },
            .driven_tape => {
                tape.setDrive(3.5);
                tape.setSaturation(0.8);
                tape.setWarmth(0.4);
                tape.setBias(0.15);
                tape.setWowFlutter(0.003, 0.0015);
            },
            .lo_fi => {
                tape.setDrive(2.5);
                tape.setSaturation(0.9);
                tape.setWarmth(0.8);
                tape.setBias(0.2);
                tape.setWowFlutter(0.008, 0.005);
            },
        }
    }
};

/// Tube saturation (similar to tape but different characteristics)
pub const TubeSaturation = struct {
    drive: f32,
    bias: f32,
    output_level: f32,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .drive = 1.0,
            .bias = 0.0,
            .output_level = 1.0,
        };
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = math.clamp(drive, 1, 20);
    }

    pub fn setBias(self: *Self, bias: f32) void {
        self.bias = math.clamp(bias, -1, 1);
    }

    pub fn setOutputLevel(self: *Self, level: f32) void {
        self.output_level = math.clamp(level, 0, 2);
    }

    /// Tube-style saturation curve
    fn tubeCurve(x: f32) f32 {
        const abs_x = @abs(x);

        if (abs_x < 0.333) {
            return x * 2.0;
        } else if (abs_x < 0.666) {
            const sign = if (x >= 0) @as(f32, 1) else -1;
            return sign * (3.0 - math.pow(f32, 2.0 - 3.0 * abs_x, 2)) / 3.0;
        } else {
            const sign = if (x >= 0) @as(f32, 1) else -1;
            return sign;
        }
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        // Apply drive and bias
        var output = (sample + self.bias) * self.drive;

        // Tube saturation curve
        output = tubeCurve(output);

        // Remove bias offset
        output -= tubeCurve(self.bias * self.drive);

        // Apply output level
        return output * self.output_level;
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

test "TapeSaturation init" {
    const tape = TapeSaturation.init(44100);
    try std.testing.expectEqual(@as(u32, 44100), tape.sample_rate);
    try std.testing.expectEqual(@as(f32, 1.0), tape.drive);
}

test "TapeSaturation process" {
    var tape = TapeSaturation.init(44100);
    tape.setDrive(2.0);
    tape.setSaturation(0.7);

    const input = [_]f32{0.5} ** 100;
    var output: [100]f32 = undefined;

    tape.process(&input, &output);

    // Output should be different due to saturation
    var different = false;
    for (input, output) |i, o| {
        if (@abs(i - o) > 0.01) {
            different = true;
            break;
        }
    }
    try std.testing.expect(different);
}

test "TapePreset vintage_warm" {
    var tape = TapeSaturation.init(44100);
    TapePreset.vintage_warm.apply(&tape);

    try std.testing.expectEqual(@as(f32, 1.8), tape.drive);
    try std.testing.expectEqual(@as(f32, 0.5), tape.saturation);
}

test "TubeSaturation init" {
    const tube = TubeSaturation.init();
    try std.testing.expectEqual(@as(f32, 1.0), tube.drive);
}

test "TubeSaturation saturation" {
    var tube = TubeSaturation.init();
    tube.setDrive(5.0);

    // Large input should be saturated
    const output = tube.processSample(0.8);
    try std.testing.expect(@abs(output) <= 1.0); // Should be limited to <=1.0
}
