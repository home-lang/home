//! Transactional owned state for typed catalogs. IDs are caller-defined u32 keys;
//! prepare a replacement before external commit, then swap/deinit the old writer.
const std = @import("std");
const wire = @import("typed_catalog.zig");
pub fn updated(allocator: std.mem.Allocator, source: ?wire.Reader, updates: wire.Reader, removed: []const u32, output_kind: u32, max_records: usize, max_bytes: usize) !wire.Writer {
    if (max_records == 0 or updates.count > max_records or removed.len > max_records) return error.StateFull;
    var records: std.ArrayList(wire.Record) = .empty;
    defer records.deinit(allocator);
    if (source) |reader| {
        if (reader.count > max_records) return error.StateFull;
        var it = reader.records();
        while (try it.next()) |record| {
            if (record.info.id == 0 or record.info.group != 0) return error.InvalidKey;
            for (records.items) |previous| if (previous.info.id == record.info.id) return error.DuplicateKey;
            try records.append(allocator, record);
        }
    }
    var position: usize = 0;
    while (position < records.items.len) {
        const record = records.items[position];
        var erase = false;
        for (removed) |id| if (id == record.info.id) {
            erase = true;
        };
        if (erase) {
            _ = records.orderedRemove(position);
        } else position += 1;
    }
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(allocator);
    var it = updates.records();
    while (try it.next()) |record| {
        if (record.info.id == 0 or record.info.group != 0) return error.InvalidKey;
        for (seen.items) |id| if (id == record.info.id) return error.DuplicateKey;
        try seen.append(allocator, record.info.id);
        var found = false;
        for (records.items) |*previous| if (previous.info.id == record.info.id) {
            previous.* = record;
            found = true;
            break;
        };
        if (!found) {
            if (records.items.len == max_records) return error.StateFull;
            try records.append(allocator, record);
        }
    }
    std.mem.sort(wire.Record, records.items, {}, struct {
        fn less(_: void, a: wire.Record, b: wire.Record) bool {
            return a.info.id < b.info.id;
        }
    }.less);
    var writer = try wire.Writer.init(allocator, output_kind, max_bytes);
    errdefer writer.deinit();
    for (records.items) |record| {
        try writer.begin(record.info);
        var values = record.values();
        while (try values.next()) |value| try writer.append(value);
        try writer.end();
    }
    return writer;
}
fn addRecord(w: *wire.Writer, id: u32, data: []const u8) !void {
    try w.begin(.{ .id = id, .kind = .byte, .name = "payload" });
    try w.append(.{ .kind = .byte, .flags = wire.array, .count = @intCast(data.len), .data = data });
    try w.end();
}
fn exercise(allocator: std.mem.Allocator) !void {
    var source = try wire.Writer.init(allocator, 5, 1024);
    defer source.deinit();
    try addRecord(&source, 7, &.{7});
    try addRecord(&source, 3, &.{3});
    var changes = try wire.Writer.init(allocator, 6, 1024);
    defer changes.deinit();
    try addRecord(&changes, 7, &.{ 8, 9 });
    try addRecord(&changes, 2, &.{2});
    var result = try updated(allocator, try wire.Reader.init(try source.finish()), try wire.Reader.init(try changes.finish()), &.{3}, 5, 2, 1024);
    defer result.deinit();
    var it = (try wire.Reader.init(try result.finish())).records();
    try std.testing.expectEqual(@as(u32, 2), (try it.next()).?.info.id);
    var values = (try it.next()).?.values();
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, (try values.next()).?.data);
    @memset(source.bytes.items, 0);
    @memset(changes.bytes.items, 0);
    _ = try wire.Reader.init(try result.finish());
}
test "catalog state stages sorted owned replacements and survives all allocation failures" {
    try exercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercise, .{});
}
test "duplicate/invalid keys and capacity failure never alter the source" {
    var source = try wire.Writer.init(std.testing.allocator, 5, 1024);
    defer source.deinit();
    try addRecord(&source, 1, &.{1});
    const original = try std.testing.allocator.dupe(u8, source.bytes.items);
    defer std.testing.allocator.free(original);
    var changes = try wire.Writer.init(std.testing.allocator, 6, 1024);
    defer changes.deinit();
    try addRecord(&changes, 2, &.{2});
    try std.testing.expectError(error.StateFull, updated(std.testing.allocator, try wire.Reader.init(try source.finish()), try wire.Reader.init(try changes.finish()), &.{}, 5, 1, 1024));
    try std.testing.expectError(error.CatalogFull, updated(std.testing.allocator, try wire.Reader.init(try source.finish()), try wire.Reader.init(try changes.finish()), &.{}, 5, 2, 16));
    try addRecord(&changes, 2, &.{3});
    try std.testing.expectError(error.DuplicateKey, updated(std.testing.allocator, null, try wire.Reader.init(try changes.finish()), &.{}, 5, 3, 1024));
    for ([_]wire.RecordInfo{ .{ .id = 0, .kind = .byte, .name = "bad" }, .{ .id = 1, .group = 1, .kind = .byte, .name = "bad" } }) |invalid| {
        var bad = try wire.Writer.init(std.testing.allocator, 6, 1024);
        defer bad.deinit();
        try bad.begin(invalid);
        try bad.end();
        const reader = try wire.Reader.init(try bad.finish());
        try std.testing.expectError(error.InvalidKey, updated(std.testing.allocator, null, reader, &.{}, 5, 3, 1024));
        try std.testing.expectError(error.InvalidKey, updated(std.testing.allocator, reader, try wire.Reader.init(try source.finish()), &.{1}, 5, 3, 1024));
    }
    try std.testing.expectEqualSlices(u8, original, source.bytes.items);
}
