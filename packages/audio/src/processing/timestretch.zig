// Home Audio Library - Time Stretching
// Change tempo without affecting pitch (phase vocoder)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Time stretch quality settings
pub const StretchQuality = enum {
    /// Fast, lower quality (256 sample window)
    fast,
    /// Balanced (1024 sample window)
    medium,
    /// High quality (4096 sample window)
    high,

    pub fn getWindowSize(self: StretchQuality) usize {
        return switch (self) {
            .fast => 256,
            .medium => 1024,
            .high => 4096,
        };
    }

    pub fn getHopSize(self: StretchQuality) usize {
        return self.getWindowSize() / 4;
    }
};

/// Phase vocoder for time stretching
pub const TimeStretcher = struct {
    allocator: Allocator,
    sample_rate: u32,
    quality: StretchQuality,

    // FFT parameters
    window_size: usize,
    hop_size: usize,

    // Window function
    window: []f32,

    // Working buffers
    input_buffer: []f32,
    output_buffer: []f32,
    fft_buffer: []f32,
    phase_buffer: []f32,
    prev_phase: []f32,
    phase_accum: []f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, quality: StretchQuality) !Self {
        const window_size = quality.getWindowSize();
        const hop_size = quality.getHopSize();

        var self = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .quality = quality,
            .window_size = window_size,
            .hop_size = hop_size,
            .window = try allocator.alloc(f32, window_size),
            .input_buffer = try allocator.alloc(f32, window_size),
            .output_buffer = try allocator.alloc(f32, window_size * 2),
            .fft_buffer = try allocator.alloc(f32, window_size),
            .phase_buffer = try allocator.alloc(f32, window_size / 2 + 1),
            .prev_phase = try allocator.alloc(f32, window_size / 2 + 1),
            .phase_accum = try allocator.alloc(f32, window_size / 2 + 1),
        };

        // Generate Hann window
        for (0..window_size) |i| {
            self.window[i] = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(window_size - 1))));
        }

        @memset(self.input_buffer, 0);
        @memset(self.output_buffer, 0);
        @memset(self.prev_phase, 0);
        @memset(self.phase_accum, 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.window);
        self.allocator.free(self.input_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.free(self.fft_buffer);
        self.allocator.free(self.phase_buffer);
        self.allocator.free(self.prev_phase);
        self.allocator.free(self.phase_accum);
    }

    /// Time stretch audio by ratio (>1 = slower, <1 = faster)
    pub fn stretch(self: *Self, input: []const f32, ratio: f32) ![]f32 {
        if (ratio <= 0) return error.InvalidRatio;

        // Calculate output size
        const output_len = @as(usize, @intFromFloat(@as(f32, @floatFromInt(input.len)) * ratio));
        const output = try self.allocator.alloc(f32, output_len);
        @memset(output, 0);

        // Analysis hop size (fixed)
        const analysis_hop = self.hop_size;
        // Synthesis hop size (scaled by ratio)
        const synthesis_hop = @as(usize, @intFromFloat(@as(f32, @floatFromInt(analysis_hop)) * ratio));

        var input_pos: usize = 0;
        var output_pos: usize = 0;

        while (input_pos + self.window_size <= input.len and output_pos + self.window_size <= output_len) {
            // Apply window to input frame
            for (0..self.window_size) |i| {
                self.input_buffer[i] = input[input_pos + i] * self.window[i];
            }

            // Process frame (simple OLA for now, full phase vocoder would use FFT)
            self.processFrame(ratio);

            // Overlap-add to output
            for (0..self.window_size) |i| {
                if (output_pos + i < output_len) {
                    output[output_pos + i] += self.output_buffer[i];
                }
            }

            input_pos += analysis_hop;
            output_pos += synthesis_hop;
        }

        // Normalize by overlap factor
        const overlap_factor = @as(f32, @floatFromInt(self.window_size)) / @as(f32, @floatFromInt(synthesis_hop));
        for (output) |*s| {
            s.* /= overlap_factor;
        }

        return output;
    }

    fn processFrame(self: *Self, ratio: f32) void {
        _ = ratio;

        // Simple overlap-add (preserves timing but not ideal for quality)
        // Full phase vocoder would:
        // 1. FFT the input frame
        // 2. Calculate phase difference from previous frame
        // 3. Accumulate phase for output
        // 4. Reconstruct with modified phase
        // 5. IFFT

        // For now, just apply window for OLA
        for (0..self.window_size) |i| {
            self.output_buffer[i] = self.input_buffer[i] * self.window[i];
        }
    }

    /// Reset internal state
    pub fn reset(self: *Self) void {
        @memset(self.input_buffer, 0);
        @memset(self.output_buffer, 0);
        @memset(self.prev_phase, 0);
        @memset(self.phase_accum, 0);
    }
};

/// WSOLA (Waveform Similarity Overlap-Add) time stretcher
/// Better quality than basic OLA
pub const WsolaStretcher = struct {
    allocator: Allocator,
    sample_rate: u32,

    // Parameters
    window_size: usize,
    seek_range: usize,

    // Window
    window: []f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        const window_size: usize = 1024;
        const seek_range: usize = 256;

        var self = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .window_size = window_size,
            .seek_range = seek_range,
            .window = try allocator.alloc(f32, window_size),
        };

        // Generate Hann window
        for (0..window_size) |i| {
            self.window[i] = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(window_size - 1))));
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.window);
    }

    /// Stretch audio
    pub fn stretch(self: *Self, input: []const f32, ratio: f32) ![]f32 {
        if (ratio <= 0) return error.InvalidRatio;

        const output_len = @as(usize, @intFromFloat(@as(f32, @floatFromInt(input.len)) * ratio));
        const output = try self.allocator.alloc(f32, output_len);
        @memset(output, 0);

        const hop = self.window_size / 2;
        var input_pos: f32 = 0;
        var output_pos: usize = 0;

        while (output_pos + self.window_size <= output_len) {
            const input_idx = @as(usize, @intFromFloat(input_pos));

            if (input_idx + self.window_size > input.len) break;

            // Find best overlap position
            const best_offset = if (output_pos > 0)
                self.findBestOverlap(input, input_idx, output, output_pos)
            else
                0;

            const src_pos = input_idx + best_offset;
            if (src_pos + self.window_size > input.len) break;

            // Overlap-add with window
            for (0..self.window_size) |i| {
                if (output_pos + i < output_len) {
                    output[output_pos + i] += input[src_pos + i] * self.window[i];
                }
            }

            input_pos += @as(f32, @floatFromInt(hop)) / ratio;
            output_pos += hop;
        }

        return output;
    }

    fn findBestOverlap(self: *Self, input: []const f32, input_pos: usize, output: []const f32, output_pos: usize) usize {
        var best_offset: usize = 0;
        var best_corr: f32 = -1;

        const overlap_size = self.window_size / 4;
        const search_start = if (input_pos >= self.seek_range) 0 else self.seek_range - input_pos;
        const search_end = @min(self.seek_range * 2, input.len - input_pos - overlap_size);

        for (search_start..search_end) |offset| {
            var corr: f32 = 0;
            var energy_in: f32 = 0;
            var energy_out: f32 = 0;

            for (0..overlap_size) |i| {
                const in_sample = input[input_pos + offset + i];
                const out_sample = if (output_pos >= overlap_size)
                    output[output_pos - overlap_size + i]
                else
                    0;

                corr += in_sample * out_sample;
                energy_in += in_sample * in_sample;
                energy_out += out_sample * out_sample;
            }

            const norm = @sqrt(energy_in * energy_out);
            const normalized_corr = if (norm > 0) corr / norm else 0;

            if (normalized_corr > best_corr) {
                best_corr = normalized_corr;
                best_offset = offset;
            }
        }

        return best_offset;
    }
};

/// Simple time stretch (convenience function)
pub fn timeStretch(
    allocator: Allocator,
    input: []const f32,
    ratio: f32,
    sample_rate: u32,
    quality: StretchQuality,
) ![]f32 {
    var stretcher = try TimeStretcher.init(allocator, sample_rate, quality);
    defer stretcher.deinit();
    return stretcher.stretch(input, ratio);
}

/// Change tempo by percentage (-50 to +100)
pub fn changeTempo(
    allocator: Allocator,
    input: []const f32,
    percent: f32,
    sample_rate: u32,
) ![]f32 {
    const ratio = 1.0 / (1.0 + percent / 100.0);
    return timeStretch(allocator, input, ratio, sample_rate, .medium);
}

// ============================================================================
// Tests
// ============================================================================

test "TimeStretcher init" {
    const allocator = std.testing.allocator;

    var stretcher = try TimeStretcher.init(allocator, 44100, .medium);
    defer stretcher.deinit();

    try std.testing.expectEqual(@as(usize, 1024), stretcher.window_size);
    try std.testing.expectEqual(@as(usize, 256), stretcher.hop_size);
}

test "StretchQuality parameters" {
    try std.testing.expectEqual(@as(usize, 256), StretchQuality.fast.getWindowSize());
    try std.testing.expectEqual(@as(usize, 1024), StretchQuality.medium.getWindowSize());
    try std.testing.expectEqual(@as(usize, 4096), StretchQuality.high.getWindowSize());
}

test "WsolaStretcher init" {
    const allocator = std.testing.allocator;

    var stretcher = try WsolaStretcher.init(allocator, 44100);
    defer stretcher.deinit();

    try std.testing.expectEqual(@as(usize, 1024), stretcher.window_size);
}
