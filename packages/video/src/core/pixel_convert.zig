// Home Video Library - Pixel Format Conversion
// Convert between YUV, RGB, and other pixel formats with colorspace handling

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Pixel Formats
// ============================================================================

pub const PixelFormat = enum {
    // Planar YUV formats
    yuv420p, // I420: Y plane, U plane (1/4), V plane (1/4)
    yuv422p, // Y plane, U plane (1/2 width), V plane (1/2 width)
    yuv444p, // Y plane, U plane (full), V plane (full)
    nv12, // Y plane, interleaved UV plane
    nv21, // Y plane, interleaved VU plane

    // Packed formats
    yuyv, // Packed YUV 4:2:2 (YUYV)
    uyvy, // Packed YUV 4:2:2 (UYVY)

    // RGB formats
    rgb24, // Packed RGB (3 bytes per pixel)
    bgr24, // Packed BGR (3 bytes per pixel)
    rgba32, // Packed RGBA (4 bytes per pixel)
    bgra32, // Packed BGRA (4 bytes per pixel)
    argb32, // Packed ARGB (4 bytes per pixel)

    // Grayscale
    gray8, // 8-bit grayscale
    gray16, // 16-bit grayscale

    /// Get the number of planes for this format
    pub fn planeCount(self: PixelFormat) u8 {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p => 3,
            .nv12, .nv21 => 2,
            .gray16 => 1,
            else => 1,
        };
    }

    /// Check if format is planar
    pub fn isPlanar(self: PixelFormat) bool {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .nv12, .nv21 => true,
            else => false,
        };
    }

    /// Check if format is RGB-based
    pub fn isRgb(self: PixelFormat) bool {
        return switch (self) {
            .rgb24, .bgr24, .rgba32, .bgra32, .argb32 => true,
            else => false,
        };
    }

    /// Get bytes per pixel for packed formats
    pub fn bytesPerPixel(self: PixelFormat) ?usize {
        return switch (self) {
            .rgb24, .bgr24 => 3,
            .rgba32, .bgra32, .argb32 => 4,
            .yuyv, .uyvy => 2, // Average per pixel
            .gray8 => 1,
            .gray16 => 2,
            else => null, // Planar formats
        };
    }
};

/// Color space definitions
pub const ColorSpace = enum {
    bt601, // SD video (ITU-R BT.601)
    bt709, // HD video (ITU-R BT.709)
    bt2020, // UHD video (ITU-R BT.2020)
    srgb, // sRGB
};

/// Color range (full vs limited)
pub const ColorRange = enum {
    limited, // 16-235 for Y, 16-240 for UV
    full, // 0-255 for all components
};

// ============================================================================
// Frame Buffer
// ============================================================================

/// Represents a video frame with pixel data
pub const Frame = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    colorspace: ColorSpace = .bt709,
    color_range: ColorRange = .limited,

    // Plane data and strides
    planes: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} },
    strides: [4]u32 = .{ 0, 0, 0, 0 },

    allocator: ?Allocator = null,

    pub fn deinit(self: *Frame) void {
        if (self.allocator) |allocator| {
            for (&self.planes) |*plane| {
                if (plane.len > 0) {
                    allocator.free(plane.*);
                    plane.* = &.{};
                }
            }
        }
    }

    /// Allocate a new frame with the given parameters
    pub fn alloc(
        width: u32,
        height: u32,
        format: PixelFormat,
        allocator: Allocator,
    ) !Frame {
        var frame = Frame{
            .width = width,
            .height = height,
            .format = format,
            .allocator = allocator,
        };

        switch (format) {
            .yuv420p => {
                const y_size = width * height;
                const uv_size = (width / 2) * (height / 2);

                frame.planes[0] = try allocator.alloc(u8, y_size);
                frame.planes[1] = try allocator.alloc(u8, uv_size);
                frame.planes[2] = try allocator.alloc(u8, uv_size);

                frame.strides[0] = width;
                frame.strides[1] = width / 2;
                frame.strides[2] = width / 2;
            },
            .yuv422p => {
                const y_size = width * height;
                const uv_size = (width / 2) * height;

                frame.planes[0] = try allocator.alloc(u8, y_size);
                frame.planes[1] = try allocator.alloc(u8, uv_size);
                frame.planes[2] = try allocator.alloc(u8, uv_size);

                frame.strides[0] = width;
                frame.strides[1] = width / 2;
                frame.strides[2] = width / 2;
            },
            .yuv444p => {
                const size = width * height;

                frame.planes[0] = try allocator.alloc(u8, size);
                frame.planes[1] = try allocator.alloc(u8, size);
                frame.planes[2] = try allocator.alloc(u8, size);

                frame.strides[0] = width;
                frame.strides[1] = width;
                frame.strides[2] = width;
            },
            .nv12, .nv21 => {
                const y_size = width * height;
                const uv_size = width * (height / 2);

                frame.planes[0] = try allocator.alloc(u8, y_size);
                frame.planes[1] = try allocator.alloc(u8, uv_size);

                frame.strides[0] = width;
                frame.strides[1] = width;
            },
            .rgb24, .bgr24 => {
                const size = width * height * 3;
                frame.planes[0] = try allocator.alloc(u8, size);
                frame.strides[0] = width * 3;
            },
            .rgba32, .bgra32, .argb32 => {
                const size = width * height * 4;
                frame.planes[0] = try allocator.alloc(u8, size);
                frame.strides[0] = width * 4;
            },
            .yuyv, .uyvy => {
                const size = width * height * 2;
                frame.planes[0] = try allocator.alloc(u8, size);
                frame.strides[0] = width * 2;
            },
            .gray8 => {
                const size = width * height;
                frame.planes[0] = try allocator.alloc(u8, size);
                frame.strides[0] = width;
            },
            .gray16 => {
                const size = width * height * 2;
                frame.planes[0] = try allocator.alloc(u8, size);
                frame.strides[0] = width * 2;
            },
        }

        return frame;
    }
};

// ============================================================================
// Color Conversion Matrices
// ============================================================================

const ColorMatrix = struct {
    kr: f32,
    kb: f32,

    // Derived values
    fn kg(self: ColorMatrix) f32 {
        return 1.0 - self.kr - self.kb;
    }
};

fn getColorMatrix(colorspace: ColorSpace) ColorMatrix {
    return switch (colorspace) {
        .bt601 => .{ .kr = 0.299, .kb = 0.114 },
        .bt709 => .{ .kr = 0.2126, .kb = 0.0722 },
        .bt2020 => .{ .kr = 0.2627, .kb = 0.0593 },
        .srgb => .{ .kr = 0.2126, .kb = 0.0722 }, // Same as BT.709
    };
}

// ============================================================================
// Conversion Functions
// ============================================================================

/// Convert a frame from one pixel format to another
pub fn convert(
    src: *const Frame,
    dst_format: PixelFormat,
    allocator: Allocator,
) !Frame {
    var dst = try Frame.alloc(src.width, src.height, dst_format, allocator);
    dst.colorspace = src.colorspace;
    dst.color_range = src.color_range;

    try convertInPlace(src, &dst);
    return dst;
}

/// Convert between frames (destination must be pre-allocated)
pub fn convertInPlace(src: *const Frame, dst: *Frame) !void {
    if (src.width != dst.width or src.height != dst.height) {
        return error.DimensionMismatch;
    }

    // Handle same format (just copy)
    if (src.format == dst.format) {
        for (0..4) |i| {
            if (src.planes[i].len > 0) {
                @memcpy(dst.planes[i], src.planes[i]);
            }
        }
        return;
    }

    // Route to appropriate converter
    if (src.format.isRgb() and !dst.format.isRgb()) {
        try rgbToYuv(src, dst);
    } else if (!src.format.isRgb() and dst.format.isRgb()) {
        try yuvToRgb(src, dst);
    } else if (src.format.isRgb() and dst.format.isRgb()) {
        try rgbToRgb(src, dst);
    } else {
        try yuvToYuv(src, dst);
    }
}

// ============================================================================
// YUV <-> RGB Conversion
// ============================================================================

fn yuvToRgb(src: *const Frame, dst: *Frame) !void {
    const matrix = getColorMatrix(src.colorspace);
    const width = src.width;
    const height = src.height;

    const y_offset: f32 = if (src.color_range == .limited) 16.0 else 0.0;
    const y_range: f32 = if (src.color_range == .limited) 219.0 else 255.0;
    const uv_range: f32 = if (src.color_range == .limited) 224.0 else 255.0;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            // Get YUV values based on source format
            const yuv = getYuvPixel(src, x, y);

            // Normalize to 0-1 range
            const y_norm = (@as(f32, @floatFromInt(yuv.y)) - y_offset) / y_range;
            const u_norm = (@as(f32, @floatFromInt(yuv.u)) - 128.0) / (uv_range / 2.0);
            const v_norm = (@as(f32, @floatFromInt(yuv.v)) - 128.0) / (uv_range / 2.0);

            // YUV to RGB conversion
            var r = y_norm + (1.0 - matrix.kr) * 2.0 * v_norm;
            var g = y_norm - (matrix.kb * (1.0 - matrix.kb) / matrix.kg()) * 2.0 * u_norm -
                (matrix.kr * (1.0 - matrix.kr) / matrix.kg()) * 2.0 * v_norm;
            var b = y_norm + (1.0 - matrix.kb) * 2.0 * u_norm;

            // Clamp to valid range
            r = std.math.clamp(r, 0.0, 1.0);
            g = std.math.clamp(g, 0.0, 1.0);
            b = std.math.clamp(b, 0.0, 1.0);

            // Convert to 8-bit and write
            const r8: u8 = @intFromFloat(r * 255.0);
            const g8: u8 = @intFromFloat(g * 255.0);
            const b8: u8 = @intFromFloat(b * 255.0);

            setRgbPixel(dst, x, y, r8, g8, b8, 255);
        }
    }
}

fn rgbToYuv(src: *const Frame, dst: *Frame) !void {
    const matrix = getColorMatrix(dst.colorspace);
    const width = src.width;
    const height = src.height;

    const y_offset: f32 = if (dst.color_range == .limited) 16.0 else 0.0;
    const y_range: f32 = if (dst.color_range == .limited) 219.0 else 255.0;
    const uv_range: f32 = if (dst.color_range == .limited) 224.0 else 255.0;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const rgb = getRgbPixel(src, x, y);

            // Normalize to 0-1
            const r = @as(f32, @floatFromInt(rgb.r)) / 255.0;
            const g = @as(f32, @floatFromInt(rgb.g)) / 255.0;
            const b = @as(f32, @floatFromInt(rgb.b)) / 255.0;

            // RGB to YUV
            const y_val = matrix.kr * r + matrix.kg() * g + matrix.kb * b;
            const u_val = (b - y_val) / (2.0 * (1.0 - matrix.kb));
            const v_val = (r - y_val) / (2.0 * (1.0 - matrix.kr));

            // Scale to output range
            const y8: u8 = @intFromFloat(std.math.clamp(y_val * y_range + y_offset, 0.0, 255.0));
            const u8_val: u8 = @intFromFloat(std.math.clamp(u_val * uv_range / 2.0 + 128.0, 0.0, 255.0));
            const v8: u8 = @intFromFloat(std.math.clamp(v_val * uv_range / 2.0 + 128.0, 0.0, 255.0));

            setYuvPixel(dst, x, y, y8, u8_val, v8);
        }
    }
}

fn rgbToRgb(src: *const Frame, dst: *Frame) !void {
    const width = src.width;
    const height = src.height;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const rgba = getRgbPixel(src, x, y);
            setRgbPixel(dst, x, y, rgba.r, rgba.g, rgba.b, rgba.a);
        }
    }
}

fn yuvToYuv(src: *const Frame, dst: *Frame) !void {
    const width = src.width;
    const height = src.height;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const yuv = getYuvPixel(src, x, y);
            setYuvPixel(dst, x, y, yuv.y, yuv.u, yuv.v);
        }
    }
}

// ============================================================================
// Pixel Access Helpers
// ============================================================================

const YuvPixel = struct { y: u8, u: u8, v: u8 };
const RgbaPixel = struct { r: u8, g: u8, b: u8, a: u8 };

fn getYuvPixel(frame: *const Frame, x: u32, y: u32) YuvPixel {
    switch (frame.format) {
        .yuv420p => {
            const y_idx = y * frame.strides[0] + x;
            const uv_x = x / 2;
            const uv_y = y / 2;
            const u_idx = uv_y * frame.strides[1] + uv_x;
            const v_idx = uv_y * frame.strides[2] + uv_x;

            return .{
                .y = frame.planes[0][y_idx],
                .u = frame.planes[1][u_idx],
                .v = frame.planes[2][v_idx],
            };
        },
        .yuv422p => {
            const y_idx = y * frame.strides[0] + x;
            const uv_x = x / 2;
            const u_idx = y * frame.strides[1] + uv_x;
            const v_idx = y * frame.strides[2] + uv_x;

            return .{
                .y = frame.planes[0][y_idx],
                .u = frame.planes[1][u_idx],
                .v = frame.planes[2][v_idx],
            };
        },
        .yuv444p => {
            const idx = y * frame.strides[0] + x;
            return .{
                .y = frame.planes[0][idx],
                .u = frame.planes[1][idx],
                .v = frame.planes[2][idx],
            };
        },
        .nv12 => {
            const y_idx = y * frame.strides[0] + x;
            const uv_x = (x / 2) * 2;
            const uv_y = y / 2;
            const uv_idx = uv_y * frame.strides[1] + uv_x;

            return .{
                .y = frame.planes[0][y_idx],
                .u = frame.planes[1][uv_idx],
                .v = frame.planes[1][uv_idx + 1],
            };
        },
        .nv21 => {
            const y_idx = y * frame.strides[0] + x;
            const uv_x = (x / 2) * 2;
            const uv_y = y / 2;
            const uv_idx = uv_y * frame.strides[1] + uv_x;

            return .{
                .y = frame.planes[0][y_idx],
                .u = frame.planes[1][uv_idx + 1],
                .v = frame.planes[1][uv_idx],
            };
        },
        .yuyv => {
            const base = y * frame.strides[0] + (x / 2) * 4;
            const y_offset: usize = if (x % 2 == 0) 0 else 2;
            return .{
                .y = frame.planes[0][base + y_offset],
                .u = frame.planes[0][base + 1],
                .v = frame.planes[0][base + 3],
            };
        },
        .uyvy => {
            const base = y * frame.strides[0] + (x / 2) * 4;
            const y_offset: usize = if (x % 2 == 0) 1 else 3;
            return .{
                .y = frame.planes[0][base + y_offset],
                .u = frame.planes[0][base],
                .v = frame.planes[0][base + 2],
            };
        },
        .gray8 => {
            const idx = y * frame.strides[0] + x;
            return .{ .y = frame.planes[0][idx], .u = 128, .v = 128 };
        },
        else => return .{ .y = 128, .u = 128, .v = 128 },
    }
}

fn setYuvPixel(frame: *Frame, x: u32, y: u32, luma: u8, u: u8, v: u8) void {
    switch (frame.format) {
        .yuv420p => {
            const y_idx = y * frame.strides[0] + x;
            frame.planes[0][y_idx] = luma;

            // Only write chroma for top-left pixel of each 2x2 block
            if (x % 2 == 0 and y % 2 == 0) {
                const uv_x = x / 2;
                const uv_y = y / 2;
                const u_idx = uv_y * frame.strides[1] + uv_x;
                const v_idx = uv_y * frame.strides[2] + uv_x;
                frame.planes[1][u_idx] = u;
                frame.planes[2][v_idx] = v;
            }
        },
        .yuv422p => {
            const y_idx = y * frame.strides[0] + x;
            frame.planes[0][y_idx] = luma;

            if (x % 2 == 0) {
                const uv_x = x / 2;
                const u_idx = y * frame.strides[1] + uv_x;
                const v_idx = y * frame.strides[2] + uv_x;
                frame.planes[1][u_idx] = u;
                frame.planes[2][v_idx] = v;
            }
        },
        .yuv444p => {
            const idx = y * frame.strides[0] + x;
            frame.planes[0][idx] = luma;
            frame.planes[1][idx] = u;
            frame.planes[2][idx] = v;
        },
        .nv12 => {
            const y_idx = y * frame.strides[0] + x;
            frame.planes[0][y_idx] = luma;

            if (x % 2 == 0 and y % 2 == 0) {
                const uv_x = x;
                const uv_y = y / 2;
                const uv_idx = uv_y * frame.strides[1] + uv_x;
                frame.planes[1][uv_idx] = u;
                frame.planes[1][uv_idx + 1] = v;
            }
        },
        .nv21 => {
            const y_idx = y * frame.strides[0] + x;
            frame.planes[0][y_idx] = luma;

            if (x % 2 == 0 and y % 2 == 0) {
                const uv_x = x;
                const uv_y = y / 2;
                const uv_idx = uv_y * frame.strides[1] + uv_x;
                frame.planes[1][uv_idx] = v;
                frame.planes[1][uv_idx + 1] = u;
            }
        },
        .gray8 => {
            const idx = y * frame.strides[0] + x;
            frame.planes[0][idx] = luma;
        },
        else => {},
    }
}

fn getRgbPixel(frame: *const Frame, x: u32, y: u32) RgbaPixel {
    switch (frame.format) {
        .rgb24 => {
            const idx = y * frame.strides[0] + x * 3;
            return .{
                .r = frame.planes[0][idx],
                .g = frame.planes[0][idx + 1],
                .b = frame.planes[0][idx + 2],
                .a = 255,
            };
        },
        .bgr24 => {
            const idx = y * frame.strides[0] + x * 3;
            return .{
                .r = frame.planes[0][idx + 2],
                .g = frame.planes[0][idx + 1],
                .b = frame.planes[0][idx],
                .a = 255,
            };
        },
        .rgba32 => {
            const idx = y * frame.strides[0] + x * 4;
            return .{
                .r = frame.planes[0][idx],
                .g = frame.planes[0][idx + 1],
                .b = frame.planes[0][idx + 2],
                .a = frame.planes[0][idx + 3],
            };
        },
        .bgra32 => {
            const idx = y * frame.strides[0] + x * 4;
            return .{
                .r = frame.planes[0][idx + 2],
                .g = frame.planes[0][idx + 1],
                .b = frame.planes[0][idx],
                .a = frame.planes[0][idx + 3],
            };
        },
        .argb32 => {
            const idx = y * frame.strides[0] + x * 4;
            return .{
                .r = frame.planes[0][idx + 1],
                .g = frame.planes[0][idx + 2],
                .b = frame.planes[0][idx + 3],
                .a = frame.planes[0][idx],
            };
        },
        else => return .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    }
}

fn setRgbPixel(frame: *Frame, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) void {
    switch (frame.format) {
        .rgb24 => {
            const idx = y * frame.strides[0] + x * 3;
            frame.planes[0][idx] = r;
            frame.planes[0][idx + 1] = g;
            frame.planes[0][idx + 2] = b;
        },
        .bgr24 => {
            const idx = y * frame.strides[0] + x * 3;
            frame.planes[0][idx] = b;
            frame.planes[0][idx + 1] = g;
            frame.planes[0][idx + 2] = r;
        },
        .rgba32 => {
            const idx = y * frame.strides[0] + x * 4;
            frame.planes[0][idx] = r;
            frame.planes[0][idx + 1] = g;
            frame.planes[0][idx + 2] = b;
            frame.planes[0][idx + 3] = a;
        },
        .bgra32 => {
            const idx = y * frame.strides[0] + x * 4;
            frame.planes[0][idx] = b;
            frame.planes[0][idx + 1] = g;
            frame.planes[0][idx + 2] = r;
            frame.planes[0][idx + 3] = a;
        },
        .argb32 => {
            const idx = y * frame.strides[0] + x * 4;
            frame.planes[0][idx] = a;
            frame.planes[0][idx + 1] = r;
            frame.planes[0][idx + 2] = g;
            frame.planes[0][idx + 3] = b;
        },
        else => {},
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Pixel format properties" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 3), PixelFormat.yuv420p.planeCount());
    try testing.expectEqual(@as(u8, 2), PixelFormat.nv12.planeCount());
    try testing.expectEqual(@as(u8, 1), PixelFormat.rgb24.planeCount());

    try testing.expect(PixelFormat.yuv420p.isPlanar());
    try testing.expect(!PixelFormat.rgb24.isPlanar());

    try testing.expect(PixelFormat.rgb24.isRgb());
    try testing.expect(!PixelFormat.yuv420p.isRgb());

    try testing.expectEqual(@as(usize, 3), PixelFormat.rgb24.bytesPerPixel().?);
    try testing.expectEqual(@as(usize, 4), PixelFormat.rgba32.bytesPerPixel().?);
}

test "Frame allocation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var frame = try Frame.alloc(1920, 1080, .yuv420p, allocator);
    defer frame.deinit();

    // Y plane should be full size
    try testing.expectEqual(@as(usize, 1920 * 1080), frame.planes[0].len);

    // U and V planes should be 1/4 size
    try testing.expectEqual(@as(usize, 960 * 540), frame.planes[1].len);
    try testing.expectEqual(@as(usize, 960 * 540), frame.planes[2].len);
}

test "YUV420 pixel access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var frame = try Frame.alloc(4, 4, .yuv420p, allocator);
    defer frame.deinit();

    // Write a test pixel
    setYuvPixel(&frame, 0, 0, 200, 100, 150);

    // Read it back
    const pixel = getYuvPixel(&frame, 0, 0);
    try testing.expectEqual(@as(u8, 200), pixel.y);
    try testing.expectEqual(@as(u8, 100), pixel.u);
    try testing.expectEqual(@as(u8, 150), pixel.v);
}

test "RGB pixel access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var frame = try Frame.alloc(4, 4, .rgba32, allocator);
    defer frame.deinit();

    // Write a test pixel
    setRgbPixel(&frame, 1, 1, 255, 128, 64, 200);

    // Read it back
    const pixel = getRgbPixel(&frame, 1, 1);
    try testing.expectEqual(@as(u8, 255), pixel.r);
    try testing.expectEqual(@as(u8, 128), pixel.g);
    try testing.expectEqual(@as(u8, 64), pixel.b);
    try testing.expectEqual(@as(u8, 200), pixel.a);
}
