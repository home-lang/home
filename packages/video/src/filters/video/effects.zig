// Home Video Library - Effect Filters
// Blur, sharpen, denoise, deinterlace, stabilization

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;

/// Blur type
pub const BlurType = enum {
    box,
    gaussian,
};

/// Blur filter
pub const BlurFilter = struct {
    allocator: std.mem.Allocator,
    blur_type: BlurType,
    radius: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, blur_type: BlurType, radius: u32) Self {
        return .{
            .allocator = allocator,
            .blur_type = blur_type,
            .radius = radius,
        };
    }

    pub fn apply(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        switch (self.blur_type) {
            .box => try self.applyBoxBlur(frame, output),
            .gaussian => try self.applyGaussianBlur(frame, output),
        }

        return output;
    }

    fn applyBoxBlur(self: *Self, input: *const VideoFrame, output: *VideoFrame) !void {
        const radius_i: i32 = @intCast(self.radius);
        const kernel_size = (radius_i * 2 + 1) * (radius_i * 2 + 1);

        // Blur luma plane
        for (0..input.height) |y| {
            for (0..input.width) |x| {
                var sum: u32 = 0;
                var count: u32 = 0;

                var ky: i32 = -radius_i;
                while (ky <= radius_i) : (ky += 1) {
                    var kx: i32 = -radius_i;
                    while (kx <= radius_i) : (kx += 1) {
                        const sample_y: i32 = @as(i32, @intCast(y)) + ky;
                        const sample_x: i32 = @as(i32, @intCast(x)) + kx;

                        if (sample_y >= 0 and sample_y < input.height and
                            sample_x >= 0 and sample_x < input.width)
                        {
                            const idx = @as(usize, @intCast(sample_y)) * input.width + @as(usize, @intCast(sample_x));
                            sum += input.data[0][idx];
                            count += 1;
                        }
                    }
                }

                const out_idx = y * input.width + x;
                output.data[0][out_idx] = @intCast(sum / count);
            }
        }

        _ = kernel_size;
    }

    fn applyGaussianBlur(self: *Self, input: *const VideoFrame, output: *VideoFrame) !void {
        // Simplified Gaussian - use separable 1D convolution
        const radius_i: i32 = @intCast(self.radius);

        // Generate Gaussian kernel
        var kernel = try self.allocator.alloc(f32, self.radius * 2 + 1);
        defer self.allocator.free(kernel);

        const sigma: f32 = @as(f32, @floatFromInt(self.radius)) / 3.0;
        var sum: f32 = 0.0;

        for (0..kernel.len) |i| {
            const x: f32 = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(self.radius));
            kernel[i] = @exp(-(x * x) / (2.0 * sigma * sigma));
            sum += kernel[i];
        }

        // Normalize kernel
        for (kernel) |*k| {
            k.* /= sum;
        }

        // Horizontal pass
        var temp = try self.allocator.alloc(u8, input.width * input.height);
        defer self.allocator.free(temp);

        for (0..input.height) |y| {
            for (0..input.width) |x| {
                var weighted_sum: f32 = 0.0;

                for (0..kernel.len) |i| {
                    const offset: i32 = @as(i32, @intCast(i)) - radius_i;
                    const sample_x: i32 = @as(i32, @intCast(x)) + offset;

                    if (sample_x >= 0 and sample_x < input.width) {
                        const idx = y * input.width + @as(usize, @intCast(sample_x));
                        weighted_sum += @as(f32, @floatFromInt(input.data[0][idx])) * kernel[i];
                    }
                }

                temp[y * input.width + x] = @intFromFloat(std.math.clamp(weighted_sum, 0.0, 255.0));
            }
        }

        // Vertical pass
        for (0..input.height) |y| {
            for (0..input.width) |x| {
                var weighted_sum: f32 = 0.0;

                for (0..kernel.len) |i| {
                    const offset: i32 = @as(i32, @intCast(i)) - radius_i;
                    const sample_y: i32 = @as(i32, @intCast(y)) + offset;

                    if (sample_y >= 0 and sample_y < input.height) {
                        const idx = @as(usize, @intCast(sample_y)) * input.width + x;
                        weighted_sum += @as(f32, @floatFromInt(temp[idx])) * kernel[i];
                    }
                }

                const out_idx = y * input.width + x;
                output.data[0][out_idx] = @intFromFloat(std.math.clamp(weighted_sum, 0.0, 255.0));
            }
        }
    }
};

/// Sharpen filter (unsharp mask)
pub const SharpenFilter = struct {
    allocator: std.mem.Allocator,
    amount: f32, // 0.0 - 2.0
    radius: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, amount: f32, radius: u32) Self {
        return .{
            .allocator = allocator,
            .amount = amount,
            .radius = radius,
        };
    }

    pub fn apply(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        // Unsharp mask = Original + Amount * (Original - Blurred)

        // 1. Create blurred version
        var blur = BlurFilter.init(self.allocator, .gaussian, self.radius);
        const blurred = try blur.apply(frame);
        defer {
            blurred.deinit();
            self.allocator.destroy(blurred);
        }

        // 2. Calculate difference and add to original
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        const pixel_count = frame.width * frame.height;

        for (0..pixel_count) |i| {
            const original: f32 = @floatFromInt(frame.data[0][i]);
            const blur_val: f32 = @floatFromInt(blurred.data[0][i]);
            const diff = original - blur_val;
            const sharpened = original + self.amount * diff;
            output.data[0][i] = @intFromFloat(std.math.clamp(sharpened, 0.0, 255.0));
        }

        return output;
    }
};

/// Denoise mode
pub const DenoiseMode = enum {
    spatial,
    temporal,
    combined,
};

/// Denoise filter
pub const DenoiseFilter = struct {
    allocator: std.mem.Allocator,
    mode: DenoiseMode,
    strength: f32, // 0.0 - 1.0
    temporal_frames: std.ArrayList(*VideoFrame), // For temporal denoising

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mode: DenoiseMode, strength: f32) Self {
        return .{
            .allocator = allocator,
            .mode = mode,
            .strength = std.math.clamp(strength, 0.0, 1.0),
            .temporal_frames = std.ArrayList(*VideoFrame).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.temporal_frames.items) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
        self.temporal_frames.deinit();
    }

    pub fn apply(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        switch (self.mode) {
            .spatial => return try self.applySpatialDenoise(frame),
            .temporal => return try self.applyTemporalDenoise(frame),
            .combined => {
                const spatial = try self.applySpatialDenoise(frame);
                defer {
                    spatial.deinit();
                    self.allocator.destroy(spatial);
                }
                return try self.applyTemporalDenoise(spatial);
            },
        }
    }

    fn applySpatialDenoise(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        // Simple bilateral filter approximation
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        const radius: i32 = 2;

        for (0..frame.height) |y| {
            for (0..frame.width) |x| {
                const center_idx = y * frame.width + x;
                const center_val: f32 = @floatFromInt(frame.data[0][center_idx]);

                var weighted_sum: f32 = 0.0;
                var weight_sum: f32 = 0.0;

                var ky: i32 = -radius;
                while (ky <= radius) : (ky += 1) {
                    var kx: i32 = -radius;
                    while (kx <= radius) : (kx += 1) {
                        const sample_y: i32 = @as(i32, @intCast(y)) + ky;
                        const sample_x: i32 = @as(i32, @intCast(x)) + kx;

                        if (sample_y >= 0 and sample_y < frame.height and
                            sample_x >= 0 and sample_x < frame.width)
                        {
                            const idx = @as(usize, @intCast(sample_y)) * frame.width + @as(usize, @intCast(sample_x));
                            const val: f32 = @floatFromInt(frame.data[0][idx]);

                            // Weight based on color distance
                            const color_dist = @abs(val - center_val);
                            const weight = @exp(-color_dist * color_dist * self.strength);

                            weighted_sum += val * weight;
                            weight_sum += weight;
                        }
                    }
                }

                output.data[0][center_idx] = @intFromFloat(weighted_sum / weight_sum);
            }
        }

        return output;
    }

    fn applyTemporalDenoise(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        // Average with previous frames
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        const pixel_count = frame.width * frame.height;

        if (self.temporal_frames.items.len > 0) {
            for (0..pixel_count) |i| {
                var sum: f32 = @floatFromInt(frame.data[0][i]);
                var count: f32 = 1.0;

                for (self.temporal_frames.items) |prev_frame| {
                    sum += @as(f32, @floatFromInt(prev_frame.data[0][i])) * self.strength;
                    count += self.strength;
                }

                output.data[0][i] = @intFromFloat(sum / count);
            }
        } else {
            @memcpy(output.data[0][0..pixel_count], frame.data[0][0..pixel_count]);
        }

        // Store frame for next iteration
        const frame_copy = try self.allocator.create(VideoFrame);
        frame_copy.* = try frame.clone(self.allocator);
        try self.temporal_frames.append(frame_copy);

        // Keep only last 3 frames
        if (self.temporal_frames.items.len > 3) {
            const old = self.temporal_frames.orderedRemove(0);
            old.deinit();
            self.allocator.destroy(old);
        }

        return output;
    }
};

/// Deinterlace mode
pub const DeinterlaceMode = enum {
    bob,        // Double framerate, interpolate fields
    weave,      // Combine fields
    yadif,      // Yet Another Deinterlacing Filter
};

/// Deinterlace filter
pub const DeinterlaceFilter = struct {
    allocator: std.mem.Allocator,
    mode: DeinterlaceMode,
    field_order: FieldOrder,

    const Self = @This();

    pub const FieldOrder = enum {
        top_first,
        bottom_first,
    };

    pub fn init(allocator: std.mem.Allocator, mode: DeinterlaceMode, field_order: FieldOrder) Self {
        return .{
            .allocator = allocator,
            .mode = mode,
            .field_order = field_order,
        };
    }

    pub fn apply(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        switch (self.mode) {
            .bob => return try self.applyBob(frame),
            .weave => return try self.applyWeave(frame),
            .yadif => return try self.applyYadif(frame),
        }
    }

    fn applyBob(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        // Interpolate missing lines
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        for (0..frame.height) |y| {
            const is_field_line = (y % 2 == 0) == (self.field_order == .top_first);

            if (is_field_line) {
                // Copy original line
                const row_start = y * frame.width;
                @memcpy(output.data[0][row_start .. row_start + frame.width], frame.data[0][row_start .. row_start + frame.width]);
            } else {
                // Interpolate from adjacent lines
                for (0..frame.width) |x| {
                    const idx = y * frame.width + x;
                    const above = if (y > 0) frame.data[0][(y - 1) * frame.width + x] else frame.data[0][idx];
                    const below = if (y < frame.height - 1) frame.data[0][(y + 1) * frame.width + x] else frame.data[0][idx];
                    output.data[0][idx] = @intCast((@as(u16, above) + @as(u16, below)) / 2);
                }
            }
        }

        return output;
    }

    fn applyWeave(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        _ = self;
        // Simply copy (weave combines fields from different frames, needs temporal info)
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);
        return output;
    }

    fn applyYadif(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        // Simplified YADIF-style edge-directed interpolation
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        for (0..frame.height) |y| {
            const is_field_line = (y % 2 == 0) == (self.field_order == .top_first);

            if (is_field_line) {
                const row_start = y * frame.width;
                @memcpy(output.data[0][row_start .. row_start + frame.width], frame.data[0][row_start .. row_start + frame.width]);
            } else {
                for (0..frame.width) |x| {
                    const idx = y * frame.width + x;

                    // Edge-directed interpolation
                    const above = if (y > 0) frame.data[0][(y - 1) * frame.width + x] else 128;
                    const below = if (y < frame.height - 1) frame.data[0][(y + 1) * frame.width + x] else 128;

                    // Simple edge detection
                    const edge_strength = @abs(@as(i16, above) - @as(i16, below));

                    if (edge_strength < 10) {
                        // Flat region - simple average
                        output.data[0][idx] = @intCast((@as(u16, above) + @as(u16, below)) / 2);
                    } else {
                        // Edge region - use median-like approach
                        if (x > 0 and x < frame.width - 1) {
                            const left = frame.data[0][idx - 1];
                            const right = frame.data[0][idx + 1];
                            const median = (@as(u16, above) + @as(u16, below) + @as(u16, left) + @as(u16, right)) / 4;
                            output.data[0][idx] = @intCast(median);
                        } else {
                            output.data[0][idx] = @intCast((@as(u16, above) + @as(u16, below)) / 2);
                        }
                    }
                }
            }
        }

        return output;
    }
};

/// Video stabilization (basic motion compensation)
pub const StabilizationFilter = struct {
    allocator: std.mem.Allocator,
    smoothing: f32 = 0.7, // 0.0 - 1.0
    zoom: f32 = 1.1,      // Zoom to hide edges

    // State
    transforms: std.ArrayList(Transform),
    smoothed_transforms: std.ArrayList(Transform),

    const Self = @This();

    const Transform = struct {
        dx: f32,
        dy: f32,
        angle: f32,
    };

    pub fn init(allocator: std.mem.Allocator, smoothing: f32, zoom: f32) Self {
        return .{
            .allocator = allocator,
            .smoothing = smoothing,
            .zoom = zoom,
            .transforms = std.ArrayList(Transform).init(allocator),
            .smoothed_transforms = std.ArrayList(Transform).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.transforms.deinit();
        self.smoothed_transforms.deinit();
    }

    pub fn analyzeMotion(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !void {
        // Simplified motion estimation - would use optical flow in full implementation
        const transform = try self.estimateTransform(frame1, frame2);
        try self.transforms.append(transform);
    }

    pub fn smoothTransforms(self: *Self) !void {
        // Moving average smoothing
        const window_size: usize = 30;

        for (self.transforms.items, 0..) |_, i| {
            var sum_dx: f32 = 0.0;
            var sum_dy: f32 = 0.0;
            var sum_angle: f32 = 0.0;
            var count: f32 = 0.0;

            const start = if (i >= window_size / 2) i - window_size / 2 else 0;
            const end = @min(i + window_size / 2, self.transforms.items.len);

            for (start..end) |j| {
                sum_dx += self.transforms.items[j].dx;
                sum_dy += self.transforms.items[j].dy;
                sum_angle += self.transforms.items[j].angle;
                count += 1.0;
            }

            try self.smoothed_transforms.append(.{
                .dx = sum_dx / count,
                .dy = sum_dy / count,
                .angle = sum_angle / count,
            });
        }
    }

    fn estimateTransform(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !Transform {
        _ = self;
        _ = frame1;
        _ = frame2;

        // Placeholder - would implement block matching or feature tracking
        return Transform{
            .dx = 0.0,
            .dy = 0.0,
            .angle = 0.0,
        };
    }
};
