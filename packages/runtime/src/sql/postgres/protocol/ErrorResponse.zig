// Copied from bun/src/sql/postgres/protocol/ErrorResponse.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres `E` (ErrorResponse) backend packet. Carries a stream of
// `T<value>` FieldMessage records (severity / code / message / ...).
// Imports rewritten: `@import("bun")` dropped — `bun.default_allocator`
// lowers to `home_rt.default_allocator` and `bun.assert(...)` lowers
// to `std.debug.assert`. The `toJS` JSC-bridge re-export is omitted
// (lands in Phase 12.2 when the sql_jsc surface ports). Decoder body
// reaches into the wave-16 NewReader stub method surface.

const ErrorResponse = @This();

messages: std.ArrayListUnmanaged(FieldMessage) = .empty,

pub fn format(formatter: ErrorResponse, writer: *std.Io.Writer) !void {
    for (formatter.messages.items) |message| {
        try writer.print("{f}\n", .{message});
    }
}

pub fn deinit(this: *ErrorResponse) void {
    for (this.messages.items) |*message| {
        message.deinit();
    }
    this.messages.deinit(home_rt.default_allocator);
}

pub fn toJS(this: ErrorResponse, globalObject: *home_rt.jsc.JSGlobalObject) home_rt.JSError!home_rt.jsc.JSValue {
    return globalObject.createErrorInstance("{f}", .{this});
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    var remaining_bytes = try reader.length();
    if (remaining_bytes < 4) return error.InvalidMessageLength;
    remaining_bytes -|= 4;

    if (remaining_bytes > 0) {
        this.* = .{
            .messages = try FieldMessage.decodeList(Container, reader),
        };
    }
}

pub const decode = DecoderWrap(ErrorResponse, decodeInternal).decode;

test "ErrorResponse defaults to empty messages list" {
    var e: ErrorResponse = .{};
    defer e.deinit();
    try std.testing.expectEqual(@as(usize, 0), e.messages.items.len);
}

const std = @import("std");
const home_rt = @import("home");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const FieldMessage = @import("./FieldMessage.zig").FieldMessage;
const NewReader = @import("./NewReader.zig").NewReader;
