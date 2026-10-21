//! Borrowed ICC curveType/parametricCurveType evaluation. No gamma guess is made
//! for sampled curves. The owner must keep bytes immutable until the view expires.
const std = @import("std");
pub const Curve = struct {
    data: []const u8,
    parametric: bool,
    count: u32,
    parameters: [7]f64 = @splat(0),
    pub fn init(data: []const u8) !Curve {
        if (data.len < 12 or !std.mem.allEqual(u8, data[4..8], 0)) return error.InvalidCurve;
        if (std.mem.eql(u8, data[0..4], "curv")) {
            const count = std.mem.readInt(u32, data[8..12], .big);
            if (count > (data.len - 12) / 2) return error.InvalidCurve;
            const size = 12 + @as(usize, count) * 2;
            if (data.len - size > 3 or !std.mem.allEqual(u8, data[size..], 0)) return error.InvalidCurve;
            if (count == 1 and std.mem.readInt(u16, data[12..14], .big) == 0) return error.InvalidCurve;
            var previous: u16 = 0;
            if (count > 1) for (0..count) |i| {
                const value = std.mem.readInt(u16, data[12 + i * 2 ..][0..2], .big);
                if (value < previous) return error.NonMonotonicCurve;
                previous = value;
            };
            return .{ .data = data, .parametric = false, .count = count };
        }
        if (!std.mem.eql(u8, data[0..4], "para") or !std.mem.allEqual(u8, data[10..12], 0)) return error.InvalidCurve;
        const function = std.mem.readInt(u16, data[8..10], .big);
        const counts = [_]usize{ 1, 3, 4, 5, 7 };
        if (function >= counts.len) return error.UnsupportedCurve;
        const size = 12 + counts[function] * 4;
        if (data.len < size or data.len - size > 3 or !std.mem.allEqual(u8, data[size..], 0)) return error.InvalidCurve;
        var result = Curve{ .data = data, .parametric = true, .count = function };
        for (result.parameters[0..counts[function]], 0..) |*value, i| value.* = @as(f64, @floatFromInt(std.mem.readInt(i32, data[12 + i * 4 ..][0..4], .big))) / 65536;
        const p = result.parameters;
        if (p[0] <= 0 or (function != 0 and p[1] <= 0) or (function >= 3 and (p[3] < 0 or p[4] < 0 or p[4] > 1 or p[1] * p[4] + p[2] < 0))) return error.InvalidCurve;
        // A monotonic breakpoint is required for the generalized inverse. Check
        // either side explicitly; coarse sampling alone could miss a narrow drop.
        if (function >= 3) {
            const left = p[3] * p[4] + if (function == 4) p[6] else @as(f64, 0);
            const right = std.math.pow(f64, p[1] * p[4] + p[2], p[0]) + if (function == 4) p[5] else @as(f64, 0);
            if (left > right + 1e-12) return error.NonMonotonicCurve;
        }
        if (!std.math.isFinite(result.eval(0)) or !std.math.isFinite(result.eval(1))) return error.InvalidCurve;
        return result;
    }
    pub fn evaluate(self: Curve, encoded: f64) !f64 {
        if (!std.math.isFinite(encoded)) return error.InvalidInput;
        return self.eval(std.math.clamp(encoded, 0, 1));
    }
    fn eval(self: Curve, x: f64) f64 {
        if (!self.parametric) {
            if (self.count == 0) return x;
            if (self.count == 1) return std.math.pow(f64, x, @as(f64, @floatFromInt(std.mem.readInt(u16, self.data[12..14], .big))) / 256);
            const position = x * @as(f64, @floatFromInt(self.count - 1));
            const first: usize = @intFromFloat(@floor(position));
            const second = @min(first + 1, self.count - 1);
            const fraction = position - @as(f64, @floatFromInt(first));
            const a: f64 = @floatFromInt(std.mem.readInt(u16, self.data[12 + first * 2 ..][0..2], .big));
            const b: f64 = @floatFromInt(std.mem.readInt(u16, self.data[12 + second * 2 ..][0..2], .big));
            return (a + (b - a) * fraction) / 65535;
        }
        const p = self.parameters;
        return switch (self.count) {
            0 => std.math.pow(f64, x, p[0]),
            1 => if (x >= -p[2] / p[1]) std.math.pow(f64, @max(0, p[1] * x + p[2]), p[0]) else 0,
            2 => (if (x >= -p[2] / p[1]) std.math.pow(f64, @max(0, p[1] * x + p[2]), p[0]) else @as(f64, 0)) + p[3],
            3 => if (x >= p[4]) std.math.pow(f64, @max(0, p[1] * x + p[2]), p[0]) else p[3] * x,
            4 => if (x >= p[4]) std.math.pow(f64, @max(0, p[1] * x + p[2]), p[0]) + p[5] else p[3] * x + p[6],
            else => unreachable,
        };
    }
    /// Monotonic lower inverse, clamped to the encoded domain. Flat sampled
    /// portions choose the first matching code; no invertibility is fabricated.
    pub fn inverse(self: Curve, linear: f64) !f64 {
        if (!std.math.isFinite(linear)) return error.InvalidInput;
        if (linear <= self.eval(0)) return 0;
        if (linear > self.eval(1)) return 1;
        var low: f64 = 0;
        var high: f64 = 1;
        for (0..48) |_| {
            const middle = (low + high) / 2;
            if (self.eval(middle) < linear) low = middle else high = middle;
        }
        return high;
    }
};
test "linear gamma sampled and parametric curves evaluate without replacing samples by gamma" {
    const t = std.testing;
    const linear = try Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00\x00");
    try t.expectEqual(@as(f64, 0.25), try linear.evaluate(0.25));
    const gamma = try Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "\x01\x02\x00");
    try t.expectApproxEqAbs(@as(f64, 0.0625), try gamma.evaluate(0.25), 1e-12);
    const sampled = try Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "\x03\x00\x00\x40\x00\xff\xff");
    try t.expectApproxEqAbs(@as(f64, 16384.0 / 65535.0), try sampled.evaluate(0.5), 1e-12);
    for ([_]f64{ 0, 0.001, 0.04, 0.25, 0.5, 0.9, 1 }) |value| try t.expectApproxEqAbs(value, try sampled.inverse(try sampled.evaluate(value)), 1e-12);
    for (0..5) |function| {
        var bytes: [40]u8 = @splat(0);
        @memcpy(bytes[0..4], "para");
        std.mem.writeInt(u16, bytes[8..10], @intCast(function), .big);
        const parameters = [_]f64{ 1, 1, 0, 1, 0, 0, 0 };
        const counts = [_]usize{ 1, 3, 4, 5, 7 };
        for (parameters[0..counts[function]], 0..) |value, i| std.mem.writeInt(i32, bytes[12 + i * 4 ..][0..4], @intFromFloat(value * 65536), .big);
        if (function == 2) std.mem.writeInt(i32, bytes[24..28], 0, .big);
        const curve = try Curve.init(bytes[0 .. 12 + counts[function] * 4]);
        try t.expectApproxEqAbs(@as(f64, 0.25), try curve.evaluate(0.25), 1e-12);
    }
    try t.expectError(error.InvalidInput, linear.evaluate(std.math.nan(f64)));
    try t.expectError(error.InvalidInput, linear.inverse(std.math.inf(f64)));
}
test "curves reject truncated tables, descending samples, invalid functions and unsafe parameters" {
    const t = std.testing;
    try t.expectError(error.InvalidCurve, Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "\x03\x00\x00"));
    try t.expectError(error.NonMonotonicCurve, Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "\x02\xff\xff\x00\x00"));
    try t.expectError(error.InvalidCurve, Curve.init("curv" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "\x01\x00\x00"));
    var para: [24]u8 = @splat(0);
    @memcpy(para[0..4], "para");
    std.mem.writeInt(u16, para[8..10], 1, .big);
    std.mem.writeInt(i32, para[12..16], 65536, .big);
    try t.expectError(error.InvalidCurve, Curve.init(&para)); // a=0
    std.mem.writeInt(u16, para[8..10], 5, .big);
    try t.expectError(error.UnsupportedCurve, Curve.init(&para));
}
