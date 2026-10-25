//! IMX500 active-array ROI encoding. Kernel zero width OR height selects the
//! full sensor. Cached controls do not prove frame-level sensor application.
const std = @import("std");
const region = @import("inference_region.zig");
pub const full = region.Size{ .width = 4056, .height = 3040 };
pub const Payload = [4]u32;
pub const Limits = struct { minimum: u32, maximum: u32, step: u32 };
pub fn effective(raw: Payload) !region.Rect {
    if (raw[2] == 0 or raw[3] == 0) return .{ .x = 0, .y = 0, .width = full.width, .height = full.height };
    if (raw[0] > full.width or raw[1] > full.height or raw[2] > full.width - raw[0] or raw[3] > full.height - raw[1]) return error.InvalidCachedRoi;
    return .{ .x = @intCast(raw[0]), .y = @intCast(raw[1]), .width = raw[2], .height = raw[3] };
}
pub fn validate(raw: Payload, limits: Limits) !void {
    if (limits.step == 0 or limits.minimum > limits.maximum) return error.InvalidLimits;
    for (raw) |value| if (value < limits.minimum or value > limits.maximum or (value - limits.minimum) % limits.step != 0) return error.UnsupportedRoiRange;
}
pub fn encode(requested: region.Rect, limits: Limits) !Payload {
    // Preserve the explicit kernel reset while rejecting accidental empty crops.
    if (requested.x == 0 and requested.y == 0 and requested.width == 0 and requested.height == 0) {
        const reset: Payload = .{ 0, 0, 0, 0 };
        try validate(reset, limits);
        return reset;
    }
    const bounded = region.intersect(requested, .{ .x = 0, .y = 0, .width = full.width, .height = full.height });
    if (bounded.width == 0 or bounded.height == 0) return error.EmptyRoi;
    const raw: Payload = if (bounded.x == 0 and bounded.y == 0 and bounded.width == full.width and bounded.height == full.height) .{ 0, 0, 0, 0 } else .{ @intCast(bounded.x), @intCast(bounded.y), bounded.width, bounded.height };
    try validate(raw, limits);
    return raw;
}
test "ROI full sensor uses zero sentinel within the driver's smaller advertised limit" {
    const t = std.testing;
    const limits = Limits{ .minimum = 0, .maximum = 4032, .step = 1 };
    try t.expectEqualDeep(Payload{ 0, 0, 0, 0 }, try encode(.{ .x = 0, .y = 0, .width = 4056, .height = 3040 }, limits));
    try t.expectEqualDeep(Payload{ 0, 0, 0, 0 }, try encode(.{ .x = 0, .y = 0, .width = 0, .height = 0 }, limits));
    try t.expectError(error.EmptyRoi, encode(.{ .x = 1, .y = 0, .width = 0, .height = 0 }, limits));
    try t.expectEqualDeep(region.Rect{ .x = 0, .y = 0, .width = 4056, .height = 3040 }, try effective(.{ 99, 77, 0, 123 }));
    try t.expectEqualDeep(Payload{ 0, 0, 100, 100 }, try encode(.{ .x = -100, .y = -100, .width = 200, .height = 200 }, limits));
    try t.expectError(error.UnsupportedRoiRange, encode(.{ .x = 0, .y = 0, .width = 4056, .height = 100 }, limits));
    try t.expectError(error.EmptyRoi, encode(.{ .x = 5000, .y = 0, .width = 2, .height = 2 }, limits));
}
test "ROI encoding validates ranges steps and cached windows without overflow" {
    const t = std.testing;
    try t.expectError(error.InvalidLimits, encode(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, .{ .minimum = 0, .maximum = 4056, .step = 0 }));
    try t.expectError(error.UnsupportedRoiRange, encode(.{ .x = 1, .y = 0, .width = 2, .height = 2 }, .{ .minimum = 0, .maximum = 4056, .step = 2 }));
    try t.expectError(error.InvalidCachedRoi, effective(.{ 4055, 0, 2, 10 }));
    try t.expectError(error.InvalidCachedRoi, effective(.{ std.math.maxInt(u32), 0, 1, 1 }));
    try t.expectEqualDeep(region.Rect{ .x = 508, .y = 0, .width = 3040, .height = 3040 }, try effective(.{ 508, 0, 3040, 3040 }));
}
