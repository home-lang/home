const std = @import("std");
const video = @import("video");
test "public Video exports inference projection and exact KPI counters" {
    const p = try video.inference_region.Plan.init(.{ .width = 100, .height = 100 }, .{ .width = 50, .height = 50 }, .{ .width = 20, .height = 20 }, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, null);
    const r = try p.normalized(.{ 0.25, 0.25, 0.75, 0.75 });
    try std.testing.expectEqual(@as(u32, 10), r.width);
    const kpi = try video.cnn_kpi.Info.fromRaw(&.{ 0xe8, 3, 0, 0, 0xd0, 7, 0, 0 }, .little);
    try std.testing.expectEqualDeep([2]f64{ 1, 2 }, kpi.picameraMilliseconds());
}
