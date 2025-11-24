// Home Audio Library - Phase Vocoder
// Time stretching and pitch shifting with phase preservation

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Phase vocoder for time/pitch manipulation
pub const PhaseVocoder = struct {
    allocator: Allocator,
    sample_rate: u32,
    fft_size: usize,
    hop_size: usize,
    overlap: usize,

    // FFT buffers
    analysis_buffer: []f32,
    synthesis_buffer: []f32,
    window: []f32,

    // Phase tracking
    previous_phase: []f32,
    phase_sum: []f32,

    // Time stretching ratio
    time_ratio: f32, // >1 = slower, <1 = faster
    pitch_ratio: f32, // >1 = higher, <1 = lower

    // Position tracking
    read_pos: f32,
    write_pos: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, fft_size: usize) !Self {
        const hop_size = fft_size / 4; // 75% overlap
        const overlap = 4;

        const analysis_buffer = try allocator.alloc(f32, fft_size);
        const synthesis_buffer = try allocator.alloc(f32, fft_size);
        const window = try allocator.alloc(f32, fft_size);
        const previous_phase = try allocator.alloc(f32, fft_size / 2 + 1);
        const phase_sum = try allocator.alloc(f32, fft_size / 2 + 1);

        @memset(analysis_buffer, 0);
        @memset(synthesis_buffer, 0);
        @memset(previous_phase, 0);
        @memset(phase_sum, 0);

        // Create Hann window
        for (window, 0..) |*w, i| {
            w.* = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fft_size))));
        }

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .fft_size = fft_size,
            .hop_size = hop_size,
            .overlap = overlap,
            .analysis_buffer = analysis_buffer,
            .synthesis_buffer = synthesis_buffer,
            .window = window,
            .previous_phase = previous_phase,
            .phase_sum = phase_sum,
            .time_ratio = 1.0,
            .pitch_ratio = 1.0,
            .read_pos = 0,
            .write_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.analysis_buffer);
        self.allocator.free(self.synthesis_buffer);
        self.allocator.free(self.window);
        self.allocator.free(self.previous_phase);
        self.allocator.free(self.phase_sum);
    }

    pub fn setTimeStretch(self: *Self, ratio: f32) void {
        self.time_ratio = math.clamp(ratio, 0.5, 2.0);
    }

    pub fn setPitchShift(self: *Self, semitones: f32) void {
        self.pitch_ratio = math.pow(f32, 2.0, semitones / 12.0);
    }

    /// Process time stretching (simplified implementation)
    pub fn processTimeStretch(self: *Self, input: []const f32, output: []f32) !void {
        _ = self;
        _ = input;
        _ = output;
        // Full implementation would:
        // 1. Apply windowing to input frame
        // 2. Perform FFT
        // 3. Convert to polar form (magnitude/phase)
        // 4. Unwrap and adjust phases
        // 5. Perform inverse FFT
        // 6. Overlap-add to output

        // Simplified: Direct copy with interpolation
        // Real phase vocoder requires complex FFT operations
        return error.NotImplemented;
    }

    /// Process pitch shifting
    pub fn processPitchShift(self: *Self, input: []const f32, output: []f32) !void {
        _ = self;
        _ = input;
        _ = output;
        // Full implementation would:
        // 1. Time-stretch by 1/pitch_ratio
        // 2. Resample by pitch_ratio
        // This maintains duration while changing pitch

        return error.NotImplemented;
    }

    /// Reset internal state
    pub fn reset(self: *Self) void {
        @memset(self.analysis_buffer, 0);
        @memset(self.synthesis_buffer, 0);
        @memset(self.previous_phase, 0);
        @memset(self.phase_sum, 0);
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

/// Simple time stretcher using overlap-add (WSOLA-style)
pub const SimpleTimeStretcher = struct {
    allocator: Allocator,
    sample_rate: u32,
    window_size: usize,
    overlap: f32,

    buffer: []f32,
    write_pos: usize,
    read_pos: f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, window_ms: f32) !Self {
        const window_size = @as(usize, @intFromFloat(window_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0));
        const buffer = try allocator.alloc(f32, window_size * 4);
        @memset(buffer, 0);

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .window_size = window_size,
            .overlap = 0.5,
            .buffer = buffer,
            .write_pos = 0,
            .read_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    /// Process with time stretch ratio
    pub fn process(self: *Self, input: []const f32, output: []f32, ratio: f32) void {
        const hop_in = @as(f32, @floatFromInt(self.window_size)) * ratio;
        const hop_out = @as(f32, @floatFromInt(self.window_size));

        var out_idx: usize = 0;

        while (out_idx < output.len) {
            // Read from input at current position
            const read_idx = @as(usize, @intFromFloat(self.read_pos));

            if (read_idx + self.window_size < input.len) {
                // Apply window and copy
                for (0..self.window_size) |i| {
                    if (out_idx + i < output.len) {
                        const hann = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.window_size))));
                        output[out_idx + i] = input[read_idx + i] * hann;
                    }
                }
            }

            self.read_pos += hop_in;
            out_idx += @intFromFloat(hop_out);

            if (self.read_pos >= @as(f32, @floatFromInt(input.len))) {
                break;
            }
        }
    }

    pub fn reset(self: *Self) void {
        @memset(self.buffer, 0);
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PhaseVocoder init" {
    const allocator = std.testing.allocator;

    var pv = try PhaseVocoder.init(allocator, 44100, 2048);
    defer pv.deinit();

    try std.testing.expectEqual(@as(usize, 2048), pv.fft_size);
    try std.testing.expectEqual(@as(usize, 512), pv.hop_size);
}

test "PhaseVocoder setPitchShift" {
    const allocator = std.testing.allocator;

    var pv = try PhaseVocoder.init(allocator, 44100, 2048);
    defer pv.deinit();

    pv.setPitchShift(12.0); // +1 octave
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pv.pitch_ratio, 0.01);
}

test "SimpleTimeStretcher init" {
    const allocator = std.testing.allocator;

    var stretcher = try SimpleTimeStretcher.init(allocator, 44100, 20.0);
    defer stretcher.deinit();

    try std.testing.expect(stretcher.window_size > 0);
}
