// Home Video Library - Image Overlay Filter
// Logo overlays, watermarks, picture-in-picture with images

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;

/// Image position mode
pub const PositionMode = enum {
    absolute, // Exact x,y coordinates
    relative, // Percentage of frame size (0.0 - 1.0)
    preset, // Predefined positions
};

/// Preset positions for quick placement
pub const PresetPosition = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// Scaling mode for overlay image
pub const ScaleMode = enum {
    none, // Use original size
    fit, // Fit to max dimensions preserving aspect ratio
    fill, // Fill dimensions (may distort)
    cover, // Cover area (may crop)
    percentage, // Scale by percentage
};

/// Image overlay configuration
pub const ImageOverlayConfig = struct {
    // Position
    position_mode: PositionMode = .absolute,
    x: i32 = 0,
    y: i32 = 0,
    rel_x: f32 = 0.0, // For relative positioning (0.0 - 1.0)
    rel_y: f32 = 0.0,
    preset: PresetPosition = .top_left,

    // Scaling
    scale_mode: ScaleMode = .none,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    max_width: ?u32 = null,
    max_height: ?u32 = null,

    // Appearance
    opacity: f32 = 1.0,
    rotation: f32 = 0.0, // Degrees
    blend_mode: BlendMode = .normal,

    // Effects
    enable_shadow: bool = false,
    shadow_offset_x: i32 = 5,
    shadow_offset_y: i32 = 5,
    shadow_blur: u32 = 10,
    shadow_opacity: f32 = 0.5,

    // Border
    border_width: u32 = 0,
    border_color: Color = Color.white(),

    // Margin/Padding
    margin: u32 = 0, // Distance from frame edges when using preset positions
};

/// Simple color structure
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn white() Color {
        return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    pub fn black() Color {
        return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }

    pub fn transparent() Color {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
};

/// Blend modes for compositing
pub const BlendMode = enum {
    normal,
    multiply,
    screen,
    overlay,
    add,
    subtract,
};

/// Image data structure
pub const Image = struct {
    width: u32,
    height: u32,
    format: core.PixelFormat,
    data: []u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat) !Self {
        const bytes_per_pixel: u32 = switch (format) {
            .rgba, .bgra => 4,
            .rgb24, .bgr24 => 3,
            .gray => 1,
            else => return error.UnsupportedFormat,
        };

        const data = try allocator.alloc(u8, width * height * bytes_per_pixel);

        return .{
            .width = width,
            .height = height,
            .format = format,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    pub fn clone(self: *const Self) !Self {
        var new_image = try Self.init(self.allocator, self.width, self.height, self.format);
        @memcpy(new_image.data, self.data);
        return new_image;
    }

    pub fn getPixel(self: *const Self, x: u32, y: u32) Color {
        const idx = (y * self.width + x);

        switch (self.format) {
            .rgba => {
                const i = idx * 4;
                return .{
                    .r = self.data[i],
                    .g = self.data[i + 1],
                    .b = self.data[i + 2],
                    .a = self.data[i + 3],
                };
            },
            .bgra => {
                const i = idx * 4;
                return .{
                    .r = self.data[i + 2],
                    .g = self.data[i + 1],
                    .b = self.data[i],
                    .a = self.data[i + 3],
                };
            },
            .rgb24 => {
                const i = idx * 3;
                return .{
                    .r = self.data[i],
                    .g = self.data[i + 1],
                    .b = self.data[i + 2],
                    .a = 255,
                };
            },
            .bgr24 => {
                const i = idx * 3;
                return .{
                    .r = self.data[i + 2],
                    .g = self.data[i + 1],
                    .b = self.data[i],
                    .a = 255,
                };
            },
            .gray => {
                const val = self.data[idx];
                return .{ .r = val, .g = val, .b = val, .a = 255 };
            },
            else => return Color.transparent(),
        }
    }
};

/// Image overlay filter
pub const ImageOverlayFilter = struct {
    allocator: std.mem.Allocator,
    config: ImageOverlayConfig,
    overlay_image: Image,
    scaled_image: ?Image = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, overlay_image: Image, config: ImageOverlayConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .overlay_image = overlay_image,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.scaled_image) |*img| {
            img.deinit();
        }
    }

    pub fn apply(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);

        // Prepare overlay image (scale if needed)
        const overlay = try self.prepareOverlay();
        defer if (self.config.scale_mode != .none and overlay.data.ptr != self.overlay_image.data.ptr) {
            var img = overlay;
            img.deinit();
        };

        // Calculate position
        const pos = self.calculatePosition(frame.width, frame.height, overlay.width, overlay.height);

        // Draw shadow if enabled
        if (self.config.enable_shadow) {
            try self.drawShadow(output, pos.x, pos.y, overlay.width, overlay.height);
        }

        // Draw border if enabled
        if (self.config.border_width > 0) {
            try self.drawBorder(output, pos.x, pos.y, overlay.width, overlay.height);
        }

        // Composite overlay onto frame
        try self.compositeImage(output, overlay, pos.x, pos.y);

        return output;
    }

    fn prepareOverlay(self: *Self) !Image {
        switch (self.config.scale_mode) {
            .none => return self.overlay_image,
            .percentage => {
                const new_width: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.width)) * self.config.scale_x);
                const new_height: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.height)) * self.config.scale_y);
                return try self.scaleImage(new_width, new_height);
            },
            .fit => {
                if (self.config.max_width == null and self.config.max_height == null) {
                    return self.overlay_image;
                }

                const max_w = self.config.max_width orelse self.overlay_image.width;
                const max_h = self.config.max_height orelse self.overlay_image.height;

                const scale_x = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(self.overlay_image.width));
                const scale_y = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(self.overlay_image.height));
                const scale = @min(scale_x, scale_y);

                if (scale >= 1.0) return self.overlay_image;

                const new_width: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.width)) * scale);
                const new_height: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.height)) * scale);

                return try self.scaleImage(new_width, new_height);
            },
            .fill => {
                const max_w = self.config.max_width orelse self.overlay_image.width;
                const max_h = self.config.max_height orelse self.overlay_image.height;
                return try self.scaleImage(max_w, max_h);
            },
            .cover => {
                if (self.config.max_width == null and self.config.max_height == null) {
                    return self.overlay_image;
                }

                const max_w = self.config.max_width orelse self.overlay_image.width;
                const max_h = self.config.max_height orelse self.overlay_image.height;

                const scale_x = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(self.overlay_image.width));
                const scale_y = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(self.overlay_image.height));
                const scale = @max(scale_x, scale_y);

                const new_width: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.width)) * scale);
                const new_height: u32 = @intFromFloat(@as(f32, @floatFromInt(self.overlay_image.height)) * scale);

                return try self.scaleImage(new_width, new_height);
            },
        }
    }

    fn scaleImage(self: *Self, new_width: u32, new_height: u32) !Image {
        var scaled = try Image.init(self.allocator, new_width, new_height, self.overlay_image.format);

        // Simple nearest-neighbor scaling
        var y: u32 = 0;
        while (y < new_height) : (y += 1) {
            var x: u32 = 0;
            while (x < new_width) : (x += 1) {
                const src_x: u32 = @intFromFloat(@as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(self.overlay_image.width)) / @as(f32, @floatFromInt(new_width)));
                const src_y: u32 = @intFromFloat(@as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(self.overlay_image.height)) / @as(f32, @floatFromInt(new_height)));

                const color = self.overlay_image.getPixel(src_x, src_y);
                self.setPixel(&scaled, x, y, color);
            }
        }

        return scaled;
    }

    fn setPixel(self: *Self, image: *Image, x: u32, y: u32, color: Color) void {
        _ = self;

        const idx = y * image.width + x;

        switch (image.format) {
            .rgba => {
                const i = idx * 4;
                image.data[i] = color.r;
                image.data[i + 1] = color.g;
                image.data[i + 2] = color.b;
                image.data[i + 3] = color.a;
            },
            .bgra => {
                const i = idx * 4;
                image.data[i] = color.b;
                image.data[i + 1] = color.g;
                image.data[i + 2] = color.r;
                image.data[i + 3] = color.a;
            },
            .rgb24 => {
                const i = idx * 3;
                image.data[i] = color.r;
                image.data[i + 1] = color.g;
                image.data[i + 2] = color.b;
            },
            .bgr24 => {
                const i = idx * 3;
                image.data[i] = color.b;
                image.data[i + 1] = color.g;
                image.data[i + 2] = color.r;
            },
            .gray => {
                const luma: u8 = @intFromFloat(0.299 * @as(f32, @floatFromInt(color.r)) + 0.587 * @as(f32, @floatFromInt(color.g)) + 0.114 * @as(f32, @floatFromInt(color.b)));
                image.data[idx] = luma;
            },
            else => {},
        }
    }

    fn calculatePosition(self: *Self, frame_width: u32, frame_height: u32, overlay_width: u32, overlay_height: u32) struct { x: i32, y: i32 } {
        switch (self.config.position_mode) {
            .absolute => {
                return .{ .x = self.config.x, .y = self.config.y };
            },
            .relative => {
                const x: i32 = @intFromFloat(self.config.rel_x * @as(f32, @floatFromInt(frame_width)));
                const y: i32 = @intFromFloat(self.config.rel_y * @as(f32, @floatFromInt(frame_height)));
                return .{ .x = x, .y = y };
            },
            .preset => {
                const margin = @as(i32, @intCast(self.config.margin));

                const x: i32 = switch (self.config.preset) {
                    .top_left, .center_left, .bottom_left => margin,
                    .top_center, .center, .bottom_center => @as(i32, @intCast(frame_width / 2)) - @as(i32, @intCast(overlay_width / 2)),
                    .top_right, .center_right, .bottom_right => @as(i32, @intCast(frame_width)) - @as(i32, @intCast(overlay_width)) - margin,
                };

                const y: i32 = switch (self.config.preset) {
                    .top_left, .top_center, .top_right => margin,
                    .center_left, .center, .center_right => @as(i32, @intCast(frame_height / 2)) - @as(i32, @intCast(overlay_height / 2)),
                    .bottom_left, .bottom_center, .bottom_right => @as(i32, @intCast(frame_height)) - @as(i32, @intCast(overlay_height)) - margin,
                };

                return .{ .x = x, .y = y };
            },
        }
    }

    fn drawShadow(self: *Self, frame: *VideoFrame, x: i32, y: i32, width: u32, height: u32) !void {
        const shadow_x = x + self.config.shadow_offset_x;
        const shadow_y = y + self.config.shadow_offset_y;

        const shadow_color = Color{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = @intFromFloat(255.0 * self.config.shadow_opacity),
        };

        var dy: i32 = shadow_y;
        const end_y = shadow_y + @as(i32, @intCast(height));
        while (dy < end_y) : (dy += 1) {
            if (dy < 0 or dy >= @as(i32, @intCast(frame.height))) continue;

            var dx: i32 = shadow_x;
            const end_x = shadow_x + @as(i32, @intCast(width));
            while (dx < end_x) : (dx += 1) {
                if (dx < 0 or dx >= @as(i32, @intCast(frame.width))) continue;

                const pixel_idx = @as(usize, @intCast(dy)) * frame.width + @as(usize, @intCast(dx));
                try self.blendPixelToFrame(frame, pixel_idx, shadow_color);
            }
        }
    }

    fn drawBorder(self: *Self, frame: *VideoFrame, x: i32, y: i32, width: u32, height: u32) !void {
        const border_width = @as(i32, @intCast(self.config.border_width));

        // Draw four rectangles for border
        var dy: i32 = y - border_width;
        const end_y = y + @as(i32, @intCast(height)) + border_width;
        while (dy < end_y) : (dy += 1) {
            if (dy < 0 or dy >= @as(i32, @intCast(frame.height))) continue;

            var dx: i32 = x - border_width;
            const end_x = x + @as(i32, @intCast(width)) + border_width;
            while (dx < end_x) : (dx += 1) {
                if (dx < 0 or dx >= @as(i32, @intCast(frame.width))) continue;

                // Only draw on border area
                if ((dx < x or dx >= x + @as(i32, @intCast(width))) or
                    (dy < y or dy >= y + @as(i32, @intCast(height))))
                {
                    const pixel_idx = @as(usize, @intCast(dy)) * frame.width + @as(usize, @intCast(dx));
                    try self.blendPixelToFrame(frame, pixel_idx, self.config.border_color);
                }
            }
        }
    }

    fn compositeImage(self: *Self, frame: *VideoFrame, overlay: Image, x: i32, y: i32) !void {
        var oy: u32 = 0;
        while (oy < overlay.height) : (oy += 1) {
            const frame_y = y + @as(i32, @intCast(oy));
            if (frame_y < 0 or frame_y >= @as(i32, @intCast(frame.height))) continue;

            var ox: u32 = 0;
            while (ox < overlay.width) : (ox += 1) {
                const frame_x = x + @as(i32, @intCast(ox));
                if (frame_x < 0 or frame_x >= @as(i32, @intCast(frame.width))) continue;

                const overlay_color = overlay.getPixel(ox, oy);

                // Apply opacity
                var color = overlay_color;
                color.a = @intFromFloat(@as(f32, @floatFromInt(overlay_color.a)) * self.config.opacity);

                const pixel_idx = @as(usize, @intCast(frame_y)) * frame.width + @as(usize, @intCast(frame_x));
                try self.blendPixelToFrame(frame, pixel_idx, color);
            }
        }
    }

    fn blendPixelToFrame(self: *Self, frame: *VideoFrame, pixel_idx: usize, color: Color) !void {
        if (frame.format == .rgba or frame.format == .bgra) {
            const idx = pixel_idx * 4;
            const alpha: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
            const inv_alpha = 1.0 - alpha;

            const bg_r: f32 = @floatFromInt(frame.data[0][idx + 0]);
            const bg_g: f32 = @floatFromInt(frame.data[0][idx + 1]);
            const bg_b: f32 = @floatFromInt(frame.data[0][idx + 2]);

            const fg_r: f32 = @floatFromInt(color.r);
            const fg_g: f32 = @floatFromInt(color.g);
            const fg_b: f32 = @floatFromInt(color.b);

            const r = self.applyBlendMode(bg_r, fg_r, alpha, inv_alpha);
            const g = self.applyBlendMode(bg_g, fg_g, alpha, inv_alpha);
            const b = self.applyBlendMode(bg_b, fg_b, alpha, inv_alpha);

            frame.data[0][idx + 0] = @intFromFloat(std.math.clamp(r, 0.0, 255.0));
            frame.data[0][idx + 1] = @intFromFloat(std.math.clamp(g, 0.0, 255.0));
            frame.data[0][idx + 2] = @intFromFloat(std.math.clamp(b, 0.0, 255.0));
        } else if (frame.format == .rgb24 or frame.format == .bgr24) {
            const idx = pixel_idx * 3;
            const alpha: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
            const inv_alpha = 1.0 - alpha;

            const bg_r: f32 = @floatFromInt(frame.data[0][idx + 0]);
            const bg_g: f32 = @floatFromInt(frame.data[0][idx + 1]);
            const bg_b: f32 = @floatFromInt(frame.data[0][idx + 2]);

            const fg_r: f32 = @floatFromInt(color.r);
            const fg_g: f32 = @floatFromInt(color.g);
            const fg_b: f32 = @floatFromInt(color.b);

            const r = self.applyBlendMode(bg_r, fg_r, alpha, inv_alpha);
            const g = self.applyBlendMode(bg_g, fg_g, alpha, inv_alpha);
            const b = self.applyBlendMode(bg_b, fg_b, alpha, inv_alpha);

            frame.data[0][idx + 0] = @intFromFloat(std.math.clamp(r, 0.0, 255.0));
            frame.data[0][idx + 1] = @intFromFloat(std.math.clamp(g, 0.0, 255.0));
            frame.data[0][idx + 2] = @intFromFloat(std.math.clamp(b, 0.0, 255.0));
        }
    }

    fn applyBlendMode(self: *Self, bg: f32, fg: f32, alpha: f32, inv_alpha: f32) f32 {
        const bg_norm = bg / 255.0;
        const fg_norm = fg / 255.0;

        const blended = switch (self.config.blend_mode) {
            .normal => fg_norm,
            .multiply => bg_norm * fg_norm,
            .screen => 1.0 - (1.0 - bg_norm) * (1.0 - fg_norm),
            .overlay => if (bg_norm < 0.5)
                2.0 * bg_norm * fg_norm
            else
                1.0 - 2.0 * (1.0 - bg_norm) * (1.0 - fg_norm),
            .add => @min(bg_norm + fg_norm, 1.0),
            .subtract => @max(bg_norm - fg_norm, 0.0),
        };

        return (bg_norm * inv_alpha + blended * alpha) * 255.0;
    }
};

/// Watermark filter (convenience wrapper around ImageOverlayFilter)
pub const WatermarkFilter = struct {
    filter: ImageOverlayFilter,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, watermark_image: Image, position: PresetPosition, opacity: f32) !Self {
        const config = ImageOverlayConfig{
            .position_mode = .preset,
            .preset = position,
            .opacity = opacity,
            .margin = 20,
        };

        const filter = try ImageOverlayFilter.init(allocator, watermark_image, config);

        return .{ .filter = filter };
    }

    pub fn deinit(self: *Self) void {
        self.filter.deinit();
    }

    pub fn apply(self: *Self, frame: *VideoFrame) !*VideoFrame {
        return try self.filter.apply(frame);
    }
};
