// Home Video Library - Video Overlay / Burn-in
// Text, timecode, watermark, and logo overlay

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Overlay Types
// ============================================================================

pub const OverlayPosition = struct {
    x: i32, // Negative values = from right/bottom
    y: i32,
    anchor: AnchorPoint = .top_left,
};

pub const AnchorPoint = enum {
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

pub const BlendMode = enum {
    alpha, // Standard alpha blending
    add, // Additive blending
    multiply, // Multiply blending
    screen, // Screen blending
    overlay, // Overlay blending
};

// ============================================================================
// Text Overlay
// ============================================================================

pub const TextStyle = struct {
    font_size: u32 = 32,
    color: Color = Color.white(),
    background_color: ?Color = null,
    background_padding: u8 = 4,
    outline_width: u8 = 0,
    outline_color: Color = Color.black(),
    shadow_offset_x: i8 = 0,
    shadow_offset_y: i8 = 0,
    shadow_color: Color = Color.black(),
    opacity: u8 = 255,
    bold: bool = false,
    italic: bool = false,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn white() Color {
        return .{ .r = 255, .g = 255, .b = 255 };
    }

    pub fn black() Color {
        return .{ .r = 0, .g = 0, .b = 0 };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toYUV(self: Color) struct { y: u8, u: u8, v: u8 } {
        const r_f = @as(f32, @floatFromInt(self.r));
        const g_f = @as(f32, @floatFromInt(self.g));
        const b_f = @as(f32, @floatFromInt(self.b));

        const y = 0.299 * r_f + 0.587 * g_f + 0.114 * b_f;
        const u = -0.147 * r_f - 0.289 * g_f + 0.436 * b_f + 128.0;
        const v = 0.615 * r_f - 0.515 * g_f - 0.100 * b_f + 128.0;

        return .{
            .y = @intFromFloat(std.math.clamp(y, 0, 255)),
            .u = @intFromFloat(std.math.clamp(u, 0, 255)),
            .v = @intFromFloat(std.math.clamp(v, 0, 255)),
        };
    }
};

pub const TextOverlay = struct {
    text: []const u8,
    position: OverlayPosition,
    style: TextStyle,
    blend_mode: BlendMode = .alpha,
    allocator: Allocator,

    pub fn init(allocator: Allocator, text: []const u8, position: OverlayPosition) !TextOverlay {
        return .{
            .text = try allocator.dupe(u8, text),
            .position = position,
            .style = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextOverlay) void {
        self.allocator.free(self.text);
    }

    /// Render text to a simple bitmap (simplified - would use real font rendering)
    pub fn render(self: *const TextOverlay, allocator: Allocator) !SimpleBitmap {
        // Simplified text rendering - each character is 8x16 pixels
        const char_width = 8;
        const char_height = 16;
        const width = @as(u32, @intCast(self.text.len)) * char_width;
        const height = char_height;

        var bitmap = SimpleBitmap.init(allocator, width, height);
        try bitmap.allocate();

        // Fill background if specified
        if (self.style.background_color) |bg| {
            bitmap.fill(bg);
        }

        // Render each character (simplified)
        for (self.text, 0..) |char, i| {
            const x_offset = @as(u32, @intCast(i)) * char_width;
            try self.renderChar(&bitmap, char, x_offset, 0);
        }

        // Apply outline if specified
        if (self.style.outline_width > 0) {
            try bitmap.applyOutline(self.style.outline_color, self.style.outline_width);
        }

        // Apply shadow if specified
        if (self.style.shadow_offset_x != 0 or self.style.shadow_offset_y != 0) {
            try bitmap.applyShadow(
                self.style.shadow_color,
                self.style.shadow_offset_x,
                self.style.shadow_offset_y,
            );
        }

        return bitmap;
    }

    fn renderChar(self: *const TextOverlay, bitmap: *SimpleBitmap, char: u8, x: u32, y: u32) !void {
        // Simplified character rendering using a basic 8x16 font
        const char_patterns = getCharPattern(char);

        for (char_patterns, 0..) |row, dy| {
            for (0..8) |dx| {
                if (row & (@as(u8, 1) << @intCast(7 - dx)) != 0) {
                    const px = x + @as(u32, @intCast(dx));
                    const py = y + @as(u32, @intCast(dy));
                    bitmap.setPixel(px, py, self.style.color);
                }
            }
        }
    }
};

// Simplified 8x16 font patterns (only a few characters)
fn getCharPattern(char: u8) [16]u8 {
    return switch (char) {
        '0' => [16]u8{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00 },
        '1' => [16]u8{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00 },
        '2' => [16]u8{ 0x3C, 0x66, 0x66, 0x06, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x60, 0x60, 0x60, 0x66, 0x7E, 0x00, 0x00 },
        ':' => [16]u8{ 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
        else => [16]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00 },
    };
}

// ============================================================================
// Timecode Overlay
// ============================================================================

pub const TimecodeFormat = enum {
    smpte, // HH:MM:SS:FF
    milliseconds, // HH:MM:SS.mmm
    frames, // Frame number
};

pub const TimecodeOverlay = struct {
    format: TimecodeFormat,
    frame_rate: f32,
    position: OverlayPosition,
    style: TextStyle,
    blend_mode: BlendMode = .alpha,

    pub fn init(frame_rate: f32, position: OverlayPosition) TimecodeOverlay {
        return .{
            .format = .smpte,
            .frame_rate = frame_rate,
            .position = position,
            .style = .{},
        };
    }

    pub fn formatTimecode(
        self: *const TimecodeOverlay,
        frame_number: u64,
        allocator: Allocator,
    ) ![]const u8 {
        return switch (self.format) {
            .smpte => {
                const total_seconds = @as(f32, @floatFromInt(frame_number)) / self.frame_rate;
                const hours = @as(u32, @intFromFloat(total_seconds / 3600));
                const minutes = @as(u32, @intFromFloat(@mod(total_seconds / 60, 60)));
                const seconds = @as(u32, @intFromFloat(@mod(total_seconds, 60)));
                const frames = @as(u32, @intFromFloat(@mod(@as(f32, @floatFromInt(frame_number)), self.frame_rate)));

                return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{
                    hours,
                    minutes,
                    seconds,
                    frames,
                });
            },
            .milliseconds => {
                const total_ms = (@as(f32, @floatFromInt(frame_number)) / self.frame_rate) * 1000.0;
                const hours = @as(u32, @intFromFloat(total_ms / 3600000));
                const minutes = @as(u32, @intFromFloat(@mod(total_ms / 60000, 60)));
                const seconds = @as(u32, @intFromFloat(@mod(total_ms / 1000, 60)));
                const milliseconds = @as(u32, @intFromFloat(@mod(total_ms, 1000)));

                return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
                    hours,
                    minutes,
                    seconds,
                    milliseconds,
                });
            },
            .frames => try std.fmt.allocPrint(allocator, "{d}", .{frame_number}),
        };
    }
};

// ============================================================================
// Image/Logo Overlay
// ============================================================================

pub const ImageOverlay = struct {
    bitmap: SimpleBitmap,
    position: OverlayPosition,
    opacity: u8 = 255,
    blend_mode: BlendMode = .alpha,
    scale: f32 = 1.0,

    pub fn init(bitmap: SimpleBitmap, position: OverlayPosition) ImageOverlay {
        return .{
            .bitmap = bitmap,
            .position = position,
        };
    }

    pub fn deinit(self: *ImageOverlay) void {
        self.bitmap.deinit();
    }
};

// ============================================================================
// Simple Bitmap
// ============================================================================

pub const SimpleBitmap = struct {
    width: u32,
    height: u32,
    data: ?[]u8 = null, // RGBA format
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32) SimpleBitmap {
        return .{
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn allocate(self: *SimpleBitmap) !void {
        const size = self.width * self.height * 4;
        self.data = try self.allocator.alloc(u8, size);
        @memset(self.data.?, 0);
    }

    pub fn deinit(self: *SimpleBitmap) void {
        if (self.data) |data| {
            self.allocator.free(data);
        }
    }

    pub fn setPixel(self: *SimpleBitmap, x: u32, y: u32, color: Color) void {
        if (self.data == null or x >= self.width or y >= self.height) return;

        const idx = (y * self.width + x) * 4;
        self.data.?[idx] = color.r;
        self.data.?[idx + 1] = color.g;
        self.data.?[idx + 2] = color.b;
        self.data.?[idx + 3] = color.a;
    }

    pub fn getPixel(self: *const SimpleBitmap, x: u32, y: u32) ?Color {
        if (self.data == null or x >= self.width or y >= self.height) return null;

        const idx = (y * self.width + x) * 4;
        return Color{
            .r = self.data.?[idx],
            .g = self.data.?[idx + 1],
            .b = self.data.?[idx + 2],
            .a = self.data.?[idx + 3],
        };
    }

    pub fn fill(self: *SimpleBitmap, color: Color) void {
        if (self.data == null) return;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }

    pub fn applyOutline(self: *SimpleBitmap, color: Color, width: u8) !void {
        _ = self;
        _ = color;
        _ = width;
        // Simplified - would dilate the alpha channel
    }

    pub fn applyShadow(self: *SimpleBitmap, color: Color, offset_x: i8, offset_y: i8) !void {
        _ = self;
        _ = color;
        _ = offset_x;
        _ = offset_y;
        // Simplified - would create shadow layer
    }
};

// ============================================================================
// Overlay Compositor
// ============================================================================

pub const OverlayCompositor = struct {
    width: u32,
    height: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32) OverlayCompositor {
        return .{
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Composite overlay onto YUV420 frame
    pub fn compositeOntoYUV(
        self: *const OverlayCompositor,
        frame: []u8,
        overlay_bitmap: *const SimpleBitmap,
        position: OverlayPosition,
        blend_mode: BlendMode,
    ) !void {
        const start_x = self.calculateX(position, overlay_bitmap.width);
        const start_y = self.calculateY(position, overlay_bitmap.height);

        // Composite onto Y plane
        const y_plane = frame[0 .. self.width * self.height];
        try self.compositeLuma(y_plane, overlay_bitmap, start_x, start_y, blend_mode);

        // Composite onto U/V planes (subsampled 4:2:0)
        const uv_width = self.width / 2;
        const uv_height = self.height / 2;
        const u_offset = self.width * self.height;
        const v_offset = u_offset + uv_width * uv_height;

        const u_plane = frame[u_offset .. u_offset + uv_width * uv_height];
        const v_plane = frame[v_offset .. v_offset + uv_width * uv_height];

        try self.compositeChroma(u_plane, v_plane, overlay_bitmap, start_x, start_y, blend_mode);
    }

    fn compositeLuma(
        self: *const OverlayCompositor,
        y_plane: []u8,
        overlay: *const SimpleBitmap,
        start_x: i32,
        start_y: i32,
        blend_mode: BlendMode,
    ) !void {
        for (0..overlay.height) |oy| {
            const y = start_y + @as(i32, @intCast(oy));
            if (y < 0 or y >= self.height) continue;

            for (0..overlay.width) |ox| {
                const x = start_x + @as(i32, @intCast(ox));
                if (x < 0 or x >= self.width) continue;

                const pixel = overlay.getPixel(@intCast(ox), @intCast(oy)) orelse continue;
                const yuv = pixel.toYUV();
                const alpha = @as(f32, @floatFromInt(pixel.a)) / 255.0;

                const idx: usize = @intCast(y * @as(i32, @intCast(self.width)) + x);
                const bg_y = y_plane[idx];

                y_plane[idx] = self.blendValue(bg_y, yuv.y, alpha, blend_mode);
            }
        }
    }

    fn compositeChroma(
        self: *const OverlayCompositor,
        u_plane: []u8,
        v_plane: []u8,
        overlay: *const SimpleBitmap,
        start_x: i32,
        start_y: i32,
        blend_mode: BlendMode,
    ) !void {
        const uv_width = self.width / 2;

        for (0..overlay.height) |oy| {
            const y = start_y + @as(i32, @intCast(oy));
            if (y < 0 or y >= self.height) continue;

            for (0..overlay.width) |ox| {
                const x = start_x + @as(i32, @intCast(ox));
                if (x < 0 or x >= self.width) continue;

                // Subsample to 4:2:0
                const uv_x = @divTrunc(x, 2);
                const uv_y = @divTrunc(y, 2);

                const pixel = overlay.getPixel(@intCast(ox), @intCast(oy)) orelse continue;
                const yuv = pixel.toYUV();
                const alpha = @as(f32, @floatFromInt(pixel.a)) / 255.0;

                const idx: usize = @intCast(uv_y * @as(i32, @intCast(uv_width)) + uv_x);
                const bg_u = u_plane[idx];
                const bg_v = v_plane[idx];

                u_plane[idx] = self.blendValue(bg_u, yuv.u, alpha, blend_mode);
                v_plane[idx] = self.blendValue(bg_v, yuv.v, alpha, blend_mode);
            }
        }
    }

    fn blendValue(self: *const OverlayCompositor, bg: u8, fg: u8, alpha: f32, mode: BlendMode) u8 {
        _ = self;

        const bg_f = @as(f32, @floatFromInt(bg));
        const fg_f = @as(f32, @floatFromInt(fg));

        const result = switch (mode) {
            .alpha => bg_f * (1.0 - alpha) + fg_f * alpha,
            .add => std.math.clamp(bg_f + fg_f * alpha, 0, 255),
            .multiply => (bg_f * fg_f * alpha) / 255.0,
            .screen => 255.0 - ((255.0 - bg_f) * (255.0 - fg_f * alpha) / 255.0),
            .overlay => if (bg_f < 128)
                (2.0 * bg_f * fg_f * alpha) / 255.0
            else
                255.0 - (2.0 * (255.0 - bg_f) * (255.0 - fg_f * alpha) / 255.0),
        };

        return @intFromFloat(std.math.clamp(result, 0, 255));
    }

    fn calculateX(self: *const OverlayCompositor, position: OverlayPosition, overlay_width: u32) i32 {
        const base_x = if (position.x < 0)
            @as(i32, @intCast(self.width)) + position.x - @as(i32, @intCast(overlay_width))
        else
            position.x;

        return switch (position.anchor) {
            .top_center, .center, .bottom_center => base_x - @as(i32, @intCast(overlay_width / 2)),
            .top_right, .center_right, .bottom_right => base_x - @as(i32, @intCast(overlay_width)),
            else => base_x,
        };
    }

    fn calculateY(self: *const OverlayCompositor, position: OverlayPosition, overlay_height: u32) i32 {
        const base_y = if (position.y < 0)
            @as(i32, @intCast(self.height)) + position.y - @as(i32, @intCast(overlay_height))
        else
            position.y;

        return switch (position.anchor) {
            .center_left, .center, .center_right => base_y - @as(i32, @intCast(overlay_height / 2)),
            .bottom_left, .bottom_center, .bottom_right => base_y - @as(i32, @intCast(overlay_height)),
            else => base_y,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Color to YUV conversion" {
    const testing = std.testing;

    const white = Color.white();
    const yuv = white.toYUV();

    // White should be ~235 in Y, 128 in U/V (for limited range)
    try testing.expect(yuv.y > 200);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(yuv.u)), 5);
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(yuv.v)), 5);
}

test "SimpleBitmap pixel operations" {
    const testing = std.testing;

    var bitmap = SimpleBitmap.init(testing.allocator, 10, 10);
    try bitmap.allocate();
    defer bitmap.deinit();

    const red = Color.rgb(255, 0, 0);
    bitmap.setPixel(5, 5, red);

    const pixel = bitmap.getPixel(5, 5);
    try testing.expect(pixel != null);
    try testing.expectEqual(@as(u8, 255), pixel.?.r);
    try testing.expectEqual(@as(u8, 0), pixel.?.g);
}

test "Timecode formatting" {
    const testing = std.testing;

    const tc = TimecodeOverlay.init(25.0, .{ .x = 10, .y = 10 });

    // Frame 0 = 00:00:00:00
    const tc_str = try tc.formatTimecode(0, testing.allocator);
    defer testing.allocator.free(tc_str);

    try testing.expect(std.mem.eql(u8, tc_str, "00:00:00:00"));
}
