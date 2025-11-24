const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Text Region Detection (Edge-Based, No ML)
// ============================================================================

pub const TextRegion = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    confidence: f32, // 0-1
    orientation: f32, // radians
    average_char_height: f32,
    average_char_width: f32,
};

pub const TextDetectionOptions = struct {
    min_text_height: u32 = 8,
    max_text_height: u32 = 200,
    min_text_width: u32 = 20,
    edge_threshold: u8 = 30,
    merge_threshold: u32 = 10,
    aspect_ratio_min: f32 = 0.1,
    aspect_ratio_max: f32 = 20.0,
};

pub fn detectTextRegions(allocator: std.mem.Allocator, img: *const Image, options: TextDetectionOptions) ![]TextRegion {
    // Convert to grayscale
    var gray = try allocator.alloc(u8, img.width * img.height);
    defer allocator.free(gray);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;
            gray[y * img.width + x] = @intFromFloat(
                @as(f32, @floatFromInt(color.r)) * 0.299 +
                    @as(f32, @floatFromInt(color.g)) * 0.587 +
                    @as(f32, @floatFromInt(color.b)) * 0.114,
            );
        }
    }

    // Edge detection (Sobel)
    var edges = try detectEdges(allocator, gray, img.width, img.height, options.edge_threshold);
    defer allocator.free(edges);

    // Stroke Width Transform
    var swt = try strokeWidthTransform(allocator, edges, gray, img.width, img.height);
    defer allocator.free(swt);

    // Connected component analysis
    var components = try findConnectedComponents(allocator, swt, img.width, img.height);
    defer {
        for (components) |*c| {
            allocator.free(c.pixels);
        }
        allocator.free(components);
    }

    // Filter and group components into text regions
    var regions = std.ArrayList(TextRegion).init(allocator);
    errdefer regions.deinit();

    var used = try allocator.alloc(bool, components.len);
    defer allocator.free(used);
    @memset(used, false);

    for (components, 0..) |comp, i| {
        if (used[i]) continue;
        if (comp.width < options.min_text_width or comp.height < options.min_text_height) continue;
        if (comp.height > options.max_text_height) continue;

        const aspect = @as(f32, @floatFromInt(comp.width)) / @as(f32, @floatFromInt(comp.height));
        if (aspect < options.aspect_ratio_min or aspect > options.aspect_ratio_max) continue;

        // Try to merge with nearby similar components
        var region = TextRegion{
            .x = comp.min_x,
            .y = comp.min_y,
            .width = comp.width,
            .height = comp.height,
            .confidence = comp.confidence,
            .orientation = 0,
            .average_char_height = @floatFromInt(comp.height),
            .average_char_width = @floatFromInt(comp.width),
        };

        var merged_count: u32 = 1;
        used[i] = true;

        // Look for nearby components
        for (components, 0..) |other, j| {
            if (used[j] or i == j) continue;

            // Check if components are close and similar size
            const dist_x = if (other.min_x > region.x + region.width)
                other.min_x - (region.x + region.width)
            else if (region.x > other.min_x + other.width)
                region.x - (other.min_x + other.width)
            else
                0;

            const dist_y = if (other.min_y > region.y + region.height)
                other.min_y - (region.y + region.height)
            else if (region.y > other.min_y + other.height)
                region.y - (other.min_y + other.height)
            else
                0;

            if (dist_x <= options.merge_threshold and dist_y <= options.merge_threshold) {
                // Check height similarity (likely same line of text)
                const height_ratio = @as(f32, @floatFromInt(other.height)) / @as(f32, @floatFromInt(region.height));
                if (height_ratio > 0.5 and height_ratio < 2.0) {
                    // Merge bounding boxes
                    const new_min_x = @min(region.x, other.min_x);
                    const new_min_y = @min(region.y, other.min_y);
                    const new_max_x = @max(region.x + region.width, other.min_x + other.width);
                    const new_max_y = @max(region.y + region.height, other.min_y + other.height);

                    region.x = new_min_x;
                    region.y = new_min_y;
                    region.width = new_max_x - new_min_x;
                    region.height = new_max_y - new_min_y;
                    region.confidence = (region.confidence * @as(f32, @floatFromInt(merged_count)) + other.confidence) / @as(f32, @floatFromInt(merged_count + 1));
                    merged_count += 1;
                    used[j] = true;
                }
            }
        }

        // Only add if merged with at least one other component (likely a word)
        if (merged_count >= 2) {
            try regions.append(region);
        }
    }

    return regions.toOwnedSlice();
}

fn detectEdges(allocator: std.mem.Allocator, gray: []const u8, width: u32, height: u32, threshold: u8) ![]u8 {
    var edges = try allocator.alloc(u8, width * height);
    @memset(edges, 0);

    // Sobel operator
    for (1..height - 1) |y| {
        for (1..width - 1) |x| {
            const idx = y * width + x;

            // Sobel X
            var gx: i32 = 0;
            gx += @as(i32, gray[(y - 1) * width + (x + 1)]);
            gx += 2 * @as(i32, gray[y * width + (x + 1)]);
            gx += @as(i32, gray[(y + 1) * width + (x + 1)]);
            gx -= @as(i32, gray[(y - 1) * width + (x - 1)]);
            gx -= 2 * @as(i32, gray[y * width + (x - 1)]);
            gx -= @as(i32, gray[(y + 1) * width + (x - 1)]);

            // Sobel Y
            var gy: i32 = 0;
            gy += @as(i32, gray[(y + 1) * width + (x - 1)]);
            gy += 2 * @as(i32, gray[(y + 1) * width + x]);
            gy += @as(i32, gray[(y + 1) * width + (x + 1)]);
            gy -= @as(i32, gray[(y - 1) * width + (x - 1)]);
            gy -= 2 * @as(i32, gray[(y - 1) * width + x]);
            gy -= @as(i32, gray[(y - 1) * width + (x + 1)]);

            const magnitude = @as(u32, @intCast(@abs(gx) + @abs(gy))) / 4;
            edges[idx] = if (magnitude > threshold) @intCast(@min(255, magnitude)) else 0;
        }
    }

    return edges;
}

fn strokeWidthTransform(allocator: std.mem.Allocator, edges: []const u8, gray: []const u8, width: u32, height: u32) ![]f32 {
    var swt = try allocator.alloc(f32, width * height);
    for (swt) |*v| v.* = std.math.inf(f32);

    // Simplified SWT: for each edge pixel, trace in gradient direction
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;
            if (edges[idx] < 30) continue;

            // Calculate gradient direction
            if (x == 0 or y == 0 or x >= width - 1 or y >= height - 1) continue;

            const gx = @as(i32, gray[idx + 1]) - @as(i32, gray[idx - 1]);
            const gy = @as(i32, gray[idx + width]) - @as(i32, gray[idx - width]);

            if (gx == 0 and gy == 0) continue;

            const len = @sqrt(@as(f32, @floatFromInt(gx * gx + gy * gy)));
            const dx = @as(f32, @floatFromInt(gx)) / len;
            const dy = @as(f32, @floatFromInt(gy)) / len;

            // Trace ray
            var ray_x = @as(f32, @floatFromInt(x)) + dx;
            var ray_y = @as(f32, @floatFromInt(y)) + dy;
            var stroke_width: f32 = 0;
            const max_stroke: f32 = 100;

            while (stroke_width < max_stroke) {
                const rx = @as(u32, @intFromFloat(ray_x));
                const ry = @as(u32, @intFromFloat(ray_y));

                if (rx >= width or ry >= height) break;

                const ray_idx = ry * width + rx;
                if (edges[ray_idx] > 0) {
                    // Found opposite edge
                    swt[idx] = @min(swt[idx], stroke_width);
                    break;
                }

                ray_x += dx;
                ray_y += dy;
                stroke_width += 1;
            }
        }
    }

    _ = gray;
    return swt;
}

const Component = struct {
    pixels: []usize,
    min_x: u32,
    min_y: u32,
    width: u32,
    height: u32,
    confidence: f32,
};

fn findConnectedComponents(allocator: std.mem.Allocator, swt: []const f32, width: u32, height: u32) ![]Component {
    var labels = try allocator.alloc(u32, width * height);
    defer allocator.free(labels);
    @memset(labels, 0);

    var next_label: u32 = 1;
    var component_pixels = std.ArrayList(std.ArrayList(usize)).init(allocator);
    defer {
        for (component_pixels.items) |list| {
            list.deinit();
        }
        component_pixels.deinit();
    }

    // Connected component labeling
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;
            if (std.math.isInf(swt[idx]) or swt[idx] > 50) continue;
            if (labels[idx] != 0) continue;

            // Start new component
            var pixels = std.ArrayList(usize).init(allocator);
            var stack = std.ArrayList(usize).init(allocator);
            defer stack.deinit();

            try stack.append(idx);
            labels[idx] = next_label;

            while (stack.items.len > 0) {
                const current = stack.pop();
                try pixels.append(current);

                const cx = current % width;
                const cy = current / width;

                // Check 8-connected neighbors
                const neighbors = [_][2]i32{
                    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
                    .{ -1, 0 },             .{ 1, 0 },
                    .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
                };

                for (neighbors) |n| {
                    const nx = @as(i32, @intCast(cx)) + n[0];
                    const ny = @as(i32, @intCast(cy)) + n[1];

                    if (nx < 0 or ny < 0 or nx >= width or ny >= height) continue;

                    const nidx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (labels[nidx] != 0) continue;
                    if (std.math.isInf(swt[nidx]) or swt[nidx] > 50) continue;

                    // Check SWT similarity
                    const ratio = swt[current] / swt[nidx];
                    if (ratio < 0.5 or ratio > 2.0) continue;

                    labels[nidx] = next_label;
                    try stack.append(nidx);
                }
            }

            if (pixels.items.len >= 10) {
                try component_pixels.append(pixels);
                next_label += 1;
            } else {
                pixels.deinit();
            }
        }
    }

    // Build component structures
    var components = try allocator.alloc(Component, component_pixels.items.len);

    for (component_pixels.items, 0..) |pixels, i| {
        var min_x: u32 = width;
        var min_y: u32 = height;
        var max_x: u32 = 0;
        var max_y: u32 = 0;

        for (pixels.items) |idx| {
            const px = @as(u32, @intCast(idx % width));
            const py = @as(u32, @intCast(idx / width));
            min_x = @min(min_x, px);
            min_y = @min(min_y, py);
            max_x = @max(max_x, px);
            max_y = @max(max_y, py);
        }

        const comp_width = if (max_x >= min_x) max_x - min_x + 1 else 0;
        const comp_height = if (max_y >= min_y) max_y - min_y + 1 else 0;

        components[i] = Component{
            .pixels = try pixels.toOwnedSlice(),
            .min_x = min_x,
            .min_y = min_y,
            .width = comp_width,
            .height = comp_height,
            .confidence = @min(1.0, @as(f32, @floatFromInt(pixels.items.len)) / 100.0),
        };
    }

    return components;
}

// ============================================================================
// Line Detection (Hough Transform)
// ============================================================================

pub const Line = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    strength: f32,
};

pub fn detectLines(allocator: std.mem.Allocator, img: *const Image, threshold: u32) ![]Line {
    // Convert to grayscale
    var gray = try allocator.alloc(u8, img.width * img.height);
    defer allocator.free(gray);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const color = img.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;
            gray[y * img.width + x] = @intFromFloat(
                @as(f32, @floatFromInt(color.r)) * 0.299 +
                    @as(f32, @floatFromInt(color.g)) * 0.587 +
                    @as(f32, @floatFromInt(color.b)) * 0.114,
            );
        }
    }

    // Edge detection
    var edges = try detectEdges(allocator, gray, img.width, img.height, 50);
    defer allocator.free(edges);

    // Hough transform
    const max_dist = @sqrt(@as(f32, @floatFromInt(img.width * img.width + img.height * img.height)));
    const num_rho: usize = @intFromFloat(max_dist * 2);
    const num_theta: usize = 180;

    var accumulator = try allocator.alloc(u32, num_rho * num_theta);
    defer allocator.free(accumulator);
    @memset(accumulator, 0);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            if (edges[y * img.width + x] == 0) continue;

            for (0..num_theta) |theta_idx| {
                const theta = @as(f32, @floatFromInt(theta_idx)) * std.math.pi / @as(f32, @floatFromInt(num_theta));
                const rho = @as(f32, @floatFromInt(x)) * @cos(theta) + @as(f32, @floatFromInt(y)) * @sin(theta);
                const rho_idx = @as(usize, @intFromFloat(rho + max_dist));

                if (rho_idx < num_rho) {
                    accumulator[rho_idx * num_theta + theta_idx] += 1;
                }
            }
        }
    }

    // Find peaks
    var lines = std.ArrayList(Line).init(allocator);
    errdefer lines.deinit();

    for (0..num_rho) |rho_idx| {
        for (0..num_theta) |theta_idx| {
            const votes = accumulator[rho_idx * num_theta + theta_idx];
            if (votes < threshold) continue;

            const rho = @as(f32, @floatFromInt(rho_idx)) - max_dist;
            const theta = @as(f32, @floatFromInt(theta_idx)) * std.math.pi / @as(f32, @floatFromInt(num_theta));

            // Convert to line endpoints
            const cos_t = @cos(theta);
            const sin_t = @sin(theta);

            var x1: f32 = 0;
            var y1: f32 = 0;
            var x2: f32 = 0;
            var y2: f32 = 0;

            if (@abs(sin_t) > 0.001) {
                x1 = 0;
                y1 = rho / sin_t;
                x2 = @floatFromInt(img.width);
                y2 = (rho - x2 * cos_t) / sin_t;
            } else {
                x1 = rho / cos_t;
                y1 = 0;
                x2 = x1;
                y2 = @floatFromInt(img.height);
            }

            try lines.append(Line{
                .x1 = x1,
                .y1 = y1,
                .x2 = x2,
                .y2 = y2,
                .strength = @as(f32, @floatFromInt(votes)) / @as(f32, @floatFromInt(threshold)),
            });
        }
    }

    return lines.toOwnedSlice();
}

// ============================================================================
// Character Segmentation Helper
// ============================================================================

pub fn segmentCharacters(allocator: std.mem.Allocator, img: *const Image, region: TextRegion) ![]Image {
    // Extract region
    const region_img = try allocator.create(Image);
    region_img.* = try Image.init(allocator, region.width, region.height, img.format);

    for (0..region.height) |y| {
        for (0..region.width) |x| {
            const src_x = region.x + @as(u32, @intCast(x));
            const src_y = region.y + @as(u32, @intCast(y));
            if (src_x < img.width and src_y < img.height) {
                region_img.setPixel(@intCast(x), @intCast(y), img.getPixel(src_x, src_y) orelse Color.WHITE);
            }
        }
    }

    // Threshold to binary
    for (0..region_img.height) |y| {
        for (0..region_img.width) |x| {
            const color = region_img.getPixel(@intCast(x), @intCast(y)) orelse Color.WHITE;
            const gray = @as(u8, @intFromFloat(
                @as(f32, @floatFromInt(color.r)) * 0.299 +
                    @as(f32, @floatFromInt(color.g)) * 0.587 +
                    @as(f32, @floatFromInt(color.b)) * 0.114,
            ));
            const bw = if (gray < 128) Color.BLACK else Color.WHITE;
            region_img.setPixel(@intCast(x), @intCast(y), bw);
        }
    }

    // Project onto X axis to find character boundaries
    var projection = try allocator.alloc(u32, region_img.width);
    defer allocator.free(projection);
    @memset(projection, 0);

    for (0..region_img.height) |y| {
        for (0..region_img.width) |x| {
            const color = region_img.getPixel(@intCast(x), @intCast(y)) orelse Color.WHITE;
            if (color.r == 0) {
                projection[x] += 1;
            }
        }
    }

    // Find gaps
    var chars = std.ArrayList(Image).init(allocator);
    errdefer {
        for (chars.items) |*c| c.deinit();
        chars.deinit();
    }

    var in_char = false;
    var char_start: u32 = 0;

    for (0..projection.len) |x| {
        if (projection[x] > 0 and !in_char) {
            in_char = true;
            char_start = @intCast(x);
        } else if (projection[x] == 0 and in_char) {
            in_char = false;
            const char_width = @as(u32, @intCast(x)) - char_start;
            if (char_width >= 3) {
                // Extract character
                var char_img = try Image.init(allocator, char_width, region_img.height, img.format);
                for (0..region_img.height) |cy| {
                    for (0..char_width) |cx| {
                        char_img.setPixel(@intCast(cx), @intCast(cy), region_img.getPixel(char_start + @as(u32, @intCast(cx)), @intCast(cy)) orelse Color.WHITE);
                    }
                }
                try chars.append(char_img);
            }
        }
    }

    region_img.deinit();
    allocator.destroy(region_img);

    return chars.toOwnedSlice();
}
