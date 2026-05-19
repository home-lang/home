// Copied verbatim from bun/src/sql/postgres/protocol/CopyFail.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres CopyFail ('f') packet — client signals a COPY-from-STDIN
// failure to the server with a free-form error string. Wire
// reader/writer bodies reference the wave-16 NewReader/NewWriter
// stub method surface (reader.int4, reader.readZ, writer.write,
// writer.string); calls trip `@compileError` until real
// readers/writers return, so this leaf is declaration-only today.

const CopyFail = @This();

message: Data = .{ .empty = {} },

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    _ = try reader.int4();

    const message = try reader.readZ();
    this.* = .{
        .message = message,
    };
}

pub const decode = DecoderWrap(CopyFail, decodeInternal).decode;

pub fn writeInternal(
    this: *@This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const message = this.message.slice();
    const count: u32 = @sizeOf((u32)) + message.len + 1;
    const header = [_]u8{
        'f',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(message);
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "CopyFail defaults to empty message" {
    const std_local = @import("std");
    const c: CopyFail = .{};
    try std_local.testing.expectEqualStrings("", c.message.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;

const int_types = @import("../types/int_types.zig");
const Int32 = int_types.Int32;
