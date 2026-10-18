//! Shared orthonormal JPEG DCT basis and inverse transform (Home, MIT).
const std = @import("std");
pub const BASIS: [8]@Vector(8, f32) = blk: {
    @setEvalBranchQuota(10000);
    var b: [8]@Vector(8, f32) = undefined;
    for (0..8) |u| for (0..8) |x| {
        const scale: f64 = if (u == 0) 0.3535533905932738 else 0.5;
        b[u][x] = @floatCast(scale * @cos((@as(f64, @floatFromInt(x)) * 2 + 1) * @as(f64, @floatFromInt(u)) * std.math.pi / 16));
    };
    break :blk b;
};

pub fn inverse(block: *[64]i32, quant: *const [64]u16) void {
    var work: [8][8]f32 = undefined;
    for (0..8) |v| {
        var coefficients: @Vector(8, f32) = undefined;
        inline for (0..8) |u| coefficients[u] = @as(f32, @floatFromInt(block[v * 8 + u])) * @as(f32, @floatFromInt(quant[v * 8 + u]));
        for (0..8) |x| {
            var basis: @Vector(8, f32) = undefined;
            inline for (0..8) |u| basis[u] = BASIS[u][x];
            work[v][x] = @reduce(.Add, coefficients * basis);
        }
    }
    for (0..8) |y| for (0..8) |x| {
        var values: @Vector(8, f32) = undefined;
        var basis: @Vector(8, f32) = undefined;
        inline for (0..8) |v| {
            values[v] = work[v][x];
            basis[v] = BASIS[v][y];
        }
        block[y * 8 + x] = @intFromFloat(std.math.clamp(@round(@reduce(.Add, values * basis)) + 128, 0, 255));
    };
}
test "inverse JPEG DC scale and zero AC are exact" {
    var block: [64]i32 = @splat(0);
    block[0] = 80;
    inverse(&block, &@as([64]u16, @splat(1)));
    for (block) |v| try std.testing.expectEqual(@as(i32, 138), v);
}
