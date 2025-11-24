const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Noise Generation
// ============================================================================

pub const NoiseType = enum {
    white,
    perlin,
    simplex,
    worley,
    fractal_brownian,
    turbulence,
};

pub const NoiseOptions = struct {
    seed: u64 = 0,
    scale: f32 = 1.0,
    octaves: u32 = 4,
    persistence: f32 = 0.5,
    lacunarity: f32 = 2.0,
    amplitude: f32 = 1.0,
    frequency: f32 = 1.0,
};

// Permutation table for Perlin/Simplex noise
const perm = blk: {
    var p: [512]u8 = undefined;
    const base = [256]u8{
        151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
        140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
        247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
        57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
        74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
        60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
        65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
        200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
        52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
        207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
        119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
        129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
        218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
        81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
        184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
        222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    };
    for (0..256) |i| {
        p[i] = base[i];
        p[i + 256] = base[i];
    }
    break :blk p;
};

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + t * (b - a);
}

fn grad(hash: u8, x: f32, y: f32, z: f32) f32 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
}

pub fn perlinNoise(x: f32, y: f32, z: f32) f32 {
    const xi: usize = @intFromFloat(@mod(@floor(x), 256));
    const yi: usize = @intFromFloat(@mod(@floor(y), 256));
    const zi: usize = @intFromFloat(@mod(@floor(z), 256));

    const xf = x - @floor(x);
    const yf = y - @floor(y);
    const zf = z - @floor(z);

    const u = fade(xf);
    const v = fade(yf);
    const w = fade(zf);

    const a = perm[xi] +% @as(u8, @intCast(yi));
    const aa = perm[a] +% @as(u8, @intCast(zi));
    const ab = perm[a +% 1] +% @as(u8, @intCast(zi));
    const b = perm[xi +% 1] +% @as(u8, @intCast(yi));
    const ba = perm[b] +% @as(u8, @intCast(zi));
    const bb = perm[b +% 1] +% @as(u8, @intCast(zi));

    return lerp(w, lerp(v, lerp(u, grad(perm[aa], xf, yf, zf), grad(perm[ba], xf - 1, yf, zf)), lerp(u, grad(perm[ab], xf, yf - 1, zf), grad(perm[bb], xf - 1, yf - 1, zf))), lerp(v, lerp(u, grad(perm[aa +% 1], xf, yf, zf - 1), grad(perm[ba +% 1], xf - 1, yf, zf - 1)), lerp(u, grad(perm[ab +% 1], xf, yf - 1, zf - 1), grad(perm[bb +% 1], xf - 1, yf - 1, zf - 1))));
}

// Simplex noise (2D)
fn dot2(gx: f32, gy: f32, x: f32, y: f32) f32 {
    return gx * x + gy * y;
}

const grad2 = [_][2]f32{
    .{ 1, 1 },   .{ -1, 1 },  .{ 1, -1 },  .{ -1, -1 },
    .{ 1, 0 },   .{ -1, 0 },  .{ 0, 1 },   .{ 0, -1 },
    .{ 1, 1 },   .{ -1, 1 },  .{ 1, -1 },  .{ -1, -1 },
    .{ 1, 0 },   .{ -1, 0 },  .{ 0, 1 },   .{ 0, -1 },
};

pub fn simplexNoise(xin: f32, yin: f32) f32 {
    const F2: f32 = 0.5 * (@sqrt(3.0) - 1.0);
    const G2: f32 = (3.0 - @sqrt(3.0)) / 6.0;

    const s = (xin + yin) * F2;
    const i = @floor(xin + s);
    const j = @floor(yin + s);

    const t = (i + j) * G2;
    const x0 = xin - (i - t);
    const y0 = yin - (j - t);

    var i1: f32 = 0;
    var j1: f32 = 0;
    if (x0 > y0) {
        i1 = 1;
        j1 = 0;
    } else {
        i1 = 0;
        j1 = 1;
    }

    const x1 = x0 - i1 + G2;
    const y1 = y0 - j1 + G2;
    const x2 = x0 - 1.0 + 2.0 * G2;
    const y2 = y0 - 1.0 + 2.0 * G2;

    const ii: usize = @intFromFloat(@mod(i, 256));
    const jj: usize = @intFromFloat(@mod(j, 256));

    const gi0 = perm[ii +% perm[jj]] % 12;
    const gi1 = perm[ii +% @as(usize, @intFromFloat(i1)) +% perm[jj +% @as(usize, @intFromFloat(j1))]] % 12;
    const gi2 = perm[ii +% 1 +% perm[jj +% 1]] % 12;

    var n0: f32 = 0;
    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 >= 0) {
        t0 *= t0;
        n0 = t0 * t0 * dot2(grad2[gi0][0], grad2[gi0][1], x0, y0);
    }

    var n1: f32 = 0;
    var t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 >= 0) {
        t1 *= t1;
        n1 = t1 * t1 * dot2(grad2[gi1][0], grad2[gi1][1], x1, y1);
    }

    var n2: f32 = 0;
    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 >= 0) {
        t2 *= t2;
        n2 = t2 * t2 * dot2(grad2[gi2][0], grad2[gi2][1], x2, y2);
    }

    return 70.0 * (n0 + n1 + n2);
}

pub fn whiteNoise(seed: u64, x: u32, y: u32) f32 {
    var state = seed ^ (@as(u64, x) << 16) ^ @as(u64, y);
    state = state *% 0x5DEECE66D +% 0xB;
    state = (state >> 16) & 0xFFFFFFFF;
    return @as(f32, @floatFromInt(state)) / 4294967295.0;
}

pub fn fractalBrownianMotion(x: f32, y: f32, options: NoiseOptions) f32 {
    var value: f32 = 0;
    var amplitude = options.amplitude;
    var frequency = options.frequency;

    for (0..options.octaves) |_| {
        value += amplitude * perlinNoise(x * frequency, y * frequency, 0);
        amplitude *= options.persistence;
        frequency *= options.lacunarity;
    }

    return value;
}

pub fn turbulence(x: f32, y: f32, options: NoiseOptions) f32 {
    var value: f32 = 0;
    var amplitude = options.amplitude;
    var frequency = options.frequency;

    for (0..options.octaves) |_| {
        value += amplitude * @abs(perlinNoise(x * frequency, y * frequency, 0));
        amplitude *= options.persistence;
        frequency *= options.lacunarity;
    }

    return value;
}

pub fn generateNoiseImage(allocator: std.mem.Allocator, width: u32, height: u32, noise_type: NoiseType, options: NoiseOptions) !Image {
    var img = try Image.create(allocator, width, height, .rgba);

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f32, @floatFromInt(x)) * options.scale / @as(f32, @floatFromInt(width));
            const fy = @as(f32, @floatFromInt(y)) * options.scale / @as(f32, @floatFromInt(height));

            const value = switch (noise_type) {
                .white => whiteNoise(options.seed, @intCast(x), @intCast(y)),
                .perlin => (perlinNoise(fx * options.frequency, fy * options.frequency, 0) + 1) * 0.5,
                .simplex => (simplexNoise(fx * options.frequency, fy * options.frequency) + 1) * 0.5,
                .worley => worleyNoise(fx * options.frequency, fy * options.frequency, options.seed),
                .fractal_brownian => (fractalBrownianMotion(fx, fy, options) + 1) * 0.5,
                .turbulence => turbulence(fx, fy, options),
            };

            const v = @as(u8, @intFromFloat(std.math.clamp(value, 0, 1) * 255));
            img.setPixel(@intCast(x), @intCast(y), Color{ .r = v, .g = v, .b = v, .a = 255 });
        }
    }

    return img;
}

fn worleyNoise(x: f32, y: f32, seed: u64) f32 {
    const xi = @floor(x);
    const yi = @floor(y);

    var min_dist: f32 = 1.0;

    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const cx = xi + @as(f32, @floatFromInt(dx));
            const cy = yi + @as(f32, @floatFromInt(dy));

            // Random point in cell
            const hash = seed ^ (@as(u64, @intFromFloat(@mod(cx, 256))) << 16) ^ @as(u64, @intFromFloat(@mod(cy, 256)));
            const px = cx + @as(f32, @floatFromInt(hash & 0xFFFF)) / 65535.0;
            const py = cy + @as(f32, @floatFromInt((hash >> 16) & 0xFFFF)) / 65535.0;

            const dist = (x - px) * (x - px) + (y - py) * (y - py);
            min_dist = @min(min_dist, dist);
        }
    }

    return @sqrt(min_dist);
}

// ============================================================================
// Gradient Fills
// ============================================================================

pub const GradientType = enum {
    linear,
    radial,
    angular,
    diamond,
    conical,
    reflected,
};

pub const GradientStop = struct {
    position: f32, // 0.0 to 1.0
    color: Color,
};

pub const GradientOptions = struct {
    start_x: f32 = 0,
    start_y: f32 = 0,
    end_x: f32 = 1,
    end_y: f32 = 1,
    center_x: f32 = 0.5,
    center_y: f32 = 0.5,
    radius: f32 = 0.5,
    angle: f32 = 0, // radians
    repeat: bool = false,
    dither: bool = true,
};

fn interpolateColor(c1: Color, c2: Color, t: f32) Color {
    return Color{
        .r = @intFromFloat(lerp(t, @as(f32, @floatFromInt(c1.r)), @as(f32, @floatFromInt(c2.r)))),
        .g = @intFromFloat(lerp(t, @as(f32, @floatFromInt(c1.g)), @as(f32, @floatFromInt(c2.g)))),
        .b = @intFromFloat(lerp(t, @as(f32, @floatFromInt(c1.b)), @as(f32, @floatFromInt(c2.b)))),
        .a = @intFromFloat(lerp(t, @as(f32, @floatFromInt(c1.a)), @as(f32, @floatFromInt(c2.a)))),
    };
}

fn sampleGradient(stops: []const GradientStop, t: f32) Color {
    if (stops.len == 0) return Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (stops.len == 1) return stops[0].color;

    var clamped_t = std.math.clamp(t, 0, 1);

    // Find the two stops to interpolate between
    var i: usize = 0;
    while (i < stops.len - 1 and stops[i + 1].position < clamped_t) : (i += 1) {}

    if (i >= stops.len - 1) return stops[stops.len - 1].color;

    const t0 = stops[i].position;
    const t1 = stops[i + 1].position;
    const local_t = if (t1 - t0 > 0.0001) (clamped_t - t0) / (t1 - t0) else 0;

    return interpolateColor(stops[i].color, stops[i + 1].color, local_t);
}

pub fn generateGradient(allocator: std.mem.Allocator, width: u32, height: u32, gradient_type: GradientType, stops: []const GradientStop, options: GradientOptions) !Image {
    var img = try Image.create(allocator, width, height, .rgba);

    const fw = @as(f32, @floatFromInt(width));
    const fh = @as(f32, @floatFromInt(height));

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f32, @floatFromInt(x)) / fw;
            const fy = @as(f32, @floatFromInt(y)) / fh;

            var t: f32 = switch (gradient_type) {
                .linear => blk: {
                    const dx = options.end_x - options.start_x;
                    const dy = options.end_y - options.start_y;
                    const len_sq = dx * dx + dy * dy;
                    if (len_sq < 0.0001) break :blk 0;
                    const px = fx - options.start_x;
                    const py = fy - options.start_y;
                    break :blk (px * dx + py * dy) / len_sq;
                },
                .radial => blk: {
                    const dx = fx - options.center_x;
                    const dy = fy - options.center_y;
                    const dist = @sqrt(dx * dx + dy * dy);
                    break :blk dist / options.radius;
                },
                .angular => blk: {
                    const dx = fx - options.center_x;
                    const dy = fy - options.center_y;
                    var angle = std.math.atan2(dy, dx) - options.angle;
                    if (angle < 0) angle += std.math.pi * 2;
                    break :blk angle / (std.math.pi * 2);
                },
                .diamond => blk: {
                    const dx = @abs(fx - options.center_x);
                    const dy = @abs(fy - options.center_y);
                    break :blk (dx + dy) / options.radius;
                },
                .conical => blk: {
                    const dx = fx - options.center_x;
                    const dy = fy - options.center_y;
                    var angle = std.math.atan2(dy, dx) - options.angle;
                    if (angle < 0) angle += std.math.pi * 2;
                    break :blk angle / (std.math.pi * 2);
                },
                .reflected => blk: {
                    const dx = options.end_x - options.start_x;
                    const dy = options.end_y - options.start_y;
                    const len_sq = dx * dx + dy * dy;
                    if (len_sq < 0.0001) break :blk 0;
                    const px = fx - options.start_x;
                    const py = fy - options.start_y;
                    const raw_t = (px * dx + py * dy) / len_sq;
                    break :blk 1.0 - @abs(1.0 - 2.0 * raw_t);
                },
            };

            if (options.repeat) {
                t = t - @floor(t);
            }

            var color = sampleGradient(stops, t);

            // Add dithering to reduce banding
            if (options.dither) {
                const dither = (whiteNoise(12345, @intCast(x), @intCast(y)) - 0.5) * 2.0;
                const dr = @as(f32, @floatFromInt(color.r)) + dither;
                const dg = @as(f32, @floatFromInt(color.g)) + dither;
                const db = @as(f32, @floatFromInt(color.b)) + dither;
                color.r = @intFromFloat(std.math.clamp(dr, 0, 255));
                color.g = @intFromFloat(std.math.clamp(dg, 0, 255));
                color.b = @intFromFloat(std.math.clamp(db, 0, 255));
            }

            img.setPixel(@intCast(x), @intCast(y), color);
        }
    }

    return img;
}

// ============================================================================
// Pattern Fills
// ============================================================================

pub const PatternType = enum {
    checkerboard,
    stripes_horizontal,
    stripes_vertical,
    stripes_diagonal,
    dots,
    grid,
    hatch,
    crosshatch,
    brick,
    hexagon,
};

pub const PatternOptions = struct {
    color1: Color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    color2: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    size: u32 = 16,
    line_width: u32 = 1,
    spacing: u32 = 8,
    angle: f32 = 0, // radians
    antialias: bool = true,
};

pub fn generatePattern(allocator: std.mem.Allocator, width: u32, height: u32, pattern_type: PatternType, options: PatternOptions) !Image {
    var img = try Image.create(allocator, width, height, .rgba);

    const size = @max(1, options.size);

    for (0..height) |y| {
        for (0..width) |x| {
            const color = switch (pattern_type) {
                .checkerboard => blk: {
                    const cx = x / size;
                    const cy = y / size;
                    break :blk if ((cx + cy) % 2 == 0) options.color1 else options.color2;
                },
                .stripes_horizontal => blk: {
                    break :blk if ((y / size) % 2 == 0) options.color1 else options.color2;
                },
                .stripes_vertical => blk: {
                    break :blk if ((x / size) % 2 == 0) options.color1 else options.color2;
                },
                .stripes_diagonal => blk: {
                    const diag = (x + y) / size;
                    break :blk if (diag % 2 == 0) options.color1 else options.color2;
                },
                .dots => blk: {
                    const cx = @mod(x, size);
                    const cy = @mod(y, size);
                    const half = size / 2;
                    const dx = if (cx > half) cx - half else half - cx;
                    const dy = if (cy > half) cy - half else half - cy;
                    const radius = size / 4;
                    break :blk if (dx * dx + dy * dy <= radius * radius) options.color1 else options.color2;
                },
                .grid => blk: {
                    const mx = @mod(x, size);
                    const my = @mod(y, size);
                    break :blk if (mx < options.line_width or my < options.line_width) options.color1 else options.color2;
                },
                .hatch => blk: {
                    const diag = @mod(x + y, size);
                    break :blk if (diag < options.line_width) options.color1 else options.color2;
                },
                .crosshatch => blk: {
                    const diag1 = @mod(x + y, size);
                    const diag2 = @mod(x + size - @mod(y, size), size);
                    break :blk if (diag1 < options.line_width or diag2 < options.line_width) options.color1 else options.color2;
                },
                .brick => blk: {
                    const row = y / size;
                    const offset: usize = if (row % 2 == 0) 0 else size / 2;
                    const mx = @mod(x + offset, size);
                    const my = @mod(y, size);
                    break :blk if (mx < options.line_width or my < options.line_width) options.color1 else options.color2;
                },
                .hexagon => blk: {
                    // Simplified hexagon pattern
                    const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(size));
                    const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(size));
                    const hx = fx - @floor(fx);
                    const hy = fy - @floor(fy);
                    const hex = @abs(hx - 0.5) + @abs(hy - 0.5);
                    break :blk if (hex > 0.4 and hex < 0.6) options.color1 else options.color2;
                },
            };

            img.setPixel(@intCast(x), @intCast(y), color);
        }
    }

    return img;
}

// ============================================================================
// Drop Shadow / Glow Effects
// ============================================================================

pub const ShadowOptions = struct {
    offset_x: i32 = 4,
    offset_y: i32 = 4,
    blur_radius: u32 = 8,
    color: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 128 },
    spread: i32 = 0,
    inner: bool = false,
};

pub const GlowOptions = struct {
    radius: u32 = 8,
    color: Color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    intensity: f32 = 1.0,
    inner: bool = false,
};

pub fn applyDropShadow(allocator: std.mem.Allocator, img: *Image, options: ShadowOptions) !Image {
    const new_width = img.width + @as(u32, @intCast(@abs(options.offset_x) + @as(i32, @intCast(options.blur_radius)) * 2));
    const new_height = img.height + @as(u32, @intCast(@abs(options.offset_y) + @as(i32, @intCast(options.blur_radius)) * 2));

    var result = try Image.create(allocator, new_width, new_height, .rgba);

    // Calculate offsets for centering
    const pad = @as(i32, @intCast(options.blur_radius));
    const img_offset_x = pad + @max(0, -options.offset_x);
    const img_offset_y = pad + @max(0, -options.offset_y);
    const shadow_offset_x = pad + @max(0, options.offset_x);
    const shadow_offset_y = pad + @max(0, options.offset_y);

    // Create shadow layer (alpha from source, color from options)
    var shadow = try Image.create(allocator, new_width, new_height, .rgba);
    defer shadow.deinit();

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));
            if (src.a > 0) {
                const sx = @as(u32, @intCast(shadow_offset_x)) + @as(u32, @intCast(x));
                const sy = @as(u32, @intCast(shadow_offset_y)) + @as(u32, @intCast(y));
                if (sx < new_width and sy < new_height) {
                    shadow.setPixel(sx, sy, Color{
                        .r = options.color.r,
                        .g = options.color.g,
                        .b = options.color.b,
                        .a = @intFromFloat(@as(f32, @floatFromInt(src.a)) * @as(f32, @floatFromInt(options.color.a)) / 255.0),
                    });
                }
            }
        }
    }

    // Blur the shadow
    if (options.blur_radius > 0) {
        try gaussianBlurInPlace(&shadow, options.blur_radius);
    }

    // Copy shadow to result
    for (0..new_height) |y| {
        for (0..new_width) |x| {
            result.setPixel(@intCast(x), @intCast(y), shadow.getPixel(@intCast(x), @intCast(y)));
        }
    }

    // Composite original image on top
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));
            if (src.a > 0) {
                const dx = @as(u32, @intCast(img_offset_x)) + @as(u32, @intCast(x));
                const dy = @as(u32, @intCast(img_offset_y)) + @as(u32, @intCast(y));
                if (dx < new_width and dy < new_height) {
                    const dst = result.getPixel(dx, dy);
                    result.setPixel(dx, dy, blendOver(src, dst));
                }
            }
        }
    }

    return result;
}

fn blendOver(src: Color, dst: Color) Color {
    const sa = @as(f32, @floatFromInt(src.a)) / 255.0;
    const da = @as(f32, @floatFromInt(dst.a)) / 255.0;
    const out_a = sa + da * (1 - sa);

    if (out_a < 0.001) return Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const sr = @as(f32, @floatFromInt(src.r));
    const sg = @as(f32, @floatFromInt(src.g));
    const sb = @as(f32, @floatFromInt(src.b));
    const dr = @as(f32, @floatFromInt(dst.r));
    const dg = @as(f32, @floatFromInt(dst.g));
    const db = @as(f32, @floatFromInt(dst.b));

    return Color{
        .r = @intFromFloat((sr * sa + dr * da * (1 - sa)) / out_a),
        .g = @intFromFloat((sg * sa + dg * da * (1 - sa)) / out_a),
        .b = @intFromFloat((sb * sa + db * da * (1 - sa)) / out_a),
        .a = @intFromFloat(out_a * 255),
    };
}

fn gaussianBlurInPlace(img: *Image, radius: u32) !void {
    if (radius == 0) return;

    const kernel_size = radius * 2 + 1;
    var kernel = try img.allocator.alloc(f32, kernel_size);
    defer img.allocator.free(kernel);

    // Generate Gaussian kernel
    const sigma = @as(f32, @floatFromInt(radius)) / 3.0;
    var sum: f32 = 0;
    for (0..kernel_size) |i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        kernel[i] = @exp(-(x * x) / (2 * sigma * sigma));
        sum += kernel[i];
    }
    for (0..kernel_size) |i| {
        kernel[i] /= sum;
    }

    // Horizontal pass
    var temp = try img.allocator.alloc(u8, img.width * img.height * 4);
    defer img.allocator.free(temp);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            var a: f32 = 0;

            for (0..kernel_size) |k| {
                const kx = @as(i32, @intCast(x)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const sx = @as(u32, @intCast(std.math.clamp(kx, 0, @as(i32, @intCast(img.width - 1)))));
                const src = img.getPixel(sx, @intCast(y));
                r += @as(f32, @floatFromInt(src.r)) * kernel[k];
                g += @as(f32, @floatFromInt(src.g)) * kernel[k];
                b += @as(f32, @floatFromInt(src.b)) * kernel[k];
                a += @as(f32, @floatFromInt(src.a)) * kernel[k];
            }

            const idx = (y * img.width + x) * 4;
            temp[idx] = @intFromFloat(std.math.clamp(r, 0, 255));
            temp[idx + 1] = @intFromFloat(std.math.clamp(g, 0, 255));
            temp[idx + 2] = @intFromFloat(std.math.clamp(b, 0, 255));
            temp[idx + 3] = @intFromFloat(std.math.clamp(a, 0, 255));
        }
    }

    // Vertical pass
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            var a: f32 = 0;

            for (0..kernel_size) |k| {
                const ky = @as(i32, @intCast(y)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const sy = @as(u32, @intCast(std.math.clamp(ky, 0, @as(i32, @intCast(img.height - 1)))));
                const idx = (sy * img.width + @as(u32, @intCast(x))) * 4;
                r += @as(f32, @floatFromInt(temp[idx])) * kernel[k];
                g += @as(f32, @floatFromInt(temp[idx + 1])) * kernel[k];
                b += @as(f32, @floatFromInt(temp[idx + 2])) * kernel[k];
                a += @as(f32, @floatFromInt(temp[idx + 3])) * kernel[k];
            }

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = @intFromFloat(std.math.clamp(a, 0, 255)),
            });
        }
    }
}

pub fn applyGlow(allocator: std.mem.Allocator, img: *Image, options: GlowOptions) !Image {
    var result = try Image.create(allocator, img.width, img.height, .rgba);

    // Create glow layer
    var glow = try Image.create(allocator, img.width, img.height, .rgba);
    defer glow.deinit();

    // Extract edges for glow
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));
            if (src.a > 128) {
                glow.setPixel(@intCast(x), @intCast(y), Color{
                    .r = options.color.r,
                    .g = options.color.g,
                    .b = options.color.b,
                    .a = @intFromFloat(@as(f32, @floatFromInt(src.a)) * options.intensity),
                });
            }
        }
    }

    // Blur the glow
    if (options.radius > 0) {
        try gaussianBlurInPlace(&glow, options.radius);
    }

    // Composite glow behind image
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const glow_px = glow.getPixel(@intCast(x), @intCast(y));
            const src_px = img.getPixel(@intCast(x), @intCast(y));
            result.setPixel(@intCast(x), @intCast(y), blendOver(src_px, glow_px));
        }
    }

    return result;
}

// ============================================================================
// Bevel / Emboss Effects
// ============================================================================

pub const BevelType = enum {
    inner,
    outer,
    emboss,
    pillow,
};

pub const BevelOptions = struct {
    bevel_type: BevelType = .inner,
    depth: f32 = 3.0,
    size: u32 = 5,
    soften: u32 = 0,
    angle: f32 = std.math.pi / 4.0, // 45 degrees, light from top-left
    altitude: f32 = std.math.pi / 4.0, // 45 degrees
    highlight_color: Color = Color{ .r = 255, .g = 255, .b = 255, .a = 192 },
    shadow_color: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 192 },
    use_texture: bool = false,
};

pub fn applyBevel(allocator: std.mem.Allocator, img: *Image, options: BevelOptions) !Image {
    var result = try img.clone(allocator);

    // Calculate light direction
    const light_x = @cos(options.angle) * @cos(options.altitude);
    const light_y = @sin(options.angle) * @cos(options.altitude);
    const light_z = @sin(options.altitude);

    const size = @max(1, options.size);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));
            if (src.a == 0) continue;

            // Calculate normal from alpha gradient
            var dx: f32 = 0;
            var dy: f32 = 0;

            if (x > 0 and x < img.width - 1) {
                const left = img.getPixel(@intCast(x - 1), @intCast(y));
                const right = img.getPixel(@intCast(x + 1), @intCast(y));
                dx = @as(f32, @floatFromInt(right.a)) - @as(f32, @floatFromInt(left.a));
            }
            if (y > 0 and y < img.height - 1) {
                const up = img.getPixel(@intCast(x), @intCast(y - 1));
                const down = img.getPixel(@intCast(x), @intCast(y + 1));
                dy = @as(f32, @floatFromInt(down.a)) - @as(f32, @floatFromInt(up.a));
            }

            // Normalize
            const len = @sqrt(dx * dx + dy * dy + 255.0 * 255.0);
            const nx = dx / len;
            const ny = dy / len;
            const nz = 255.0 / len;

            // Dot product with light
            var shade = nx * light_x + ny * light_y + nz * light_z;
            shade = std.math.clamp(shade * options.depth, -1, 1);

            // Apply highlight/shadow
            if (shade > 0) {
                const t = shade;
                const blend_a = @as(f32, @floatFromInt(options.highlight_color.a)) / 255.0 * t;
                result.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.r)), @as(f32, @floatFromInt(options.highlight_color.r)))),
                    .g = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.g)), @as(f32, @floatFromInt(options.highlight_color.g)))),
                    .b = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.b)), @as(f32, @floatFromInt(options.highlight_color.b)))),
                    .a = src.a,
                });
            } else {
                const t = -shade;
                const blend_a = @as(f32, @floatFromInt(options.shadow_color.a)) / 255.0 * t;
                result.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.r)), @as(f32, @floatFromInt(options.shadow_color.r)))),
                    .g = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.g)), @as(f32, @floatFromInt(options.shadow_color.g)))),
                    .b = @intFromFloat(lerp(blend_a, @as(f32, @floatFromInt(src.b)), @as(f32, @floatFromInt(options.shadow_color.b)))),
                    .a = src.a,
                });
            }
        }
    }

    // Apply softening if requested
    if (options.soften > 0) {
        try gaussianBlurInPlace(&result, options.soften);
    }

    _ = size;
    return result;
}

pub fn applyEmboss(allocator: std.mem.Allocator, img: *Image, angle: f32, depth: f32) !Image {
    var result = try Image.create(allocator, img.width, img.height, .rgba);

    const dx = @cos(angle);
    const dy = @sin(angle);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            // Sample in direction of light
            const x1 = @as(i32, @intCast(x)) - @as(i32, @intFromFloat(dx));
            const y1 = @as(i32, @intCast(y)) - @as(i32, @intFromFloat(dy));
            const x2 = @as(i32, @intCast(x)) + @as(i32, @intFromFloat(dx));
            const y2 = @as(i32, @intCast(y)) + @as(i32, @intFromFloat(dy));

            const p1 = if (x1 >= 0 and y1 >= 0 and x1 < img.width and y1 < img.height)
                img.getPixel(@intCast(x1), @intCast(y1))
            else
                Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

            const p2 = if (x2 >= 0 and y2 >= 0 and x2 < img.width and y2 < img.height)
                img.getPixel(@intCast(x2), @intCast(y2))
            else
                Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

            const src = img.getPixel(@intCast(x), @intCast(y));

            // Calculate emboss value
            const diff = (@as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r)) +
                @as(f32, @floatFromInt(p1.g)) - @as(f32, @floatFromInt(p2.g)) +
                @as(f32, @floatFromInt(p1.b)) - @as(f32, @floatFromInt(p2.b))) / 3.0;

            const emboss = 128 + diff * depth;
            const v = @as(u8, @intFromFloat(std.math.clamp(emboss, 0, 255)));

            result.setPixel(@intCast(x), @intCast(y), Color{
                .r = v,
                .g = v,
                .b = v,
                .a = src.a,
            });
        }
    }

    return result;
}

// ============================================================================
// Perspective Transform / 3D Rotation
// ============================================================================

pub const PerspectiveCorners = struct {
    top_left: [2]f32,
    top_right: [2]f32,
    bottom_left: [2]f32,
    bottom_right: [2]f32,
};

pub const Transform3D = struct {
    rotate_x: f32 = 0, // pitch
    rotate_y: f32 = 0, // yaw
    rotate_z: f32 = 0, // roll
    scale: f32 = 1.0,
    perspective: f32 = 0, // 0 = orthographic, higher = more perspective
    center_x: f32 = 0.5,
    center_y: f32 = 0.5,
};

pub fn applyPerspectiveTransform(allocator: std.mem.Allocator, img: *Image, corners: PerspectiveCorners) !Image {
    // Calculate bounding box of output
    const min_x = @min(@min(corners.top_left[0], corners.top_right[0]), @min(corners.bottom_left[0], corners.bottom_right[0]));
    const max_x = @max(@max(corners.top_left[0], corners.top_right[0]), @max(corners.bottom_left[0], corners.bottom_right[0]));
    const min_y = @min(@min(corners.top_left[1], corners.top_right[1]), @min(corners.bottom_left[1], corners.bottom_right[1]));
    const max_y = @max(@max(corners.top_left[1], corners.top_right[1]), @max(corners.bottom_left[1], corners.bottom_right[1]));

    const out_width = @as(u32, @intFromFloat(@ceil(max_x - min_x)));
    const out_height = @as(u32, @intFromFloat(@ceil(max_y - min_y)));

    var result = try Image.create(allocator, out_width, out_height, .rgba);

    // Calculate perspective transform matrix (simplified quadrilateral mapping)
    const src_corners = PerspectiveCorners{
        .top_left = .{ 0, 0 },
        .top_right = .{ @floatFromInt(img.width), 0 },
        .bottom_left = .{ 0, @floatFromInt(img.height) },
        .bottom_right = .{ @floatFromInt(img.width), @floatFromInt(img.height) },
    };

    _ = src_corners;

    // Offset corners to output space
    const tl = [2]f32{ corners.top_left[0] - min_x, corners.top_left[1] - min_y };
    const tr = [2]f32{ corners.top_right[0] - min_x, corners.top_right[1] - min_y };
    const bl = [2]f32{ corners.bottom_left[0] - min_x, corners.bottom_left[1] - min_y };
    const br = [2]f32{ corners.bottom_right[0] - min_x, corners.bottom_right[1] - min_y };

    // For each output pixel, find corresponding source pixel using bilinear interpolation
    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const fx = @as(f32, @floatFromInt(x));
            const fy = @as(f32, @floatFromInt(y));

            // Check if point is inside the quadrilateral and find UV coordinates
            const uv = pointInQuad(fx, fy, tl, tr, bl, br);
            if (uv) |coords| {
                const u = coords[0];
                const v = coords[1];

                // Sample source image with bilinear interpolation
                const sx = u * @as(f32, @floatFromInt(img.width - 1));
                const sy = v * @as(f32, @floatFromInt(img.height - 1));

                const color = bilinearSample(img, sx, sy);
                result.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }

    return result;
}

fn pointInQuad(x: f32, y: f32, tl: [2]f32, tr: [2]f32, bl: [2]f32, br: [2]f32) ?[2]f32 {
    // Use inverse bilinear interpolation to find UV coordinates
    // This is a simplified version; full implementation would use proper matrix inversion

    // Iterative solver for UV
    var u: f32 = 0.5;
    var v: f32 = 0.5;

    for (0..8) |_| {
        // Bilinear interpolation: P = (1-u)(1-v)TL + u(1-v)TR + (1-u)vBL + uvBR
        const px = (1 - u) * (1 - v) * tl[0] + u * (1 - v) * tr[0] + (1 - u) * v * bl[0] + u * v * br[0];
        const py = (1 - u) * (1 - v) * tl[1] + u * (1 - v) * tr[1] + (1 - u) * v * bl[1] + u * v * br[1];

        const dx = x - px;
        const dy = y - py;

        if (@abs(dx) < 0.01 and @abs(dy) < 0.01) break;

        // Compute Jacobian and update UV
        const dPx_du = -(1 - v) * tl[0] + (1 - v) * tr[0] - v * bl[0] + v * br[0];
        const dPx_dv = -(1 - u) * tl[0] - u * tr[0] + (1 - u) * bl[0] + u * br[0];
        const dPy_du = -(1 - v) * tl[1] + (1 - v) * tr[1] - v * bl[1] + v * br[1];
        const dPy_dv = -(1 - u) * tl[1] - u * tr[1] + (1 - u) * bl[1] + u * br[1];

        const det = dPx_du * dPy_dv - dPx_dv * dPy_du;
        if (@abs(det) < 0.0001) break;

        u += (dPy_dv * dx - dPx_dv * dy) / det;
        v += (-dPy_du * dx + dPx_du * dy) / det;
    }

    if (u >= 0 and u <= 1 and v >= 0 and v <= 1) {
        return .{ u, v };
    }
    return null;
}

fn bilinearSample(img: *Image, x: f32, y: f32) Color {
    const x0 = @as(u32, @intFromFloat(@floor(x)));
    const y0 = @as(u32, @intFromFloat(@floor(y)));
    const x1 = @min(x0 + 1, img.width - 1);
    const y1 = @min(y0 + 1, img.height - 1);

    const fx = x - @floor(x);
    const fy = y - @floor(y);

    const c00 = img.getPixel(x0, y0);
    const c10 = img.getPixel(x1, y0);
    const c01 = img.getPixel(x0, y1);
    const c11 = img.getPixel(x1, y1);

    const top = interpolateColor(c00, c10, fx);
    const bottom = interpolateColor(c01, c11, fx);
    return interpolateColor(top, bottom, fy);
}

pub fn apply3DRotation(allocator: std.mem.Allocator, img: *Image, transform: Transform3D) !Image {
    const w = @as(f32, @floatFromInt(img.width));
    const h = @as(f32, @floatFromInt(img.height));
    const cx = w * transform.center_x;
    const cy = h * transform.center_y;

    // Pre-calculate rotation matrices
    const cos_x = @cos(transform.rotate_x);
    const sin_x = @sin(transform.rotate_x);
    const cos_y = @cos(transform.rotate_y);
    const sin_y = @sin(transform.rotate_y);
    const cos_z = @cos(transform.rotate_z);
    const sin_z = @sin(transform.rotate_z);

    // Transform corners to find output bounds
    var corners: [4][3]f32 = undefined;
    corners[0] = transformPoint3D(0 - cx, 0 - cy, 0, cos_x, sin_x, cos_y, sin_y, cos_z, sin_z, transform.scale, transform.perspective);
    corners[1] = transformPoint3D(w - cx, 0 - cy, 0, cos_x, sin_x, cos_y, sin_y, cos_z, sin_z, transform.scale, transform.perspective);
    corners[2] = transformPoint3D(0 - cx, h - cy, 0, cos_x, sin_x, cos_y, sin_y, cos_z, sin_z, transform.scale, transform.perspective);
    corners[3] = transformPoint3D(w - cx, h - cy, 0, cos_x, sin_x, cos_y, sin_y, cos_z, sin_z, transform.scale, transform.perspective);

    var min_x: f32 = corners[0][0];
    var max_x: f32 = corners[0][0];
    var min_y: f32 = corners[0][1];
    var max_y: f32 = corners[0][1];

    for (corners[1..]) |c| {
        min_x = @min(min_x, c[0]);
        max_x = @max(max_x, c[0]);
        min_y = @min(min_y, c[1]);
        max_y = @max(max_y, c[1]);
    }

    const out_width = @as(u32, @intFromFloat(@ceil(max_x - min_x))) + 1;
    const out_height = @as(u32, @intFromFloat(@ceil(max_y - min_y))) + 1;
    const offset_x = -min_x;
    const offset_y = -min_y;

    var result = try Image.create(allocator, out_width, out_height, .rgba);

    // Use perspective corners for transform
    const persp_corners = PerspectiveCorners{
        .top_left = .{ corners[0][0] + offset_x, corners[0][1] + offset_y },
        .top_right = .{ corners[1][0] + offset_x, corners[1][1] + offset_y },
        .bottom_left = .{ corners[2][0] + offset_x, corners[2][1] + offset_y },
        .bottom_right = .{ corners[3][0] + offset_x, corners[3][1] + offset_y },
    };

    // Map each output pixel back to source
    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const fx = @as(f32, @floatFromInt(x));
            const fy = @as(f32, @floatFromInt(y));

            const uv = pointInQuad(fx, fy, persp_corners.top_left, persp_corners.top_right, persp_corners.bottom_left, persp_corners.bottom_right);
            if (uv) |coords| {
                const sx = coords[0] * @as(f32, @floatFromInt(img.width - 1));
                const sy = coords[1] * @as(f32, @floatFromInt(img.height - 1));
                result.setPixel(@intCast(x), @intCast(y), bilinearSample(img, sx, sy));
            }
        }
    }

    return result;
}

fn transformPoint3D(x: f32, y: f32, z: f32, cos_x: f32, sin_x: f32, cos_y: f32, sin_y: f32, cos_z: f32, sin_z: f32, scale: f32, perspective: f32) [3]f32 {
    // Apply rotations (X then Y then Z)
    var px = x;
    var py = y * cos_x - z * sin_x;
    var pz = y * sin_x + z * cos_x;

    const tx = px * cos_y + pz * sin_y;
    pz = -px * sin_y + pz * cos_y;
    px = tx;

    const ty = px;
    px = px * cos_z - py * sin_z;
    py = ty * sin_z + py * cos_z;

    // Apply scale
    px *= scale;
    py *= scale;

    // Apply perspective
    if (perspective > 0) {
        const w = 1.0 + pz * perspective;
        px /= w;
        py /= w;
    }

    return .{ px, py, pz };
}

// ============================================================================
// Color Overlay / Tint
// ============================================================================

pub fn applyColorOverlay(img: *Image, color: Color, opacity: f32) void {
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));
            if (src.a == 0) continue;

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(lerp(opacity, @as(f32, @floatFromInt(src.r)), @as(f32, @floatFromInt(color.r)))),
                .g = @intFromFloat(lerp(opacity, @as(f32, @floatFromInt(src.g)), @as(f32, @floatFromInt(color.g)))),
                .b = @intFromFloat(lerp(opacity, @as(f32, @floatFromInt(src.b)), @as(f32, @floatFromInt(color.b)))),
                .a = src.a,
            });
        }
    }
}

pub fn applyTint(img: *Image, color: Color) void {
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const src = img.getPixel(@intCast(x), @intCast(y));

            // Multiply blend
            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(@as(f32, @floatFromInt(src.r)) * @as(f32, @floatFromInt(color.r)) / 255.0),
                .g = @intFromFloat(@as(f32, @floatFromInt(src.g)) * @as(f32, @floatFromInt(color.g)) / 255.0),
                .b = @intFromFloat(@as(f32, @floatFromInt(src.b)) * @as(f32, @floatFromInt(color.b)) / 255.0),
                .a = src.a,
            });
        }
    }
}

// ============================================================================
// Stroke / Outline
// ============================================================================

pub const StrokePosition = enum {
    outside,
    inside,
    center,
};

pub const StrokeOptions = struct {
    width: u32 = 2,
    color: Color = Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    position: StrokePosition = .outside,
};

pub fn applyStroke(allocator: std.mem.Allocator, img: *Image, options: StrokeOptions) !Image {
    const padding = switch (options.position) {
        .outside => options.width,
        .center => options.width / 2,
        .inside => 0,
    };

    const new_width = img.width + padding * 2;
    const new_height = img.height + padding * 2;

    var result = try Image.create(allocator, new_width, new_height, .rgba);

    // Create dilated alpha mask for stroke
    for (0..new_height) |y| {
        for (0..new_width) |x| {
            const ix = @as(i32, @intCast(x)) - @as(i32, @intCast(padding));
            const iy = @as(i32, @intCast(y)) - @as(i32, @intCast(padding));

            // Check if any pixel within stroke width has alpha
            var max_alpha: u8 = 0;
            var dy: i32 = -@as(i32, @intCast(options.width));
            while (dy <= @as(i32, @intCast(options.width))) : (dy += 1) {
                var dx: i32 = -@as(i32, @intCast(options.width));
                while (dx <= @as(i32, @intCast(options.width))) : (dx += 1) {
                    const dist_sq = dx * dx + dy * dy;
                    if (dist_sq <= @as(i32, @intCast(options.width * options.width))) {
                        const sx = ix + dx;
                        const sy = iy + dy;
                        if (sx >= 0 and sy >= 0 and sx < img.width and sy < img.height) {
                            const src = img.getPixel(@intCast(sx), @intCast(sy));
                            max_alpha = @max(max_alpha, src.a);
                        }
                    }
                }
            }

            // Get original pixel
            var final_color = options.color;
            final_color.a = max_alpha;

            if (ix >= 0 and iy >= 0 and ix < img.width and iy < img.height) {
                const src = img.getPixel(@intCast(ix), @intCast(iy));
                if (src.a > 0) {
                    // Composite original over stroke
                    final_color = blendOver(src, final_color);
                }
            }

            result.setPixel(@intCast(x), @intCast(y), final_color);
        }
    }

    return result;
}
