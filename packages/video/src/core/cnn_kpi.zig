//! Exact signed libcamera counters plus the pinned Picamera2 /1000 view. Keep
//! raw counters: the upstream control documentation disagrees about units.
const std = @import("std");
const wire = @import("typed_catalog.zig");
pub const Info = struct {
    dnn_raw: i32,
    dsp_raw: i32,
    pub fn picameraMilliseconds(self: Info) [2]f64 {
        return .{ @as(f64, @floatFromInt(self.dnn_raw)) / 1000, @as(f64, @floatFromInt(self.dsp_raw)) / 1000 };
    }
    pub fn fromRaw(bytes: []const u8, endian: std.builtin.Endian) !Info {
        if (bytes.len != 8) return error.InvalidKpi;
        return .{ .dnn_raw = std.mem.readInt(i32, bytes[0..4], endian), .dsp_raw = std.mem.readInt(i32, bytes[4..8], endian) };
    }
    pub fn fromCatalog(bytes: []const u8) !?Info {
        const reader = try wire.Reader.init(bytes);
        if (reader.catalog_kind != 4) return error.InvalidCatalogKind;
        const value = try reader.findValue(.i32, .{ .name = "CnnKpiInfo", .vendors = &.{ "rpi", "libcamera", "" }, .forbidden_flags = 1 }) orelse return null;
        if (value.count != 2 or value.flags & wire.array == 0 or value.flags & ~@as(u32, wire.array | wire.little_endian) != 0) return error.InvalidKpi;
        return try fromRaw(value.data, if (value.flags & wire.little_endian != 0) .little else .big);
    }
};
test "KPI counters retain signed extremes exact byte order and fractional milliseconds" {
    const t = std.testing;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var raw: [8]u8 = undefined;
        std.mem.writeInt(i32, raw[0..4], 13961, endian);
        std.mem.writeInt(i32, raw[4..8], 12360, endian);
        const info = try Info.fromRaw(&raw, endian);
        try t.expectEqual(@as(i32, 13961), info.dnn_raw);
        try t.expectEqualDeep([2]f64{ 13.961, 12.36 }, info.picameraMilliseconds());
        std.mem.writeInt(i32, raw[0..4], std.math.minInt(i32), endian);
        std.mem.writeInt(i32, raw[4..8], std.math.maxInt(i32), endian);
        const extremes = try Info.fromRaw(&raw, endian);
        try t.expectEqual(std.math.minInt(i32), extremes.dnn_raw);
        try t.expectEqual(std.math.maxInt(i32), extremes.dsp_raw);
    }
    try t.expectError(error.InvalidKpi, Info.fromRaw(&.{}, .little));
}
test "KPI lookup requires exact count kind role flags provenance and no duplicate" {
    const t = std.testing;
    var writer = try wire.Writer.init(t.allocator, 4, 4096);
    defer writer.deinit();
    try t.expectEqual(@as(?Info, null), try Info.fromCatalog(try writer.finish()));
    const raw = [_]u8{ 0x88, 0x13, 0, 0, 0xe8, 3, 0, 0 };
    try writer.begin(.{ .name = "CnnKpiInfo", .vendor = "rpi", .kind = .i32, .flags = 2 });
    try writer.append(.{ .kind = .i32, .count = 2, .flags = wire.array | wire.little_endian, .data = &raw });
    try writer.end();
    try t.expectEqualDeep(Info{ .dnn_raw = 5000, .dsp_raw = 1000 }, (try Info.fromCatalog(try writer.finish())).?);
    try writer.begin(.{ .name = "CnnKpiInfo", .vendor = "libcamera", .kind = .i32, .flags = 2 });
    try writer.append(.{ .kind = .i32, .count = 2, .flags = wire.array | wire.little_endian, .data = &raw });
    try writer.end();
    try t.expectError(error.AmbiguousValue, Info.fromCatalog(try writer.finish()));
    var bad = try wire.Writer.init(t.allocator, 4, 1024);
    defer bad.deinit();
    try bad.begin(.{ .name = "CnnKpiInfo", .kind = .i32 });
    try bad.append(.{ .kind = .i32, .count = 1, .data = raw[0..4] });
    try bad.end();
    try t.expectError(error.InvalidKpi, Info.fromCatalog(try bad.finish()));
}
