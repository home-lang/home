// Color Operations and Adjustments

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Basic Color Adjustments
// ============================================================================

/// Convert image to grayscale
pub fn grayscale(img: *Image) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                const gray = c.toGrayscale();
                img.setPixel(x, y, Color{ .r = gray, .g = gray, .b = gray, .a = c.a });
            }
        }
    }
}

/// Invert colors (negative)
pub fn negate(img: *Image) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = 255 - c.r,
                    .g = 255 - c.g,
                    .b = 255 - c.b,
                    .a = c.a,
                });
            }
        }
    }
}

/// Apply tint (colorize)
pub fn tint(img: *Image, tint_color: Color) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                // Multiply blend
                img.setPixel(x, y, Color{
                    .r = @intCast(@as(u16, c.r) * @as(u16, tint_color.r) / 255),
                    .g = @intCast(@as(u16, c.g) * @as(u16, tint_color.g) / 255),
                    .b = @intCast(@as(u16, c.b) * @as(u16, tint_color.b) / 255),
                    .a = c.a,
                });
            }
        }
    }
}

/// Apply sepia tone
pub fn sepia(img: *Image) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                const r: f32 = @floatFromInt(c.r);
                const g: f32 = @floatFromInt(c.g);
                const b: f32 = @floatFromInt(c.b);

                const new_r = std.math.clamp(0.393 * r + 0.769 * g + 0.189 * b, 0, 255);
                const new_g = std.math.clamp(0.349 * r + 0.686 * g + 0.168 * b, 0, 255);
                const new_b = std.math.clamp(0.272 * r + 0.534 * g + 0.131 * b, 0, 255);

                img.setPixel(x, y, Color{
                    .r = @intFromFloat(new_r),
                    .g = @intFromFloat(new_g),
                    .b = @intFromFloat(new_b),
                    .a = c.a,
                });
            }
        }
    }
}

// ============================================================================
// Brightness, Contrast, Saturation
// ============================================================================

/// Adjust brightness (-1.0 to 1.0, 0 = no change)
pub fn brightness(img: *Image, amount: f32) void {
    const offset: i16 = @intFromFloat(amount * 255);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = @intCast(std.math.clamp(@as(i16, c.r) + offset, 0, 255)),
                    .g = @intCast(std.math.clamp(@as(i16, c.g) + offset, 0, 255)),
                    .b = @intCast(std.math.clamp(@as(i16, c.b) + offset, 0, 255)),
                    .a = c.a,
                });
            }
        }
    }
}

/// Adjust contrast (0 = gray, 1 = no change, 2 = double contrast)
pub fn contrast(img: *Image, factor: f32) void {
    const f = (259 * (factor * 255 + 255)) / (255 * (259 - factor * 255));

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = @intFromFloat(std.math.clamp(f * (@as(f32, @floatFromInt(c.r)) - 128) + 128, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(f * (@as(f32, @floatFromInt(c.g)) - 128) + 128, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(f * (@as(f32, @floatFromInt(c.b)) - 128) + 128, 0, 255)),
                    .a = c.a,
                });
            }
        }
    }
}

/// Adjust saturation (0 = grayscale, 1 = no change, 2 = double saturation)
pub fn saturation(img: *Image, factor: f32) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                const gray: f32 = @floatFromInt(c.toGrayscale());
                const r: f32 = @floatFromInt(c.r);
                const g: f32 = @floatFromInt(c.g);
                const b: f32 = @floatFromInt(c.b);

                img.setPixel(x, y, Color{
                    .r = @intFromFloat(std.math.clamp(gray + (r - gray) * factor, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(gray + (g - gray) * factor, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(gray + (b - gray) * factor, 0, 255)),
                    .a = c.a,
                });
            }
        }
    }
}

/// Modulate brightness, saturation, and hue at once
pub fn modulate(img: *Image, brightness_mult: f32, saturation_mult: f32, hue_rotation: f32) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                var hsl = rgbToHsl(c);
                hsl.l = std.math.clamp(hsl.l * brightness_mult, 0, 1);
                hsl.s = std.math.clamp(hsl.s * saturation_mult, 0, 1);
                hsl.h = @mod(hsl.h + hue_rotation, 360);

                var rgb = hslToRgb(hsl);
                rgb.a = c.a;
                img.setPixel(x, y, rgb);
            }
        }
    }
}

/// Apply gamma correction
pub fn gamma(img: *Image, gamma_value: f32) void {
    const inv_gamma = 1.0 / gamma_value;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = @intFromFloat(std.math.pow(f32, @as(f32, @floatFromInt(c.r)) / 255.0, inv_gamma) * 255.0),
                    .g = @intFromFloat(std.math.pow(f32, @as(f32, @floatFromInt(c.g)) / 255.0, inv_gamma) * 255.0),
                    .b = @intFromFloat(std.math.pow(f32, @as(f32, @floatFromInt(c.b)) / 255.0, inv_gamma) * 255.0),
                    .a = c.a,
                });
            }
        }
    }
}

/// Normalize (stretch histogram to full range)
pub fn normalize(img: *Image) void {
    // Find min/max values
    var min_r: u8 = 255;
    var max_r: u8 = 0;
    var min_g: u8 = 255;
    var max_g: u8 = 0;
    var min_b: u8 = 255;
    var max_b: u8 = 0;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                min_r = @min(min_r, c.r);
                max_r = @max(max_r, c.r);
                min_g = @min(min_g, c.g);
                max_g = @max(max_g, c.g);
                min_b = @min(min_b, c.b);
                max_b = @max(max_b, c.b);
            }
        }
    }

    // Apply normalization
    const range_r = @max(1, max_r - min_r);
    const range_g = @max(1, max_g - min_g);
    const range_b = @max(1, max_b - min_b);

    y = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = @intCast((@as(u16, c.r -| min_r) * 255) / @as(u16, range_r)),
                    .g = @intCast((@as(u16, c.g -| min_g) * 255) / @as(u16, range_g)),
                    .b = @intCast((@as(u16, c.b -| min_b) * 255) / @as(u16, range_b)),
                    .a = c.a,
                });
            }
        }
    }
}

/// Apply threshold (convert to black and white)
pub fn threshold(img: *Image, threshold_value: u8) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                const gray = c.toGrayscale();
                const value: u8 = if (gray >= threshold_value) 255 else 0;
                img.setPixel(x, y, Color{ .r = value, .g = value, .b = value, .a = c.a });
            }
        }
    }
}

/// Linear transform: output = a * input + b
pub fn linear(img: *Image, a: f32, b: f32) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                img.setPixel(x, y, Color{
                    .r = @intFromFloat(std.math.clamp(a * @as(f32, @floatFromInt(c.r)) + b, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(a * @as(f32, @floatFromInt(c.g)) + b, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(a * @as(f32, @floatFromInt(c.b)) + b, 0, 255)),
                    .a = c.a,
                });
            }
        }
    }
}

/// Apply color matrix transformation (recombination)
/// Matrix is 3x3 for RGB channels
pub fn recomb(img: *Image, matrix: [3][3]f32) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |c| {
                const r: f32 = @floatFromInt(c.r);
                const g: f32 = @floatFromInt(c.g);
                const b: f32 = @floatFromInt(c.b);

                const new_r = matrix[0][0] * r + matrix[0][1] * g + matrix[0][2] * b;
                const new_g = matrix[1][0] * r + matrix[1][1] * g + matrix[1][2] * b;
                const new_b = matrix[2][0] * r + matrix[2][1] * g + matrix[2][2] * b;

                img.setPixel(x, y, Color{
                    .r = @intFromFloat(std.math.clamp(new_r, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(new_g, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(new_b, 0, 255)),
                    .a = c.a,
                });
            }
        }
    }
}

// ============================================================================
// Color Space Conversions
// ============================================================================

pub const HSL = struct {
    h: f32, // 0-360
    s: f32, // 0-1
    l: f32, // 0-1
};

pub fn rgbToHsl(c: Color) HSL {
    const r: f32 = @as(f32, @floatFromInt(c.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(c.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(c.b)) / 255.0;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const delta = max_val - min_val;

    var h: f32 = 0;
    var s: f32 = 0;
    const l = (max_val + min_val) / 2;

    if (delta > 0) {
        s = if (l < 0.5) delta / (max_val + min_val) else delta / (2 - max_val - min_val);

        if (max_val == r) {
            h = (g - b) / delta + (if (g < b) @as(f32, 6) else @as(f32, 0));
        } else if (max_val == g) {
            h = (b - r) / delta + 2;
        } else {
            h = (r - g) / delta + 4;
        }
        h *= 60;
    }

    return HSL{ .h = h, .s = s, .l = l };
}

pub fn hslToRgb(hsl: HSL) Color {
    if (hsl.s == 0) {
        const v: u8 = @intFromFloat(hsl.l * 255);
        return Color{ .r = v, .g = v, .b = v, .a = 255 };
    }

    const q = if (hsl.l < 0.5) hsl.l * (1 + hsl.s) else hsl.l + hsl.s - hsl.l * hsl.s;
    const p = 2 * hsl.l - q;
    const h = hsl.h / 360;

    return Color{
        .r = @intFromFloat(hueToRgb(p, q, h + 1.0 / 3.0) * 255),
        .g = @intFromFloat(hueToRgb(p, q, h) * 255),
        .b = @intFromFloat(hueToRgb(p, q, h - 1.0 / 3.0) * 255),
        .a = 255,
    };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;

    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

pub const HSV = struct {
    h: f32, // 0-360
    s: f32, // 0-1
    v: f32, // 0-1
};

pub fn rgbToHsv(c: Color) HSV {
    const r: f32 = @as(f32, @floatFromInt(c.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(c.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(c.b)) / 255.0;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const delta = max_val - min_val;

    var h: f32 = 0;
    const s: f32 = if (max_val == 0) 0 else delta / max_val;
    const v = max_val;

    if (delta > 0) {
        if (max_val == r) {
            h = (g - b) / delta + (if (g < b) @as(f32, 6) else @as(f32, 0));
        } else if (max_val == g) {
            h = (b - r) / delta + 2;
        } else {
            h = (r - g) / delta + 4;
        }
        h *= 60;
    }

    return HSV{ .h = h, .s = s, .v = v };
}

pub fn hsvToRgb(hsv: HSV) Color {
    if (hsv.s == 0) {
        const v: u8 = @intFromFloat(hsv.v * 255);
        return Color{ .r = v, .g = v, .b = v, .a = 255 };
    }

    const h = hsv.h / 60;
    const i: u32 = @intFromFloat(@floor(h));
    const f = h - @as(f32, @floatFromInt(i));

    const p = hsv.v * (1 - hsv.s);
    const q = hsv.v * (1 - hsv.s * f);
    const t = hsv.v * (1 - hsv.s * (1 - f));

    const v = hsv.v;

    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    switch (i % 6) {
        0 => {
            r = v;
            g = t;
            b = p;
        },
        1 => {
            r = q;
            g = v;
            b = p;
        },
        2 => {
            r = p;
            g = v;
            b = t;
        },
        3 => {
            r = p;
            g = q;
            b = v;
        },
        4 => {
            r = t;
            g = p;
            b = v;
        },
        else => {
            r = v;
            g = p;
            b = q;
        },
    }

    return Color{
        .r = @intFromFloat(r * 255),
        .g = @intFromFloat(g * 255),
        .b = @intFromFloat(b * 255),
        .a = 255,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "RGB to HSL conversion" {
    const red = Color.RED;
    const hsl = rgbToHsl(red);

    try std.testing.expectApproxEqAbs(@as(f32, 0), hsl.h, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsl.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), hsl.l, 0.01);
}

test "HSL to RGB conversion" {
    const hsl = HSL{ .h = 0, .s = 1, .l = 0.5 };
    const rgb = hslToRgb(hsl);

    try std.testing.expectEqual(@as(u8, 255), rgb.r);
    try std.testing.expectEqual(@as(u8, 0), rgb.g);
    try std.testing.expectEqual(@as(u8, 0), rgb.b);
}

test "Grayscale conversion" {
    var img = try Image.init(std.testing.allocator, 2, 2, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    grayscale(&img);

    const pixel = img.getPixel(0, 0);
    try std.testing.expect(pixel != null);
    // Red has specific grayscale value (around 76)
    try std.testing.expectEqual(pixel.?.r, pixel.?.g);
    try std.testing.expectEqual(pixel.?.g, pixel.?.b);
}
