//! Bounded read-only KMS catalog policy. No display/DRM master or buffer owner.
const std = @import("std");
pub const max_formats = 256;
pub fn fourcc(text: *const [4]u8) u32 {
    return std.mem.readInt(u32, text, .little);
}
const entries = .{
    .{ "RG24", "RGB888" },   .{ "BG24", "BGR888" },
    .{ "XR24", "XRGB8888" }, .{ "XB24", "XBGR8888" },
    .{ "YU12", "YUV420" },   .{ "YV12", "YVU420" },
    .{ "NV12", "NV12" },     .{ "NV21", "NV21" },
    .{ "YUYV", "YUYV" },     .{ "YVYU", "YVYU" },
    .{ "UYVY", "UYVY" },     .{ "VYUY", "VYUY" },
};
pub fn processedFormat(value: u32) ?[]const u8 {
    inline for (entries) |entry| if (value == fourcc(entry[0])) return entry[1];
    return null;
}
pub fn fourccForProcessed(value: []const u8) ?u32 {
    inline for (entries) |entry| if (std.mem.eql(u8, value, entry[1])) return fourcc(entry[0]);
    return null;
}
pub fn validIds(values: []const u32) !void {
    for (values, 0..) |id, i| {
        if (id == 0 or std.mem.indexOfScalar(u32, values[0..i], id) != null) return error.InvalidTopology;
    }
}
pub fn crtcMask(count: usize) !u32 {
    if (count > 32) return error.TopologyLimit;
    return if (count == 32) std.math.maxInt(u32) else (@as(u32, 1) << @as(u5, @intCast(count))) - 1;
}
pub const FormatSet = struct {
    values: [max_formats]u32 = undefined,
    count: usize = 0,
    pub fn slice(self: *const FormatSet) []const u32 {
        return self.values[0..self.count];
    }
    /// Transactional even on a late unique format exceeding the fixed capacity.
    pub fn include(self: *FormatSet, values: []const u32) !void {
        if (values.len > max_formats) return error.TopologyLimit;
        var next = self.*;
        for (values) |value| {
            if (std.mem.indexOfScalar(u32, next.slice(), value) != null) continue;
            if (next.count == max_formats) return error.TopologyLimit;
            next.values[next.count] = value;
            next.count += 1;
        }
        self.* = next;
    }
};
pub fn connectorName(buffer: []u8, kind: u32, number: u32) ![]const u8 {
    const names = [_][]const u8{ "Unknown", "VGA", "DVI-I", "DVI-D", "DVI-A", "Composite", "SVIDEO", "LVDS", "Component", "DIN", "DP", "HDMI-A", "HDMI-B", "TV", "eDP", "Virtual", "DSI", "DPI", "Writeback", "SPI", "USB" };
    const name = if (kind < names.len) names[kind] else names[0];
    return std.fmt.bufPrint(buffer, "{s}-{d}", .{ name, number });
}
test "KMS formats retain unknown codes and reject overflow without partial unions" {
    const t = std.testing;
    var set: FormatSet = .{};
    try set.include(&.{ fourcc("NV12"), fourcc("XR24"), fourcc("NV12"), 0xdeadbeef });
    try t.expectEqual(@as(usize, 3), set.count);
    try t.expectEqualStrings("XRGB8888", processedFormat(fourcc("XR24")).?);
    try t.expectEqual(null, processedFormat(0xdeadbeef));
    var all: [256]u32 = undefined;
    for (&all, 0..) |*v, i| v.* = @intCast(i);
    set = .{};
    try set.include(&all);
    try t.expectError(error.TopologyLimit, set.include(&.{ 0, 999 }));
    try t.expectEqualSlices(u32, &all, set.slice());
}
test "KMS IDs masks and connector names preserve kernel object identities" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0xffffffff), try crtcMask(32));
    try t.expectEqual(@as(u32, 0), try crtcMask(0));
    try t.expectError(error.TopologyLimit, crtcMask(33));
    try t.expectError(error.InvalidTopology, validIds(&.{ 4, 7, 4 }));
    try t.expectError(error.InvalidTopology, validIds(&.{0}));
    var name: [32]u8 = undefined;
    try t.expectEqualStrings("HDMI-A-2", try connectorName(&name, 11, 2));
    try t.expectEqualStrings("Unknown-7", try connectorName(&name, 999, 7));
}
