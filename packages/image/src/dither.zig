const std = @import("std");
const Image = @import("image.zig").Image;

/// Dithering algorithm types
pub const Algorithm = enum {
    floyd_steinberg,
    jarvis_judice_ninke,
    stucki,
    atkinson,
    burkes,
    sierra,
    sierra_two_row,
    sierra_lite,
    ordered_2x2,
    ordered_4x4,
    ordered_8x8,
    bayer_2x2,
    bayer_4x4,
    bayer_8x8,
    random,
    threshold,
    halftone,
};

/// Dithering configuration
pub const DitherConfig = struct {
    algorithm: Algorithm = .floyd_steinberg,
    palette: ?[]const [3]u8 = null, // Custom palette, null = quantize to n colors
    num_colors: u32 = 2, // Number of colors when no palette provided
    threshold: u8 = 128, // For threshold dithering
    strength: f32 = 1.0, // Error diffusion strength (0.0 - 1.0)
    serpentine: bool = true, // Alternate row direction for error diffusion
};

/// Floyd-Steinberg error diffusion matrix
const FLOYD_STEINBERG = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 7.0 / 16.0 },
    .{ .dx = -1, .dy = 1, .weight = 3.0 / 16.0 },
    .{ .dx = 0, .dy = 1, .weight = 5.0 / 16.0 },
    .{ .dx = 1, .dy = 1, .weight = 1.0 / 16.0 },
};

/// Jarvis-Judice-Ninke error diffusion matrix
const JARVIS_JUDICE_NINKE = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 7.0 / 48.0 },
    .{ .dx = 2, .dy = 0, .weight = 5.0 / 48.0 },
    .{ .dx = -2, .dy = 1, .weight = 3.0 / 48.0 },
    .{ .dx = -1, .dy = 1, .weight = 5.0 / 48.0 },
    .{ .dx = 0, .dy = 1, .weight = 7.0 / 48.0 },
    .{ .dx = 1, .dy = 1, .weight = 5.0 / 48.0 },
    .{ .dx = 2, .dy = 1, .weight = 3.0 / 48.0 },
    .{ .dx = -2, .dy = 2, .weight = 1.0 / 48.0 },
    .{ .dx = -1, .dy = 2, .weight = 3.0 / 48.0 },
    .{ .dx = 0, .dy = 2, .weight = 5.0 / 48.0 },
    .{ .dx = 1, .dy = 2, .weight = 3.0 / 48.0 },
    .{ .dx = 2, .dy = 2, .weight = 1.0 / 48.0 },
};

/// Stucki error diffusion matrix
const STUCKI = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 8.0 / 42.0 },
    .{ .dx = 2, .dy = 0, .weight = 4.0 / 42.0 },
    .{ .dx = -2, .dy = 1, .weight = 2.0 / 42.0 },
    .{ .dx = -1, .dy = 1, .weight = 4.0 / 42.0 },
    .{ .dx = 0, .dy = 1, .weight = 8.0 / 42.0 },
    .{ .dx = 1, .dy = 1, .weight = 4.0 / 42.0 },
    .{ .dx = 2, .dy = 1, .weight = 2.0 / 42.0 },
    .{ .dx = -2, .dy = 2, .weight = 1.0 / 42.0 },
    .{ .dx = -1, .dy = 2, .weight = 2.0 / 42.0 },
    .{ .dx = 0, .dy = 2, .weight = 4.0 / 42.0 },
    .{ .dx = 1, .dy = 2, .weight = 2.0 / 42.0 },
    .{ .dx = 2, .dy = 2, .weight = 1.0 / 42.0 },
};

/// Atkinson error diffusion matrix (only diffuses 6/8 = 75% of error)
const ATKINSON = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 1.0 / 8.0 },
    .{ .dx = 2, .dy = 0, .weight = 1.0 / 8.0 },
    .{ .dx = -1, .dy = 1, .weight = 1.0 / 8.0 },
    .{ .dx = 0, .dy = 1, .weight = 1.0 / 8.0 },
    .{ .dx = 1, .dy = 1, .weight = 1.0 / 8.0 },
    .{ .dx = 0, .dy = 2, .weight = 1.0 / 8.0 },
};

/// Burkes error diffusion matrix
const BURKES = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 8.0 / 32.0 },
    .{ .dx = 2, .dy = 0, .weight = 4.0 / 32.0 },
    .{ .dx = -2, .dy = 1, .weight = 2.0 / 32.0 },
    .{ .dx = -1, .dy = 1, .weight = 4.0 / 32.0 },
    .{ .dx = 0, .dy = 1, .weight = 8.0 / 32.0 },
    .{ .dx = 1, .dy = 1, .weight = 4.0 / 32.0 },
    .{ .dx = 2, .dy = 1, .weight = 2.0 / 32.0 },
};

/// Sierra error diffusion matrix
const SIERRA = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 5.0 / 32.0 },
    .{ .dx = 2, .dy = 0, .weight = 3.0 / 32.0 },
    .{ .dx = -2, .dy = 1, .weight = 2.0 / 32.0 },
    .{ .dx = -1, .dy = 1, .weight = 4.0 / 32.0 },
    .{ .dx = 0, .dy = 1, .weight = 5.0 / 32.0 },
    .{ .dx = 1, .dy = 1, .weight = 4.0 / 32.0 },
    .{ .dx = 2, .dy = 1, .weight = 2.0 / 32.0 },
    .{ .dx = -1, .dy = 2, .weight = 2.0 / 32.0 },
    .{ .dx = 0, .dy = 2, .weight = 3.0 / 32.0 },
    .{ .dx = 1, .dy = 2, .weight = 2.0 / 32.0 },
};

/// Sierra Two Row error diffusion matrix
const SIERRA_TWO_ROW = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 4.0 / 16.0 },
    .{ .dx = 2, .dy = 0, .weight = 3.0 / 16.0 },
    .{ .dx = -2, .dy = 1, .weight = 1.0 / 16.0 },
    .{ .dx = -1, .dy = 1, .weight = 2.0 / 16.0 },
    .{ .dx = 0, .dy = 1, .weight = 3.0 / 16.0 },
    .{ .dx = 1, .dy = 1, .weight = 2.0 / 16.0 },
    .{ .dx = 2, .dy = 1, .weight = 1.0 / 16.0 },
};

/// Sierra Lite error diffusion matrix
const SIERRA_LITE = [_]ErrorDiffusion{
    .{ .dx = 1, .dy = 0, .weight = 2.0 / 4.0 },
    .{ .dx = -1, .dy = 1, .weight = 1.0 / 4.0 },
    .{ .dx = 0, .dy = 1, .weight = 1.0 / 4.0 },
};

/// Error diffusion entry
const ErrorDiffusion = struct {
    dx: i32,
    dy: i32,
    weight: f32,
};

/// 2x2 Bayer matrix
const BAYER_2X2 = [2][2]u8{
    .{ 0, 2 },
    .{ 3, 1 },
};

/// 4x4 Bayer matrix
const BAYER_4X4 = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

/// 8x8 Bayer matrix
const BAYER_8X8 = [8][8]u8{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },
    .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 },
    .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },
    .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 },
    .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

/// Apply dithering to an image
pub fn dither(image: *Image, config: DitherConfig, allocator: std.mem.Allocator) !void {
    switch (config.algorithm) {
        .floyd_steinberg => try applyErrorDiffusion(image, &FLOYD_STEINBERG, config, allocator),
        .jarvis_judice_ninke => try applyErrorDiffusion(image, &JARVIS_JUDICE_NINKE, config, allocator),
        .stucki => try applyErrorDiffusion(image, &STUCKI, config, allocator),
        .atkinson => try applyErrorDiffusion(image, &ATKINSON, config, allocator),
        .burkes => try applyErrorDiffusion(image, &BURKES, config, allocator),
        .sierra => try applyErrorDiffusion(image, &SIERRA, config, allocator),
        .sierra_two_row => try applyErrorDiffusion(image, &SIERRA_TWO_ROW, config, allocator),
        .sierra_lite => try applyErrorDiffusion(image, &SIERRA_LITE, config, allocator),
        .ordered_2x2, .bayer_2x2 => applyOrderedDither(image, 2, config),
        .ordered_4x4, .bayer_4x4 => applyOrderedDither(image, 4, config),
        .ordered_8x8, .bayer_8x8 => applyOrderedDither(image, 8, config),
        .random => applyRandomDither(image, config),
        .threshold => applyThresholdDither(image, config),
        .halftone => try applyHalftone(image, config, allocator),
    }
}

/// Apply error diffusion dithering
fn applyErrorDiffusion(
    image: *Image,
    matrix: []const ErrorDiffusion,
    config: DitherConfig,
    allocator: std.mem.Allocator,
) !void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    // Create error buffer (using f32 for precision)
    const error_buffer = try allocator.alloc(f32, image.width * image.height * 3);
    defer allocator.free(error_buffer);
    @memset(error_buffer, 0);

    // Get or generate palette
    const palette = if (config.palette) |p| p else try generatePalette(config.num_colors, allocator);
    defer if (config.palette == null) allocator.free(palette);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        const reverse = config.serpentine and (y % 2 == 1);

        var x: u32 = if (reverse) image.width - 1 else 0;
        const end_x: u32 = if (reverse) 0 else image.width - 1;
        const step: i32 = if (reverse) -1 else 1;

        while (true) {
            const idx = (y * image.width + x) * bytes_per_pixel;
            const err_idx = (y * image.width + x) * 3;

            // Get current pixel + accumulated error
            var r: f32 = @floatFromInt(image.pixels[idx]);
            var g: f32 = if (bytes_per_pixel >= 3) @floatFromInt(image.pixels[idx + 1]) else r;
            var b: f32 = if (bytes_per_pixel >= 3) @floatFromInt(image.pixels[idx + 2]) else r;

            r += error_buffer[err_idx];
            g += error_buffer[err_idx + 1];
            b += error_buffer[err_idx + 2];

            // Find closest palette color
            const closest = findClosestColor(palette, @intFromFloat(std.math.clamp(r, 0, 255)), @intFromFloat(std.math.clamp(g, 0, 255)), @intFromFloat(std.math.clamp(b, 0, 255)));

            // Set pixel to palette color
            if (bytes_per_pixel == 1) {
                image.pixels[idx] = @intFromFloat(
                    @as(f32, @floatFromInt(closest[0])) * 0.299 +
                        @as(f32, @floatFromInt(closest[1])) * 0.587 +
                        @as(f32, @floatFromInt(closest[2])) * 0.114,
                );
            } else if (bytes_per_pixel >= 3) {
                image.pixels[idx] = closest[0];
                image.pixels[idx + 1] = closest[1];
                image.pixels[idx + 2] = closest[2];
            }

            // Calculate quantization error
            const err_r = (r - @as(f32, @floatFromInt(closest[0]))) * config.strength;
            const err_g = (g - @as(f32, @floatFromInt(closest[1]))) * config.strength;
            const err_b = (b - @as(f32, @floatFromInt(closest[2]))) * config.strength;

            // Diffuse error to neighbors
            for (matrix) |entry| {
                const nx_signed = @as(i32, @intCast(x)) + (if (reverse) -entry.dx else entry.dx);
                const ny = y + @as(u32, @intCast(entry.dy));

                if (nx_signed >= 0 and nx_signed < @as(i32, @intCast(image.width)) and ny < image.height) {
                    const nx: u32 = @intCast(nx_signed);
                    const neighbor_err_idx = (ny * image.width + nx) * 3;
                    error_buffer[neighbor_err_idx] += err_r * entry.weight;
                    error_buffer[neighbor_err_idx + 1] += err_g * entry.weight;
                    error_buffer[neighbor_err_idx + 2] += err_b * entry.weight;
                }
            }

            if (x == end_x) break;
            x = @intCast(@as(i32, @intCast(x)) + step);
        }
    }
}

/// Apply ordered (Bayer) dithering
fn applyOrderedDither(image: *Image, matrix_size: u32, config: DitherConfig) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const num_colors = config.num_colors;
    const step: f32 = 255.0 / @as(f32, @floatFromInt(num_colors - 1));

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            // Get threshold from Bayer matrix
            const threshold_norm: f32 = getBayerThreshold(x, y, matrix_size);
            const threshold: f32 = (threshold_norm - 0.5) * step;

            // Apply to each channel
            for (0..@min(bytes_per_pixel, 3)) |c| {
                const val: f32 = @floatFromInt(image.pixels[idx + c]);
                const adjusted = val + threshold;
                const quantized = @round(adjusted / step) * step;
                image.pixels[idx + c] = @intFromFloat(std.math.clamp(quantized, 0, 255));
            }
        }
    }
}

/// Get normalized threshold from Bayer matrix
fn getBayerThreshold(x: u32, y: u32, size: u32) f32 {
    const mx = x % size;
    const my = y % size;

    const value: f32 = switch (size) {
        2 => @floatFromInt(BAYER_2X2[my][mx]),
        4 => @floatFromInt(BAYER_4X4[my][mx]),
        8 => @floatFromInt(BAYER_8X8[my][mx]),
        else => 0,
    };

    const max_value: f32 = @floatFromInt(size * size);
    return value / max_value;
}

/// Apply random (white noise) dithering
fn applyRandomDither(image: *Image, config: DitherConfig) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();

    const num_colors = config.num_colors;
    const step: f32 = 255.0 / @as(f32, @floatFromInt(num_colors - 1));

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            for (0..@min(bytes_per_pixel, 3)) |c| {
                const val: f32 = @floatFromInt(image.pixels[idx + c]);
                const noise = (random.float(f32) - 0.5) * step * config.strength;
                const adjusted = val + noise;
                const quantized = @round(adjusted / step) * step;
                image.pixels[idx + c] = @intFromFloat(std.math.clamp(quantized, 0, 255));
            }
        }
    }
}

/// Apply simple threshold dithering
fn applyThresholdDither(image: *Image, config: DitherConfig) void {
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const threshold = config.threshold;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            for (0..@min(bytes_per_pixel, 3)) |c| {
                image.pixels[idx + c] = if (image.pixels[idx + c] >= threshold) 255 else 0;
            }
        }
    }
}

/// Apply halftone dithering (circular dots)
fn applyHalftone(image: *Image, config: DitherConfig, allocator: std.mem.Allocator) !void {
    _ = allocator;

    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const cell_size: u32 = 4;
    const half_cell: f32 = @as(f32, @floatFromInt(cell_size)) / 2.0;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            // Calculate position within cell
            const cell_x = x % cell_size;
            const cell_y = y % cell_size;

            // Distance from cell center
            const dx = @as(f32, @floatFromInt(cell_x)) - half_cell + 0.5;
            const dy = @as(f32, @floatFromInt(cell_y)) - half_cell + 0.5;
            const dist = @sqrt(dx * dx + dy * dy);

            // Get average intensity for this cell
            const cell_start_x = (x / cell_size) * cell_size;
            const cell_start_y = (y / cell_size) * cell_size;
            var sum: f32 = 0;
            var count: u32 = 0;

            var cy: u32 = cell_start_y;
            while (cy < cell_start_y + cell_size and cy < image.height) : (cy += 1) {
                var cx: u32 = cell_start_x;
                while (cx < cell_start_x + cell_size and cx < image.width) : (cx += 1) {
                    const cidx = (cy * image.width + cx) * bytes_per_pixel;
                    if (bytes_per_pixel == 1) {
                        sum += @floatFromInt(image.pixels[cidx]);
                    } else {
                        sum += @as(f32, @floatFromInt(image.pixels[cidx])) * 0.299 +
                            @as(f32, @floatFromInt(image.pixels[cidx + 1])) * 0.587 +
                            @as(f32, @floatFromInt(image.pixels[cidx + 2])) * 0.114;
                    }
                    count += 1;
                }
            }

            const avg = sum / @as(f32, @floatFromInt(count));
            const radius = (1.0 - avg / 255.0) * half_cell * 1.5;

            // Set pixel based on whether it's inside the dot
            const inside = dist < radius;
            for (0..@min(bytes_per_pixel, 3)) |c| {
                image.pixels[idx + c] = if (inside) 0 else 255;
            }
        }
    }
}

/// Find closest color in palette
fn findClosestColor(palette: []const [3]u8, r: u8, g: u8, b: u8) [3]u8 {
    var closest = palette[0];
    var min_dist: u32 = std.math.maxInt(u32);

    for (palette) |color| {
        const dr = @as(i32, @intCast(r)) - @as(i32, @intCast(color[0]));
        const dg = @as(i32, @intCast(g)) - @as(i32, @intCast(color[1]));
        const db = @as(i32, @intCast(b)) - @as(i32, @intCast(color[2]));

        // Weighted distance (more weight to green for perceptual accuracy)
        const dist: u32 = @intCast(dr * dr * 2 + dg * dg * 4 + db * db * 3);

        if (dist < min_dist) {
            min_dist = dist;
            closest = color;
        }
    }

    return closest;
}

/// Generate a simple grayscale palette with n colors
fn generatePalette(num_colors: u32, allocator: std.mem.Allocator) ![]const [3]u8 {
    const palette = try allocator.alloc([3]u8, num_colors);

    for (0..num_colors) |i| {
        const val: u8 = @intFromFloat(@as(f32, @floatFromInt(i)) * 255.0 / @as(f32, @floatFromInt(num_colors - 1)));
        palette[i] = .{ val, val, val };
    }

    return palette;
}

/// Predefined palettes
pub const Palettes = struct {
    /// Classic 1-bit black and white
    pub const black_white = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 255, 255, 255 },
    };

    /// CGA 4-color palette (cyan, magenta, white, black)
    pub const cga = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 0, 255, 255 },
        .{ 255, 0, 255 },
        .{ 255, 255, 255 },
    };

    /// EGA 16-color palette
    pub const ega = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 0, 0, 170 },
        .{ 0, 170, 0 },
        .{ 0, 170, 170 },
        .{ 170, 0, 0 },
        .{ 170, 0, 170 },
        .{ 170, 85, 0 },
        .{ 170, 170, 170 },
        .{ 85, 85, 85 },
        .{ 85, 85, 255 },
        .{ 85, 255, 85 },
        .{ 85, 255, 255 },
        .{ 255, 85, 85 },
        .{ 255, 85, 255 },
        .{ 255, 255, 85 },
        .{ 255, 255, 255 },
    };

    /// Game Boy 4-color palette
    pub const gameboy = [_][3]u8{
        .{ 15, 56, 15 },
        .{ 48, 98, 48 },
        .{ 139, 172, 15 },
        .{ 155, 188, 15 },
    };

    /// Commodore 64 16-color palette
    pub const c64 = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 255, 255, 255 },
        .{ 136, 0, 0 },
        .{ 170, 255, 238 },
        .{ 204, 68, 204 },
        .{ 0, 204, 85 },
        .{ 0, 0, 170 },
        .{ 238, 238, 119 },
        .{ 221, 136, 85 },
        .{ 102, 68, 0 },
        .{ 255, 119, 119 },
        .{ 51, 51, 51 },
        .{ 119, 119, 119 },
        .{ 170, 255, 102 },
        .{ 0, 136, 255 },
        .{ 187, 187, 187 },
    };

    /// Web-safe 216-color palette
    pub fn webSafe(allocator: std.mem.Allocator) ![][3]u8 {
        const palette = try allocator.alloc([3]u8, 216);
        var idx: usize = 0;

        for ([_]u8{ 0, 51, 102, 153, 204, 255 }) |r| {
            for ([_]u8{ 0, 51, 102, 153, 204, 255 }) |g| {
                for ([_]u8{ 0, 51, 102, 153, 204, 255 }) |b| {
                    palette[idx] = .{ r, g, b };
                    idx += 1;
                }
            }
        }

        return palette;
    }
};

/// Apply blue noise dithering (higher quality than white noise)
pub fn applyBlueNoiseDither(image: *Image, config: DitherConfig) void {
    // Blue noise uses a precomputed void-and-cluster pattern
    // For simplicity, we'll use a simple approximation
    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    const num_colors = config.num_colors;
    const step: f32 = 255.0 / @as(f32, @floatFromInt(num_colors - 1));

    // Simple blue noise approximation using interleaved gradient noise
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            // Interleaved gradient noise (approximates blue noise)
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const noise = @mod(52.9829189 * @mod(0.06711056 * fx + 0.00583715 * fy, 1.0), 1.0);
            const threshold = (noise - 0.5) * step * config.strength;

            for (0..@min(bytes_per_pixel, 3)) |c| {
                const val: f32 = @floatFromInt(image.pixels[idx + c]);
                const adjusted = val + threshold;
                const quantized = @round(adjusted / step) * step;
                image.pixels[idx + c] = @intFromFloat(std.math.clamp(quantized, 0, 255));
            }
        }
    }
}

/// Convert image to specified number of colors using median cut quantization
pub fn quantize(image: *Image, num_colors: u32, allocator: std.mem.Allocator) ![][3]u8 {
    // Simple uniform quantization for now
    // A full implementation would use median cut or octree
    const palette = try allocator.alloc([3]u8, num_colors);

    const bytes_per_pixel: u32 = switch (image.format) {
        .grayscale => 1,
        .grayscale_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        else => 4,
    };

    // Count colors using simple histogram
    var hist = std.AutoHashMap(u24, u32).init(allocator);
    defer hist.deinit();

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = (y * image.width + x) * bytes_per_pixel;

            var r: u8 = image.pixels[idx];
            var g: u8 = if (bytes_per_pixel >= 3) image.pixels[idx + 1] else r;
            var b: u8 = if (bytes_per_pixel >= 3) image.pixels[idx + 2] else r;

            // Quantize to reduce color space
            r = (r / 16) * 16;
            g = (g / 16) * 16;
            b = (b / 16) * 16;

            const key: u24 = @as(u24, r) << 16 | @as(u24, g) << 8 | @as(u24, b);
            const entry = try hist.getOrPut(key);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }
    }

    // Pick most common colors
    var colors = std.ArrayList(struct { color: u24, count: u32 }).init(allocator);
    defer colors.deinit();

    var it = hist.iterator();
    while (it.next()) |entry| {
        try colors.append(.{ .color = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    // Sort by count
    std.mem.sort(@TypeOf(colors.items[0]), colors.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(colors.items[0]), b: @TypeOf(colors.items[0])) bool {
            return a.count > b.count;
        }
    }.lessThan);

    // Take top colors
    for (0..num_colors) |i| {
        if (i < colors.items.len) {
            const c = colors.items[i].color;
            palette[i] = .{
                @intCast((c >> 16) & 0xFF),
                @intCast((c >> 8) & 0xFF),
                @intCast(c & 0xFF),
            };
        } else {
            // Fill remaining with gray
            const val: u8 = @intFromFloat(@as(f32, @floatFromInt(i)) * 255.0 / @as(f32, @floatFromInt(num_colors - 1)));
            palette[i] = .{ val, val, val };
        }
    }

    return palette;
}
