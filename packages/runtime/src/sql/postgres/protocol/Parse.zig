// Copied verbatim from bun/src/sql/postgres/protocol/Parse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres Parse ('P') extended-protocol packet writer. The upstream
// `@import("../PostgresTypes.zig")` import is rewritten to the in-tree
// split-out `types/int_types.zig`.

const Parse = @This();

name: []const u8 = "",
query: []const u8 = "",
params: []const int4 = &.{},

pub fn deinit(this: *Parse) void {
    _ = this;
}

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const parameters = this.params;
    if (parameters.len > std.math.maxInt(u16)) {
        return error.TooManyParameters;
    }
    const count: usize = @sizeOf((u32)) + @sizeOf(u16) + (parameters.len * @sizeOf(u32)) + @max(zCount(this.name), 1) + @max(zCount(this.query), 1);
    const header = [_]u8{
        'P',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(this.name);
    try writer.string(this.query);
    try writer.short(parameters.len);
    for (parameters) |parameter| {
        try writer.int4(parameter);
    }
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "Parse holds name + query + params" {
    const std_local = @import("std");
    const p: Parse = .{ .name = "stmt", .query = "SELECT 1" };
    try std_local.testing.expectEqualStrings("stmt", p.name);
    try std_local.testing.expectEqualStrings("SELECT 1", p.query);
    try std_local.testing.expectEqual(@as(usize, 0), p.params.len);
}

test "Parse writes extended query packet bytes" {
    var list = std.array_list.Managed(u8).init(std.testing.allocator);
    defer list.deinit();

    const ctx = ArrayList{ .array = &list };
    const writer = NewWriter(ArrayList){ .wrapped = ctx };
    const message: Parse = .{
        .name = "",
        .query = "select 1",
        .params = &.{23},
    };

    try message.writeInternal(ArrayList, writer);

    try std.testing.expectEqualSlices(u8, &.{
        'P',
        0,
        0,
        0,
        20,
        0,
        's',
        'e',
        'l',
        'e',
        'c',
        't',
        ' ',
        '1',
        0,
        0,
        1,
        0,
        0,
        0,
        23,
    }, list.items);
}

const std = @import("std");
const ArrayList = @import("./ArrayList.zig");
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;

const int_types = @import("../types/int_types.zig");
const Int32 = int_types.Int32;
const int4 = int_types.int4;

const zHelpers = @import("./zHelpers.zig");
const zCount = zHelpers.zCount;
