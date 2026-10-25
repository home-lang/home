//! Retain actual coordinate and KPI implementations without libc or a heap.
const region = @import("region");
const kpi = @import("kpi");
export fn home_inference_convert(g: *const [14]u32, coordinates: *const [4]f64, output: *[4]i64) u32 {
    const p = region.Plan.init(.{ .width = g[0], .height = g[1] }, .{ .width = g[2], .height = g[3] }, .{ .width = g[4], .height = g[5] }, .{ .x = @bitCast(g[6]), .y = @bitCast(g[7]), .width = g[8], .height = g[9] }, .{ .x = @bitCast(g[10]), .y = @bitCast(g[11]), .width = g[12], .height = g[13] }) catch return 1;
    const r = p.normalized(coordinates.*) catch return 1;
    output.* = .{ r.x, r.y, r.width, r.height };
    return 0;
}
export fn home_inference_aspect(width: u32, height: u32, aspect_width: u32, aspect_height: u32, output: *[4]i64) u32 {
    const r = region.centeredAspect(.{ .width = width, .height = height }, .{ .width = aspect_width, .height = aspect_height }) catch return 1;
    output.* = .{ r.x, r.y, r.width, r.height };
    return 0;
}
export fn home_cnn_kpi_milliseconds(raw: *const [8]u8, output: *[2]f64) u32 {
    const info = kpi.Info.fromRaw(raw, .little) catch return 1;
    output.* = info.picameraMilliseconds();
    return 0;
}
