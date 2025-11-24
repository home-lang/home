const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Histogram
// ============================================================================

pub const Histogram = struct {
    red: [256]u32,
    green: [256]u32,
    blue: [256]u32,
    luminosity: [256]u32,
    total_pixels: u64,

    pub fn init() Histogram {
        return Histogram{
            .red = [_]u32{0} ** 256,
            .green = [_]u32{0} ** 256,
            .blue = [_]u32{0} ** 256,
            .luminosity = [_]u32{0} ** 256,
            .total_pixels = 0,
        };
    }

    pub fn compute(img: *const Image) Histogram {
        var hist = Histogram.init();

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                if (color.a == 0) continue;

                hist.red[color.r] += 1;
                hist.green[color.g] += 1;
                hist.blue[color.b] += 1;

                // Luminosity
                const lum = @as(u8, @intFromFloat(
                    @as(f32, @floatFromInt(color.r)) * 0.299 +
                        @as(f32, @floatFromInt(color.g)) * 0.587 +
                        @as(f32, @floatFromInt(color.b)) * 0.114,
                ));
                hist.luminosity[lum] += 1;
                hist.total_pixels += 1;
            }
        }

        return hist;
    }

    pub fn getMax(self: *const Histogram, channel: Channel) u32 {
        const data = switch (channel) {
            .red => &self.red,
            .green => &self.green,
            .blue => &self.blue,
            .luminosity => &self.luminosity,
            .rgb => return @max(self.getMax(.red), @max(self.getMax(.green), self.getMax(.blue))),
        };

        var max: u32 = 0;
        for (data) |v| {
            max = @max(max, v);
        }
        return max;
    }

    pub fn getPercentile(self: *const Histogram, channel: Channel, percentile: f32) u8 {
        const data = switch (channel) {
            .red => &self.red,
            .green => &self.green,
            .blue => &self.blue,
            .luminosity => &self.luminosity,
            .rgb => &self.luminosity,
        };

        const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.total_pixels)) * percentile));
        var cumulative: u64 = 0;

        for (0..256) |i| {
            cumulative += data[i];
            if (cumulative >= target) return @intCast(i);
        }

        return 255;
    }

    pub fn render(self: *const Histogram, allocator: std.mem.Allocator, width: u32, height: u32, channel: Channel) !Image {
        var img = try Image.create(allocator, width, height, .rgba);

        // Fill background
        for (0..height) |y| {
            for (0..width) |x| {
                img.setPixel(@intCast(x), @intCast(y), Color{ .r = 32, .g = 32, .b = 32, .a = 255 });
            }
        }

        const max = @as(f32, @floatFromInt(self.getMax(channel)));
        if (max == 0) return img;

        // Draw histogram bars
        for (0..width) |x| {
            const idx = @as(usize, @intFromFloat(@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width)) * 255.0));

            const values: [3]u32 = switch (channel) {
                .red => .{ self.red[idx], 0, 0 },
                .green => .{ 0, self.green[idx], 0 },
                .blue => .{ 0, 0, self.blue[idx] },
                .luminosity => .{ self.luminosity[idx], self.luminosity[idx], self.luminosity[idx] },
                .rgb => .{ self.red[idx], self.green[idx], self.blue[idx] },
            };

            const colors: [3]Color = .{
                Color{ .r = 255, .g = 64, .b = 64, .a = 200 },
                Color{ .r = 64, .g = 255, .b = 64, .a = 200 },
                Color{ .r = 64, .g = 64, .b = 255, .a = 200 },
            };

            for (0..3) |c| {
                if (values[c] == 0) continue;

                const bar_height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(values[c])) / max * @as(f32, @floatFromInt(height))));

                for (0..bar_height) |y| {
                    const py = height - 1 - y;
                    const current = img.getPixel(@intCast(x), py);
                    img.setPixel(@intCast(x), py, blendAdditive(current, colors[c]));
                }
            }
        }

        return img;
    }
};

fn blendAdditive(dst: Color, src: Color) Color {
    return Color{
        .r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(dst.r)) + @as(f32, @floatFromInt(src.r)) * @as(f32, @floatFromInt(src.a)) / 255.0)),
        .g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(dst.g)) + @as(f32, @floatFromInt(src.g)) * @as(f32, @floatFromInt(src.a)) / 255.0)),
        .b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(dst.b)) + @as(f32, @floatFromInt(src.b)) * @as(f32, @floatFromInt(src.a)) / 255.0)),
        .a = 255,
    };
}

pub const Channel = enum {
    red,
    green,
    blue,
    luminosity,
    rgb,
};

// ============================================================================
// Curves Adjustment
// ============================================================================

pub const CurvePoint = struct {
    input: f32, // 0.0 to 1.0
    output: f32, // 0.0 to 1.0
};

pub const Curve = struct {
    points: []CurvePoint,
    lut: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Curve {
        var points = try allocator.alloc(CurvePoint, 2);
        points[0] = CurvePoint{ .input = 0, .output = 0 };
        points[1] = CurvePoint{ .input = 1, .output = 1 };

        var curve = Curve{
            .points = points,
            .lut = undefined,
            .allocator = allocator,
        };
        curve.rebuildLUT();
        return curve;
    }

    pub fn deinit(self: *Curve) void {
        self.allocator.free(self.points);
    }

    pub fn addPoint(self: *Curve, point: CurvePoint) !void {
        // Find insertion position
        var insert_idx: usize = 0;
        for (self.points, 0..) |p, i| {
            if (p.input > point.input) {
                insert_idx = i;
                break;
            }
            insert_idx = i + 1;
        }

        var new_points = try self.allocator.alloc(CurvePoint, self.points.len + 1);
        @memcpy(new_points[0..insert_idx], self.points[0..insert_idx]);
        new_points[insert_idx] = point;
        @memcpy(new_points[insert_idx + 1 ..], self.points[insert_idx..]);

        self.allocator.free(self.points);
        self.points = new_points;
        self.rebuildLUT();
    }

    pub fn removePoint(self: *Curve, index: usize) void {
        if (self.points.len <= 2 or index >= self.points.len) return;

        // Don't remove first or last point
        if (index == 0 or index == self.points.len - 1) return;

        for (index..self.points.len - 1) |i| {
            self.points[i] = self.points[i + 1];
        }
        self.points = self.points[0 .. self.points.len - 1];
        self.rebuildLUT();
    }

    pub fn movePoint(self: *Curve, index: usize, new_output: f32) void {
        if (index >= self.points.len) return;
        self.points[index].output = std.math.clamp(new_output, 0, 1);
        self.rebuildLUT();
    }

    pub fn rebuildLUT(self: *Curve) void {
        // Use cubic spline interpolation
        for (0..256) |i| {
            const t = @as(f32, @floatFromInt(i)) / 255.0;
            self.lut[i] = @intFromFloat(std.math.clamp(self.evaluate(t), 0, 1) * 255.0);
        }
    }

    fn evaluate(self: *const Curve, t: f32) f32 {
        // Find the segment
        var i: usize = 0;
        while (i < self.points.len - 1 and self.points[i + 1].input < t) : (i += 1) {}

        if (i >= self.points.len - 1) return self.points[self.points.len - 1].output;

        const p0 = self.points[i];
        const p1 = self.points[i + 1];

        // Linear interpolation for simplicity (could upgrade to cubic)
        if (p1.input - p0.input < 0.0001) return p0.output;
        const local_t = (t - p0.input) / (p1.input - p0.input);

        // Smoothstep for nicer curves
        const smooth_t = local_t * local_t * (3 - 2 * local_t);
        return p0.output + (p1.output - p0.output) * smooth_t;
    }

    pub fn apply(self: *const Curve, value: u8) u8 {
        return self.lut[value];
    }

    pub fn setPreset(self: *Curve, preset: CurvePreset) !void {
        self.allocator.free(self.points);

        switch (preset) {
            .linear => {
                self.points = try self.allocator.alloc(CurvePoint, 2);
                self.points[0] = CurvePoint{ .input = 0, .output = 0 };
                self.points[1] = CurvePoint{ .input = 1, .output = 1 };
            },
            .increase_contrast => {
                self.points = try self.allocator.alloc(CurvePoint, 3);
                self.points[0] = CurvePoint{ .input = 0, .output = 0 };
                self.points[1] = CurvePoint{ .input = 0.5, .output = 0.5 };
                self.points[2] = CurvePoint{ .input = 1, .output = 1 };
                // S-curve
                self.points[0].output = 0.05;
                self.points[2].output = 0.95;
            },
            .decrease_contrast => {
                self.points = try self.allocator.alloc(CurvePoint, 2);
                self.points[0] = CurvePoint{ .input = 0, .output = 0.1 };
                self.points[1] = CurvePoint{ .input = 1, .output = 0.9 };
            },
            .lighten => {
                self.points = try self.allocator.alloc(CurvePoint, 3);
                self.points[0] = CurvePoint{ .input = 0, .output = 0 };
                self.points[1] = CurvePoint{ .input = 0.5, .output = 0.65 };
                self.points[2] = CurvePoint{ .input = 1, .output = 1 };
            },
            .darken => {
                self.points = try self.allocator.alloc(CurvePoint, 3);
                self.points[0] = CurvePoint{ .input = 0, .output = 0 };
                self.points[1] = CurvePoint{ .input = 0.5, .output = 0.35 };
                self.points[2] = CurvePoint{ .input = 1, .output = 1 };
            },
            .negative => {
                self.points = try self.allocator.alloc(CurvePoint, 2);
                self.points[0] = CurvePoint{ .input = 0, .output = 1 };
                self.points[1] = CurvePoint{ .input = 1, .output = 0 };
            },
            .posterize => {
                self.points = try self.allocator.alloc(CurvePoint, 5);
                self.points[0] = CurvePoint{ .input = 0, .output = 0 };
                self.points[1] = CurvePoint{ .input = 0.25, .output = 0 };
                self.points[2] = CurvePoint{ .input = 0.5, .output = 0.5 };
                self.points[3] = CurvePoint{ .input = 0.75, .output = 1 };
                self.points[4] = CurvePoint{ .input = 1, .output = 1 };
            },
        }
        self.rebuildLUT();
    }
};

pub const CurvePreset = enum {
    linear,
    increase_contrast,
    decrease_contrast,
    lighten,
    darken,
    negative,
    posterize,
};

pub const CurvesAdjustment = struct {
    master: Curve,
    red: Curve,
    green: Curve,
    blue: Curve,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CurvesAdjustment {
        return CurvesAdjustment{
            .master = try Curve.init(allocator),
            .red = try Curve.init(allocator),
            .green = try Curve.init(allocator),
            .blue = try Curve.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CurvesAdjustment) void {
        self.master.deinit();
        self.red.deinit();
        self.green.deinit();
        self.blue.deinit();
    }

    pub fn apply(self: *const CurvesAdjustment, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));

                // Apply channel curves first, then master
                const r = self.master.apply(self.red.apply(color.r));
                const g = self.master.apply(self.green.apply(color.g));
                const b = self.master.apply(self.blue.apply(color.b));

                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = r,
                    .g = g,
                    .b = b,
                    .a = color.a,
                });
            }
        }
    }
};

// ============================================================================
// Levels Adjustment
// ============================================================================

pub const LevelsAdjustment = struct {
    input_black: u8 = 0,
    input_white: u8 = 255,
    input_gamma: f32 = 1.0,
    output_black: u8 = 0,
    output_white: u8 = 255,
    lut: [256]u8 = undefined,

    pub fn init() LevelsAdjustment {
        var levels = LevelsAdjustment{};
        levels.rebuildLUT();
        return levels;
    }

    pub fn setInputLevels(self: *LevelsAdjustment, black: u8, white: u8, gamma: f32) void {
        self.input_black = black;
        self.input_white = @max(black + 1, white);
        self.input_gamma = std.math.clamp(gamma, 0.1, 10.0);
        self.rebuildLUT();
    }

    pub fn setOutputLevels(self: *LevelsAdjustment, black: u8, white: u8) void {
        self.output_black = black;
        self.output_white = white;
        self.rebuildLUT();
    }

    pub fn autoLevels(self: *LevelsAdjustment, hist: *const Histogram) void {
        // Find black and white points at 0.5% and 99.5% percentile
        self.input_black = hist.getPercentile(.luminosity, 0.005);
        self.input_white = hist.getPercentile(.luminosity, 0.995);
        self.rebuildLUT();
    }

    fn rebuildLUT(self: *LevelsAdjustment) void {
        const in_range = @as(f32, @floatFromInt(self.input_white - self.input_black));
        const out_range = @as(f32, @floatFromInt(self.output_white)) - @as(f32, @floatFromInt(self.output_black));

        for (0..256) |i| {
            var value: f32 = @floatFromInt(i);

            // Clip to input range
            value = std.math.clamp(value, @floatFromInt(self.input_black), @floatFromInt(self.input_white));

            // Normalize to 0-1
            value = (value - @as(f32, @floatFromInt(self.input_black))) / in_range;

            // Apply gamma
            value = std.math.pow(value, 1.0 / self.input_gamma);

            // Map to output range
            value = value * out_range + @as(f32, @floatFromInt(self.output_black));

            self.lut[i] = @intFromFloat(std.math.clamp(value, 0, 255));
        }
    }

    pub fn apply(self: *const LevelsAdjustment, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = self.lut[color.r],
                    .g = self.lut[color.g],
                    .b = self.lut[color.b],
                    .a = color.a,
                });
            }
        }
    }

    pub fn applyToChannel(self: *const LevelsAdjustment, img: *Image, channel: Channel) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                var color = img.getPixel(@intCast(x), @intCast(y));
                switch (channel) {
                    .red => color.r = self.lut[color.r],
                    .green => color.g = self.lut[color.g],
                    .blue => color.b = self.lut[color.b],
                    .luminosity, .rgb => {
                        color.r = self.lut[color.r];
                        color.g = self.lut[color.g];
                        color.b = self.lut[color.b];
                    },
                }
                img.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }
};

// ============================================================================
// Channel Mixer
// ============================================================================

pub const ChannelMixer = struct {
    // Output channel = sum of (input channel * coefficient)
    red_red: f32 = 1.0,
    red_green: f32 = 0.0,
    red_blue: f32 = 0.0,
    red_constant: f32 = 0.0,

    green_red: f32 = 0.0,
    green_green: f32 = 1.0,
    green_blue: f32 = 0.0,
    green_constant: f32 = 0.0,

    blue_red: f32 = 0.0,
    blue_green: f32 = 0.0,
    blue_blue: f32 = 1.0,
    blue_constant: f32 = 0.0,

    monochrome: bool = false,

    pub fn init() ChannelMixer {
        return ChannelMixer{};
    }

    pub fn setPreset(self: *ChannelMixer, preset: ChannelMixerPreset) void {
        switch (preset) {
            .identity => {
                self.* = ChannelMixer{};
            },
            .grayscale_luminosity => {
                self.monochrome = true;
                self.red_red = 0.299;
                self.red_green = 0.587;
                self.red_blue = 0.114;
            },
            .grayscale_average => {
                self.monochrome = true;
                self.red_red = 0.333;
                self.red_green = 0.333;
                self.red_blue = 0.333;
            },
            .sepia => {
                self.red_red = 0.393;
                self.red_green = 0.769;
                self.red_blue = 0.189;
                self.green_red = 0.349;
                self.green_green = 0.686;
                self.green_blue = 0.168;
                self.blue_red = 0.272;
                self.blue_green = 0.534;
                self.blue_blue = 0.131;
            },
            .swap_red_blue => {
                self.red_red = 0;
                self.red_blue = 1;
                self.blue_red = 1;
                self.blue_blue = 0;
            },
            .infrared => {
                self.red_red = -0.6;
                self.red_green = 2.0;
                self.red_blue = -0.4;
                self.green_red = -0.6;
                self.green_green = 2.0;
                self.green_blue = -0.4;
                self.blue_red = -0.6;
                self.blue_green = 2.0;
                self.blue_blue = -0.4;
            },
        }
    }

    pub fn apply(self: *const ChannelMixer, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                const r = @as(f32, @floatFromInt(color.r));
                const g = @as(f32, @floatFromInt(color.g));
                const b = @as(f32, @floatFromInt(color.b));

                var out_r = r * self.red_red + g * self.red_green + b * self.red_blue + self.red_constant * 255;
                var out_g = r * self.green_red + g * self.green_green + b * self.green_blue + self.green_constant * 255;
                var out_b = r * self.blue_red + g * self.blue_green + b * self.blue_blue + self.blue_constant * 255;

                if (self.monochrome) {
                    out_g = out_r;
                    out_b = out_r;
                }

                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(std.math.clamp(out_r, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(out_g, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(out_b, 0, 255)),
                    .a = color.a,
                });
            }
        }
    }
};

pub const ChannelMixerPreset = enum {
    identity,
    grayscale_luminosity,
    grayscale_average,
    sepia,
    swap_red_blue,
    infrared,
};

// ============================================================================
// Selective Color Adjustment
// ============================================================================

pub const SelectiveColor = struct {
    // Adjustments for each color range (-1 to 1)
    reds: ColorAdjustment = ColorAdjustment{},
    yellows: ColorAdjustment = ColorAdjustment{},
    greens: ColorAdjustment = ColorAdjustment{},
    cyans: ColorAdjustment = ColorAdjustment{},
    blues: ColorAdjustment = ColorAdjustment{},
    magentas: ColorAdjustment = ColorAdjustment{},
    whites: ColorAdjustment = ColorAdjustment{},
    neutrals: ColorAdjustment = ColorAdjustment{},
    blacks: ColorAdjustment = ColorAdjustment{},

    relative: bool = true, // true = relative, false = absolute

    pub const ColorAdjustment = struct {
        cyan: f32 = 0,
        magenta: f32 = 0,
        yellow: f32 = 0,
        black: f32 = 0,
    };

    pub fn apply(self: *const SelectiveColor, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));

                // Convert to CMY
                var c = 1.0 - @as(f32, @floatFromInt(color.r)) / 255.0;
                var m = 1.0 - @as(f32, @floatFromInt(color.g)) / 255.0;
                var y_val = 1.0 - @as(f32, @floatFromInt(color.b)) / 255.0;

                // Determine which color ranges this pixel belongs to
                const max_val = @max(c, @max(m, y_val));
                const min_val = @min(c, @min(m, y_val));
                const luminosity = (max_val + min_val) / 2.0;

                // Get the dominant color adjustment
                const adj = self.getAdjustmentForColor(c, m, y_val, luminosity);

                // Apply adjustment
                if (self.relative) {
                    c += adj.cyan * c;
                    m += adj.magenta * m;
                    y_val += adj.yellow * y_val;
                    // Black adjustment affects all channels
                    c += adj.black;
                    m += adj.black;
                    y_val += adj.black;
                } else {
                    c += adj.cyan;
                    m += adj.magenta;
                    y_val += adj.yellow;
                    c += adj.black;
                    m += adj.black;
                    y_val += adj.black;
                }

                // Convert back to RGB
                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(std.math.clamp((1.0 - c) * 255.0, 0, 255)),
                    .g = @intFromFloat(std.math.clamp((1.0 - m) * 255.0, 0, 255)),
                    .b = @intFromFloat(std.math.clamp((1.0 - y_val) * 255.0, 0, 255)),
                    .a = color.a,
                });
            }
        }
    }

    fn getAdjustmentForColor(self: *const SelectiveColor, c: f32, m: f32, y: f32, lum: f32) ColorAdjustment {
        var result = ColorAdjustment{};
        var total_weight: f32 = 0;

        // Calculate weights for each color range
        const weights = [_]struct { adj: ColorAdjustment, weight: f32 }{
            .{ .adj = self.reds, .weight = getRedWeight(c, m, y) },
            .{ .adj = self.yellows, .weight = getYellowWeight(c, m, y) },
            .{ .adj = self.greens, .weight = getGreenWeight(c, m, y) },
            .{ .adj = self.cyans, .weight = getCyanWeight(c, m, y) },
            .{ .adj = self.blues, .weight = getBlueWeight(c, m, y) },
            .{ .adj = self.magentas, .weight = getMagentaWeight(c, m, y) },
            .{ .adj = self.whites, .weight = if (lum > 0.75) (lum - 0.75) * 4 else 0 },
            .{ .adj = self.neutrals, .weight = if (lum > 0.25 and lum < 0.75) 1.0 - @abs(lum - 0.5) * 4 else 0 },
            .{ .adj = self.blacks, .weight = if (lum < 0.25) (0.25 - lum) * 4 else 0 },
        };

        for (weights) |w| {
            if (w.weight > 0) {
                result.cyan += w.adj.cyan * w.weight;
                result.magenta += w.adj.magenta * w.weight;
                result.yellow += w.adj.yellow * w.weight;
                result.black += w.adj.black * w.weight;
                total_weight += w.weight;
            }
        }

        if (total_weight > 0) {
            result.cyan /= total_weight;
            result.magenta /= total_weight;
            result.yellow /= total_weight;
            result.black /= total_weight;
        }

        return result;
    }
};

fn getRedWeight(c: f32, m: f32, y: f32) f32 {
    // Red: low C, high M and Y
    return @max(0, (1 - c) * m * y);
}

fn getYellowWeight(c: f32, m: f32, y: f32) f32 {
    // Yellow: low C and M, high Y
    return @max(0, (1 - c) * (1 - m) * y);
}

fn getGreenWeight(c: f32, m: f32, y: f32) f32 {
    // Green: high C and Y, low M
    return @max(0, c * (1 - m) * y);
}

fn getCyanWeight(c: f32, m: f32, y: f32) f32 {
    // Cyan: high C, low M and Y
    return @max(0, c * (1 - m) * (1 - y));
}

fn getBlueWeight(c: f32, m: f32, y: f32) f32 {
    // Blue: high C and M, low Y
    return @max(0, c * m * (1 - y));
}

fn getMagentaWeight(c: f32, m: f32, y: f32) f32 {
    // Magenta: high M, low C and Y
    return @max(0, (1 - c) * m * (1 - y));
}

// ============================================================================
// Color Balance
// ============================================================================

pub const ColorBalance = struct {
    shadows_cyan_red: f32 = 0, // -1 = cyan, +1 = red
    shadows_magenta_green: f32 = 0,
    shadows_yellow_blue: f32 = 0,

    midtones_cyan_red: f32 = 0,
    midtones_magenta_green: f32 = 0,
    midtones_yellow_blue: f32 = 0,

    highlights_cyan_red: f32 = 0,
    highlights_magenta_green: f32 = 0,
    highlights_yellow_blue: f32 = 0,

    preserve_luminosity: bool = true,

    pub fn apply(self: *const ColorBalance, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                var r = @as(f32, @floatFromInt(color.r)) / 255.0;
                var g = @as(f32, @floatFromInt(color.g)) / 255.0;
                var b = @as(f32, @floatFromInt(color.b)) / 255.0;

                const lum = r * 0.299 + g * 0.587 + b * 0.114;

                // Calculate tonal weights
                const shadow_weight = @max(0, 0.333 - lum) * 3;
                const midtone_weight = 1.0 - @abs(lum - 0.5) * 2;
                const highlight_weight = @max(0, lum - 0.666) * 3;

                // Apply adjustments
                var dr: f32 = 0;
                var dg: f32 = 0;
                var db: f32 = 0;

                dr += shadow_weight * self.shadows_cyan_red * 0.2;
                dg += shadow_weight * self.shadows_magenta_green * 0.2;
                db += shadow_weight * self.shadows_yellow_blue * 0.2;

                dr += midtone_weight * self.midtones_cyan_red * 0.2;
                dg += midtone_weight * self.midtones_magenta_green * 0.2;
                db += midtone_weight * self.midtones_yellow_blue * 0.2;

                dr += highlight_weight * self.highlights_cyan_red * 0.2;
                dg += highlight_weight * self.highlights_magenta_green * 0.2;
                db += highlight_weight * self.highlights_yellow_blue * 0.2;

                r = std.math.clamp(r + dr, 0, 1);
                g = std.math.clamp(g + dg, 0, 1);
                b = std.math.clamp(b + db, 0, 1);

                // Preserve luminosity if requested
                if (self.preserve_luminosity) {
                    const new_lum = r * 0.299 + g * 0.587 + b * 0.114;
                    if (new_lum > 0.001) {
                        const scale = lum / new_lum;
                        r = std.math.clamp(r * scale, 0, 1);
                        g = std.math.clamp(g * scale, 0, 1);
                        b = std.math.clamp(b * scale, 0, 1);
                    }
                }

                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(r * 255),
                    .g = @intFromFloat(g * 255),
                    .b = @intFromFloat(b * 255),
                    .a = color.a,
                });
            }
        }
    }
};

// ============================================================================
// Hue/Saturation Adjustment
// ============================================================================

pub const HueSaturation = struct {
    hue: f32 = 0, // -180 to 180
    saturation: f32 = 0, // -1 to 1
    lightness: f32 = 0, // -1 to 1

    // Per-color adjustments
    reds_hue: f32 = 0,
    reds_saturation: f32 = 0,
    reds_lightness: f32 = 0,

    yellows_hue: f32 = 0,
    yellows_saturation: f32 = 0,
    yellows_lightness: f32 = 0,

    greens_hue: f32 = 0,
    greens_saturation: f32 = 0,
    greens_lightness: f32 = 0,

    cyans_hue: f32 = 0,
    cyans_saturation: f32 = 0,
    cyans_lightness: f32 = 0,

    blues_hue: f32 = 0,
    blues_saturation: f32 = 0,
    blues_lightness: f32 = 0,

    magentas_hue: f32 = 0,
    magentas_saturation: f32 = 0,
    magentas_lightness: f32 = 0,

    colorize: bool = false,
    colorize_hue: f32 = 0,
    colorize_saturation: f32 = 0.5,

    pub fn apply(self: *const HueSaturation, img: *Image) void {
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                const hsl = rgbToHsl(color);
                var h = hsl[0];
                var s = hsl[1];
                var l = hsl[2];

                if (self.colorize) {
                    h = self.colorize_hue;
                    s = self.colorize_saturation;
                    l += self.lightness;
                } else {
                    // Apply master adjustment
                    h += self.hue;
                    s += self.saturation;
                    l += self.lightness;

                    // Apply per-color adjustments based on hue
                    const color_adj = self.getColorAdjustment(h);
                    h += color_adj[0];
                    s += color_adj[1];
                    l += color_adj[2];
                }

                // Normalize
                while (h < 0) h += 360;
                while (h >= 360) h -= 360;
                s = std.math.clamp(s, 0, 1);
                l = std.math.clamp(l, 0, 1);

                const rgb = hslToRgb(h, s, l);
                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = rgb[0],
                    .g = rgb[1],
                    .b = rgb[2],
                    .a = color.a,
                });
            }
        }
    }

    fn getColorAdjustment(self: *const HueSaturation, hue: f32) [3]f32 {
        // Determine which color range and blend
        const ranges = [_]struct { center: f32, h: f32, s: f32, l: f32 }{
            .{ .center = 0, .h = self.reds_hue, .s = self.reds_saturation, .l = self.reds_lightness },
            .{ .center = 60, .h = self.yellows_hue, .s = self.yellows_saturation, .l = self.yellows_lightness },
            .{ .center = 120, .h = self.greens_hue, .s = self.greens_saturation, .l = self.greens_lightness },
            .{ .center = 180, .h = self.cyans_hue, .s = self.cyans_saturation, .l = self.cyans_lightness },
            .{ .center = 240, .h = self.blues_hue, .s = self.blues_saturation, .l = self.blues_lightness },
            .{ .center = 300, .h = self.magentas_hue, .s = self.magentas_saturation, .l = self.magentas_lightness },
        };

        var total_h: f32 = 0;
        var total_s: f32 = 0;
        var total_l: f32 = 0;
        var total_weight: f32 = 0;

        for (ranges) |range| {
            var diff = @abs(hue - range.center);
            if (diff > 180) diff = 360 - diff;

            if (diff < 60) {
                const weight = 1.0 - diff / 60.0;
                total_h += range.h * weight;
                total_s += range.s * weight;
                total_l += range.l * weight;
                total_weight += weight;
            }
        }

        if (total_weight > 0) {
            return .{ total_h / total_weight, total_s / total_weight, total_l / total_weight };
        }
        return .{ 0, 0, 0 };
    }
};

fn rgbToHsl(color: Color) [3]f32 {
    const r = @as(f32, @floatFromInt(color.r)) / 255.0;
    const g = @as(f32, @floatFromInt(color.g)) / 255.0;
    const b = @as(f32, @floatFromInt(color.b)) / 255.0;

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const l = (max_val + min_val) / 2.0;

    if (max_val == min_val) {
        return .{ 0, 0, l };
    }

    const d = max_val - min_val;
    const s = if (l > 0.5) d / (2.0 - max_val - min_val) else d / (max_val + min_val);

    var h: f32 = 0;
    if (max_val == r) {
        h = (g - b) / d + (if (g < b) @as(f32, 6.0) else 0);
    } else if (max_val == g) {
        h = (b - r) / d + 2.0;
    } else {
        h = (r - g) / d + 4.0;
    }
    h *= 60;

    return .{ h, s, l };
}

fn hslToRgb(h: f32, s: f32, l: f32) [3]u8 {
    if (s == 0) {
        const v = @as(u8, @intFromFloat(l * 255));
        return .{ v, v, v };
    }

    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;

    const r = hueToRgb(p, q, h / 360.0 + 1.0 / 3.0);
    const g = hueToRgb(p, q, h / 360.0);
    const b = hueToRgb(p, q, h / 360.0 - 1.0 / 3.0);

    return .{
        @intFromFloat(std.math.clamp(r * 255, 0, 255)),
        @intFromFloat(std.math.clamp(g * 255, 0, 255)),
        @intFromFloat(std.math.clamp(b * 255, 0, 255)),
    };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

// ============================================================================
// Exposure Adjustment
// ============================================================================

pub const ExposureAdjustment = struct {
    exposure: f32 = 0, // -5 to +5 stops
    offset: f32 = 0, // -0.5 to +0.5
    gamma: f32 = 1.0, // 0.1 to 10

    pub fn apply(self: *const ExposureAdjustment, img: *Image) void {
        const exp_factor = std.math.pow(@as(f32, 2.0), self.exposure);

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));

                var r = @as(f32, @floatFromInt(color.r)) / 255.0;
                var g = @as(f32, @floatFromInt(color.g)) / 255.0;
                var b = @as(f32, @floatFromInt(color.b)) / 255.0;

                // Apply exposure
                r *= exp_factor;
                g *= exp_factor;
                b *= exp_factor;

                // Apply offset
                r += self.offset;
                g += self.offset;
                b += self.offset;

                // Apply gamma
                r = std.math.pow(@max(0, r), 1.0 / self.gamma);
                g = std.math.pow(@max(0, g), 1.0 / self.gamma);
                b = std.math.pow(@max(0, b), 1.0 / self.gamma);

                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = @intFromFloat(std.math.clamp(r * 255, 0, 255)),
                    .g = @intFromFloat(std.math.clamp(g * 255, 0, 255)),
                    .b = @intFromFloat(std.math.clamp(b * 255, 0, 255)),
                    .a = color.a,
                });
            }
        }
    }
};
