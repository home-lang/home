// Copied from bun/src/sql/mysql/protocol/ResultSetHeader.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// MySQL ResultSet leading "column count" packet — the server sends a
// single length-encoded integer that names how many ColumnDefinition41
// packets will follow before the EOF/row packets. No `@import("bun")`
// references upstream. The decoder consumes the concrete NewReader
// `encodedLenInt()` method now exercised by the decode test below.

const ResultSetHeader = @This();
field_count: u64 = 0,

pub fn decodeInternal(this: *ResultSetHeader, comptime Context: type, reader: NewReader(Context)) !void {
    // Field count (length encoded integer)
    this.field_count = try reader.encodedLenInt();
}

pub const decode = decoderWrap(ResultSetHeader, decodeInternal).decode;

test "ResultSetHeader defaults to zero field_count" {
    const std = @import("std");
    const h: ResultSetHeader = .{};
    try std.testing.expectEqual(@as(u64, 0), h.field_count);
}

test "ResultSetHeader holds an explicit field_count" {
    const std = @import("std");
    const h: ResultSetHeader = .{ .field_count = 17 };
    try std.testing.expectEqual(@as(u64, 17), h.field_count);
}

test "ResultSetHeader decodes length-encoded field count" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0xfc, 0x34, 0x12 }, &offset, &message_start);

    var h: ResultSetHeader = .{};
    try h.decode(reader);

    try std.testing.expectEqual(@as(u64, 0x1234), h.field_count);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
const StackReader = @import("./StackReader.zig");
