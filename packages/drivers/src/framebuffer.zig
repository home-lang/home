// Home Programming Language - Framebuffer Driver
// Linear framebuffer graphics output

const Basics = @import("basics");
const sync = @import("sync.zig");

// ============================================================================
// Pixel Formats
// ============================================================================

pub const PixelFormat = enum {
    RGB888, // 24-bit RGB (8-8-8)
    BGR888, // 24-bit BGR (8-8-8)
    RGBA8888, // 32-bit RGBA (8-8-8-8)
    BGRA8888, // 32-bit BGRA (8-8-8-8)
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

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
// Framebuffer
// ============================================================================

pub const Framebuffer = struct {
    base_address: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    format: PixelFormat,
    buffer: []volatile u8,
    lock: sync.Spinlock,

    pub fn init(
        base_address: u64,
        width: u32,
        height: u32,
        pitch: u32,
        bpp: u32,
        format: PixelFormat,
    ) Framebuffer {
        const buffer_size = pitch * height;
        const buffer: [*]volatile u8 = @ptrFromInt(base_address);

        return .{
            .base_address = base_address,
            .width = width,
            .height = height,
            .pitch = pitch,
            .bpp = bpp,
            .format = format,
            .buffer = buffer[0..buffer_size],
            .lock = sync.Spinlock.init(),
        };
    }

    /// Put a pixel at (x, y)
    pub fn putPixel(self: *Framebuffer, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;

        self.lock.acquire();
        defer self.lock.release();

        const offset = y * self.pitch + x * (self.bpp / 8);

        switch (self.format) {
            .RGB888 => {
                self.buffer[offset + 0] = color.r;
                self.buffer[offset + 1] = color.g;
                self.buffer[offset + 2] = color.b;
            },
            .BGR888 => {
                self.buffer[offset + 0] = color.b;
                self.buffer[offset + 1] = color.g;
                self.buffer[offset + 2] = color.r;
            },
            .RGBA8888 => {
                self.buffer[offset + 0] = color.r;
                self.buffer[offset + 1] = color.g;
                self.buffer[offset + 2] = color.b;
                self.buffer[offset + 3] = color.a;
            },
            .BGRA8888 => {
                self.buffer[offset + 0] = color.b;
                self.buffer[offset + 1] = color.g;
                self.buffer[offset + 2] = color.r;
                self.buffer[offset + 3] = color.a;
            },
        }
    }

    /// Fill entire screen with color
    pub fn clear(self: *Framebuffer, color: Color) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.putPixel(@intCast(x), @intCast(y), color);
            }
        }
    }

    /// Draw a rectangle
    pub fn drawRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        const x2 = Basics.math.min(x + w, self.width);
        const y2 = Basics.math.min(y + h, self.height);

        for (y..y2) |py| {
            for (x..x2) |px| {
                self.putPixel(@intCast(px), @intCast(py), color);
            }
        }
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        self.drawRect(x, y, w, h, color);
    }

    /// Draw a line (Bresenham's algorithm)
    pub fn drawLine(self: *Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        var x = x0;
        var y = y0;

        const dx = Basics.math.absInt(x1 - x0) catch 0;
        const dy = Basics.math.absInt(y1 - y0) catch 0;

        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;

        var err = dx - dy;

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

    /// Draw a circle (Midpoint algorithm)
    pub fn drawCircle(self: *Framebuffer, cx: i32, cy: i32, radius: u32, color: Color) void {
        var x: i32 = @intCast(radius);
        var y: i32 = 0;
        var err: i32 = 0;

        while (x >= y) {
            self.putPixel(@intCast(cx + x), @intCast(cy + y), color);
            self.putPixel(@intCast(cx + y), @intCast(cy + x), color);
            self.putPixel(@intCast(cx - y), @intCast(cy + x), color);
            self.putPixel(@intCast(cx - x), @intCast(cy + y), color);
            self.putPixel(@intCast(cx - x), @intCast(cy - y), color);
            self.putPixel(@intCast(cx - y), @intCast(cy - x), color);
            self.putPixel(@intCast(cx + y), @intCast(cy - x), color);
            self.putPixel(@intCast(cx + x), @intCast(cy - y), color);

            if (err <= 0) {
                y += 1;
                err += 2 * y + 1;
            }

            if (err > 0) {
                x -= 1;
                err -= 2 * x + 1;
            }
        }
    }

    /// Scroll the framebuffer up by n pixels
    pub fn scrollUp(self: *Framebuffer, pixels: u32) void {
        self.lock.acquire();
        defer self.lock.release();

        if (pixels >= self.height) {
            self.clear(Color.BLACK);
            return;
        }

        const bytes_per_pixel = self.bpp / 8;
        const scroll_bytes = pixels * self.pitch;
        const remaining_bytes = (self.height - pixels) * self.pitch;

        // Move rows up
        for (0..remaining_bytes) |i| {
            self.buffer[i] = self.buffer[i + scroll_bytes];
        }

        // Clear bottom rows
        const clear_start = remaining_bytes;
        for (clear_start..self.buffer.len) |i| {
            self.buffer[i] = 0;
        }

        _ = bytes_per_pixel;
    }

    /// Blit (copy) data to framebuffer
    pub fn blit(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
        if (x >= self.width or y >= self.height) return;

        const bytes_per_pixel = self.bpp / 8;
        const max_w = Basics.math.min(w, self.width - x);
        const max_h = Basics.math.min(h, self.height - y);

        self.lock.acquire();
        defer self.lock.release();

        for (0..max_h) |row| {
            const dst_offset = (y + @as(u32, @intCast(row))) * self.pitch + x * bytes_per_pixel;
            const src_offset = row * w * bytes_per_pixel;
            const copy_bytes = max_w * bytes_per_pixel;

            for (0..copy_bytes) |i| {
                self.buffer[dst_offset + i] = data[src_offset + i];
            }
        }
    }
};

// ============================================================================
// Global Framebuffer
// ============================================================================

var global_framebuffer: ?Framebuffer = null;
var fb_lock = sync.Spinlock.init();

/// Initialize global framebuffer
pub fn init(
    base_address: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    format: PixelFormat,
) void {
    fb_lock.acquire();
    defer fb_lock.release();

    global_framebuffer = Framebuffer.init(base_address, width, height, pitch, bpp, format);
}

/// Get global framebuffer
pub fn get() ?*Framebuffer {
    if (global_framebuffer) |*fb| {
        return fb;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "color values" {
    try Basics.testing.expectEqual(@as(u8, 255), Color.WHITE.r);
    try Basics.testing.expectEqual(@as(u8, 255), Color.WHITE.g);
    try Basics.testing.expectEqual(@as(u8, 255), Color.WHITE.b);

    try Basics.testing.expectEqual(@as(u8, 0), Color.BLACK.r);
    try Basics.testing.expectEqual(@as(u8, 0), Color.BLACK.g);
    try Basics.testing.expectEqual(@as(u8, 0), Color.BLACK.b);
}
