// Copied from bun/src/sql/postgres/protocol/NoticeResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres `N` (NoticeResponse) backend packet. Same shape as
// ErrorResponse (a stream of `T<value>` FieldMessage records) but
// non-fatal — typically WARNING / NOTICE / INFO severity. Imports
// rewritten: `@import("bun")` dropped — `bun.default_allocator`
// lowers to `home_rt.default_allocator`. `toJS` JSC-bridge re-export
// omitted (lands in Phase 12.2). Decoder body reaches into the wave-16
// NewReader stub method surface.

const NoticeResponse = @This();

messages: std.ArrayListUnmanaged(FieldMessage) = .{},

pub fn deinit(this: *NoticeResponse) void {
    for (this.messages.items) |*message| {
        message.deinit();
    }
    this.messages.deinit(home_rt.default_allocator);
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    var remaining_bytes = try reader.length();
    remaining_bytes -|= 4;

    if (remaining_bytes > 0) {
        this.* = .{
            .messages = try FieldMessage.decodeList(Container, reader),
        };
    }
}

pub const decode = DecoderWrap(NoticeResponse, decodeInternal).decode;

test "NoticeResponse defaults to empty messages list" {
    var n: NoticeResponse = .{};
    defer n.deinit();
    try std.testing.expectEqual(@as(usize, 0), n.messages.items.len);
}

const std = @import("std");
const home_rt = @import("home");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const FieldMessage = @import("./FieldMessage.zig").FieldMessage;
const NewReader = @import("./NewReader.zig").NewReader;
