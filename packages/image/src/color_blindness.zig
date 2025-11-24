const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Color Blindness Simulation
// ============================================================================

pub const ColorBlindnessType = enum {
    protanopia, // Red-blind (no L cones)
    protanomaly, // Red-weak
    deuteranopia, // Green-blind (no M cones)
    deuteranomaly, // Green-weak
    tritanopia, // Blue-blind (no S cones)
    tritanomaly, // Blue-weak
    achromatopsia, // Complete color blindness (monochrome)
    achromatomaly, // Blue cone monochromacy
};

pub const SimulationOptions = struct {
    severity: f32 = 1.0, // 0.0 to 1.0 (for anomalies)
    preserve_brightness: bool = true,
};

/// Simulates how an image appears to people with color blindness
pub fn simulateColorBlindness(
    allocator: std.mem.Allocator,
    img: *const Image,
    cb_type: ColorBlindnessType,
    options: SimulationOptions,
) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));
            const transformed = transformColor(pixel, cb_type, options);
            result.setPixel(@intCast(x), @intCast(y), transformed);
        }
    }

    return result;
}

fn transformColor(color: Color, cb_type: ColorBlindnessType, options: SimulationOptions) Color {
    // Convert RGB to linear RGB
    const r_linear = srgbToLinear(@as(f32, @floatFromInt(color.r)) / 255.0);
    const g_linear = srgbToLinear(@as(f32, @floatFromInt(color.g)) / 255.0);
    const b_linear = srgbToLinear(@as(f32, @floatFromInt(color.b)) / 255.0);

    // Convert to LMS color space (cone responses)
    const lms = rgbToLMS(r_linear, g_linear, b_linear);

    // Apply color blindness transformation
    const transformed_lms = switch (cb_type) {
        .protanopia => applyProtanopia(lms),
        .protanomaly => applyProtanomaly(lms, options.severity),
        .deuteranopia => applyDeuteranopia(lms),
        .deuteranomaly => applyDeuteranomaly(lms, options.severity),
        .tritanopia => applyTritanopia(lms),
        .tritanomaly => applyTritanomaly(lms, options.severity),
        .achromatopsia => applyAchromatopsia(lms),
        .achromatomaly => applyAchromatomaly(lms),
    };

    // Convert back to RGB
    const rgb = lmsToRGB(transformed_lms);

    // Convert back to sRGB
    var r_srgb = linearToSrgb(rgb.r);
    var g_srgb = linearToSrgb(rgb.g);
    var b_srgb = linearToSrgb(rgb.b);

    // Preserve brightness if requested
    if (options.preserve_brightness) {
        const original_brightness = r_linear * 0.2126 + g_linear * 0.7152 + b_linear * 0.0722;
        const new_brightness = rgb.r * 0.2126 + rgb.g * 0.7152 + rgb.b * 0.0722;

        if (new_brightness > 0.0001) {
            const scale = original_brightness / new_brightness;
            r_srgb = linearToSrgb(rgb.r * scale);
            g_srgb = linearToSrgb(rgb.g * scale);
            b_srgb = linearToSrgb(rgb.b * scale);
        }
    }

    return Color{
        .r = @intFromFloat(@min(255.0, @max(0.0, r_srgb * 255.0))),
        .g = @intFromFloat(@min(255.0, @max(0.0, g_srgb * 255.0))),
        .b = @intFromFloat(@min(255.0, @max(0.0, b_srgb * 255.0))),
        .a = color.a,
    };
}

// ============================================================================
// Color Space Conversions
// ============================================================================

const LMS = struct {
    l: f32, // Long wavelength (red)
    m: f32, // Medium wavelength (green)
    s: f32, // Short wavelength (blue)
};

const RGB = struct {
    r: f32,
    g: f32,
    b: f32,
};

fn srgbToLinear(val: f32) f32 {
    if (val <= 0.04045) {
        return val / 12.92;
    } else {
        return std.math.pow(f32, (val + 0.055) / 1.055, 2.4);
    }
}

fn linearToSrgb(val: f32) f32 {
    if (val <= 0.0031308) {
        return val * 12.92;
    } else {
        return 1.055 * std.math.pow(f32, val, 1.0 / 2.4) - 0.055;
    }
}

fn rgbToLMS(r: f32, g: f32, b: f32) LMS {
    // Hunt-Pointer-Estevez transformation matrix
    return LMS{
        .l = 0.31399022 * r + 0.63951294 * g + 0.04649755 * b,
        .m = 0.15537241 * r + 0.75789446 * g + 0.08670142 * b,
        .s = 0.01775239 * r + 0.10944209 * g + 0.87256922 * b,
    };
}

fn lmsToRGB(lms: LMS) RGB {
    // Inverse Hunt-Pointer-Estevez transformation
    return RGB{
        .r = 5.47221206 * lms.l - 4.64196010 * lms.m + 0.16963708 * lms.s,
        .g = -1.12524190 * lms.l + 2.29317094 * lms.m - 0.16789520 * lms.s,
        .b = 0.02980165 * lms.l - 0.19318073 * lms.m + 1.16364789 * lms.s,
    };
}

// ============================================================================
// Color Blindness Transformations
// ============================================================================

fn applyProtanopia(lms: LMS) LMS {
    // Protanopia: no L (long wavelength) cones
    // Estimate L from M and S
    return LMS{
        .l = 2.02344 * lms.m - 2.52581 * lms.s,
        .m = lms.m,
        .s = lms.s,
    };
}

fn applyProtanomaly(lms: LMS, severity: f32) LMS {
    const normal = lms;
    const affected = applyProtanopia(lms);
    return LMS{
        .l = normal.l * (1.0 - severity) + affected.l * severity,
        .m = lms.m,
        .s = lms.s,
    };
}

fn applyDeuteranopia(lms: LMS) LMS {
    // Deuteranopia: no M (medium wavelength) cones
    // Estimate M from L and S
    return LMS{
        .l = lms.l,
        .m = 0.49421 * lms.l + 1.24827 * lms.s,
        .s = lms.s,
    };
}

fn applyDeuteranomaly(lms: LMS, severity: f32) LMS {
    const normal = lms;
    const affected = applyDeuteranopia(lms);
    return LMS{
        .l = lms.l,
        .m = normal.m * (1.0 - severity) + affected.m * severity,
        .s = lms.s,
    };
}

fn applyTritanopia(lms: LMS) LMS {
    // Tritanopia: no S (short wavelength) cones
    // Estimate S from L and M
    return LMS{
        .l = lms.l,
        .m = lms.m,
        .s = -0.86744 * lms.l + 1.86727 * lms.m,
    };
}

fn applyTritanomaly(lms: LMS, severity: f32) LMS {
    const normal = lms;
    const affected = applyTritanopia(lms);
    return LMS{
        .l = lms.l,
        .m = lms.m,
        .s = normal.s * (1.0 - severity) + affected.s * severity,
    };
}

fn applyAchromatopsia(lms: LMS) LMS {
    // Complete color blindness - only brightness
    const brightness = (lms.l + lms.m + lms.s) / 3.0;
    return LMS{
        .l = brightness,
        .m = brightness,
        .s = brightness,
    };
}

fn applyAchromatomaly(lms: LMS) LMS {
    // Blue cone monochromacy - only S cones work
    return LMS{
        .l = lms.s,
        .m = lms.s,
        .s = lms.s,
    };
}

// ============================================================================
// Comparison and Analysis
// ============================================================================

pub const AccessibilityReport = struct {
    is_accessible: bool,
    problematic_colors: []ColorPair,
    contrast_ratios: []f32,
    recommendations: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AccessibilityReport) void {
        self.allocator.free(self.problematic_colors);
        self.allocator.free(self.contrast_ratios);
        for (self.recommendations) |rec| {
            self.allocator.free(rec);
        }
        self.allocator.free(self.recommendations);
    }
};

pub const ColorPair = struct {
    color1: Color,
    color2: Color,
    location1: struct { x: u32, y: u32 },
    location2: struct { x: u32, y: u32 },
    similarity_normal: f32,
    similarity_colorblind: f32,
};

/// Analyzes an image for color blindness accessibility
pub fn analyzeAccessibility(allocator: std.mem.Allocator, img: *const Image, cb_type: ColorBlindnessType) !AccessibilityReport {
    var problematic = std.ArrayList(ColorPair).init(allocator);
    defer problematic.deinit();

    var contrasts = std.ArrayList(f32).init(allocator);
    defer contrasts.deinit();

    var recommendations = std.ArrayList([]const u8).init(allocator);
    defer recommendations.deinit();

    // Sample colors from the image
    const sample_step = 20;
    for (0..img.height / sample_step) |sy| {
        for (0..img.width / sample_step) |sx| {
            const y1 = @as(u32, @intCast(sy)) * sample_step;
            const x1 = @as(u32, @intCast(sx)) * sample_step;
            const color1 = img.getPixel(x1, y1);

            // Compare with nearby colors
            for (0..img.height / sample_step) |sy2| {
                for (0..img.width / sample_step) |sx2| {
                    const y2 = @as(u32, @intCast(sy2)) * sample_step;
                    const x2 = @as(u32, @intCast(sx2)) * sample_step;
                    if (x1 == x2 and y1 == y2) continue;

                    const color2 = img.getPixel(x2, y2);

                    // Check if colors are distinguishable
                    const normal_diff = colorDifference(color1, color2);
                    const cb_color1 = transformColor(color1, cb_type, .{});
                    const cb_color2 = transformColor(color2, cb_type, .{});
                    const cb_diff = colorDifference(cb_color1, cb_color2);

                    // If colors are distinct normally but similar with color blindness
                    if (normal_diff > 30.0 and cb_diff < 15.0) {
                        try problematic.append(ColorPair{
                            .color1 = color1,
                            .color2 = color2,
                            .location1 = .{ .x = x1, .y = y1 },
                            .location2 = .{ .x = x2, .y = y2 },
                            .similarity_normal = normal_diff,
                            .similarity_colorblind = cb_diff,
                        });
                    }

                    // Check contrast ratio
                    const contrast = computeContrastRatio(color1, color2);
                    try contrasts.append(contrast);
                }
            }
        }
    }

    // Generate recommendations
    if (problematic.items.len > 0) {
        try recommendations.append(try allocator.dupe(u8, "Some colors may be indistinguishable with color blindness"));
        try recommendations.append(try allocator.dupe(u8, "Consider using patterns, textures, or labels in addition to color"));
        try recommendations.append(try allocator.dupe(u8, "Increase contrast between important elements"));
    }

    const avg_contrast = if (contrasts.items.len > 0) blk: {
        var sum: f32 = 0.0;
        for (contrasts.items) |c| sum += c;
        break :blk sum / @as(f32, @floatFromInt(contrasts.items.len));
    } else 0.0;

    if (avg_contrast < 4.5) {
        try recommendations.append(try allocator.dupe(u8, "Overall contrast is low (below WCAG AA standard of 4.5:1)"));
    }

    return AccessibilityReport{
        .is_accessible = problematic.items.len == 0 and avg_contrast >= 4.5,
        .problematic_colors = try problematic.toOwnedSlice(),
        .contrast_ratios = try contrasts.toOwnedSlice(),
        .recommendations = try recommendations.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn colorDifference(c1: Color, c2: Color) f32 {
    const dr = @as(f32, @floatFromInt(c1.r)) - @as(f32, @floatFromInt(c2.r));
    const dg = @as(f32, @floatFromInt(c1.g)) - @as(f32, @floatFromInt(c2.g));
    const db = @as(f32, @floatFromInt(c1.b)) - @as(f32, @floatFromInt(c2.b));
    return @sqrt(dr * dr + dg * dg + db * db);
}

fn computeContrastRatio(c1: Color, c2: Color) f32 {
    const l1 = relativeLuminance(c1);
    const l2 = relativeLuminance(c2);

    const lighter = @max(l1, l2);
    const darker = @min(l1, l2);

    return (lighter + 0.05) / (darker + 0.05);
}

fn relativeLuminance(color: Color) f32 {
    const r = srgbToLinear(@as(f32, @floatFromInt(color.r)) / 255.0);
    const g = srgbToLinear(@as(f32, @floatFromInt(color.g)) / 255.0);
    const b = srgbToLinear(@as(f32, @floatFromInt(color.b)) / 255.0);

    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// ============================================================================
// Daltonization (Color Correction)
// ============================================================================

/// Attempts to correct colors to make them more distinguishable for color blind people
pub fn daltonize(allocator: std.mem.Allocator, img: *const Image, cb_type: ColorBlindnessType) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const original = img.getPixel(@intCast(x), @intCast(y));

            // Simulate how colorblind person sees it
            const simulated = transformColor(original, cb_type, .{});

            // Compute error
            const error_r = @as(f32, @floatFromInt(original.r)) - @as(f32, @floatFromInt(simulated.r));
            const error_g = @as(f32, @floatFromInt(original.g)) - @as(f32, @floatFromInt(simulated.g));
            const error_b = @as(f32, @floatFromInt(original.b)) - @as(f32, @floatFromInt(simulated.b));

            // Apply error correction based on type
            const correction = switch (cb_type) {
                .protanopia, .protanomaly => RGB{
                    .r = 0.0,
                    .g = error_r * 0.7 + error_g * 0.3,
                    .b = error_r * 0.7 + error_b * 0.3,
                },
                .deuteranopia, .deuteranomaly => RGB{
                    .r = error_g * 0.7 + error_r * 0.3,
                    .g = 0.0,
                    .b = error_g * 0.7 + error_b * 0.3,
                },
                .tritanopia, .tritanomaly => RGB{
                    .r = error_b * 0.7 + error_r * 0.3,
                    .g = error_b * 0.7 + error_g * 0.3,
                    .b = 0.0,
                },
                else => RGB{ .r = 0.0, .g = 0.0, .b = 0.0 },
            };

            // Add correction to simulated color
            const corrected = Color{
                .r = @intFromFloat(@min(255.0, @max(0.0, @as(f32, @floatFromInt(simulated.r)) + correction.r))),
                .g = @intFromFloat(@min(255.0, @max(0.0, @as(f32, @floatFromInt(simulated.g)) + correction.g))),
                .b = @intFromFloat(@min(255.0, @max(0.0, @as(f32, @floatFromInt(simulated.b)) + correction.b))),
                .a = original.a,
            };

            result.setPixel(@intCast(x), @intCast(y), corrected);
        }
    }

    return result;
}

// ============================================================================
// Batch Simulation
// ============================================================================

pub const SimulationSet = struct {
    normal: Image,
    protanopia: Image,
    deuteranopia: Image,
    tritanopia: Image,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SimulationSet) void {
        self.normal.deinit();
        self.protanopia.deinit();
        self.deuteranopia.deinit();
        self.tritanopia.deinit();
    }
};

/// Generates simulations for all major types of color blindness
pub fn generateAllSimulations(allocator: std.mem.Allocator, img: *const Image) !SimulationSet {
    var normal = try Image.init(allocator, img.width, img.height, img.format);
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            normal.setPixel(@intCast(x), @intCast(y), img.getPixel(@intCast(x), @intCast(y)));
        }
    }

    return SimulationSet{
        .normal = normal,
        .protanopia = try simulateColorBlindness(allocator, img, .protanopia, .{}),
        .deuteranopia = try simulateColorBlindness(allocator, img, .deuteranopia, .{}),
        .tritanopia = try simulateColorBlindness(allocator, img, .tritanopia, .{}),
        .allocator = allocator,
    };
}
