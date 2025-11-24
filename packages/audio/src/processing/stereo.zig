// Home Audio Library - Stereo Processing
// Stereo widener, M/S processing, and stereo image tools

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Stereo widener using M/S (Mid/Side) technique
pub const StereoWidener = struct {
    width: f32, // 0.0 = mono, 1.0 = normal, 2.0 = widest
    center_level: f32, // Center (mid) level adjustment
    side_level: f32, // Side level adjustment (computed from width)

    // Optional low-frequency crossover
    crossover_enabled: bool,
    crossover_freq: f32,
    sample_rate: u32,

    // Crossover filter state
    lp_x1: [2]f64,
    lp_x2: [2]f64,
    lp_y1: [2]f64,
    lp_y2: [2]f64,
    lp_coeffs: BiquadCoeffs,

    const Self = @This();

    const BiquadCoeffs = struct {
        b0: f64,
        b1: f64,
        b2: f64,
        a1: f64,
        a2: f64,
    };

    pub fn init(sample_rate: u32) Self {
        var widener = Self{
            .width = 1.0,
            .center_level = 1.0,
            .side_level = 1.0,
            .crossover_enabled = false,
            .crossover_freq = 200,
            .sample_rate = sample_rate,
            .lp_x1 = [_]f64{0} ** 2,
            .lp_x2 = [_]f64{0} ** 2,
            .lp_y1 = [_]f64{0} ** 2,
            .lp_y2 = [_]f64{0} ** 2,
            .lp_coeffs = .{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 },
        };
        widener.updateCrossover();
        return widener;
    }

    fn updateCrossover(self: *Self) void {
        const w0 = 2.0 * math.pi * @as(f64, self.crossover_freq) / @as(f64, @floatFromInt(self.sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * @sqrt(2.0)); // Butterworth Q

        const b0 = (1 - cos_w0) / 2;
        const b1 = 1 - cos_w0;
        const b2 = (1 - cos_w0) / 2;
        const a0 = 1 + alpha;
        const a1 = -2 * cos_w0;
        const a2 = 1 - alpha;

        self.lp_coeffs = .{
            .b0 = b0 / a0,
            .b1 = b1 / a0,
            .b2 = b2 / a0,
            .a1 = a1 / a0,
            .a2 = a2 / a0,
        };
    }

    /// Set stereo width (0.0 = mono, 1.0 = original, 2.0 = double width)
    pub fn setWidth(self: *Self, width: f32) void {
        self.width = std.math.clamp(width, 0.0, 2.0);
        self.side_level = self.width;
    }

    /// Set center/mid level
    pub fn setCenterLevel(self: *Self, level: f32) void {
        self.center_level = @max(0.0, level);
    }

    /// Enable bass mono (keep bass in center)
    pub fn enableBassMono(self: *Self, enabled: bool, crossover_hz: f32) void {
        self.crossover_enabled = enabled;
        self.crossover_freq = std.math.clamp(crossover_hz, 50, 500);
        self.updateCrossover();
    }

    /// Apply low-pass filter
    fn applyLowPass(self: *Self, sample: f32, ch: u8) f32 {
        const x: f64 = sample;
        const y = self.lp_coeffs.b0 * x +
            self.lp_coeffs.b1 * self.lp_x1[ch] +
            self.lp_coeffs.b2 * self.lp_x2[ch] -
            self.lp_coeffs.a1 * self.lp_y1[ch] -
            self.lp_coeffs.a2 * self.lp_y2[ch];

        self.lp_x2[ch] = self.lp_x1[ch];
        self.lp_x1[ch] = x;
        self.lp_y2[ch] = self.lp_y1[ch];
        self.lp_y1[ch] = y;

        return @floatCast(y);
    }

    /// Process stereo pair (in-place)
    pub fn processStereo(self: *Self, left: *f32, right: *f32) void {
        // Convert L/R to M/S
        const mid = (left.* + right.*) * 0.5;
        const side = (left.* - right.*) * 0.5;

        // Apply width
        var new_mid = mid * self.center_level;
        var new_side = side * self.side_level;

        // Bass mono option
        if (self.crossover_enabled) {
            // Get low frequency content
            const bass_left = self.applyLowPass(left.*, 0);
            const bass_right = self.applyLowPass(right.*, 1);
            const bass_mono = (bass_left + bass_right) * 0.5;

            // Remove bass from side, add mono bass to mid
            const high_mid = mid - bass_mono;
            const high_side = side;

            new_mid = bass_mono * self.center_level + high_mid * self.center_level;
            new_side = high_side * self.side_level;
        }

        // Convert back to L/R
        left.* = new_mid + new_side;
        right.* = new_mid - new_side;
    }

    /// Process interleaved stereo buffer
    pub fn process(self: *Self, buffer: []f32) void {
        if (buffer.len < 2) return;

        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            self.processStereo(&buffer[i], &buffer[i + 1]);
        }
    }

    /// Reset filter state
    pub fn reset(self: *Self) void {
        self.lp_x1 = [_]f64{0} ** 2;
        self.lp_x2 = [_]f64{0} ** 2;
        self.lp_y1 = [_]f64{0} ** 2;
        self.lp_y2 = [_]f64{0} ** 2;
    }
};

/// Mid/Side encoder/decoder for advanced stereo processing
pub const MidSideProcessor = struct {
    const Self = @This();

    /// Encode L/R to M/S
    pub fn encode(left: f32, right: f32) struct { mid: f32, side: f32 } {
        return .{
            .mid = (left + right) * 0.5,
            .side = (left - right) * 0.5,
        };
    }

    /// Decode M/S to L/R
    pub fn decode(mid: f32, side: f32) struct { left: f32, right: f32 } {
        return .{
            .left = mid + side,
            .right = mid - side,
        };
    }

    /// Process buffer: encode L/R to M/S (in-place, alternating samples become M/S)
    pub fn encodeBuffer(buffer: []f32) void {
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const left = buffer[i];
            const right = buffer[i + 1];
            const ms = encode(left, right);
            buffer[i] = ms.mid;
            buffer[i + 1] = ms.side;
        }
    }

    /// Process buffer: decode M/S to L/R (in-place)
    pub fn decodeBuffer(buffer: []f32) void {
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const mid = buffer[i];
            const side = buffer[i + 1];
            const lr = decode(mid, side);
            buffer[i] = lr.left;
            buffer[i + 1] = lr.right;
        }
    }
};

/// Stereo balance/pan control
pub const StereoBalance = struct {
    balance: f32, // -1.0 = full left, 0.0 = center, 1.0 = full right
    left_gain: f32,
    right_gain: f32,
    pan_law: PanLaw,

    const Self = @This();

    pub const PanLaw = enum {
        linear, // Simple linear
        constant_power, // -3dB at center
        compensated, // -4.5dB at center
    };

    pub fn init() Self {
        return Self{
            .balance = 0,
            .left_gain = 1.0,
            .right_gain = 1.0,
            .pan_law = .constant_power,
        };
    }

    /// Set balance (-1 to +1)
    pub fn setBalance(self: *Self, balance: f32) void {
        self.balance = std.math.clamp(balance, -1.0, 1.0);
        self.updateGains();
    }

    /// Set pan law
    pub fn setPanLaw(self: *Self, law: PanLaw) void {
        self.pan_law = law;
        self.updateGains();
    }

    fn updateGains(self: *Self) void {
        const b = self.balance;

        switch (self.pan_law) {
            .linear => {
                self.left_gain = if (b <= 0) 1.0 else 1.0 - b;
                self.right_gain = if (b >= 0) 1.0 else 1.0 + b;
            },
            .constant_power => {
                // -3dB at center (sqrt(0.5))
                const angle = (b + 1.0) * math.pi / 4.0;
                self.left_gain = @cos(angle);
                self.right_gain = @sin(angle);
            },
            .compensated => {
                // -4.5dB at center
                const angle = (b + 1.0) * math.pi / 4.0;
                const compensation = math.pow(f32, 10.0, -4.5 / 20.0);
                self.left_gain = @cos(angle) / compensation;
                self.right_gain = @sin(angle) / compensation;
            },
        }
    }

    /// Process stereo buffer
    pub fn process(self: *Self, buffer: []f32) void {
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            buffer[i] *= self.left_gain;
            buffer[i + 1] *= self.right_gain;
        }
    }
};

/// Stereo correlation meter
pub const StereoCorrelation = struct {
    sum_lr: f64,
    sum_l2: f64,
    sum_r2: f64,
    sample_count: u64,
    window_size: u64,

    const Self = @This();

    pub fn init(window_ms: f32, sample_rate: u32) Self {
        return Self{
            .sum_lr = 0,
            .sum_l2 = 0,
            .sum_r2 = 0,
            .sample_count = 0,
            .window_size = @intFromFloat(window_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0),
        };
    }

    /// Process stereo buffer and update correlation
    pub fn process(self: *Self, buffer: []const f32) void {
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const left: f64 = buffer[i];
            const right: f64 = buffer[i + 1];

            self.sum_lr += left * right;
            self.sum_l2 += left * left;
            self.sum_r2 += right * right;
            self.sample_count += 1;

            // Sliding window decay
            if (self.sample_count > self.window_size) {
                const decay = 0.999;
                self.sum_lr *= decay;
                self.sum_l2 *= decay;
                self.sum_r2 *= decay;
            }
        }
    }

    /// Get correlation coefficient (-1 to +1)
    /// +1 = perfect correlation (mono)
    ///  0 = no correlation (stereo)
    /// -1 = perfect anti-correlation (out of phase)
    pub fn getCorrelation(self: *Self) f32 {
        const denominator = @sqrt(self.sum_l2 * self.sum_r2);
        if (denominator < 0.000001) return 1.0;
        return @floatCast(self.sum_lr / denominator);
    }

    /// Reset
    pub fn reset(self: *Self) void {
        self.sum_lr = 0;
        self.sum_l2 = 0;
        self.sum_r2 = 0;
        self.sample_count = 0;
    }
};

/// Haas effect delay for stereo widening
pub const HaasWidener = struct {
    allocator: Allocator,
    sample_rate: u32,
    delay_ms: f32,
    delay_samples: usize,
    delay_buffer: []f32,
    write_pos: usize,
    wet_mix: f32,
    side: HaasSide,

    const Self = @This();

    pub const HaasSide = enum {
        left,
        right,
    };

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        const max_delay = @as(usize, @intFromFloat(50.0 * @as(f32, @floatFromInt(sample_rate)) / 1000.0));

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .delay_ms = 15,
            .delay_samples = @intFromFloat(15.0 * @as(f32, @floatFromInt(sample_rate)) / 1000.0),
            .delay_buffer = try allocator.alloc(f32, max_delay),
            .write_pos = 0,
            .wet_mix = 0.5,
            .side = .right,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.delay_buffer);
    }

    /// Set delay time in ms (1-50ms typical for Haas effect)
    pub fn setDelay(self: *Self, ms: f32) void {
        self.delay_ms = std.math.clamp(ms, 1, 50);
        self.delay_samples = @intFromFloat(self.delay_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0);
    }

    /// Set wet mix (0-1)
    pub fn setWetMix(self: *Self, mix: f32) void {
        self.wet_mix = std.math.clamp(mix, 0, 1);
    }

    /// Set which side gets the delay
    pub fn setSide(self: *Self, side: HaasSide) void {
        self.side = side;
    }

    /// Process stereo buffer
    pub fn process(self: *Self, buffer: []f32) void {
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const left = buffer[i];
            const right = buffer[i + 1];

            // Read delayed sample
            const read_pos = (self.write_pos + self.delay_buffer.len - self.delay_samples) % self.delay_buffer.len;
            const delayed = self.delay_buffer[read_pos];

            // Write current mono sum to delay
            self.delay_buffer[self.write_pos] = (left + right) * 0.5;
            self.write_pos = (self.write_pos + 1) % self.delay_buffer.len;

            // Apply to selected side
            switch (self.side) {
                .left => {
                    buffer[i] = left * (1 - self.wet_mix) + delayed * self.wet_mix;
                },
                .right => {
                    buffer[i + 1] = right * (1 - self.wet_mix) + delayed * self.wet_mix;
                },
            }
        }
    }

    /// Reset
    pub fn reset(self: *Self) void {
        @memset(self.delay_buffer, 0);
        self.write_pos = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StereoWidener basic" {
    var widener = StereoWidener.init(44100);
    widener.setWidth(1.5);

    var left: f32 = 1.0;
    var right: f32 = 0.5;
    widener.processStereo(&left, &right);

    // Width > 1 should increase stereo difference
    try std.testing.expect(left != right);
}

test "StereoWidener mono" {
    var widener = StereoWidener.init(44100);
    widener.setWidth(0.0); // Full mono

    var left: f32 = 1.0;
    var right: f32 = -1.0;
    widener.processStereo(&left, &right);

    // Should be equal (mono)
    try std.testing.expectApproxEqAbs(left, right, 0.001);
}

test "MidSideProcessor encode/decode" {
    const left: f32 = 1.0;
    const right: f32 = 0.5;

    const ms = MidSideProcessor.encode(left, right);
    const lr = MidSideProcessor.decode(ms.mid, ms.side);

    try std.testing.expectApproxEqAbs(left, lr.left, 0.0001);
    try std.testing.expectApproxEqAbs(right, lr.right, 0.0001);
}

test "StereoBalance center" {
    var balance = StereoBalance.init();
    balance.setBalance(0);

    var buffer = [_]f32{ 1.0, 1.0 };
    balance.process(&buffer);

    // Center should keep both channels similar (depending on pan law)
    try std.testing.expect(buffer[0] != 0);
    try std.testing.expect(buffer[1] != 0);
}

test "StereoCorrelation mono" {
    var corr = StereoCorrelation.init(100, 44100);

    // Identical signals = correlation of 1
    const buffer = [_]f32{ 0.5, 0.5, 0.3, 0.3, 0.7, 0.7 };
    corr.process(&buffer);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corr.getCorrelation(), 0.001);
}

test "HaasWidener init" {
    const allocator = std.testing.allocator;

    var haas = try HaasWidener.init(allocator, 44100);
    defer haas.deinit();

    haas.setDelay(20);
    haas.setWetMix(0.5);
}
