// Copied verbatim from bun/src/sql/mysql/protocol/OKPacket.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// MySQL OK / EOF (deprecated) packet. Decoder body consumes the concrete
// NewReader method surface (`reader.int`, `reader.peek`, `reader.read`,
// `reader.encodedLenIntWithSize`) now exercised by the decode test below.

// OK Packet
const OKPacket = @This();
header: u8 = 0x00,
affected_rows: u64 = 0,
last_insert_id: u64 = 0,
status_flags: StatusFlags = .{},
warnings: u16 = 0,
info: Data = .{ .empty = {} },
session_state_changes: Data = .{ .empty = {} },
packet_size: u24,

pub fn deinit(this: *OKPacket) void {
    this.info.deinit();
    this.session_state_changes.deinit();
}

pub fn decodeInternal(this: *OKPacket, comptime Context: type, reader: NewReader(Context)) !void {
    var read_size: usize = 5; // header + status flags + warnings
    this.header = try reader.int(u8);
    if (this.header != 0x00 and this.header != 0xfe) {
        return error.InvalidOKPacket;
    }

    // Affected rows (length encoded integer)
    this.affected_rows = try reader.encodedLenIntWithSize(&read_size);

    // Last insert ID (length encoded integer)
    this.last_insert_id = try reader.encodedLenIntWithSize(&read_size);

    // Status flags
    this.status_flags = StatusFlags.fromInt(try reader.int(u16));
    // Warnings
    this.warnings = try reader.int(u16);

    // Info (EOF-terminated string)
    if (reader.peek().len > 0 and this.packet_size > read_size) {
        const remaining = this.packet_size - read_size;
        this.info = try reader.read(@truncate(remaining));
    }
}

pub const decode = decoderWrap(OKPacket, decodeInternal).decode;

test "OKPacket defaults zero" {
    const std = @import("std");
    var p: OKPacket = .{ .packet_size = 0 };
    defer p.deinit();
    try std.testing.expectEqual(@as(u8, 0), p.header);
    try std.testing.expectEqual(@as(u64, 0), p.affected_rows);
    try std.testing.expectEqual(@as(u64, 0), p.last_insert_id);
}

test "OKPacket decodes length-encoded counters flags warnings and info" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0x00, 0x01, 0x02, 0x02, 0x00, 0x04, 0x00, 'o', 'k' }, &offset, &message_start);

    var p: OKPacket = .{ .packet_size = 9 };
    defer p.deinit();
    try p.decode(reader);

    try std.testing.expectEqual(@as(u8, 0x00), p.header);
    try std.testing.expectEqual(@as(u64, 1), p.affected_rows);
    try std.testing.expectEqual(@as(u64, 2), p.last_insert_id);
    try std.testing.expectEqual(@as(u16, 2), p.status_flags.toInt());
    try std.testing.expectEqual(@as(u16, 4), p.warnings);
    try std.testing.expectEqualStrings("ok", p.info.slice());
    try std.testing.expectEqual(@as(usize, 9), offset);
}

const Data = @import("../../shared/Data.zig").Data;

const StatusFlags = @import("../StatusFlags.zig").StatusFlags;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
const StackReader = @import("./StackReader.zig");
