// Copied verbatim from bun/src/sql/postgres/protocol/SASLResponse.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres SASL continuation response ('p') packet writer. Wire body
// reaches into the wave-16 NewWriter stub method surface — those calls
// trip a natural compile error if exercised today.

const SASLResponse = @This();

data: Data = .{ .empty = {} },

pub fn deinit(this: *SASLResponse) void {
    this.data.deinit();
}

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const data = this.data.slice();
    const count: usize = @sizeOf(u32) + data.len;
    const header = [_]u8{
        'p',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.write(data);
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "SASLResponse holds payload slice" {
    const std_local = @import("std");
    var r: SASLResponse = .{ .data = .{ .temporary = "client-final-message" } };
    defer r.deinit();
    try std_local.testing.expectEqualStrings("client-final-message", r.data.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const Int32 = @import("../types/int_types.zig").Int32;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;
