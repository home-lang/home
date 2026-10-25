//! Checked sensor -> raw -> scaler crop -> ISP rectangle projection. Rounding
//! matches libcamera Rectangle::scaledBy at each stage, not a fused transform.
const std = @import("std");
pub const Size = struct { width: u32, height: u32 };
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
fn sizeValid(s: Size) bool {
    return s.width != 0 and s.height != 0 and s.width <= std.math.maxInt(i32) and s.height <= std.math.maxInt(i32);
}
fn checked(value: i64) !i32 {
    return std.math.cast(i32, value) orelse error.InvalidGeometry;
}
pub fn intersect(a: Rect, b: Rect) Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
    const bottom = @min(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
    return .{ .x = x, .y = y, .width = @intCast(@max(0, right - x)), .height = @intCast(@max(0, bottom - y)) };
}
fn scale(r: Rect, numerator: Size, denominator: Size) !Rect {
    if (denominator.width == 0 or denominator.height == 0) return error.DegenerateCrop;
    const width = @as(u64, r.width) * numerator.width / denominator.width;
    const height = @as(u64, r.height) * numerator.height / denominator.height;
    return .{
        .x = try checked(@divTrunc(@as(i64, r.x) * numerator.width, denominator.width)),
        .y = try checked(@divTrunc(@as(i64, r.y) * numerator.height, denominator.height)),
        .width = std.math.cast(u32, width) orelse return error.InvalidGeometry,
        .height = std.math.cast(u32, height) orelse return error.InvalidGeometry,
    };
}
fn fullRect(s: Size) Rect {
    return .{ .x = 0, .y = 0, .width = s.width, .height = s.height };
}
pub const Plan = struct {
    full: Size,
    raw: Size,
    output: Size,
    crop: Rect,
    roi: ?Rect,
    pub fn init(full: Size, raw: Size, output: Size, scaler_crop: Rect, roi: ?Rect) !Plan {
        if (!sizeValid(full) or !sizeValid(raw) or !sizeValid(output)) return error.InvalidGeometry;
        if (scaler_crop.x < 0 or scaler_crop.y < 0 or scaler_crop.width == 0 or scaler_crop.height == 0 or @as(u64, @intCast(scaler_crop.x)) + scaler_crop.width > full.width or @as(u64, @intCast(scaler_crop.y)) + scaler_crop.height > full.height) return error.InvalidCrop;
        const crop = try scale(scaler_crop, raw, full);
        if (crop.width == 0 or crop.height == 0) return error.DegenerateCrop;
        const selected = if (roi) |r| if (r.x == 0 and r.y == 0 and r.width == 0 and r.height == 0) null else intersect(r, fullRect(full)) else null;
        return .{ .full = full, .raw = raw, .output = output, .crop = crop, .roi = selected };
    }
    /// Absolute full-sensor pixels. Empty results retain libcamera's intersection
    /// anchor, which can lie outside the canvas; draw only nonempty rectangles.
    pub fn project(self: Plan, object: Rect) !Rect {
        const selected = if (self.roi) |roi| intersect(object, roi) else object;
        const sensor = try scale(selected, self.raw, self.full);
        const bounded = intersect(sensor, self.crop);
        const translated: Rect = .{ .x = try checked(@as(i64, bounded.x) - self.crop.x), .y = try checked(@as(i64, bounded.y) - self.crop.y), .width = bounded.width, .height = bounded.height };
        return scale(translated, self.output, .{ .width = self.crop.width, .height = self.crop.height });
    }
    /// Picamera2's (y0,x0,y1,x1) convention: clamp each derived origin/extent to
    /// zero, truncate to signed pixels, then apply the same integer stages.
    pub fn normalized(self: Plan, coords: [4]f64) !Rect {
        for (coords) |value| if (!std.math.isFinite(value)) return error.InvalidCoordinates;
        const values = [_]f64{ coords[1] * @as(f64, @floatFromInt(self.full.width)), coords[0] * @as(f64, @floatFromInt(self.full.height)), (coords[3] - coords[1]) * @as(f64, @floatFromInt(self.full.width)), (coords[2] - coords[0]) * @as(f64, @floatFromInt(self.full.height)) };
        var pixels: [4]i32 = undefined;
        for (values, 0..) |value, i| {
            if (!std.math.isFinite(value) or @max(value, 0) > std.math.maxInt(i32)) return error.InvalidCoordinates;
            pixels[i] = @intFromFloat(@max(value, 0));
        }
        return self.project(.{ .x = pixels[0], .y = pixels[1], .width = @intCast(pixels[2]), .height = @intCast(pixels[3]) });
    }
    pub fn roiScaled(self: Plan) !Rect {
        return self.project(fullRect(self.full));
    }
};
/// Full-sensor centered aspect crop. Reject a subpixel dimension rather than
/// sending a zero-sized ROI to a device. The returned rectangle owns no device.
pub fn centeredAspect(full: Size, ratio: Size) !Rect {
    if (!sizeValid(full) or ratio.width == 0 or ratio.height == 0) return error.InvalidGeometry;
    const a = @as(u64, full.width) * ratio.height;
    const b = @as(u64, ratio.width) * full.height;
    const w = if (a > b) @as(u32, @intCast(b / ratio.height)) else full.width;
    const h = if (a > b) full.height else @as(u32, @intCast(a / ratio.width));
    if (w == 0 or h == 0) return error.DegenerateCrop;
    // libcamera Size::centeredTo truncates each half independently.
    return .{ .x = @intCast(full.width / 2 - w / 2), .y = @intCast(full.height / 2 - h / 2), .width = w, .height = h };
}
test "sensor ROI scaling preserves each integer stage and normalized coordinate convention" {
    const t = std.testing;
    const plan = try Plan.init(.{ .width = 4056, .height = 3040 }, .{ .width = 2028, .height = 1520 }, .{ .width = 640, .height = 480 }, .{ .x = 100, .y = 200, .width = 2000, .height = 1600 }, .{ .x = 200, .y = 300, .width = 1200, .height = 900 });
    try t.expectEqualDeep(Rect{ .x = 32, .y = 30, .width = 384, .height = 270 }, try plan.roiScaled());
    try t.expectEqualDeep(try plan.project(.{ .x = 1014, .y = 760, .width = 2028, .height = 1520 }), try plan.normalized(.{ 0.25, 0.25, 0.75, 0.75 }));
    const tiny = try Plan.init(.{ .width = 7, .height = 7 }, .{ .width = 5, .height = 5 }, .{ .width = 11, .height = 11 }, .{ .x = 1, .y = 1, .width = 5, .height = 5 }, null);
    try t.expectEqualDeep(Rect{ .x = 3, .y = 3, .width = 3, .height = 3 }, try tiny.project(.{ .x = 2, .y = 2, .width = 2, .height = 2 }));
}
test "normalized negative reversed empty and disjoint rectangles follow upstream clipping" {
    const t = std.testing;
    const p = try Plan.init(.{ .width = 100, .height = 80 }, .{ .width = 100, .height = 80 }, .{ .width = 100, .height = 80 }, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, null);
    try t.expectEqualDeep(Rect{ .x = 0, .y = 0, .width = 100, .height = 80 }, try p.normalized(.{ -1, -1, 1, 1 }));
    try t.expectEqualDeep(Rect{ .x = 80, .y = 64, .width = 0, .height = 0 }, try p.normalized(.{ 0.8, 0.8, 0.2, 0.2 }));
    try t.expectEqualDeep(Rect{ .x = 200, .y = 160, .width = 0, .height = 0 }, try p.normalized(.{ 2, 2, 3, 3 }));
    const disabled = try Plan.init(p.full, p.raw, p.output, p.crop, .{ .x = 0, .y = 0, .width = 0, .height = 0 });
    try t.expectEqualDeep(try p.roiScaled(), try disabled.roiScaled());
}
test "aspect crop uses centered integer halves and rejects invalid or degenerate geometry" {
    const t = std.testing;
    try t.expectEqualDeep(Rect{ .x = 508, .y = 0, .width = 3040, .height = 3040 }, try centeredAspect(.{ .width = 4056, .height = 3040 }, .{ .width = 1, .height = 1 }));
    try t.expectEqualDeep(Rect{ .x = 2, .y = 0, .width = 4, .height = 4 }, try centeredAspect(.{ .width = 9, .height = 4 }, .{ .width = 1, .height = 1 }));
    try t.expectError(error.DegenerateCrop, centeredAspect(.{ .width = 1, .height = 1 }, .{ .width = 1, .height = 100 }));
    try t.expectError(error.InvalidGeometry, centeredAspect(.{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }));
    try t.expectError(error.DegenerateCrop, Plan.init(.{ .width = 100, .height = 100 }, .{ .width = 1, .height = 1 }, .{ .width = 1, .height = 1 }, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, null));
    const p = try Plan.init(.{ .width = 100, .height = 80 }, .{ .width = 100, .height = 80 }, .{ .width = 100, .height = 80 }, .{ .x = 0, .y = 0, .width = 100, .height = 80 }, null);
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e100 }) |value| try t.expectError(error.InvalidCoordinates, p.normalized(.{ 0, value, 1, 1 }));
    try t.expectError(error.InvalidCrop, Plan.init(p.full, p.raw, p.output, .{ .x = 90, .y = 0, .width = 11, .height = 1 }, null));
}
test "intersections use widened endpoints even for extreme signed origins and extents" {
    const r = intersect(.{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32), .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }, .{ .x = 0, .y = 0, .width = 4056, .height = 3040 });
    try std.testing.expectEqualDeep(Rect{ .x = std.math.maxInt(i32), .y = 0, .width = 0, .height = 3040 }, r);
}
