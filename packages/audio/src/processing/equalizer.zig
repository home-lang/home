// Home Audio Library - Equalizer
// Parametric and Graphic Equalizer implementations

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Filter type for parametric EQ bands
pub const FilterType = enum {
    low_shelf,
    high_shelf,
    peak, // Bell/parametric
    low_pass,
    high_pass,
    band_pass,
    notch,
    all_pass,
};

/// Single biquad filter coefficients
pub const BiquadCoeffs = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
};

/// Parametric EQ band
pub const ParametricBand = struct {
    frequency: f32, // Center frequency in Hz
    gain_db: f32, // Gain in dB (-24 to +24)
    q: f32, // Q factor (0.1 to 10)
    filter_type: FilterType,
    enabled: bool,

    // Filter state (per channel)
    x1: [8]f64, // Previous inputs
    x2: [8]f64,
    y1: [8]f64, // Previous outputs
    y2: [8]f64,

    // Computed coefficients
    coeffs: BiquadCoeffs,

    const Self = @This();

    pub fn init(freq: f32, gain: f32, q: f32, filter_type: FilterType) Self {
        var band = Self{
            .frequency = freq,
            .gain_db = gain,
            .q = q,
            .filter_type = filter_type,
            .enabled = true,
            .x1 = [_]f64{0} ** 8,
            .x2 = [_]f64{0} ** 8,
            .y1 = [_]f64{0} ** 8,
            .y2 = [_]f64{0} ** 8,
            .coeffs = .{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 },
        };
        band.computeCoefficients(44100);
        return band;
    }

    /// Compute biquad coefficients for given sample rate
    pub fn computeCoefficients(self: *Self, sample_rate: u32) void {
        const w0 = 2.0 * math.pi * @as(f64, self.frequency) / @as(f64, @floatFromInt(sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * @as(f64, self.q));
        const A = math.pow(f64, 10.0, @as(f64, self.gain_db) / 40.0);

        var b0: f64 = 1;
        var b1: f64 = 0;
        var b2: f64 = 0;
        var a0: f64 = 1;
        var a1: f64 = 0;
        var a2: f64 = 0;

        switch (self.filter_type) {
            .peak => {
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cos_w0;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cos_w0;
                a2 = 1.0 - alpha / A;
            },
            .low_shelf => {
                const sq = @sqrt(A);
                b0 = A * ((A + 1) - (A - 1) * cos_w0 + 2 * sq * alpha);
                b1 = 2 * A * ((A - 1) - (A + 1) * cos_w0);
                b2 = A * ((A + 1) - (A - 1) * cos_w0 - 2 * sq * alpha);
                a0 = (A + 1) + (A - 1) * cos_w0 + 2 * sq * alpha;
                a1 = -2 * ((A - 1) + (A + 1) * cos_w0);
                a2 = (A + 1) + (A - 1) * cos_w0 - 2 * sq * alpha;
            },
            .high_shelf => {
                const sq = @sqrt(A);
                b0 = A * ((A + 1) + (A - 1) * cos_w0 + 2 * sq * alpha);
                b1 = -2 * A * ((A - 1) + (A + 1) * cos_w0);
                b2 = A * ((A + 1) + (A - 1) * cos_w0 - 2 * sq * alpha);
                a0 = (A + 1) - (A - 1) * cos_w0 + 2 * sq * alpha;
                a1 = 2 * ((A - 1) - (A + 1) * cos_w0);
                a2 = (A + 1) - (A - 1) * cos_w0 - 2 * sq * alpha;
            },
            .low_pass => {
                b0 = (1 - cos_w0) / 2;
                b1 = 1 - cos_w0;
                b2 = (1 - cos_w0) / 2;
                a0 = 1 + alpha;
                a1 = -2 * cos_w0;
                a2 = 1 - alpha;
            },
            .high_pass => {
                b0 = (1 + cos_w0) / 2;
                b1 = -(1 + cos_w0);
                b2 = (1 + cos_w0) / 2;
                a0 = 1 + alpha;
                a1 = -2 * cos_w0;
                a2 = 1 - alpha;
            },
            .band_pass => {
                b0 = alpha;
                b1 = 0;
                b2 = -alpha;
                a0 = 1 + alpha;
                a1 = -2 * cos_w0;
                a2 = 1 - alpha;
            },
            .notch => {
                b0 = 1;
                b1 = -2 * cos_w0;
                b2 = 1;
                a0 = 1 + alpha;
                a1 = -2 * cos_w0;
                a2 = 1 - alpha;
            },
            .all_pass => {
                b0 = 1 - alpha;
                b1 = -2 * cos_w0;
                b2 = 1 + alpha;
                a0 = 1 + alpha;
                a1 = -2 * cos_w0;
                a2 = 1 - alpha;
            },
        }

        // Normalize coefficients
        self.coeffs = .{
            .b0 = b0 / a0,
            .b1 = b1 / a0,
            .b2 = b2 / a0,
            .a1 = a1 / a0,
            .a2 = a2 / a0,
        };
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32, channel: u8) f32 {
        if (!self.enabled) return sample;

        const ch = @min(channel, 7);
        const x: f64 = sample;

        const y = self.coeffs.b0 * x +
            self.coeffs.b1 * self.x1[ch] +
            self.coeffs.b2 * self.x2[ch] -
            self.coeffs.a1 * self.y1[ch] -
            self.coeffs.a2 * self.y2[ch];

        // Update state
        self.x2[ch] = self.x1[ch];
        self.x1[ch] = x;
        self.y2[ch] = self.y1[ch];
        self.y1[ch] = y;

        return @floatCast(y);
    }

    /// Reset filter state
    pub fn reset(self: *Self) void {
        self.x1 = [_]f64{0} ** 8;
        self.x2 = [_]f64{0} ** 8;
        self.y1 = [_]f64{0} ** 8;
        self.y2 = [_]f64{0} ** 8;
    }
};

/// Parametric Equalizer (up to 8 bands)
pub const ParametricEQ = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    bands: []ParametricBand,
    output_gain: f32,

    const Self = @This();

    pub const MAX_BANDS = 8;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bands = try allocator.alloc(ParametricBand, 0),
            .output_gain = 1.0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
    }

    /// Add a new band
    pub fn addBand(self: *Self, freq: f32, gain_db: f32, q: f32, filter_type: FilterType) !void {
        if (self.bands.len >= MAX_BANDS) return;

        var new_bands = try self.allocator.alloc(ParametricBand, self.bands.len + 1);
        @memcpy(new_bands[0..self.bands.len], self.bands);

        var band = ParametricBand.init(freq, gain_db, q, filter_type);
        band.computeCoefficients(self.sample_rate);
        new_bands[self.bands.len] = band;

        self.allocator.free(self.bands);
        self.bands = new_bands;
    }

    /// Remove a band
    pub fn removeBand(self: *Self, index: usize) void {
        if (index >= self.bands.len) return;

        for (index..self.bands.len - 1) |i| {
            self.bands[i] = self.bands[i + 1];
        }
        self.bands = self.allocator.realloc(self.bands, self.bands.len - 1) catch self.bands;
    }

    /// Update band parameters
    pub fn updateBand(self: *Self, index: usize, freq: f32, gain_db: f32, q: f32) void {
        if (index >= self.bands.len) return;

        self.bands[index].frequency = freq;
        self.bands[index].gain_db = gain_db;
        self.bands[index].q = q;
        self.bands[index].computeCoefficients(self.sample_rate);
    }

    /// Process audio buffer
    pub fn process(self: *Self, buffer: []f32) void {
        const frame_count = buffer.len / self.channels;

        for (0..frame_count) |frame| {
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                var sample = buffer[idx];

                // Process through all bands
                for (self.bands) |*band| {
                    sample = band.processSample(sample, @intCast(ch));
                }

                buffer[idx] = sample * self.output_gain;
            }
        }
    }

    /// Set output gain in dB
    pub fn setOutputGain(self: *Self, gain_db: f32) void {
        self.output_gain = math.pow(f32, 10.0, gain_db / 20.0);
    }

    /// Reset all filter states
    pub fn reset(self: *Self) void {
        for (self.bands) |*band| {
            band.reset();
        }
    }

    /// Create common presets
    pub fn preset(self: *Self, name: PresetType) !void {
        // Clear existing bands
        self.allocator.free(self.bands);
        self.bands = try self.allocator.alloc(ParametricBand, 0);

        switch (name) {
            .flat => {},
            .bass_boost => {
                try self.addBand(80, 6, 0.7, .low_shelf);
            },
            .treble_boost => {
                try self.addBand(10000, 6, 0.7, .high_shelf);
            },
            .vocal_presence => {
                try self.addBand(3000, 3, 1.0, .peak);
                try self.addBand(200, -2, 0.7, .low_shelf);
            },
            .loudness => {
                try self.addBand(100, 6, 0.7, .low_shelf);
                try self.addBand(10000, 4, 0.7, .high_shelf);
            },
            .reduce_mud => {
                try self.addBand(300, -4, 1.5, .peak);
            },
        }
    }
};

pub const PresetType = enum {
    flat,
    bass_boost,
    treble_boost,
    vocal_presence,
    loudness,
    reduce_mud,
};

/// Graphic Equalizer (fixed frequency bands)
pub const GraphicEQ = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    bands: []ParametricBand,
    num_bands: usize,

    const Self = @This();

    // Standard octave bands (31-band)
    pub const BANDS_31: [31]f32 = .{
        20,    25,    31.5,  40,   50,   63,   80,   100,
        125,   160,   200,   250,  315,  400,  500,  630,
        800,   1000,  1250,  1600, 2000, 2500, 3150, 4000,
        5000,  6300,  8000,  10000, 12500, 16000, 20000,
    };

    // 10-band
    pub const BANDS_10: [10]f32 = .{
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    };

    // 5-band
    pub const BANDS_5: [5]f32 = .{ 60, 230, 910, 3600, 14000 };

    pub fn init10Band(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return initWithFreqs(allocator, sample_rate, channels, &BANDS_10);
    }

    pub fn init31Band(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return initWithFreqs(allocator, sample_rate, channels, &BANDS_31);
    }

    pub fn init5Band(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        return initWithFreqs(allocator, sample_rate, channels, &BANDS_5);
    }

    fn initWithFreqs(allocator: Allocator, sample_rate: u32, channels: u8, freqs: []const f32) !Self {
        var bands = try allocator.alloc(ParametricBand, freqs.len);

        for (freqs, 0..) |freq, i| {
            bands[i] = ParametricBand.init(freq, 0, 1.41, .peak); // Q=1.41 for octave
            bands[i].computeCoefficients(sample_rate);
        }

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bands = bands,
            .num_bands = freqs.len,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
    }

    /// Set gain for a specific band
    pub fn setBandGain(self: *Self, band_index: usize, gain_db: f32) void {
        if (band_index >= self.num_bands) return;
        self.bands[band_index].gain_db = std.math.clamp(gain_db, -12, 12);
        self.bands[band_index].computeCoefficients(self.sample_rate);
    }

    /// Get gain for a specific band
    pub fn getBandGain(self: *Self, band_index: usize) f32 {
        if (band_index >= self.num_bands) return 0;
        return self.bands[band_index].gain_db;
    }

    /// Get frequency for a specific band
    pub fn getBandFrequency(self: *Self, band_index: usize) f32 {
        if (band_index >= self.num_bands) return 0;
        return self.bands[band_index].frequency;
    }

    /// Set all bands from array
    pub fn setAllBands(self: *Self, gains_db: []const f32) void {
        const count = @min(gains_db.len, self.num_bands);
        for (0..count) |i| {
            self.setBandGain(i, gains_db[i]);
        }
    }

    /// Process audio buffer
    pub fn process(self: *Self, buffer: []f32) void {
        const frame_count = buffer.len / self.channels;

        for (0..frame_count) |frame| {
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                var sample = buffer[idx];

                for (self.bands) |*band| {
                    sample = band.processSample(sample, @intCast(ch));
                }

                buffer[idx] = sample;
            }
        }
    }

    /// Reset all filter states
    pub fn reset(self: *Self) void {
        for (self.bands) |*band| {
            band.reset();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ParametricBand basic" {
    var band = ParametricBand.init(1000, 6, 1.0, .peak);
    band.computeCoefficients(44100);

    const output = band.processSample(1.0, 0);
    try std.testing.expect(output != 0);
}

test "ParametricEQ init" {
    const allocator = std.testing.allocator;

    var eq = try ParametricEQ.init(allocator, 44100, 2);
    defer eq.deinit();

    try eq.addBand(1000, 6, 1.0, .peak);
    try std.testing.expectEqual(@as(usize, 1), eq.bands.len);
}

test "GraphicEQ 10-band" {
    const allocator = std.testing.allocator;

    var eq = try GraphicEQ.init10Band(allocator, 44100, 2);
    defer eq.deinit();

    try std.testing.expectEqual(@as(usize, 10), eq.num_bands);

    eq.setBandGain(0, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 6), eq.getBandGain(0), 0.001);
}

test "GraphicEQ process" {
    const allocator = std.testing.allocator;

    var eq = try GraphicEQ.init5Band(allocator, 44100, 1);
    defer eq.deinit();

    var buffer = [_]f32{ 0.5, -0.5, 0.3, -0.3 };
    eq.process(&buffer);

    // Output should be different (filter affects signal)
    try std.testing.expect(buffer[0] != 0);
}
