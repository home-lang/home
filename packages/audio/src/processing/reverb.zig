// Home Audio Library - Reverb Effect
// Algorithmic reverb using Schroeder/Moorer design

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Reverb presets
pub const ReverbPreset = enum {
    small_room,
    medium_room,
    large_hall,
    cathedral,
    plate,
    spring,

    pub fn getParams(self: ReverbPreset) ReverbParams {
        return switch (self) {
            .small_room => .{
                .room_size = 0.3,
                .damping = 0.7,
                .wet = 0.25,
                .dry = 0.75,
                .width = 0.8,
                .predelay_ms = 5,
            },
            .medium_room => .{
                .room_size = 0.5,
                .damping = 0.5,
                .wet = 0.35,
                .dry = 0.65,
                .width = 1.0,
                .predelay_ms = 15,
            },
            .large_hall => .{
                .room_size = 0.8,
                .damping = 0.3,
                .wet = 0.45,
                .dry = 0.55,
                .width = 1.0,
                .predelay_ms = 30,
            },
            .cathedral => .{
                .room_size = 0.95,
                .damping = 0.2,
                .wet = 0.5,
                .dry = 0.5,
                .width = 1.0,
                .predelay_ms = 50,
            },
            .plate => .{
                .room_size = 0.6,
                .damping = 0.8,
                .wet = 0.4,
                .dry = 0.6,
                .width = 1.0,
                .predelay_ms = 0,
            },
            .spring => .{
                .room_size = 0.4,
                .damping = 0.6,
                .wet = 0.3,
                .dry = 0.7,
                .width = 0.6,
                .predelay_ms = 10,
            },
        };
    }
};

/// Reverb parameters
pub const ReverbParams = struct {
    room_size: f32 = 0.5, // 0.0 to 1.0
    damping: f32 = 0.5, // 0.0 to 1.0
    wet: f32 = 0.33, // Wet signal level
    dry: f32 = 0.67, // Dry signal level
    width: f32 = 1.0, // Stereo width
    predelay_ms: u32 = 20, // Pre-delay in ms
};

/// Comb filter for reverb
const CombFilter = struct {
    buffer: []f32,
    index: usize,
    feedback: f32,
    damp1: f32,
    damp2: f32,
    filter_store: f32,

    fn init(allocator: Allocator, size: usize) !CombFilter {
        const buffer = try allocator.alloc(f32, size);
        @memset(buffer, 0);
        return CombFilter{
            .buffer = buffer,
            .index = 0,
            .feedback = 0.5,
            .damp1 = 0.5,
            .damp2 = 0.5,
            .filter_store = 0,
        };
    }

    fn deinit(self: *CombFilter, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    fn process(self: *CombFilter, input: f32) f32 {
        const output = self.buffer[self.index];

        self.filter_store = output * self.damp2 + self.filter_store * self.damp1;
        self.buffer[self.index] = input + self.filter_store * self.feedback;

        self.index += 1;
        if (self.index >= self.buffer.len) {
            self.index = 0;
        }

        return output;
    }

    fn setFeedback(self: *CombFilter, feedback: f32) void {
        self.feedback = feedback;
    }

    fn setDamp(self: *CombFilter, damp: f32) void {
        self.damp1 = damp;
        self.damp2 = 1.0 - damp;
    }

    fn clear(self: *CombFilter) void {
        @memset(self.buffer, 0);
        self.filter_store = 0;
    }
};

/// Allpass filter for reverb
const AllpassFilter = struct {
    buffer: []f32,
    index: usize,
    feedback: f32,

    fn init(allocator: Allocator, size: usize) !AllpassFilter {
        const buffer = try allocator.alloc(f32, size);
        @memset(buffer, 0);
        return AllpassFilter{
            .buffer = buffer,
            .index = 0,
            .feedback = 0.5,
        };
    }

    fn deinit(self: *AllpassFilter, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    fn process(self: *AllpassFilter, input: f32) f32 {
        const buffered = self.buffer[self.index];
        const output = buffered - input;

        self.buffer[self.index] = input + buffered * self.feedback;

        self.index += 1;
        if (self.index >= self.buffer.len) {
            self.index = 0;
        }

        return output;
    }

    fn clear(self: *AllpassFilter) void {
        @memset(self.buffer, 0);
    }
};

/// Schroeder reverb processor
pub const Reverb = struct {
    allocator: Allocator,
    sample_rate: u32,

    // 8 parallel comb filters (4 per channel)
    comb_l: [4]CombFilter,
    comb_r: [4]CombFilter,

    // 4 series allpass filters (2 per channel)
    allpass_l: [2]AllpassFilter,
    allpass_r: [2]AllpassFilter,

    // Pre-delay buffer
    predelay_l: []f32,
    predelay_r: []f32,
    predelay_index: usize,
    predelay_samples: usize,

    // Parameters
    params: ReverbParams,

    // Gain compensation
    gain: f32,

    const Self = @This();

    /// Comb filter delay times (in samples at 44100Hz)
    const COMB_TUNINGS = [_]usize{ 1116, 1188, 1277, 1356 };
    const ALLPASS_TUNINGS = [_]usize{ 556, 441 };
    const STEREO_SPREAD = 23;

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        const scale = @as(f32, @floatFromInt(sample_rate)) / 44100.0;
        const max_predelay = @as(usize, @intFromFloat(0.1 * @as(f32, @floatFromInt(sample_rate)))); // 100ms max

        var self = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .comb_l = undefined,
            .comb_r = undefined,
            .allpass_l = undefined,
            .allpass_r = undefined,
            .predelay_l = try allocator.alloc(f32, max_predelay),
            .predelay_r = try allocator.alloc(f32, max_predelay),
            .predelay_index = 0,
            .predelay_samples = 0,
            .params = ReverbParams{},
            .gain = 0.015,
        };

        @memset(self.predelay_l, 0);
        @memset(self.predelay_r, 0);

        // Initialize comb filters
        for (0..4) |i| {
            const size_l = @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNINGS[i])) * scale));
            const size_r = @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNINGS[i] + STEREO_SPREAD)) * scale));
            self.comb_l[i] = try CombFilter.init(allocator, size_l);
            self.comb_r[i] = try CombFilter.init(allocator, size_r);
        }

        // Initialize allpass filters
        for (0..2) |i| {
            const size_l = @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNINGS[i])) * scale));
            const size_r = @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNINGS[i] + STEREO_SPREAD)) * scale));
            self.allpass_l[i] = try AllpassFilter.init(allocator, size_l);
            self.allpass_r[i] = try AllpassFilter.init(allocator, size_r);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (&self.comb_l) |*c| c.deinit(self.allocator);
        for (&self.comb_r) |*c| c.deinit(self.allocator);
        for (&self.allpass_l) |*a| a.deinit(self.allocator);
        for (&self.allpass_r) |*a| a.deinit(self.allocator);
        self.allocator.free(self.predelay_l);
        self.allocator.free(self.predelay_r);
    }

    /// Set reverb parameters
    pub fn setParams(self: *Self, params: ReverbParams) void {
        self.params = params;

        // Calculate feedback from room size
        const feedback = 0.28 + params.room_size * 0.7;

        for (&self.comb_l, &self.comb_r) |*cl, *cr| {
            cl.setFeedback(feedback);
            cr.setFeedback(feedback);
            cl.setDamp(params.damping);
            cr.setDamp(params.damping);
        }

        // Calculate predelay in samples
        self.predelay_samples = @as(usize, @intFromFloat(@as(f32, @floatFromInt(params.predelay_ms)) * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0));
        if (self.predelay_samples >= self.predelay_l.len) {
            self.predelay_samples = self.predelay_l.len - 1;
        }
    }

    /// Apply preset
    pub fn setPreset(self: *Self, preset: ReverbPreset) void {
        self.setParams(preset.getParams());
    }

    /// Process stereo audio in-place
    pub fn process(self: *Self, left: []f32, right: []f32) void {
        const wet = self.params.wet * self.gain;
        const dry = self.params.dry;
        const width = self.params.width;
        const wet1 = wet * (width / 2.0 + 0.5);
        const wet2 = wet * (1.0 - width) / 2.0;

        for (0..@min(left.len, right.len)) |i| {
            var in_l = left[i];
            var in_r = right[i];

            // Pre-delay
            if (self.predelay_samples > 0) {
                const delayed_l = self.predelay_l[self.predelay_index];
                const delayed_r = self.predelay_r[self.predelay_index];
                self.predelay_l[self.predelay_index] = in_l;
                self.predelay_r[self.predelay_index] = in_r;
                self.predelay_index = (self.predelay_index + 1) % self.predelay_samples;
                in_l = delayed_l;
                in_r = delayed_r;
            }

            // Sum input for reverb
            const input = (in_l + in_r) * 0.5;

            // Parallel comb filters
            var out_l: f32 = 0;
            var out_r: f32 = 0;
            for (&self.comb_l, &self.comb_r) |*cl, *cr| {
                out_l += cl.process(input);
                out_r += cr.process(input);
            }

            // Series allpass filters
            for (&self.allpass_l) |*a| {
                out_l = a.process(out_l);
            }
            for (&self.allpass_r) |*a| {
                out_r = a.process(out_r);
            }

            // Mix dry and wet
            left[i] = left[i] * dry + out_l * wet1 + out_r * wet2;
            right[i] = right[i] * dry + out_r * wet1 + out_l * wet2;
        }
    }

    /// Process mono audio
    pub fn processMono(self: *Self, samples: []f32) void {
        const wet = self.params.wet * self.gain;
        const dry = self.params.dry;

        for (0..samples.len) |i| {
            var input = samples[i];

            // Pre-delay
            if (self.predelay_samples > 0) {
                const delayed = self.predelay_l[self.predelay_index];
                self.predelay_l[self.predelay_index] = input;
                self.predelay_index = (self.predelay_index + 1) % self.predelay_samples;
                input = delayed;
            }

            // Comb filters
            var output: f32 = 0;
            for (&self.comb_l) |*c| {
                output += c.process(input);
            }

            // Allpass filters
            for (&self.allpass_l) |*a| {
                output = a.process(output);
            }

            samples[i] = samples[i] * dry + output * wet;
        }
    }

    /// Clear reverb tail
    pub fn clear(self: *Self) void {
        for (&self.comb_l, &self.comb_r) |*cl, *cr| {
            cl.clear();
            cr.clear();
        }
        for (&self.allpass_l, &self.allpass_r) |*al, *ar| {
            al.clear();
            ar.clear();
        }
        @memset(self.predelay_l, 0);
        @memset(self.predelay_r, 0);
        self.predelay_index = 0;
    }
};

/// Apply reverb to audio buffer (convenience function)
pub fn applyReverb(
    allocator: Allocator,
    left: []f32,
    right: []f32,
    sample_rate: u32,
    preset: ReverbPreset,
) !void {
    var reverb = try Reverb.init(allocator, sample_rate);
    defer reverb.deinit();
    reverb.setPreset(preset);
    reverb.process(left, right);
}

// ============================================================================
// Tests
// ============================================================================

test "Reverb init" {
    const allocator = std.testing.allocator;

    var reverb = try Reverb.init(allocator, 44100);
    defer reverb.deinit();

    try std.testing.expectEqual(@as(u32, 44100), reverb.sample_rate);
}

test "ReverbPreset params" {
    const small = ReverbPreset.small_room.getParams();
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), small.room_size, 0.01);

    const hall = ReverbPreset.large_hall.getParams();
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), hall.room_size, 0.01);
}

test "Reverb process" {
    const allocator = std.testing.allocator;

    var reverb = try Reverb.init(allocator, 44100);
    defer reverb.deinit();
    reverb.setPreset(.medium_room);

    var left = [_]f32{0.5} ** 100;
    var right = [_]f32{0.5} ** 100;

    reverb.process(&left, &right);

    // Output should be different from input due to reverb
    try std.testing.expect(left[99] != 0.5 or right[99] != 0.5);
}
