// Image Filters
// Blur, sharpen, convolution, and other effects

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Convolution Kernel
// ============================================================================

pub const Kernel = struct {
    data: []const f32,
    width: u8,
    height: u8,
    divisor: f32,
    offset: f32,

    pub fn normalize(self: Kernel) Kernel {
        var sum: f32 = 0;
        for (self.data) |v| {
            sum += v;
        }
        return Kernel{
            .data = self.data,
            .width = self.width,
            .height = self.height,
            .divisor = if (sum != 0) sum else 1,
            .offset = self.offset,
        };
    }
};

// Predefined kernels
pub const KERNEL_IDENTITY = Kernel{
    .data = &[_]f32{ 0, 0, 0, 0, 1, 0, 0, 0, 0 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 0,
};

pub const KERNEL_EDGE_DETECT = Kernel{
    .data = &[_]f32{ -1, -1, -1, -1, 8, -1, -1, -1, -1 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 0,
};

pub const KERNEL_SHARPEN = Kernel{
    .data = &[_]f32{ 0, -1, 0, -1, 5, -1, 0, -1, 0 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 0,
};

pub const KERNEL_EMBOSS = Kernel{
    .data = &[_]f32{ -2, -1, 0, -1, 1, 1, 0, 1, 2 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 128,
};

pub const KERNEL_BOX_BLUR_3 = Kernel{
    .data = &[_]f32{ 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .width = 3,
    .height = 3,
    .divisor = 9,
    .offset = 0,
};

pub const KERNEL_SOBEL_X = Kernel{
    .data = &[_]f32{ -1, 0, 1, -2, 0, 2, -1, 0, 1 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 128,
};

pub const KERNEL_SOBEL_Y = Kernel{
    .data = &[_]f32{ -1, -2, -1, 0, 0, 0, 1, 2, 1 },
    .width = 3,
    .height = 3,
    .divisor = 1,
    .offset = 128,
};

// ============================================================================
// Convolution
// ============================================================================

pub fn convolve(img: *const Image, kernel: Kernel) !Image {
    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    const half_w: i32 = @intCast(kernel.width / 2);
    const half_h: i32 = @intCast(kernel.height / 2);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var a: u8 = 255;

            var ky: i32 = 0;
            while (ky < kernel.height) : (ky += 1) {
                var kx: i32 = 0;
                while (kx < kernel.width) : (kx += 1) {
                    const px = @as(i32, @intCast(x)) + kx - half_w;
                    const py = @as(i32, @intCast(y)) + ky - half_h;

                    // Clamp to image bounds
                    const sx: u32 = @intCast(std.math.clamp(px, 0, @as(i32, @intCast(img.width - 1))));
                    const sy: u32 = @intCast(std.math.clamp(py, 0, @as(i32, @intCast(img.height - 1))));

                    const color = img.getPixel(sx, sy) orelse Color.BLACK;
                    const k_idx: usize = @intCast(ky * @as(i32, kernel.width) + kx);
                    const weight = kernel.data[k_idx];

                    r_sum += @as(f32, @floatFromInt(color.r)) * weight;
                    g_sum += @as(f32, @floatFromInt(color.g)) * weight;
                    b_sum += @as(f32, @floatFromInt(color.b)) * weight;

                    // Keep center pixel alpha
                    if (kx == half_w and ky == half_h) {
                        a = color.a;
                    }
                }
            }

            result.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r_sum / kernel.divisor + kernel.offset, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g_sum / kernel.divisor + kernel.offset, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b_sum / kernel.divisor + kernel.offset, 0, 255)),
                .a = a,
            });
        }
    }

    return result;
}

// ============================================================================
// Gaussian Blur
// ============================================================================

pub fn blur(img: *const Image, sigma: f32) !Image {
    if (sigma <= 0) return img.clone();

    // Calculate kernel size (6*sigma gives 99.7% of the Gaussian)
    const kernel_size: u32 = @max(3, (@as(u32, @intFromFloat(@ceil(sigma * 6))) | 1));
    const half: i32 = @intCast(kernel_size / 2);

    // Generate 1D Gaussian kernel
    var kernel = try img.allocator.alloc(f32, kernel_size);
    defer img.allocator.free(kernel);

    var sum: f32 = 0;
    var i: i32 = 0;
    while (i < kernel_size) : (i += 1) {
        const x = @as(f32, @floatFromInt(i - half));
        kernel[@intCast(i)] = @exp(-(x * x) / (2 * sigma * sigma));
        sum += kernel[@intCast(i)];
    }

    // Normalize
    for (kernel) |*v| {
        v.* /= sum;
    }

    // Two-pass separable blur (horizontal then vertical)
    var temp = try Image.init(img.allocator, img.width, img.height, img.format);
    defer temp.deinit();

    // Horizontal pass
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var a: u8 = 255;

            var ki: i32 = 0;
            while (ki < kernel_size) : (ki += 1) {
                const px = @as(i32, @intCast(x)) + ki - half;
                const sx: u32 = @intCast(std.math.clamp(px, 0, @as(i32, @intCast(img.width - 1))));

                const color = img.getPixel(sx, y) orelse Color.BLACK;
                const weight = kernel[@intCast(ki)];

                r_sum += @as(f32, @floatFromInt(color.r)) * weight;
                g_sum += @as(f32, @floatFromInt(color.g)) * weight;
                b_sum += @as(f32, @floatFromInt(color.b)) * weight;

                if (ki == half) a = color.a;
            }

            temp.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r_sum, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g_sum, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b_sum, 0, 255)),
                .a = a,
            });
        }
    }

    // Vertical pass
    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    y = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            var r_sum: f32 = 0;
            var g_sum: f32 = 0;
            var b_sum: f32 = 0;
            var a: u8 = 255;

            var ki: i32 = 0;
            while (ki < kernel_size) : (ki += 1) {
                const py = @as(i32, @intCast(y)) + ki - half;
                const sy: u32 = @intCast(std.math.clamp(py, 0, @as(i32, @intCast(img.height - 1))));

                const color = temp.getPixel(x, sy) orelse Color.BLACK;
                const weight = kernel[@intCast(ki)];

                r_sum += @as(f32, @floatFromInt(color.r)) * weight;
                g_sum += @as(f32, @floatFromInt(color.g)) * weight;
                b_sum += @as(f32, @floatFromInt(color.b)) * weight;

                if (ki == half) a = color.a;
            }

            result.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r_sum, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g_sum, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b_sum, 0, 255)),
                .a = a,
            });
        }
    }

    return result;
}

// ============================================================================
// Sharpen
// ============================================================================

pub fn sharpen(img: *const Image, sigma: f32, flat: f32, jagged: f32) !Image {
    // Create blurred version
    var blurred = try blur(img, sigma);
    defer blurred.deinit();

    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    // Unsharp mask: original + amount * (original - blurred)
    const amount = flat + jagged;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const orig = img.getPixel(x, y) orelse Color.BLACK;
            const blur_c = blurred.getPixel(x, y) orelse Color.BLACK;

            const r_diff = @as(f32, @floatFromInt(orig.r)) - @as(f32, @floatFromInt(blur_c.r));
            const g_diff = @as(f32, @floatFromInt(orig.g)) - @as(f32, @floatFromInt(blur_c.g));
            const b_diff = @as(f32, @floatFromInt(orig.b)) - @as(f32, @floatFromInt(blur_c.b));

            result.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(orig.r)) + amount * r_diff, 0, 255)),
                .g = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(orig.g)) + amount * g_diff, 0, 255)),
                .b = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(orig.b)) + amount * b_diff, 0, 255)),
                .a = orig.a,
            });
        }
    }

    return result;
}

// ============================================================================
// Median Filter (Noise Reduction)
// ============================================================================

pub fn median(img: *const Image, radius: u8) !Image {
    const size: u32 = @as(u32, radius) * 2 + 1;
    const area = size * size;

    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    // Allocate sort buffers
    var r_values = try img.allocator.alloc(u8, area);
    defer img.allocator.free(r_values);
    var g_values = try img.allocator.alloc(u8, area);
    defer img.allocator.free(g_values);
    var b_values = try img.allocator.alloc(u8, area);
    defer img.allocator.free(b_values);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            var count: usize = 0;
            var a: u8 = 255;

            var dy: i32 = -@as(i32, radius);
            while (dy <= radius) : (dy += 1) {
                var dx: i32 = -@as(i32, radius);
                while (dx <= radius) : (dx += 1) {
                    const px = @as(i32, @intCast(x)) + dx;
                    const py = @as(i32, @intCast(y)) + dy;

                    if (px >= 0 and px < img.width and py >= 0 and py < img.height) {
                        const color = img.getPixel(@intCast(px), @intCast(py)) orelse Color.BLACK;
                        r_values[count] = color.r;
                        g_values[count] = color.g;
                        b_values[count] = color.b;
                        count += 1;

                        if (dx == 0 and dy == 0) a = color.a;
                    }
                }
            }

            // Sort and get median
            std.mem.sort(u8, r_values[0..count], {}, std.sort.asc(u8));
            std.mem.sort(u8, g_values[0..count], {}, std.sort.asc(u8));
            std.mem.sort(u8, b_values[0..count], {}, std.sort.asc(u8));

            const mid = count / 2;
            result.setPixel(x, y, Color{
                .r = r_values[mid],
                .g = g_values[mid],
                .b = b_values[mid],
                .a = a,
            });
        }
    }

    return result;
}

// ============================================================================
// Edge Detection
// ============================================================================

pub fn edgeDetect(img: *const Image) !Image {
    return convolve(img, KERNEL_EDGE_DETECT);
}

pub fn sobel(img: *const Image) !Image {
    var gx = try convolve(img, KERNEL_SOBEL_X);
    defer gx.deinit();

    var gy = try convolve(img, KERNEL_SOBEL_Y);
    defer gy.deinit();

    var result = try Image.init(img.allocator, img.width, img.height, img.format);
    errdefer result.deinit();

    // Combine gradients: magnitude = sqrt(gx^2 + gy^2)
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const cx = gx.getPixel(x, y) orelse Color.BLACK;
            const cy = gy.getPixel(x, y) orelse Color.BLACK;

            // Convert to signed (centered at 128)
            const rx: f32 = @as(f32, @floatFromInt(cx.r)) - 128;
            const gx_g: f32 = @as(f32, @floatFromInt(cx.g)) - 128;
            const bx: f32 = @as(f32, @floatFromInt(cx.b)) - 128;

            const ry: f32 = @as(f32, @floatFromInt(cy.r)) - 128;
            const gy_g: f32 = @as(f32, @floatFromInt(cy.g)) - 128;
            const by: f32 = @as(f32, @floatFromInt(cy.b)) - 128;

            const r_mag = @sqrt(rx * rx + ry * ry);
            const g_mag = @sqrt(gx_g * gx_g + gy_g * gy_g);
            const b_mag = @sqrt(bx * bx + by * by);

            result.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r_mag, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g_mag, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b_mag, 0, 255)),
                .a = 255,
            });
        }
    }

    return result;
}

pub fn emboss(img: *const Image) !Image {
    return convolve(img, KERNEL_EMBOSS);
}

// ============================================================================
// Tests
// ============================================================================

test "Gaussian kernel generation" {
    // Test that blur returns a valid image
    var img = try Image.init(std.testing.allocator, 4, 4, .rgba8);
    defer img.deinit();

    img.setPixel(2, 2, Color.WHITE);

    var blurred = try blur(&img, 1.0);
    defer blurred.deinit();

    try std.testing.expectEqual(@as(u32, 4), blurred.width);
    try std.testing.expectEqual(@as(u32, 4), blurred.height);
}

test "Convolution with identity kernel" {
    var img = try Image.init(std.testing.allocator, 4, 4, .rgba8);
    defer img.deinit();

    img.setPixel(2, 2, Color.RED);

    var result = try convolve(&img, KERNEL_IDENTITY);
    defer result.deinit();

    const pixel = result.getPixel(2, 2);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Median filter" {
    var img = try Image.init(std.testing.allocator, 5, 5, .rgba8);
    defer img.deinit();

    // Fill with white, add some noise
    var y: u32 = 0;
    while (y < 5) : (y += 1) {
        var x: u32 = 0;
        while (x < 5) : (x += 1) {
            img.setPixel(x, y, Color.WHITE);
        }
    }
    img.setPixel(2, 2, Color.BLACK); // Salt noise

    var filtered = try median(&img, 1);
    defer filtered.deinit();

    // Center pixel should be filtered to white (median of mostly white)
    const center = filtered.getPixel(2, 2);
    try std.testing.expect(center != null);
    try std.testing.expect(center.?.r > 128); // Should be closer to white
}
