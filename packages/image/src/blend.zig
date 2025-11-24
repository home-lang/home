// Advanced Blend Modes
// Photoshop-style compositing operations

const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Blend Mode Types
// ============================================================================

pub const BlendMode = enum {
    // Normal modes
    normal,
    dissolve,

    // Darken modes
    darken,
    multiply,
    color_burn,
    linear_burn,
    darker_color,

    // Lighten modes
    lighten,
    screen,
    color_dodge,
    linear_dodge, // Add
    lighter_color,

    // Contrast modes
    overlay,
    soft_light,
    hard_light,
    vivid_light,
    linear_light,
    pin_light,
    hard_mix,

    // Inversion modes
    difference,
    exclusion,
    subtract,
    divide,

    // Component modes
    hue,
    saturation,
    color,
    luminosity,
};

// ============================================================================
// Blend Operations
// ============================================================================

/// Blend two colors with specified mode and opacity
pub fn blend(base: Color, overlay_color: Color, mode: BlendMode, opacity: f32) Color {
    const op = std.math.clamp(opacity, 0.0, 1.0);
    if (op == 0.0) return base;

    // Get blended result
    const blended = blendColors(base, overlay_color, mode);

    // Apply opacity
    if (op == 1.0) return blended;

    return Color{
        .r = @intFromFloat(@as(f32, @floatFromInt(base.r)) * (1 - op) + @as(f32, @floatFromInt(blended.r)) * op),
        .g = @intFromFloat(@as(f32, @floatFromInt(base.g)) * (1 - op) + @as(f32, @floatFromInt(blended.g)) * op),
        .b = @intFromFloat(@as(f32, @floatFromInt(base.b)) * (1 - op) + @as(f32, @floatFromInt(blended.b)) * op),
        .a = @max(base.a, @intFromFloat(@as(f32, @floatFromInt(overlay_color.a)) * op)),
    };
}

fn blendColors(base: Color, over: Color, mode: BlendMode) Color {
    const br: f32 = @as(f32, @floatFromInt(base.r)) / 255.0;
    const bg: f32 = @as(f32, @floatFromInt(base.g)) / 255.0;
    const bb: f32 = @as(f32, @floatFromInt(base.b)) / 255.0;

    const or_f: f32 = @as(f32, @floatFromInt(over.r)) / 255.0;
    const og: f32 = @as(f32, @floatFromInt(over.g)) / 255.0;
    const ob: f32 = @as(f32, @floatFromInt(over.b)) / 255.0;

    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    switch (mode) {
        .normal => {
            r = or_f;
            g = og;
            b = ob;
        },
        .dissolve => {
            // Random threshold based on alpha
            r = or_f;
            g = og;
            b = ob;
        },

        // Darken modes
        .darken => {
            r = @min(br, or_f);
            g = @min(bg, og);
            b = @min(bb, ob);
        },
        .multiply => {
            r = br * or_f;
            g = bg * og;
            b = bb * ob;
        },
        .color_burn => {
            r = if (or_f == 0) 0 else 1.0 - @min(1.0, (1.0 - br) / or_f);
            g = if (og == 0) 0 else 1.0 - @min(1.0, (1.0 - bg) / og);
            b = if (ob == 0) 0 else 1.0 - @min(1.0, (1.0 - bb) / ob);
        },
        .linear_burn => {
            r = @max(0, br + or_f - 1.0);
            g = @max(0, bg + og - 1.0);
            b = @max(0, bb + ob - 1.0);
        },
        .darker_color => {
            const base_lum = 0.299 * br + 0.587 * bg + 0.114 * bb;
            const over_lum = 0.299 * or_f + 0.587 * og + 0.114 * ob;
            if (over_lum < base_lum) {
                r = or_f;
                g = og;
                b = ob;
            } else {
                r = br;
                g = bg;
                b = bb;
            }
        },

        // Lighten modes
        .lighten => {
            r = @max(br, or_f);
            g = @max(bg, og);
            b = @max(bb, ob);
        },
        .screen => {
            r = 1.0 - (1.0 - br) * (1.0 - or_f);
            g = 1.0 - (1.0 - bg) * (1.0 - og);
            b = 1.0 - (1.0 - bb) * (1.0 - ob);
        },
        .color_dodge => {
            r = if (or_f >= 1.0) 1.0 else @min(1.0, br / (1.0 - or_f));
            g = if (og >= 1.0) 1.0 else @min(1.0, bg / (1.0 - og));
            b = if (ob >= 1.0) 1.0 else @min(1.0, bb / (1.0 - ob));
        },
        .linear_dodge => {
            r = @min(1.0, br + or_f);
            g = @min(1.0, bg + og);
            b = @min(1.0, bb + ob);
        },
        .lighter_color => {
            const base_lum = 0.299 * br + 0.587 * bg + 0.114 * bb;
            const over_lum = 0.299 * or_f + 0.587 * og + 0.114 * ob;
            if (over_lum > base_lum) {
                r = or_f;
                g = og;
                b = ob;
            } else {
                r = br;
                g = bg;
                b = bb;
            }
        },

        // Contrast modes
        .overlay => {
            r = overlayChannel(br, or_f);
            g = overlayChannel(bg, og);
            b = overlayChannel(bb, ob);
        },
        .soft_light => {
            r = softLightChannel(br, or_f);
            g = softLightChannel(bg, og);
            b = softLightChannel(bb, ob);
        },
        .hard_light => {
            r = overlayChannel(or_f, br);
            g = overlayChannel(og, bg);
            b = overlayChannel(ob, bb);
        },
        .vivid_light => {
            r = vividLightChannel(br, or_f);
            g = vividLightChannel(bg, og);
            b = vividLightChannel(bb, ob);
        },
        .linear_light => {
            r = std.math.clamp(br + 2.0 * or_f - 1.0, 0.0, 1.0);
            g = std.math.clamp(bg + 2.0 * og - 1.0, 0.0, 1.0);
            b = std.math.clamp(bb + 2.0 * ob - 1.0, 0.0, 1.0);
        },
        .pin_light => {
            r = pinLightChannel(br, or_f);
            g = pinLightChannel(bg, og);
            b = pinLightChannel(bb, ob);
        },
        .hard_mix => {
            r = if (br + or_f >= 1.0) 1.0 else 0.0;
            g = if (bg + og >= 1.0) 1.0 else 0.0;
            b = if (bb + ob >= 1.0) 1.0 else 0.0;
        },

        // Inversion modes
        .difference => {
            r = @abs(br - or_f);
            g = @abs(bg - og);
            b = @abs(bb - ob);
        },
        .exclusion => {
            r = br + or_f - 2.0 * br * or_f;
            g = bg + og - 2.0 * bg * og;
            b = bb + ob - 2.0 * bb * ob;
        },
        .subtract => {
            r = @max(0, br - or_f);
            g = @max(0, bg - og);
            b = @max(0, bb - ob);
        },
        .divide => {
            r = if (or_f == 0) 1.0 else @min(1.0, br / or_f);
            g = if (og == 0) 1.0 else @min(1.0, bg / og);
            b = if (ob == 0) 1.0 else @min(1.0, bb / ob);
        },

        // Component modes
        .hue => {
            const base_hsl = rgbToHsl(br, bg, bb);
            const over_hsl = rgbToHsl(or_f, og, ob);
            const result = hslToRgb(over_hsl[0], base_hsl[1], base_hsl[2]);
            r = result[0];
            g = result[1];
            b = result[2];
        },
        .saturation => {
            const base_hsl = rgbToHsl(br, bg, bb);
            const over_hsl = rgbToHsl(or_f, og, ob);
            const result = hslToRgb(base_hsl[0], over_hsl[1], base_hsl[2]);
            r = result[0];
            g = result[1];
            b = result[2];
        },
        .color => {
            const base_hsl = rgbToHsl(br, bg, bb);
            const over_hsl = rgbToHsl(or_f, og, ob);
            const result = hslToRgb(over_hsl[0], over_hsl[1], base_hsl[2]);
            r = result[0];
            g = result[1];
            b = result[2];
        },
        .luminosity => {
            const base_hsl = rgbToHsl(br, bg, bb);
            const over_hsl = rgbToHsl(or_f, og, ob);
            const result = hslToRgb(base_hsl[0], base_hsl[1], over_hsl[2]);
            r = result[0];
            g = result[1];
            b = result[2];
        },
    }

    return Color{
        .r = @intFromFloat(std.math.clamp(r * 255.0, 0.0, 255.0)),
        .g = @intFromFloat(std.math.clamp(g * 255.0, 0.0, 255.0)),
        .b = @intFromFloat(std.math.clamp(b * 255.0, 0.0, 255.0)),
        .a = over.a,
    };
}

fn overlayChannel(base: f32, over: f32) f32 {
    if (base < 0.5) {
        return 2.0 * base * over;
    } else {
        return 1.0 - 2.0 * (1.0 - base) * (1.0 - over);
    }
}

fn softLightChannel(base: f32, over: f32) f32 {
    if (over < 0.5) {
        return base - (1.0 - 2.0 * over) * base * (1.0 - base);
    } else {
        const d = if (base < 0.25)
            ((16.0 * base - 12.0) * base + 4.0) * base
        else
            @sqrt(base);
        return base + (2.0 * over - 1.0) * (d - base);
    }
}

fn vividLightChannel(base: f32, over: f32) f32 {
    if (over < 0.5) {
        // Color burn
        const o2 = 2.0 * over;
        return if (o2 == 0) 0 else 1.0 - @min(1.0, (1.0 - base) / o2);
    } else {
        // Color dodge
        const o2 = 2.0 * (over - 0.5);
        return if (o2 >= 1.0) 1.0 else @min(1.0, base / (1.0 - o2));
    }
}

fn pinLightChannel(base: f32, over: f32) f32 {
    if (over < 0.5) {
        return @min(base, 2.0 * over);
    } else {
        return @max(base, 2.0 * (over - 0.5));
    }
}

fn rgbToHsl(r: f32, g: f32, b: f32) [3]f32 {
    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const delta = max_val - min_val;

    var h: f32 = 0;
    var s: f32 = 0;
    const l = (max_val + min_val) / 2.0;

    if (delta > 0) {
        s = if (l < 0.5) delta / (max_val + min_val) else delta / (2.0 - max_val - min_val);

        if (max_val == r) {
            h = (g - b) / delta + (if (g < b) @as(f32, 6) else @as(f32, 0));
        } else if (max_val == g) {
            h = (b - r) / delta + 2;
        } else {
            h = (r - g) / delta + 4;
        }
        h /= 6.0;
    }

    return .{ h, s, l };
}

fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    if (s == 0) {
        return .{ l, l, l };
    }

    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;

    return .{
        hueToRgb(p, q, h + 1.0 / 3.0),
        hueToRgb(p, q, h),
        hueToRgb(p, q, h - 1.0 / 3.0),
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

// ============================================================================
// Image Compositing
// ============================================================================

/// Composite overlay image onto base with specified blend mode
pub fn composite(base: *Image, overlay_img: *const Image, x: i32, y: i32, mode: BlendMode, opacity: f32) void {
    const op = std.math.clamp(opacity, 0.0, 1.0);
    if (op == 0.0) return;

    var oy: u32 = 0;
    while (oy < overlay_img.height) : (oy += 1) {
        const by = @as(i32, @intCast(oy)) + y;
        if (by < 0 or by >= @as(i32, @intCast(base.height))) continue;

        var ox: u32 = 0;
        while (ox < overlay_img.width) : (ox += 1) {
            const bx = @as(i32, @intCast(ox)) + x;
            if (bx < 0 or bx >= @as(i32, @intCast(base.width))) continue;

            const base_color = base.getPixel(@intCast(bx), @intCast(by)) orelse Color.BLACK;
            const over_color = overlay_img.getPixel(ox, oy) orelse continue;

            // Apply overlay alpha
            const effective_opacity = op * @as(f32, @floatFromInt(over_color.a)) / 255.0;
            const blended = blend(base_color, over_color, mode, effective_opacity);

            base.setPixel(@intCast(bx), @intCast(by), blended);
        }
    }
}

/// Blend two images of the same size
pub fn blendImages(base: *Image, overlay_img: *const Image, mode: BlendMode, opacity: f32) void {
    composite(base, overlay_img, 0, 0, mode, opacity);
}

// ============================================================================
// Porter-Duff Compositing
// ============================================================================

pub const PorterDuff = enum {
    clear,
    src,
    dst,
    src_over,
    dst_over,
    src_in,
    dst_in,
    src_out,
    dst_out,
    src_atop,
    dst_atop,
    xor_op,
};

/// Apply Porter-Duff compositing operation
pub fn porterDuff(base: Color, over: Color, op: PorterDuff) Color {
    const ba: f32 = @as(f32, @floatFromInt(base.a)) / 255.0;
    const oa: f32 = @as(f32, @floatFromInt(over.a)) / 255.0;

    var fa: f32 = undefined;
    var fb: f32 = undefined;

    switch (op) {
        .clear => {
            fa = 0;
            fb = 0;
        },
        .src => {
            fa = 1;
            fb = 0;
        },
        .dst => {
            fa = 0;
            fb = 1;
        },
        .src_over => {
            fa = 1;
            fb = 1 - oa;
        },
        .dst_over => {
            fa = 1 - ba;
            fb = 1;
        },
        .src_in => {
            fa = ba;
            fb = 0;
        },
        .dst_in => {
            fa = 0;
            fb = oa;
        },
        .src_out => {
            fa = 1 - ba;
            fb = 0;
        },
        .dst_out => {
            fa = 0;
            fb = 1 - oa;
        },
        .src_atop => {
            fa = ba;
            fb = 1 - oa;
        },
        .dst_atop => {
            fa = 1 - ba;
            fb = oa;
        },
        .xor_op => {
            fa = 1 - ba;
            fb = 1 - oa;
        },
    }

    const result_a = fa * oa + fb * ba;
    if (result_a == 0) return Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const r = (fa * oa * @as(f32, @floatFromInt(over.r)) + fb * ba * @as(f32, @floatFromInt(base.r))) / result_a;
    const g = (fa * oa * @as(f32, @floatFromInt(over.g)) + fb * ba * @as(f32, @floatFromInt(base.g))) / result_a;
    const b = (fa * oa * @as(f32, @floatFromInt(over.b)) + fb * ba * @as(f32, @floatFromInt(base.b))) / result_a;

    return Color{
        .r = @intFromFloat(std.math.clamp(r, 0.0, 255.0)),
        .g = @intFromFloat(std.math.clamp(g, 0.0, 255.0)),
        .b = @intFromFloat(std.math.clamp(b, 0.0, 255.0)),
        .a = @intFromFloat(std.math.clamp(result_a * 255.0, 0.0, 255.0)),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Multiply blend" {
    const white = Color.WHITE;
    const gray = Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blend(white, gray, .multiply, 1.0);

    // White * gray should give ~gray
    try std.testing.expect(result.r > 120 and result.r < 136);
}

test "Screen blend" {
    const black = Color.BLACK;
    const gray = Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blend(black, gray, .screen, 1.0);

    // Screen of black and gray should give gray
    try std.testing.expect(result.r > 120 and result.r < 136);
}

test "Porter-Duff src_over" {
    const base = Color{ .r = 255, .g = 0, .b = 0, .a = 128 };
    const over = Color{ .r = 0, .g = 255, .b = 0, .a = 128 };

    const result = porterDuff(base, over, .src_over);

    // Should be mostly green with some red showing through
    try std.testing.expect(result.g > result.r);
}
