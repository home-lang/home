// Home Audio Library - FFT Spectrum Analyzer
// Fast Fourier Transform for frequency analysis

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Complex number for FFT operations
pub const Complex = struct {
    re: f32,
    im: f32,

    pub fn init(re: f32, im: f32) Complex {
        return .{ .re = re, .im = im };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn magnitude(self: Complex) f32 {
        return @sqrt(self.re * self.re + self.im * self.im);
    }

    pub fn phase(self: Complex) f32 {
        return math.atan2(self.im, self.re);
    }

    pub fn fromPolar(mag: f32, angle: f32) Complex {
        return .{
            .re = mag * @cos(angle),
            .im = mag * @sin(angle),
        };
    }
};

/// Window functions for FFT
pub const WindowType = enum {
    rectangular,
    hann,
    hamming,
    blackman,
    blackman_harris,
    kaiser,
    flat_top,
};

/// Generate window function
pub fn generateWindow(allocator: Allocator, size: usize, window_type: WindowType) ![]f32 {
    const window = try allocator.alloc(f32, size);

    const n = @as(f32, @floatFromInt(size));

    for (0..size) |i| {
        const x = @as(f32, @floatFromInt(i));
        window[i] = switch (window_type) {
            .rectangular => 1.0,
            .hann => 0.5 * (1.0 - @cos(2.0 * math.pi * x / (n - 1))),
            .hamming => 0.54 - 0.46 * @cos(2.0 * math.pi * x / (n - 1)),
            .blackman => 0.42 - 0.5 * @cos(2.0 * math.pi * x / (n - 1)) +
                0.08 * @cos(4.0 * math.pi * x / (n - 1)),
            .blackman_harris => 0.35875 - 0.48829 * @cos(2.0 * math.pi * x / (n - 1)) +
                0.14128 * @cos(4.0 * math.pi * x / (n - 1)) -
                0.01168 * @cos(6.0 * math.pi * x / (n - 1)),
            .kaiser => kaiserWindow(x, n, 8.6),
            .flat_top => 0.21557895 - 0.41663158 * @cos(2.0 * math.pi * x / (n - 1)) +
                0.277263158 * @cos(4.0 * math.pi * x / (n - 1)) -
                0.083578947 * @cos(6.0 * math.pi * x / (n - 1)) +
                0.006947368 * @cos(8.0 * math.pi * x / (n - 1)),
        };
    }

    return window;
}

fn kaiserWindow(n: f32, size: f32, beta: f32) f32 {
    const alpha = (size - 1) / 2.0;
    const x = (n - alpha) / alpha;
    const arg = beta * @sqrt(1.0 - x * x);
    return bessel_i0(arg) / bessel_i0(beta);
}

fn bessel_i0(x: f32) f32 {
    // Modified Bessel function of order 0 (approximation)
    var sum: f32 = 1.0;
    var term: f32 = 1.0;
    const x2 = x * x / 4.0;

    for (1..25) |k| {
        term *= x2 / @as(f32, @floatFromInt(k * k));
        sum += term;
        if (term < 1e-10) break;
    }

    return sum;
}

/// FFT Spectrum Analyzer
pub const SpectrumAnalyzer = struct {
    allocator: Allocator,
    fft_size: usize,
    log2_size: u6,
    sample_rate: u32,

    // Pre-computed twiddle factors
    twiddle: []Complex,

    // Bit reversal lookup
    bit_rev: []usize,

    // Window
    window: []f32,
    window_type: WindowType,

    // Working buffers
    buffer: []Complex,

    const Self = @This();

    /// Create spectrum analyzer with power-of-2 FFT size
    pub fn init(allocator: Allocator, fft_size: usize, sample_rate: u32, window_type: WindowType) !Self {
        // Verify power of 2
        if (@popCount(fft_size) != 1) {
            return error.InvalidFftSize;
        }

        const log2_size: u6 = @intCast(@ctz(fft_size));

        var self = Self{
            .allocator = allocator,
            .fft_size = fft_size,
            .log2_size = log2_size,
            .sample_rate = sample_rate,
            .twiddle = try allocator.alloc(Complex, fft_size / 2),
            .bit_rev = try allocator.alloc(usize, fft_size),
            .window = try generateWindow(allocator, fft_size, window_type),
            .window_type = window_type,
            .buffer = try allocator.alloc(Complex, fft_size),
        };

        // Pre-compute twiddle factors
        for (0..fft_size / 2) |k| {
            const angle = -2.0 * math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(fft_size));
            self.twiddle[k] = Complex.fromPolar(1.0, angle);
        }

        // Pre-compute bit reversal
        for (0..fft_size) |i| {
            self.bit_rev[i] = bitReverse(i, log2_size);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.twiddle);
        self.allocator.free(self.bit_rev);
        self.allocator.free(self.window);
        self.allocator.free(self.buffer);
    }

    /// Perform FFT and return magnitude spectrum (in dB)
    pub fn analyze(self: *Self, input: []const f32) ![]f32 {
        if (input.len < self.fft_size) return error.InsufficientData;

        // Apply window and copy to buffer
        for (0..self.fft_size) |i| {
            self.buffer[self.bit_rev[i]] = Complex.init(input[i] * self.window[i], 0);
        }

        // Cooley-Tukey FFT
        var stage: u6 = 1;
        while (stage <= self.log2_size) : (stage += 1) {
            const m = @as(usize, 1) << stage;
            const m2 = m / 2;
            const step = self.fft_size / m;

            var k: usize = 0;
            while (k < self.fft_size) : (k += m) {
                for (0..m2) |j| {
                    const twiddle_idx = j * step;
                    const t = self.twiddle[twiddle_idx].mul(self.buffer[k + j + m2]);
                    const u = self.buffer[k + j];
                    self.buffer[k + j] = u.add(t);
                    self.buffer[k + j + m2] = u.sub(t);
                }
            }
        }

        // Convert to magnitude spectrum (dB)
        const half_size = self.fft_size / 2;
        const spectrum = try self.allocator.alloc(f32, half_size);

        for (0..half_size) |i| {
            const mag = self.buffer[i].magnitude() / @as(f32, @floatFromInt(self.fft_size));
            spectrum[i] = 20.0 * @log10(@max(mag, 1e-10));
        }

        return spectrum;
    }

    /// Analyze and return linear magnitude (not dB)
    pub fn analyzeLinear(self: *Self, input: []const f32) ![]f32 {
        if (input.len < self.fft_size) return error.InsufficientData;

        // Apply window and copy to buffer
        for (0..self.fft_size) |i| {
            self.buffer[self.bit_rev[i]] = Complex.init(input[i] * self.window[i], 0);
        }

        // Cooley-Tukey FFT
        var stage: u6 = 1;
        while (stage <= self.log2_size) : (stage += 1) {
            const m = @as(usize, 1) << stage;
            const m2 = m / 2;
            const step = self.fft_size / m;

            var k: usize = 0;
            while (k < self.fft_size) : (k += m) {
                for (0..m2) |j| {
                    const twiddle_idx = j * step;
                    const t = self.twiddle[twiddle_idx].mul(self.buffer[k + j + m2]);
                    const u = self.buffer[k + j];
                    self.buffer[k + j] = u.add(t);
                    self.buffer[k + j + m2] = u.sub(t);
                }
            }
        }

        // Convert to magnitude spectrum
        const half_size = self.fft_size / 2;
        const spectrum = try self.allocator.alloc(f32, half_size);

        for (0..half_size) |i| {
            spectrum[i] = self.buffer[i].magnitude() / @as(f32, @floatFromInt(self.fft_size));
        }

        return spectrum;
    }

    /// Get frequency at bin index
    pub fn binToFrequency(self: *const Self, bin: usize) f32 {
        return @as(f32, @floatFromInt(bin)) * @as(f32, @floatFromInt(self.sample_rate)) / @as(f32, @floatFromInt(self.fft_size));
    }

    /// Get bin index for frequency
    pub fn frequencyToBin(self: *const Self, freq: f32) usize {
        const bin = freq * @as(f32, @floatFromInt(self.fft_size)) / @as(f32, @floatFromInt(self.sample_rate));
        return @intFromFloat(@max(0, @min(bin, @as(f32, @floatFromInt(self.fft_size / 2 - 1)))));
    }

    /// Get frequency resolution (Hz per bin)
    pub fn getFrequencyResolution(self: *const Self) f32 {
        return @as(f32, @floatFromInt(self.sample_rate)) / @as(f32, @floatFromInt(self.fft_size));
    }
};

fn bitReverse(n: usize, bits: u6) usize {
    var result: usize = 0;
    var x = n;
    for (0..bits) |_| {
        result = (result << 1) | (x & 1);
        x >>= 1;
    }
    return result;
}

/// Find peak frequency in spectrum
pub fn findPeakFrequency(spectrum: []const f32, sample_rate: u32, fft_size: usize) f32 {
    var max_bin: usize = 0;
    var max_val: f32 = spectrum[0];

    for (1..spectrum.len) |i| {
        if (spectrum[i] > max_val) {
            max_val = spectrum[i];
            max_bin = i;
        }
    }

    // Parabolic interpolation for better precision
    if (max_bin > 0 and max_bin < spectrum.len - 1) {
        const y0 = spectrum[max_bin - 1];
        const y1 = spectrum[max_bin];
        const y2 = spectrum[max_bin + 1];

        const d = (y0 - y2) / (2.0 * (y0 - 2.0 * y1 + y2));
        const refined_bin = @as(f32, @floatFromInt(max_bin)) + d;

        return refined_bin * @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(fft_size));
    }

    return @as(f32, @floatFromInt(max_bin)) * @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(fft_size));
}

/// Compute power spectrum
pub fn powerSpectrum(allocator: Allocator, magnitude: []const f32) ![]f32 {
    const power = try allocator.alloc(f32, magnitude.len);
    for (0..magnitude.len) |i| {
        power[i] = magnitude[i] * magnitude[i];
    }
    return power;
}

// ============================================================================
// Tests
// ============================================================================

test "Complex operations" {
    const a = Complex.init(3, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), a.magnitude(), 0.001);

    const b = Complex.init(1, 2);
    const sum = a.add(b);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), sum.re, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), sum.im, 0.001);
}

test "Window functions" {
    const allocator = std.testing.allocator;

    const hann = try generateWindow(allocator, 64, .hann);
    defer allocator.free(hann);

    // Hann window should be 0 at endpoints
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hann[0], 0.001);
    // And 1.0 at center
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hann[31], 0.01);
}

test "Bit reversal" {
    try std.testing.expectEqual(@as(usize, 0), bitReverse(0, 4));
    try std.testing.expectEqual(@as(usize, 8), bitReverse(1, 4));
    try std.testing.expectEqual(@as(usize, 4), bitReverse(2, 4));
}

test "SpectrumAnalyzer init" {
    const allocator = std.testing.allocator;

    var analyzer = try SpectrumAnalyzer.init(allocator, 1024, 44100, .hann);
    defer analyzer.deinit();

    try std.testing.expectEqual(@as(usize, 1024), analyzer.fft_size);
    try std.testing.expectApproxEqAbs(@as(f32, 43.066), analyzer.getFrequencyResolution(), 0.01);
}
