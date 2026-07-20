// Copied verbatim from bun/src/sql/mysql/protocol/StmtPrepareOKPacket.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL COM_STMT_PREPARE response packet. Decoder body consumes the
// concrete NewReader method surface now exercised by the decode test below.

const StmtPrepareOKPacket = @This();
status: u8 = 0,
statement_id: u32 = 0,
num_columns: u16 = 0,
num_params: u16 = 0,
warning_count: u16 = 0,
packet_length: u24,

pub fn decodeInternal(this: *StmtPrepareOKPacket, comptime Context: type, reader: NewReader(Context)) !void {
    this.status = try reader.int(u8);
    if (this.status != 0) {
        return error.InvalidPrepareOKPacket;
    }

    this.statement_id = try reader.int(u32);
    // The server never issues statement_id 0, and the client keys its own
    // "prepared" state on statement_id > 0, so a 0 here is a protocol violation.
    if (this.statement_id == 0) {
        return error.InvalidPrepareOKPacket;
    }
    this.num_columns = try reader.int(u16);
    this.num_params = try reader.int(u16);
    _ = try reader.int(u8); // reserved_1
    if (this.packet_length >= 12) {
        this.warning_count = try reader.int(u16);
    }
}

pub const decode = decoderWrap(StmtPrepareOKPacket, decodeInternal).decode;

test "StmtPrepareOKPacket defaults zero" {
    const std = @import("std");
    const p: StmtPrepareOKPacket = .{ .packet_length = 0 };
    try std.testing.expectEqual(@as(u8, 0), p.status);
    try std.testing.expectEqual(@as(u32, 0), p.statement_id);
}

test "StmtPrepareOKPacket decodes prepare OK body" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{
        0x00,
        0x12,
        0x34,
        0x56,
        0x78,
        0x02,
        0x00,
        0x01,
        0x00,
        0x00,
        0x09,
        0x00,
    }, &offset, &message_start);

    var p: StmtPrepareOKPacket = .{ .packet_length = 12 };
    try p.decode(reader);

    try std.testing.expectEqual(@as(u8, 0), p.status);
    try std.testing.expectEqual(@as(u32, 0x78563412), p.statement_id);
    try std.testing.expectEqual(@as(u16, 2), p.num_columns);
    try std.testing.expectEqual(@as(u16, 1), p.num_params);
    try std.testing.expectEqual(@as(u16, 9), p.warning_count);
    try std.testing.expectEqual(@as(usize, 12), offset);
}

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
const StackReader = @import("./StackReader.zig");
