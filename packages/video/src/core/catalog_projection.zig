//! Checked allocation-free projection of owned/borrowed HCAT records.
//! Selected records retain exact bytes, order, identity and opaque payloads.
const std = @import("std");
const wire = @import("typed_catalog.zig");
pub const Selection = struct { first_group: u32, last_group: u32, vendor: ?[]const u8 = null };
pub const Plan = struct { bytes: usize = wire.header_size, count: u32 = 0 };
fn selected(record: wire.Record, selection: Selection) bool {
    return record.info.group >= selection.first_group and record.info.group <= selection.last_group and (selection.vendor == null or std.mem.eql(u8, record.info.vendor, selection.vendor.?));
}
/// Checks every record/value, including unselected tails, before publishing size.
pub fn plan(reader: wire.Reader, selection: Selection) !Plan {
    if (selection.first_group > selection.last_group) return error.InvalidSelection;
    var result: Plan = .{};
    var records = reader.records();
    while (true) {
        const before = records.bytes.len;
        const record = (try records.next()) orelse break;
        if (selected(record, selection)) {
            result.bytes = try std.math.add(usize, result.bytes, before - records.bytes.len);
            result.count = try std.math.add(u32, result.count, 1);
        }
    }
    return result;
}
/// Source stays immutable/live and output owns its storage. Rejection never
/// writes a prefix; overlap is rejected. Extra destination suffix is unchanged.
pub fn copy(reader: wire.Reader, selection: Selection, output_kind: u32, output: []u8) !usize {
    const description = try plan(reader, selection);
    if (output.len < description.bytes) return error.BufferTooSmall;
    const start = @intFromPtr(reader.bytes.ptr);
    const end = try std.math.add(usize, start, reader.bytes.len);
    const dest = @intFromPtr(output.ptr);
    const dest_end = try std.math.add(usize, dest, description.bytes);
    if (start < dest_end and dest < end) return error.BufferOverlap;
    if (selection.vendor) |vendor| {
        const vendor_start = @intFromPtr(vendor.ptr);
        const vendor_end = try std.math.add(usize, vendor_start, vendor.len);
        if (vendor.len != 0 and vendor_start < dest_end and dest < vendor_end) return error.BufferOverlap;
    }
    @memcpy(output[0..4], "HCAT");
    std.mem.writeInt(u32, output[4..8], 1, .little);
    std.mem.writeInt(u32, output[8..12], output_kind, .little);
    std.mem.writeInt(u32, output[12..16], description.count, .little);
    var position: usize = wire.header_size;
    var records = reader.records();
    while (true) {
        const before = records.bytes;
        const record = (records.next() catch unreachable) orelse break;
        if (selected(record, selection)) {
            const length = before.len - records.bytes.len;
            @memcpy(output[position..][0..length], before[0..length]);
            position += length;
        }
    }
    return position;
}
fn fixture(w: *wire.Writer, group: u32, vendor: []const u8, id: u32) !void {
    try w.begin(.{ .group = group, .vendor = vendor, .id = id, .name = "opaque", .kind = .unknown, .native_type = 999 });
    try w.append(.{ .kind = .unknown, .native_type = 777, .count = 123, .data = &.{ 0, 255, 128, 1 } });
    try w.end();
}
test "catalog projection keeps selected record bytes and opaque order while replacing only the catalog header" {
    const t = std.testing;
    var w = try wire.Writer.init(t.allocator, 4, 4096);
    defer w.deinit();
    try fixture(&w, 5, "accepted", 1);
    try fixture(&w, 7, "foreign", 2);
    try fixture(&w, 7, "accepted", 3);
    try fixture(&w, 9, "accepted", 4);
    try fixture(&w, 8, "accepted", 5);
    const reader = try wire.Reader.init(try w.finish());
    const selection = Selection{ .first_group = 7, .last_group = 8, .vendor = "accepted" };
    const size = try plan(reader, selection);
    try t.expectEqual(@as(u32, 2), size.count);
    var out: [4096]u8 = @splat(42);
    const length = try copy(reader, selection, 7, &out);
    try t.expectEqual(size.bytes, length);
    try t.expectEqual(@as(u8, 42), out[length]);
    const projected = try wire.Reader.init(out[0..length]);
    try t.expectEqual(@as(u32, 7), projected.catalog_kind);
    var source = reader.records();
    var dest = projected.records();
    while (true) {
        const before = source.bytes;
        const record = (try source.next()) orelse break;
        if (!selected(record, selection)) continue;
        const expected = before[0 .. before.len - source.bytes.len];
        const at = dest.bytes;
        try t.expect((try dest.next()) != null);
        try t.expectEqualSlices(u8, expected, at[0 .. at.len - dest.bytes.len]);
    }
    try t.expect((try dest.next()) == null);
}
test "empty and all-record projections preserve input and output bounds" {
    const t = std.testing;
    var w = try wire.Writer.init(t.allocator, 4, 4096);
    defer w.deinit();
    try fixture(&w, 0, "", 1);
    const reader = try wire.Reader.init(try w.finish());
    var out: [4096]u8 = @splat(42);
    const length = try copy(reader, .{ .first_group = 0, .last_group = std.math.maxInt(u32) }, 4, &out);
    try t.expectEqualSlices(u8, reader.bytes, out[0..length]);
    try t.expectEqual(@as(usize, 16), try copy(reader, .{ .first_group = 1, .last_group = 1 }, 7, &out));
    const empty = try wire.Reader.init(out[0..16]);
    try t.expectEqual(@as(u32, 0), empty.count);
}
test "projection rejects short overlap invalid selection and late unselected damage before output mutation" {
    const t = std.testing;
    var w = try wire.Writer.init(t.allocator, 4, 4096);
    defer w.deinit();
    try fixture(&w, 1, "accepted", 1);
    try fixture(&w, 2, "foreign", 2);
    var reader = try wire.Reader.init(try w.finish());
    var out: [4096]u8 = @splat(42);
    const selection = Selection{ .first_group = 1, .last_group = 1 };
    const size = try plan(reader, selection);
    try t.expectError(error.BufferTooSmall, copy(reader, selection, 7, out[0 .. size.bytes - 1]));
    try t.expectError(error.InvalidSelection, copy(reader, .{ .first_group = 2, .last_group = 1 }, 7, &out));
    const source = try t.allocator.dupe(u8, reader.bytes);
    defer t.allocator.free(source);
    try t.expectError(error.BufferOverlap, copy(reader, selection, 7, w.bytes.items));
    try t.expectEqualSlices(u8, source, reader.bytes);
    reader.bytes = reader.bytes[0 .. reader.bytes.len - 1];
    try t.expectError(error.InvalidCatalog, copy(reader, selection, 7, &out));
    try t.expectEqualSlices(u8, &@as([4096]u8, @splat(42)), &out);
}

test "projection rejects a selection string aliased with output before the predicate can change" {
    const t = std.testing;
    var w = try wire.Writer.init(t.allocator, 4, 1024);
    defer w.deinit();
    try fixture(&w, 1, "accepted", 1);
    const reader = try wire.Reader.init(try w.finish());
    var out: [1024]u8 = @splat(42);
    @memcpy(out[0..8], "accepted");
    const before = out;
    try t.expectError(error.BufferOverlap, copy(reader, .{ .first_group = 1, .last_group = 1, .vendor = out[0..8] }, 7, &out));
    try t.expectEqualSlices(u8, &before, &out);
}
