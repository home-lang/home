//! Checked, allocation-free dense tensor geometry. Strides count elements.
const std = @import("std");
pub const max_rank = 16;
pub const Order = enum { row_major, column_major };
pub const Layout = struct {
    rank: u8,
    shape: [max_rank]u32 = @splat(0),
    strides: [max_rank]usize = @splat(0),
    elements: usize,
    order: Order,

    /// Rank zero denotes a scalar. Empty extents yield zero elements and
    /// canonical all-zero strides; no indexing of an empty tensor is valid.
    pub fn init(shape: []const u32, order: Order, max_elements: usize) !Layout {
        if (shape.len > max_rank) return error.InvalidRank;
        var result: Layout = .{ .rank = @intCast(shape.len), .order = order, .elements = 1 };
        @memcpy(result.shape[0..shape.len], shape);
        for (shape) |extent| if (extent == 0) {
            result.elements = 0;
            return result;
        };
        for (shape) |extent| {
            if (result.elements > max_elements / extent) return error.TensorTooLarge;
            result.elements *= extent;
        }
        if (result.elements > max_elements) return error.TensorTooLarge;
        var stride: usize = 1;
        for (0..shape.len) |at| {
            const axis = if (order == .column_major) at else shape.len - 1 - at;
            result.strides[axis] = stride;
            stride *= shape[axis];
        }
        return result;
    }
    pub fn offset(self: Layout, coordinates: []const u32) !usize {
        if (self.rank > max_rank or coordinates.len != self.rank or self.elements == 0) return error.InvalidIndex;
        var result: usize = 0;
        for (coordinates, 0..) |value, axis| {
            if (value >= self.shape[axis]) return error.InvalidIndex;
            const term = std.math.mul(usize, value, self.strides[axis]) catch return error.InvalidIndex;
            result = std.math.add(usize, result, term) catch return error.InvalidIndex;
        }
        if (result >= self.elements) return error.InvalidIndex;
        return result;
    }
    /// Source element corresponding to one row-major flat output element.
    /// No scratch allocation or floating arithmetic is needed for a transpose.
    pub fn rowMajorSource(self: Layout, linear: usize) !usize {
        if (self.rank > max_rank or linear >= self.elements) return error.InvalidIndex;
        var coordinates: [max_rank]u32 = @splat(0);
        var remaining = linear;
        var axis: usize = self.rank;
        while (axis != 0) {
            axis -= 1;
            const extent = self.shape[axis];
            if (extent == 0) return error.InvalidIndex;
            coordinates[axis] = @intCast(remaining % extent);
            remaining /= extent;
        }
        return self.offset(coordinates[0..self.rank]);
    }
};

test "scalar, row-major and column-major layouts preserve exact element meaning" {
    const t = std.testing;
    const scalar = try Layout.init(&.{}, .column_major, 1);
    try t.expectEqual(@as(usize, 1), scalar.elements);
    try t.expectEqual(@as(usize, 0), try scalar.offset(&.{}));
    try t.expectError(error.TensorTooLarge, Layout.init(&.{}, .row_major, 0));
    const row = try Layout.init(&.{ 2, 3, 4 }, .row_major, 24);
    const column = try Layout.init(&.{ 2, 3, 4 }, .column_major, 24);
    try t.expectEqualSlices(usize, &.{ 12, 4, 1 }, row.strides[0..3]);
    try t.expectEqualSlices(usize, &.{ 1, 2, 6 }, column.strides[0..3]);
    try t.expectEqual(@as(usize, 17), try row.offset(&.{ 1, 1, 1 }));
    try t.expectEqual(@as(usize, 9), try column.offset(&.{ 1, 1, 1 }));
    try t.expectEqual(@as(usize, 9), try column.rowMajorSource(17));
}
test "empty tensors are bounded even when other extents would overflow" {
    const max = std.math.maxInt(u32);
    const layout = try Layout.init(&.{ max, max, max, 0 }, .column_major, 0);
    try std.testing.expectEqual(@as(usize, 0), layout.elements);
    for (layout.strides) |stride| try std.testing.expectEqual(@as(usize, 0), stride);
    try std.testing.expectError(error.InvalidIndex, layout.offset(&.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidIndex, layout.rowMajorSource(0));
    try std.testing.expectError(error.TensorTooLarge, Layout.init(&.{ max, max, max }, .row_major, std.math.maxInt(usize)));
    try std.testing.expectError(error.TensorTooLarge, Layout.init(&.{ 2, 3 }, .column_major, 5));
    const dimensions: [17]u32 = @splat(1);
    try std.testing.expectError(error.InvalidRank, Layout.init(&dimensions, .row_major, 100));
    const sixteen = try Layout.init(dimensions[0..16], .column_major, 1);
    try std.testing.expectEqual(@as(u8, 16), sixteen.rank);
    try std.testing.expectEqual(@as(usize, 0), try sixteen.offset(&@as([16]u32, @splat(0))));
}
test "index failures do not rely on unchecked or wrapped pointer arithmetic" {
    const layout = try Layout.init(&.{ 2, 3 }, .row_major, 6);
    try std.testing.expectError(error.InvalidIndex, layout.offset(&.{ 1, 3 }));
    try std.testing.expectError(error.InvalidIndex, layout.offset(&.{1}));
    try std.testing.expectError(error.InvalidIndex, layout.rowMajorSource(6));
    var malformed = layout;
    malformed.strides[0] = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidIndex, malformed.offset(&.{ 1, 2 }));
}
test "every small tensor layout is a bijection matching independent enumeration" {
    for (1..5) |a| for (1..5) |b| for (1..5) |c| {
        const shape = [_]u32{ @intCast(a), @intCast(b), @intCast(c) };
        const row = try Layout.init(&shape, .row_major, 64);
        const column = try Layout.init(&shape, .column_major, 64);
        var seen: [64]bool = @splat(false);
        var row_index: usize = 0;
        for (0..a) |x| for (0..b) |y| for (0..c) |z| {
            const at = [_]u32{ @intCast(x), @intCast(y), @intCast(z) };
            try std.testing.expectEqual(row_index, try row.offset(&at));
            // Independent column-first enumeration, no stride products.
            var source_index: usize = 0;
            outer: for (0..c) |zz| for (0..b) |yy| for (0..a) |xx| {
                if (xx == x and yy == y and zz == z) break :outer;
                source_index += 1;
            };
            try std.testing.expectEqual(source_index, try column.offset(&at));
            try std.testing.expectEqual(source_index, try column.rowMajorSource(row_index));
            try std.testing.expect(!seen[source_index]);
            seen[source_index] = true;
            row_index += 1;
        };
        for (seen[0..row.elements]) |present| try std.testing.expect(present);
    };
}
