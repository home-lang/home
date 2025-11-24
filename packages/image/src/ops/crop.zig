// Image Cropping and Extraction Operations

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Crop Region
// ============================================================================

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn isValid(self: Region, img_width: u32, img_height: u32) bool {
        return self.x < img_width and
            self.y < img_height and
            self.width > 0 and
            self.height > 0 and
            self.x + self.width <= img_width and
            self.y + self.height <= img_height;
    }

    pub fn clamp(self: Region, img_width: u32, img_height: u32) Region {
        const x = @min(self.x, img_width);
        const y = @min(self.y, img_height);
        const max_width = img_width - x;
        const max_height = img_height - y;

        return Region{
            .x = x,
            .y = y,
            .width = @min(self.width, max_width),
            .height = @min(self.height, max_height),
        };
    }
};

// ============================================================================
// Crop Function
// ============================================================================

pub fn crop(img: *const Image, x: u32, y: u32, width: u32, height: u32) !Image {
    const region = Region{ .x = x, .y = y, .width = width, .height = height };
    return extract(img, region);
}

pub fn extract(img: *const Image, region: Region) !Image {
    // Clamp region to image bounds
    const clamped = region.clamp(img.width, img.height);

    if (clamped.width == 0 or clamped.height == 0) {
        return error.InvalidDimensions;
    }

    var result = try Image.init(img.allocator, clamped.width, clamped.height, img.format);
    errdefer result.deinit();

    // Copy pixels
    const bpp = img.format.bytesPerPixel();

    var y: u32 = 0;
    while (y < clamped.height) : (y += 1) {
        const src_y = clamped.y + y;
        const src_offset = (@as(usize, src_y) * @as(usize, img.width) + @as(usize, clamped.x)) * bpp;
        const dst_offset = @as(usize, y) * @as(usize, clamped.width) * bpp;
        const row_bytes = @as(usize, clamped.width) * bpp;

        @memcpy(result.pixels[dst_offset..][0..row_bytes], img.pixels[src_offset..][0..row_bytes]);
    }

    return result;
}

// ============================================================================
// Extend (Add Padding)
// ============================================================================

pub const ExtendOptions = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,
    background: Color = Color.TRANSPARENT,
};

pub fn extend(img: *const Image, options: ExtendOptions) !Image {
    const new_width = img.width + options.left + options.right;
    const new_height = img.height + options.top + options.bottom;

    if (new_width == 0 or new_height == 0) {
        return error.InvalidDimensions;
    }

    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    // Fill with background color
    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            result.setPixel(x, y, options.background);
        }
    }

    // Copy original image
    y = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.getPixel(x, y)) |color| {
                result.setPixel(options.left + x, options.top + y, color);
            }
        }
    }

    return result;
}

pub fn extendUniform(img: *const Image, padding: u32, background: Color) !Image {
    return extend(img, .{
        .top = padding,
        .bottom = padding,
        .left = padding,
        .right = padding,
        .background = background,
    });
}

// ============================================================================
// Trim (Auto-crop whitespace/transparency)
// ============================================================================

pub const TrimOptions = struct {
    threshold: u8 = 10, // Color difference threshold
    trim_alpha: bool = true, // Trim based on alpha channel
    trim_color: ?Color = null, // Specific color to trim (null = auto-detect)
};

pub fn trim(img: *const Image, options: TrimOptions) !Image {
    // Detect bounds
    const bounds = detectTrimBounds(img, options);

    if (bounds.width == 0 or bounds.height == 0) {
        // Image is entirely "empty", return 1x1 transparent pixel
        var result = try Image.init(img.allocator, 1, 1, img.format);
        result.setPixel(0, 0, Color.TRANSPARENT);
        return result;
    }

    return extract(img, bounds);
}

fn detectTrimBounds(img: *const Image, options: TrimOptions) Region {
    var min_x: u32 = img.width;
    var min_y: u32 = img.height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;

    // Auto-detect trim color from top-left corner if not specified
    const trim_color = options.trim_color orelse (img.getPixel(0, 0) orelse Color.TRANSPARENT);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const pixel = img.getPixel(x, y) orelse continue;

            const should_trim = if (options.trim_alpha and pixel.a < options.threshold)
                true
            else
                colorDifference(pixel, trim_color) < options.threshold;

            if (!should_trim) {
                min_x = @min(min_x, x);
                min_y = @min(min_y, y);
                max_x = @max(max_x, x);
                max_y = @max(max_y, y);
            }
        }
    }

    if (min_x > max_x or min_y > max_y) {
        return Region{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    return Region{
        .x = min_x,
        .y = min_y,
        .width = max_x - min_x + 1,
        .height = max_y - min_y + 1,
    };
}

fn colorDifference(a: Color, b: Color) u8 {
    const dr = @as(i16, a.r) - @as(i16, b.r);
    const dg = @as(i16, a.g) - @as(i16, b.g);
    const db = @as(i16, a.b) - @as(i16, b.b);
    const da = @as(i16, a.a) - @as(i16, b.a);

    const sum = @abs(dr) + @abs(dg) + @abs(db) + @abs(da);
    return @intCast(@min(sum / 4, 255));
}

// ============================================================================
// Composite (Overlay)
// ============================================================================

pub const BlendMode = enum {
    normal, // Standard alpha blending
    multiply, // Darkens
    screen, // Lightens
    overlay, // Combines multiply and screen
    add, // Additive blending
    subtract, // Subtractive blending
    difference, // Absolute difference
    darken, // Take darker pixel
    lighten, // Take lighter pixel
};

pub fn composite(base: *Image, overlay_img: *const Image, x: i32, y: i32, blend_mode: BlendMode, opacity: f32) void {
    const op = std.math.clamp(opacity, 0, 1);

    var oy: u32 = 0;
    while (oy < overlay_img.height) : (oy += 1) {
        const by = @as(i32, @intCast(oy)) + y;
        if (by < 0 or by >= @as(i32, @intCast(base.height))) continue;

        var ox: u32 = 0;
        while (ox < overlay_img.width) : (ox += 1) {
            const bx = @as(i32, @intCast(ox)) + x;
            if (bx < 0 or bx >= @as(i32, @intCast(base.width))) continue;

            const base_color = base.getPixel(@intCast(bx), @intCast(by)) orelse Color.BLACK;
            var over_color = overlay_img.getPixel(ox, oy) orelse continue;

            // Apply opacity
            over_color.a = @intFromFloat(@as(f32, @floatFromInt(over_color.a)) * op);

            const blended = blendColors(base_color, over_color, blend_mode);
            base.setPixel(@intCast(bx), @intCast(by), blended);
        }
    }
}

fn blendColors(base: Color, over: Color, mode: BlendMode) Color {
    const alpha = @as(f32, @floatFromInt(over.a)) / 255.0;
    const inv_alpha = 1.0 - alpha;

    const br: f32 = @floatFromInt(base.r);
    const bg: f32 = @floatFromInt(base.g);
    const bb: f32 = @floatFromInt(base.b);
    const or_f: f32 = @floatFromInt(over.r);
    const og: f32 = @floatFromInt(over.g);
    const ob: f32 = @floatFromInt(over.b);

    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;

    switch (mode) {
        .normal => {
            r = or_f * alpha + br * inv_alpha;
            g = og * alpha + bg * inv_alpha;
            b = ob * alpha + bb * inv_alpha;
        },
        .multiply => {
            r = (br * or_f / 255.0) * alpha + br * inv_alpha;
            g = (bg * og / 255.0) * alpha + bg * inv_alpha;
            b = (bb * ob / 255.0) * alpha + bb * inv_alpha;
        },
        .screen => {
            r = (255 - (255 - br) * (255 - or_f) / 255.0) * alpha + br * inv_alpha;
            g = (255 - (255 - bg) * (255 - og) / 255.0) * alpha + bg * inv_alpha;
            b = (255 - (255 - bb) * (255 - ob) / 255.0) * alpha + bb * inv_alpha;
        },
        .overlay => {
            r = overlayChannel(br, or_f) * alpha + br * inv_alpha;
            g = overlayChannel(bg, og) * alpha + bg * inv_alpha;
            b = overlayChannel(bb, ob) * alpha + bb * inv_alpha;
        },
        .add => {
            r = @min(br + or_f * alpha, 255);
            g = @min(bg + og * alpha, 255);
            b = @min(bb + ob * alpha, 255);
        },
        .subtract => {
            r = @max(br - or_f * alpha, 0);
            g = @max(bg - og * alpha, 0);
            b = @max(bb - ob * alpha, 0);
        },
        .difference => {
            r = @abs(br - or_f) * alpha + br * inv_alpha;
            g = @abs(bg - og) * alpha + bg * inv_alpha;
            b = @abs(bb - ob) * alpha + bb * inv_alpha;
        },
        .darken => {
            r = @min(br, or_f) * alpha + br * inv_alpha;
            g = @min(bg, og) * alpha + bg * inv_alpha;
            b = @min(bb, ob) * alpha + bb * inv_alpha;
        },
        .lighten => {
            r = @max(br, or_f) * alpha + br * inv_alpha;
            g = @max(bg, og) * alpha + bg * inv_alpha;
            b = @max(bb, ob) * alpha + bb * inv_alpha;
        },
    }

    return Color{
        .r = @intFromFloat(std.math.clamp(r, 0, 255)),
        .g = @intFromFloat(std.math.clamp(g, 0, 255)),
        .b = @intFromFloat(std.math.clamp(b, 0, 255)),
        .a = @intCast(@max(base.a, over.a)),
    };
}

fn overlayChannel(base: f32, over: f32) f32 {
    if (base < 128) {
        return 2 * base * over / 255.0;
    } else {
        return 255 - 2 * (255 - base) * (255 - over) / 255.0;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Crop basic" {
    var img = try Image.init(std.testing.allocator, 10, 10, .rgba8);
    defer img.deinit();

    img.setPixel(5, 5, Color.RED);

    var cropped = try crop(&img, 4, 4, 4, 4);
    defer cropped.deinit();

    try std.testing.expectEqual(@as(u32, 4), cropped.width);
    try std.testing.expectEqual(@as(u32, 4), cropped.height);

    // RED pixel should now be at (1, 1)
    const pixel = cropped.getPixel(1, 1);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Region clamp" {
    const region = Region{ .x = 90, .y = 90, .width = 20, .height = 20 };
    const clamped = region.clamp(100, 100);

    try std.testing.expectEqual(@as(u32, 90), clamped.x);
    try std.testing.expectEqual(@as(u32, 90), clamped.y);
    try std.testing.expectEqual(@as(u32, 10), clamped.width);
    try std.testing.expectEqual(@as(u32, 10), clamped.height);
}

test "Extend uniform" {
    var img = try Image.init(std.testing.allocator, 4, 4, .rgba8);
    defer img.deinit();

    var extended = try extendUniform(&img, 2, Color.WHITE);
    defer extended.deinit();

    try std.testing.expectEqual(@as(u32, 8), extended.width);
    try std.testing.expectEqual(@as(u32, 8), extended.height);
}

test "Color difference" {
    const white = Color.WHITE;
    const black = Color.BLACK;

    const diff = colorDifference(white, black);
    try std.testing.expect(diff > 200); // Should be close to max
}
