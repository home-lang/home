// Copied from bun/src/sql/postgres/protocol/NotificationResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres `A` (NotificationResponse) backend packet. Carries a LISTEN
// channel name + payload published via the `NOTIFY` SQL command.
// Imports rewritten: `@import("bun")` dropped — upstream body's only
// references are `bun.assert(length >= 4)` (lowers to `std.debug.assert`),
// `bun.default_allocator` (lowers to `home_rt.default_allocator`), and
// `bun.ByteList` for the `channel` / `payload` fields (substituted with
// the wave-18 `shared.Data.ByteList` stub — same `ptr/len/cap` field
// shape so callers that hold or read `.slice()` compile). Decoder body
// reaches into the wave-16 NewReader stub method surface (reader.length,
// reader.int4, reader.readZ); those trip a natural compile error if
// exercised.

const NotificationResponse = @This();

pid: int4 = 0,
channel: Data.ByteList = .{},
payload: Data.ByteList = .{},

pub fn deinit(this: *@This()) void {
    // Real upstream calls `this.channel.clearAndFree(bun.default_allocator)`
    // / same for payload. The wave-18 `ByteList` stub is a pure
    // field-shape — frees are a no-op until the real list lands.
    _ = this;
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    const length = try reader.length();
    std.debug.assert(length >= 4);

    this.* = .{
        .pid = try reader.int4(),
        .channel = (try reader.readZ()).toOwned(),
        .payload = (try reader.readZ()).toOwned(),
    };
}

pub const decode = DecoderWrap(NotificationResponse, decodeInternal).decode;

test "NotificationResponse defaults to pid 0 and empty channel/payload" {
    const std_local = @import("std");
    var n: NotificationResponse = .{};
    defer n.deinit();
    try std_local.testing.expectEqual(@as(int4, 0), n.pid);
    try std_local.testing.expectEqualStrings("", n.channel.slice());
    try std_local.testing.expectEqualStrings("", n.payload.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;

const int_types = @import("../types/int_types.zig");
const int4 = int_types.int4;
