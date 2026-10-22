//! Add missing image/Exif fields to caller metadata. Original bytes/value
//! locations and secondary/GPS/interoperability directories remain in place.
//! Returns owned bare TIFF, with source tag values taking precedence. This is
//! not a MakerNote conformance checker or an image-container metadata merger.
const std = @import("std");
const layout = @import("exif_layout.zig");
const builder = @import("exif_builder.zig");
const copyValue = @import("exif_value.zig").copy;
const Row = struct { tag: u16, raw: ?[]const u8 = null, value: ?layout.Entry = null, body: usize = 0, pointer: bool = false };
const Plan = struct { first: usize, count: usize, offset: usize = 0, next: u32 = 0 };
fn add(a: usize, b: usize) !usize {
    const sum = std.math.add(usize, a, b) catch return error.MetadataTooLarge;
    if (sum > layout.max_bytes) return error.MetadataTooLarge;
    return sum;
}
fn less(_: void, a: Row, b: Row) bool {
    return a.tag < b.tag;
}
fn primaryExif(view: layout.View) ?layout.Directory {
    for (view.directories[0..view.count]) |dir| if (dir.primary and dir.kind == .exif) return dir;
    return null;
}
fn next(view: layout.View, dir: layout.Directory) u32 {
    return std.mem.readInt(u32, view.data[dir.offset + 2 + dir.count * 12 ..][0..4], view.endian);
}
/// Defaults are typed little-endian fields in .image/.exif groups only. Explicit
/// caller fields win even if their values are empty or zero. Null source creates
/// new metadata. Opaque proprietary internal pointer semantics remain caller-owned.
pub fn apply(allocator: std.mem.Allocator, source: ?[]const u8, defaults: []const builder.Field) ![]u8 {
    if (defaults.len > layout.max_entries - 6) return error.MetadataTooLarge;
    for (defaults) |field| if (field.group != .image and field.group != .exif) return error.UnsupportedDefaultDirectory;
    const template = try builder.encode(allocator, defaults, .{});
    if (source == null) return template;
    defer allocator.free(template);
    const raw = source.?;
    const original = try layout.validate(raw);
    const fallback = try layout.validate(template);
    const fallback_exif = primaryExif(fallback);
    const original_exif = primaryExif(original);
    const source_dirs = [_]?layout.Directory{ original.directories[0], original_exif };
    const default_dirs = [_]?layout.Directory{ fallback.directories[0], fallback_exif };
    const directories: usize = if (fallback_exif == null) 1 else 2;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var capacity: usize = 1;
    for (source_dirs) |maybe| if (maybe) |dir| {
        capacity += dir.count;
    };
    for (default_dirs) |maybe| if (maybe) |dir| {
        capacity += dir.count;
    };
    try rows.ensureTotalCapacityPrecise(allocator, capacity);
    var plans: [2]Plan = undefined;
    var changed = false;
    for (0..directories) |index| {
        const first = rows.items.len;
        if (source_dirs[index]) |dir| {
            for (0..dir.count) |i| {
                const value = original.entry(dir, i);
                if (index == 0 and directories == 2 and value.tag == 0x8769) continue;
                try rows.append(allocator, .{ .tag = value.tag, .raw = original.data[dir.offset + 2 + i * 12 ..][0..12] });
            }
        }
        if (default_dirs[index]) |dir| {
            for (0..dir.count) |i| {
                const value = fallback.entry(dir, i);
                if (index == 0 and value.tag == 0x8769) continue;
                const exists = if (source_dirs[index]) |old| original.find(old, value.tag) != null else false;
                if (exists) continue;
                changed = true;
                try rows.append(allocator, .{ .tag = value.tag, .value = value });
            }
        }
        if (index == 0 and directories == 2) try rows.append(allocator, .{ .tag = 0x8769, .pointer = true });
        const count = rows.items.len - first;
        if (count > layout.max_entries) return error.MetadataTooLarge;
        std.mem.sort(Row, rows.items[first..], {}, less);
        plans[index] = .{ .first = first, .count = count, .next = if (source_dirs[index]) |dir| next(original, dir) else 0 };
    }
    if (!changed) return allocator.dupe(u8, original.data);
    var total = try add(original.data.len, original.data.len % 2);
    for (plans[0..directories]) |*plan| {
        plan.offset = total;
        total = try add(total, 6 + plan.count * 12);
    }
    for (rows.items) |*row| if (row.value) |value| if (value.bytes.len > 4) {
        total = try add(total, total % 2);
        row.body = total;
        total = try add(total, value.bytes.len);
    };
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memcpy(out[0..original.data.len], original.data);
    @memset(out[original.data.len..], 0);
    const endian = original.endian;
    std.mem.writeInt(u32, out[4..8], @intCast(plans[0].offset), endian);
    for (plans[0..directories]) |plan| {
        std.mem.writeInt(u16, out[plan.offset..][0..2], @intCast(plan.count), endian);
        for (rows.items[plan.first..][0..plan.count], 0..) |row, i| {
            const entry = out[plan.offset + 2 + i * 12 ..][0..12];
            if (row.raw) |bytes| {
                @memcpy(entry, bytes);
                continue;
            }
            std.mem.writeInt(u16, entry[0..2], row.tag, endian);
            if (row.pointer) {
                std.mem.writeInt(u16, entry[2..4], 4, endian);
                std.mem.writeInt(u32, entry[4..8], 1, endian);
                std.mem.writeInt(u32, entry[8..12], @intCast(plans[1].offset), endian);
                continue;
            }
            const value = row.value.?;
            std.mem.writeInt(u16, entry[2..4], value.field_type, endian);
            std.mem.writeInt(u32, entry[4..8], value.count, endian);
            if (value.bytes.len > 4) {
                std.mem.writeInt(u32, entry[8..12], @intCast(row.body), endian);
                copyValue(out[row.body..][0..value.bytes.len], value.bytes, value.field_type, .little, endian);
            } else copyValue(entry[8..][0..value.bytes.len], value.bytes, value.field_type, .little, endian);
        }
        std.mem.writeInt(u32, out[plan.offset + 2 + plan.count * 12 ..][0..4], plan.next, endian);
    }
    _ = try layout.validate(out);
    return out;
}

fn defaultsFixture(allocator: std.mem.Allocator, input: ?[]const u8) ![]u8 {
    var fields = builder.Builder.init(allocator);
    defer fields.deinit();
    try fields.ascii(.image, 0x010f, "Default Make");
    try fields.ascii(.image, 0x0110, "Default Model");
    try fields.ascii(.image, 0x0131, "zig-camera");
    try fields.short(.image, 0x0112, 1);
    try fields.rational(.exif, 0x829a, 1, 125);
    try fields.long(.exif, 0x8833, 102400);
    return apply(allocator, input, fields.fields.items);
}
fn parseExif(view: layout.View) layout.Directory {
    return primaryExif(view).?;
}
test "missing defaults preserve explicit empty zero custom fields and original value locations" {
    const t = std.testing;
    var fields = builder.Builder.init(t.allocator);
    defer fields.deinit();
    try fields.ascii(.image, 0x010f, "Custom Make");
    try fields.ascii(.image, 0x0131, "");
    try fields.rational(.exif, 0x829a, 0, 100);
    try fields.bytes(.exif, 0x927c, 7, 9, "makerdata");
    try fields.bytes(.interoperability, 1, 2, 4, "R98\x00");
    try fields.bytes(.gps, 1, 2, 2, "S\x00");
    const source = try fields.finish(.{ .thumbnail = "\xff\xd8\xff\xd9" });
    defer t.allocator.free(source);
    const out = try defaultsFixture(t.allocator, source);
    defer t.allocator.free(out);
    try t.expectEqualSlices(u8, source[8..], out[8..source.len]);
    const old = try layout.validate(source);
    const checked = try layout.validate(out);
    try t.expectEqualSlices(u8, "Custom Make\x00", checked.find(checked.directories[0], 0x010f).?.bytes);
    try t.expectEqualSlices(u8, "\x00", checked.find(checked.directories[0], 0x0131).?.bytes);
    try t.expectEqualSlices(u8, "Default Model\x00", checked.find(checked.directories[0], 0x0110).?.bytes);
    const exposure = checked.find(parseExif(checked), 0x829a).?;
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, exposure.bytes[0..4], .little));
    const before = old.find(parseExif(old), 0x927c).?;
    const after = checked.find(parseExif(checked), 0x927c).?;
    try t.expectEqual(@intFromPtr(before.bytes.ptr) - @intFromPtr(old.data.ptr), @intFromPtr(after.bytes.ptr) - @intFromPtr(checked.data.ptr));
    try t.expectEqualSlices(u8, before.bytes, after.bytes);
    var image_dirs: usize = 0;
    for (checked.directories[0..checked.count]) |dir| if (dir.kind == .image) {
        image_dirs += 1;
    };
    try t.expectEqual(@as(usize, 2), image_dirs);
    const again = try defaultsFixture(t.allocator, out);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, out, again); // all defaults now present; no further append
}
test "big endian caller metadata and empty source Exif gain correctly encoded defaults" {
    const t = std.testing;
    var source: [44]u8 = @splat(0);
    @memcpy(source[0..8], "MM\x00*\x00\x00\x00\x08");
    std.mem.writeInt(u16, source[8..10], 2, .big);
    std.mem.writeInt(u16, source[10..12], 0x010f, .big);
    std.mem.writeInt(u16, source[12..14], 2, .big);
    std.mem.writeInt(u32, source[14..18], 2, .big);
    source[18] = 'Q';
    std.mem.writeInt(u16, source[22..24], 0x8769, .big);
    std.mem.writeInt(u16, source[24..26], 4, .big);
    std.mem.writeInt(u32, source[26..30], 1, .big);
    std.mem.writeInt(u32, source[30..34], 38, .big);
    const out = try defaultsFixture(t.allocator, &source);
    defer t.allocator.free(out);
    const view = try layout.validate(out);
    try t.expectEqual(std.builtin.Endian.big, view.endian);
    try t.expectEqualSlices(u8, "Q\x00", view.find(view.directories[0], 0x010f).?.bytes);
    const exposure = view.find(parseExif(view), 0x829a).?.bytes;
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, exposure[0..4], .big));
    try t.expectEqual(@as(u32, 125), std.mem.readInt(u32, exposure[4..8], .big));
    try t.expectEqual(@as(u32, 102400), std.mem.readInt(u32, view.find(parseExif(view), 0x8833).?.bytes[0..4], .big));
}
fn ownership(allocator: std.mem.Allocator) !void {
    const generated = try defaultsFixture(allocator, null);
    defer allocator.free(generated);
    var fields = builder.Builder.init(allocator);
    defer fields.deinit();
    try fields.ascii(.image, 0x010f, "Explicit");
    const source = try fields.finish(.{});
    defer allocator.free(source);
    const result = try defaultsFixture(allocator, source);
    defer allocator.free(result);
    const again = try defaultsFixture(allocator, result);
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, result, again);
}
test "every default construction merge and identity-copy allocation failure unwinds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownership, .{});
}
test "malformed metadata and unsupported default groups fail before returning output" {
    const t = std.testing;
    try t.expectError(error.InvalidExif, defaultsFixture(t.allocator, "bad"));
    var fields = builder.Builder.init(t.allocator);
    defer fields.deinit();
    try fields.bytes(.gps, 1, 2, 2, "S\x00");
    try t.expectError(error.UnsupportedDefaultDirectory, apply(t.allocator, null, fields.fields.items));
}
