const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// HDR Image (32-bit float per channel)
// ============================================================================

pub const HDRImage = struct {
    data: []f32, // RGBA float data
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !HDRImage {
        const data = try allocator.alloc(f32, width * height * 4);
        @memset(data, 0);

        return HDRImage{
            .data = data,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HDRImage) void {
        self.allocator.free(self.data);
    }

    pub fn getPixel(self: *const HDRImage, x: u32, y: u32) [4]f32 {
        if (x >= self.width or y >= self.height) return .{ 0, 0, 0, 1 };
        const idx = (y * self.width + x) * 4;
        return .{
            self.data[idx],
            self.data[idx + 1],
            self.data[idx + 2],
            self.data[idx + 3],
        };
    }

    pub fn setPixel(self: *HDRImage, x: u32, y: u32, pixel: [4]f32) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (y * self.width + x) * 4;
        self.data[idx] = pixel[0];
        self.data[idx + 1] = pixel[1];
        self.data[idx + 2] = pixel[2];
        self.data[idx + 3] = pixel[3];
    }

    pub fn fromLDR(allocator: std.mem.Allocator, img: *const Image) !HDRImage {
        var hdr = try HDRImage.init(allocator, img.width, img.height);

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                hdr.setPixel(@intCast(x), @intCast(y), .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    @as(f32, @floatFromInt(color.a)) / 255.0,
                });
            }
        }

        return hdr;
    }

    pub fn toLDR(self: *const HDRImage, allocator: std.mem.Allocator, tone_mapper: ToneMapOperator) !Image {
        return toneMap(allocator, self, tone_mapper);
    }

    pub fn clone(self: *const HDRImage) !HDRImage {
        var result = try HDRImage.init(self.allocator, self.width, self.height);
        @memcpy(result.data, self.data);
        return result;
    }

    pub fn getLuminance(self: *const HDRImage, x: u32, y: u32) f32 {
        const pixel = self.getPixel(x, y);
        return pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722;
    }

    pub fn getAverageLuminance(self: *const HDRImage) f32 {
        var sum: f64 = 0;
        const delta: f64 = 0.0001;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const lum = self.getLuminance(@intCast(x), @intCast(y));
                sum += @log(@as(f64, delta) + @as(f64, lum));
            }
        }

        const avg = sum / @as(f64, @floatFromInt(self.width * self.height));
        return @floatCast(@exp(avg));
    }

    pub fn getMaxLuminance(self: *const HDRImage) f32 {
        var max: f32 = 0;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                max = @max(max, self.getLuminance(@intCast(x), @intCast(y)));
            }
        }
        return max;
    }
};

// ============================================================================
// Tone Mapping Operators
// ============================================================================

pub const ToneMapOperator = enum {
    reinhard,
    reinhard_extended,
    filmic,
    aces,
    aces_approx,
    uncharted2,
    lottes,
    uchimura,
    linear,
    exponential,
    logarithmic,
    drago,
    mantiuk,
};

pub const ToneMapOptions = struct {
    exposure: f32 = 1.0,
    gamma: f32 = 2.2,
    white_point: f32 = 1.0,
    saturation: f32 = 1.0,
    // Reinhard parameters
    key_value: f32 = 0.18,
    // Filmic parameters
    shoulder_strength: f32 = 0.22,
    linear_strength: f32 = 0.30,
    linear_angle: f32 = 0.10,
    toe_strength: f32 = 0.20,
    toe_numerator: f32 = 0.01,
    toe_denominator: f32 = 0.30,
    // Drago parameters
    drago_bias: f32 = 0.85,
};

pub fn toneMap(allocator: std.mem.Allocator, hdr: *const HDRImage, operator: ToneMapOperator) !Image {
    return toneMapWithOptions(allocator, hdr, operator, ToneMapOptions{});
}

pub fn toneMapWithOptions(allocator: std.mem.Allocator, hdr: *const HDRImage, operator: ToneMapOperator, options: ToneMapOptions) !Image {
    var img = try Image.create(allocator, hdr.width, hdr.height, .rgba);

    const avg_lum = hdr.getAverageLuminance();
    const max_lum = hdr.getMaxLuminance();

    for (0..hdr.height) |y| {
        for (0..hdr.width) |x| {
            var pixel = hdr.getPixel(@intCast(x), @intCast(y));

            // Apply exposure
            pixel[0] *= options.exposure;
            pixel[1] *= options.exposure;
            pixel[2] *= options.exposure;

            // Apply tone mapping
            const mapped = switch (operator) {
                .reinhard => toneMapReinhard(pixel, avg_lum, options),
                .reinhard_extended => toneMapReinhardExtended(pixel, max_lum, options),
                .filmic => toneMapFilmic(pixel, options),
                .aces => toneMapACES(pixel),
                .aces_approx => toneMapACESApprox(pixel),
                .uncharted2 => toneMapUncharted2(pixel, options),
                .lottes => toneMapLottes(pixel),
                .uchimura => toneMapUchimura(pixel),
                .linear => toneMapLinear(pixel, options),
                .exponential => toneMapExponential(pixel, options),
                .logarithmic => toneMapLogarithmic(pixel, max_lum, options),
                .drago => toneMapDrago(pixel, avg_lum, max_lum, options),
                .mantiuk => toneMapMantiuk(pixel, avg_lum, options),
            };

            // Apply saturation adjustment
            const lum = mapped[0] * 0.2126 + mapped[1] * 0.7152 + mapped[2] * 0.0722;
            var r = lerp(options.saturation, lum, mapped[0]);
            var g = lerp(options.saturation, lum, mapped[1]);
            var b = lerp(options.saturation, lum, mapped[2]);

            // Apply gamma correction
            r = std.math.pow(@max(0, r), 1.0 / options.gamma);
            g = std.math.pow(@max(0, g), 1.0 / options.gamma);
            b = std.math.pow(@max(0, b), 1.0 / options.gamma);

            img.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(std.math.clamp(r * 255, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g * 255, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b * 255, 0, 255)),
                .a = @intFromFloat(std.math.clamp(pixel[3] * 255, 0, 255)),
            });
        }
    }

    return img;
}

fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + t * (b - a);
}

fn toneMapReinhard(pixel: [4]f32, avg_lum: f32, options: ToneMapOptions) [3]f32 {
    const lum = pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722;
    const scaled_lum = (options.key_value / avg_lum) * lum;
    const mapped_lum = scaled_lum / (1.0 + scaled_lum);

    const scale = if (lum > 0.0001) mapped_lum / lum else 0;
    return .{
        pixel[0] * scale,
        pixel[1] * scale,
        pixel[2] * scale,
    };
}

fn toneMapReinhardExtended(pixel: [4]f32, max_lum: f32, options: ToneMapOptions) [3]f32 {
    const white_sq = options.white_point * options.white_point;
    const lum = pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722;
    const mapped_lum = (lum * (1.0 + lum / white_sq)) / (1.0 + lum);

    _ = max_lum;
    const scale = if (lum > 0.0001) mapped_lum / lum else 0;
    return .{
        pixel[0] * scale,
        pixel[1] * scale,
        pixel[2] * scale,
    };
}

fn toneMapFilmic(pixel: [4]f32, options: ToneMapOptions) [3]f32 {
    // Uncharted 2 filmic curve parameters
    const A = options.shoulder_strength;
    const B = options.linear_strength;
    const C = options.linear_angle;
    const D = options.toe_strength;
    const E = options.toe_numerator;
    const F = options.toe_denominator;

    const filmic = struct {
        fn apply(x: f32) f32 {
            return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
        }
    }.apply;

    const white = filmic(options.white_point);
    return .{
        filmic(pixel[0]) / white,
        filmic(pixel[1]) / white,
        filmic(pixel[2]) / white,
    };
}

fn toneMapACES(pixel: [4]f32) [3]f32 {
    // ACES RRT and ODT fit by Stephen Hill
    const a = 2.51;
    const b = 0.03;
    const c = 2.43;
    const d = 0.59;
    const e = 0.14;

    return .{
        (pixel[0] * (a * pixel[0] + b)) / (pixel[0] * (c * pixel[0] + d) + e),
        (pixel[1] * (a * pixel[1] + b)) / (pixel[1] * (c * pixel[1] + d) + e),
        (pixel[2] * (a * pixel[2] + b)) / (pixel[2] * (c * pixel[2] + d) + e),
    };
}

fn toneMapACESApprox(pixel: [4]f32) [3]f32 {
    // Faster ACES approximation by Krzysztof Narkowicz
    const a = 2.51;
    const b = 0.03;
    const c = 2.43;
    const d = 0.59;
    const e = 0.14;

    // Input transform
    const x = pixel[0] * 0.6;
    const y = pixel[1] * 0.6;
    const z = pixel[2] * 0.6;

    return .{
        std.math.clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1),
        std.math.clamp((y * (a * y + b)) / (y * (c * y + d) + e), 0, 1),
        std.math.clamp((z * (a * z + b)) / (z * (c * z + d) + e), 0, 1),
    };
}

fn toneMapUncharted2(pixel: [4]f32, options: ToneMapOptions) [3]f32 {
    const A: f32 = 0.15; // Shoulder Strength
    const B: f32 = 0.50; // Linear Strength
    const C: f32 = 0.10; // Linear Angle
    const D: f32 = 0.20; // Toe Strength
    const E: f32 = 0.02; // Toe Numerator
    const F: f32 = 0.30; // Toe Denominator

    const uncharted = struct {
        fn apply(x: f32) f32 {
            return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
        }
    }.apply;

    const white = uncharted(options.white_point);
    return .{
        uncharted(pixel[0]) / white,
        uncharted(pixel[1]) / white,
        uncharted(pixel[2]) / white,
    };
}

fn toneMapLottes(pixel: [4]f32) [3]f32 {
    // Timothy Lottes tone mapping
    const a: f32 = 1.6;
    const d: f32 = 0.977;
    const hdrMax: f32 = 8.0;
    const midIn: f32 = 0.18;
    const midOut: f32 = 0.267;

    const b = (-std.math.pow(midIn, a) + std.math.pow(hdrMax, a) * midOut) / ((std.math.pow(hdrMax, a * d) - std.math.pow(midIn, a * d)) * midOut);
    const c = (std.math.pow(hdrMax, a * d) * std.math.pow(midIn, a) - std.math.pow(hdrMax, a) * std.math.pow(midIn, a * d) * midOut) / ((std.math.pow(hdrMax, a * d) - std.math.pow(midIn, a * d)) * midOut);

    const lottes = struct {
        fn apply(x: f32) f32 {
            return std.math.pow(x, a) / (std.math.pow(x, a * d) * b + c);
        }
    }.apply;

    return .{
        lottes(pixel[0]),
        lottes(pixel[1]),
        lottes(pixel[2]),
    };
}

fn toneMapUchimura(pixel: [4]f32) [3]f32 {
    // Hajime Uchimura's GT tone mapper
    const P: f32 = 1.0; // max brightness
    const a: f32 = 1.0; // contrast
    const m: f32 = 0.22; // linear section start
    const l: f32 = 0.4; // linear section length
    const c: f32 = 1.33; // black
    const b: f32 = 0.0; // pedestal

    const l0 = ((P - m) * l) / a;
    const S0 = m + l0;
    const S1 = m + a * l0;
    const C2 = (a * P) / (P - S1);
    const CP = -C2 / P;

    const uchimura = struct {
        fn apply(x: f32) f32 {
            const w0 = 1.0 - smoothstep(0.0, m, x);
            const w2 = @as(f32, if (x > m + l0) 1.0 else 0.0);
            const w1 = 1.0 - w0 - w2;

            const T = m * std.math.pow(x / m, c) + b;
            const L = m + a * (x - m);
            const S = P - (P - S1) * @exp(CP * (x - S0));

            return T * w0 + L * w1 + S * w2;
        }
    }.apply;

    return .{
        uchimura(pixel[0]),
        uchimura(pixel[1]),
        uchimura(pixel[2]),
    };
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn toneMapLinear(pixel: [4]f32, options: ToneMapOptions) [3]f32 {
    _ = options;
    return .{
        std.math.clamp(pixel[0], 0, 1),
        std.math.clamp(pixel[1], 0, 1),
        std.math.clamp(pixel[2], 0, 1),
    };
}

fn toneMapExponential(pixel: [4]f32, options: ToneMapOptions) [3]f32 {
    _ = options;
    return .{
        1.0 - @exp(-pixel[0]),
        1.0 - @exp(-pixel[1]),
        1.0 - @exp(-pixel[2]),
    };
}

fn toneMapLogarithmic(pixel: [4]f32, max_lum: f32, options: ToneMapOptions) [3]f32 {
    _ = options;
    const log_max = @log(1.0 + max_lum);
    return .{
        @log(1.0 + pixel[0]) / log_max,
        @log(1.0 + pixel[1]) / log_max,
        @log(1.0 + pixel[2]) / log_max,
    };
}

fn toneMapDrago(pixel: [4]f32, avg_lum: f32, max_lum: f32, options: ToneMapOptions) [3]f32 {
    const lum = pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722;

    // Drago operator
    const lum_scaled = lum / avg_lum;
    const bias = options.drago_bias;
    const log_base = @log(2.0 + 8.0 * std.math.pow(lum_scaled / max_lum, @log(bias) / @log(0.5)));
    const mapped_lum = @log(1.0 + lum_scaled) / log_base;

    const scale = if (lum > 0.0001) mapped_lum / lum else 0;
    return .{
        pixel[0] * scale,
        pixel[1] * scale,
        pixel[2] * scale,
    };
}

fn toneMapMantiuk(pixel: [4]f32, avg_lum: f32, options: ToneMapOptions) [3]f32 {
    // Simplified Mantiuk operator (perceptual)
    const lum = pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722;
    const key = options.key_value;

    const lum_scaled = (key / avg_lum) * lum;
    const mapped_lum = lum_scaled / (1.0 + lum_scaled);

    const scale = if (lum > 0.0001) mapped_lum / lum else 0;
    return .{
        pixel[0] * scale,
        pixel[1] * scale,
        pixel[2] * scale,
    };
}

// ============================================================================
// Exposure Bracketing / HDR Merge
// ============================================================================

pub const BracketedImage = struct {
    image: Image,
    exposure_time: f32, // in seconds
    aperture: f32, // f-number
    iso: u32,

    pub fn getEV(self: *const BracketedImage) f32 {
        // Calculate exposure value
        const ev_aperture = @log2(self.aperture * self.aperture);
        const ev_time = -@log2(self.exposure_time);
        const ev_iso = @log2(@as(f32, @floatFromInt(self.iso)) / 100.0);
        return ev_aperture + ev_time - ev_iso;
    }
};

pub const HDRMergeMethod = enum {
    debevec, // Debevec & Malik
    robertson, // Robertson
    mertens, // Mertens (exposure fusion, LDR output)
    simple_average,
};

pub fn mergeExposureBrackets(allocator: std.mem.Allocator, brackets: []const BracketedImage, method: HDRMergeMethod) !HDRImage {
    if (brackets.len == 0) return error.NoBrackets;

    const width = brackets[0].image.width;
    const height = brackets[0].image.height;

    return switch (method) {
        .debevec => mergeDebevec(allocator, brackets, width, height),
        .robertson => mergeRobertson(allocator, brackets, width, height),
        .mertens => mergeMertens(allocator, brackets, width, height),
        .simple_average => mergeSimpleAverage(allocator, brackets, width, height),
    };
}

fn mergeDebevec(allocator: std.mem.Allocator, brackets: []const BracketedImage, width: u32, height: u32) !HDRImage {
    var hdr = try HDRImage.init(allocator, width, height);

    // Response curve (simplified - assume linear)
    // In a full implementation, this would be recovered from the images

    for (0..height) |y| {
        for (0..width) |x| {
            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;
            var weight_sum: f32 = 0;

            for (brackets) |bracket| {
                const color = bracket.image.getPixel(@intCast(x), @intCast(y));

                // Weight based on pixel value (hat function - prefer middle values)
                const weight_r = triangleWeight(color.r);
                const weight_g = triangleWeight(color.g);
                const weight_b = triangleWeight(color.b);
                const weight = (weight_r + weight_g + weight_b) / 3.0;

                if (weight > 0.01) {
                    // Convert to radiance using exposure
                    const exposure = bracket.exposure_time;
                    sum_r += weight * (@as(f32, @floatFromInt(color.r)) / 255.0) / exposure;
                    sum_g += weight * (@as(f32, @floatFromInt(color.g)) / 255.0) / exposure;
                    sum_b += weight * (@as(f32, @floatFromInt(color.b)) / 255.0) / exposure;
                    weight_sum += weight;
                }
            }

            if (weight_sum > 0) {
                hdr.setPixel(@intCast(x), @intCast(y), .{
                    sum_r / weight_sum,
                    sum_g / weight_sum,
                    sum_b / weight_sum,
                    1.0,
                });
            }
        }
    }

    return hdr;
}

fn triangleWeight(value: u8) f32 {
    // Triangle/hat weighting function
    const normalized = @as(f32, @floatFromInt(value)) / 255.0;
    if (normalized <= 0.5) {
        return normalized * 2.0;
    } else {
        return (1.0 - normalized) * 2.0;
    }
}

fn mergeRobertson(allocator: std.mem.Allocator, brackets: []const BracketedImage, width: u32, height: u32) !HDRImage {
    // Robertson method with iterative refinement
    // Simplified version - similar to Debevec but with Gaussian weights
    var hdr = try HDRImage.init(allocator, width, height);

    for (0..height) |y| {
        for (0..width) |x| {
            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;
            var weight_sum: f32 = 0;

            for (brackets) |bracket| {
                const color = bracket.image.getPixel(@intCast(x), @intCast(y));

                // Gaussian weight centered at 0.5
                const weight_r = gaussianWeight(color.r);
                const weight_g = gaussianWeight(color.g);
                const weight_b = gaussianWeight(color.b);
                const weight = (weight_r + weight_g + weight_b) / 3.0;

                if (weight > 0.01) {
                    const exposure = bracket.exposure_time;
                    sum_r += weight * (@as(f32, @floatFromInt(color.r)) / 255.0) / exposure;
                    sum_g += weight * (@as(f32, @floatFromInt(color.g)) / 255.0) / exposure;
                    sum_b += weight * (@as(f32, @floatFromInt(color.b)) / 255.0) / exposure;
                    weight_sum += weight;
                }
            }

            if (weight_sum > 0) {
                hdr.setPixel(@intCast(x), @intCast(y), .{
                    sum_r / weight_sum,
                    sum_g / weight_sum,
                    sum_b / weight_sum,
                    1.0,
                });
            }
        }
    }

    return hdr;
}

fn gaussianWeight(value: u8) f32 {
    const normalized = @as(f32, @floatFromInt(value)) / 255.0;
    const diff = normalized - 0.5;
    return @exp(-(diff * diff) / 0.08);
}

fn mergeMertens(allocator: std.mem.Allocator, brackets: []const BracketedImage, width: u32, height: u32) !HDRImage {
    // Mertens exposure fusion (produces LDR result stored as HDR)
    var hdr = try HDRImage.init(allocator, width, height);

    // Calculate weights for each bracket (contrast, saturation, well-exposedness)
    var weights = try allocator.alloc([]f32, brackets.len);
    defer {
        for (weights) |w| allocator.free(w);
        allocator.free(weights);
    }

    for (0..brackets.len) |i| {
        weights[i] = try allocator.alloc(f32, width * height);
    }

    // Calculate weights
    for (brackets, 0..) |bracket, bi| {
        for (0..height) |y| {
            for (0..width) |x| {
                const color = bracket.image.getPixel(@intCast(x), @intCast(y));

                // Well-exposedness (Gaussian centered at 0.5)
                const exposure_r = gaussianWeight(color.r);
                const exposure_g = gaussianWeight(color.g);
                const exposure_b = gaussianWeight(color.b);
                const well_exposed = (exposure_r + exposure_g + exposure_b) / 3.0;

                // Saturation
                const r = @as(f32, @floatFromInt(color.r)) / 255.0;
                const g = @as(f32, @floatFromInt(color.g)) / 255.0;
                const b = @as(f32, @floatFromInt(color.b)) / 255.0;
                const mean = (r + g + b) / 3.0;
                const saturation = @sqrt(((r - mean) * (r - mean) + (g - mean) * (g - mean) + (b - mean) * (b - mean)) / 3.0);

                // Contrast (Laplacian magnitude)
                var contrast: f32 = 0;
                if (x > 0 and x < width - 1 and y > 0 and y < height - 1) {
                    const center = @as(f32, @floatFromInt(getLuminance8(color)));
                    const left = @as(f32, @floatFromInt(getLuminance8(bracket.image.getPixel(@intCast(x - 1), @intCast(y)))));
                    const right = @as(f32, @floatFromInt(getLuminance8(bracket.image.getPixel(@intCast(x + 1), @intCast(y)))));
                    const up = @as(f32, @floatFromInt(getLuminance8(bracket.image.getPixel(@intCast(x), @intCast(y - 1)))));
                    const down = @as(f32, @floatFromInt(getLuminance8(bracket.image.getPixel(@intCast(x), @intCast(y + 1)))));
                    contrast = @abs(4 * center - left - right - up - down) / 255.0;
                }

                // Combined weight
                const weight = well_exposed * saturation * (contrast + 0.01);
                weights[bi][y * width + x] = weight;
            }
        }
    }

    // Normalize weights and blend
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;

            var weight_sum: f32 = 0;
            for (0..brackets.len) |i| {
                weight_sum += weights[i][idx];
            }

            if (weight_sum < 0.0001) weight_sum = 1.0;

            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;

            for (brackets, 0..) |bracket, i| {
                const color = bracket.image.getPixel(@intCast(x), @intCast(y));
                const w = weights[i][idx] / weight_sum;
                sum_r += @as(f32, @floatFromInt(color.r)) / 255.0 * w;
                sum_g += @as(f32, @floatFromInt(color.g)) / 255.0 * w;
                sum_b += @as(f32, @floatFromInt(color.b)) / 255.0 * w;
            }

            hdr.setPixel(@intCast(x), @intCast(y), .{ sum_r, sum_g, sum_b, 1.0 });
        }
    }

    return hdr;
}

fn getLuminance8(color: Color) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(color.r)) * 0.299 + @as(f32, @floatFromInt(color.g)) * 0.587 + @as(f32, @floatFromInt(color.b)) * 0.114);
}

fn mergeSimpleAverage(allocator: std.mem.Allocator, brackets: []const BracketedImage, width: u32, height: u32) !HDRImage {
    var hdr = try HDRImage.init(allocator, width, height);

    for (0..height) |y| {
        for (0..width) |x| {
            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;

            for (brackets) |bracket| {
                const color = bracket.image.getPixel(@intCast(x), @intCast(y));
                const exposure = bracket.exposure_time;

                sum_r += (@as(f32, @floatFromInt(color.r)) / 255.0) / exposure;
                sum_g += (@as(f32, @floatFromInt(color.g)) / 255.0) / exposure;
                sum_b += (@as(f32, @floatFromInt(color.b)) / 255.0) / exposure;
            }

            const n = @as(f32, @floatFromInt(brackets.len));
            hdr.setPixel(@intCast(x), @intCast(y), .{
                sum_r / n,
                sum_g / n,
                sum_b / n,
                1.0,
            });
        }
    }

    return hdr;
}

// ============================================================================
// HDR to SDR Conversion
// ============================================================================

pub const HDRToSDROptions = struct {
    tone_mapper: ToneMapOperator = .aces,
    exposure: f32 = 1.0,
    gamma: f32 = 2.2,
    preserve_highlights: bool = true,
    local_contrast: f32 = 0.0,
    color_saturation: f32 = 1.0,
};

pub fn convertHDRToSDR(allocator: std.mem.Allocator, hdr: *const HDRImage, options: HDRToSDROptions) !Image {
    var tone_options = ToneMapOptions{
        .exposure = options.exposure,
        .gamma = options.gamma,
        .saturation = options.color_saturation,
    };

    // Apply local tone mapping if requested
    var processed = if (options.local_contrast > 0)
        try applyLocalToneMapping(allocator, hdr, options.local_contrast)
    else
        try hdr.clone();
    defer processed.deinit();

    return toneMapWithOptions(allocator, &processed, options.tone_mapper, tone_options);
}

fn applyLocalToneMapping(allocator: std.mem.Allocator, hdr: *const HDRImage, strength: f32) !HDRImage {
    var result = try hdr.clone();

    // Simple local contrast enhancement using unsharp mask on luminance
    const radius: u32 = 32;

    // Create luminance blur
    var lum_blur = try allocator.alloc(f32, hdr.width * hdr.height);
    defer allocator.free(lum_blur);

    // Box blur for speed
    for (0..hdr.height) |y| {
        for (0..hdr.width) |x| {
            var sum: f32 = 0;
            var count: f32 = 0;

            const y_start = if (y >= radius) y - radius else 0;
            const y_end = @min(y + radius, hdr.height);
            const x_start = if (x >= radius) x - radius else 0;
            const x_end = @min(x + radius, hdr.width);

            var ky = y_start;
            while (ky < y_end) : (ky += 1) {
                var kx = x_start;
                while (kx < x_end) : (kx += 1) {
                    sum += hdr.getLuminance(@intCast(kx), @intCast(ky));
                    count += 1;
                }
            }

            lum_blur[y * hdr.width + x] = sum / count;
        }
    }

    // Apply local contrast
    for (0..hdr.height) |y| {
        for (0..hdr.width) |x| {
            const pixel = hdr.getPixel(@intCast(x), @intCast(y));
            const lum = hdr.getLuminance(@intCast(x), @intCast(y));
            const blur = lum_blur[y * hdr.width + x];

            // Local contrast: enhance difference from blur
            const detail = (lum - blur) * strength;
            const new_lum = lum + detail;

            const scale = if (lum > 0.0001) new_lum / lum else 1;
            result.setPixel(@intCast(x), @intCast(y), .{
                @max(0, pixel[0] * scale),
                @max(0, pixel[1] * scale),
                @max(0, pixel[2] * scale),
                pixel[3],
            });
        }
    }

    return result;
}

// ============================================================================
// HDR File Format Support (simplified Radiance RGBE)
// ============================================================================

pub fn encodeRGBE(r: f32, g: f32, b: f32) [4]u8 {
    const v = @max(r, @max(g, b));
    if (v < 1e-32) {
        return .{ 0, 0, 0, 0 };
    }

    var exp: i32 = 0;
    const mantissa = std.math.frexp(v);
    exp = mantissa.exponent;
    const scale = mantissa.significand * 256.0 / v;

    return .{
        @intFromFloat(r * scale),
        @intFromFloat(g * scale),
        @intFromFloat(b * scale),
        @intCast(@as(i32, exp) + 128),
    };
}

pub fn decodeRGBE(rgbe: [4]u8) [3]f32 {
    if (rgbe[3] == 0) {
        return .{ 0, 0, 0 };
    }

    const exp = @as(i32, @intCast(rgbe[3])) - 128;
    const scale = std.math.ldexp(@as(f32, 1.0), exp) / 256.0;

    return .{
        @as(f32, @floatFromInt(rgbe[0])) * scale,
        @as(f32, @floatFromInt(rgbe[1])) * scale,
        @as(f32, @floatFromInt(rgbe[2])) * scale,
    };
}
