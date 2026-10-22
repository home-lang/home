//! Append-only classic TIFF metadata merge. Existing sample bytes, offsets and
//! page directories remain in place. New Exif directory/value offsets are owned
//! by this output; unknown MakerNote-internal offsets remain caller-owned.
const std = @import("std");
const exif = @import("metadata/exif_layout.zig");
const Row = struct {
    tag: u16,
    original: ?[]const u8 = null,
    value: ?exif.Entry = null,
    body: usize = 0,
    endian: ?std.builtin.Endian = null,
    thumbnail: ?[]const u8 = null,
};
const Plan = struct { first: usize, count: usize, offset: usize = 0 };
fn less(_: void, a: Row, b: Row) bool {
    return a.tag < b.tag;
}
fn add(a: usize, b: usize) !usize {
    const sum = std.math.add(usize, a, b) catch return error.MetadataTooLarge;
    if (sum > std.math.maxInt(u32)) return error.MetadataTooLarge;
    return sum;
}
fn protected(tag: u16) bool {
    // Image geometry/layout and external pixel pointers are owned by the image,
    // never by an Exif blob. Child metadata pointers are relocated separately.
    return switch (tag) {
        254, 255, 256, 257, 258, 259, 262, 263, 264, 265, 266, 273, 277, 278, 279, 280, 281, 284, 292, 293, 301, 317, 320, 322, 323, 324, 325, 330, 332, 333, 334, 336, 337, 338, 339, 340, 341, 347, 512, 513, 514, 515, 517, 518, 519, 520, 521, 529, 530, 531, 532, 34675 => true,
        else => false,
    };
}
fn pointer(kind: exif.Kind, tag: u16) bool {
    return (kind == .image and (tag == 0x8769 or tag == 0x8825)) or (kind == .exif and tag == 0xa005);
}
fn findDirectory(view: exif.View, offset: u32) !usize {
    for (view.directories[0..view.count], 0..) |dir, i| if (dir.offset == offset) return i;
    return error.InvalidExif;
}
const copyValue = @import("metadata/exif_value.zig").copy;
pub fn check(view: exif.View) !void {
    for (view.directories[0..view.count], 0..) |dir, i| for (0..dir.count) |n| {
        const tag = view.entry(dir, n).tag;
        if (i == 0 and protected(tag)) return error.ProtectedImageTag;
        if (dir.kind == .image and i != 0) switch (tag) {
            273, 288, 289, 324, 330, 519, 520, 521 => return error.UnsupportedThumbnail,
            else => {},
        };
    };
}
fn oldThumbnailNext(image: []const u8, offset: usize, endian: std.builtin.Endian) !?u32 {
    if (offset < 8 or offset % 2 != 0 or offset > image.len or image.len - offset < 6) return error.InvalidImage;
    const count: usize = std.mem.readInt(u16, image[offset..][0..2], endian);
    if (count > 4096 or count > (image.len - offset - 6) / 12) return error.InvalidImage;
    var reduced = false;
    var jpeg = false;
    var start: ?u32 = null;
    var length: ?u32 = null;
    for (0..count) |i| {
        const row = image[offset + 2 + i * 12 ..][0..12];
        const tag = std.mem.readInt(u16, row[0..2], endian);
        const kind = std.mem.readInt(u16, row[2..4], endian);
        const items = std.mem.readInt(u32, row[4..8], endian);
        if (tag == 254 and kind == 4 and items == 1) reduced = std.mem.readInt(u32, row[8..12], endian) & 1 != 0;
        if (tag == 259 and kind == 3 and items == 1) jpeg = std.mem.readInt(u16, row[8..10], endian) == 6;
        if (tag == 513 and kind == 4 and items == 1) start = std.mem.readInt(u32, row[8..12], endian);
        if (tag == 514 and kind == 4 and items == 1) length = std.mem.readInt(u32, row[8..12], endian);
    }
    if (!reduced or !jpeg or start == null or length == null) return null;
    if (start.? < 8 or length.? == 0 or start.? > image.len or length.? > image.len - start.?) return error.InvalidImage;
    return std.mem.readInt(u32, image[offset + 2 + count * 12 ..][0..4], endian);
}
/// ICC has been validated by the public embedding entry point. Exif is a
/// validated borrowed view. Existing TIFF root entries must be sorted/unique.
pub fn merge(allocator: std.mem.Allocator, image: []const u8, profile: ?[]const u8, metadata: ?exif.View) ![]u8 {
    if (metadata) |view| try check(view);
    if (image.len < 8 or image.len > std.math.maxInt(u32)) return error.InvalidImage;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, image[0..2], "II")) .little else if (std.mem.eql(u8, image[0..2], "MM")) .big else return error.InvalidImage;
    if (std.mem.readInt(u16, image[2..4], endian) != 42) return error.UnsupportedFormat;
    const root: usize = std.mem.readInt(u32, image[4..8], endian);
    if (root < 8 or root % 2 != 0 or root > image.len or image.len - root < 6) return error.InvalidImage;
    const count: usize = std.mem.readInt(u16, image[root..][0..2], endian);
    if (count > 4096 or count > (image.len - root - 6) / 12) return error.InvalidImage;
    var next = std.mem.readInt(u32, image[root + 2 + count * 12 ..][0..4], endian);
    if (next != 0 and (next < 8 or next % 2 != 0 or next > image.len - 2 or next == root)) return error.InvalidImage;
    if (metadata) |view| {
        var has_thumbnail = false;
        for (view.directories[0..view.count]) |dir| if (dir.kind == .image and !dir.primary and view.find(dir, 513) != null) {
            has_thumbnail = true;
        };
        if (has_thumbnail) {
            var visited: [exif.max_directories]u32 = undefined;
            var visited_count: usize = 0;
            while (next != 0) {
                if (visited_count == visited.len or next == root) return error.InvalidImage;
                for (visited[0..visited_count]) |old| if (old == next) return error.InvalidImage;
                visited[visited_count] = next;
                visited_count += 1;
                next = try oldThumbnailNext(image, next, endian) orelse break;
            }
        }
    }
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var plans: [exif.max_directories]Plan = undefined;
    const directories = if (metadata) |view| view.count else 1;
    var row_capacity = count + @intFromBool(profile != null);
    if (metadata) |view| for (view.directories[0..view.count]) |dir| {
        row_capacity += dir.count;
        if (dir.kind == .image and !dir.primary and view.find(dir, 513) != null) row_capacity += 1;
    };
    try rows.ensureTotalCapacityPrecise(allocator, row_capacity);
    var previous: u16 = 0;
    var rgb = false;
    for (0..count) |i| {
        const entry = image[root + 2 + i * 12 ..][0..12];
        const tag = std.mem.readInt(u16, entry[0..2], endian);
        const kind = std.mem.readInt(u16, entry[2..4], endian);
        const items = std.mem.readInt(u32, entry[4..8], endian);
        if (i != 0 and tag <= previous) return error.InvalidImage;
        previous = tag;
        const size = std.math.mul(usize, items, exif.typeSize(kind) orelse return error.UnsupportedFormat) catch return error.InvalidImage;
        if (size > 4) {
            const offset: usize = std.mem.readInt(u32, entry[8..12], endian);
            if (offset < 8 or offset > image.len or size > image.len - offset) return error.InvalidImage;
        }
        if (tag == 262) rgb = kind == 3 and items == 1 and std.mem.readInt(u16, entry[8..10], endian) == 2;
        if (profile != null and tag == 34675) continue;
        if (metadata) |view| {
            if (view.find(view.directories[0], tag) != null) continue;
        }
        try rows.append(allocator, .{ .tag = tag, .original = entry });
    }
    if (profile != null and !rgb) return error.UnsupportedFormat;
    for (0..directories) |i| {
        const first = if (i == 0) 0 else rows.items.len;
        if (metadata) |view| {
            const dir = view.directories[i];
            const jpeg_thumbnail = dir.kind == .image and !dir.primary and view.find(dir, 513) != null;
            for (0..dir.count) |n| {
                const value = view.entry(dir, n);
                if (i == 0 and protected(value.tag)) return error.ProtectedImageTag;
                if (jpeg_thumbnail and value.tag == 254) continue;
                var row = Row{ .tag = value.tag, .value = value };
                if (dir.kind == .image and value.tag == 0x0201) {
                    const offset = std.mem.readInt(u32, value.bytes[0..4], view.endian);
                    const length = std.mem.readInt(u32, view.find(dir, 0x0202).?.bytes[0..4], view.endian);
                    row.thumbnail = view.data[offset..][0..length];
                }
                try rows.append(allocator, row);
            }
            if (jpeg_thumbnail) try rows.append(allocator, .{ .tag = 254, .endian = .little, .value = .{ .tag = 254, .field_type = 4, .count = 1, .bytes = &.{ 1, 0, 0, 0 } } });
        }
        if (i == 0) if (profile) |bytes| try rows.append(allocator, .{ .tag = 34675, .value = .{ .tag = 34675, .field_type = 7, .count = @intCast(bytes.len), .bytes = bytes } });
        const size = rows.items.len - first;
        if (size > 4096) return error.MetadataTooLarge;
        std.mem.sort(Row, rows.items[first..], {}, less);
        plans[i] = .{ .first = first, .count = size };
    }
    var total = try add(image.len, image.len % 2);
    for (plans[0..directories]) |*plan| {
        plan.offset = total;
        total = try add(total, 6 + plan.count * 12);
    }
    for (rows.items) |*row| if (row.value) |value| {
        const length = if (row.thumbnail) |bytes| bytes.len else if (value.bytes.len > 4) value.bytes.len else 0;
        if (length != 0) {
            total = try add(total, total % 2);
            row.body = total;
            total = try add(total, length);
        }
    };
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memcpy(out[0..image.len], image);
    @memset(out[image.len..], 0);
    std.mem.writeInt(u32, out[4..8], @intCast(plans[0].offset), endian);
    for (plans[0..directories], 0..) |plan, i| {
        std.mem.writeInt(u16, out[plan.offset..][0..2], @intCast(plan.count), endian);
        for (rows.items[plan.first..][0..plan.count], 0..) |row, n| {
            const entry = out[plan.offset + 2 + n * 12 ..][0..12];
            if (row.original) |original| {
                @memcpy(entry, original);
                continue;
            }
            const value = row.value.?;
            std.mem.writeInt(u16, entry[0..2], value.tag, endian);
            std.mem.writeInt(u16, entry[2..4], value.field_type, endian);
            std.mem.writeInt(u32, entry[4..8], value.count, endian);
            if (row.thumbnail) |bytes| {
                std.mem.writeInt(u32, entry[8..12], @intCast(row.body), endian);
                @memcpy(out[row.body..][0..bytes.len], bytes);
            } else if (metadata != null and pointer(metadata.?.directories[i].kind, value.tag)) {
                const child = try findDirectory(metadata.?, std.mem.readInt(u32, value.bytes[0..4], metadata.?.endian));
                std.mem.writeInt(u32, entry[8..12], @intCast(plans[child].offset), endian);
            } else {
                const source = row.endian orelse if (value.tag == 34675 and i == 0) endian else metadata.?.endian;
                if (value.bytes.len > 4) {
                    std.mem.writeInt(u32, entry[8..12], @intCast(row.body), endian);
                    copyValue(out[row.body..][0..value.bytes.len], value.bytes, value.field_type, source, endian);
                } else copyValue(entry[8..][0..value.bytes.len], value.bytes, value.field_type, source, endian);
            }
        }
        var following = next;
        if (metadata) |view| {
            const dir = view.directories[i];
            const original_next = std.mem.readInt(u32, view.data[dir.offset + 2 + dir.count * 12 ..][0..4], view.endian);
            following = if (original_next != 0) @intCast(plans[try findDirectory(view, original_next)].offset) else if (dir.kind == .image) next else 0;
        }
        std.mem.writeInt(u32, out[plan.offset + 2 + plan.count * 12 ..][0..4], following, endian);
    }
    return out;
}
