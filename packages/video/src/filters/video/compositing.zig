// Home Video Library - Compositing Filters
// Alpha channel, overlay, blend modes, fades, transitions

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;

/// Alpha channel operation
pub const AlphaOperation = enum {
    keep,
    discard,
    premultiply,
    unpremultiply,
    extract,
};

/// Alpha channel filter
pub const AlphaFilter = struct {
    operation: AlphaOperation,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, operation: AlphaOperation) Self {
        return .{
            .allocator = allocator,
            .operation = operation,
        };
    }

    pub fn apply(self: *Self, frame: *VideoFrame) !*VideoFrame {
        switch (self.operation) {
            .keep => {
                // Just clone
                const output = try self.allocator.create(VideoFrame);
                output.* = try frame.clone(self.allocator);
                return output;
            },
            .discard => {
                // Convert RGBA/YUVA to RGB/YUV
                return try self.discardAlpha(frame);
            },
            .premultiply => {
                return try self.premultiplyAlpha(frame);
            },
            .unpremultiply => {
                return try self.unpremultiplyAlpha(frame);
            },
            .extract => {
                return try self.extractAlpha(frame);
            },
        }
    }

    fn discardAlpha(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const new_format: core.PixelFormat = switch (frame.format) {
            .rgba => .rgb24,
            .bgra => .bgr24,
            .yuva444p => .yuv444p,
            else => frame.format,
        };

        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, new_format);

        // Copy RGB/YUV planes only
        const pixel_count = frame.width * frame.height;

        if (frame.format == .rgba or frame.format == .bgra) {
            // Packed RGB, skip alpha
            for (0..pixel_count) |i| {
                output.data[0][i * 3 + 0] = frame.data[0][i * 4 + 0];
                output.data[0][i * 3 + 1] = frame.data[0][i * 4 + 1];
                output.data[0][i * 3 + 2] = frame.data[0][i * 4 + 2];
            }
        } else if (frame.format == .yuva444p) {
            // Planar, just copy Y, U, V
            @memcpy(output.data[0][0..pixel_count], frame.data[0][0..pixel_count]);
            @memcpy(output.data[1][0..pixel_count], frame.data[1][0..pixel_count]);
            @memcpy(output.data[2][0..pixel_count], frame.data[2][0..pixel_count]);
        }

        return output;
    }

    fn premultiplyAlpha(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);

        const pixel_count = frame.width * frame.height;

        if (frame.format == .rgba or frame.format == .bgra) {
            for (0..pixel_count) |i| {
                const alpha: f32 = @as(f32, @floatFromInt(frame.data[0][i * 4 + 3])) / 255.0;
                output.data[0][i * 4 + 0] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][i * 4 + 0])) * alpha);
                output.data[0][i * 4 + 1] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][i * 4 + 1])) * alpha);
                output.data[0][i * 4 + 2] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][i * 4 + 2])) * alpha);
            }
        }

        return output;
    }

    fn unpremultiplyAlpha(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);

        const pixel_count = frame.width * frame.height;

        if (frame.format == .rgba or frame.format == .bgra) {
            for (0..pixel_count) |i| {
                const alpha: f32 = @as(f32, @floatFromInt(frame.data[0][i * 4 + 3])) / 255.0;
                if (alpha > 0.0) {
                    output.data[0][i * 4 + 0] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(frame.data[0][i * 4 + 0])) / alpha, 0.0, 255.0));
                    output.data[0][i * 4 + 1] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(frame.data[0][i * 4 + 1])) / alpha, 0.0, 255.0));
                    output.data[0][i * 4 + 2] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(frame.data[0][i * 4 + 2])) / alpha, 0.0, 255.0));
                }
            }
        }

        return output;
    }

    fn extractAlpha(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, .gray);

        const pixel_count = frame.width * frame.height;

        if (frame.format == .rgba or frame.format == .bgra) {
            for (0..pixel_count) |i| {
                output.data[0][i] = frame.data[0][i * 4 + 3];
            }
        } else if (frame.format == .yuva444p) {
            @memcpy(output.data[0][0..pixel_count], frame.data[3][0..pixel_count]);
        } else {
            // No alpha, output white
            @memset(output.data[0][0..pixel_count], 255);
        }

        return output;
    }
};

/// Blend mode
pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    add,
    subtract,
};

/// Overlay/Picture-in-picture filter
pub const OverlayFilter = struct {
    allocator: std.mem.Allocator,
    x: i32,
    y: i32,
    blend_mode: BlendMode = .normal,
    opacity: f32 = 1.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, x: i32, y: i32, blend_mode: BlendMode, opacity: f32) Self {
        return .{
            .allocator = allocator,
            .x = x,
            .y = y,
            .blend_mode = blend_mode,
            .opacity = std.math.clamp(opacity, 0.0, 1.0),
        };
    }

    pub fn apply(self: *Self, background: *const VideoFrame, overlay: *const VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try background.clone(self.allocator);

        // Blit overlay onto background
        const start_x = std.math.clamp(self.x, 0, @as(i32, @intCast(background.width)));
        const start_y = std.math.clamp(self.y, 0, @as(i32, @intCast(background.height)));

        const end_x = std.math.clamp(self.x + @as(i32, @intCast(overlay.width)), 0, @as(i32, @intCast(background.width)));
        const end_y = std.math.clamp(self.y + @as(i32, @intCast(overlay.height)), 0, @as(i32, @intCast(background.height)));

        var dy: i32 = start_y;
        while (dy < end_y) : (dy += 1) {
            var dx: i32 = start_x;
            while (dx < end_x) : (dx += 1) {
                const bg_idx = @as(usize, @intCast(dy)) * background.width + @as(usize, @intCast(dx));
                const ov_idx = @as(usize, @intCast(dy - self.y)) * overlay.width + @as(usize, @intCast(dx - self.x));

                // Blend pixel
                const blended = self.blendPixel(
                    background.data[0][bg_idx],
                    overlay.data[0][ov_idx],
                    self.blend_mode,
                    self.opacity,
                );
                output.data[0][bg_idx] = blended;
            }
        }

        return output;
    }

    fn blendPixel(self: *Self, bg: u8, fg: u8, mode: BlendMode, opacity: f32) u8 {
        _ = self;

        const bg_f: f32 = @as(f32, @floatFromInt(bg)) / 255.0;
        const fg_f: f32 = @as(f32, @floatFromInt(fg)) / 255.0;

        const blended = switch (mode) {
            .normal => fg_f,
            .multiply => bg_f * fg_f,
            .screen => 1.0 - (1.0 - bg_f) * (1.0 - fg_f),
            .overlay => if (bg_f < 0.5)
                2.0 * bg_f * fg_f
            else
                1.0 - 2.0 * (1.0 - bg_f) * (1.0 - fg_f),
            .darken => @min(bg_f, fg_f),
            .lighten => @max(bg_f, fg_f),
            .color_dodge => if (fg_f < 1.0) @min(bg_f / (1.0 - fg_f), 1.0) else 1.0,
            .color_burn => if (fg_f > 0.0) 1.0 - @min((1.0 - bg_f) / fg_f, 1.0) else 0.0,
            .hard_light => if (fg_f < 0.5)
                2.0 * bg_f * fg_f
            else
                1.0 - 2.0 * (1.0 - bg_f) * (1.0 - fg_f),
            .soft_light => if (fg_f < 0.5)
                2.0 * bg_f * fg_f + bg_f * bg_f * (1.0 - 2.0 * fg_f)
            else
                2.0 * bg_f * (1.0 - fg_f) + std.math.sqrt(bg_f) * (2.0 * fg_f - 1.0),
            .difference => @abs(bg_f - fg_f),
            .exclusion => bg_f + fg_f - 2.0 * bg_f * fg_f,
            .add => @min(bg_f + fg_f, 1.0),
            .subtract => @max(bg_f - fg_f, 0.0),
        };

        // Apply opacity
        const result = bg_f * (1.0 - opacity) + blended * opacity;
        return @intFromFloat(std.math.clamp(result * 255.0, 0.0, 255.0));
    }
};

/// Fade filter
pub const FadeFilter = struct {
    allocator: std.mem.Allocator,
    fade_in_duration: f64 = 0.0,  // seconds
    fade_out_duration: f64 = 0.0, // seconds
    total_duration: f64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, fade_in: f64, fade_out: f64, total_duration: f64) Self {
        return .{
            .allocator = allocator,
            .fade_in_duration = fade_in,
            .fade_out_duration = fade_out,
            .total_duration = total_duration,
        };
    }

    pub fn apply(self: *Self, frame: *const VideoFrame, timestamp: f64) !*VideoFrame {
        var opacity: f32 = 1.0;

        // Fade in
        if (timestamp < self.fade_in_duration) {
            opacity = @floatCast(timestamp / self.fade_in_duration);
        }

        // Fade out
        const fade_out_start = self.total_duration - self.fade_out_duration;
        if (timestamp > fade_out_start) {
            opacity = @floatCast((self.total_duration - timestamp) / self.fade_out_duration);
        }

        opacity = std.math.clamp(opacity, 0.0, 1.0);

        // Apply opacity to frame
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame.width, frame.height, frame.format);

        const pixel_count = frame.width * frame.height;

        // Apply to luma
        for (0..pixel_count) |i| {
            output.data[0][i] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][i])) * opacity);
        }

        // Apply to chroma if present
        if (frame.format == .yuv420p or frame.format == .yuv422p or frame.format == .yuv444p) {
            const chroma_size = switch (frame.format) {
                .yuv420p => (frame.width / 2) * (frame.height / 2),
                .yuv422p => (frame.width / 2) * frame.height,
                .yuv444p => frame.width * frame.height,
                else => 0,
            };

            // Fade chroma toward neutral (128)
            for (0..chroma_size) |i| {
                output.data[1][i] = @intFromFloat(128.0 + (@as(f32, @floatFromInt(frame.data[1][i])) - 128.0) * opacity);
                output.data[2][i] = @intFromFloat(128.0 + (@as(f32, @floatFromInt(frame.data[2][i])) - 128.0) * opacity);
            }
        }

        return output;
    }
};

/// Crossfade/dissolve transition
pub const CrossfadeFilter = struct {
    allocator: std.mem.Allocator,
    duration: f64, // seconds

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, duration: f64) Self {
        return .{
            .allocator = allocator,
            .duration = duration,
        };
    }

    pub fn apply(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame, progress: f64) !*VideoFrame {
        const ratio = std.math.clamp(progress / self.duration, 0.0, 1.0);
        const ratio_f32: f32 = @floatCast(ratio);

        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame1.width, frame1.height, frame1.format);

        const pixel_count = frame1.width * frame1.height;

        // Blend luma
        for (0..pixel_count) |i| {
            const val1: f32 = @floatFromInt(frame1.data[0][i]);
            const val2: f32 = @floatFromInt(frame2.data[0][i]);
            output.data[0][i] = @intFromFloat(val1 * (1.0 - ratio_f32) + val2 * ratio_f32);
        }

        // Blend chroma
        if (frame1.format == .yuv420p or frame1.format == .yuv422p or frame1.format == .yuv444p) {
            const chroma_size = switch (frame1.format) {
                .yuv420p => (frame1.width / 2) * (frame1.height / 2),
                .yuv422p => (frame1.width / 2) * frame1.height,
                .yuv444p => frame1.width * frame1.height,
                else => 0,
            };

            for (0..chroma_size) |i| {
                const u1: f32 = @floatFromInt(frame1.data[1][i]);
                const u2: f32 = @floatFromInt(frame2.data[1][i]);
                output.data[1][i] = @intFromFloat(u1 * (1.0 - ratio_f32) + u2 * ratio_f32);

                const v1: f32 = @floatFromInt(frame1.data[2][i]);
                const v2: f32 = @floatFromInt(frame2.data[2][i]);
                output.data[2][i] = @intFromFloat(v1 * (1.0 - ratio_f32) + v2 * ratio_f32);
            }
        }

        return output;
    }
};
