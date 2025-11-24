// Home Audio Library - SIMD-Optimized FFT
// High-performance FFT using platform-specific SIMD instructions

const std = @import("std");
const math = std.math;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// FFT planner with SIMD optimization
pub const FFT = struct {
    allocator: Allocator,
    size: usize,
    log2_size: u5,

    // Twiddle factors (precomputed)
    cos_table: []f32,
    sin_table: []f32,

    // Bit-reversal table
    bit_reverse: []usize,

    // Scratch buffers
    real_buffer: []f32,
    imag_buffer: []f32,

    const Self = @This();

    pub fn init(allocator: Allocator, size: usize) !Self {
        // Size must be power of 2
        if (!math.isPowerOfTwo(size)) {
            return error.InvalidSize;
        }

        const log2_size: u5 = @intCast(@ctz(size));

        // Allocate twiddle factors
        const cos_table = try allocator.alloc(f32, size / 2);
        const sin_table = try allocator.alloc(f32, size / 2);

        // Precompute twiddle factors
        for (0..size / 2) |k| {
            const angle = -2.0 * math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(size));
            cos_table[k] = @cos(angle);
            sin_table[k] = @sin(angle);
        }

        // Precompute bit-reversal indices
        const bit_reverse = try allocator.alloc(usize, size);
        for (0..size) |i| {
            bit_reverse[i] = reverseBits(i, log2_size);
        }

        const real_buffer = try allocator.alloc(f32, size);
        const imag_buffer = try allocator.alloc(f32, size);

        return Self{
            .allocator = allocator,
            .size = size,
            .log2_size = log2_size,
            .cos_table = cos_table,
            .sin_table = sin_table,
            .bit_reverse = bit_reverse,
            .real_buffer = real_buffer,
            .imag_buffer = imag_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cos_table);
        self.allocator.free(self.sin_table);
        self.allocator.free(self.bit_reverse);
        self.allocator.free(self.real_buffer);
        self.allocator.free(self.imag_buffer);
    }

    /// Forward FFT
    pub fn forward(self: *Self, real: []f32, imag: []f32) void {
        if (real.len != self.size or imag.len != self.size) {
            @panic("FFT: size mismatch");
        }

        // Choose implementation based on platform and size
        if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
            self.forwardAVX2(real, imag);
        } else if (comptime builtin.cpu.arch == .aarch64) {
            self.forwardNEON(real, imag);
        } else {
            self.forwardScalar(real, imag);
        }
    }

    /// Inverse FFT
    pub fn inverse(self: *Self, real: []f32, imag: []f32) void {
        if (real.len != self.size or imag.len != self.size) {
            @panic("FFT: size mismatch");
        }

        // Conjugate input
        for (imag) |*im| {
            im.* = -im.*;
        }

        // Forward FFT
        self.forward(real, imag);

        // Conjugate and scale output
        const scale = 1.0 / @as(f32, @floatFromInt(self.size));
        for (real, imag) |*re, *im| {
            re.* *= scale;
            im.* = -im.* * scale;
        }
    }

    /// Scalar (portable) FFT implementation
    fn forwardScalar(self: *Self, real: []f32, imag: []f32) void {
        // Bit-reversal permutation
        for (0..self.size) |i| {
            const j = self.bit_reverse[i];
            if (i < j) {
                std.mem.swap(f32, &real[i], &real[j]);
                std.mem.swap(f32, &imag[i], &imag[j]);
            }
        }

        // Cooley-Tukey FFT
        var step: usize = 2;
        while (step <= self.size) : (step *= 2) {
            const half_step = step / 2;
            const angle_step = self.size / step;

            var k: usize = 0;
            while (k < self.size) : (k += step) {
                for (0..half_step) |j| {
                    const twiddle_idx = j * angle_step;
                    const wr = self.cos_table[twiddle_idx];
                    const wi = self.sin_table[twiddle_idx];

                    const idx1 = k + j;
                    const idx2 = k + j + half_step;

                    // Complex multiplication: (r2 + i*i2) * (wr + i*wi)
                    const tr = real[idx2] * wr - imag[idx2] * wi;
                    const ti = real[idx2] * wi + imag[idx2] * wr;

                    // Butterfly
                    real[idx2] = real[idx1] - tr;
                    imag[idx2] = imag[idx1] - ti;
                    real[idx1] += tr;
                    imag[idx1] += ti;
                }
            }
        }
    }

    /// AVX2-optimized FFT (x86_64)
    fn forwardAVX2(self: *Self, real: []f32, imag: []f32) void {
        // Bit-reversal permutation
        for (0..self.size) |i| {
            const j = self.bit_reverse[i];
            if (i < j) {
                std.mem.swap(f32, &real[i], &real[j]);
                std.mem.swap(f32, &imag[i], &imag[j]);
            }
        }

        // Cooley-Tukey with SIMD
        var step: usize = 2;
        while (step <= self.size) : (step *= 2) {
            const half_step = step / 2;
            const angle_step = self.size / step;

            var k: usize = 0;
            while (k < self.size) : (k += step) {
                // Process 8 elements at a time with AVX2
                var j: usize = 0;
                while (j + 8 <= half_step) : (j += 8) {
                    // Load twiddle factors into arrays, then create vectors
                    var wr_arr: [8]f32 = undefined;
                    var wi_arr: [8]f32 = undefined;
                    for (0..8) |lane| {
                        const twiddle_idx = (j + lane) * angle_step;
                        wr_arr[lane] = self.cos_table[twiddle_idx];
                        wi_arr[lane] = self.sin_table[twiddle_idx];
                    }
                    const wr_vec: @Vector(8, f32) = wr_arr;
                    const wi_vec: @Vector(8, f32) = wi_arr;

                    const idx1 = k + j;
                    const idx2 = k + j + half_step;

                    // Load data
                    const r1: @Vector(8, f32) = real[idx1..][0..8].*;
                    const im1: @Vector(8, f32) = imag[idx1..][0..8].*;
                    const r2: @Vector(8, f32) = real[idx2..][0..8].*;
                    const im2: @Vector(8, f32) = imag[idx2..][0..8].*;

                    // Complex multiplication
                    const tr = r2 * wr_vec - im2 * wi_vec;
                    const ti = r2 * wi_vec + im2 * wr_vec;

                    // Butterfly
                    real[idx1..][0..8].* = r1 + tr;
                    imag[idx1..][0..8].* = im1 + ti;
                    real[idx2..][0..8].* = r1 - tr;
                    imag[idx2..][0..8].* = im1 - ti;
                }

                // Handle remaining elements
                while (j < half_step) : (j += 1) {
                    const twiddle_idx = j * angle_step;
                    const wr = self.cos_table[twiddle_idx];
                    const wi = self.sin_table[twiddle_idx];

                    const idx1 = k + j;
                    const idx2 = k + j + half_step;

                    const tr = real[idx2] * wr - imag[idx2] * wi;
                    const ti = real[idx2] * wi + imag[idx2] * wr;

                    real[idx2] = real[idx1] - tr;
                    imag[idx2] = imag[idx1] - ti;
                    real[idx1] += tr;
                    imag[idx1] += ti;
                }
            }
        }
    }

    /// NEON-optimized FFT (ARM)
    fn forwardNEON(self: *Self, real: []f32, imag: []f32) void {
        // Bit-reversal permutation
        for (0..self.size) |i| {
            const j = self.bit_reverse[i];
            if (i < j) {
                std.mem.swap(f32, &real[i], &real[j]);
                std.mem.swap(f32, &imag[i], &imag[j]);
            }
        }

        // Cooley-Tukey with NEON (4-wide vectors)
        var step: usize = 2;
        while (step <= self.size) : (step *= 2) {
            const half_step = step / 2;
            const angle_step = self.size / step;

            var k: usize = 0;
            while (k < self.size) : (k += step) {
                // Process 4 elements at a time with NEON
                var j: usize = 0;
                while (j + 4 <= half_step) : (j += 4) {
                    // Load twiddle factors into arrays, then create vectors
                    var wr_arr: [4]f32 = undefined;
                    var wi_arr: [4]f32 = undefined;
                    for (0..4) |lane| {
                        const twiddle_idx = (j + lane) * angle_step;
                        wr_arr[lane] = self.cos_table[twiddle_idx];
                        wi_arr[lane] = self.sin_table[twiddle_idx];
                    }
                    const wr_vec: @Vector(4, f32) = wr_arr;
                    const wi_vec: @Vector(4, f32) = wi_arr;

                    const idx1 = k + j;
                    const idx2 = k + j + half_step;

                    // Load data
                    const r1: @Vector(4, f32) = real[idx1..][0..4].*;
                    const im1: @Vector(4, f32) = imag[idx1..][0..4].*;
                    const r2: @Vector(4, f32) = real[idx2..][0..4].*;
                    const im2: @Vector(4, f32) = imag[idx2..][0..4].*;

                    // Complex multiplication
                    const tr = r2 * wr_vec - im2 * wi_vec;
                    const ti = r2 * wi_vec + im2 * wr_vec;

                    // Butterfly
                    real[idx1..][0..4].* = r1 + tr;
                    imag[idx1..][0..4].* = im1 + ti;
                    real[idx2..][0..4].* = r1 - tr;
                    imag[idx2..][0..4].* = im1 - ti;
                }

                // Handle remaining elements
                while (j < half_step) : (j += 1) {
                    const twiddle_idx = j * angle_step;
                    const wr = self.cos_table[twiddle_idx];
                    const wi = self.sin_table[twiddle_idx];

                    const idx1 = k + j;
                    const idx2 = k + j + half_step;

                    const tr = real[idx2] * wr - imag[idx2] * wi;
                    const ti = real[idx2] * wi + imag[idx2] * wr;

                    real[idx2] = real[idx1] - tr;
                    imag[idx2] = imag[idx1] - ti;
                    real[idx1] += tr;
                    imag[idx1] += ti;
                }
            }
        }
    }

    /// Compute power spectrum (magnitude squared)
    pub fn powerSpectrum(_: *Self, real: []const f32, imag: []const f32, output: []f32) void {
        const len = @min(@min(real.len, imag.len), output.len);

        // Use SIMD if available
        if (comptime builtin.cpu.arch == .x86_64) {
            var i: usize = 0;
            while (i + 8 <= len) : (i += 8) {
                const r: @Vector(8, f32) = real[i..][0..8].*;
                const im: @Vector(8, f32) = imag[i..][0..8].*;
                output[i..][0..8].* = r * r + im * im;
            }
            while (i < len) : (i += 1) {
                output[i] = real[i] * real[i] + imag[i] * imag[i];
            }
        } else {
            for (0..len) |i| {
                output[i] = real[i] * real[i] + imag[i] * imag[i];
            }
        }
    }

    /// Compute magnitude
    pub fn magnitude(self: *Self, real: []const f32, imag: []const f32, output: []f32) void {
        self.powerSpectrum(real, imag, output);

        // Take square root
        for (output) |*mag| {
            mag.* = @sqrt(mag.*);
        }
    }
};

/// Reverse bits for FFT bit-reversal permutation
fn reverseBits(x: usize, bits: u5) usize {
    var result: usize = 0;
    var value = x;
    for (0..bits) |_| {
        result = (result << 1) | (value & 1);
        value >>= 1;
    }
    return result;
}

/// Real FFT (optimized for real-valued input)
pub const RealFFT = struct {
    fft: FFT,

    const Self = @This();

    pub fn init(allocator: Allocator, size: usize) !Self {
        // Use half-size complex FFT for real FFT
        const fft = try FFT.init(allocator, size / 2);
        return Self{ .fft = fft };
    }

    pub fn deinit(self: *Self) void {
        self.fft.deinit();
    }

    /// Forward real FFT
    pub fn forward(self: *Self, input: []const f32, real_out: []f32, imag_out: []f32) void {
        const n = self.fft.size;

        // Pack real input into complex (even indices -> real, odd -> imag)
        for (0..n) |i| {
            self.fft.real_buffer[i] = input[i * 2];
            self.fft.imag_buffer[i] = input[i * 2 + 1];
        }

        // Perform complex FFT
        self.fft.forward(self.fft.real_buffer, self.fft.imag_buffer);

        // Unpack to get full spectrum (exploiting symmetry)
        real_out[0] = self.fft.real_buffer[0] + self.fft.imag_buffer[0];
        imag_out[0] = 0;

        real_out[n] = self.fft.real_buffer[0] - self.fft.imag_buffer[0];
        imag_out[n] = 0;

        for (1..n) |k| {
            const re = (self.fft.real_buffer[k] + self.fft.real_buffer[n - k]) / 2.0;
            const im = (self.fft.imag_buffer[k] - self.fft.imag_buffer[n - k]) / 2.0;

            real_out[k] = re;
            imag_out[k] = im;
            real_out[n + n - k] = re;
            imag_out[n + n - k] = -im;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FFT init" {
    const allocator = std.testing.allocator;

    var fft = try FFT.init(allocator, 256);
    defer fft.deinit();

    try std.testing.expectEqual(@as(usize, 256), fft.size);
    try std.testing.expectEqual(@as(u5, 8), fft.log2_size);
}

test "FFT reverseBits" {
    try std.testing.expectEqual(@as(usize, 0b0000), reverseBits(0b0000, 4));
    try std.testing.expectEqual(@as(usize, 0b1000), reverseBits(0b0001, 4));
    try std.testing.expectEqual(@as(usize, 0b0100), reverseBits(0b0010, 4));
    try std.testing.expectEqual(@as(usize, 0b1111), reverseBits(0b1111, 4));
}

test "FFT forward/inverse" {
    const allocator = std.testing.allocator;

    var fft = try FFT.init(allocator, 64);
    defer fft.deinit();

    // Create test signal: DC + sine wave
    var real: [64]f32 = undefined;
    var imag: [64]f32 = undefined;

    for (0..64) |i| {
        const t = @as(f32, @floatFromInt(i)) / 64.0;
        real[i] = 1.0 + @sin(2.0 * math.pi * 5.0 * t); // DC + 5 Hz
        imag[i] = 0;
    }

    // Forward FFT
    fft.forward(&real, &imag);

    // Check DC component
    try std.testing.expect(real[0] > 60); // Should be ~64

    // Inverse FFT
    fft.inverse(&real, &imag);

    // Check reconstruction
    for (0..64) |i| {
        const t = @as(f32, @floatFromInt(i)) / 64.0;
        const expected = 1.0 + @sin(2.0 * math.pi * 5.0 * t);
        try std.testing.expectApproxEqAbs(expected, real[i], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0), imag[i], 0.01);
    }
}

test "FFT power spectrum" {
    const allocator = std.testing.allocator;

    var fft = try FFT.init(allocator, 128);
    defer fft.deinit();

    var real: [128]f32 = undefined;
    var imag: [128]f32 = undefined;
    var power: [128]f32 = undefined;

    // Create impulse
    @memset(&real, 0);
    @memset(&imag, 0);
    real[0] = 1.0;

    fft.forward(&real, &imag);
    fft.powerSpectrum(&real, &imag, &power);

    // Impulse should have flat spectrum
    for (power) |p| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), p, 0.01);
    }
}
