//! Bounded, allocation-free classic-TIFF Exif directory views. Unknown tag
//! values are opaque; this is not a complete TIFF image/Exif conformance checker.
const std = @import("std");
pub const max_bytes = 16 * 1024 * 1024;
pub const max_directories = 32;
pub const max_entries = 4096;
pub const Kind = enum { image, exif, gps, interoperability };
pub const Entry = struct { tag: u16, field_type: u16, count: u32, bytes: []const u8 };
pub const Directory = struct { offset: usize, count: usize = 0, kind: Kind, primary: bool };
pub const View = struct {
    data: []const u8,
    endian: std.builtin.Endian,
    directories: [max_directories]Directory = undefined,
    count: usize = 0,
    pub fn entry(self: View, dir: Directory, index: usize) Entry {
        std.debug.assert(index < dir.count);
        const at = dir.offset + 2 + index * 12;
        const row = self.data[at..][0..12];
        const field_type = std.mem.readInt(u16, row[2..4], self.endian);
        const count = std.mem.readInt(u32, row[4..8], self.endian);
        const size = @as(usize, count) * typeSize(field_type).?;
        const start = if (size > 4) std.mem.readInt(u32, row[8..12], self.endian) else at + 8;
        return .{ .tag = std.mem.readInt(u16, row[0..2], self.endian), .field_type = field_type, .count = count, .bytes = self.data[start..][0..size] };
    }
    pub fn find(self: View, dir: Directory, tag: u16) ?Entry {
        for (0..dir.count) |i| {
            const value = self.entry(dir, i);
            if (value.tag == tag) return value;
        }
        return null;
    }
    fn append(self: *View, offset: usize, kind: Kind, primary: bool) !void {
        if (offset == 0) return;
        if (self.count == max_directories) return error.MetadataTooLarge;
        for (self.directories[0..self.count]) |dir| if (dir.offset == offset) return error.CyclicDirectory;
        self.directories[self.count] = .{ .offset = offset, .kind = kind, .primary = primary };
        self.count += 1;
    }
};
pub fn typeSize(kind: u16) ?usize {
    const sizes = [_]u8{ 0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 };
    return if (kind > 0 and kind < sizes.len) sizes[kind] else null;
}
pub fn validate(input: []const u8) !View {
    const data = if (std.mem.startsWith(u8, input, "Exif\x00\x00")) input[6..] else input;
    if (data.len < 8) return error.InvalidExif;
    if (data.len > max_bytes) return error.MetadataTooLarge;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, data[0..2], "II")) .little else if (std.mem.eql(u8, data[0..2], "MM")) .big else return error.InvalidExif;
    if (std.mem.readInt(u16, data[2..4], endian) != 42) return error.InvalidExif;
    const first = std.mem.readInt(u32, data[4..8], endian);
    if (first == 0) return error.InvalidExif;
    var result = View{ .data = data, .endian = endian };
    try result.append(first, .image, true);
    var index: usize = 0;
    var entries: usize = 0;
    var owned: usize = 0;
    while (index < result.count) : (index += 1) {
        const offset = result.directories[index].offset;
        if (offset < 8 or offset > data.len or data.len - offset < 6) return error.InvalidExif;
        const count: usize = std.mem.readInt(u16, data[offset..][0..2], endian);
        if (count > max_entries - entries) return error.MetadataTooLarge;
        if (count > (data.len - offset - 6) / 12) return error.InvalidExif;
        entries += count;
        result.directories[index].count = count;
        const dir = result.directories[index];
        for (0..count) |i| {
            const at = offset + 2 + i * 12;
            const row = data[at..][0..12];
            const tag = std.mem.readInt(u16, row[0..2], endian);
            const kind = std.mem.readInt(u16, row[2..4], endian);
            const items = std.mem.readInt(u32, row[4..8], endian);
            const size = std.math.mul(usize, items, typeSize(kind) orelse return error.UnsupportedFieldType) catch return error.InvalidExif;
            if (size > 4) {
                const start: usize = std.mem.readInt(u32, row[8..12], endian);
                if (start < 8 or start > data.len or size > data.len - start) return error.InvalidExif;
            }
            owned = std.math.add(usize, owned, size) catch return error.MetadataTooLarge;
            if (owned > 64 * 1024 * 1024) return error.MetadataTooLarge;
            for (0..i) |j| if (std.mem.readInt(u16, data[offset + 2 + j * 12 ..][0..2], endian) == tag) return error.DuplicateTag;
            const value = result.entry(dir, i);
            try shape(dir.kind, value);
            if (kind == 2 and (items == 0 or value.bytes[value.bytes.len - 1] != 0)) return error.InvalidExif;
            if (kind == 5 or kind == 10) {
                for (0..items) |n| if (std.mem.readInt(u32, value.bytes[n * 8 + 4 ..][0..4], endian) == 0) return error.InvalidExif;
            }
            if (pointerKind(dir.kind, tag)) |child| {
                const child_offset = std.mem.readInt(u32, value.bytes[0..4], endian);
                if (child_offset == 0) return error.InvalidExif;
                try result.append(child_offset, child, dir.primary);
            }
        }
        const next = std.mem.readInt(u32, data[offset + 2 + count * 12 ..][0..4], endian);
        try result.append(next, dir.kind, false);
    }
    // Directory bodies cannot overlap each other or out-of-line values. Exact
    // sharing of value bodies is legal and still charged to the owned budget.
    for (result.directories[0..result.count], 0..) |dir, i| {
        const end = dir.offset + 6 + dir.count * 12;
        for (result.directories[0..i]) |old| if (dir.offset < old.offset + 6 + old.count * 12 and old.offset < end) return error.InvalidExif;
        for (result.directories[0..result.count]) |values| for (0..values.count) |j| {
            const value = result.entry(values, j);
            if (value.bytes.len <= 4) continue;
            const begin = @intFromPtr(value.bytes.ptr) - @intFromPtr(data.ptr);
            if (begin < end and dir.offset < begin + value.bytes.len) return error.InvalidExif;
        };
    }
    for (result.directories[0..result.count]) |dir| {
        if (dir.kind != .image) continue;
        const start = result.find(dir, 0x0201);
        const length = result.find(dir, 0x0202);
        if ((start == null) != (length == null)) return error.InvalidThumbnail;
        if (start) |value| {
            const begin: usize = std.mem.readInt(u32, value.bytes[0..4], endian);
            const size: usize = std.mem.readInt(u32, length.?.bytes[0..4], endian);
            if (begin < 8 or size == 0 or begin > data.len or size > data.len - begin) return error.InvalidThumbnail;
            owned = std.math.add(usize, owned, size) catch return error.MetadataTooLarge;
            if (owned > 64 * 1024 * 1024) return error.MetadataTooLarge;
            for (result.directories[0..result.count]) |other| {
                if (begin < other.offset + 6 + other.count * 12 and other.offset < begin + size) return error.InvalidThumbnail;
            }
        }
    }
    return result;
}
fn pointerKind(kind: Kind, tag: u16) ?Kind {
    if (kind == .image) return switch (tag) {
        0x8769 => .exif,
        0x8825 => .gps,
        else => null,
    };
    if (kind == .exif and tag == 0xA005) return .interoperability;
    return null;
}
fn is(value: Entry, kind: u16, count: u32) bool {
    return value.field_type == kind and value.count == count;
}
fn shape(kind: Kind, v: Entry) !void {
    if (pointerKind(kind, v.tag) != null) {
        if (!is(v, 4, 1)) return error.InvalidExif;
        return;
    }
    if (kind == .gps) {
        switch (v.tag) {
            1, 3 => if (!is(v, 2, 2)) return error.InvalidExif,
            2, 4, 7 => if (!is(v, 5, 3)) return error.InvalidExif,
            5 => if (!is(v, 1, 1)) return error.InvalidExif,
            6 => if (!is(v, 5, 1)) return error.InvalidExif,
            29 => if (v.field_type != 2) return error.InvalidExif,
            else => {},
        }
    } else if (kind == .image or kind == .exif) {
        switch (v.tag) {
            0x010F, 0x0110, 0x0131, 0x013B, 0x8298, 0xA433, 0xA434, 0x0132, 0x9003, 0x9004 => if (v.field_type != 2) return error.InvalidExif,
            0x0100, 0x0101, 0xA002, 0xA003 => if (v.count != 1 or (v.field_type != 3 and v.field_type != 4)) return error.InvalidExif,
            0x0112, 0x8822, 0xA402, 0xA405, 0x9209, 0xA403, 0x9208, 0x9207, 0xA406, 0xA001 => if (!is(v, 3, 1)) return error.InvalidExif,
            0x829A, 0x829D, 0x920A, 0x9205 => if (!is(v, 5, 1)) return error.InvalidExif,
            0x9204 => if (!is(v, 10, 1)) return error.InvalidExif,
            0x8827 => if (v.count < 1 or (v.field_type != 3 and v.field_type != 4)) return error.InvalidExif,
            0x0201, 0x0202, 0x8833 => if (!is(v, 4, 1)) return error.InvalidExif,
            else => {},
        }
    }
}
