// Copied from bun/src/sql/postgres/protocol/ParameterStatus.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Postgres ParameterStatus ('S') backend packet. Imports rewritten:
// `@import("bun")` dropped — upstream body's only reference is
// `bun.assert(length >= 4)` which lowers to `std.debug.assert`.

const ParameterStatus = @This();

name: Data = .{ .empty = {} },
value: Data = .{ .empty = {} },

pub fn deinit(this: *@This()) void {
    this.name.deinit();
    this.value.deinit();
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    const length = try reader.length();
    std.debug.assert(length >= 4);

    this.* = .{
        .name = try reader.readZ(),
        .value = try reader.readZ(),
    };
}

pub const decode = DecoderWrap(ParameterStatus, decodeInternal).decode;

test "ParameterStatus defaults to empty name and value" {
    const std_local = @import("std");
    var s: ParameterStatus = .{};
    defer s.deinit();
    try std_local.testing.expectEqualStrings("", s.name.slice());
    try std_local.testing.expectEqualStrings("", s.value.slice());
}

test "ParameterStatus decodes NUL-terminated name and value" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0, 0, 0, 8, 'a', 0, 'b', 0 }, &offset, &message_start);
    var status: ParameterStatus = .{};

    try status.decode(reader);

    try std.testing.expectEqualStrings("a", status.name.slice());
    try std.testing.expectEqualStrings("b", status.value.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
const StackReader = @import("./StackReader.zig");
