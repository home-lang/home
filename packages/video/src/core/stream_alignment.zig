//! Allocation-free processed-stream geometry planning. This rounds dimensions
//! down; it neither negotiates hardware nor allocates or changes pixel buffers.
const std = @import("std");
pub const Profile = enum { vc4, pisp };
pub const Layout = enum { packed_pixels, planar420, wide };
pub const Plan = struct {
    width: u32,
    height: u32,
    width_alignment: u32,
    height_alignment: u32 = 2,
};
pub fn aligned(width: u32, height: u32, layout: Layout, profile: Profile, optimal: bool) !Plan {
    if (width == 0 or height == 0) return error.InvalidGeometry;
    const base: u32 = if (!optimal) 2 else if (profile == .vc4) 32 else 64;
    const quantum = if (!optimal) base else switch (layout) {
        .packed_pixels => base,
        .planar420 => base * 2,
        .wide => base / 2,
    };
    const result: Plan = .{ .width = width - width % quantum, .height = height - height % 2, .width_alignment = quantum };
    // Never turn an explicit tiny extent into a backend-default zero extent.
    if (result.width == 0 or result.height == 0) return error.EmptyAlignment;
    return result;
}
test "PiSP and VC4 layouts retain their explicit processed-plane alignment recipes" {
    const t = std.testing;
    try t.expectEqualDeep(Plan{ .width = 1856, .height = 1080, .width_alignment = 64 }, try aligned(1919, 1081, .packed_pixels, .pisp, true));
    try t.expectEqualDeep(Plan{ .width = 1792, .height = 1080, .width_alignment = 128 }, try aligned(1919, 1081, .planar420, .pisp, true));
    try t.expectEqualDeep(Plan{ .width = 1888, .height = 1080, .width_alignment = 32 }, try aligned(1919, 1081, .wide, .pisp, true));
    try t.expectEqualDeep(Plan{ .width = 1888, .height = 1080, .width_alignment = 32 }, try aligned(1919, 1081, .packed_pixels, .vc4, true));
    try t.expectEqualDeep(Plan{ .width = 1856, .height = 1080, .width_alignment = 64 }, try aligned(1919, 1081, .planar420, .vc4, true));
    try t.expectEqualDeep(Plan{ .width = 1904, .height = 1080, .width_alignment = 16 }, try aligned(1919, 1081, .wide, .vc4, true));
}
test "minimum alignment is profile and layout independent and tiny inputs never become defaults" {
    const t = std.testing;
    for ([_]Profile{ .vc4, .pisp }) |profile| for ([_]Layout{ .packed_pixels, .planar420, .wide }) |layout| {
        try t.expectEqualDeep(Plan{ .width = 1918, .height = 1080, .width_alignment = 2 }, try aligned(1919, 1081, layout, profile, false));
        try t.expectError(error.InvalidGeometry, aligned(0, 2, layout, profile, false));
        try t.expectError(error.InvalidGeometry, aligned(2, 0, layout, profile, false));
        try t.expectError(error.EmptyAlignment, aligned(1, 2, layout, profile, false));
        try t.expectError(error.EmptyAlignment, aligned(2, 1, layout, profile, false));
    };
    try t.expectError(error.EmptyAlignment, aligned(63, 2, .packed_pixels, .pisp, true));
    try t.expectError(error.EmptyAlignment, aligned(127, 2, .planar420, .pisp, true));
    try t.expectError(error.EmptyAlignment, aligned(31, 2, .wide, .pisp, true));
}
test "alignment is idempotent never enlarges extents and stays exact at unsigned limits" {
    const t = std.testing;
    const values = [_]u32{ 128, 129, 1023, 1920, 16384, std.math.maxInt(u32) };
    for ([_]Profile{ .vc4, .pisp }) |profile| for ([_]Layout{ .packed_pixels, .planar420, .wide }) |layout| for ([_]bool{ false, true }) |optimal| for (values) |width| for (values) |height| {
        const plan = try aligned(width, height, layout, profile, optimal);
        try t.expect(plan.width <= width and plan.height <= height);
        try t.expectEqual(@as(u32, 0), plan.width % plan.width_alignment);
        try t.expectEqual(@as(u32, 0), plan.height % plan.height_alignment);
        try t.expectEqualDeep(plan, try aligned(plan.width, plan.height, layout, profile, optimal));
        if (optimal and layout == .planar420) try t.expectEqual(@as(u32, 0), (plan.width / 2) % (if (profile == .vc4) @as(u32, 32) else 64));
    };
}
