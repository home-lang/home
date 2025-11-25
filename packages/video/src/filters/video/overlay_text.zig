// Home Video Library - Text Overlay Filter
// Text rendering, watermarks, subtitles, timecode burn-in

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;

/// Text alignment
pub const TextAlignment = enum {
    left,
    center,
    right,
    top_left,
    top_center,
    top_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// Font style
pub const FontStyle = enum {
    normal,
    bold,
    italic,
    bold_italic,
};

/// Text color with alpha
pub const TextColor = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn white() TextColor {
        return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    pub fn black() TextColor {
        return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }

    pub fn transparent() TextColor {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
};

/// Text shadow configuration
pub const TextShadow = struct {
    enabled: bool = false,
    offset_x: i32 = 2,
    offset_y: i32 = 2,
    color: TextColor = TextColor.black(),
    blur: u32 = 0,
};

/// Text outline configuration
pub const TextOutline = struct {
    enabled: bool = false,
    width: u32 = 2,
    color: TextColor = TextColor.black(),
};

/// Text box background
pub const TextBox = struct {
    enabled: bool = false,
    color: TextColor = .{ .r = 0, .g = 0, .b = 0, .a = 128 },
    padding: u32 = 10,
};

/// Text overlay configuration
pub const TextOverlayConfig = struct {
    text: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    font_size: u32 = 24,
    font_style: FontStyle = .normal,
    color: TextColor = TextColor.white(),
    alignment: TextAlignment = .top_left,
    shadow: TextShadow = .{},
    outline: TextOutline = .{},
    box: TextBox = .{},
    line_spacing: f32 = 1.2,
    enable_word_wrap: bool = false,
    max_width: ?u32 = null,
};

/// Simple bitmap glyph for text rendering
pub const BitmapGlyph = struct {
    width: u32,
    height: u32,
    advance: u32,
    bearing_x: i32,
    bearing_y: i32,
    bitmap: []const u8,
};

/// Basic bitmap font (placeholder for real font rendering)
pub const BitmapFont = struct {
    size: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, size: u32) Self {
        return .{
            .allocator = allocator,
            .size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    // Placeholder: In real implementation, this would load from font files
    pub fn getGlyph(self: *Self, char: u8) !BitmapGlyph {
        _ = self;

        // Simple 8x8 placeholder glyph
        const width: u32 = 8;
        const height: u32 = 8;

        // For now, return a simple filled rectangle
        // Real implementation would rasterize actual glyphs
        const bitmap = try self.allocator.alloc(u8, width * height);
        @memset(bitmap, if (char >= 32 and char <= 126) 255 else 0);

        return .{
            .width = width,
            .height = height,
            .advance = width + 1,
            .bearing_x = 0,
            .bearing_y = @intCast(height),
            .bitmap = bitmap,
        };
    }

    pub fn measureText(self: *Self, text: []const u8) !struct { width: u32, height: u32 } {
        var total_width: u32 = 0;
        var max_height: u32 = self.size;

        for (text) |char| {
            const glyph = try self.getGlyph(char);
            total_width += glyph.advance;
            max_height = @max(max_height, glyph.height);
            self.allocator.free(glyph.bitmap);
        }

        return .{ .width = total_width, .height = max_height };
    }
};

/// Text overlay filter
pub const TextOverlayFilter = struct {
    allocator: std.mem.Allocator,
    config: TextOverlayConfig,
    font: BitmapFont,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: TextOverlayConfig) !Self {
        const font = BitmapFont.init(allocator, config.font_size);

        return .{
            .allocator = allocator,
            .config = config,
            .font = font,
        };
    }

    pub fn deinit(self: *Self) void {
        self.font.deinit();
    }

    pub fn apply(self: *Self, frame: *VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);

        // Calculate text position based on alignment
        const text_size = try self.font.measureText(self.config.text);
        const pos = self.calculatePosition(frame.width, frame.height, text_size.width, text_size.height);

        // Draw text box background if enabled
        if (self.config.box.enabled) {
            try self.drawTextBox(output, pos.x, pos.y, text_size.width, text_size.height);
        }

        // Draw shadow if enabled
        if (self.config.shadow.enabled) {
            const shadow_x = pos.x + self.config.shadow.offset_x;
            const shadow_y = pos.y + self.config.shadow.offset_y;
            try self.drawText(output, self.config.text, shadow_x, shadow_y, self.config.shadow.color);
        }

        // Draw outline if enabled
        if (self.config.outline.enabled) {
            try self.drawTextOutline(output, self.config.text, pos.x, pos.y);
        }

        // Draw main text
        try self.drawText(output, self.config.text, pos.x, pos.y, self.config.color);

        return output;
    }

    fn calculatePosition(self: *Self, frame_width: u32, frame_height: u32, text_width: u32, text_height: u32) struct { x: i32, y: i32 } {
        const x: i32 = switch (self.config.alignment) {
            .left, .top_left, .bottom_left => self.config.x,
            .center, .top_center, .bottom_center => @as(i32, @intCast(frame_width / 2)) - @as(i32, @intCast(text_width / 2)) + self.config.x,
            .right, .top_right, .bottom_right => @as(i32, @intCast(frame_width)) - @as(i32, @intCast(text_width)) - self.config.x,
        };

        const y: i32 = switch (self.config.alignment) {
            .left, .center, .right => @as(i32, @intCast(frame_height / 2)) - @as(i32, @intCast(text_height / 2)) + self.config.y,
            .top_left, .top_center, .top_right => self.config.y,
            .bottom_left, .bottom_center, .bottom_right => @as(i32, @intCast(frame_height)) - @as(i32, @intCast(text_height)) - self.config.y,
        };

        return .{ .x = x, .y = y };
    }

    fn drawTextBox(self: *Self, frame: *VideoFrame, x: i32, y: i32, width: u32, height: u32) !void {
        const padding = @as(i32, @intCast(self.config.box.padding));
        const box_x1 = std.math.clamp(x - padding, 0, @as(i32, @intCast(frame.width)));
        const box_y1 = std.math.clamp(y - padding, 0, @as(i32, @intCast(frame.height)));
        const box_x2 = std.math.clamp(x + @as(i32, @intCast(width)) + padding, 0, @as(i32, @intCast(frame.width)));
        const box_y2 = std.math.clamp(y + @as(i32, @intCast(height)) + padding, 0, @as(i32, @intCast(frame.height)));

        var dy: i32 = box_y1;
        while (dy < box_y2) : (dy += 1) {
            var dx: i32 = box_x1;
            while (dx < box_x2) : (dx += 1) {
                const pixel_idx = @as(usize, @intCast(dy)) * frame.width + @as(usize, @intCast(dx));
                try self.blendPixel(frame, pixel_idx, self.config.box.color);
            }
        }
    }

    fn drawText(self: *Self, frame: *VideoFrame, text: []const u8, x: i32, y: i32, color: TextColor) !void {
        var cursor_x = x;

        for (text) |char| {
            const glyph = try self.font.getGlyph(char);
            defer self.allocator.free(glyph.bitmap);

            const glyph_x = cursor_x + glyph.bearing_x;
            const glyph_y = y - glyph.bearing_y;

            try self.drawGlyph(frame, glyph, glyph_x, glyph_y, color);

            cursor_x += @intCast(glyph.advance);
        }
    }

    fn drawTextOutline(self: *Self, frame: *VideoFrame, text: []const u8, x: i32, y: i32) !void {
        const outline_width: i32 = @intCast(self.config.outline.width);

        // Draw text in 8 directions for outline effect
        const offsets = [_]struct { dx: i32, dy: i32 }{
            .{ .dx = -outline_width, .dy = -outline_width },
            .{ .dx = 0, .dy = -outline_width },
            .{ .dx = outline_width, .dy = -outline_width },
            .{ .dx = -outline_width, .dy = 0 },
            .{ .dx = outline_width, .dy = 0 },
            .{ .dx = -outline_width, .dy = outline_width },
            .{ .dx = 0, .dy = outline_width },
            .{ .dx = outline_width, .dy = outline_width },
        };

        for (offsets) |offset| {
            try self.drawText(frame, text, x + offset.dx, y + offset.dy, self.config.outline.color);
        }
    }

    fn drawGlyph(self: *Self, frame: *VideoFrame, glyph: BitmapGlyph, x: i32, y: i32, color: TextColor) !void {
        var gy: u32 = 0;
        while (gy < glyph.height) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < glyph.width) : (gx += 1) {
                const pixel_x = x + @as(i32, @intCast(gx));
                const pixel_y = y + @as(i32, @intCast(gy));

                if (pixel_x < 0 or pixel_x >= @as(i32, @intCast(frame.width)) or
                    pixel_y < 0 or pixel_y >= @as(i32, @intCast(frame.height)))
                {
                    continue;
                }

                const glyph_alpha = glyph.bitmap[gy * glyph.width + gx];
                if (glyph_alpha == 0) continue;

                const pixel_idx = @as(usize, @intCast(pixel_y)) * frame.width + @as(usize, @intCast(pixel_x));

                var text_color = color;
                text_color.a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * (@as(f32, @floatFromInt(glyph_alpha)) / 255.0));

                try self.blendPixel(frame, pixel_idx, text_color);
            }
        }
    }

    fn blendPixel(self: *Self, frame: *VideoFrame, pixel_idx: usize, color: TextColor) !void {
        _ = self;

        if (frame.format == .rgba or frame.format == .bgra) {
            const idx = pixel_idx * 4;
            const alpha: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
            const inv_alpha = 1.0 - alpha;

            frame.data[0][idx + 0] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 0])) * inv_alpha + @as(f32, @floatFromInt(color.r)) * alpha);
            frame.data[0][idx + 1] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 1])) * inv_alpha + @as(f32, @floatFromInt(color.g)) * alpha);
            frame.data[0][idx + 2] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 2])) * inv_alpha + @as(f32, @floatFromInt(color.b)) * alpha);
        } else if (frame.format == .rgb24 or frame.format == .bgr24) {
            const idx = pixel_idx * 3;
            const alpha: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
            const inv_alpha = 1.0 - alpha;

            frame.data[0][idx + 0] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 0])) * inv_alpha + @as(f32, @floatFromInt(color.r)) * alpha);
            frame.data[0][idx + 1] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 1])) * inv_alpha + @as(f32, @floatFromInt(color.g)) * alpha);
            frame.data[0][idx + 2] = @intFromFloat(@as(f32, @floatFromInt(frame.data[0][idx + 2])) * inv_alpha + @as(f32, @floatFromInt(color.b)) * alpha);
        }
        // For YUV formats, would need RGB->YUV conversion
    }
};

/// Timecode overlay filter
pub const TimecodeFilter = struct {
    allocator: std.mem.Allocator,
    text_filter: TextOverlayFilter,
    fps: core.Rational,
    start_timecode: core.Timestamp,
    drop_frame: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: TextOverlayConfig, fps: core.Rational, start_timecode: core.Timestamp, drop_frame: bool) !Self {
        const text_filter = try TextOverlayFilter.init(allocator, config);

        return .{
            .allocator = allocator,
            .text_filter = text_filter,
            .fps = fps,
            .start_timecode = start_timecode,
            .drop_frame = drop_frame,
        };
    }

    pub fn deinit(self: *Self) void {
        self.text_filter.deinit();
    }

    pub fn apply(self: *Self, frame: *VideoFrame, timestamp: core.Timestamp) !*VideoFrame {
        const timecode_str = try self.formatTimecode(timestamp);
        defer self.allocator.free(timecode_str);

        // Update text filter config with timecode
        self.text_filter.config.text = timecode_str;

        return try self.text_filter.apply(frame);
    }

    fn formatTimecode(self: *Self, timestamp: core.Timestamp) ![]u8 {
        const ts_us = timestamp.toMicroseconds();
        const fps_f: f64 = @as(f64, @floatFromInt(self.fps.num)) / @as(f64, @floatFromInt(self.fps.den));

        const total_frames: u64 = @intFromFloat(@as(f64, @floatFromInt(ts_us)) / 1_000_000.0 * fps_f);

        const frames_per_second = @as(u64, @intFromFloat(fps_f));
        const frames_per_minute = frames_per_second * 60;
        const frames_per_hour = frames_per_minute * 60;

        const hours = total_frames / frames_per_hour;
        const minutes = (total_frames % frames_per_hour) / frames_per_minute;
        const seconds = (total_frames % frames_per_minute) / frames_per_second;
        const frames = total_frames % frames_per_second;

        const separator: u8 = if (self.drop_frame) ';' else ':';

        return try std.fmt.allocPrint(
            self.allocator,
            "{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}",
            .{ hours, minutes, seconds, separator, frames },
        );
    }
};

/// Subtitle overlay filter
pub const SubtitleFilter = struct {
    allocator: std.mem.Allocator,
    text_filter: TextOverlayFilter,
    subtitles: std.ArrayList(Subtitle),

    const Self = @This();

    pub const Subtitle = struct {
        start_time: core.Timestamp,
        end_time: core.Timestamp,
        text: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: TextOverlayConfig) !Self {
        const text_filter = try TextOverlayFilter.init(allocator, config);

        return .{
            .allocator = allocator,
            .text_filter = text_filter,
            .subtitles = std.ArrayList(Subtitle).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.subtitles.items) |sub| {
            self.allocator.free(sub.text);
        }
        self.subtitles.deinit();
        self.text_filter.deinit();
    }

    pub fn addSubtitle(self: *Self, start_time: core.Timestamp, end_time: core.Timestamp, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        try self.subtitles.append(.{
            .start_time = start_time,
            .end_time = end_time,
            .text = text_copy,
        });
    }

    pub fn apply(self: *Self, frame: *VideoFrame, timestamp: core.Timestamp) !*VideoFrame {
        // Find active subtitle
        for (self.subtitles.items) |sub| {
            if (timestamp.compare(sub.start_time) != .lt and timestamp.compare(sub.end_time) != .gt) {
                self.text_filter.config.text = sub.text;
                return try self.text_filter.apply(frame);
            }
        }

        // No active subtitle, return clone
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);
        return output;
    }
};
