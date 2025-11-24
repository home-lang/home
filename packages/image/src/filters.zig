const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;

// ============================================================================
// Morphological Operations
// ============================================================================

/// Structuring element for morphological operations
pub const StructuringElement = struct {
    data: []const bool,
    width: u32,
    height: u32,
    center_x: u32,
    center_y: u32,

    pub const RECT_3X3 = StructuringElement{
        .data = &[_]bool{
            true, true, true,
            true, true, true,
            true, true, true,
        },
        .width = 3,
        .height = 3,
        .center_x = 1,
        .center_y = 1,
    };

    pub const CROSS_3X3 = StructuringElement{
        .data = &[_]bool{
            false, true,  false,
            true,  true,  true,
            false, true,  false,
        },
        .width = 3,
        .height = 3,
        .center_x = 1,
        .center_y = 1,
    };

    pub const ELLIPSE_5X5 = StructuringElement{
        .data = &[_]bool{
            false, true,  true,  true,  false,
            true,  true,  true,  true,  true,
            true,  true,  true,  true,  true,
            true,  true,  true,  true,  true,
            false, true,  true,  true,  false,
        },
        .width = 5,
        .height = 5,
        .center_x = 2,
        .center_y = 2,
    };

    pub fn get(self: *const StructuringElement, x: u32, y: u32) bool {
        if (x >= self.width or y >= self.height) return false;
        return self.data[y * self.width + x];
    }
};

/// Dilate: expand bright regions
pub fn dilate(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var max_r: u8 = 0;
            var max_g: u8 = 0;
            var max_b: u8 = 0;

            for (0..element.height) |ky| {
                for (0..element.width) |kx| {
                    if (!element.get(@intCast(kx), @intCast(ky))) continue;

                    const px = @as(i32, @intCast(x)) + @as(i32, @intCast(kx)) - @as(i32, @intCast(element.center_x));
                    const py = @as(i32, @intCast(y)) + @as(i32, @intCast(ky)) - @as(i32, @intCast(element.center_y));

                    if (px >= 0 and px < @as(i32, @intCast(image.width)) and
                        py >= 0 and py < @as(i32, @intCast(image.height)))
                    {
                        const idx = (@as(u32, @intCast(py)) * image.width + @as(u32, @intCast(px))) * bpp;
                        max_r = @max(max_r, temp[idx]);
                        if (bpp >= 3) {
                            max_g = @max(max_g, temp[idx + 1]);
                            max_b = @max(max_b, temp[idx + 2]);
                        }
                    }
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            image.pixels[out_idx] = max_r;
            if (bpp >= 3) {
                image.pixels[out_idx + 1] = max_g;
                image.pixels[out_idx + 2] = max_b;
            }
        }
    }
}

/// Erode: shrink bright regions
pub fn erode(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var min_r: u8 = 255;
            var min_g: u8 = 255;
            var min_b: u8 = 255;

            for (0..element.height) |ky| {
                for (0..element.width) |kx| {
                    if (!element.get(@intCast(kx), @intCast(ky))) continue;

                    const px = @as(i32, @intCast(x)) + @as(i32, @intCast(kx)) - @as(i32, @intCast(element.center_x));
                    const py = @as(i32, @intCast(y)) + @as(i32, @intCast(ky)) - @as(i32, @intCast(element.center_y));

                    if (px >= 0 and px < @as(i32, @intCast(image.width)) and
                        py >= 0 and py < @as(i32, @intCast(image.height)))
                    {
                        const idx = (@as(u32, @intCast(py)) * image.width + @as(u32, @intCast(px))) * bpp;
                        min_r = @min(min_r, temp[idx]);
                        if (bpp >= 3) {
                            min_g = @min(min_g, temp[idx + 1]);
                            min_b = @min(min_b, temp[idx + 2]);
                        }
                    }
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            image.pixels[out_idx] = min_r;
            if (bpp >= 3) {
                image.pixels[out_idx + 1] = min_g;
                image.pixels[out_idx + 2] = min_b;
            }
        }
    }
}

/// Opening: erode then dilate (removes small bright spots)
pub fn morphOpen(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    try erode(image, element, allocator);
    try dilate(image, element, allocator);
}

/// Closing: dilate then erode (fills small dark holes)
pub fn morphClose(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    try dilate(image, element, allocator);
    try erode(image, element, allocator);
}

/// Morphological gradient: dilate - erode (edge detection)
pub fn morphGradient(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    var dilated = try image.clone();
    defer dilated.deinit();
    try dilate(&dilated, element, allocator);

    var eroded = try image.clone();
    defer eroded.deinit();
    try erode(&eroded, element, allocator);

    // Subtract
    for (0..image.pixels.len) |i| {
        const diff = @as(i16, dilated.pixels[i]) - @as(i16, eroded.pixels[i]);
        image.pixels[i] = @intCast(@max(0, diff));
    }
}

/// Top hat: original - opening (highlights bright features)
pub fn topHat(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    var opened = try image.clone();
    defer opened.deinit();
    try morphOpen(&opened, element, allocator);

    for (0..image.pixels.len) |i| {
        const diff = @as(i16, image.pixels[i]) - @as(i16, opened.pixels[i]);
        image.pixels[i] = @intCast(@max(0, diff));
    }
}

/// Black hat: closing - original (highlights dark features)
pub fn blackHat(image: *Image, element: StructuringElement, allocator: std.mem.Allocator) !void {
    var closed = try image.clone();
    defer closed.deinit();
    try morphClose(&closed, element, allocator);

    for (0..image.pixels.len) |i| {
        const diff = @as(i16, closed.pixels[i]) - @as(i16, image.pixels[i]);
        image.pixels[i] = @intCast(@max(0, diff));
    }
}

// ============================================================================
// Median Filter
// ============================================================================

/// Apply median filter (noise reduction)
pub fn medianFilter(image: *Image, radius: u32, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const window_size = (2 * radius + 1) * (2 * radius + 1);
    const median_idx = window_size / 2;

    var r_values = try allocator.alloc(u8, window_size);
    defer allocator.free(r_values);
    var g_values = try allocator.alloc(u8, window_size);
    defer allocator.free(g_values);
    var b_values = try allocator.alloc(u8, window_size);
    defer allocator.free(b_values);

    var y: u32 = radius;
    while (y < image.height - radius) : (y += 1) {
        var x: u32 = radius;
        while (x < image.width - radius) : (x += 1) {
            var count: usize = 0;

            for (0..(2 * radius + 1)) |ky| {
                for (0..(2 * radius + 1)) |kx| {
                    const px = x + @as(u32, @intCast(kx)) - radius;
                    const py = y + @as(u32, @intCast(ky)) - radius;
                    const idx = (py * image.width + px) * bpp;

                    r_values[count] = temp[idx];
                    if (bpp >= 3) {
                        g_values[count] = temp[idx + 1];
                        b_values[count] = temp[idx + 2];
                    }
                    count += 1;
                }
            }

            // Sort to find median
            std.mem.sort(u8, r_values[0..count], {}, std.sort.asc(u8));
            if (bpp >= 3) {
                std.mem.sort(u8, g_values[0..count], {}, std.sort.asc(u8));
                std.mem.sort(u8, b_values[0..count], {}, std.sort.asc(u8));
            }

            const out_idx = (y * image.width + x) * bpp;
            image.pixels[out_idx] = r_values[median_idx];
            if (bpp >= 3) {
                image.pixels[out_idx + 1] = g_values[median_idx];
                image.pixels[out_idx + 2] = b_values[median_idx];
            }
        }
    }
}

// ============================================================================
// Bilateral Filter
// ============================================================================

/// Apply bilateral filter (edge-preserving smoothing)
pub fn bilateralFilter(
    image: *Image,
    radius: u32,
    sigma_space: f32,
    sigma_color: f32,
    allocator: std.mem.Allocator,
) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const sigma_space_sq = sigma_space * sigma_space;
    const sigma_color_sq = sigma_color * sigma_color;

    var y: u32 = radius;
    while (y < image.height - radius) : (y += 1) {
        var x: u32 = radius;
        while (x < image.width - radius) : (x += 1) {
            const center_idx = (y * image.width + x) * bpp;
            const center_r: f32 = @floatFromInt(temp[center_idx]);
            const center_g: f32 = if (bpp >= 3) @floatFromInt(temp[center_idx + 1]) else center_r;
            const center_b: f32 = if (bpp >= 3) @floatFromInt(temp[center_idx + 2]) else center_r;

            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;
            var weight_sum: f32 = 0;

            for (0..(2 * radius + 1)) |ky| {
                for (0..(2 * radius + 1)) |kx| {
                    const px = x + @as(u32, @intCast(kx)) - radius;
                    const py = y + @as(u32, @intCast(ky)) - radius;
                    const idx = (py * image.width + px) * bpp;

                    const r: f32 = @floatFromInt(temp[idx]);
                    const g: f32 = if (bpp >= 3) @floatFromInt(temp[idx + 1]) else r;
                    const b: f32 = if (bpp >= 3) @floatFromInt(temp[idx + 2]) else r;

                    // Spatial distance
                    const dx = @as(f32, @floatFromInt(kx)) - @as(f32, @floatFromInt(radius));
                    const dy = @as(f32, @floatFromInt(ky)) - @as(f32, @floatFromInt(radius));
                    const spatial_dist_sq = dx * dx + dy * dy;

                    // Color distance
                    const dr = r - center_r;
                    const dg = g - center_g;
                    const db = b - center_b;
                    const color_dist_sq = dr * dr + dg * dg + db * db;

                    // Combined weight
                    const weight = @exp(-spatial_dist_sq / (2 * sigma_space_sq)) *
                        @exp(-color_dist_sq / (2 * sigma_color_sq));

                    sum_r += r * weight;
                    sum_g += g * weight;
                    sum_b += b * weight;
                    weight_sum += weight;
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            image.pixels[out_idx] = @intFromFloat(sum_r / weight_sum);
            if (bpp >= 3) {
                image.pixels[out_idx + 1] = @intFromFloat(sum_g / weight_sum);
                image.pixels[out_idx + 2] = @intFromFloat(sum_b / weight_sum);
            }
        }
    }
}

// ============================================================================
// Unsharp Mask
// ============================================================================

/// Unsharp mask parameters
pub const UnsharpMaskParams = struct {
    radius: u32 = 2,
    amount: f32 = 1.0, // Strength (0.0 - 3.0+)
    threshold: u8 = 0, // Only sharpen if difference > threshold
};

/// Apply unsharp mask sharpening
pub fn unsharpMask(image: *Image, params: UnsharpMaskParams, allocator: std.mem.Allocator) !void {
    // Create blurred version
    var blurred = try image.clone();
    defer blurred.deinit();

    try gaussianBlur(&blurred, params.radius, allocator);

    const bpp = image.format.bytesPerPixel();

    // Apply unsharp mask: original + amount * (original - blurred)
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bpp;

            for (0..@min(bpp, 3)) |c| {
                const orig: f32 = @floatFromInt(image.pixels[idx + c]);
                const blur: f32 = @floatFromInt(blurred.pixels[idx + c]);
                const diff = orig - blur;

                // Apply threshold
                if (@abs(diff) > @as(f32, @floatFromInt(params.threshold))) {
                    const result = orig + diff * params.amount;
                    image.pixels[idx + c] = @intFromFloat(std.math.clamp(result, 0, 255));
                }
            }
        }
    }
}

/// Gaussian blur helper
pub fn gaussianBlur(image: *Image, radius: u32, allocator: std.mem.Allocator) !void {
    const size = 2 * radius + 1;
    const sigma = @as(f32, @floatFromInt(radius)) / 3.0;

    // Generate 1D kernel
    var kernel = try allocator.alloc(f32, size);
    defer allocator.free(kernel);

    var sum: f32 = 0;
    for (0..size) |i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        kernel[i] = @exp(-(x * x) / (2 * sigma * sigma));
        sum += kernel[i];
    }
    for (kernel) |*k| k.* /= sum;

    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    const bpp = image.format.bytesPerPixel();

    // Horizontal pass
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var sums = [_]f32{0} ** 4;

            for (0..size) |k| {
                const px_i = @as(i32, @intCast(x)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const px: u32 = @intCast(std.math.clamp(px_i, 0, @as(i32, @intCast(image.width)) - 1));
                const idx = (y * image.width + px) * bpp;

                for (0..bpp) |c| {
                    sums[c] += @as(f32, @floatFromInt(image.pixels[idx + c])) * kernel[k];
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            for (0..bpp) |c| {
                temp[out_idx + c] = @intFromFloat(std.math.clamp(sums[c], 0, 255));
            }
        }
    }

    // Vertical pass
    y = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var sums = [_]f32{0} ** 4;

            for (0..size) |k| {
                const py_i = @as(i32, @intCast(y)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const py: u32 = @intCast(std.math.clamp(py_i, 0, @as(i32, @intCast(image.height)) - 1));
                const idx = (py * image.width + x) * bpp;

                for (0..bpp) |c| {
                    sums[c] += @as(f32, @floatFromInt(temp[idx + c])) * kernel[k];
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            for (0..bpp) |c| {
                image.pixels[out_idx + c] = @intFromFloat(std.math.clamp(sums[c], 0, 255));
            }
        }
    }
}

// ============================================================================
// Vignette Effect
// ============================================================================

/// Vignette parameters
pub const VignetteParams = struct {
    strength: f32 = 0.5, // 0.0 = none, 1.0 = full black at corners
    radius: f32 = 0.7, // Radius of clear center (0.0 - 1.0)
    softness: f32 = 0.5, // Edge softness
    color: Color = Color.BLACK,
};

/// Apply vignette effect
pub fn vignette(image: *Image, params: VignetteParams) void {
    const bpp = image.format.bytesPerPixel();
    const center_x: f32 = @as(f32, @floatFromInt(image.width)) / 2.0;
    const center_y: f32 = @as(f32, @floatFromInt(image.height)) / 2.0;
    const max_dist = @sqrt(center_x * center_x + center_y * center_y);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - center_x;
            const dy = @as(f32, @floatFromInt(y)) - center_y;
            const dist = @sqrt(dx * dx + dy * dy) / max_dist;

            // Calculate vignette factor
            const vignette_start = params.radius;
            const vignette_end = params.radius + params.softness;

            var factor: f32 = 0;
            if (dist > vignette_start) {
                if (dist >= vignette_end) {
                    factor = 1.0;
                } else {
                    factor = (dist - vignette_start) / (vignette_end - vignette_start);
                }
            }

            factor *= params.strength;

            const idx = (y * image.width + x) * bpp;

            for (0..@min(bpp, 3)) |c| {
                const orig: f32 = @floatFromInt(image.pixels[idx + c]);
                const target: f32 = switch (c) {
                    0 => @floatFromInt(params.color.r),
                    1 => @floatFromInt(params.color.g),
                    2 => @floatFromInt(params.color.b),
                    else => 0,
                };
                const result = orig * (1.0 - factor) + target * factor;
                image.pixels[idx + c] = @intFromFloat(result);
            }
        }
    }
}

// ============================================================================
// Lens Distortion
// ============================================================================

/// Lens distortion type
pub const DistortionType = enum {
    barrel, // Bulge outward (fisheye-like)
    pincushion, // Pinch inward
    mustache, // Combined
};

/// Lens distortion parameters
pub const LensDistortionParams = struct {
    type: DistortionType = .barrel,
    strength: f32 = 0.3, // Distortion strength
    zoom: f32 = 1.0, // Zoom to hide edges
};

/// Apply lens distortion correction/effect
pub fn lensDistortion(image: *Image, params: LensDistortionParams, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const center_x: f32 = @as(f32, @floatFromInt(image.width)) / 2.0;
    const center_y: f32 = @as(f32, @floatFromInt(image.height)) / 2.0;
    const max_r = @sqrt(center_x * center_x + center_y * center_y);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            // Normalize coordinates to -1..1
            var nx = (@as(f32, @floatFromInt(x)) - center_x) / max_r;
            var ny = (@as(f32, @floatFromInt(y)) - center_y) / max_r;

            const r = @sqrt(nx * nx + ny * ny);
            const theta = std.math.atan2(ny, nx);

            // Apply distortion
            var r_distorted: f32 = undefined;
            switch (params.type) {
                .barrel => {
                    r_distorted = r * (1.0 + params.strength * r * r);
                },
                .pincushion => {
                    r_distorted = r * (1.0 - params.strength * r * r);
                },
                .mustache => {
                    r_distorted = r * (1.0 + params.strength * r * r - params.strength * 0.5 * r * r * r * r);
                },
            }

            // Apply zoom
            r_distorted *= params.zoom;

            // Convert back to image coordinates
            nx = r_distorted * @cos(theta);
            ny = r_distorted * @sin(theta);

            const src_x = nx * max_r + center_x;
            const src_y = ny * max_r + center_y;

            // Bilinear interpolation
            const out_idx = (y * image.width + x) * bpp;

            if (src_x >= 0 and src_x < @as(f32, @floatFromInt(image.width)) - 1 and
                src_y >= 0 and src_y < @as(f32, @floatFromInt(image.height)) - 1)
            {
                const x0: u32 = @intFromFloat(src_x);
                const y0: u32 = @intFromFloat(src_y);
                const x1 = x0 + 1;
                const y1 = y0 + 1;

                const fx = src_x - @as(f32, @floatFromInt(x0));
                const fy = src_y - @as(f32, @floatFromInt(y0));

                for (0..bpp) |c| {
                    const p00: f32 = @floatFromInt(temp[(y0 * image.width + x0) * bpp + c]);
                    const p10: f32 = @floatFromInt(temp[(y0 * image.width + x1) * bpp + c]);
                    const p01: f32 = @floatFromInt(temp[(y1 * image.width + x0) * bpp + c]);
                    const p11: f32 = @floatFromInt(temp[(y1 * image.width + x1) * bpp + c]);

                    const result = p00 * (1 - fx) * (1 - fy) +
                        p10 * fx * (1 - fy) +
                        p01 * (1 - fx) * fy +
                        p11 * fx * fy;

                    image.pixels[out_idx + c] = @intFromFloat(std.math.clamp(result, 0, 255));
                }
            } else {
                // Out of bounds - black
                for (0..bpp) |c| {
                    image.pixels[out_idx + c] = 0;
                }
            }
        }
    }
}

// ============================================================================
// Chromatic Aberration
// ============================================================================

/// Chromatic aberration parameters
pub const ChromaticAberrationParams = struct {
    red_shift: f32 = 2.0, // Pixels to shift red channel outward
    blue_shift: f32 = -2.0, // Pixels to shift blue channel outward (negative = inward)
    radial: bool = true, // Radial (from center) or horizontal shift
};

/// Apply chromatic aberration effect
pub fn chromaticAberration(image: *Image, params: ChromaticAberrationParams, allocator: std.mem.Allocator) !void {
    if (image.format.bytesPerPixel() < 3) return;

    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const center_x: f32 = @as(f32, @floatFromInt(image.width)) / 2.0;
    const center_y: f32 = @as(f32, @floatFromInt(image.height)) / 2.0;
    const max_dist = @sqrt(center_x * center_x + center_y * center_y);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const out_idx = (y * image.width + x) * bpp;

            var red_src_x: f32 = @floatFromInt(x);
            var red_src_y: f32 = @floatFromInt(y);
            var blue_src_x: f32 = @floatFromInt(x);
            var blue_src_y: f32 = @floatFromInt(y);

            if (params.radial) {
                const dx = @as(f32, @floatFromInt(x)) - center_x;
                const dy = @as(f32, @floatFromInt(y)) - center_y;
                const dist = @sqrt(dx * dx + dy * dy);

                if (dist > 0) {
                    const nx = dx / dist;
                    const ny = dy / dist;
                    const factor = dist / max_dist;

                    red_src_x -= nx * params.red_shift * factor;
                    red_src_y -= ny * params.red_shift * factor;
                    blue_src_x -= nx * params.blue_shift * factor;
                    blue_src_y -= ny * params.blue_shift * factor;
                }
            } else {
                red_src_x -= params.red_shift;
                blue_src_x -= params.blue_shift;
            }

            // Sample red channel
            const r = sampleChannel(temp, image.width, image.height, bpp, red_src_x, red_src_y, 0);
            // Green stays in place
            const g = temp[out_idx + 1];
            // Sample blue channel
            const b = sampleChannel(temp, image.width, image.height, bpp, blue_src_x, blue_src_y, 2);

            image.pixels[out_idx] = r;
            image.pixels[out_idx + 1] = g;
            image.pixels[out_idx + 2] = b;
        }
    }
}

fn sampleChannel(data: []const u8, width: u32, height: u32, bpp: u32, fx: f32, fy: f32, channel: usize) u8 {
    if (fx < 0 or fx >= @as(f32, @floatFromInt(width)) - 1 or
        fy < 0 or fy >= @as(f32, @floatFromInt(height)) - 1)
    {
        return 0;
    }

    const x0: u32 = @intFromFloat(fx);
    const y0: u32 = @intFromFloat(fy);
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);

    const fx_frac = fx - @as(f32, @floatFromInt(x0));
    const fy_frac = fy - @as(f32, @floatFromInt(y0));

    const p00: f32 = @floatFromInt(data[(y0 * width + x0) * bpp + channel]);
    const p10: f32 = @floatFromInt(data[(y0 * width + x1) * bpp + channel]);
    const p01: f32 = @floatFromInt(data[(y1 * width + x0) * bpp + channel]);
    const p11: f32 = @floatFromInt(data[(y1 * width + x1) * bpp + channel]);

    const result = p00 * (1 - fx_frac) * (1 - fy_frac) +
        p10 * fx_frac * (1 - fy_frac) +
        p01 * (1 - fx_frac) * fy_frac +
        p11 * fx_frac * fy_frac;

    return @intFromFloat(std.math.clamp(result, 0, 255));
}

// ============================================================================
// Additional Filters
// ============================================================================

/// Box blur (simple averaging)
pub fn boxBlur(image: *Image, radius: u32, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const size = (2 * radius + 1) * (2 * radius + 1);

    var y: u32 = radius;
    while (y < image.height - radius) : (y += 1) {
        var x: u32 = radius;
        while (x < image.width - radius) : (x += 1) {
            var sums = [_]u32{0} ** 4;

            for (0..(2 * radius + 1)) |ky| {
                for (0..(2 * radius + 1)) |kx| {
                    const px = x + @as(u32, @intCast(kx)) - radius;
                    const py = y + @as(u32, @intCast(ky)) - radius;
                    const idx = (py * image.width + px) * bpp;

                    for (0..bpp) |c| {
                        sums[c] += temp[idx + c];
                    }
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            for (0..bpp) |c| {
                image.pixels[out_idx + c] = @intCast(sums[c] / size);
            }
        }
    }
}

/// Motion blur
pub fn motionBlur(image: *Image, angle: f32, length: u32, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const dx = @cos(angle);
    const dy = @sin(angle);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var sums = [_]f32{0} ** 4;
            var count: f32 = 0;

            for (0..length) |i| {
                const offset = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(length)) / 2.0;
                const sx = @as(f32, @floatFromInt(x)) + dx * offset;
                const sy = @as(f32, @floatFromInt(y)) + dy * offset;

                if (sx >= 0 and sx < @as(f32, @floatFromInt(image.width)) and
                    sy >= 0 and sy < @as(f32, @floatFromInt(image.height)))
                {
                    const idx = (@as(u32, @intFromFloat(sy)) * image.width + @as(u32, @intFromFloat(sx))) * bpp;
                    for (0..bpp) |c| {
                        sums[c] += @floatFromInt(temp[idx + c]);
                    }
                    count += 1;
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            for (0..bpp) |c| {
                image.pixels[out_idx + c] = @intFromFloat(sums[c] / count);
            }
        }
    }
}

/// Radial blur (zoom blur)
pub fn radialBlur(image: *Image, strength: f32, allocator: std.mem.Allocator) !void {
    const temp = try allocator.alloc(u8, image.pixels.len);
    defer allocator.free(temp);
    @memcpy(temp, image.pixels);

    const bpp = image.format.bytesPerPixel();
    const center_x: f32 = @as(f32, @floatFromInt(image.width)) / 2.0;
    const center_y: f32 = @as(f32, @floatFromInt(image.height)) / 2.0;
    const samples: u32 = 16;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - center_x;
            const dy = @as(f32, @floatFromInt(y)) - center_y;

            var sums = [_]f32{0} ** 4;
            var count: f32 = 0;

            for (0..samples) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples)) * strength;
                const sx = center_x + dx * (1.0 - t);
                const sy = center_y + dy * (1.0 - t);

                if (sx >= 0 and sx < @as(f32, @floatFromInt(image.width)) and
                    sy >= 0 and sy < @as(f32, @floatFromInt(image.height)))
                {
                    const idx = (@as(u32, @intFromFloat(sy)) * image.width + @as(u32, @intFromFloat(sx))) * bpp;
                    for (0..bpp) |c| {
                        sums[c] += @floatFromInt(temp[idx + c]);
                    }
                    count += 1;
                }
            }

            const out_idx = (y * image.width + x) * bpp;
            for (0..bpp) |c| {
                image.pixels[out_idx + c] = @intFromFloat(sums[c] / count);
            }
        }
    }
}
