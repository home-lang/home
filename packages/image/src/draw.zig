// Drawing Primitives
// Lines, circles, rectangles, polygons, and basic text rendering

const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Line Drawing
// ============================================================================

/// Draw a line using Bresenham's algorithm
pub fn line(img: *Image, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
    var xa = x0;
    var ya = y0;
    const xb = x1;
    const yb = y1;

    const dx = @as(i32, @intCast(@abs(xb - xa)));
    const dy = -@as(i32, @intCast(@abs(yb - ya)));
    const sx: i32 = if (xa < xb) 1 else -1;
    const sy: i32 = if (ya < yb) 1 else -1;
    var err = dx + dy;

    while (true) {
        if (xa >= 0 and ya >= 0 and xa < img.width and ya < img.height) {
            img.setPixel(@intCast(xa), @intCast(ya), color);
        }

        if (xa == xb and ya == yb) break;

        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            xa += sx;
        }
        if (e2 <= dx) {
            err += dx;
            ya += sy;
        }
    }
}

/// Draw an anti-aliased line using Xiaolin Wu's algorithm
pub fn lineAA(img: *Image, x0: f32, y0: f32, x1: f32, y1: f32, color: Color) void {
    const steep = @abs(y1 - y0) > @abs(x1 - x0);

    var xa = if (steep) y0 else x0;
    var ya = if (steep) x0 else y0;
    var xb = if (steep) y1 else x1;
    var yb = if (steep) x1 else y1;

    if (xa > xb) {
        std.mem.swap(f32, &xa, &xb);
        std.mem.swap(f32, &ya, &yb);
    }

    const dx = xb - xa;
    const dy = yb - ya;
    const gradient = if (dx == 0) 1.0 else dy / dx;

    // First endpoint
    var xend = @round(xa);
    var yend = ya + gradient * (xend - xa);
    var xgap = 1.0 - fract(xa + 0.5);
    const xpxl1: i32 = @intFromFloat(xend);
    const ypxl1: i32 = @intFromFloat(yend);

    if (steep) {
        plotAA(img, ypxl1, xpxl1, color, (1.0 - fract(yend)) * xgap);
        plotAA(img, ypxl1 + 1, xpxl1, color, fract(yend) * xgap);
    } else {
        plotAA(img, xpxl1, ypxl1, color, (1.0 - fract(yend)) * xgap);
        plotAA(img, xpxl1, ypxl1 + 1, color, fract(yend) * xgap);
    }

    var intery = yend + gradient;

    // Second endpoint
    xend = @round(xb);
    yend = yb + gradient * (xend - xb);
    xgap = fract(xb + 0.5);
    const xpxl2: i32 = @intFromFloat(xend);
    const ypxl2: i32 = @intFromFloat(yend);

    if (steep) {
        plotAA(img, ypxl2, xpxl2, color, (1.0 - fract(yend)) * xgap);
        plotAA(img, ypxl2 + 1, xpxl2, color, fract(yend) * xgap);
    } else {
        plotAA(img, xpxl2, ypxl2, color, (1.0 - fract(yend)) * xgap);
        plotAA(img, xpxl2, ypxl2 + 1, color, fract(yend) * xgap);
    }

    // Main loop
    var x = xpxl1 + 1;
    while (x < xpxl2) : (x += 1) {
        const iy: i32 = @intFromFloat(intery);
        if (steep) {
            plotAA(img, iy, x, color, 1.0 - fract(intery));
            plotAA(img, iy + 1, x, color, fract(intery));
        } else {
            plotAA(img, x, iy, color, 1.0 - fract(intery));
            plotAA(img, x, iy + 1, color, fract(intery));
        }
        intery += gradient;
    }
}

fn fract(x: f32) f32 {
    return x - @floor(x);
}

fn plotAA(img: *Image, x: i32, y: i32, color: Color, brightness: f32) void {
    if (x < 0 or y < 0 or x >= img.width or y >= img.height) return;

    const existing = img.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;
    const alpha = @as(u8, @intFromFloat(brightness * 255));

    // Blend with existing pixel
    const inv_alpha = 255 - alpha;
    const blended = Color{
        .r = @intCast((@as(u16, color.r) * alpha + @as(u16, existing.r) * inv_alpha) / 255),
        .g = @intCast((@as(u16, color.g) * alpha + @as(u16, existing.g) * inv_alpha) / 255),
        .b = @intCast((@as(u16, color.b) * alpha + @as(u16, existing.b) * inv_alpha) / 255),
        .a = @max(existing.a, alpha),
    };

    img.setPixel(@intCast(x), @intCast(y), blended);
}

/// Draw a thick line
pub fn lineThick(img: *Image, x0: i32, y0: i32, x1: i32, y1: i32, thickness: u32, color: Color) void {
    if (thickness <= 1) {
        line(img, x0, y0, x1, y1, color);
        return;
    }

    const dx = @as(f32, @floatFromInt(x1 - x0));
    const dy = @as(f32, @floatFromInt(y1 - y0));
    const len = @sqrt(dx * dx + dy * dy);

    if (len == 0) {
        circleFilled(img, x0, y0, @intCast(thickness / 2), color);
        return;
    }

    // Perpendicular vector
    const px = -dy / len;
    const py = dx / len;

    const half_thick = @as(f32, @floatFromInt(thickness)) / 2.0;

    // Draw filled polygon for thick line
    const corners = [4][2]i32{
        .{ @intFromFloat(@as(f32, @floatFromInt(x0)) + px * half_thick), @intFromFloat(@as(f32, @floatFromInt(y0)) + py * half_thick) },
        .{ @intFromFloat(@as(f32, @floatFromInt(x0)) - px * half_thick), @intFromFloat(@as(f32, @floatFromInt(y0)) - py * half_thick) },
        .{ @intFromFloat(@as(f32, @floatFromInt(x1)) - px * half_thick), @intFromFloat(@as(f32, @floatFromInt(y1)) - py * half_thick) },
        .{ @intFromFloat(@as(f32, @floatFromInt(x1)) + px * half_thick), @intFromFloat(@as(f32, @floatFromInt(y1)) + py * half_thick) },
    };

    // Fill the quadrilateral
    polygonFilled(img, &corners, color);

    // Round caps
    circleFilled(img, x0, y0, @intCast(thickness / 2), color);
    circleFilled(img, x1, y1, @intCast(thickness / 2), color);
}

// ============================================================================
// Rectangle Drawing
// ============================================================================

/// Draw a rectangle outline
pub fn rect(img: *Image, x: i32, y: i32, width: u32, height: u32, color: Color) void {
    const x2 = x + @as(i32, @intCast(width)) - 1;
    const y2 = y + @as(i32, @intCast(height)) - 1;

    line(img, x, y, x2, y, color); // Top
    line(img, x, y2, x2, y2, color); // Bottom
    line(img, x, y, x, y2, color); // Left
    line(img, x2, y, x2, y2, color); // Right
}

/// Draw a filled rectangle
pub fn rectFilled(img: *Image, x: i32, y: i32, width: u32, height: u32, color: Color) void {
    const x_start: u32 = if (x < 0) 0 else @intCast(@min(x, @as(i32, @intCast(img.width))));
    const y_start: u32 = if (y < 0) 0 else @intCast(@min(y, @as(i32, @intCast(img.height))));
    const x_end: u32 = @intCast(@max(0, @min(x + @as(i32, @intCast(width)), @as(i32, @intCast(img.width)))));
    const y_end: u32 = @intCast(@max(0, @min(y + @as(i32, @intCast(height)), @as(i32, @intCast(img.height)))));

    var py = y_start;
    while (py < y_end) : (py += 1) {
        var px = x_start;
        while (px < x_end) : (px += 1) {
            img.setPixel(px, py, color);
        }
    }
}

/// Draw a rounded rectangle outline
pub fn rectRounded(img: *Image, x: i32, y: i32, width: u32, height: u32, radius: u32, color: Color) void {
    const r: i32 = @intCast(@min(radius, @min(width / 2, height / 2)));
    const x2 = x + @as(i32, @intCast(width)) - 1;
    const y2 = y + @as(i32, @intCast(height)) - 1;

    // Straight edges
    line(img, x + r, y, x2 - r, y, color); // Top
    line(img, x + r, y2, x2 - r, y2, color); // Bottom
    line(img, x, y + r, x, y2 - r, color); // Left
    line(img, x2, y + r, x2, y2 - r, color); // Right

    // Corner arcs
    arcQuarter(img, x + r, y + r, r, 2, color); // Top-left
    arcQuarter(img, x2 - r, y + r, r, 1, color); // Top-right
    arcQuarter(img, x + r, y2 - r, r, 3, color); // Bottom-left
    arcQuarter(img, x2 - r, y2 - r, r, 0, color); // Bottom-right
}

/// Draw a filled rounded rectangle
pub fn rectRoundedFilled(img: *Image, x: i32, y: i32, width: u32, height: u32, radius: u32, color: Color) void {
    const r: i32 = @intCast(@min(radius, @min(width / 2, height / 2)));

    // Main body
    rectFilled(img, x + r, y, width - @as(u32, @intCast(r)) * 2, height, color);
    rectFilled(img, x, y + r, width, height - @as(u32, @intCast(r)) * 2, color);

    // Corner circles
    const x2 = x + @as(i32, @intCast(width)) - 1;
    const y2 = y + @as(i32, @intCast(height)) - 1;
    circleFilled(img, x + r, y + r, @intCast(r), color);
    circleFilled(img, x2 - r, y + r, @intCast(r), color);
    circleFilled(img, x + r, y2 - r, @intCast(r), color);
    circleFilled(img, x2 - r, y2 - r, @intCast(r), color);
}

// ============================================================================
// Circle Drawing
// ============================================================================

/// Draw a circle outline using midpoint algorithm
pub fn circle(img: *Image, cx: i32, cy: i32, radius: u32, color: Color) void {
    if (radius == 0) {
        if (cx >= 0 and cy >= 0 and cx < img.width and cy < img.height) {
            img.setPixel(@intCast(cx), @intCast(cy), color);
        }
        return;
    }

    var x: i32 = @intCast(radius);
    var y: i32 = 0;
    var err: i32 = 0;

    while (x >= y) {
        plot8(img, cx, cy, x, y, color);
        y += 1;
        err += 1 + 2 * y;
        if (2 * (err - x) + 1 > 0) {
            x -= 1;
            err += 1 - 2 * x;
        }
    }
}

/// Draw a filled circle
pub fn circleFilled(img: *Image, cx: i32, cy: i32, radius: u32, color: Color) void {
    if (radius == 0) {
        if (cx >= 0 and cy >= 0 and cx < img.width and cy < img.height) {
            img.setPixel(@intCast(cx), @intCast(cy), color);
        }
        return;
    }

    var x: i32 = @intCast(radius);
    var y: i32 = 0;
    var err: i32 = 0;

    while (x >= y) {
        // Draw horizontal lines for each octant pair
        hline(img, cx - x, cx + x, cy + y, color);
        hline(img, cx - x, cx + x, cy - y, color);
        hline(img, cx - y, cx + y, cy + x, color);
        hline(img, cx - y, cx + y, cy - x, color);

        y += 1;
        err += 1 + 2 * y;
        if (2 * (err - x) + 1 > 0) {
            x -= 1;
            err += 1 - 2 * x;
        }
    }
}

/// Draw an anti-aliased circle outline
pub fn circleAA(img: *Image, cx: i32, cy: i32, radius: u32, color: Color) void {
    const r: f32 = @floatFromInt(radius);
    const r2 = r * r;

    var y: i32 = 0;
    while (y <= radius) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const x_exact = @sqrt(r2 - yf * yf);
        const x_floor: i32 = @intFromFloat(x_exact);
        const frac = x_exact - @floor(x_exact);

        // Plot with anti-aliasing
        plotAA(img, cx + x_floor, cy + y, color, 1.0 - frac);
        plotAA(img, cx + x_floor + 1, cy + y, color, frac);
        plotAA(img, cx - x_floor, cy + y, color, 1.0 - frac);
        plotAA(img, cx - x_floor - 1, cy + y, color, frac);
        plotAA(img, cx + x_floor, cy - y, color, 1.0 - frac);
        plotAA(img, cx + x_floor + 1, cy - y, color, frac);
        plotAA(img, cx - x_floor, cy - y, color, 1.0 - frac);
        plotAA(img, cx - x_floor - 1, cy - y, color, frac);
    }
}

fn plot8(img: *Image, cx: i32, cy: i32, x: i32, y: i32, color: Color) void {
    const points = [8][2]i32{
        .{ cx + x, cy + y },
        .{ cx - x, cy + y },
        .{ cx + x, cy - y },
        .{ cx - x, cy - y },
        .{ cx + y, cy + x },
        .{ cx - y, cy + x },
        .{ cx + y, cy - x },
        .{ cx - y, cy - x },
    };

    for (points) |p| {
        if (p[0] >= 0 and p[1] >= 0 and p[0] < img.width and p[1] < img.height) {
            img.setPixel(@intCast(p[0]), @intCast(p[1]), color);
        }
    }
}

fn hline(img: *Image, x1: i32, x2: i32, y: i32, color: Color) void {
    if (y < 0 or y >= img.height) return;

    const start: u32 = @intCast(@max(0, @min(x1, x2)));
    const end: u32 = @intCast(@min(@as(i32, @intCast(img.width)) - 1, @max(x1, x2)));

    var x = start;
    while (x <= end) : (x += 1) {
        img.setPixel(x, @intCast(y), color);
    }
}

fn arcQuarter(img: *Image, cx: i32, cy: i32, radius: i32, quadrant: u2, color: Color) void {
    var x: i32 = radius;
    var y: i32 = 0;
    var err: i32 = 0;

    while (x >= y) {
        const points: [2][2]i32 = switch (quadrant) {
            0 => .{ .{ cx + x, cy + y }, .{ cx + y, cy + x } }, // Bottom-right
            1 => .{ .{ cx + x, cy - y }, .{ cx + y, cy - x } }, // Top-right
            2 => .{ .{ cx - x, cy - y }, .{ cx - y, cy - x } }, // Top-left
            3 => .{ .{ cx - x, cy + y }, .{ cx - y, cy + x } }, // Bottom-left
        };

        for (points) |p| {
            if (p[0] >= 0 and p[1] >= 0 and p[0] < img.width and p[1] < img.height) {
                img.setPixel(@intCast(p[0]), @intCast(p[1]), color);
            }
        }

        y += 1;
        err += 1 + 2 * y;
        if (2 * (err - x) + 1 > 0) {
            x -= 1;
            err += 1 - 2 * x;
        }
    }
}

// ============================================================================
// Ellipse Drawing
// ============================================================================

/// Draw an ellipse outline
pub fn ellipse(img: *Image, cx: i32, cy: i32, rx: u32, ry: u32, color: Color) void {
    if (rx == 0 or ry == 0) {
        if (rx == 0) line(img, cx, cy - @as(i32, @intCast(ry)), cx, cy + @as(i32, @intCast(ry)), color);
        if (ry == 0) line(img, cx - @as(i32, @intCast(rx)), cy, cx + @as(i32, @intCast(rx)), cy, color);
        return;
    }

    const a: i64 = rx;
    const b: i64 = ry;
    var x: i64 = 0;
    var y: i64 = b;

    var a2 = a * a;
    var b2 = b * b;
    var err = b2 - (2 * b - 1) * a2;

    while (y >= 0) {
        plot4Ellipse(img, cx, cy, @intCast(x), @intCast(y), color);

        const e2 = 2 * err;
        if (e2 < (2 * x + 1) * b2) {
            x += 1;
            err += (2 * x + 1) * b2;
        }
        if (e2 > -(2 * y - 1) * a2) {
            y -= 1;
            err -= (2 * y - 1) * a2;
        }
    }
}

/// Draw a filled ellipse
pub fn ellipseFilled(img: *Image, cx: i32, cy: i32, rx: u32, ry: u32, color: Color) void {
    if (rx == 0 or ry == 0) {
        if (rx == 0) line(img, cx, cy - @as(i32, @intCast(ry)), cx, cy + @as(i32, @intCast(ry)), color);
        if (ry == 0) line(img, cx - @as(i32, @intCast(rx)), cy, cx + @as(i32, @intCast(rx)), cy, color);
        return;
    }

    const a: i64 = rx;
    const b: i64 = ry;
    var x: i64 = 0;
    var y: i64 = b;

    var a2 = a * a;
    var b2 = b * b;
    var err = b2 - (2 * b - 1) * a2;
    var last_y: i64 = y + 1;

    while (y >= 0) {
        if (y != last_y) {
            hline(img, cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy + @as(i32, @intCast(y)), color);
            hline(img, cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy - @as(i32, @intCast(y)), color);
            last_y = y;
        }

        const e2 = 2 * err;
        if (e2 < (2 * x + 1) * b2) {
            x += 1;
            err += (2 * x + 1) * b2;
        }
        if (e2 > -(2 * y - 1) * a2) {
            y -= 1;
            err -= (2 * y - 1) * a2;
        }
    }
}

fn plot4Ellipse(img: *Image, cx: i32, cy: i32, x: i32, y: i32, color: Color) void {
    const points = [4][2]i32{
        .{ cx + x, cy + y },
        .{ cx - x, cy + y },
        .{ cx + x, cy - y },
        .{ cx - x, cy - y },
    };

    for (points) |p| {
        if (p[0] >= 0 and p[1] >= 0 and p[0] < img.width and p[1] < img.height) {
            img.setPixel(@intCast(p[0]), @intCast(p[1]), color);
        }
    }
}

// ============================================================================
// Polygon Drawing
// ============================================================================

/// Draw a polygon outline
pub fn polygon(img: *Image, points: []const [2]i32, color: Color) void {
    if (points.len < 2) return;

    for (0..points.len) |i| {
        const next = (i + 1) % points.len;
        line(img, points[i][0], points[i][1], points[next][0], points[next][1], color);
    }
}

/// Draw a filled polygon using scanline algorithm
pub fn polygonFilled(img: *Image, points: []const [2]i32, color: Color) void {
    if (points.len < 3) return;

    // Find bounding box
    var min_y: i32 = points[0][1];
    var max_y: i32 = points[0][1];
    for (points) |p| {
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }

    min_y = @max(0, min_y);
    max_y = @min(@as(i32, @intCast(img.height)) - 1, max_y);

    // Scanline fill
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var intersections: [64]i32 = undefined;
        var count: usize = 0;

        // Find intersections with edges
        for (0..points.len) |i| {
            const next = (i + 1) % points.len;
            const y1 = points[i][1];
            const y2 = points[next][1];

            if ((y1 <= y and y < y2) or (y2 <= y and y < y1)) {
                const x1 = points[i][0];
                const x2 = points[next][0];
                const x_intersect = x1 + @divTrunc((y - y1) * (x2 - x1), (y2 - y1));
                if (count < intersections.len) {
                    intersections[count] = x_intersect;
                    count += 1;
                }
            }
        }

        // Sort intersections
        std.mem.sort(i32, intersections[0..count], {}, std.sort.asc(i32));

        // Fill between pairs
        var i: usize = 0;
        while (i + 1 < count) : (i += 2) {
            hline(img, intersections[i], intersections[i + 1], y, color);
        }
    }
}

/// Draw a regular polygon (triangle, pentagon, hexagon, etc.)
pub fn regularPolygon(img: *Image, cx: i32, cy: i32, radius: u32, sides: u8, rotation: f32, color: Color) void {
    if (sides < 3) return;

    var points: [32][2]i32 = undefined;
    const n = @min(sides, 32);

    for (0..n) |i| {
        const angle = rotation + @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(n));
        points[i] = .{
            cx + @as(i32, @intFromFloat(@cos(angle) * @as(f32, @floatFromInt(radius)))),
            cy + @as(i32, @intFromFloat(@sin(angle) * @as(f32, @floatFromInt(radius)))),
        };
    }

    polygon(img, points[0..n], color);
}

// ============================================================================
// Arc and Bezier Curves
// ============================================================================

/// Draw an arc
pub fn arc(img: *Image, cx: i32, cy: i32, radius: u32, start_angle: f32, end_angle: f32, color: Color) void {
    const r: f32 = @floatFromInt(radius);
    const steps: u32 = @max(16, radius * 2);
    const step_angle = (end_angle - start_angle) / @as(f32, @floatFromInt(steps));

    var prev_x: i32 = cx + @as(i32, @intFromFloat(@cos(start_angle) * r));
    var prev_y: i32 = cy + @as(i32, @intFromFloat(@sin(start_angle) * r));

    var i: u32 = 1;
    while (i <= steps) : (i += 1) {
        const angle = start_angle + @as(f32, @floatFromInt(i)) * step_angle;
        const x: i32 = cx + @as(i32, @intFromFloat(@cos(angle) * r));
        const y: i32 = cy + @as(i32, @intFromFloat(@sin(angle) * r));

        line(img, prev_x, prev_y, x, y, color);
        prev_x = x;
        prev_y = y;
    }
}

/// Draw a quadratic Bezier curve
pub fn bezierQuadratic(img: *Image, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
    const steps: u32 = 64;

    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const t2 = t * t;
        const mt = 1.0 - t;
        const mt2 = mt * mt;

        const x: i32 = @intFromFloat(mt2 * @as(f32, @floatFromInt(x0)) + 2.0 * mt * t * @as(f32, @floatFromInt(x1)) + t2 * @as(f32, @floatFromInt(x2)));
        const y: i32 = @intFromFloat(mt2 * @as(f32, @floatFromInt(y0)) + 2.0 * mt * t * @as(f32, @floatFromInt(y1)) + t2 * @as(f32, @floatFromInt(y2)));

        line(img, prev_x, prev_y, x, y, color);
        prev_x = x;
        prev_y = y;
    }
}

/// Draw a cubic Bezier curve
pub fn bezierCubic(img: *Image, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, color: Color) void {
    const steps: u32 = 64;

    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const t2 = t * t;
        const t3 = t2 * t;
        const mt = 1.0 - t;
        const mt2 = mt * mt;
        const mt3 = mt2 * mt;

        const x: i32 = @intFromFloat(mt3 * @as(f32, @floatFromInt(x0)) + 3.0 * mt2 * t * @as(f32, @floatFromInt(x1)) + 3.0 * mt * t2 * @as(f32, @floatFromInt(x2)) + t3 * @as(f32, @floatFromInt(x3)));
        const y: i32 = @intFromFloat(mt3 * @as(f32, @floatFromInt(y0)) + 3.0 * mt2 * t * @as(f32, @floatFromInt(y1)) + 3.0 * mt * t2 * @as(f32, @floatFromInt(y2)) + t3 * @as(f32, @floatFromInt(y3)));

        line(img, prev_x, prev_y, x, y, color);
        prev_x = x;
        prev_y = y;
    }
}

// ============================================================================
// Flood Fill
// ============================================================================

/// Flood fill (bucket fill) using scanline algorithm
pub fn floodFill(img: *Image, start_x: u32, start_y: u32, fill_color: Color, allocator: std.mem.Allocator) !void {
    if (start_x >= img.width or start_y >= img.height) return;

    const target_color = img.getPixel(start_x, start_y) orelse return;
    if (target_color.eql(fill_color)) return;

    var stack = std.ArrayList([2]u32).init(allocator);
    defer stack.deinit();

    try stack.append(.{ start_x, start_y });

    while (stack.items.len > 0) {
        const pos = stack.pop();
        var x = pos[0];
        const y = pos[1];

        // Find left edge
        while (x > 0 and colorMatch(img.getPixel(x - 1, y), target_color)) {
            x -= 1;
        }

        var span_above = false;
        var span_below = false;

        while (x < img.width and colorMatch(img.getPixel(x, y), target_color)) {
            img.setPixel(x, y, fill_color);

            // Check above
            if (y > 0) {
                if (colorMatch(img.getPixel(x, y - 1), target_color)) {
                    if (!span_above) {
                        try stack.append(.{ x, y - 1 });
                        span_above = true;
                    }
                } else {
                    span_above = false;
                }
            }

            // Check below
            if (y < img.height - 1) {
                if (colorMatch(img.getPixel(x, y + 1), target_color)) {
                    if (!span_below) {
                        try stack.append(.{ x, y + 1 });
                        span_below = true;
                    }
                } else {
                    span_below = false;
                }
            }

            x += 1;
        }
    }
}

fn colorMatch(a: ?Color, b: Color) bool {
    if (a == null) return false;
    return a.?.r == b.r and a.?.g == b.g and a.?.b == b.b and a.?.a == b.a;
}

// ============================================================================
// Basic Text Rendering (Built-in 8x8 Font)
// ============================================================================

/// 8x8 bitmap font (ASCII 32-127)
const font_8x8 = @import("font_8x8.zig").font_data;

/// Draw a single character
pub fn char8x8(img: *Image, x: i32, y: i32, c: u8, color: Color) void {
    if (c < 32 or c > 127) return;

    const glyph = font_8x8[c - 32];

    for (0..8) |row| {
        const row_data = glyph[row];
        for (0..8) |col| {
            if ((row_data >> @intCast(7 - col)) & 1 == 1) {
                const px = x + @as(i32, @intCast(col));
                const py = y + @as(i32, @intCast(row));
                if (px >= 0 and py >= 0 and px < img.width and py < img.height) {
                    img.setPixel(@intCast(px), @intCast(py), color);
                }
            }
        }
    }
}

/// Draw a string
pub fn text8x8(img: *Image, x: i32, y: i32, str: []const u8, color: Color) void {
    var cx = x;
    for (str) |c| {
        if (c == '\n') {
            cx = x;
            continue;
        }
        char8x8(img, cx, y, c, color);
        cx += 8;
    }
}

/// Draw scaled text (integer scaling)
pub fn textScaled(img: *Image, x: i32, y: i32, str: []const u8, scale: u32, color: Color) void {
    if (scale == 0) return;

    var cx = x;
    for (str) |c| {
        if (c < 32 or c > 127) continue;

        const glyph = font_8x8[c - 32];

        for (0..8) |row| {
            const row_data = glyph[row];
            for (0..8) |col| {
                if ((row_data >> @intCast(7 - col)) & 1 == 1) {
                    // Draw scaled pixel
                    for (0..scale) |sy| {
                        for (0..scale) |sx| {
                            const px = cx + @as(i32, @intCast(col * scale + sx));
                            const py = y + @as(i32, @intCast(row * scale + sy));
                            if (px >= 0 and py >= 0 and px < img.width and py < img.height) {
                                img.setPixel(@intCast(px), @intCast(py), color);
                            }
                        }
                    }
                }
            }
        }

        cx += @intCast(8 * scale);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Line drawing" {
    var img = try Image.init(std.testing.allocator, 100, 100, .rgba8);
    defer img.deinit();

    line(&img, 0, 0, 99, 99, Color.RED);

    // Check that some pixels were drawn
    const pixel = img.getPixel(50, 50);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Circle drawing" {
    var img = try Image.init(std.testing.allocator, 100, 100, .rgba8);
    defer img.deinit();

    circle(&img, 50, 50, 25, Color.GREEN);

    // Check top of circle
    const pixel = img.getPixel(50, 25);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.g);
}

test "Filled rectangle" {
    var img = try Image.init(std.testing.allocator, 100, 100, .rgba8);
    defer img.deinit();

    rectFilled(&img, 10, 10, 20, 20, Color.BLUE);

    const pixel = img.getPixel(15, 15);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.b);
}
