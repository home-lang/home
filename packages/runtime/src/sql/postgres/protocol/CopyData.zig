// Copied verbatim from bun/src/sql/postgres/protocol/CopyData.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres CopyData ('d') packet — message-framed bytes both sides
// exchange during a COPY. Wire reader/writer bodies reference the
// wave-16 NewReader/NewWriter stub method surface (reader.length,
// reader.read, writer.write, writer.string); calls trip
// `@compileError` until real readers/writers return, so this leaf is
// declaration-only today.

const CopyData = @This();

data: Data = .{ .empty = {} },

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    const length = try reader.length();

    // The length field counts itself (4 bytes) but not the 'd' type byte the
    // dispatcher already consumed, so the body is exactly `length - 4`. The
    // previous `- 5` left one body byte unread, desyncing every message after a
    // CopyData ('d') packet. Saturating so a malformed short length can't
    // underflow-panic the connection thread.
    const data = try reader.read(@intCast(length -| 4));
    this.* = .{
        .data = data,
    };
}

pub const decode = DecoderWrap(CopyData, decodeInternal).decode;

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const data = this.data.slice();
    const count: u32 = @sizeOf((u32)) + data.len + 1;
    const header = [_]u8{
        'd',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(data);
}

pub const write = WriteWrap(@This(), writeInternal).write;

test "CopyData defaults to empty data" {
    const std_local = @import("std");
    const c: CopyData = .{};
    try std_local.testing.expectEqualStrings("", c.data.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const Int32 = @import("../types/int_types.zig").Int32;
const NewReader = @import("./NewReader.zig").NewReader;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;
