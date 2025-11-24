const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Selection Representation
// ============================================================================

pub const Selection = struct {
    mask: []u8, // Alpha mask: 0 = not selected, 255 = fully selected
    width: u32,
    height: u32,
    bounds: BoundingBox,
    allocator: std.mem.Allocator,

    pub const BoundingBox = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,

        pub fn isEmpty(self: BoundingBox) bool {
            return self.width == 0 or self.height == 0;
        }

        pub fn intersect(self: BoundingBox, other: BoundingBox) BoundingBox {
            const x1 = @max(self.x, other.x);
            const y1 = @max(self.y, other.y);
            const x2 = @min(self.x + self.width, other.x + other.width);
            const y2 = @min(self.y + self.height, other.y + other.height);

            if (x2 <= x1 or y2 <= y1) {
                return BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };
            }
            return BoundingBox{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
        }

        pub fn union_(self: BoundingBox, other: BoundingBox) BoundingBox {
            if (self.isEmpty()) return other;
            if (other.isEmpty()) return self;

            const x1 = @min(self.x, other.x);
            const y1 = @min(self.y, other.y);
            const x2 = @max(self.x + self.width, other.x + other.width);
            const y2 = @max(self.y + self.height, other.y + other.height);

            return BoundingBox{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
        }
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Selection {
        const mask = try allocator.alloc(u8, width * height);
        @memset(mask, 0);
        return Selection{
            .mask = mask,
            .width = width,
            .height = height,
            .bounds = BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.mask);
    }

    pub fn clone(self: *const Selection) !Selection {
        const mask = try self.allocator.alloc(u8, self.width * self.height);
        @memcpy(mask, self.mask);
        return Selection{
            .mask = mask,
            .width = self.width,
            .height = self.height,
            .bounds = self.bounds,
            .allocator = self.allocator,
        };
    }

    pub fn getValue(self: *const Selection, x: u32, y: u32) u8 {
        if (x >= self.width or y >= self.height) return 0;
        return self.mask[y * self.width + x];
    }

    pub fn setValue(self: *Selection, x: u32, y: u32, value: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.mask[y * self.width + x] = value;
    }

    pub fn clear(self: *Selection) void {
        @memset(self.mask, 0);
        self.bounds = BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn selectAll(self: *Selection) void {
        @memset(self.mask, 255);
        self.bounds = BoundingBox{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    pub fn invert(self: *Selection) void {
        for (self.mask) |*v| {
            v.* = 255 - v.*;
        }
        self.recalculateBounds();
    }

    pub fn recalculateBounds(self: *Selection) void {
        var min_x: u32 = self.width;
        var min_y: u32 = self.height;
        var max_x: u32 = 0;
        var max_y: u32 = 0;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.getValue(@intCast(x), @intCast(y)) > 0) {
                    min_x = @min(min_x, @as(u32, @intCast(x)));
                    min_y = @min(min_y, @as(u32, @intCast(y)));
                    max_x = @max(max_x, @as(u32, @intCast(x)));
                    max_y = @max(max_y, @as(u32, @intCast(y)));
                }
            }
        }

        if (max_x >= min_x and max_y >= min_y) {
            self.bounds = BoundingBox{
                .x = min_x,
                .y = min_y,
                .width = max_x - min_x + 1,
                .height = max_y - min_y + 1,
            };
        } else {
            self.bounds = BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
    }

    pub fn isEmpty(self: *const Selection) bool {
        for (self.mask) |v| {
            if (v > 0) return false;
        }
        return true;
    }

    pub fn toImage(self: *const Selection, allocator: std.mem.Allocator) !Image {
        var img = try Image.create(allocator, self.width, self.height, .rgba);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const v = self.getValue(@intCast(x), @intCast(y));
                img.setPixel(@intCast(x), @intCast(y), Color{ .r = v, .g = v, .b = v, .a = 255 });
            }
        }
        return img;
    }
};

// ============================================================================
// Selection Operations
// ============================================================================

pub const SelectionOp = enum {
    replace,
    add,
    subtract,
    intersect,
};

pub fn combineSelections(dest: *Selection, src: *const Selection, op: SelectionOp) void {
    const min_w = @min(dest.width, src.width);
    const min_h = @min(dest.height, src.height);

    for (0..min_h) |y| {
        for (0..min_w) |x| {
            const d = dest.getValue(@intCast(x), @intCast(y));
            const s = src.getValue(@intCast(x), @intCast(y));

            const result = switch (op) {
                .replace => s,
                .add => @as(u8, @intFromFloat(@min(255.0, @as(f32, @floatFromInt(d)) + @as(f32, @floatFromInt(s))))),
                .subtract => @as(u8, @intFromFloat(@max(0.0, @as(f32, @floatFromInt(d)) - @as(f32, @floatFromInt(s))))),
                .intersect => @min(d, s),
            };

            dest.setValue(@intCast(x), @intCast(y), result);
        }
    }

    dest.recalculateBounds();
}

// ============================================================================
// Magic Wand (Flood Select by Color)
// ============================================================================

pub const MagicWandOptions = struct {
    tolerance: u8 = 32,
    contiguous: bool = true,
    anti_alias: bool = true,
    sample_all_layers: bool = false,
};

pub fn magicWand(allocator: std.mem.Allocator, img: *const Image, start_x: u32, start_y: u32, options: MagicWandOptions) !Selection {
    var selection = try Selection.init(allocator, img.width, img.height);

    if (start_x >= img.width or start_y >= img.height) return selection;

    const target_color = img.getPixel(start_x, start_y);

    if (options.contiguous) {
        // Flood fill from start point
        var stack = std.ArrayList(struct { x: u32, y: u32 }).init(allocator);
        defer stack.deinit();

        var visited = try allocator.alloc(bool, img.width * img.height);
        defer allocator.free(visited);
        @memset(visited, false);

        try stack.append(.{ .x = start_x, .y = start_y });

        while (stack.items.len > 0) {
            const pos = stack.pop();
            const idx = pos.y * img.width + pos.x;

            if (visited[idx]) continue;
            visited[idx] = true;

            const color = img.getPixel(pos.x, pos.y);
            const diff = colorDifference(target_color, color);

            if (diff <= options.tolerance) {
                const alpha = if (options.anti_alias)
                    @as(u8, @intFromFloat(255.0 * (1.0 - @as(f32, @floatFromInt(diff)) / @as(f32, @floatFromInt(options.tolerance + 1)))))
                else
                    @as(u8, 255);

                selection.setValue(pos.x, pos.y, alpha);

                // Add neighbors
                if (pos.x > 0) try stack.append(.{ .x = pos.x - 1, .y = pos.y });
                if (pos.x < img.width - 1) try stack.append(.{ .x = pos.x + 1, .y = pos.y });
                if (pos.y > 0) try stack.append(.{ .x = pos.x, .y = pos.y - 1 });
                if (pos.y < img.height - 1) try stack.append(.{ .x = pos.x, .y = pos.y + 1 });
            }
        }
    } else {
        // Select all pixels matching color
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                const diff = colorDifference(target_color, color);

                if (diff <= options.tolerance) {
                    const alpha = if (options.anti_alias)
                        @as(u8, @intFromFloat(255.0 * (1.0 - @as(f32, @floatFromInt(diff)) / @as(f32, @floatFromInt(options.tolerance + 1)))))
                    else
                        @as(u8, 255);

                    selection.setValue(@intCast(x), @intCast(y), alpha);
                }
            }
        }
    }

    selection.recalculateBounds();
    return selection;
}

fn colorDifference(c1: Color, c2: Color) u8 {
    const dr = @as(i32, @intCast(c1.r)) - @as(i32, @intCast(c2.r));
    const dg = @as(i32, @intCast(c1.g)) - @as(i32, @intCast(c2.g));
    const db = @as(i32, @intCast(c1.b)) - @as(i32, @intCast(c2.b));
    const da = @as(i32, @intCast(c1.a)) - @as(i32, @intCast(c2.a));

    // Weighted euclidean distance
    const sum = (dr * dr + dg * dg + db * db + da * da);
    const dist = @sqrt(@as(f32, @floatFromInt(sum)));
    return @intFromFloat(@min(255.0, dist));
}

// ============================================================================
// Select by Color Range
// ============================================================================

pub const ColorRangeOptions = struct {
    fuzziness: u8 = 40,
    range: ?ColorRange = null,
    localized_color_clusters: bool = false,
};

pub const ColorRange = struct {
    hue_min: f32 = 0,
    hue_max: f32 = 360,
    saturation_min: f32 = 0,
    saturation_max: f32 = 1,
    lightness_min: f32 = 0,
    lightness_max: f32 = 1,
};

pub fn selectByColorRange(allocator: std.mem.Allocator, img: *const Image, sample_color: Color, options: ColorRangeOptions) !Selection {
    var selection = try Selection.init(allocator, img.width, img.height);

    const sample_hsl = rgbToHsl(sample_color);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y));
            const hsl = rgbToHsl(color);

            var in_range = true;
            var closeness: f32 = 1.0;

            if (options.range) |range| {
                // Check if color is in specified range
                var hue_ok = hsl[0] >= range.hue_min and hsl[0] <= range.hue_max;
                // Handle hue wraparound
                if (range.hue_min > range.hue_max) {
                    hue_ok = hsl[0] >= range.hue_min or hsl[0] <= range.hue_max;
                }

                in_range = hue_ok and
                    hsl[1] >= range.saturation_min and hsl[1] <= range.saturation_max and
                    hsl[2] >= range.lightness_min and hsl[2] <= range.lightness_max;
            }

            // Calculate similarity to sample color
            const hue_diff = @min(@abs(hsl[0] - sample_hsl[0]), 360 - @abs(hsl[0] - sample_hsl[0])) / 180.0;
            const sat_diff = @abs(hsl[1] - sample_hsl[1]);
            const light_diff = @abs(hsl[2] - sample_hsl[2]);

            const total_diff = (hue_diff + sat_diff + light_diff) / 3.0;
            const fuzz = @as(f32, @floatFromInt(options.fuzziness)) / 100.0;

            if (total_diff <= fuzz and in_range) {
                closeness = 1.0 - (total_diff / fuzz);
                selection.setValue(@intCast(x), @intCast(y), @intFromFloat(closeness * 255.0));
            }
        }
    }

    selection.recalculateBounds();
    return selection;
}

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

// ============================================================================
// Lasso Selection (Polygon)
// ============================================================================

pub const LassoPoint = struct {
    x: f32,
    y: f32,
};

pub fn lassoSelect(allocator: std.mem.Allocator, width: u32, height: u32, points: []const LassoPoint, anti_alias: bool) !Selection {
    var selection = try Selection.init(allocator, width, height);

    if (points.len < 3) return selection;

    // Scanline polygon fill
    for (0..height) |y| {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;

        // Find intersections with polygon edges
        var intersections = std.ArrayList(f32).init(allocator);
        defer intersections.deinit();

        for (0..points.len) |i| {
            const p1 = points[i];
            const p2 = points[(i + 1) % points.len];

            // Check if scanline intersects this edge
            if ((p1.y <= fy and p2.y > fy) or (p2.y <= fy and p1.y > fy)) {
                const t = (fy - p1.y) / (p2.y - p1.y);
                const x = p1.x + t * (p2.x - p1.x);
                try intersections.append(x);
            }
        }

        // Sort intersections
        std.mem.sort(f32, intersections.items, {}, std.sort.asc(f32));

        // Fill between pairs of intersections
        var i: usize = 0;
        while (i + 1 < intersections.items.len) : (i += 2) {
            const x1 = @max(0, @as(i32, @intFromFloat(intersections.items[i])));
            const x2 = @min(@as(i32, @intCast(width - 1)), @as(i32, @intFromFloat(intersections.items[i + 1])));

            var x = x1;
            while (x <= x2) : (x += 1) {
                var alpha: u8 = 255;

                if (anti_alias) {
                    // Simple anti-aliasing at edges
                    const fx = @as(f32, @floatFromInt(x));
                    if (fx < intersections.items[i] + 1) {
                        alpha = @intFromFloat((fx - intersections.items[i] + 1) * 255);
                    } else if (fx > intersections.items[i + 1] - 1) {
                        alpha = @intFromFloat((intersections.items[i + 1] - fx + 1) * 255);
                    }
                }

                selection.setValue(@intCast(x), @intCast(y), alpha);
            }
        }
    }

    selection.recalculateBounds();
    return selection;
}

// ============================================================================
// Rectangular Selection
// ============================================================================

pub fn rectangularSelect(allocator: std.mem.Allocator, width: u32, height: u32, x: u32, y: u32, sel_width: u32, sel_height: u32, feather: u32) !Selection {
    var selection = try Selection.init(allocator, width, height);

    const x2 = @min(x + sel_width, width);
    const y2 = @min(y + sel_height, height);

    for (y..y2) |py| {
        for (x..x2) |px| {
            var alpha: u8 = 255;

            if (feather > 0) {
                // Calculate distance to edge
                const dist_left = px - x;
                const dist_right = x2 - 1 - px;
                const dist_top = py - y;
                const dist_bottom = y2 - 1 - py;
                const min_dist = @min(@min(dist_left, dist_right), @min(dist_top, dist_bottom));

                if (min_dist < feather) {
                    alpha = @intFromFloat(@as(f32, @floatFromInt(min_dist)) / @as(f32, @floatFromInt(feather)) * 255.0);
                }
            }

            selection.setValue(@intCast(px), @intCast(py), alpha);
        }
    }

    selection.recalculateBounds();
    return selection;
}

// ============================================================================
// Elliptical Selection
// ============================================================================

pub fn ellipticalSelect(allocator: std.mem.Allocator, width: u32, height: u32, center_x: f32, center_y: f32, radius_x: f32, radius_y: f32, feather: u32, anti_alias: bool) !Selection {
    var selection = try Selection.init(allocator, width, height);

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;

            // Normalized distance from center
            const dx = (fx - center_x) / radius_x;
            const dy = (fy - center_y) / radius_y;
            const dist = @sqrt(dx * dx + dy * dy);

            if (dist <= 1.0) {
                var alpha: u8 = 255;

                if (feather > 0) {
                    const feather_start = 1.0 - @as(f32, @floatFromInt(feather)) / @min(radius_x, radius_y);
                    if (dist > feather_start) {
                        alpha = @intFromFloat((1.0 - (dist - feather_start) / (1.0 - feather_start)) * 255.0);
                    }
                } else if (anti_alias and dist > 0.9) {
                    alpha = @intFromFloat((1.0 - (dist - 0.9) / 0.1) * 255.0);
                }

                selection.setValue(@intCast(x), @intCast(y), alpha);
            }
        }
    }

    selection.recalculateBounds();
    return selection;
}

// ============================================================================
// Feather Selection
// ============================================================================

pub fn featherSelection(selection: *Selection, radius: u32) !void {
    if (radius == 0) return;

    // Apply Gaussian blur to the selection mask
    const kernel_size = radius * 2 + 1;
    var kernel = try selection.allocator.alloc(f32, kernel_size);
    defer selection.allocator.free(kernel);

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
    var temp = try selection.allocator.alloc(u8, selection.width * selection.height);
    defer selection.allocator.free(temp);

    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            var val: f32 = 0;
            for (0..kernel_size) |k| {
                const kx = @as(i32, @intCast(x)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const sx = @as(u32, @intCast(std.math.clamp(kx, 0, @as(i32, @intCast(selection.width - 1)))));
                val += @as(f32, @floatFromInt(selection.getValue(sx, @intCast(y)))) * kernel[k];
            }
            temp[y * selection.width + x] = @intFromFloat(std.math.clamp(val, 0, 255));
        }
    }

    // Vertical pass
    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            var val: f32 = 0;
            for (0..kernel_size) |k| {
                const ky = @as(i32, @intCast(y)) + @as(i32, @intCast(k)) - @as(i32, @intCast(radius));
                const sy = @as(u32, @intCast(std.math.clamp(ky, 0, @as(i32, @intCast(selection.height - 1)))));
                val += @as(f32, @floatFromInt(temp[sy * selection.width + x])) * kernel[k];
            }
            selection.setValue(@intCast(x), @intCast(y), @intFromFloat(std.math.clamp(val, 0, 255)));
        }
    }

    selection.recalculateBounds();
}

// ============================================================================
// Grow / Shrink Selection
// ============================================================================

pub fn growSelection(selection: *Selection, amount: u32) !void {
    if (amount == 0) return;

    var new_mask = try selection.allocator.alloc(u8, selection.width * selection.height);
    defer selection.allocator.free(new_mask);
    @memcpy(new_mask, selection.mask);

    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            if (selection.getValue(@intCast(x), @intCast(y)) > 0) {
                // Expand to neighbors within radius
                var dy: i32 = -@as(i32, @intCast(amount));
                while (dy <= @as(i32, @intCast(amount))) : (dy += 1) {
                    var dx: i32 = -@as(i32, @intCast(amount));
                    while (dx <= @as(i32, @intCast(amount))) : (dx += 1) {
                        const dist_sq = dx * dx + dy * dy;
                        if (dist_sq <= @as(i32, @intCast(amount * amount))) {
                            const nx = @as(i32, @intCast(x)) + dx;
                            const ny = @as(i32, @intCast(y)) + dy;
                            if (nx >= 0 and ny >= 0 and nx < selection.width and ny < selection.height) {
                                const idx = @as(usize, @intCast(ny)) * selection.width + @as(usize, @intCast(nx));
                                new_mask[idx] = 255;
                            }
                        }
                    }
                }
            }
        }
    }

    @memcpy(selection.mask, new_mask);
    selection.recalculateBounds();
}

pub fn shrinkSelection(selection: *Selection, amount: u32) !void {
    if (amount == 0) return;

    var new_mask = try selection.allocator.alloc(u8, selection.width * selection.height);
    defer selection.allocator.free(new_mask);
    @memset(new_mask, 0);

    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            if (selection.getValue(@intCast(x), @intCast(y)) > 0) {
                // Check if all pixels within radius are selected
                var all_selected = true;

                outer: {
                    var dy: i32 = -@as(i32, @intCast(amount));
                    while (dy <= @as(i32, @intCast(amount))) : (dy += 1) {
                        var dx: i32 = -@as(i32, @intCast(amount));
                        while (dx <= @as(i32, @intCast(amount))) : (dx += 1) {
                            const dist_sq = dx * dx + dy * dy;
                            if (dist_sq <= @as(i32, @intCast(amount * amount))) {
                                const nx = @as(i32, @intCast(x)) + dx;
                                const ny = @as(i32, @intCast(y)) + dy;
                                if (nx < 0 or ny < 0 or nx >= selection.width or ny >= selection.height) {
                                    all_selected = false;
                                    break :outer;
                                }
                                if (selection.getValue(@intCast(nx), @intCast(ny)) == 0) {
                                    all_selected = false;
                                    break :outer;
                                }
                            }
                        }
                    }
                }

                if (all_selected) {
                    new_mask[y * selection.width + x] = 255;
                }
            }
        }
    }

    @memcpy(selection.mask, new_mask);
    selection.recalculateBounds();
}

// ============================================================================
// Border Selection
// ============================================================================

pub fn borderSelection(selection: *Selection, width_amount: u32) !void {
    if (width_amount == 0) return;

    var original = try selection.clone();
    defer original.deinit();

    // Shrink the selection
    try shrinkSelection(selection, width_amount);

    // Subtract from original to get border
    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            const orig = original.getValue(@intCast(x), @intCast(y));
            const shrunk = selection.getValue(@intCast(x), @intCast(y));
            selection.setValue(@intCast(x), @intCast(y), if (orig > 0 and shrunk == 0) @as(u8, 255) else 0);
        }
    }

    selection.recalculateBounds();
}

// ============================================================================
// Selection from Image
// ============================================================================

pub fn selectionFromAlpha(allocator: std.mem.Allocator, img: *const Image) !Selection {
    var selection = try Selection.init(allocator, img.width, img.height);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y));
            selection.setValue(@intCast(x), @intCast(y), color.a);
        }
    }

    selection.recalculateBounds();
    return selection;
}

pub fn selectionFromLuminosity(allocator: std.mem.Allocator, img: *const Image) !Selection {
    var selection = try Selection.init(allocator, img.width, img.height);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y));
            // Luminosity formula
            const lum = @as(f32, @floatFromInt(color.r)) * 0.299 +
                @as(f32, @floatFromInt(color.g)) * 0.587 +
                @as(f32, @floatFromInt(color.b)) * 0.114;
            selection.setValue(@intCast(x), @intCast(y), @intFromFloat(lum));
        }
    }

    selection.recalculateBounds();
    return selection;
}

pub fn selectionFromChannel(allocator: std.mem.Allocator, img: *const Image, channel: enum { red, green, blue, alpha }) !Selection {
    var selection = try Selection.init(allocator, img.width, img.height);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y));
            const value = switch (channel) {
                .red => color.r,
                .green => color.g,
                .blue => color.b,
                .alpha => color.a,
            };
            selection.setValue(@intCast(x), @intCast(y), value);
        }
    }

    selection.recalculateBounds();
    return selection;
}

// ============================================================================
// Apply Selection to Image
// ============================================================================

pub fn applySelectionMask(img: *Image, selection: *const Selection) void {
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const sel_alpha = selection.getValue(@intCast(x), @intCast(y));
            if (sel_alpha < 255) {
                const color = img.getPixel(@intCast(x), @intCast(y));
                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * @as(f32, @floatFromInt(sel_alpha)) / 255.0),
                });
            }
        }
    }
}

pub fn extractSelection(allocator: std.mem.Allocator, img: *const Image, selection: *const Selection) !Image {
    const bounds = selection.bounds;
    if (bounds.isEmpty()) {
        return Image.create(allocator, 1, 1, .rgba);
    }

    var result = try Image.create(allocator, bounds.width, bounds.height, .rgba);

    for (0..bounds.height) |y| {
        for (0..bounds.width) |x| {
            const src_x = bounds.x + @as(u32, @intCast(x));
            const src_y = bounds.y + @as(u32, @intCast(y));

            const sel_alpha = selection.getValue(src_x, src_y);
            if (sel_alpha > 0) {
                const color = img.getPixel(src_x, src_y);
                result.setPixel(@intCast(x), @intCast(y), Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * @as(f32, @floatFromInt(sel_alpha)) / 255.0),
                });
            }
        }
    }

    return result;
}

// ============================================================================
// Marching Ants (Selection Border Visualization)
// ============================================================================

pub fn drawMarchingAnts(img: *Image, selection: *const Selection, frame: u32, color1: Color, color2: Color) void {
    const dash_length: u32 = 4;

    for (0..selection.height) |y| {
        for (0..selection.width) |x| {
            const sel = selection.getValue(@intCast(x), @intCast(y));
            if (sel == 0) continue;

            // Check if this is a border pixel
            var is_border = false;
            if (x > 0 and selection.getValue(@intCast(x - 1), @intCast(y)) == 0) is_border = true;
            if (x < selection.width - 1 and selection.getValue(@intCast(x + 1), @intCast(y)) == 0) is_border = true;
            if (y > 0 and selection.getValue(@intCast(x), @intCast(y - 1)) == 0) is_border = true;
            if (y < selection.height - 1 and selection.getValue(@intCast(x), @intCast(y + 1)) == 0) is_border = true;

            if (is_border) {
                // Animated dash pattern
                const pos = (x + y + frame) % (dash_length * 2);
                const color = if (pos < dash_length) color1 else color2;
                if (x < img.width and y < img.height) {
                    img.setPixel(@intCast(x), @intCast(y), color);
                }
            }
        }
    }
}
