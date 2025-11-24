// Image Transform Operations
// Rotate, flip, affine transformations

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Rotation
// ============================================================================

pub const RotateMode = enum {
    degrees_90,
    degrees_180,
    degrees_270,
};

/// Rotate image by 90, 180, or 270 degrees
pub fn rotate(img: *const Image, mode: RotateMode) !Image {
    return switch (mode) {
        .degrees_90 => rotate90(img),
        .degrees_180 => rotate180(img),
        .degrees_270 => rotate270(img),
    };
}

/// Rotate image by arbitrary angle (in degrees)
pub fn rotateAngle(img: *const Image, degrees: f64, background: Color) !Image {
    const radians = degrees * std.math.pi / 180.0;
    const cos_a = @cos(radians);
    const sin_a = @sin(radians);

    // Calculate new dimensions to fit rotated image
    const w: f64 = @floatFromInt(img.width);
    const h: f64 = @floatFromInt(img.height);

    const corners = [4][2]f64{
        .{ 0, 0 },
        .{ w, 0 },
        .{ 0, h },
        .{ w, h },
    };

    var min_x: f64 = std.math.floatMax(f64);
    var max_x: f64 = std.math.floatMin(f64);
    var min_y: f64 = std.math.floatMax(f64);
    var max_y: f64 = std.math.floatMin(f64);

    for (corners) |corner| {
        const rx = corner[0] * cos_a - corner[1] * sin_a;
        const ry = corner[0] * sin_a + corner[1] * cos_a;
        min_x = @min(min_x, rx);
        max_x = @max(max_x, rx);
        min_y = @min(min_y, ry);
        max_y = @max(max_y, ry);
    }

    const new_width: u32 = @intFromFloat(@ceil(max_x - min_x));
    const new_height: u32 = @intFromFloat(@ceil(max_y - min_y));

    if (new_width == 0 or new_height == 0) {
        return error.InvalidDimensions;
    }

    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    // Fill with background
    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            result.setPixel(x, y, background);
        }
    }

    // Center of source and destination
    const src_cx = w / 2.0;
    const src_cy = h / 2.0;
    const dst_cx = @as(f64, @floatFromInt(new_width)) / 2.0;
    const dst_cy = @as(f64, @floatFromInt(new_height)) / 2.0;

    // Inverse transform to map destination to source
    y = 0;
    while (y < new_height) : (y += 1) {
        const dy = @as(f64, @floatFromInt(y)) - dst_cy;

        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) - dst_cx;

            // Inverse rotation
            const sx = dx * cos_a + dy * sin_a + src_cx;
            const sy = -dx * sin_a + dy * cos_a + src_cy;

            // Bilinear interpolation
            if (sx >= 0 and sx < w - 1 and sy >= 0 and sy < h - 1) {
                const sx0: u32 = @intFromFloat(sx);
                const sy0: u32 = @intFromFloat(sy);
                const sx1: u32 = sx0 + 1;
                const sy1: u32 = sy0 + 1;

                const fx = sx - @as(f64, @floatFromInt(sx0));
                const fy = sy - @as(f64, @floatFromInt(sy0));

                const c00 = img.getPixel(sx0, sy0) orelse background;
                const c10 = img.getPixel(sx1, sy0) orelse background;
                const c01 = img.getPixel(sx0, sy1) orelse background;
                const c11 = img.getPixel(sx1, sy1) orelse background;

                const color = bilinearInterpolate(c00, c10, c01, c11, fx, fy);
                result.setPixel(x, y, color);
            } else if (sx >= 0 and sx < w and sy >= 0 and sy < h) {
                if (img.getPixel(@intFromFloat(sx), @intFromFloat(sy))) |c| {
                    result.setPixel(x, y, c);
                }
            }
        }
    }

    return result;
}

fn bilinearInterpolate(c00: Color, c10: Color, c01: Color, c11: Color, fx: f64, fy: f64) Color {
    const inv_fx = 1.0 - fx;
    const inv_fy = 1.0 - fy;

    return Color{
        .r = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.r)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.r)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.r)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.r)) * fx * fy,
            0,
            255,
        )),
        .g = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.g)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.g)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.g)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.g)) * fx * fy,
            0,
            255,
        )),
        .b = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.b)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.b)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.b)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.b)) * fx * fy,
            0,
            255,
        )),
        .a = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.a)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.a)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.a)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.a)) * fx * fy,
            0,
            255,
        )),
    };
}

fn rotate90(img: *const Image) !Image {
    var result = try Image.init(img.allocator, img.height, img.width, img.format);
    errdefer result.deinit();

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |color| {
                result.setPixel(img.height - 1 - y, x, color);
            }
        }
    }

    return result;
}

fn rotate180(img: *const Image) !Image {
    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |color| {
                result.setPixel(img.width - 1 - x, img.height - 1 - y, color);
            }
        }
    }

    return result;
}

fn rotate270(img: *const Image) !Image {
    var result = try Image.init(img.allocator, img.height, img.width, img.format);
    errdefer result.deinit();

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |color| {
                result.setPixel(y, img.width - 1 - x, color);
            }
        }
    }

    return result;
}

// ============================================================================
// Flip Operations
// ============================================================================

/// Flip image vertically (top to bottom)
pub fn flip(img: *const Image) !Image {
    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    const bpp = img.format.bytesPerPixel();
    const row_bytes = @as(usize, img.width) * bpp;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const src_offset = @as(usize, img.height - 1 - y) * row_bytes;
        const dst_offset = @as(usize, y) * row_bytes;
        @memcpy(result.pixels[dst_offset..][0..row_bytes], img.pixels[src_offset..][0..row_bytes]);
    }

    return result;
}

/// Flip image horizontally (left to right)
pub fn flop(img: *const Image) !Image {
    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |color| {
                result.setPixel(img.width - 1 - x, y, color);
            }
        }
    }

    return result;
}

/// Flip in-place (modifies the original image)
pub fn flipInPlace(img: *Image) void {
    const bpp = img.format.bytesPerPixel();
    const row_bytes = @as(usize, img.width) * bpp;

    var y: u32 = 0;
    while (y < img.height / 2) : (y += 1) {
        const top_offset = @as(usize, y) * row_bytes;
        const bottom_offset = @as(usize, img.height - 1 - y) * row_bytes;

        // Swap rows
        for (0..row_bytes) |i| {
            const tmp = img.pixels[top_offset + i];
            img.pixels[top_offset + i] = img.pixels[bottom_offset + i];
            img.pixels[bottom_offset + i] = tmp;
        }
    }
}

pub fn flopInPlace(img: *Image) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width / 2) : (x += 1) {
            const left = img.getPixel(x, y) orelse Color.BLACK;
            const right = img.getPixel(img.width - 1 - x, y) orelse Color.BLACK;

            img.setPixel(x, y, right);
            img.setPixel(img.width - 1 - x, y, left);
        }
    }
}

// ============================================================================
// Affine Transform
// ============================================================================

/// 2D affine transformation matrix (3x3, but only using 2x3)
/// | a  b  tx |
/// | c  d  ty |
/// | 0  0  1  |
pub const AffineMatrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,

    pub fn identity() AffineMatrix {
        return .{};
    }

    pub fn translation(dx: f64, dy: f64) AffineMatrix {
        return .{ .tx = dx, .ty = dy };
    }

    pub fn scale(sx: f64, sy: f64) AffineMatrix {
        return .{ .a = sx, .d = sy };
    }

    pub fn rotation(radians: f64) AffineMatrix {
        const cos_a = @cos(radians);
        const sin_a = @sin(radians);
        return .{ .a = cos_a, .b = -sin_a, .c = sin_a, .d = cos_a };
    }

    pub fn shear(shx: f64, shy: f64) AffineMatrix {
        return .{ .b = shx, .c = shy };
    }

    /// Multiply two matrices
    pub fn multiply(self: AffineMatrix, other: AffineMatrix) AffineMatrix {
        return .{
            .a = self.a * other.a + self.b * other.c,
            .b = self.a * other.b + self.b * other.d,
            .c = self.c * other.a + self.d * other.c,
            .d = self.c * other.b + self.d * other.d,
            .tx = self.a * other.tx + self.b * other.ty + self.tx,
            .ty = self.c * other.tx + self.d * other.ty + self.ty,
        };
    }

    /// Invert the matrix
    pub fn invert(self: AffineMatrix) ?AffineMatrix {
        const det = self.a * self.d - self.b * self.c;
        if (@abs(det) < 1e-10) return null;

        const inv_det = 1.0 / det;
        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .tx = (self.b * self.ty - self.d * self.tx) * inv_det,
            .ty = (self.c * self.tx - self.a * self.ty) * inv_det,
        };
    }

    /// Transform a point
    pub fn transformPoint(self: AffineMatrix, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{
            .x = self.a * x + self.b * y + self.tx,
            .y = self.c * x + self.d * y + self.ty,
        };
    }
};

pub fn affine(img: *const Image, matrix: AffineMatrix, new_width: u32, new_height: u32, background: Color) !Image {
    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    // Get inverse matrix to map destination to source
    const inv = matrix.invert() orelse return error.InvalidTransform;

    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            // Map destination point to source
            const src = inv.transformPoint(@floatFromInt(x), @floatFromInt(y));

            if (src.x >= 0 and src.x < @as(f64, @floatFromInt(img.width - 1)) and
                src.y >= 0 and src.y < @as(f64, @floatFromInt(img.height - 1)))
            {
                // Bilinear interpolation
                const sx0: u32 = @intFromFloat(src.x);
                const sy0: u32 = @intFromFloat(src.y);
                const sx1: u32 = @min(sx0 + 1, img.width - 1);
                const sy1: u32 = @min(sy0 + 1, img.height - 1);

                const fx = src.x - @as(f64, @floatFromInt(sx0));
                const fy = src.y - @as(f64, @floatFromInt(sy0));

                const c00 = img.getPixel(sx0, sy0) orelse background;
                const c10 = img.getPixel(sx1, sy0) orelse background;
                const c01 = img.getPixel(sx0, sy1) orelse background;
                const c11 = img.getPixel(sx1, sy1) orelse background;

                const color = bilinearInterpolate(c00, c10, c01, c11, fx, fy);
                result.setPixel(x, y, color);
            } else {
                result.setPixel(x, y, background);
            }
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "Rotate 90 degrees" {
    var img = try Image.init(std.testing.allocator, 4, 2, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(3, 0, Color.GREEN);

    var rotated = try rotate(&img, .degrees_90);
    defer rotated.deinit();

    try std.testing.expectEqual(@as(u32, 2), rotated.width);
    try std.testing.expectEqual(@as(u32, 4), rotated.height);

    // RED (0,0) should now be at (1,0)
    const pixel = rotated.getPixel(1, 0);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Flip vertical" {
    var img = try Image.init(std.testing.allocator, 2, 4, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(0, 3, Color.BLUE);

    var flipped = try flip(&img);
    defer flipped.deinit();

    // RED should now be at bottom, BLUE at top
    const top = flipped.getPixel(0, 0);
    try std.testing.expect(top != null);
    try std.testing.expectEqual(@as(u8, 0), top.?.r);
    try std.testing.expectEqual(@as(u8, 0), top.?.g);
    try std.testing.expectEqual(@as(u8, 255), top.?.b);
}

test "Affine matrix multiplication" {
    const scale = AffineMatrix.scale(2, 2);
    const translate = AffineMatrix.translation(10, 20);
    const combined = scale.multiply(translate);

    // Point (5, 5) -> scale to (10, 10) -> translate to (20, 30)
    const result = combined.transformPoint(5, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 20), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), result.y, 0.001);
}

test "Affine matrix inverse" {
    const scale = AffineMatrix.scale(2, 3);
    const inv = scale.invert();

    try std.testing.expect(inv != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), inv.?.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), inv.?.d, 0.001);
}
