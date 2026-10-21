//! Owned classic-TIFF Exif serialization. Field values use little-endian byte
//! order; caller inputs are borrowed only during encode. No image pixels change.
const std = @import("std");
const layout = @import("exif_layout.zig");
pub const Group = enum(u16) { image, exif, gps, interoperability, thumbnail };
pub const Field = struct { group: Group, tag: u16, field_type: u16, count: u32, data: []const u8 };
pub const Options = struct { thumbnail: ?[]const u8 = null };
fn reserved(tag: u16) bool {
    return tag == 0x8769 or tag == 0x8825 or tag == 0xA005 or tag == 0x0201 or tag == 0x0202;
}
fn less(_: void, a: Field, b: Field) bool {
    return a.tag < b.tag;
}
fn add(a: usize, b: usize) !usize {
    const value = std.math.add(usize, a, b) catch return error.MetadataTooLarge;
    if (value > layout.max_bytes) return error.MetadataTooLarge;
    return value;
}
pub fn encode(allocator: std.mem.Allocator, fields: []const Field, options: Options) ![]u8 {
    if (fields.len > layout.max_entries - 6) return error.MetadataTooLarge;
    var groups: [5]std.ArrayList(Field) = .{ .empty, .empty, .empty, .empty, .empty };
    defer for (&groups) |*group| group.deinit(allocator);
    for (fields) |field| {
        if (reserved(field.tag)) return error.ReservedTag;
        const size = std.math.mul(usize, field.count, layout.typeSize(field.field_type) orelse return error.UnsupportedFieldType) catch return error.MetadataTooLarge;
        if (size != field.data.len) return error.InvalidExif;
        if (field.field_type == 2 and (size == 0 or field.data[size - 1] != 0)) return error.InvalidExif;
        if (size > layout.max_bytes) return error.MetadataTooLarge;
        try groups[@intFromEnum(field.group)].append(allocator, field);
    }
    var pointer_data: [6][4]u8 = @splat(@splat(0));
    const active = [_]bool{ true, groups[1].items.len != 0 or groups[3].items.len != 0, groups[2].items.len != 0, groups[3].items.len != 0, groups[4].items.len != 0 or options.thumbnail != null };
    if (active[1]) try groups[0].append(allocator, .{ .group = .image, .tag = 0x8769, .field_type = 4, .count = 1, .data = &pointer_data[0] });
    if (active[2]) try groups[0].append(allocator, .{ .group = .image, .tag = 0x8825, .field_type = 4, .count = 1, .data = &pointer_data[1] });
    if (active[3]) try groups[1].append(allocator, .{ .group = .exif, .tag = 0xA005, .field_type = 4, .count = 1, .data = &pointer_data[2] });
    if (options.thumbnail) |thumbnail| {
        if (thumbnail.len < 4 or thumbnail.len > layout.max_bytes or !std.mem.startsWith(u8, thumbnail, "\xff\xd8") or !std.mem.endsWith(u8, thumbnail, "\xff\xd9")) return error.InvalidThumbnail;
        std.mem.writeInt(u16, pointer_data[3][0..2], 6, .little);
        std.mem.writeInt(u32, &pointer_data[5], @intCast(thumbnail.len), .little);
        try groups[4].append(allocator, .{ .group = .thumbnail, .tag = 0x0103, .field_type = 3, .count = 1, .data = pointer_data[3][0..2] });
        try groups[4].append(allocator, .{ .group = .thumbnail, .tag = 0x0201, .field_type = 4, .count = 1, .data = &pointer_data[4] });
        try groups[4].append(allocator, .{ .group = .thumbnail, .tag = 0x0202, .field_type = 4, .count = 1, .data = &pointer_data[5] });
    }
    var offsets: [5]usize = @splat(0);
    var total: usize = 8;
    for (&groups, 0..) |*group, i| {
        if (!active[i]) continue;
        std.mem.sort(Field, group.items, {}, less);
        for (group.items, 0..) |field, n| if (n != 0 and group.items[n - 1].tag == field.tag) return error.DuplicateTag;
        offsets[i] = total;
        total = try add(total, 6 + group.items.len * 12);
    }
    for ([_]usize{ 1, 2, 3 }, 0..) |group, i| std.mem.writeInt(u32, &pointer_data[i], @intCast(offsets[group]), .little);
    const bodies = total;
    for (groups) |group| for (group.items) |field| if (field.data.len > 4) {
        total = try add(total, total % 2);
        total = try add(total, field.data.len);
    };
    if (options.thumbnail) |thumbnail| {
        total = try add(total, total % 2);
        std.mem.writeInt(u32, &pointer_data[4], @intCast(total), .little);
        total = try add(total, thumbnail.len);
    }
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    @memcpy(out[0..4], "II*\x00");
    std.mem.writeInt(u32, out[4..8], 8, .little);
    var cursor = bodies;
    for (groups, 0..) |group, i| {
        if (!active[i]) continue;
        const start = offsets[i];
        std.mem.writeInt(u16, out[start..][0..2], @intCast(group.items.len), .little);
        for (group.items, 0..) |field, n| {
            const at = start + 2 + n * 12;
            std.mem.writeInt(u16, out[at..][0..2], field.tag, .little);
            std.mem.writeInt(u16, out[at + 2 ..][0..2], field.field_type, .little);
            std.mem.writeInt(u32, out[at + 4 ..][0..4], field.count, .little);
            if (field.data.len <= 4) @memcpy(out[at + 8 ..][0..field.data.len], field.data) else {
                cursor += cursor % 2;
                std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(cursor), .little);
                @memcpy(out[cursor..][0..field.data.len], field.data);
                cursor += field.data.len;
            }
        }
        if (i == 0) std.mem.writeInt(u32, out[start + 2 + group.items.len * 12 ..][0..4], @intCast(offsets[4]), .little);
    }
    if (options.thumbnail) |thumbnail| {
        cursor += cursor % 2;
        @memcpy(out[cursor..][0..thumbnail.len], thumbnail);
    }
    _ = try layout.validate(out);
    return out;
}
/// Convenience owner for typed fields. Every added value is copied. Generic
/// encode() additionally supports borrowed arrays without this builder owner.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    fields: std.ArrayList(Field) = .empty,
    owned_bytes: usize = 0,
    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Builder) void {
        for (self.fields.items) |field| self.allocator.free(field.data);
        self.fields.deinit(self.allocator);
    }
    fn capacity(self: *Builder, size: usize) !void {
        if (self.fields.items.len >= layout.max_entries - 6 or size > layout.max_bytes - self.owned_bytes) return error.MetadataTooLarge;
    }
    fn owned(self: *Builder, group: Group, tag: u16, kind: u16, count: u32, value: []u8) !void {
        errdefer self.allocator.free(value);
        try self.fields.append(self.allocator, .{ .group = group, .tag = tag, .field_type = kind, .count = count, .data = value });
        self.owned_bytes += value.len;
    }
    pub fn bytes(self: *Builder, group: Group, tag: u16, kind: u16, count: u32, value: []const u8) !void {
        try self.capacity(value.len);
        try self.owned(group, tag, kind, count, try self.allocator.dupe(u8, value));
    }
    pub fn ascii(self: *Builder, group: Group, tag: u16, value: []const u8) !void {
        if (value.len >= layout.max_bytes or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
        for (value) |byte| if (byte > 127) return error.InvalidText;
        try self.capacity(value.len + 1);
        const copy = try self.allocator.alloc(u8, value.len + 1);
        @memcpy(copy[0..value.len], value);
        copy[value.len] = 0;
        try self.owned(group, tag, 2, @intCast(copy.len), copy);
    }
    pub fn short(self: *Builder, group: Group, tag: u16, value: u16) !void {
        var data: [2]u8 = undefined;
        std.mem.writeInt(u16, &data, value, .little);
        try self.bytes(group, tag, 3, 1, &data);
    }
    pub fn long(self: *Builder, group: Group, tag: u16, value: u32) !void {
        var data: [4]u8 = undefined;
        std.mem.writeInt(u32, &data, value, .little);
        try self.bytes(group, tag, 4, 1, &data);
    }
    pub fn rational(self: *Builder, group: Group, tag: u16, numerator: u32, denominator: u32) !void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(u32, data[0..4], numerator, .little);
        std.mem.writeInt(u32, data[4..8], denominator, .little);
        try self.bytes(group, tag, 5, 1, &data);
    }
    pub fn srational(self: *Builder, group: Group, tag: u16, numerator: i32, denominator: i32) !void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(i32, data[0..4], numerator, .little);
        std.mem.writeInt(i32, data[4..8], denominator, .little);
        try self.bytes(group, tag, 10, 1, &data);
    }
    pub fn finish(self: *Builder, options: Options) ![]u8 {
        return encode(self.allocator, self.fields.items, options);
    }
};
