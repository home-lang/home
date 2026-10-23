//! Exact nested HCAT snapshots. No decoded-value conversion or backend identity.
const std = @import("std");
const wire = @import("typed_catalog.zig");
pub const snapshot_flags: u32 = 2 | 4 | 8 | 16 | 32;
pub const Spec = struct {
    group: u32,
    id: u32,
    name: []const u8,
    vendor: []const u8,
    inner_kind: u32,
    max_bytes: usize,
    fn check(s: Spec) !void {
        if (s.inner_kind == 0 or s.max_bytes < wire.header_size or s.max_bytes > std.math.maxInt(u32) or s.name.len == 0 or s.vendor.len == 0 or !std.unicode.utf8ValidateSlice(s.name) or !std.unicode.utf8ValidateSlice(s.vendor)) return error.InvalidEnvelope;
    }
};
fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const first = @intFromPtr(a.ptr);
    const second = @intFromPtr(b.ptr);
    return if (first <= second) second - first < a.len else first - second < b.len;
}
fn validate(bytes: []const u8, spec: Spec) !void {
    if (bytes.len > spec.max_bytes) return error.EnvelopeTooLarge;
    if ((try wire.Reader.init(bytes)).catalog_kind != spec.inner_kind) return error.InvalidEnvelope;
}
/// Append one read-only byte-array record atomically. Source/spec storage must
/// not alias any allocated writer storage, which growth could invalidate.
pub fn append(w: *wire.Writer, spec: Spec, inner: []const u8) !void {
    try spec.check();
    try validate(inner, spec);
    const current = try w.finish();
    const reader = try wire.Reader.init(current);
    if ((try find(current, reader.catalog_kind, spec)) != null) return error.AmbiguousEnvelope;
    const allocation = w.bytes.allocatedSlice();
    if (overlap(allocation, inner) or overlap(allocation, spec.name) or overlap(allocation, spec.vendor)) return error.BufferOverlap;
    var extra = try std.math.add(usize, wire.record_size + wire.value_size, inner.len);
    extra = try std.math.add(usize, extra, spec.name.len);
    extra = try std.math.add(usize, extra, spec.vendor.len);
    if (extra > w.limit - w.bytes.items.len) return error.CatalogFull;
    try w.bytes.ensureUnusedCapacity(w.allocator, extra);
    const before = w.bytes.items.len;
    const count = w.count;
    errdefer {
        w.bytes.items.len = before;
        w.open = null;
        w.count = count;
        std.mem.writeInt(u32, w.bytes.items[12..16], count, .little);
    }
    try w.begin(.{ .group = spec.group, .id = spec.id, .name = spec.name, .vendor = spec.vendor, .kind = .byte, .flags = snapshot_flags, .extent = @intCast(inner.len) });
    try w.append(.{ .kind = .byte, .flags = wire.array | wire.little_endian, .count = @intCast(inner.len), .data = inner });
    try w.end();
}
/// Borrowed exact payload or null for legacy absence. All outer tails are
/// validated, including foreign records. Duplicate reserved identities reject.
pub fn find(outer: []const u8, outer_kind: u32, spec: Spec) !?[]const u8 {
    try spec.check();
    const reader = try wire.Reader.init(outer);
    if (outer_kind == 0 or reader.catalog_kind != outer_kind) return error.InvalidEnvelope;
    var result: ?[]const u8 = null;
    var records = reader.records();
    while (try records.next()) |record| {
        const info = record.info;
        if (info.group != spec.group or info.id != spec.id or !std.mem.eql(u8, info.vendor, spec.vendor)) continue;
        if (result != null) return error.AmbiguousEnvelope;
        if (!std.mem.eql(u8, info.name, spec.name) or info.kind != .byte or info.flags != snapshot_flags or info.app_id != 0 or info.native_type != 0 or record.count != 1) return error.InvalidEnvelope;
        var values = record.values();
        const value = (try values.next()) orelse return error.InvalidEnvelope;
        if (value.kind != .byte or value.role != 0 or value.native_type != 0 or value.flags != wire.array | wire.little_endian or value.label.len != 0 or value.count != info.extent or value.data.len != info.extent) return error.InvalidEnvelope;
        try validate(value.data, spec);
        result = value.data;
    }
    return result;
}
/// Failure never writes a prefix. Source, output and identity strings must be
/// disjoint; caller retains immutable inputs. Extra output suffix is unchanged.
pub fn copy(outer: []const u8, outer_kind: u32, spec: Spec, output: []u8) !usize {
    const bytes = (try find(outer, outer_kind, spec)) orelse return error.MissingEnvelope;
    if (output.len < bytes.len) return error.BufferTooSmall;
    const dest = output[0..bytes.len];
    if (overlap(dest, outer) or overlap(dest, spec.name) or overlap(dest, spec.vendor)) return error.BufferOverlap;
    @memcpy(dest, bytes);
    return bytes.len;
}
const test_spec: Spec = .{ .group = 100, .id = 7, .name = "Snapshot", .vendor = "test", .inner_kind = 2, .max_bytes = 4096 };
const empty = "HCAT\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00";
fn fixture(a: std.mem.Allocator) !wire.Writer {
    var w = try wire.Writer.init(a, 2, 4096);
    errdefer w.deinit();
    try w.begin(.{ .group = 91, .id = 0xf0000001, .native_type = 231, .kind = .unknown, .flags = 97, .name = "Vendor.Property", .vendor = "arbitrary" });
    try w.append(.{ .kind = .unknown, .native_type = 231, .flags = 0x103, .count = 123456, .label = "raw", .data = &.{ 0, 255, 7, 19, 0, 128 } });
    try w.end();
    return w;
}
test "catalog envelopes retain exact nested identities opaque bytes and independent copies" {
    const t = std.testing;
    var inner = try fixture(t.allocator);
    defer inner.deinit();
    var outer = try wire.Writer.init(t.allocator, 4, 8192);
    defer outer.deinit();
    try append(&outer, test_spec, try inner.finish());
    const payload = (try find(try outer.finish(), 4, test_spec)).?;
    try t.expectEqualSlices(u8, try inner.finish(), payload);
    var out: [4096]u8 = @splat(73);
    const length = try copy(try outer.finish(), 4, test_spec, &out);
    try t.expectEqualSlices(u8, payload, out[0..length]);
    try t.expect(std.mem.allEqual(u8, out[length..], 73));
    @memset(outer.bytes.items, 0);
    const reader = try wire.Reader.init(out[0..length]);
    var records = reader.records();
    const record = (try records.next()).?;
    try t.expectEqualStrings("arbitrary", record.info.vendor);
    try t.expectEqual(@as(u32, 231), record.info.native_type);
}
test "catalog envelopes reject malformed tails duplicates wrong kinds flags roles shapes and limits" {
    const t = std.testing;
    var outer = try wire.Writer.init(t.allocator, 4, 8192);
    defer outer.deinit();
    try t.expect((try find(try outer.finish(), 4, test_spec)) == null);
    try append(&outer, test_spec, empty);
    try t.expectError(error.InvalidEnvelope, find(try outer.finish(), 3, test_spec));
    var limited = test_spec;
    limited.max_bytes = 15;
    try t.expectError(error.InvalidEnvelope, find(try outer.finish(), 4, limited));
    limited = test_spec;
    limited.inner_kind = 3;
    try t.expectError(error.InvalidEnvelope, find(try outer.finish(), 4, limited));
    const record_offset = wire.header_size;
    const value_offset = record_offset + wire.record_size + test_spec.name.len + test_spec.vendor.len;
    for ([_]usize{ record_offset + 12, record_offset + 16, record_offset + 20, record_offset + 24, record_offset + 28, value_offset + 4, value_offset + 8, value_offset + 12, value_offset + 16, value_offset + 20 }) |offset| {
        const original = std.mem.readInt(u32, outer.bytes.items[offset..][0..4], .little);
        std.mem.writeInt(u32, outer.bytes.items[offset..][0..4], original + 1, .little);
        if (find(try outer.finish(), 4, test_spec)) |_| return error.TestExpectedError else |err| try t.expect(err == error.InvalidEnvelope or err == error.InvalidCatalog);
        std.mem.writeInt(u32, outer.bytes.items[offset..][0..4], original, .little);
    }
    try t.expectError(error.AmbiguousEnvelope, append(&outer, test_spec, empty));
    try outer.begin(.{ .group = test_spec.group, .id = test_spec.id, .name = test_spec.name, .vendor = test_spec.vendor, .kind = .byte, .flags = snapshot_flags, .extent = empty.len });
    try outer.append(.{ .kind = .byte, .flags = 3, .count = empty.len, .data = empty });
    try outer.end();
    try t.expectError(error.AmbiguousEnvelope, find(try outer.finish(), 4, test_spec));
    outer.bytes.items.len -= 1;
    try t.expectError(error.InvalidCatalog, find(try outer.finish(), 4, test_spec));
}
test "envelope prefix output overlap alias and writer failure are rejected atomically" {
    const t = std.testing;
    var outer = try wire.Writer.init(t.allocator, 4, 4096);
    defer outer.deinit();
    try append(&outer, test_spec, empty);
    var out: [64]u8 = @splat(91);
    try t.expectError(error.BufferTooSmall, copy(try outer.finish(), 4, test_spec, out[0..15]));
    try t.expect(std.mem.allEqual(u8, &out, 91));
    try t.expectError(error.BufferOverlap, copy(try outer.finish(), 4, test_spec, outer.bytes.items));
    @memcpy(out[0..test_spec.name.len], test_spec.name);
    var alias = test_spec;
    alias.name = out[0..8];
    try t.expectError(error.BufferOverlap, copy(try outer.finish(), 4, alias, &out));
    const before = outer.bytes.items.len;
    alias = test_spec;
    alias.inner_kind = 4;
    try t.expectError(error.InvalidEnvelope, append(&outer, alias, outer.bytes.items));
    var other = try wire.Writer.init(t.allocator, 2, 4096);
    defer other.deinit();
    try t.expectError(error.BufferOverlap, append(&other, test_spec, other.bytes.items));
    try t.expectEqual(before, outer.bytes.items.len);
    outer.limit = before + 1;
    alias = test_spec;
    alias.id += 1;
    try t.expectError(error.CatalogFull, append(&outer, alias, empty));
    try t.expectEqual(before, outer.bytes.items.len);
    try t.expectEqual(@as(u32, 1), (try wire.Reader.init(try outer.finish())).count);
}
fn failures(a: std.mem.Allocator) !void {
    var w = try wire.Writer.init(a, 4, 4096);
    defer w.deinit();
    // Allocate fixture storage separately: the failing allocator must reach
    // append growth, rather than only failing writer/fixture construction.
    var inner = try fixture(std.testing.allocator);
    defer inner.deinit();
    const payload = try inner.finish();
    const extra = wire.record_size + wire.value_size + test_spec.name.len + test_spec.vendor.len + payload.len;
    try std.testing.expect(extra > w.bytes.capacity - w.bytes.items.len);
    const before = std.hash.Wyhash.hash(0, try w.finish());
    append(&w, test_spec, payload) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), w.count);
        try std.testing.expect(w.open == null);
        try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, try w.finish()));
        return err;
    };
}
test "foreign identities stay absent and malformed foreign tails never publish an early envelope" {
    const t = std.testing;
    var w = try wire.Writer.init(t.allocator, 4, 4096);
    defer w.deinit();
    var foreign = test_spec;
    foreign.vendor = "another";
    try append(&w, foreign, empty);
    try t.expect((try find(try w.finish(), 4, test_spec)) == null);
    var out: [1024]u8 = @splat(99);
    try t.expectError(error.MissingEnvelope, copy(try w.finish(), 4, test_spec, &out));
    try append(&w, test_spec, empty);
    try w.begin(.{ .group = 42, .id = 3, .name = "Tail", .kind = .byte });
    try w.append(.{ .kind = .byte, .data = &.{73} });
    try w.end();
    w.bytes.items.len -= 1;
    try t.expectError(error.InvalidCatalog, copy(try w.finish(), 4, test_spec, &out));
    try t.expect(std.mem.allEqual(u8, &out, 99));
}
test "nested payload limits and inner corruption reject before append or output mutation" {
    const t = std.testing;
    var inner = try fixture(t.allocator);
    defer inner.deinit();
    var outer = try wire.Writer.init(t.allocator, 4, 8192);
    defer outer.deinit();
    var limited = test_spec;
    limited.max_bytes = empty.len;
    try t.expectError(error.EnvelopeTooLarge, append(&outer, limited, try inner.finish()));
    try t.expectEqual(@as(usize, wire.header_size), outer.bytes.items.len);
    try append(&outer, test_spec, try inner.finish());
    var out: [4096]u8 = @splat(19);
    try t.expectError(error.EnvelopeTooLarge, copy(try outer.finish(), 4, limited, &out));
    const offset = wire.header_size + wire.record_size + test_spec.name.len + test_spec.vendor.len + wire.value_size;
    outer.bytes.items[offset + 4] = 2;
    try t.expectError(error.InvalidCatalog, copy(try outer.finish(), 4, test_spec, &out));
    try t.expect(std.mem.allEqual(u8, &out, 19));
}
test "catalog envelope allocation failures leave valid unchanged writer state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failures, .{});
}
