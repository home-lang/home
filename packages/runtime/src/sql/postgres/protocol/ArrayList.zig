// Copied from bun/src/sql/postgres/protocol/ArrayList.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Thin `std.array_list.Managed(u8)` wrapper adapting an in-memory byte
// buffer to the postgres-wire `NewWriter` interface (offset / write /
// pwrite). Used as a `Context` parameter for `NewWriter(ArrayList)`
// during protocol-message construction.

array: *std.array_list.Managed(u8),

pub fn offset(this: @This()) usize {
    return this.array.items.len;
}

pub fn write(this: @This(), bytes: []const u8) AnyPostgresError!void {
    try this.array.appendSlice(bytes);
}

pub fn pwrite(this: @This(), bytes: []const u8, i: usize) AnyPostgresError!void {
    @memcpy(this.array.items[i..][0..bytes.len], bytes);
}

pub const Writer = NewWriter(@This());

const std = @import("std");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
const NewWriter = @import("./NewWriter.zig").NewWriter;

test "ArrayList.write appends bytes and offset tracks length" {
    var managed = std.array_list.Managed(u8).init(std.testing.allocator);
    defer managed.deinit();

    const ctx = @This(){ .array = &managed };
    try std.testing.expectEqual(@as(usize, 0), ctx.offset());

    try ctx.write("hello");
    try std.testing.expectEqual(@as(usize, 5), ctx.offset());
    try std.testing.expectEqualSlices(u8, "hello", managed.items);

    try ctx.write(" world");
    try std.testing.expectEqual(@as(usize, 11), ctx.offset());

    // pwrite overwrites in place without changing length.
    try ctx.pwrite("HELLO", 0);
    try std.testing.expectEqualSlices(u8, "HELLO world", managed.items);
    try std.testing.expectEqual(@as(usize, 11), ctx.offset());
}
