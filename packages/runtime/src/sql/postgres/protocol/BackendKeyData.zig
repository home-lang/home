// Copied verbatim from bun/src/sql/postgres/protocol/BackendKeyData.zig
// at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md. No `@import("bun")` references.
//
// Postgres backend-key-data packet: the server sends a (process_id,
// secret_key) pair after authentication that the client must echo when
// it later sends a CancelRequest.

const BackendKeyData = @This();

process_id: u32 = 0,
secret_key: u32 = 0,
pub const decode = DecoderWrap(BackendKeyData, decodeInternal).decode;

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    if (!try reader.expectInt(u32, 12)) {
        return error.InvalidBackendKeyData;
    }

    this.* = .{
        .process_id = @bitCast(try reader.int4()),
        .secret_key = @bitCast(try reader.int4()),
    };
}

test "BackendKeyData.process_id/secret_key default to zero" {
    const std = @import("std");
    const bkd: BackendKeyData = .{};
    try std.testing.expectEqual(@as(u32, 0), bkd.process_id);
    try std.testing.expectEqual(@as(u32, 0), bkd.secret_key);
}

test "BackendKeyData decodes process id and secret key" {
    const std = @import("std");
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0, 0, 0, 12, 0, 0, 0, 7, 0, 0, 0, 9 }, &offset, &message_start);
    var bkd: BackendKeyData = .{};

    try bkd.decode(reader);

    try std.testing.expectEqual(@as(u32, 7), bkd.process_id);
    try std.testing.expectEqual(@as(u32, 9), bkd.secret_key);
}

const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;

const NewReader = @import("./NewReader.zig").NewReader;
const StackReader = @import("./StackReader.zig");
