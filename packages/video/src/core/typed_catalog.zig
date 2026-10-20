//! Bounded, owned wire snapshots of typed capability/metadata records.
//! Headers are little endian; value payload byte order is explicit. No pointers
//! or backend enum assumptions cross this format. Readers borrow their source.
const std = @import("std");
pub const header_size = 16;
pub const record_size = 44;
pub const value_size = 28;
pub const Kind = enum(u32) { none, boolean, byte, i32, i64, f32, string, rectangle, size, u16, u32, point, unknown = 255 };
pub const array = 1;
pub const little_endian = 2;
pub const RecordInfo = struct {
    group: u32 = 0,
    id: u32 = 0,
    app_id: u32 = 0,
    native_type: u32 = 0,
    flags: u32 = 0,
    extent: u32 = 0,
    kind: Kind = .none,
    name: []const u8,
    vendor: []const u8 = "",
};
pub const Value = struct {
    role: u32 = 0,
    kind: Kind,
    native_type: u32 = 0,
    flags: u32 = little_endian,
    count: u32 = 1,
    label: []const u8 = "",
    data: []const u8,
};
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn get(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn kind(raw: u32) !Kind {
    return std.enums.fromInt(Kind, raw) orelse error.InvalidCatalog;
}
fn validValue(value: Value) !void {
    if (!std.unicode.utf8ValidateSlice(value.label)) return error.InvalidCatalog;
    const width: usize = switch (value.kind) {
        .none => 0,
        .boolean, .byte, .string => 1,
        .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .size, .point => 8,
        .rectangle => 16,
        .unknown => return,
    };
    if (value.kind == .none) {
        if (value.count != 0 or value.data.len != 0) return error.InvalidCatalog;
    } else if (value.data.len != @as(u64, value.count) * width) return error.InvalidCatalog;
    if (value.kind != .none and value.kind != .string and value.flags & array == 0 and value.count != 1) return error.InvalidCatalog;
    if (value.kind == .boolean) for (value.data) |b| {
        if (b > 1) return error.InvalidCatalog;
    };
}
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    limit: usize,
    open: ?usize = null,
    count: u32 = 0,
    pub fn init(allocator: std.mem.Allocator, catalog_kind: u32, limit: usize) !Writer {
        var w: Writer = .{ .allocator = allocator, .limit = @min(limit, std.math.maxInt(u32)) };
        errdefer w.deinit();
        const start = try w.extend(header_size);
        @memcpy(start[0..4], "HCAT");
        put(start, 4, 1);
        put(start, 8, catalog_kind);
        return w;
    }
    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.allocator);
        w.* = undefined;
    }
    fn extend(w: *Writer, length: usize) ![]u8 {
        if (length > w.limit - w.bytes.items.len) return error.CatalogFull;
        const offset = w.bytes.items.len;
        try w.bytes.resize(w.allocator, offset + length);
        const result = w.bytes.items[offset..];
        @memset(result, 0);
        return result;
    }
    pub fn begin(w: *Writer, info: RecordInfo) !void {
        if (w.open != null or w.count == std.math.maxInt(u32)) return error.InvalidCatalog;
        if (!std.unicode.utf8ValidateSlice(info.name) or !std.unicode.utf8ValidateSlice(info.vendor)) return error.InvalidCatalog;
        const length = std.math.add(usize, record_size, info.name.len) catch return error.CatalogFull;
        const total = std.math.add(usize, length, info.vendor.len) catch return error.CatalogFull;
        const offset = w.bytes.items.len;
        const dest = try w.extend(total);
        const fields = [_]u32{ @intCast(total), info.group, info.id, info.app_id, info.native_type, info.flags, info.extent, @intFromEnum(info.kind), @intCast(info.name.len), @intCast(info.vendor.len), 0 };
        for (fields, 0..) |field, i| put(dest, i * 4, field);
        @memcpy(dest[record_size..][0..info.name.len], info.name);
        @memcpy(dest[record_size + info.name.len ..], info.vendor);
        w.open = offset;
    }
    pub fn append(w: *Writer, value: Value) !void {
        const offset = w.open orelse return error.InvalidCatalog;
        try validValue(value);
        const length = std.math.add(usize, value_size, value.label.len) catch return error.CatalogFull;
        const total = std.math.add(usize, length, value.data.len) catch return error.CatalogFull;
        const count = get(w.bytes.items, offset + 40);
        if (count == std.math.maxInt(u32)) return error.CatalogFull;
        const dest = try w.extend(total);
        const fields = [_]u32{ @intCast(total), value.role, @intFromEnum(value.kind), value.native_type, value.flags, value.count, @intCast(value.label.len) };
        for (fields, 0..) |field, i| put(dest, i * 4, field);
        @memcpy(dest[value_size..][0..value.label.len], value.label);
        @memcpy(dest[value_size + value.label.len ..], value.data);
        put(w.bytes.items, offset, @intCast(w.bytes.items.len - offset));
        put(w.bytes.items, offset + 40, count + 1);
    }
    pub fn end(w: *Writer) !void {
        if (w.open == null) return error.InvalidCatalog;
        w.open = null;
        w.count += 1;
        put(w.bytes.items, 12, w.count);
    }
    pub fn finish(w: *const Writer) ![]const u8 {
        if (w.open != null) return error.InvalidCatalog;
        return w.bytes.items;
    }
};
pub const Record = struct {
    info: RecordInfo,
    data: []const u8,
    count: u32,
    pub fn values(r: Record) Values {
        return .{ .bytes = r.data, .remaining = r.count };
    }
};
pub const Values = struct {
    bytes: []const u8,
    remaining: u32,
    pub fn next(it: *Values) !?Value {
        if (it.remaining == 0) {
            if (it.bytes.len != 0) return error.InvalidCatalog;
            return null;
        }
        if (it.bytes.len < value_size) return error.InvalidCatalog;
        const total = get(it.bytes, 0);
        const label = get(it.bytes, 24);
        if (total < value_size or total > it.bytes.len or label > total - value_size) return error.InvalidCatalog;
        const value: Value = .{ .role = get(it.bytes, 4), .kind = try kind(get(it.bytes, 8)), .native_type = get(it.bytes, 12), .flags = get(it.bytes, 16), .count = get(it.bytes, 20), .label = it.bytes[value_size..][0..label], .data = it.bytes[value_size + label .. total] };
        try validValue(value);
        it.bytes = it.bytes[total..];
        it.remaining -= 1;
        return value;
    }
};
pub const Records = struct {
    bytes: []const u8,
    remaining: u32,
    pub fn next(it: *Records) !?Record {
        if (it.remaining == 0) {
            if (it.bytes.len != 0) return error.InvalidCatalog;
            return null;
        }
        if (it.bytes.len < record_size) return error.InvalidCatalog;
        const total = get(it.bytes, 0);
        const name = get(it.bytes, 32);
        const vendor = get(it.bytes, 36);
        if (total < record_size or total > it.bytes.len or name > total - record_size or vendor > total - record_size - name) return error.InvalidCatalog;
        const r: Record = .{ .info = .{ .group = get(it.bytes, 4), .id = get(it.bytes, 8), .app_id = get(it.bytes, 12), .native_type = get(it.bytes, 16), .flags = get(it.bytes, 20), .extent = get(it.bytes, 24), .kind = try kind(get(it.bytes, 28)), .name = it.bytes[record_size..][0..name], .vendor = it.bytes[record_size + name ..][0..vendor] }, .data = it.bytes[record_size + name + vendor .. total], .count = get(it.bytes, 40) };
        if (!std.unicode.utf8ValidateSlice(r.info.name) or !std.unicode.utf8ValidateSlice(r.info.vendor)) return error.InvalidCatalog;
        var values_it = r.values();
        while (try values_it.next()) |_| {}
        it.bytes = it.bytes[total..];
        it.remaining -= 1;
        return r;
    }
};
pub const Reader = struct {
    bytes: []const u8,
    catalog_kind: u32,
    count: u32,
    pub fn init(bytes: []const u8) !Reader {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], "HCAT") or get(bytes, 4) != 1) return error.InvalidCatalog;
        const r: Reader = .{ .bytes = bytes, .catalog_kind = get(bytes, 8), .count = get(bytes, 12) };
        var records_it = r.records();
        while (try records_it.next()) |_| {}
        return r;
    }
    pub fn records(r: Reader) Records {
        return .{ .bytes = r.bytes[header_size..], .remaining = r.count };
    }
};
fn sample(allocator: std.mem.Allocator) !void {
    var w = try Writer.init(allocator, 4, 2048);
    defer w.deinit();
    try w.begin(.{ .id = 7, .native_type = 55, .kind = .i64, .name = "Timestamp", .vendor = "test" });
    var payload: [8]u8 = undefined;
    std.mem.writeInt(i64, &payload, 9007199254740993, .little);
    try w.append(.{ .kind = .i64, .data = &payload });
    try w.append(.{ .role = 5, .kind = .byte, .flags = array, .count = 3, .label = "raw", .data = &.{ 7, 8, 9 } });
    try w.append(.{ .kind = .unknown, .native_type = 77, .count = 99, .data = &.{ 4, 3 } });
    try w.end();
    const r = try Reader.init(try w.finish());
    var records_it = r.records();
    const record = (try records_it.next()).?;
    try std.testing.expectEqualStrings("Timestamp", record.info.name);
    var values_it = record.values();
    try std.testing.expectEqual(@as(i64, 9007199254740993), std.mem.readInt(i64, (try values_it.next()).?.data[0..8], .little));
    try std.testing.expectEqualStrings("raw", (try values_it.next()).?.label);
    try std.testing.expectEqual(@as(u32, 77), (try values_it.next()).?.native_type);
    try std.testing.expect((try records_it.next()) == null);
}
test "typed snapshots retain exact i64, arrays, labels and unknown payloads under allocation failure" {
    try sample(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sample, .{});
}
test "bounded rejection leaves open records unchanged and malformed payloads reject" {
    var w = try Writer.init(std.testing.allocator, 3, 100);
    defer w.deinit();
    try w.begin(.{ .name = "x", .kind = .boolean });
    const before = try std.testing.allocator.dupe(u8, w.bytes.items);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.InvalidCatalog, w.append(.{ .kind = .boolean, .data = &.{2} }));
    try std.testing.expectError(error.CatalogFull, w.append(.{ .kind = .unknown, .data = &@as([80]u8, @splat(0)) }));
    try std.testing.expectEqualSlices(u8, before, w.bytes.items);
    try std.testing.expectError(error.InvalidCatalog, w.finish());
    try w.append(.{ .kind = .boolean, .data = &.{1} });
    try w.end();
    _ = try Reader.init(try w.finish());
}
test "all truncations, counts, lengths, tags and trailing bytes are validated" {
    var w = try Writer.init(std.testing.allocator, 4, 1024);
    defer w.deinit();
    try w.begin(.{ .name = "v", .kind = .rectangle });
    try w.append(.{ .kind = .rectangle, .flags = array | little_endian, .count = 2, .data = &@as([32]u8, @splat(0)) });
    try w.end();
    const original = try w.finish();
    for (0..original.len) |length| try std.testing.expectError(error.InvalidCatalog, Reader.init(original[0..length]));
    for ([_]usize{ 4, 12, 16, 44, 48, 52, 56, 61, 69, 81, 85 }) |offset| {
        const copy = try std.testing.allocator.dupe(u8, original);
        defer std.testing.allocator.free(copy);
        put(copy, offset, std.math.maxInt(u32));
        try std.testing.expectError(error.InvalidCatalog, Reader.init(copy));
    }
    try w.bytes.append(w.allocator, 0);
    try std.testing.expectError(error.InvalidCatalog, Reader.init(w.bytes.items));
}
