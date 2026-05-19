// Copied verbatim from bun/src/sql/postgres/protocol/SASLInitialResponse.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres SASL initial response ('p') packet writer. Wire body
// reaches into the wave-16 NewWriter stub method surface — those calls
// trip a natural compile error if exercised today.

const SASLInitialResponse = @This();

mechanism: Data = .{ .empty = {} },
data: Data = .{ .empty = {} },

pub fn deinit(this: *SASLInitialResponse) void {
    this.mechanism.deinit();
    this.data.deinit();
}

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const mechanism = this.mechanism.slice();
    const data = this.data.slice();
    const count: usize = @sizeOf(u32) + mechanism.len + 1 + data.len + @sizeOf(u32);
    const header = [_]u8{
        'p',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(mechanism);
    try writer.int4(@truncate(data.len));
    try writer.write(data);
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "SASLInitialResponse holds mechanism and data" {
    const std_local = @import("std");
    var r: SASLInitialResponse = .{
        .mechanism = .{ .temporary = "SCRAM-SHA-256" },
        .data = .{ .temporary = "n,,n=alice,r=client-nonce" },
    };
    defer r.deinit();
    try std_local.testing.expectEqualStrings("SCRAM-SHA-256", r.mechanism.slice());
    try std_local.testing.expectEqualStrings("n,,n=alice,r=client-nonce", r.data.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const Int32 = @import("../types/int_types.zig").Int32;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;
