// Copied verbatim from bun/src/sql/mysql/protocol/StmtPrepareOKPacket.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL COM_STMT_PREPARE response packet. Decoder body calls the
// wave-18 NewReader stub's method surface — those calls trip a natural
// compile error if exercised today; the declaration shape lands so
// downstream packet code that names `StmtPrepareOKPacket` works.

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

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
