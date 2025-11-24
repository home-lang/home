const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Vector Graphics Types
// ============================================================================

pub const Point = struct {
    x: f32,
    y: f32,

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Point, s: f32) Point {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn distance(self: Point, other: Point) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

pub const BezierCurve = struct {
    p0: Point, // Start
    p1: Point, // Control 1
    p2: Point, // Control 2 (for cubic)
    p3: Point, // End
    cubic: bool,

    pub fn quadratic(p0: Point, p1: Point, p2: Point) BezierCurve {
        return .{
            .p0 = p0,
            .p1 = p1,
            .p2 = p2,
            .p3 = p2,
            .cubic = false,
        };
    }

    pub fn cubicCurve(p0: Point, p1: Point, p2: Point, p3: Point) BezierCurve {
        return .{
            .p0 = p0,
            .p1 = p1,
            .p2 = p2,
            .p3 = p3,
            .cubic = true,
        };
    }

    pub fn evaluate(self: *const BezierCurve, t: f32) Point {
        const t_clamped = std.math.clamp(t, 0, 1);

        if (self.cubic) {
            // Cubic Bezier
            const mt = 1 - t_clamped;
            const mt2 = mt * mt;
            const mt3 = mt2 * mt;
            const t2 = t_clamped * t_clamped;
            const t3 = t2 * t_clamped;

            return Point{
                .x = mt3 * self.p0.x + 3 * mt2 * t_clamped * self.p1.x + 3 * mt * t2 * self.p2.x + t3 * self.p3.x,
                .y = mt3 * self.p0.y + 3 * mt2 * t_clamped * self.p1.y + 3 * mt * t2 * self.p2.y + t3 * self.p3.y,
            };
        } else {
            // Quadratic Bezier
            const mt = 1 - t_clamped;
            const mt2 = mt * mt;
            const t2 = t_clamped * t_clamped;

            return Point{
                .x = mt2 * self.p0.x + 2 * mt * t_clamped * self.p1.x + t2 * self.p2.x,
                .y = mt2 * self.p0.y + 2 * mt * t_clamped * self.p1.y + t2 * self.p2.y,
            };
        }
    }

    pub fn flatten(self: *const BezierCurve, allocator: std.mem.Allocator, tolerance: f32) ![]Point {
        var points = std.ArrayList(Point).init(allocator);
        errdefer points.deinit();

        try points.append(self.p0);
        try self.flattenRecursive(&points, 0, 1, tolerance);
        try points.append(if (self.cubic) self.p3 else self.p2);

        return points.toOwnedSlice();
    }

    fn flattenRecursive(self: *const BezierCurve, points: *std.ArrayList(Point), t0: f32, t1: f32, tolerance: f32) !void {
        const p0 = self.evaluate(t0);
        const p1 = self.evaluate(t1);
        const tmid = (t0 + t1) / 2;
        const pmid = self.evaluate(tmid);

        // Check if curve is flat enough
        const line_mid = Point{
            .x = (p0.x + p1.x) / 2,
            .y = (p0.y + p1.y) / 2,
        };

        const dist = pmid.distance(line_mid);

        if (dist < tolerance) {
            return;
        }

        try self.flattenRecursive(points, t0, tmid, tolerance);
        try points.append(pmid);
        try self.flattenRecursive(points, tmid, t1, tolerance);
    }
};

pub const Path = struct {
    points: std.ArrayList(Point),
    closed: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{
            .points = std.ArrayList(Point).init(allocator),
            .closed = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Path) void {
        self.points.deinit();
    }

    pub fn moveTo(self: *Path, x: f32, y: f32) !void {
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn lineTo(self: *Path, x: f32, y: f32) !void {
        try self.points.append(.{ .x = x, .y = y });
    }

    pub fn quadraticTo(self: *Path, cp_x: f32, cp_y: f32, x: f32, y: f32, tolerance: f32) !void {
        if (self.points.items.len == 0) return;

        const start = self.points.items[self.points.items.len - 1];
        const curve = BezierCurve.quadratic(
            start,
            .{ .x = cp_x, .y = cp_y },
            .{ .x = x, .y = y },
        );

        const flat_points = try curve.flatten(self.allocator, tolerance);
        defer self.allocator.free(flat_points);

        for (flat_points[1..]) |pt| {
            try self.points.append(pt);
        }
    }

    pub fn cubicTo(self: *Path, cp1_x: f32, cp1_y: f32, cp2_x: f32, cp2_y: f32, x: f32, y: f32, tolerance: f32) !void {
        if (self.points.items.len == 0) return;

        const start = self.points.items[self.points.items.len - 1];
        const curve = BezierCurve.cubicCurve(
            start,
            .{ .x = cp1_x, .y = cp1_y },
            .{ .x = cp2_x, .y = cp2_y },
            .{ .x = x, .y = y },
        );

        const flat_points = try curve.flatten(self.allocator, tolerance);
        defer self.allocator.free(flat_points);

        for (flat_points[1..]) |pt| {
            try self.points.append(pt);
        }
    }

    pub fn arc(self: *Path, cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32, segments: u32) !void {
        const angle_step = (end_angle - start_angle) / @as(f32, @floatFromInt(segments));

        for (0..segments + 1) |i| {
            const angle = start_angle + angle_step * @as(f32, @floatFromInt(i));
            const x = cx + radius * @cos(angle);
            const y = cy + radius * @sin(angle);
            try self.points.append(.{ .x = x, .y = y });
        }
    }

    pub fn close(self: *Path) void {
        self.closed = true;
    }

    pub fn getBounds(self: *const Path) ?struct { x: f32, y: f32, width: f32, height: f32 } {
        if (self.points.items.len == 0) return null;

        var min_x = self.points.items[0].x;
        var min_y = self.points.items[0].y;
        var max_x = min_x;
        var max_y = min_y;

        for (self.points.items[1..]) |pt| {
            min_x = @min(min_x, pt.x);
            min_y = @min(min_y, pt.y);
            max_x = @max(max_x, pt.x);
            max_y = @max(max_y, pt.y);
        }

        return .{
            .x = min_x,
            .y = min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
};

// ============================================================================
// Shape Drawing with Anti-Aliasing
// ============================================================================

pub const StrokeStyle = struct {
    width: f32 = 1.0,
    color: Color = Color.BLACK,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    miter_limit: f32 = 10.0,
};

pub const LineCap = enum {
    butt,
    round,
    square,
};

pub const LineJoin = enum {
    miter,
    round,
    bevel,
};

pub const FillStyle = struct {
    color: Color = Color.WHITE,
    fill_rule: FillRule = .non_zero,
};

pub const FillRule = enum {
    non_zero,
    even_odd,
};

pub fn strokePath(img: *Image, path: *const Path, style: StrokeStyle) !void {
    if (path.points.items.len < 2) return;

    const half_width = style.width / 2.0;

    for (0..path.points.items.len - 1) |i| {
        const p0 = path.points.items[i];
        const p1 = path.points.items[i + 1];
        try drawLineAA(img, p0.x, p0.y, p1.x, p1.y, style.color, style.width);
    }

    if (path.closed and path.points.items.len > 2) {
        const p0 = path.points.items[path.points.items.len - 1];
        const p1 = path.points.items[0];
        try drawLineAA(img, p0.x, p0.y, p1.x, p1.y, style.color, style.width);
    }

    _ = half_width;
}

pub fn fillPath(img: *Image, path: *const Path, style: FillStyle) !void {
    if (path.points.items.len < 3) return;

    const bounds = path.getBounds() orelse return;
    const min_y = @as(i32, @intFromFloat(@floor(bounds.y)));
    const max_y = @as(i32, @intFromFloat(@ceil(bounds.y + bounds.height)));

    // Scanline fill
    var y = @max(0, min_y);
    while (y <= @min(@as(i32, @intCast(img.height - 1)), max_y)) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;

        // Find intersections with scanline
        var intersections = std.ArrayList(f32).init(img.allocator);
        defer intersections.deinit();

        const n = path.points.items.len;
        for (0..n) |i| {
            const p0 = path.points.items[i];
            const p1 = if (path.closed) path.points.items[(i + 1) % n] else if (i + 1 < n) path.points.items[i + 1] else continue;

            if ((p0.y <= fy and p1.y > fy) or (p1.y <= fy and p0.y > fy)) {
                const t = (fy - p0.y) / (p1.y - p0.y);
                const x = p0.x + t * (p1.x - p0.x);
                try intersections.append(x);
            }
        }

        // Sort intersections
        std.mem.sort(f32, intersections.items, {}, std.sort.asc(f32));

        // Fill between pairs
        var i: usize = 0;
        while (i + 1 < intersections.items.len) : (i += 2) {
            const x0 = @as(i32, @intFromFloat(@floor(intersections.items[i])));
            const x1 = @as(i32, @intFromFloat(@ceil(intersections.items[i + 1])));

            var x = @max(0, x0);
            while (x <= @min(@as(i32, @intCast(img.width - 1)), x1)) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5;

                // Anti-aliasing at edges
                var alpha: f32 = 1.0;
                if (x == x0 and intersections.items[i] > @as(f32, @floatFromInt(x0))) {
                    alpha = intersections.items[i] - @as(f32, @floatFromInt(x0));
                } else if (x == x1 and intersections.items[i + 1] < @as(f32, @floatFromInt(x1))) {
                    alpha = @as(f32, @floatFromInt(x1)) - intersections.items[i + 1];
                }

                _ = fx;
                const color = blendColor(img.getPixel(@intCast(x), @intCast(y)) orelse Color.TRANSPARENT, style.color, alpha);
                img.setPixel(@intCast(x), @intCast(y), color);
            }
        }
    }
}

fn drawLineAA(img: *Image, x0: f32, y0: f32, x1: f32, y1: f32, color: Color, width: f32) !void {
    // Xiaolin Wu's line algorithm with width
    const dx = x1 - x0;
    const dy = y1 - y0;

    const steep = @abs(dy) > @abs(dx);
    var sx0 = x0;
    var sy0 = y0;
    var sx1 = x1;
    var sy1 = y1;

    if (steep) {
        std.mem.swap(f32, &sx0, &sy0);
        std.mem.swap(f32, &sx1, &sy1);
    }
    if (sx0 > sx1) {
        std.mem.swap(f32, &sx0, &sx1);
        std.mem.swap(f32, &sy0, &sy1);
    }

    const sdx = sx1 - sx0;
    const sdy = sy1 - sy0;
    const gradient = if (sdx == 0) 1.0 else sdy / sdx;

    // First endpoint
    var xend = @round(sx0);
    var yend = sy0 + gradient * (xend - sx0);
    var xgap = 1.0 - fpart(sx0 + 0.5);
    const xpxl1 = xend;
    const ypxl1 = @floor(yend);

    if (steep) {
        plotAA(img, @intFromFloat(ypxl1), @intFromFloat(xpxl1), color, (1.0 - fpart(yend)) * xgap);
        plotAA(img, @intFromFloat(ypxl1 + 1), @intFromFloat(xpxl1), color, fpart(yend) * xgap);
    } else {
        plotAA(img, @intFromFloat(xpxl1), @intFromFloat(ypxl1), color, (1.0 - fpart(yend)) * xgap);
        plotAA(img, @intFromFloat(xpxl1), @intFromFloat(ypxl1 + 1), color, fpart(yend) * xgap);
    }

    var intery = yend + gradient;

    // Second endpoint
    xend = @round(sx1);
    yend = sy1 + gradient * (xend - sx1);
    xgap = fpart(sx1 + 0.5);
    const xpxl2 = xend;
    const ypxl2 = @floor(yend);

    if (steep) {
        plotAA(img, @intFromFloat(ypxl2), @intFromFloat(xpxl2), color, (1.0 - fpart(yend)) * xgap);
        plotAA(img, @intFromFloat(ypxl2 + 1), @intFromFloat(xpxl2), color, fpart(yend) * xgap);
    } else {
        plotAA(img, @intFromFloat(xpxl2), @intFromFloat(ypxl2), color, (1.0 - fpart(yend)) * xgap);
        plotAA(img, @intFromFloat(xpxl2), @intFromFloat(ypxl2 + 1), color, fpart(yend) * xgap);
    }

    // Main loop
    var x = xpxl1 + 1;
    while (x < xpxl2) : (x += 1) {
        if (steep) {
            plotAA(img, @intFromFloat(@floor(intery)), @intFromFloat(x), color, 1.0 - fpart(intery));
            plotAA(img, @intFromFloat(@floor(intery) + 1), @intFromFloat(x), color, fpart(intery));
        } else {
            plotAA(img, @intFromFloat(x), @intFromFloat(@floor(intery)), color, 1.0 - fpart(intery));
            plotAA(img, @intFromFloat(x), @intFromFloat(@floor(intery) + 1), color, fpart(intery));
        }
        intery += gradient;
    }

    _ = width;
}

fn fpart(x: f32) f32 {
    return x - @floor(x);
}

fn plotAA(img: *Image, x: i32, y: i32, color: Color, alpha: f32) void {
    if (x < 0 or y < 0 or x >= img.width or y >= img.height) return;

    const existing = img.getPixel(@intCast(x), @intCast(y)) orelse Color.TRANSPARENT;
    const blended = blendColor(existing, color, alpha);
    img.setPixel(@intCast(x), @intCast(y), blended);
}

fn blendColor(dst: Color, src: Color, alpha: f32) Color {
    const src_alpha = @as(f32, @floatFromInt(src.a)) / 255.0 * alpha;
    const dst_alpha = @as(f32, @floatFromInt(dst.a)) / 255.0 * (1.0 - src_alpha);
    const out_alpha = src_alpha + dst_alpha;

    if (out_alpha < 0.001) return Color.TRANSPARENT;

    return Color{
        .r = @intFromFloat(((@as(f32, @floatFromInt(src.r)) * src_alpha + @as(f32, @floatFromInt(dst.r)) * dst_alpha) / out_alpha)),
        .g = @intFromFloat(((@as(f32, @floatFromInt(src.g)) * src_alpha + @as(f32, @floatFromInt(dst.g)) * dst_alpha) / out_alpha)),
        .b = @intFromFloat(((@as(f32, @floatFromInt(src.b)) * src_alpha + @as(f32, @floatFromInt(dst.b)) * dst_alpha) / out_alpha)),
        .a = @intFromFloat(out_alpha * 255),
    };
}

// ============================================================================
// Shape Primitives
// ============================================================================

pub fn drawCircleAA(img: *Image, cx: f32, cy: f32, radius: f32, color: Color, filled: bool) !void {
    const r2 = radius * radius;
    const min_x = @as(i32, @intFromFloat(@floor(cx - radius - 1)));
    const max_x = @as(i32, @intFromFloat(@ceil(cx + radius + 1)));
    const min_y = @as(i32, @intFromFloat(@floor(cy - radius - 1)));
    const max_y = @as(i32, @intFromFloat(@ceil(cy + radius + 1)));

    var y = @max(0, min_y);
    while (y <= @min(@as(i32, @intCast(img.height - 1)), max_y)) : (y += 1) {
        var x = @max(0, min_x);
        while (x <= @min(@as(i32, @intCast(img.width - 1)), max_x)) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const dist2 = fx * fx + fy * fy;
            const dist = @sqrt(dist2);

            var alpha: f32 = 0;
            if (filled) {
                if (dist <= radius) {
                    alpha = if (dist > radius - 1) (radius - dist) else 1.0;
                }
            } else {
                const edge_dist = @abs(dist - radius);
                if (edge_dist < 1) {
                    alpha = 1.0 - edge_dist;
                }
            }

            if (alpha > 0) {
                plotAA(img, x, y, color, alpha);
            }
        }
    }
}

pub fn drawRectangleAA(img: *Image, x: f32, y: f32, width: f32, height: f32, color: Color, filled: bool) !void {
    if (filled) {
        const x0 = @as(i32, @intFromFloat(@floor(x)));
        const y0 = @as(i32, @intFromFloat(@floor(y)));
        const x1 = @as(i32, @intFromFloat(@ceil(x + width)));
        const y1 = @as(i32, @intFromFloat(@ceil(y + height)));

        var py = @max(0, y0);
        while (py <= @min(@as(i32, @intCast(img.height - 1)), y1)) : (py += 1) {
            var px = @max(0, x0);
            while (px <= @min(@as(i32, @intCast(img.width - 1)), x1)) : (px += 1) {
                img.setPixel(@intCast(px), @intCast(py), color);
            }
        }
    } else {
        // Draw four lines
        try drawLineAA(img, x, y, x + width, y, color, 1.0);
        try drawLineAA(img, x + width, y, x + width, y + height, color, 1.0);
        try drawLineAA(img, x + width, y + height, x, y + height, color, 1.0);
        try drawLineAA(img, x, y + height, x, y, color, 1.0);
    }
}

pub fn drawEllipseAA(img: *Image, cx: f32, cy: f32, rx: f32, ry: f32, color: Color, filled: bool) !void {
    const min_x = @as(i32, @intFromFloat(@floor(cx - rx - 1)));
    const max_x = @as(i32, @intFromFloat(@ceil(cx + rx + 1)));
    const min_y = @as(i32, @intFromFloat(@floor(cy - ry - 1)));
    const max_y = @as(i32, @intFromFloat(@ceil(cy + ry + 1)));

    var y = @max(0, min_y);
    while (y <= @min(@as(i32, @intCast(img.height - 1)), max_y)) : (y += 1) {
        var x = @max(0, min_x);
        while (x <= @min(@as(i32, @intCast(img.width - 1)), max_x)) : (x += 1) {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / rx;
            const fy = (@as(f32, @floatFromInt(y)) + 0.5 - cy) / ry;
            const dist = @sqrt(fx * fx + fy * fy);

            var alpha: f32 = 0;
            if (filled) {
                if (dist <= 1.0) {
                    alpha = if (dist > 0.9) ((1.0 - dist) / 0.1) else 1.0;
                }
            } else {
                const edge_dist = @abs(dist - 1.0) * @min(rx, ry);
                if (edge_dist < 1) {
                    alpha = 1.0 - edge_dist;
                }
            }

            if (alpha > 0) {
                plotAA(img, x, y, color, alpha);
            }
        }
    }
}

pub fn drawPolygonAA(img: *Image, points: []const Point, color: Color, filled: bool) !void {
    if (points.len < 3) return;

    var path = Path.init(img.allocator);
    defer path.deinit();

    for (points) |pt| {
        try path.lineTo(pt.x, pt.y);
    }
    path.close();

    if (filled) {
        try fillPath(img, &path, .{ .color = color });
    } else {
        try strokePath(img, &path, .{ .color = color });
    }
}

// ============================================================================
// SVG Path Parser (Simplified)
// ============================================================================

pub fn parseSVGPath(allocator: std.mem.Allocator, svg_path: []const u8) !Path {
    var path = Path.init(allocator);
    errdefer path.deinit();

    var i: usize = 0;
    var current_x: f32 = 0;
    var current_y: f32 = 0;

    while (i < svg_path.len) {
        // Skip whitespace and commas
        while (i < svg_path.len and (svg_path[i] == ' ' or svg_path[i] == ',' or svg_path[i] == '\n' or svg_path[i] == '\r' or svg_path[i] == '\t')) {
            i += 1;
        }
        if (i >= svg_path.len) break;

        const cmd = svg_path[i];
        i += 1;

        switch (cmd) {
            'M', 'm' => {
                // Move to
                const coords = try parseNumbers(svg_path, &i, 2);
                const x = if (cmd == 'M') coords[0] else current_x + coords[0];
                const y = if (cmd == 'M') coords[1] else current_y + coords[1];
                try path.moveTo(x, y);
                current_x = x;
                current_y = y;
            },
            'L', 'l' => {
                // Line to
                const coords = try parseNumbers(svg_path, &i, 2);
                const x = if (cmd == 'L') coords[0] else current_x + coords[0];
                const y = if (cmd == 'L') coords[1] else current_y + coords[1];
                try path.lineTo(x, y);
                current_x = x;
                current_y = y;
            },
            'H', 'h' => {
                // Horizontal line
                const coords = try parseNumbers(svg_path, &i, 1);
                const x = if (cmd == 'H') coords[0] else current_x + coords[0];
                try path.lineTo(x, current_y);
                current_x = x;
            },
            'V', 'v' => {
                // Vertical line
                const coords = try parseNumbers(svg_path, &i, 1);
                const y = if (cmd == 'V') coords[0] else current_y + coords[0];
                try path.lineTo(current_x, y);
                current_y = y;
            },
            'Q', 'q' => {
                // Quadratic Bezier
                const coords = try parseNumbers(svg_path, &i, 4);
                const cpx = if (cmd == 'Q') coords[0] else current_x + coords[0];
                const cpy = if (cmd == 'Q') coords[1] else current_y + coords[1];
                const x = if (cmd == 'Q') coords[2] else current_x + coords[2];
                const y = if (cmd == 'Q') coords[3] else current_y + coords[3];
                try path.quadraticTo(cpx, cpy, x, y, 0.5);
                current_x = x;
                current_y = y;
            },
            'C', 'c' => {
                // Cubic Bezier
                const coords = try parseNumbers(svg_path, &i, 6);
                const cp1x = if (cmd == 'C') coords[0] else current_x + coords[0];
                const cp1y = if (cmd == 'C') coords[1] else current_y + coords[1];
                const cp2x = if (cmd == 'C') coords[2] else current_x + coords[2];
                const cp2y = if (cmd == 'C') coords[3] else current_y + coords[3];
                const x = if (cmd == 'C') coords[4] else current_x + coords[4];
                const y = if (cmd == 'C') coords[5] else current_y + coords[5];
                try path.cubicTo(cp1x, cp1y, cp2x, cp2y, x, y, 0.5);
                current_x = x;
                current_y = y;
            },
            'Z', 'z' => {
                // Close path
                path.close();
            },
            else => {
                // Unknown command, skip
            },
        }
    }

    return path;
}

fn parseNumbers(str: []const u8, idx: *usize, count: usize) ![6]f32 {
    var numbers: [6]f32 = undefined;
    var num_idx: usize = 0;

    while (num_idx < count and idx.* < str.len) {
        // Skip whitespace and commas
        while (idx.* < str.len and (str[idx.*] == ' ' or str[idx.*] == ',' or str[idx.*] == '\n' or str[idx.*] == '\r' or str[idx.*] == '\t')) {
            idx.* += 1;
        }
        if (idx.* >= str.len) break;

        // Parse number
        var num_start = idx.*;
        var has_dot = false;
        var has_sign = false;

        if (str[idx.*] == '-' or str[idx.*] == '+') {
            has_sign = true;
            idx.* += 1;
        }

        while (idx.* < str.len) {
            const c = str[idx.*];
            if (c >= '0' and c <= '9') {
                idx.* += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                idx.* += 1;
            } else {
                break;
            }
        }

        const num_str = str[num_start..idx.*];
        numbers[num_idx] = std.fmt.parseFloat(f32, num_str) catch 0;
        num_idx += 1;
    }

    return numbers;
}

// ============================================================================
// Gradient Fill (Vector Style)
// ============================================================================

pub const VectorGradient = struct {
    stops: []GradientStop,
    gradient_type: enum { linear, radial },
    start: Point,
    end: Point,
    allocator: std.mem.Allocator,

    pub const GradientStop = struct {
        offset: f32, // 0 to 1
        color: Color,
    };

    pub fn deinit(self: *VectorGradient) void {
        self.allocator.free(self.stops);
    }

    pub fn sample(self: *const VectorGradient, pt: Point) Color {
        const t = switch (self.gradient_type) {
            .linear => blk: {
                const dx = self.end.x - self.start.x;
                const dy = self.end.y - self.start.y;
                const len_sq = dx * dx + dy * dy;
                if (len_sq < 0.0001) break :blk 0.0;
                const px = pt.x - self.start.x;
                const py = pt.y - self.start.y;
                break :blk std.math.clamp((px * dx + py * dy) / len_sq, 0, 1);
            },
            .radial => blk: {
                const dist = pt.distance(self.start);
                const max_dist = self.start.distance(self.end);
                break :blk std.math.clamp(dist / max_dist, 0, 1);
            },
        };

        return sampleGradient(self.stops, t);
    }
};

fn sampleGradient(stops: []const VectorGradient.GradientStop, t: f32) Color {
    if (stops.len == 0) return Color.BLACK;
    if (stops.len == 1) return stops[0].color;

    var i: usize = 0;
    while (i < stops.len - 1 and stops[i + 1].offset < t) : (i += 1) {}

    if (i >= stops.len - 1) return stops[stops.len - 1].color;

    const t0 = stops[i].offset;
    const t1 = stops[i + 1].offset;
    const local_t = if (t1 - t0 > 0.0001) (t - t0) / (t1 - t0) else 0;

    return interpolateColor(stops[i].color, stops[i + 1].color, local_t);
}

fn interpolateColor(c1: Color, c2: Color, t: f32) Color {
    return Color{
        .r = @intFromFloat(@as(f32, @floatFromInt(c1.r)) * (1 - t) + @as(f32, @floatFromInt(c2.r)) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(c1.g)) * (1 - t) + @as(f32, @floatFromInt(c2.g)) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(c1.b)) * (1 - t) + @as(f32, @floatFromInt(c2.b)) * t),
        .a = @intFromFloat(@as(f32, @floatFromInt(c1.a)) * (1 - t) + @as(f32, @floatFromInt(c2.a)) * t),
    };
}
