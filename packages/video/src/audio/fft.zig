// Home Video Library - FFT Implementation
// Fast Fourier Transform for audio processing

const std = @import("std");

/// Complex number for FFT
pub const Complex = struct {
    real: f32,
    imag: f32,

    pub fn init(real: f32, imag: f32) Complex {
        return .{ .real = real, .imag = imag };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .real = a.real + b.real, .imag = a.imag + b.imag };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .real = a.real - b.real, .imag = a.imag - b.imag };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .real = a.real * b.real - a.imag * b.imag,
            .imag = a.real * b.imag + a.imag * b.real,
        };
    }

    pub fn magnitude(self: Complex) f32 {
        return @sqrt(self.real * self.real + self.imag * self.imag);
    }

    pub fn phase(self: Complex) f32 {
        return std.math.atan2(f32, self.imag, self.real);
    }
};

/// Cooley-Tukey FFT algorithm (radix-2 decimation-in-time)
pub fn fft(allocator: std.mem.Allocator, input: []const f32) ![]Complex {
    const n = input.len;

    // Ensure n is power of 2
    if (n == 0 or (n & (n - 1)) != 0) {
        return error.InputSizeMustBePowerOfTwo;
    }

    // Convert real input to complex
    var x = try allocator.alloc(Complex, n);
    errdefer allocator.free(x);

    for (input, 0..) |val, i| {
        x[i] = Complex.init(val, 0.0);
    }

    // Bit-reversal permutation
    var j: usize = 0;
    for (1..n - 1) |i| {
        var k = n >> 1;
        while (j >= k) {
            j -= k;
            k >>= 1;
        }
        j += k;

        if (i < j) {
            const temp = x[i];
            x[i] = x[j];
            x[j] = temp;
        }
    }

    // FFT computation
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const angle = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen = Complex.init(@cos(angle), @sin(angle));

        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex.init(1.0, 0.0);

            for (0..len / 2) |j| {
                const u = x[i + j];
                const v = w.mul(x[i + j + len / 2]);

                x[i + j] = u.add(v);
                x[i + j + len / 2] = u.sub(v);

                w = w.mul(wlen);
            }
        }
    }

    return x;
}

/// Inverse FFT
pub fn ifft(allocator: std.mem.Allocator, input: []const Complex) ![]Complex {
    const n = input.len;

    if (n == 0 or (n & (n - 1)) != 0) {
        return error.InputSizeMustBePowerOfTwo;
    }

    // Conjugate input
    var x = try allocator.alloc(Complex, n);
    errdefer allocator.free(x);

    for (input, 0..) |val, i| {
        x[i] = Complex.init(val.real, -val.imag);
    }

    // Bit-reversal permutation
    var j: usize = 0;
    for (1..n - 1) |i| {
        var k = n >> 1;
        while (j >= k) {
            j -= k;
            k >>= 1;
        }
        j += k;

        if (i < j) {
            const temp = x[i];
            x[i] = x[j];
            x[j] = temp;
        }
    }

    // FFT computation
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const angle = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen = Complex.init(@cos(angle), @sin(angle));

        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex.init(1.0, 0.0);

            for (0..len / 2) |j| {
                const u = x[i + j];
                const v = w.mul(x[i + j + len / 2]);

                x[i + j] = u.add(v);
                x[i + j + len / 2] = u.sub(v);

                w = w.mul(wlen);
            }
        }
    }

    // Conjugate output and scale
    const scale = 1.0 / @as(f32, @floatFromInt(n));
    for (x) |*val| {
        val.* = Complex.init(val.real * scale, -val.imag * scale);
    }

    return x;
}

/// Compute power spectrum (magnitude squared)
pub fn powerSpectrum(allocator: std.mem.Allocator, fft_result: []const Complex) ![]f32 {
    var power = try allocator.alloc(f32, fft_result.len);

    for (fft_result, 0..) |val, i| {
        const mag = val.magnitude();
        power[i] = mag * mag;
    }

    return power;
}

/// Window functions for spectral analysis
pub const WindowFunction = enum {
    rectangular,
    hann,
    hamming,
    blackman,
    bartlett,
};

/// Apply window function to signal
pub fn applyWindow(signal: []f32, window_func: WindowFunction) void {
    const n = signal.len;
    const n_float = @as(f32, @floatFromInt(n));

    for (signal, 0..) |*sample, i| {
        const i_float = @as(f32, @floatFromInt(i));

        const window_value = switch (window_func) {
            .rectangular => 1.0,
            .hann => 0.5 * (1.0 - @cos(2.0 * std.math.pi * i_float / (n_float - 1.0))),
            .hamming => 0.54 - 0.46 * @cos(2.0 * std.math.pi * i_float / (n_float - 1.0)),
            .blackman => 0.42 - 0.5 * @cos(2.0 * std.math.pi * i_float / (n_float - 1.0)) +
                0.08 * @cos(4.0 * std.math.pi * i_float / (n_float - 1.0)),
            .bartlett => 1.0 - @abs(2.0 * i_float / (n_float - 1.0) - 1.0),
        };

        sample.* *= window_value;
    }
}

/// Short-Time Fourier Transform (STFT)
pub const STFT = struct {
    allocator: std.mem.Allocator,
    window_size: usize,
    hop_size: usize,
    window_func: WindowFunction,

    pub fn init(allocator: std.mem.Allocator, window_size: usize, hop_size: usize, window_func: WindowFunction) STFT {
        return .{
            .allocator = allocator,
            .window_size = window_size,
            .hop_size = hop_size,
            .window_func = window_func,
        };
    }

    pub fn compute(self: *STFT, signal: []const f32) ![][]Complex {
        // Calculate number of frames
        const num_frames = (signal.len - self.window_size) / self.hop_size + 1;

        var frames = try self.allocator.alloc([]Complex, num_frames);
        errdefer {
            for (frames) |frame| self.allocator.free(frame);
            self.allocator.free(frames);
        }

        var window_buffer = try self.allocator.alloc(f32, self.window_size);
        defer self.allocator.free(window_buffer);

        for (0..num_frames) |frame_idx| {
            const start = frame_idx * self.hop_size;

            // Extract window
            @memcpy(window_buffer, signal[start..start + self.window_size]);

            // Apply window function
            applyWindow(window_buffer, self.window_func);

            // Compute FFT
            frames[frame_idx] = try fft(self.allocator, window_buffer);
        }

        return frames;
    }

    pub fn deinit(self: *STFT, frames: [][]Complex) void {
        for (frames) |frame| {
            self.allocator.free(frame);
        }
        self.allocator.free(frames);
    }
};

/// Convert frequency bin to Hz
pub fn binToFrequency(bin: usize, sample_rate: u32, fft_size: usize) f32 {
    return @as(f32, @floatFromInt(bin)) * @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(fft_size));
}

/// Convert Hz to frequency bin
pub fn frequencyToBin(frequency: f32, sample_rate: u32, fft_size: usize) usize {
    const bin_float = frequency * @as(f32, @floatFromInt(fft_size)) / @as(f32, @floatFromInt(sample_rate));
    return @intFromFloat(bin_float);
}

/// Mel scale conversion
pub fn hzToMel(hz: f32) f32 {
    return 2595.0 * @log10(1.0 + hz / 700.0);
}

pub fn melToHz(mel: f32) f32 {
    return 700.0 * (std.math.pow(f32, 10.0, mel / 2595.0) - 1.0);
}

/// Generate mel filterbank
pub fn melFilterbank(allocator: std.mem.Allocator, num_filters: usize, fft_size: usize, sample_rate: u32, low_freq: f32, high_freq: f32) ![][]f32 {
    var filterbank = try allocator.alloc([]f32, num_filters);
    errdefer {
        for (filterbank) |filter| allocator.free(filter);
        allocator.free(filterbank);
    }

    // Convert to mel scale
    const low_mel = hzToMel(low_freq);
    const high_mel = hzToMel(high_freq);
    const mel_step = (high_mel - low_mel) / @as(f32, @floatFromInt(num_filters + 1));

    // Calculate center frequencies in mel scale
    var mel_points = try allocator.alloc(f32, num_filters + 2);
    defer allocator.free(mel_points);

    for (0..num_filters + 2) |i| {
        mel_points[i] = low_mel + mel_step * @as(f32, @floatFromInt(i));
    }

    // Convert back to Hz
    var hz_points = try allocator.alloc(f32, num_filters + 2);
    defer allocator.free(hz_points);

    for (mel_points, 0..) |mel, i| {
        hz_points[i] = melToHz(mel);
    }

    // Convert Hz to FFT bin numbers
    var bin_points = try allocator.alloc(usize, num_filters + 2);
    defer allocator.free(bin_points);

    for (hz_points, 0..) |hz, i| {
        bin_points[i] = frequencyToBin(hz, sample_rate, fft_size);
    }

    // Create triangular filters
    for (0..num_filters) |i| {
        filterbank[i] = try allocator.alloc(f32, fft_size / 2 + 1);
        @memset(filterbank[i], 0.0);

        const left = bin_points[i];
        const center = bin_points[i + 1];
        const right = bin_points[i + 2];

        // Rising slope
        for (left..center + 1) |bin| {
            if (bin < filterbank[i].len) {
                const val = @as(f32, @floatFromInt(bin - left)) / @as(f32, @floatFromInt(center - left));
                filterbank[i][bin] = val;
            }
        }

        // Falling slope
        for (center..right + 1) |bin| {
            if (bin < filterbank[i].len) {
                const val = @as(f32, @floatFromInt(right - bin)) / @as(f32, @floatFromInt(right - center));
                filterbank[i][bin] = val;
            }
        }
    }

    return filterbank;
}
