// Home OS - Graphics Driver Support
// Framebuffer and GPU driver interfaces

const std = @import("std");
const drivers = @import("drivers.zig");

// ============================================================================
// Pixel Formats
// ============================================================================

pub const PixelFormat = enum {
    rgb888,    // 24-bit RGB (8 bits per channel)
    rgba8888,  // 32-bit RGBA (8 bits per channel)
    bgr888,    // 24-bit BGR (8 bits per channel)
    bgra8888,  // 32-bit BGRA (8 bits per channel)
    rgb565,    // 16-bit RGB (5-6-5)
    rgb555,    // 16-bit RGB (5-5-5)
    indexed8,  // 8-bit indexed color
    grayscale8, // 8-bit grayscale

    pub fn bytesPerPixel(self: PixelFormat) u8 {
        return switch (self) {
            .rgb888, .bgr888 => 3,
            .rgba8888, .bgra8888 => 4,
            .rgb565, .rgb555 => 2,
            .indexed8, .grayscale8 => 1,
        };
    }

    pub fn bitsPerPixel(self: PixelFormat) u8 {
        return switch (self) {
            .rgb888, .bgr888 => 24,
            .rgba8888, .bgra8888 => 32,
            .rgb565, .rgb555 => 16,
            .indexed8, .grayscale8 => 8,
        };
    }
};

// ============================================================================
// Color Representation
// ============================================================================

pub const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8 = 0xFF,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 0xFF };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toU32(self: Color, format: PixelFormat) u32 {
        return switch (format) {
            .rgba8888 => (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | self.a,
            .bgra8888 => (@as(u32, self.b) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.r) << 8) | self.a,
            .rgb888 => (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b,
            .bgr888 => (@as(u32, self.b) << 16) | (@as(u32, self.g) << 8) | self.r,
            .rgb565 => (@as(u32, self.r & 0xF8) << 8) | (@as(u32, self.g & 0xFC) << 3) | (self.b >> 3),
            else => 0,
        };
    }

    // Common colors
    pub const BLACK = Color.rgb(0, 0, 0);
    pub const WHITE = Color.rgb(255, 255, 255);
    pub const RED = Color.rgb(255, 0, 0);
    pub const GREEN = Color.rgb(0, 255, 0);
    pub const BLUE = Color.rgb(0, 0, 255);
    pub const YELLOW = Color.rgb(255, 255, 0);
    pub const CYAN = Color.rgb(0, 255, 255);
    pub const MAGENTA = Color.rgb(255, 0, 255);
};

// ============================================================================
// Framebuffer Information
// ============================================================================

pub const FramebufferInfo = struct {
    address: usize,
    width: u32,
    height: u32,
    pitch: u32,        // Bytes per scanline
    bpp: u8,           // Bits per pixel
    format: PixelFormat,

    pub fn size(self: FramebufferInfo) usize {
        return self.pitch * self.height;
    }
};

// ============================================================================
// Framebuffer Driver
// ============================================================================

pub const Framebuffer = struct {
    info: FramebufferInfo,
    buffer: []u8,

    pub fn init(info: FramebufferInfo) Framebuffer {
        const fb_buffer: [*]u8 = @ptrFromInt(info.address);
        return .{
            .info = info,
            .buffer = fb_buffer[0..info.size()],
        };
    }

    pub fn putPixel(self: *Framebuffer, x: u32, y: u32, color: Color) void {
        if (x >= self.info.width or y >= self.info.height) return;

        const offset = y * self.info.pitch + x * self.info.format.bytesPerPixel();
        const pixel_value = color.toU32(self.info.format);

        switch (self.info.format.bytesPerPixel()) {
            1 => self.buffer[offset] = @truncate(pixel_value),
            2 => {
                const ptr: *u16 = @ptrCast(@alignCast(&self.buffer[offset]));
                ptr.* = @truncate(pixel_value);
            },
            3 => {
                self.buffer[offset] = @truncate(pixel_value);
                self.buffer[offset + 1] = @truncate(pixel_value >> 8);
                self.buffer[offset + 2] = @truncate(pixel_value >> 16);
            },
            4 => {
                const ptr: *u32 = @ptrCast(@alignCast(&self.buffer[offset]));
                ptr.* = pixel_value;
            },
            else => {},
        }
    }

    pub fn getPixel(self: *Framebuffer, x: u32, y: u32) ?Color {
        if (x >= self.info.width or y >= self.info.height) return null;

        const offset = y * self.info.pitch + x * self.info.format.bytesPerPixel();

        const value = switch (self.info.format.bytesPerPixel()) {
            1 => @as(u32, self.buffer[offset]),
            2 => @as(u32, @as(*const u16, @ptrCast(@alignCast(&self.buffer[offset]))).*),
            3 => @as(u32, self.buffer[offset]) |
                (@as(u32, self.buffer[offset + 1]) << 8) |
                (@as(u32, self.buffer[offset + 2]) << 16),
            4 => @as(*const u32, @ptrCast(@alignCast(&self.buffer[offset]))).*,
            else => return null,
        };

        return switch (self.info.format) {
            .rgba8888 => Color.rgba(
                @truncate(value >> 24),
                @truncate(value >> 16),
                @truncate(value >> 8),
                @truncate(value),
            ),
            .bgra8888 => Color.rgba(
                @truncate(value >> 8),
                @truncate(value >> 16),
                @truncate(value >> 24),
                @truncate(value),
            ),
            else => Color.BLACK,
        };
    }

    pub fn clear(self: *Framebuffer, color: Color) void {
        for (0..self.info.height) |y| {
            for (0..self.info.width) |x| {
                self.putPixel(@intCast(x), @intCast(y), color);
            }
        }
    }

    pub fn drawRect(self: *Framebuffer, x: u32, y: u32, width: u32, height: u32, color: Color) void {
        const x_end = @min(x + width, self.info.width);
        const y_end = @min(y + height, self.info.height);

        var py = y;
        while (py < y_end) : (py += 1) {
            var px = x;
            while (px < x_end) : (px += 1) {
                self.putPixel(px, py, color);
            }
        }
    }

    pub fn drawLine(self: *Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        // Bresenham's line algorithm
        const dx = @abs(x1 - x0);
        const dy = @abs(y1 - y0);
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        var x = x0;
        var y = y0;

        while (true) {
            if (x >= 0 and y >= 0) {
                self.putPixel(@intCast(x), @intCast(y), color);
            }

            if (x == x1 and y == y1) break;

            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    pub fn drawCircle(self: *Framebuffer, cx: i32, cy: i32, radius: u32, color: Color) void {
        // Midpoint circle algorithm
        var x: i32 = 0;
        var y: i32 = @intCast(radius);
        var d: i32 = @intCast(3 - 2 * radius);

        while (x <= y) {
            self.putPixelSafe(cx + x, cy + y, color);
            self.putPixelSafe(cx - x, cy + y, color);
            self.putPixelSafe(cx + x, cy - y, color);
            self.putPixelSafe(cx - x, cy - y, color);
            self.putPixelSafe(cx + y, cy + x, color);
            self.putPixelSafe(cx - y, cy + x, color);
            self.putPixelSafe(cx + y, cy - x, color);
            self.putPixelSafe(cx - y, cy - x, color);

            if (d < 0) {
                d = d + 4 * x + 6;
            } else {
                d = d + 4 * (x - y) + 10;
                y -= 1;
            }
            x += 1;
        }
    }

    fn putPixelSafe(self: *Framebuffer, x: i32, y: i32, color: Color) void {
        if (x >= 0 and y >= 0) {
            self.putPixel(@intCast(x), @intCast(y), color);
        }
    }

    pub fn scroll(self: *Framebuffer, lines: u32) void {
        const bytes_per_line = self.info.pitch;
        const scroll_bytes = lines * bytes_per_line;

        if (scroll_bytes >= self.buffer.len) {
            // Scroll entire screen, just clear
            @memset(self.buffer, 0);
            return;
        }

        // Move data up
        const src = self.buffer[scroll_bytes..];
        const dest = self.buffer[0 .. self.buffer.len - scroll_bytes];
        @memcpy(dest, src);

        // Clear bottom
        const clear_start = self.buffer.len - scroll_bytes;
        @memset(self.buffer[clear_start..], 0);
    }
};

// ============================================================================
// VGA Text Mode
// ============================================================================

pub const VGAColor = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

pub const VGAText = struct {
    buffer: [*]volatile u16,
    width: u32,
    height: u32,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,

    pub const DEFAULT_ADDRESS = 0xB8000;
    pub const DEFAULT_WIDTH = 80;
    pub const DEFAULT_HEIGHT = 25;

    pub fn init() VGAText {
        return .{
            .buffer = @ptrFromInt(DEFAULT_ADDRESS),
            .width = DEFAULT_WIDTH,
            .height = DEFAULT_HEIGHT,
        };
    }

    pub fn makeEntry(char: u8, fg: VGAColor, bg: VGAColor) u16 {
        const color: u16 = @as(u16, @intFromEnum(bg)) << 4 | @intFromEnum(fg);
        return @as(u16, char) | (color << 8);
    }

    pub fn putChar(self: *VGAText, x: u32, y: u32, char: u8, fg: VGAColor, bg: VGAColor) void {
        if (x >= self.width or y >= self.height) return;
        const index = y * self.width + x;
        self.buffer[index] = makeEntry(char, fg, bg);
    }

    pub fn clear(self: *VGAText, fg: VGAColor, bg: VGAColor) void {
        const entry = makeEntry(' ', fg, bg);
        for (0..self.width * self.height) |i| {
            self.buffer[i] = entry;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    pub fn write(self: *VGAText, char: u8, fg: VGAColor, bg: VGAColor) void {
        if (char == '\n') {
            self.cursor_x = 0;
            self.cursor_y += 1;
        } else {
            self.putChar(self.cursor_x, self.cursor_y, char, fg, bg);
            self.cursor_x += 1;

            if (self.cursor_x >= self.width) {
                self.cursor_x = 0;
                self.cursor_y += 1;
            }
        }

        if (self.cursor_y >= self.height) {
            self.scroll();
        }
    }

    pub fn writeString(self: *VGAText, str: []const u8, fg: VGAColor, bg: VGAColor) void {
        for (str) |char| {
            self.write(char, fg, bg);
        }
    }

    pub fn scroll(self: *VGAText) void {
        // Move all lines up one
        for (0..self.height - 1) |y| {
            for (0..self.width) |x| {
                const src_idx = (y + 1) * self.width + x;
                const dst_idx = y * self.width + x;
                self.buffer[dst_idx] = self.buffer[src_idx];
            }
        }

        // Clear last line
        const last_line_start = (self.height - 1) * self.width;
        const blank = makeEntry(' ', .light_gray, .black);
        for (0..self.width) |x| {
            self.buffer[last_line_start + x] = blank;
        }

        self.cursor_y = self.height - 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "pixel format bytes per pixel" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 4), PixelFormat.rgba8888.bytesPerPixel());
    try testing.expectEqual(@as(u8, 3), PixelFormat.rgb888.bytesPerPixel());
    try testing.expectEqual(@as(u8, 2), PixelFormat.rgb565.bytesPerPixel());
    try testing.expectEqual(@as(u8, 1), PixelFormat.indexed8.bytesPerPixel());
}

test "color creation" {
    const testing = std.testing;

    const red = Color.rgb(255, 0, 0);
    try testing.expectEqual(@as(u8, 255), red.r);
    try testing.expectEqual(@as(u8, 0), red.g);
    try testing.expectEqual(@as(u8, 0), red.b);
    try testing.expectEqual(@as(u8, 255), red.a);
}

test "VGA entry creation" {
    const testing = std.testing;

    const entry = VGAText.makeEntry('A', .white, .black);
    try testing.expectEqual(@as(u16, 0x0F41), entry); // 'A' with white on black
}
