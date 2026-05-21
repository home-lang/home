// Copied verbatim from bun/src/sql/postgres/protocol/PasswordMessage.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres password-message ('p') packet writer.

const PasswordMessage = @This();

password: Data = .{ .empty = {} },

pub fn deinit(this: *PasswordMessage) void {
    this.password.deinit();
}

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const password = this.password.slice();
    const count: usize = @sizeOf((u32)) + password.len + 1;
    const header = [_]u8{
        'p',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(password);
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "PasswordMessage holds password slice" {
    const std_local = @import("std");
    var m: PasswordMessage = .{ .password = .{ .temporary = "hunter2" } };
    defer m.deinit();
    try std_local.testing.expectEqualStrings("hunter2", m.password.slice());
}

test "PasswordMessage writes postgres password packet bytes" {
    var list = std.array_list.Managed(u8).init(std.testing.allocator);
    defer list.deinit();

    const ctx = ArrayList{ .array = &list };
    const writer = NewWriter(ArrayList){ .wrapped = ctx };
    const message: PasswordMessage = .{ .password = .{ .temporary = "abc" } };

    try message.writeInternal(ArrayList, writer);

    try std.testing.expectEqualSlices(u8, &.{ 'p', 0, 0, 0, 8, 'a', 'b', 'c', 0 }, list.items);
}

const std = @import("std");
const ArrayList = @import("./ArrayList.zig");
const Data = @import("../../shared/Data.zig").Data;
const Int32 = @import("../types/int_types.zig").Int32;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;
