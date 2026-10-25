//! Bounded Raspberry Pi CNN metadata layouts. The actual producer uses 16x16;
//! older documented 8x8 packets are accepted only at their exact ABI length.
//! Shapes describe column-major float32 values, not image HWC/CHW guesses.
const std = @import("std");
const geometry = @import("tensor_layout.zig");
const wire = @import("typed_catalog.zig");
pub const max_tensors = 16;
pub const Tensor = struct { offset: usize, layout: geometry.Layout };
pub const Info = struct {
    network_name: [64]u8 = @splat(0),
    name_length: u8,
    count: u8,
    profile: u8,
    frame_count: u8,
    values: usize,
    tensors: [max_tensors]?Tensor = @splat(null),

    pub fn name(self: *const Info) []const u8 {
        return self.network_name[0..self.name_length];
    }
    /// No foreign struct casts: the byte schema is little endian and may be
    /// unaligned. Tensor products and the complete float span must agree.
    pub fn parse(bytes: []const u8, value_count: usize, max_values: usize) !Info {
        const dimensions: usize = switch (bytes.len) {
            264 => 8,
            712 => 16,
            else => return error.UnsupportedTensorInfo,
        };
        if (value_count > max_values) return error.TensorTooLarge;
        const name_length = std.mem.indexOfScalar(u8, bytes[0..64], 0) orelse 64;
        if (!std.unicode.utf8ValidateSlice(bytes[0..name_length])) return error.InvalidNetworkName;
        const count = get(u32, bytes, 64);
        if (count > dimensions) return error.InvalidTensorCount;
        var result: Info = .{ .name_length = @intCast(name_length), .count = @intCast(count), .profile = @intCast(dimensions), .frame_count = bytes[68 + dimensions * (8 + dimensions * 2)], .values = value_count };
        @memcpy(result.network_name[0..name_length], bytes[0..name_length]);
        var offset: usize = 0;
        for (0..count) |i| {
            const at = 68 + i * (8 + dimensions * 2);
            const elements = get(u32, bytes, at);
            const rank = get(u32, bytes, at + 4);
            if (rank > dimensions) return error.InvalidRank;
            var shape: [16]u32 = @splat(0);
            for (0..rank) |axis| shape[axis] = get(u16, bytes, at + 8 + axis * 2);
            const plan = try geometry.Layout.init(shape[0..rank], .column_major, max_values);
            if (plan.elements != elements) return error.InvalidTensorSize;
            if (offset > value_count or plan.elements > value_count - offset) return error.InvalidTensorSize;
            result.tensors[i] = .{ .offset = offset, .layout = plan };
            offset += plan.elements;
        }
        if (offset != value_count) return error.InvalidTensorSize;
        return result;
    }
};
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
pub const Outputs = struct {
    info: Info,
    /// Borrowed IEEE float32 bits; nonfinite payloads are preserved exactly.
    data: []const u8,
    endian: std.builtin.Endian,
    pub fn fromRaw(info: []const u8, data: []const u8, endian: std.builtin.Endian, max_values: usize) !Outputs {
        if (data.len % 4 != 0) return error.InvalidTensorSize;
        return .{ .info = try Info.parse(info, data.len / 4, max_values), .data = data, .endian = endian };
    }
    pub fn fromCatalog(bytes: []const u8, max_values: usize) !?Outputs {
        const reader = try wire.Reader.init(bytes);
        if (reader.catalog_kind != 4) return error.InvalidCatalogKind;
        const vendors = &.{ "rpi", "libcamera", "" };
        const info = try reader.findValue(.byte, .{ .name = "CnnOutputTensorInfo", .vendors = vendors, .forbidden_flags = 1 });
        const data = try reader.findValue(.f32, .{ .name = "CnnOutputTensor", .vendors = vendors, .forbidden_flags = 1 });
        if (info == null and data == null) return null;
        if (info == null or data == null) return error.IncompleteTensorMetadata;
        for ([_]wire.Value{ info.?, data.? }) |value| if (value.flags & wire.array == 0 or value.flags & ~@as(u32, wire.array | wire.little_endian) != 0) return error.InvalidTensorValue;
        return try fromRaw(info.?.data, data.?.data, if (data.?.flags & wire.little_endian != 0) .little else .big, max_values);
    }
    /// Preflight before writing; overlapping payloads are rejected. The output
    /// order is explicit and never changes network shapes or float payload bits.
    pub fn copy(self: *const Outputs, destination: []f32, order: geometry.Order) !void {
        if (destination.len < self.info.values) return error.OutputTooSmall;
        const target = destination[0..self.info.values];
        if (overlaps(std.mem.sliceAsBytes(target), self.data)) return error.AliasedOutput;
        if (order == .column_major and self.endian == @import("builtin").cpu.arch.endian()) {
            @memcpy(std.mem.sliceAsBytes(target), self.data);
            return;
        }
        for (self.info.tensors[0..self.info.count]) |optional| {
            const tensor = optional.?;
            for (0..tensor.layout.elements) |i| {
                const source = tensor.offset + (if (order == .row_major) try tensor.layout.rowMajorSource(i) else i);
                const bits = std.mem.readInt(u32, self.data[source * 4 ..][0..4], self.endian);
                target[tensor.offset + i] = @bitCast(bits);
            }
        }
    }
};

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x >= y) x - y < b.len else y - x < a.len;
}
fn fixture(capacity: usize, bytes: []u8, shape: []const u16) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..3], "cnn");
    std.mem.writeInt(u32, bytes[64..68], 1, .little);
    var product: u32 = 1;
    for (shape) |extent| product *= extent;
    std.mem.writeInt(u32, bytes[68..72], product, .little);
    std.mem.writeInt(u32, bytes[72..76], @intCast(shape.len), .little);
    for (shape, 0..) |extent, i| std.mem.writeInt(u16, bytes[76 + i * 2 ..][0..2], extent, .little);
    bytes[68 + capacity * (8 + capacity * 2)] = 255;
}
test "both exported tensor profiles decode unaligned metadata and validate exact shape products" {
    var wide: [713]u8 = undefined;
    fixture(16, wide[1..], &.{ 2, 3 });
    const info = try Info.parse(wide[1..], 6, 6);
    try std.testing.expectEqualStrings("cnn", info.name());
    try std.testing.expectEqual(@as(u8, 255), info.frame_count);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, info.tensors[0].?.layout.strides[0..2]);
    var old: [264]u8 = undefined;
    fixture(8, &old, &.{ 2, 3 });
    try std.testing.expectEqual(@as(u8, 8), (try Info.parse(&old, 6, 6)).profile);
    try std.testing.expectError(error.InvalidTensorSize, Info.parse(&old, 5, 6));
    try std.testing.expectError(error.InvalidTensorSize, Info.parse(&old, 7, 7));
    try std.testing.expectError(error.TensorTooLarge, Info.parse(&old, 6, 5));
    try std.testing.expectError(error.UnsupportedTensorInfo, Info.parse(old[0..263], 6, 6));
    std.mem.writeInt(u32, old[64..68], 9, .little);
    try std.testing.expectError(error.InvalidTensorCount, Info.parse(&old, 6, 6));
}
test "column order and row conversion preserve native float bits and reject short or aliased output" {
    var info: [712]u8 = undefined;
    fixture(16, &info, &.{ 2, 3 });
    const bits = [_]u32{ 0x7fc01234, 0x80000000, 0x3f800000, 0x40000000, 0x40400000, 0xff800000 };
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var data: [24]u8 = undefined;
        for (bits, 0..) |word, i| std.mem.writeInt(u32, data[i * 4 ..][0..4], word, endian);
        const model = try Outputs.fromRaw(&info, &data, endian, 6);
        var output: [7]f32 = @splat(9);
        try model.copy(&output, .column_major);
        for (bits, output[0..6]) |expected, value| try std.testing.expectEqual(expected, @as(u32, @bitCast(value)));
        try std.testing.expectEqual(@as(f32, 9), output[6]);
        try model.copy(&output, .row_major);
        for ([_]usize{ 0, 2, 4, 1, 3, 5 }, output[0..6]) |source, value| try std.testing.expectEqual(bits[source], @as(u32, @bitCast(value)));
        const before = output;
        try std.testing.expectError(error.OutputTooSmall, model.copy(output[0..5], .row_major));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&output));
    }
    var floats: [6]f32 = @splat(1);
    const aliased = try Outputs.fromRaw(&info, std.mem.sliceAsBytes(&floats), .little, 6);
    try std.testing.expectError(error.AliasedOutput, aliased.copy(&floats, .row_major));
}
test "empty extents scalars maximum rank invalid names and truncated data remain explicit" {
    var info: [712]u8 = undefined;
    fixture(16, &info, &.{});
    try std.testing.expectEqual(@as(usize, 1), (try Info.parse(&info, 1, 1)).values);
    fixture(16, &info, &.{ 0, 7 });
    try std.testing.expectEqual(@as(usize, 0), (try Info.parse(&info, 0, 0)).values);
    const shape: [16]u16 = @splat(1);
    fixture(16, &info, &shape);
    try std.testing.expectEqual(@as(u8, 16), (try Info.parse(&info, 1, 1)).tensors[0].?.layout.rank);
    std.mem.writeInt(u32, info[72..76], 17, .little);
    try std.testing.expectError(error.InvalidRank, Info.parse(&info, 1, 1));
    fixture(16, &info, &.{1});
    info[0] = 255;
    try std.testing.expectError(error.InvalidNetworkName, Info.parse(&info, 1, 1));
    fixture(16, &info, &.{1});
    try std.testing.expectError(error.InvalidTensorSize, Outputs.fromRaw(&info, &.{0}, .little, 1));
}

test "typed catalog outputs select exact metadata arrays and reject partial or ambiguous snapshots" {
    const t = std.testing;
    var info: [712]u8 = undefined;
    fixture(16, &info, &.{ 2, 3 });
    var w = try wire.Writer.init(t.allocator, 4, 8192);
    defer w.deinit();
    try t.expectEqual(@as(?Outputs, null), try Outputs.fromCatalog(try w.finish(), 6));
    try w.begin(.{ .name = "CnnOutputTensorInfo", .vendor = "rpi", .flags = 2, .kind = .byte });
    try w.append(.{ .kind = .byte, .flags = wire.array, .count = 712, .data = &info });
    try w.end();
    try t.expectError(error.IncompleteTensorMetadata, Outputs.fromCatalog(try w.finish(), 6));
    const values: [6]f32 = .{ 0, 1, 2, 3, 4, 5 };
    try w.begin(.{ .name = "CnnOutputTensor", .vendor = "rpi", .flags = 2, .kind = .f32 });
    try w.append(.{ .kind = .f32, .flags = wire.array | (if (@import("builtin").cpu.arch.endian() == .little) @as(u32, wire.little_endian) else 0), .count = 6, .data = std.mem.sliceAsBytes(&values) });
    try w.end();
    const model = (try Outputs.fromCatalog(try w.finish(), 6)).?;
    var result: [6]f32 = undefined;
    try model.copy(&result, .row_major);
    try t.expectEqualSlices(f32, &.{ 0, 2, 4, 1, 3, 5 }, &result);
    try w.begin(.{ .name = "CnnOutputTensor", .vendor = "rpi", .flags = 2, .kind = .f32 });
    try w.append(.{ .kind = .f32, .flags = wire.array | wire.little_endian, .count = 6, .data = std.mem.sliceAsBytes(&values) });
    try w.end();
    try t.expectError(error.AmbiguousValue, Outputs.fromCatalog(try w.finish(), 6));
}

/// Copy an already-decoded dense tensor into row-major owned output. Shape and
/// byte counts are validated before writing, and arbitrary source aliasing is
/// refused. Leading singleton batch axes need not change physical storage.
pub fn copyTensorRowMajor(shape: []const u32, source: []const f32, order: geometry.Order, destination: []f32) !void {
    const layout = try geometry.Layout.init(shape, order, source.len);
    if (layout.elements != source.len) return error.InvalidTensorSize;
    if (destination.len < source.len) return error.OutputTooSmall;
    const target = destination[0..source.len];
    if (overlaps(std.mem.sliceAsBytes(source), std.mem.sliceAsBytes(target))) return error.AliasedOutput;
    if (order == .row_major) {
        @memcpy(target, source);
        return;
    }
    for (target, 0..) |*value, i| value.* = source[try layout.rowMajorSource(i)];
}
test "decoded tensor row copies preserve independent ownership and reject malformed extents before writes" {
    const input = [_]f32{ 0, 1, 2, 3, 4, 5 };
    var output: [7]f32 = @splat(11);
    try copyTensorRowMajor(&.{ 2, 3 }, &input, .column_major, &output);
    try std.testing.expectEqualSlices(f32, &.{ 0, 2, 4, 1, 3, 5 }, output[0..6]);
    try std.testing.expectEqual(@as(f32, 11), output[6]);
    const before = output;
    try std.testing.expectError(error.InvalidTensorSize, copyTensorRowMajor(&.{ 2, 2 }, &input, .column_major, &output));
    try std.testing.expectEqualSlices(f32, &before, &output);
    try std.testing.expectError(error.OutputTooSmall, copyTensorRowMajor(&.{ 2, 3 }, &input, .row_major, output[0..5]));
    try std.testing.expectError(error.AliasedOutput, copyTensorRowMajor(&.{ 2, 3 }, output[0..6], .column_major, output[0..6]));
}
