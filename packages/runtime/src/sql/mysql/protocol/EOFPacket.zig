// Copied verbatim from bun/src/sql/mysql/protocol/EOFPacket.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL EOF (server response) packet. `decodeInternal` consumes the
// concrete NewReader method surface now exercised by the decode test below.

const EOFPacket = @This();
header: u8 = 0xfe,
warnings: u16 = 0,
status_flags: StatusFlags = .{},

pub fn decodeInternal(this: *EOFPacket, comptime Context: type, reader: NewReader(Context)) !void {
    this.header = try reader.int(u8);
    if (this.header != 0xfe) {
        return error.InvalidEOFPacket;
    }

    this.warnings = try reader.int(u16);
    this.status_flags = StatusFlags.fromInt(try reader.int(u16));
}

pub const decode = decoderWrap(EOFPacket, decodeInternal).decode;

test "EOFPacket default header is 0xfe" {
    const std = @import("std");
    const p: EOFPacket = .{};
    try std.testing.expectEqual(@as(u8, 0xfe), p.header);
    try std.testing.expectEqual(@as(u16, 0), p.warnings);
}

test "EOFPacket decodes wire header warnings and status flags" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0xfe, 0x02, 0x00, 0x03, 0x00 }, &offset, &message_start);

    var p: EOFPacket = .{};
    try p.decode(reader);

    try std.testing.expectEqual(@as(u8, 0xfe), p.header);
    try std.testing.expectEqual(@as(u16, 2), p.warnings);
    try std.testing.expectEqual(@as(u16, 3), p.status_flags.toInt());
    try std.testing.expectEqual(@as(usize, 5), offset);
}

const StatusFlags = @import("../StatusFlags.zig").StatusFlags;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
const StackReader = @import("./StackReader.zig");
