const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;

// ============================================================================
// Color Space Types
// ============================================================================

pub const ColorSpace = enum {
    srgb,
    linear_rgb,
    adobe_rgb,
    prophoto_rgb,
    display_p3,
    rec2020,
    xyz,
    lab,
    lch,
    cmyk,
};

/// RGB color with floating point precision
pub const RGBf = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,
};

/// CMYK color
pub const CMYK = struct {
    c: f64, // Cyan 0-1
    m: f64, // Magenta 0-1
    y: f64, // Yellow 0-1
    k: f64, // Key (black) 0-1
};

/// CIE XYZ color
pub const XYZ = struct {
    x: f64,
    y: f64,
    z: f64,
};

/// CIE LAB color
pub const LAB = struct {
    l: f64, // Lightness 0-100
    a: f64, // Green-Red -128 to 127
    b: f64, // Blue-Yellow -128 to 127
};

/// CIE LCH color (polar form of LAB)
pub const LCH = struct {
    l: f64, // Lightness 0-100
    c: f64, // Chroma 0-~180
    h: f64, // Hue 0-360 degrees
};

/// HSL color
pub const HSL = struct {
    h: f64, // Hue 0-360
    s: f64, // Saturation 0-1
    l: f64, // Lightness 0-1
};

/// HSV/HSB color
pub const HSV = struct {
    h: f64, // Hue 0-360
    s: f64, // Saturation 0-1
    v: f64, // Value/Brightness 0-1
};

// ============================================================================
// White Points (D50 and D65)
// ============================================================================

pub const WhitePoint = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const D50 = WhitePoint{ .x = 0.96422, .y = 1.0, .z = 0.82521 };
pub const D65 = WhitePoint{ .x = 0.95047, .y = 1.0, .z = 1.08883 };

// ============================================================================
// RGB Color Space Matrices
// ============================================================================

/// Matrix for RGB to XYZ conversion
const Matrix3x3 = [3][3]f64;

// sRGB to XYZ (D65)
const SRGB_TO_XYZ: Matrix3x3 = .{
    .{ 0.4124564, 0.3575761, 0.1804375 },
    .{ 0.2126729, 0.7151522, 0.0721750 },
    .{ 0.0193339, 0.1191920, 0.9503041 },
};

const XYZ_TO_SRGB: Matrix3x3 = .{
    .{ 3.2404542, -1.5371385, -0.4985314 },
    .{ -0.9692660, 1.8760108, 0.0415560 },
    .{ 0.0556434, -0.2040259, 1.0572252 },
};

// Adobe RGB to XYZ (D65)
const ADOBE_RGB_TO_XYZ: Matrix3x3 = .{
    .{ 0.5767309, 0.1855540, 0.1881852 },
    .{ 0.2973769, 0.6273491, 0.0752741 },
    .{ 0.0270343, 0.0706872, 0.9911085 },
};

const XYZ_TO_ADOBE_RGB: Matrix3x3 = .{
    .{ 2.0413690, -0.5649464, -0.3446944 },
    .{ -0.9692660, 1.8760108, 0.0415560 },
    .{ 0.0134474, -0.1183897, 1.0154096 },
};

// ProPhoto RGB to XYZ (D50)
const PROPHOTO_TO_XYZ: Matrix3x3 = .{
    .{ 0.7976749, 0.1351917, 0.0313534 },
    .{ 0.2880402, 0.7118741, 0.0000857 },
    .{ 0.0000000, 0.0000000, 0.8252100 },
};

const XYZ_TO_PROPHOTO: Matrix3x3 = .{
    .{ 1.3459433, -0.2556075, -0.0511118 },
    .{ -0.5445989, 1.5081673, 0.0205351 },
    .{ 0.0000000, 0.0000000, 1.2118128 },
};

// Display P3 to XYZ (D65)
const P3_TO_XYZ: Matrix3x3 = .{
    .{ 0.4865709, 0.2656677, 0.1982173 },
    .{ 0.2289746, 0.6917385, 0.0792869 },
    .{ 0.0000000, 0.0451134, 1.0439444 },
};

const XYZ_TO_P3: Matrix3x3 = .{
    .{ 2.4934969, -0.9313836, -0.4027108 },
    .{ -0.8294890, 1.7626641, 0.0236247 },
    .{ 0.0358458, -0.0761724, 0.9568845 },
};

// Rec. 2020 to XYZ (D65)
const REC2020_TO_XYZ: Matrix3x3 = .{
    .{ 0.6369580, 0.1446169, 0.1688810 },
    .{ 0.2627002, 0.6779981, 0.0593017 },
    .{ 0.0000000, 0.0280727, 1.0609851 },
};

const XYZ_TO_REC2020: Matrix3x3 = .{
    .{ 1.7166512, -0.3556708, -0.2533663 },
    .{ -0.6666844, 1.6164812, 0.0157685 },
    .{ 0.0176399, -0.0427706, 0.9421031 },
};

// ============================================================================
// Gamma Functions
// ============================================================================

/// sRGB gamma encode (linear to sRGB)
pub fn srgbGammaEncode(linear: f64) f64 {
    if (linear <= 0.0031308) {
        return linear * 12.92;
    }
    return 1.055 * std.math.pow(f64, linear, 1.0 / 2.4) - 0.055;
}

/// sRGB gamma decode (sRGB to linear)
pub fn srgbGammaDecode(encoded: f64) f64 {
    if (encoded <= 0.04045) {
        return encoded / 12.92;
    }
    return std.math.pow(f64, (encoded + 0.055) / 1.055, 2.4);
}

/// Adobe RGB gamma (2.2)
pub fn adobeRgbGammaEncode(linear: f64) f64 {
    return std.math.pow(f64, @max(0, linear), 1.0 / 2.19921875);
}

pub fn adobeRgbGammaDecode(encoded: f64) f64 {
    return std.math.pow(f64, @max(0, encoded), 2.19921875);
}

/// ProPhoto RGB gamma (1.8)
pub fn prophotoGammaEncode(linear: f64) f64 {
    if (linear <= 0.001953) {
        return linear * 16.0;
    }
    return std.math.pow(f64, linear, 1.0 / 1.8);
}

pub fn prophotoGammaDecode(encoded: f64) f64 {
    if (encoded <= 0.03125) {
        return encoded / 16.0;
    }
    return std.math.pow(f64, encoded, 1.8);
}

// ============================================================================
// Color Conversions
// ============================================================================

/// Convert sRGB (0-255) to linear RGB (0-1)
pub fn srgbToLinear(color: Color) RGBf {
    return RGBf{
        .r = srgbGammaDecode(@as(f64, @floatFromInt(color.r)) / 255.0),
        .g = srgbGammaDecode(@as(f64, @floatFromInt(color.g)) / 255.0),
        .b = srgbGammaDecode(@as(f64, @floatFromInt(color.b)) / 255.0),
        .a = @as(f64, @floatFromInt(color.a)) / 255.0,
    };
}

/// Convert linear RGB (0-1) to sRGB (0-255)
pub fn linearToSrgb(rgb: RGBf) Color {
    return Color{
        .r = @intFromFloat(std.math.clamp(srgbGammaEncode(rgb.r) * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(srgbGammaEncode(rgb.g) * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(srgbGammaEncode(rgb.b) * 255.0, 0, 255)),
        .a = @intFromFloat(std.math.clamp(rgb.a * 255.0, 0, 255)),
    };
}

/// Convert RGB to XYZ using specified matrix
pub fn rgbToXyz(rgb: RGBf, matrix: Matrix3x3) XYZ {
    return XYZ{
        .x = rgb.r * matrix[0][0] + rgb.g * matrix[0][1] + rgb.b * matrix[0][2],
        .y = rgb.r * matrix[1][0] + rgb.g * matrix[1][1] + rgb.b * matrix[1][2],
        .z = rgb.r * matrix[2][0] + rgb.g * matrix[2][1] + rgb.b * matrix[2][2],
    };
}

/// Convert XYZ to RGB using specified matrix
pub fn xyzToRgb(xyz: XYZ, matrix: Matrix3x3) RGBf {
    return RGBf{
        .r = xyz.x * matrix[0][0] + xyz.y * matrix[0][1] + xyz.z * matrix[0][2],
        .g = xyz.x * matrix[1][0] + xyz.y * matrix[1][1] + xyz.z * matrix[1][2],
        .b = xyz.x * matrix[2][0] + xyz.y * matrix[2][1] + xyz.z * matrix[2][2],
    };
}

/// Convert XYZ to LAB
pub fn xyzToLab(xyz: XYZ, white: WhitePoint) LAB {
    const epsilon: f64 = 0.008856;
    const kappa: f64 = 903.3;

    var x = xyz.x / white.x;
    var y = xyz.y / white.y;
    var z = xyz.z / white.z;

    x = if (x > epsilon) std.math.cbrt(x) else (kappa * x + 16.0) / 116.0;
    y = if (y > epsilon) std.math.cbrt(y) else (kappa * y + 16.0) / 116.0;
    z = if (z > epsilon) std.math.cbrt(z) else (kappa * z + 16.0) / 116.0;

    return LAB{
        .l = 116.0 * y - 16.0,
        .a = 500.0 * (x - y),
        .b = 200.0 * (y - z),
    };
}

/// Convert LAB to XYZ
pub fn labToXyz(lab: LAB, white: WhitePoint) XYZ {
    const epsilon: f64 = 0.008856;
    const kappa: f64 = 903.3;

    const fy = (lab.l + 16.0) / 116.0;
    const fx = lab.a / 500.0 + fy;
    const fz = fy - lab.b / 200.0;

    const xr = if (fx * fx * fx > epsilon) fx * fx * fx else (116.0 * fx - 16.0) / kappa;
    const yr = if (lab.l > kappa * epsilon) std.math.pow(f64, (lab.l + 16.0) / 116.0, 3) else lab.l / kappa;
    const zr = if (fz * fz * fz > epsilon) fz * fz * fz else (116.0 * fz - 16.0) / kappa;

    return XYZ{
        .x = xr * white.x,
        .y = yr * white.y,
        .z = zr * white.z,
    };
}

/// Convert LAB to LCH
pub fn labToLch(lab: LAB) LCH {
    const c = @sqrt(lab.a * lab.a + lab.b * lab.b);
    var h = std.math.atan2(lab.b, lab.a) * 180.0 / std.math.pi;
    if (h < 0) h += 360.0;

    return LCH{
        .l = lab.l,
        .c = c,
        .h = h,
    };
}

/// Convert LCH to LAB
pub fn lchToLab(lch: LCH) LAB {
    const h_rad = lch.h * std.math.pi / 180.0;
    return LAB{
        .l = lch.l,
        .a = lch.c * @cos(h_rad),
        .b = lch.c * @sin(h_rad),
    };
}

/// Convert RGB to CMYK
pub fn rgbToCmyk(color: Color) CMYK {
    const r: f64 = @as(f64, @floatFromInt(color.r)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt(color.g)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color.b)) / 255.0;

    const k = 1.0 - @max(r, @max(g, b));

    if (k >= 1.0) {
        return CMYK{ .c = 0, .m = 0, .y = 0, .k = 1.0 };
    }

    return CMYK{
        .c = (1.0 - r - k) / (1.0 - k),
        .m = (1.0 - g - k) / (1.0 - k),
        .y = (1.0 - b - k) / (1.0 - k),
        .k = k,
    };
}

/// Convert CMYK to RGB
pub fn cmykToRgb(cmyk: CMYK) Color {
    const r = (1.0 - cmyk.c) * (1.0 - cmyk.k);
    const g = (1.0 - cmyk.m) * (1.0 - cmyk.k);
    const b = (1.0 - cmyk.y) * (1.0 - cmyk.k);

    return Color{
        .r = @intFromFloat(std.math.clamp(r * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(g * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(b * 255.0, 0, 255)),
        .a = 255,
    };
}

/// Convert RGB to HSL
pub fn rgbToHsl(color: Color) HSL {
    const r: f64 = @as(f64, @floatFromInt(color.r)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt(color.g)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color.b)) / 255.0;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const l = (max_val + min_val) / 2.0;

    if (max_val == min_val) {
        return HSL{ .h = 0, .s = 0, .l = l };
    }

    const d = max_val - min_val;
    const s = if (l > 0.5) d / (2.0 - max_val - min_val) else d / (max_val + min_val);

    var h: f64 = 0;
    if (max_val == r) {
        h = (g - b) / d + (if (g < b) 6.0 else 0.0);
    } else if (max_val == g) {
        h = (b - r) / d + 2.0;
    } else {
        h = (r - g) / d + 4.0;
    }
    h *= 60.0;

    return HSL{ .h = h, .s = s, .l = l };
}

/// Convert HSL to RGB
pub fn hslToRgb(hsl: HSL) Color {
    if (hsl.s == 0) {
        const v: u8 = @intFromFloat(std.math.clamp(hsl.l * 255.0, 0, 255));
        return Color{ .r = v, .g = v, .b = v, .a = 255 };
    }

    const q = if (hsl.l < 0.5) hsl.l * (1.0 + hsl.s) else hsl.l + hsl.s - hsl.l * hsl.s;
    const p = 2.0 * hsl.l - q;

    const hue2rgb = struct {
        fn call(pp: f64, qq: f64, t: f64) f64 {
            var tt = t;
            if (tt < 0) tt += 1;
            if (tt > 1) tt -= 1;
            if (tt < 1.0 / 6.0) return pp + (qq - pp) * 6.0 * tt;
            if (tt < 1.0 / 2.0) return qq;
            if (tt < 2.0 / 3.0) return pp + (qq - pp) * (2.0 / 3.0 - tt) * 6.0;
            return pp;
        }
    }.call;

    return Color{
        .r = @intFromFloat(std.math.clamp(hue2rgb(p, q, hsl.h / 360.0 + 1.0 / 3.0) * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(hue2rgb(p, q, hsl.h / 360.0) * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(hue2rgb(p, q, hsl.h / 360.0 - 1.0 / 3.0) * 255.0, 0, 255)),
        .a = 255,
    };
}

/// Convert RGB to HSV
pub fn rgbToHsv(color: Color) HSV {
    const r: f64 = @as(f64, @floatFromInt(color.r)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt(color.g)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(color.b)) / 255.0;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const d = max_val - min_val;

    var h: f64 = 0;
    const s = if (max_val == 0) 0 else d / max_val;
    const v = max_val;

    if (d != 0) {
        if (max_val == r) {
            h = (g - b) / d + (if (g < b) 6.0 else 0.0);
        } else if (max_val == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h *= 60.0;
    }

    return HSV{ .h = h, .s = s, .v = v };
}

/// Convert HSV to RGB
pub fn hsvToRgb(hsv: HSV) Color {
    if (hsv.s == 0) {
        const v: u8 = @intFromFloat(std.math.clamp(hsv.v * 255.0, 0, 255));
        return Color{ .r = v, .g = v, .b = v, .a = 255 };
    }

    const h = hsv.h / 60.0;
    const i = @floor(h);
    const f = h - i;
    const p = hsv.v * (1.0 - hsv.s);
    const q = hsv.v * (1.0 - hsv.s * f);
    const t = hsv.v * (1.0 - hsv.s * (1.0 - f));

    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;

    const sector: u32 = @intFromFloat(@mod(i, 6));
    switch (sector) {
        0 => {
            r = hsv.v;
            g = t;
            b = p;
        },
        1 => {
            r = q;
            g = hsv.v;
            b = p;
        },
        2 => {
            r = p;
            g = hsv.v;
            b = t;
        },
        3 => {
            r = p;
            g = q;
            b = hsv.v;
        },
        4 => {
            r = t;
            g = p;
            b = hsv.v;
        },
        else => {
            r = hsv.v;
            g = p;
            b = q;
        },
    }

    return Color{
        .r = @intFromFloat(std.math.clamp(r * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(g * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(b * 255.0, 0, 255)),
        .a = 255,
    };
}

/// Convert sRGB color to LAB
pub fn srgbToLab(color: Color) LAB {
    const linear = srgbToLinear(color);
    const xyz = rgbToXyz(linear, SRGB_TO_XYZ);
    return xyzToLab(xyz, D65);
}

/// Convert LAB to sRGB color
pub fn labToSrgb(lab: LAB) Color {
    const xyz = labToXyz(lab, D65);
    const linear = xyzToRgb(xyz, XYZ_TO_SRGB);
    return linearToSrgb(linear);
}

// ============================================================================
// Color Space Conversion for Images
// ============================================================================

/// Convert entire image between color spaces
pub fn convertColorSpace(image: *Image, from: ColorSpace, to: ColorSpace) void {
    if (from == to) return;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse continue;
            const converted = convertColor(color, from, to);
            image.setPixel(x, y, converted);
        }
    }
}

/// Convert a single color between color spaces
pub fn convertColor(color: Color, from: ColorSpace, to: ColorSpace) Color {
    if (from == to) return color;

    // Convert to XYZ first
    var xyz: XYZ = undefined;

    switch (from) {
        .srgb => {
            const linear = srgbToLinear(color);
            xyz = rgbToXyz(linear, SRGB_TO_XYZ);
        },
        .linear_rgb => {
            const linear = RGBf{
                .r = @as(f64, @floatFromInt(color.r)) / 255.0,
                .g = @as(f64, @floatFromInt(color.g)) / 255.0,
                .b = @as(f64, @floatFromInt(color.b)) / 255.0,
            };
            xyz = rgbToXyz(linear, SRGB_TO_XYZ);
        },
        .adobe_rgb => {
            const linear = RGBf{
                .r = adobeRgbGammaDecode(@as(f64, @floatFromInt(color.r)) / 255.0),
                .g = adobeRgbGammaDecode(@as(f64, @floatFromInt(color.g)) / 255.0),
                .b = adobeRgbGammaDecode(@as(f64, @floatFromInt(color.b)) / 255.0),
            };
            xyz = rgbToXyz(linear, ADOBE_RGB_TO_XYZ);
        },
        .prophoto_rgb => {
            const linear = RGBf{
                .r = prophotoGammaDecode(@as(f64, @floatFromInt(color.r)) / 255.0),
                .g = prophotoGammaDecode(@as(f64, @floatFromInt(color.g)) / 255.0),
                .b = prophotoGammaDecode(@as(f64, @floatFromInt(color.b)) / 255.0),
            };
            xyz = rgbToXyz(linear, PROPHOTO_TO_XYZ);
        },
        .display_p3 => {
            const linear = srgbToLinear(color);
            xyz = rgbToXyz(linear, P3_TO_XYZ);
        },
        .rec2020 => {
            const linear = srgbToLinear(color);
            xyz = rgbToXyz(linear, REC2020_TO_XYZ);
        },
        else => {
            // Assume sRGB
            const linear = srgbToLinear(color);
            xyz = rgbToXyz(linear, SRGB_TO_XYZ);
        },
    }

    // Convert from XYZ to target
    switch (to) {
        .srgb => {
            const linear = xyzToRgb(xyz, XYZ_TO_SRGB);
            return linearToSrgb(linear);
        },
        .linear_rgb => {
            const linear = xyzToRgb(xyz, XYZ_TO_SRGB);
            return Color{
                .r = @intFromFloat(std.math.clamp(linear.r * 255.0, 0, 255)),
                .g = @intFromFloat(std.math.clamp(linear.g * 255.0, 0, 255)),
                .b = @intFromFloat(std.math.clamp(linear.b * 255.0, 0, 255)),
                .a = color.a,
            };
        },
        .adobe_rgb => {
            const linear = xyzToRgb(xyz, XYZ_TO_ADOBE_RGB);
            return Color{
                .r = @intFromFloat(std.math.clamp(adobeRgbGammaEncode(linear.r) * 255.0, 0, 255)),
                .g = @intFromFloat(std.math.clamp(adobeRgbGammaEncode(linear.g) * 255.0, 0, 255)),
                .b = @intFromFloat(std.math.clamp(adobeRgbGammaEncode(linear.b) * 255.0, 0, 255)),
                .a = color.a,
            };
        },
        .prophoto_rgb => {
            const linear = xyzToRgb(xyz, XYZ_TO_PROPHOTO);
            return Color{
                .r = @intFromFloat(std.math.clamp(prophotoGammaEncode(linear.r) * 255.0, 0, 255)),
                .g = @intFromFloat(std.math.clamp(prophotoGammaEncode(linear.g) * 255.0, 0, 255)),
                .b = @intFromFloat(std.math.clamp(prophotoGammaEncode(linear.b) * 255.0, 0, 255)),
                .a = color.a,
            };
        },
        .display_p3 => {
            const linear = xyzToRgb(xyz, XYZ_TO_P3);
            return linearToSrgb(linear);
        },
        .rec2020 => {
            const linear = xyzToRgb(xyz, XYZ_TO_REC2020);
            return linearToSrgb(linear);
        },
        else => {
            const linear = xyzToRgb(xyz, XYZ_TO_SRGB);
            return linearToSrgb(linear);
        },
    }
}

// ============================================================================
// LUT (Look-Up Table) Support
// ============================================================================

/// 3D LUT structure
pub const LUT3D = struct {
    size: u32, // Grid size (typically 17, 33, or 65)
    data: []Color, // size^3 entries
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: u32) !LUT3D {
        const data = try allocator.alloc(Color, size * size * size);

        // Initialize with identity
        for (0..size) |b| {
            for (0..size) |g| {
                for (0..size) |r| {
                    const idx = b * size * size + g * size + r;
                    data[idx] = Color{
                        .r = @intFromFloat(@as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(size - 1)) * 255.0),
                        .g = @intFromFloat(@as(f64, @floatFromInt(g)) / @as(f64, @floatFromInt(size - 1)) * 255.0),
                        .b = @intFromFloat(@as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(size - 1)) * 255.0),
                        .a = 255,
                    };
                }
            }
        }

        return LUT3D{
            .size = size,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LUT3D) void {
        self.allocator.free(self.data);
    }

    /// Apply LUT to a color with trilinear interpolation
    pub fn apply(self: *const LUT3D, color: Color) Color {
        const size_f: f64 = @floatFromInt(self.size - 1);

        // Normalize to LUT coordinates
        const r = @as(f64, @floatFromInt(color.r)) / 255.0 * size_f;
        const g = @as(f64, @floatFromInt(color.g)) / 255.0 * size_f;
        const b = @as(f64, @floatFromInt(color.b)) / 255.0 * size_f;

        // Get integer and fractional parts
        const r0: u32 = @min(@as(u32, @intFromFloat(r)), self.size - 2);
        const g0: u32 = @min(@as(u32, @intFromFloat(g)), self.size - 2);
        const b0: u32 = @min(@as(u32, @intFromFloat(b)), self.size - 2);

        const rf = r - @as(f64, @floatFromInt(r0));
        const gf = g - @as(f64, @floatFromInt(g0));
        const bf = b - @as(f64, @floatFromInt(b0));

        // Trilinear interpolation
        const c000 = self.get(r0, g0, b0);
        const c100 = self.get(r0 + 1, g0, b0);
        const c010 = self.get(r0, g0 + 1, b0);
        const c110 = self.get(r0 + 1, g0 + 1, b0);
        const c001 = self.get(r0, g0, b0 + 1);
        const c101 = self.get(r0 + 1, g0, b0 + 1);
        const c011 = self.get(r0, g0 + 1, b0 + 1);
        const c111 = self.get(r0 + 1, g0 + 1, b0 + 1);

        const interp = struct {
            fn lerp(a: u8, bb: u8, t: f64) f64 {
                return @as(f64, @floatFromInt(a)) * (1.0 - t) + @as(f64, @floatFromInt(bb)) * t;
            }
        };

        // Interpolate along r axis
        const c00r = interp.lerp(c000.r, c100.r, rf);
        const c01r = interp.lerp(c001.r, c101.r, rf);
        const c10r = interp.lerp(c010.r, c110.r, rf);
        const c11r = interp.lerp(c011.r, c111.r, rf);

        const c00g = interp.lerp(c000.g, c100.g, rf);
        const c01g = interp.lerp(c001.g, c101.g, rf);
        const c10g = interp.lerp(c010.g, c110.g, rf);
        const c11g = interp.lerp(c011.g, c111.g, rf);

        const c00b = interp.lerp(c000.b, c100.b, rf);
        const c01b = interp.lerp(c001.b, c101.b, rf);
        const c10b = interp.lerp(c010.b, c110.b, rf);
        const c11b = interp.lerp(c011.b, c111.b, rf);

        // Interpolate along g axis
        const c0r = c00r * (1.0 - gf) + c10r * gf;
        const c1r = c01r * (1.0 - gf) + c11r * gf;

        const c0g = c00g * (1.0 - gf) + c10g * gf;
        const c1g = c01g * (1.0 - gf) + c11g * gf;

        const c0b = c00b * (1.0 - gf) + c10b * gf;
        const c1b = c01b * (1.0 - gf) + c11b * gf;

        // Interpolate along b axis
        const final_r = c0r * (1.0 - bf) + c1r * bf;
        const final_g = c0g * (1.0 - bf) + c1g * bf;
        const final_b = c0b * (1.0 - bf) + c1b * bf;

        return Color{
            .r = @intFromFloat(std.math.clamp(final_r, 0, 255)),
            .g = @intFromFloat(std.math.clamp(final_g, 0, 255)),
            .b = @intFromFloat(std.math.clamp(final_b, 0, 255)),
            .a = color.a,
        };
    }

    fn get(self: *const LUT3D, r: u32, g: u32, b: u32) Color {
        return self.data[b * self.size * self.size + g * self.size + r];
    }

    pub fn set(self: *LUT3D, r: u32, g: u32, b: u32, color: Color) void {
        self.data[b * self.size * self.size + g * self.size + r] = color;
    }
};

/// 1D LUT for per-channel adjustments
pub const LUT1D = struct {
    r: [256]u8,
    g: [256]u8,
    b: [256]u8,

    /// Create identity LUT
    pub fn identity() LUT1D {
        var lut = LUT1D{
            .r = undefined,
            .g = undefined,
            .b = undefined,
        };

        for (0..256) |i| {
            lut.r[i] = @intCast(i);
            lut.g[i] = @intCast(i);
            lut.b[i] = @intCast(i);
        }

        return lut;
    }

    /// Create contrast curve LUT
    pub fn contrast(factor: f64) LUT1D {
        var lut = LUT1D.identity();

        for (0..256) |i| {
            const normalized = (@as(f64, @floatFromInt(i)) / 255.0 - 0.5) * factor + 0.5;
            const val: u8 = @intFromFloat(std.math.clamp(normalized * 255.0, 0, 255));
            lut.r[i] = val;
            lut.g[i] = val;
            lut.b[i] = val;
        }

        return lut;
    }

    /// Create gamma curve LUT
    pub fn gamma(g: f64) LUT1D {
        var lut = LUT1D.identity();

        for (0..256) |i| {
            const normalized = @as(f64, @floatFromInt(i)) / 255.0;
            const val: u8 = @intFromFloat(std.math.clamp(std.math.pow(f64, normalized, 1.0 / g) * 255.0, 0, 255));
            lut.r[i] = val;
            lut.g[i] = val;
            lut.b[i] = val;
        }

        return lut;
    }

    /// Apply LUT to a color
    pub fn apply(self: *const LUT1D, color: Color) Color {
        return Color{
            .r = self.r[color.r],
            .g = self.g[color.g],
            .b = self.b[color.b],
            .a = color.a,
        };
    }
};

/// Apply 3D LUT to entire image
pub fn applyLUT3D(image: *Image, lut: *const LUT3D) void {
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse continue;
            image.setPixel(x, y, lut.apply(color));
        }
    }
}

/// Apply 1D LUT to entire image
pub fn applyLUT1D(image: *Image, lut: *const LUT1D) void {
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse continue;
            image.setPixel(x, y, lut.apply(color));
        }
    }
}

// ============================================================================
// Color Grading Presets
// ============================================================================

/// Common color grading effects
pub const ColorGrade = struct {
    /// Warm/sunset look
    pub fn warm(image: *Image) void {
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                var color = image.getPixel(x, y) orelse continue;
                // Add warmth
                color.r = @intFromFloat(@min(@as(f32, @floatFromInt(color.r)) * 1.1, 255));
                color.b = @intFromFloat(@max(@as(f32, @floatFromInt(color.b)) * 0.9, 0));
                image.setPixel(x, y, color);
            }
        }
    }

    /// Cool/blue look
    pub fn cool(image: *Image) void {
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                var color = image.getPixel(x, y) orelse continue;
                color.r = @intFromFloat(@max(@as(f32, @floatFromInt(color.r)) * 0.9, 0));
                color.b = @intFromFloat(@min(@as(f32, @floatFromInt(color.b)) * 1.1, 255));
                image.setPixel(x, y, color);
            }
        }
    }

    /// Vintage/sepia-ish look
    pub fn vintage(image: *Image) void {
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse continue;
                const r: f32 = @floatFromInt(color.r);
                const g: f32 = @floatFromInt(color.g);
                const b: f32 = @floatFromInt(color.b);

                const new_r = r * 0.393 + g * 0.769 + b * 0.189;
                const new_g = r * 0.349 + g * 0.686 + b * 0.168;
                const new_b = r * 0.272 + g * 0.534 + b * 0.131;

                image.setPixel(x, y, Color{
                    .r = @intFromFloat(@min(new_r, 255)),
                    .g = @intFromFloat(@min(new_g, 255)),
                    .b = @intFromFloat(@min(new_b, 255)),
                    .a = color.a,
                });
            }
        }
    }

    /// Black and white with tint
    pub fn tintedBW(image: *Image, tint: Color) void {
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const color = image.getPixel(x, y) orelse continue;
                const gray = color.toGrayscale();

                image.setPixel(x, y, Color{
                    .r = @intFromFloat(@as(f32, @floatFromInt(gray)) * @as(f32, @floatFromInt(tint.r)) / 255.0),
                    .g = @intFromFloat(@as(f32, @floatFromInt(gray)) * @as(f32, @floatFromInt(tint.g)) / 255.0),
                    .b = @intFromFloat(@as(f32, @floatFromInt(gray)) * @as(f32, @floatFromInt(tint.b)) / 255.0),
                    .a = color.a,
                });
            }
        }
    }

    /// Cross-process effect
    pub fn crossProcess(image: *Image) void {
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                var color = image.getPixel(x, y) orelse continue;

                // Boost greens in shadows, blues in highlights
                const lum = color.toGrayscale();
                if (lum < 128) {
                    color.g = @intFromFloat(@min(@as(f32, @floatFromInt(color.g)) * 1.2, 255));
                } else {
                    color.b = @intFromFloat(@min(@as(f32, @floatFromInt(color.b)) * 1.15, 255));
                }

                image.setPixel(x, y, color);
            }
        }
    }
};

/// Calculate CIE Delta E (color difference) between two LAB colors
pub fn deltaE(lab1: LAB, lab2: LAB) f64 {
    const dl = lab1.l - lab2.l;
    const da = lab1.a - lab2.a;
    const db = lab1.b - lab2.b;
    return @sqrt(dl * dl + da * da + db * db);
}

/// Calculate perceptual color difference between two sRGB colors
pub fn colorDifference(c1: Color, c2: Color) f64 {
    const lab1 = srgbToLab(c1);
    const lab2 = srgbToLab(c2);
    return deltaE(lab1, lab2);
}
