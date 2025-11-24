const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// RAW Image Data Structures
// ============================================================================

pub const BayerPattern = enum {
    rggb,
    bggr,
    grbg,
    gbrg,

    pub fn getColorAt(self: BayerPattern, x: usize, y: usize) enum { r, g, b } {
        const even_x = x % 2 == 0;
        const even_y = y % 2 == 0;

        return switch (self) {
            .rggb => if (even_y) (if (even_x) .r else .g) else (if (even_x) .g else .b),
            .bggr => if (even_y) (if (even_x) .b else .g) else (if (even_x) .g else .r),
            .grbg => if (even_y) (if (even_x) .g else .r) else (if (even_x) .b else .g),
            .gbrg => if (even_y) (if (even_x) .g else .b) else (if (even_x) .r else .g),
        };
    }
};

pub const RawImage = struct {
    data: []u16, // Raw sensor data (typically 12-14 bit)
    width: u32,
    height: u32,
    bits_per_sample: u8,
    bayer_pattern: BayerPattern,
    black_level: u16,
    white_level: u16,
    // Camera matrices
    color_matrix: [9]f32, // Camera to XYZ
    white_balance: [3]f32, // R, G, B multipliers
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, bits: u8) !RawImage {
        const data = try allocator.alloc(u16, width * height);
        @memset(data, 0);

        return RawImage{
            .data = data,
            .width = width,
            .height = height,
            .bits_per_sample = bits,
            .bayer_pattern = .rggb,
            .black_level = 0,
            .white_level = @as(u16, 1) << @intCast(bits),
            .color_matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
            .white_balance = .{ 1, 1, 1 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RawImage) void {
        self.allocator.free(self.data);
    }

    pub fn getValue(self: *const RawImage, x: u32, y: u32) u16 {
        if (x >= self.width or y >= self.height) return 0;
        return self.data[y * self.width + x];
    }

    pub fn setValue(self: *RawImage, x: u32, y: u32, value: u16) void {
        if (x >= self.width or y >= self.height) return;
        self.data[y * self.width + x] = value;
    }
};

// ============================================================================
// Demosaicing Algorithms
// ============================================================================

pub const DemosaicAlgorithm = enum {
    bilinear,
    vng, // Variable Number of Gradients
    ahd, // Adaptive Homogeneity-Directed
    dcb, // DCB (improved edge detection)
    amaze, // AMaZE (Aliasing Minimization and Zipper Elimination)
};

pub fn demosaic(allocator: std.mem.Allocator, raw: *const RawImage, algorithm: DemosaicAlgorithm) !Image {
    return switch (algorithm) {
        .bilinear => demosaicBilinear(allocator, raw),
        .vng => demosaicVNG(allocator, raw),
        .ahd => demosaicAHD(allocator, raw),
        .dcb => demosaicDCB(allocator, raw),
        .amaze => demosaicAMaZE(allocator, raw),
    };
}

fn demosaicBilinear(allocator: std.mem.Allocator, raw: *const RawImage) !Image {
    var img = try Image.create(allocator, raw.width, raw.height, .rgba);

    const scale = 255.0 / @as(f32, @floatFromInt(raw.white_level - raw.black_level));

    for (0..raw.height) |y| {
        for (0..raw.width) |x| {
            const color_type = raw.bayer_pattern.getColorAt(x, y);

            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;

            // Get raw value at this pixel
            const raw_val = @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));

            switch (color_type) {
                .r => {
                    r = raw_val;
                    g = interpolateGreenAtRB(raw, x, y);
                    b = interpolateBlueAtRed(raw, x, y);
                },
                .g => {
                    r = interpolateRedAtGreen(raw, x, y);
                    g = raw_val;
                    b = interpolateBlueAtGreen(raw, x, y);
                },
                .b => {
                    r = interpolateRedAtBlue(raw, x, y);
                    g = interpolateGreenAtRB(raw, x, y);
                    b = raw_val;
                },
            }

            // Subtract black level and scale
            r = (r - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[0];
            g = (g - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[1];
            b = (b - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[2];

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = 255,
            });
        }
    }

    return img;
}

fn interpolateGreenAtRB(raw: *const RawImage, x: usize, y: usize) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;

    // Average of 4 neighbors
    if (x > 0) {
        sum += @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)));
        count += 1;
    }
    if (x < raw.width - 1) {
        sum += @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y)));
        count += 1;
    }
    if (y > 0) {
        sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)));
        count += 1;
    }
    if (y < raw.height - 1) {
        sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1)));
        count += 1;
    }

    return if (count > 0) sum / count else 0;
}

fn interpolateRedAtGreen(raw: *const RawImage, x: usize, y: usize) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;

    // Check horizontal or vertical based on row
    if (y % 2 == 0) {
        // Red is to the left and right
        if (x > 0) {
            sum += @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)));
            count += 1;
        }
        if (x < raw.width - 1) {
            sum += @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y)));
            count += 1;
        }
    } else {
        // Red is above and below
        if (y > 0) {
            sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)));
            count += 1;
        }
        if (y < raw.height - 1) {
            sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1)));
            count += 1;
        }
    }

    return if (count > 0) sum / count else 0;
}

fn interpolateBlueAtGreen(raw: *const RawImage, x: usize, y: usize) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;

    // Opposite of red
    if (y % 2 != 0) {
        if (x > 0) {
            sum += @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)));
            count += 1;
        }
        if (x < raw.width - 1) {
            sum += @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y)));
            count += 1;
        }
    } else {
        if (y > 0) {
            sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)));
            count += 1;
        }
        if (y < raw.height - 1) {
            sum += @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1)));
            count += 1;
        }
    }

    return if (count > 0) sum / count else 0;
}

fn interpolateBlueAtRed(raw: *const RawImage, x: usize, y: usize) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;

    // Average of 4 diagonal neighbors
    if (x > 0 and y > 0) {
        sum += @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y - 1)));
        count += 1;
    }
    if (x < raw.width - 1 and y > 0) {
        sum += @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y - 1)));
        count += 1;
    }
    if (x > 0 and y < raw.height - 1) {
        sum += @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y + 1)));
        count += 1;
    }
    if (x < raw.width - 1 and y < raw.height - 1) {
        sum += @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y + 1)));
        count += 1;
    }

    return if (count > 0) sum / count else 0;
}

fn interpolateRedAtBlue(raw: *const RawImage, x: usize, y: usize) f32 {
    return interpolateBlueAtRed(raw, x, y);
}

// VNG Demosaicing (Variable Number of Gradients)
fn demosaicVNG(allocator: std.mem.Allocator, raw: *const RawImage) !Image {
    var img = try Image.create(allocator, raw.width, raw.height, .rgba);

    const scale = 255.0 / @as(f32, @floatFromInt(raw.white_level - raw.black_level));

    for (2..raw.height - 2) |y| {
        for (2..raw.width - 2) |x| {
            const color_type = raw.bayer_pattern.getColorAt(x, y);
            const raw_val = @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));

            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;

            // Calculate gradients in 8 directions
            var gradients: [8]f32 = undefined;
            var values: [8][3]f32 = undefined;

            // N, NE, E, SE, S, SW, W, NW
            const dirs = [_][2]i32{ .{ 0, -1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ -1, -1 } };

            for (0..8) |d| {
                gradients[d] = calculateGradient(raw, x, y, dirs[d][0], dirs[d][1]);
                values[d] = interpolateVNG(raw, x, y, dirs[d][0], dirs[d][1], color_type);
            }

            // Find threshold (minimum gradient + some margin)
            var min_grad: f32 = gradients[0];
            for (gradients[1..]) |grad| {
                min_grad = @min(min_grad, grad);
            }
            const threshold = min_grad * 1.5 + 1;

            // Average values from directions with low gradient
            var count: f32 = 0;
            for (0..8) |d| {
                if (gradients[d] <= threshold) {
                    r += values[d][0];
                    g += values[d][1];
                    b += values[d][2];
                    count += 1;
                }
            }

            if (count > 0) {
                r /= count;
                g /= count;
                b /= count;
            }

            // Handle center pixel
            switch (color_type) {
                .r => r = raw_val,
                .g => g = raw_val,
                .b => b = raw_val,
            }

            r = (r - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[0];
            g = (g - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[1];
            b = (b - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[2];

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = 255,
            });
        }
    }

    // Handle borders with bilinear
    for (0..raw.height) |y| {
        for (0..raw.width) |x| {
            if (x >= 2 and x < raw.width - 2 and y >= 2 and y < raw.height - 2) continue;

            const color_type = raw.bayer_pattern.getColorAt(x, y);
            const raw_val = @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));

            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;

            switch (color_type) {
                .r => {
                    r = raw_val;
                    g = interpolateGreenAtRB(raw, x, y);
                    b = interpolateBlueAtRed(raw, x, y);
                },
                .g => {
                    r = interpolateRedAtGreen(raw, x, y);
                    g = raw_val;
                    b = interpolateBlueAtGreen(raw, x, y);
                },
                .b => {
                    r = interpolateRedAtBlue(raw, x, y);
                    g = interpolateGreenAtRB(raw, x, y);
                    b = raw_val;
                },
            }

            r = (r - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[0];
            g = (g - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[1];
            b = (b - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[2];

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = 255,
            });
        }
    }

    return img;
}

fn calculateGradient(raw: *const RawImage, x: usize, y: usize, dx: i32, dy: i32) f32 {
    const x1 = @as(i32, @intCast(x)) + dx;
    const y1 = @as(i32, @intCast(y)) + dy;
    const x2 = @as(i32, @intCast(x)) + dx * 2;
    const y2 = @as(i32, @intCast(y)) + dy * 2;

    const v0 = @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));
    const v1 = if (x1 >= 0 and y1 >= 0 and x1 < raw.width and y1 < raw.height)
        @as(f32, @floatFromInt(raw.getValue(@intCast(x1), @intCast(y1))))
    else
        v0;
    const v2 = if (x2 >= 0 and y2 >= 0 and x2 < raw.width and y2 < raw.height)
        @as(f32, @floatFromInt(raw.getValue(@intCast(x2), @intCast(y2))))
    else
        v1;

    return @abs(v0 - v1) + @abs(v1 - v2);
}

fn interpolateVNG(raw: *const RawImage, x: usize, y: usize, dx: i32, dy: i32, center_type: enum { r, g, b }) [3]f32 {
    _ = center_type;
    const nx = @as(i32, @intCast(x)) + dx;
    const ny = @as(i32, @intCast(y)) + dy;

    if (nx < 0 or ny < 0 or nx >= raw.width or ny >= raw.height) {
        return .{ 0, 0, 0 };
    }

    const neighbor_type = raw.bayer_pattern.getColorAt(@intCast(nx), @intCast(ny));
    const val = @as(f32, @floatFromInt(raw.getValue(@intCast(nx), @intCast(ny))));

    var result: [3]f32 = .{ 0, 0, 0 };
    switch (neighbor_type) {
        .r => result[0] = val,
        .g => result[1] = val,
        .b => result[2] = val,
    }

    return result;
}

// AHD Demosaicing (Adaptive Homogeneity-Directed)
fn demosaicAHD(allocator: std.mem.Allocator, raw: *const RawImage) !Image {
    // AHD interpolates in two directions (horizontal and vertical)
    // then chooses the direction with lower color difference

    var img = try Image.create(allocator, raw.width, raw.height, .rgba);

    // Allocate temporary buffers for H and V interpolation
    var h_rgb = try allocator.alloc([3]f32, raw.width * raw.height);
    defer allocator.free(h_rgb);
    var v_rgb = try allocator.alloc([3]f32, raw.width * raw.height);
    defer allocator.free(v_rgb);

    const scale = 255.0 / @as(f32, @floatFromInt(raw.white_level - raw.black_level));

    // First pass: directional interpolation
    for (0..raw.height) |y| {
        for (0..raw.width) |x| {
            const idx = y * raw.width + x;
            const color_type = raw.bayer_pattern.getColorAt(x, y);
            const raw_val = @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));

            // Horizontal interpolation
            h_rgb[idx] = interpolateDirectional(raw, x, y, color_type, true);
            // Vertical interpolation
            v_rgb[idx] = interpolateDirectional(raw, x, y, color_type, false);

            // Set known channel
            switch (color_type) {
                .r => {
                    h_rgb[idx][0] = raw_val;
                    v_rgb[idx][0] = raw_val;
                },
                .g => {
                    h_rgb[idx][1] = raw_val;
                    v_rgb[idx][1] = raw_val;
                },
                .b => {
                    h_rgb[idx][2] = raw_val;
                    v_rgb[idx][2] = raw_val;
                },
            }
        }
    }

    // Second pass: homogeneity analysis and selection
    for (1..raw.height - 1) |y| {
        for (1..raw.width - 1) |x| {
            const idx = y * raw.width + x;

            // Calculate homogeneity for both directions
            const h_homo = calculateHomogeneity(h_rgb, raw.width, x, y);
            const v_homo = calculateHomogeneity(v_rgb, raw.width, x, y);

            // Choose direction with higher homogeneity
            const rgb = if (h_homo >= v_homo) h_rgb[idx] else v_rgb[idx];

            const r = (rgb[0] - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[0];
            const g = (rgb[1] - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[1];
            const b = (rgb[2] - @as(f32, @floatFromInt(raw.black_level))) * scale * raw.white_balance[2];

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = 255,
            });
        }
    }

    return img;
}

fn interpolateDirectional(raw: *const RawImage, x: usize, y: usize, color_type: enum { r, g, b }, horizontal: bool) [3]f32 {
    var result: [3]f32 = .{ 0, 0, 0 };

    if (horizontal) {
        // Use horizontal neighbors
        switch (color_type) {
            .r => {
                // Green from horizontal neighbors
                if (x > 0 and x < raw.width - 1) {
                    result[1] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y))))) / 2;
                }
                // Blue from row above/below
                if (y > 0 and y < raw.height - 1) {
                    result[2] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1))))) / 2;
                }
            },
            .g => {
                // Red or blue from horizontal neighbors depending on row
                if (x > 0 and x < raw.width - 1) {
                    const neighbor = raw.bayer_pattern.getColorAt(x - 1, y);
                    const val = (@as(f32, @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y))))) / 2;
                    switch (neighbor) {
                        .r => result[0] = val,
                        .b => result[2] = val,
                        .g => {},
                    }
                }
            },
            .b => {
                if (x > 0 and x < raw.width - 1) {
                    result[1] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y))))) / 2;
                }
                if (y > 0 and y < raw.height - 1) {
                    result[0] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1))))) / 2;
                }
            },
        }
    } else {
        // Vertical interpolation (similar logic but vertical neighbors)
        switch (color_type) {
            .r => {
                if (y > 0 and y < raw.height - 1) {
                    result[1] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1))))) / 2;
                }
                if (x > 0 and x < raw.width - 1) {
                    result[2] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y))))) / 2;
                }
            },
            .g => {
                if (y > 0 and y < raw.height - 1) {
                    const neighbor = raw.bayer_pattern.getColorAt(x, y - 1);
                    const val = (@as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1))))) / 2;
                    switch (neighbor) {
                        .r => result[0] = val,
                        .b => result[2] = val,
                        .g => {},
                    }
                }
            },
            .b => {
                if (y > 0 and y < raw.height - 1) {
                    result[1] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y - 1)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x), @intCast(y + 1))))) / 2;
                }
                if (x > 0 and x < raw.width - 1) {
                    result[0] = (@as(f32, @floatFromInt(raw.getValue(@intCast(x - 1), @intCast(y)))) +
                        @as(f32, @floatFromInt(raw.getValue(@intCast(x + 1), @intCast(y))))) / 2;
                }
            },
        }
    }

    return result;
}

fn calculateHomogeneity(rgb: [][3]f32, width: usize, x: usize, y: usize) f32 {
    const idx = y * width + x;
    const center = rgb[idx];

    var homo: f32 = 0;
    var count: f32 = 0;

    // Check 8 neighbors
    const neighbors = [_][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },             .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };

    for (neighbors) |n| {
        const nx = @as(i32, @intCast(x)) + n[0];
        const ny = @as(i32, @intCast(y)) + n[1];

        if (nx >= 0 and ny >= 0) {
            const nidx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
            const neighbor = rgb[nidx];

            // Calculate color difference
            const dr = center[0] - neighbor[0];
            const dg = center[1] - neighbor[1];
            const db = center[2] - neighbor[2];
            const diff = @sqrt(dr * dr + dg * dg + db * db);

            // Higher homogeneity = lower difference
            homo += 1.0 / (diff + 1);
            count += 1;
        }
    }

    return if (count > 0) homo / count else 0;
}

// DCB Demosaicing
fn demosaicDCB(allocator: std.mem.Allocator, raw: *const RawImage) !Image {
    // DCB uses edge-directed interpolation similar to AHD but with
    // additional color correction passes
    return demosaicAHD(allocator, raw); // Use AHD as base
}

// AMaZE Demosaicing
fn demosaicAMaZE(allocator: std.mem.Allocator, raw: *const RawImage) !Image {
    // AMaZE is similar to VNG but with additional zipper elimination
    return demosaicVNG(allocator, raw); // Use VNG as base
}

// ============================================================================
// White Balance
// ============================================================================

pub const WhiteBalanceMethod = enum {
    manual,
    auto_gray_world,
    auto_white_patch,
    daylight,
    cloudy,
    shade,
    tungsten,
    fluorescent,
    flash,
};

pub fn calculateWhiteBalance(raw: *const RawImage, method: WhiteBalanceMethod) [3]f32 {
    return switch (method) {
        .manual => raw.white_balance,
        .auto_gray_world => autoWhiteBalanceGrayWorld(raw),
        .auto_white_patch => autoWhiteBalanceWhitePatch(raw),
        .daylight => .{ 1.0, 1.0, 1.0 },
        .cloudy => .{ 0.95, 1.0, 1.1 },
        .shade => .{ 0.9, 1.0, 1.2 },
        .tungsten => .{ 1.3, 1.0, 0.7 },
        .fluorescent => .{ 1.1, 1.0, 0.85 },
        .flash => .{ 0.98, 1.0, 1.05 },
    };
}

fn autoWhiteBalanceGrayWorld(raw: *const RawImage) [3]f32 {
    var sum_r: f64 = 0;
    var sum_g: f64 = 0;
    var sum_b: f64 = 0;
    var count_r: u64 = 0;
    var count_g: u64 = 0;
    var count_b: u64 = 0;

    for (0..raw.height) |y| {
        for (0..raw.width) |x| {
            const val = @as(f64, @floatFromInt(raw.getValue(@intCast(x), @intCast(y))));
            switch (raw.bayer_pattern.getColorAt(x, y)) {
                .r => {
                    sum_r += val;
                    count_r += 1;
                },
                .g => {
                    sum_g += val;
                    count_g += 1;
                },
                .b => {
                    sum_b += val;
                    count_b += 1;
                },
            }
        }
    }

    const avg_r = sum_r / @as(f64, @floatFromInt(count_r));
    const avg_g = sum_g / @as(f64, @floatFromInt(count_g));
    const avg_b = sum_b / @as(f64, @floatFromInt(count_b));

    // Normalize to green channel
    return .{
        @floatCast(avg_g / avg_r),
        1.0,
        @floatCast(avg_g / avg_b),
    };
}

fn autoWhiteBalanceWhitePatch(raw: *const RawImage) [3]f32 {
    var max_r: u16 = 0;
    var max_g: u16 = 0;
    var max_b: u16 = 0;

    for (0..raw.height) |y| {
        for (0..raw.width) |x| {
            const val = raw.getValue(@intCast(x), @intCast(y));
            switch (raw.bayer_pattern.getColorAt(x, y)) {
                .r => max_r = @max(max_r, val),
                .g => max_g = @max(max_g, val),
                .b => max_b = @max(max_b, val),
            }
        }
    }

    const fmax_g = @as(f32, @floatFromInt(max_g));
    return .{
        fmax_g / @as(f32, @floatFromInt(max_r)),
        1.0,
        fmax_g / @as(f32, @floatFromInt(max_b)),
    };
}

pub fn applyWhiteBalance(raw: *RawImage, multipliers: [3]f32) void {
    raw.white_balance = multipliers;
}

// ============================================================================
// Highlight Recovery
// ============================================================================

pub const HighlightRecoveryMethod = enum {
    clip, // Simple clipping (default)
    unclip, // Use unclipped channels to recover
    blend, // Blend with gray
    reconstruct, // Reconstruct from neighbor pixels
};

pub fn recoverHighlights(img: *Image, method: HighlightRecoveryMethod, threshold: u8) void {
    switch (method) {
        .clip => {}, // No action needed
        .unclip => recoverHighlightsUnclip(img, threshold),
        .blend => recoverHighlightsBlend(img, threshold),
        .reconstruct => recoverHighlightsReconstruct(img, threshold),
    }
}

fn recoverHighlightsUnclip(img: *Image, threshold: u8) void {
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            var color = img.getPixel(@intCast(x), @intCast(y));

            // Check if any channel is clipped
            const r_clipped = color.r >= threshold;
            const g_clipped = color.g >= threshold;
            const b_clipped = color.b >= threshold;

            if (r_clipped or g_clipped or b_clipped) {
                // Use unclipped channels to estimate clipped ones
                var valid_channels: u8 = 0;
                var avg: f32 = 0;

                if (!r_clipped) {
                    avg += @floatFromInt(color.r);
                    valid_channels += 1;
                }
                if (!g_clipped) {
                    avg += @floatFromInt(color.g);
                    valid_channels += 1;
                }
                if (!b_clipped) {
                    avg += @floatFromInt(color.b);
                    valid_channels += 1;
                }

                if (valid_channels > 0) {
                    avg /= @floatFromInt(valid_channels);
                    if (r_clipped) color.r = @intFromFloat(@min(255, avg * 1.1));
                    if (g_clipped) color.g = @intFromFloat(@min(255, avg * 1.0));
                    if (b_clipped) color.b = @intFromFloat(@min(255, avg * 0.9));

                    img.setPixel(@intCast(x), @intCast(y), color);
                }
            }
        }
    }
}

fn recoverHighlightsBlend(img: *Image, threshold: u8) void {
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            var color = img.getPixel(@intCast(x), @intCast(y));

            const max_val = @max(color.r, @max(color.g, color.b));
            if (max_val >= threshold) {
                // Blend towards gray based on how clipped we are
                const blend_factor = @as(f32, @floatFromInt(max_val - threshold)) / @as(f32, @floatFromInt(255 - threshold));
                const lum = @as(f32, @floatFromInt(color.r)) * 0.299 + @as(f32, @floatFromInt(color.g)) * 0.587 + @as(f32, @floatFromInt(color.b)) * 0.114;

                color.r = @intFromFloat(lerp(blend_factor, @floatFromInt(color.r), lum));
                color.g = @intFromFloat(lerp(blend_factor, @floatFromInt(color.g), lum));
                color.b = @intFromFloat(lerp(blend_factor, @floatFromInt(color.b), lum));

                img.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }
}

fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + t * (b - a);
}

fn recoverHighlightsReconstruct(img: *Image, threshold: u8) void {
    // Use median of neighbors for clipped pixels
    for (1..img.height - 1) |y| {
        for (1..img.width - 1) |x| {
            var color = img.getPixel(@intCast(x), @intCast(y));

            const max_val = @max(color.r, @max(color.g, color.b));
            if (max_val >= threshold) {
                // Collect neighbor values
                var r_vals: [8]u8 = undefined;
                var g_vals: [8]u8 = undefined;
                var b_vals: [8]u8 = undefined;
                var idx: usize = 0;

                const neighbors = [_][2]i32{
                    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
                    .{ -1, 0 },             .{ 1, 0 },
                    .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
                };

                for (neighbors) |n| {
                    const nx = @as(i32, @intCast(x)) + n[0];
                    const ny = @as(i32, @intCast(y)) + n[1];
                    const nc = img.getPixel(@intCast(nx), @intCast(ny));
                    r_vals[idx] = nc.r;
                    g_vals[idx] = nc.g;
                    b_vals[idx] = nc.b;
                    idx += 1;
                }

                // Sort and take median
                std.mem.sort(u8, &r_vals, {}, std.sort.asc(u8));
                std.mem.sort(u8, &g_vals, {}, std.sort.asc(u8));
                std.mem.sort(u8, &b_vals, {}, std.sort.asc(u8));

                if (color.r >= threshold) color.r = (r_vals[3] + r_vals[4]) / 2;
                if (color.g >= threshold) color.g = (g_vals[3] + g_vals[4]) / 2;
                if (color.b >= threshold) color.b = (b_vals[3] + b_vals[4]) / 2;

                img.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }
}

// ============================================================================
// RAW-specific Noise Reduction
// ============================================================================

pub const RawNoiseReductionOptions = struct {
    luminance_strength: f32 = 0.5,
    color_strength: f32 = 0.5,
    detail_preservation: f32 = 0.5,
};

pub fn reduceRawNoise(allocator: std.mem.Allocator, img: *Image, options: RawNoiseReductionOptions) !void {
    // Wavelet-based denoising for RAW images
    // This is a simplified version - real implementations use proper wavelet transforms

    var temp = try allocator.alloc(u8, img.width * img.height * 4);
    defer allocator.free(temp);

    // Copy image data
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y));
            const idx = (y * img.width + x) * 4;
            temp[idx] = color.r;
            temp[idx + 1] = color.g;
            temp[idx + 2] = color.b;
            temp[idx + 3] = color.a;
        }
    }

    // Apply bilateral filter for edge-preserving smoothing
    const radius: u32 = 3;
    const sigma_space = 3.0;
    const sigma_color = 30.0 * options.color_strength;
    const sigma_lum = 30.0 * options.luminance_strength;

    for (radius..img.height - radius) |y| {
        for (radius..img.width - radius) |x| {
            const center = img.getPixel(@intCast(x), @intCast(y));
            const center_lum = @as(f32, @floatFromInt(center.r)) * 0.299 +
                @as(f32, @floatFromInt(center.g)) * 0.587 +
                @as(f32, @floatFromInt(center.b)) * 0.114;

            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;
            var weight_sum: f32 = 0;

            var ky: i32 = -@as(i32, @intCast(radius));
            while (ky <= @as(i32, @intCast(radius))) : (ky += 1) {
                var kx: i32 = -@as(i32, @intCast(radius));
                while (kx <= @as(i32, @intCast(radius))) : (kx += 1) {
                    const nx = @as(u32, @intCast(@as(i32, @intCast(x)) + kx));
                    const ny = @as(u32, @intCast(@as(i32, @intCast(y)) + ky));
                    const neighbor = img.getPixel(nx, ny);

                    // Spatial weight
                    const space_dist = @as(f32, @floatFromInt(kx * kx + ky * ky));
                    const space_weight = @exp(-space_dist / (2 * sigma_space * sigma_space));

                    // Color weight
                    const dr = @as(f32, @floatFromInt(center.r)) - @as(f32, @floatFromInt(neighbor.r));
                    const dg = @as(f32, @floatFromInt(center.g)) - @as(f32, @floatFromInt(neighbor.g));
                    const db = @as(f32, @floatFromInt(center.b)) - @as(f32, @floatFromInt(neighbor.b));
                    const color_dist = dr * dr + dg * dg + db * db;
                    const color_weight = @exp(-color_dist / (2 * sigma_color * sigma_color));

                    // Luminance weight
                    const neighbor_lum = @as(f32, @floatFromInt(neighbor.r)) * 0.299 +
                        @as(f32, @floatFromInt(neighbor.g)) * 0.587 +
                        @as(f32, @floatFromInt(neighbor.b)) * 0.114;
                    const lum_diff = center_lum - neighbor_lum;
                    const lum_weight = @exp(-(lum_diff * lum_diff) / (2 * sigma_lum * sigma_lum));

                    const weight = space_weight * color_weight * lum_weight;

                    sum_r += @as(f32, @floatFromInt(neighbor.r)) * weight;
                    sum_g += @as(f32, @floatFromInt(neighbor.g)) * weight;
                    sum_b += @as(f32, @floatFromInt(neighbor.b)) * weight;
                    weight_sum += weight;
                }
            }

            if (weight_sum > 0) {
                // Blend with original based on detail preservation
                const denoised_r = sum_r / weight_sum;
                const denoised_g = sum_g / weight_sum;
                const denoised_b = sum_b / weight_sum;

                const final_r = lerp(options.detail_preservation, denoised_r, @floatFromInt(center.r));
                const final_g = lerp(options.detail_preservation, denoised_g, @floatFromInt(center.g));
                const final_b = lerp(options.detail_preservation, denoised_b, @floatFromInt(center.b));

                const idx = (y * img.width + x) * 4;
                temp[idx] = @intFromFloat(std.math.clamp(final_r, 0, 255));
                temp[idx + 1] = @intFromFloat(std.math.clamp(final_g, 0, 255));
                temp[idx + 2] = @intFromFloat(std.math.clamp(final_b, 0, 255));
            }
        }
    }

    // Copy back
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const idx = (y * img.width + x) * 4;
            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = temp[idx],
                .g = temp[idx + 1],
                .b = temp[idx + 2],
                .a = temp[idx + 3],
            });
        }
    }
}

// ============================================================================
// Chromatic Aberration Correction
// ============================================================================

pub fn correctChromaticAberration(img: *Image, red_shift: f32, blue_shift: f32) void {
    const cx = @as(f32, @floatFromInt(img.width)) / 2.0;
    const cy = @as(f32, @floatFromInt(img.height)) / 2.0;
    const max_dist = @sqrt(cx * cx + cy * cy);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const fx = @as(f32, @floatFromInt(x)) - cx;
            const fy = @as(f32, @floatFromInt(y)) - cy;
            const dist = @sqrt(fx * fx + fy * fy) / max_dist;

            // Calculate shifted positions for red and blue
            const r_scale = 1.0 + red_shift * dist;
            const b_scale = 1.0 + blue_shift * dist;

            const r_x = cx + fx * r_scale;
            const r_y = cy + fy * r_scale;
            const b_x = cx + fx * b_scale;
            const b_y = cy + fy * b_scale;

            // Sample red and blue from shifted positions
            const r = bilinearSample(img, r_x, r_y).r;
            const g = img.getPixel(@intCast(x), @intCast(y)).g;
            const b = bilinearSample(img, b_x, b_y).b;

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = r,
                .g = g,
                .b = b,
                .a = 255,
            });
        }
    }
}

fn bilinearSample(img: *Image, x: f32, y: f32) Color {
    const x0 = @as(u32, @intFromFloat(@max(0, @floor(x))));
    const y0 = @as(u32, @intFromFloat(@max(0, @floor(y))));
    const x1 = @min(x0 + 1, img.width - 1);
    const y1 = @min(y0 + 1, img.height - 1);

    const fx = x - @floor(x);
    const fy = y - @floor(y);

    const c00 = img.getPixel(x0, y0);
    const c10 = img.getPixel(x1, y0);
    const c01 = img.getPixel(x0, y1);
    const c11 = img.getPixel(x1, y1);

    return Color{
        .r = @intFromFloat(lerp(fy, lerp(fx, @floatFromInt(c00.r), @floatFromInt(c10.r)), lerp(fx, @floatFromInt(c01.r), @floatFromInt(c11.r)))),
        .g = @intFromFloat(lerp(fy, lerp(fx, @floatFromInt(c00.g), @floatFromInt(c10.g)), lerp(fx, @floatFromInt(c01.g), @floatFromInt(c11.g)))),
        .b = @intFromFloat(lerp(fy, lerp(fx, @floatFromInt(c00.b), @floatFromInt(c10.b)), lerp(fx, @floatFromInt(c01.b), @floatFromInt(c11.b)))),
        .a = 255,
    };
}
