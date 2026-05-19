// Copied verbatim from bun/src/sql/mysql/protocol/EOFPacket.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL EOF (server response) packet. `decodeInternal` calls the
// wave-18 NewReader stub method surface (reader.int) which trips a
// natural compile error if invoked today; the leaf compiles as a
// declaration so other packet code that names `EOFPacket` works.

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

const StatusFlags = @import("../StatusFlags.zig").StatusFlags;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
