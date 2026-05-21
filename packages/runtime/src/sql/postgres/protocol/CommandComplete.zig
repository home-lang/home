// Copied from bun/src/sql/postgres/protocol/CommandComplete.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Imports rewritten: @import("bun") dropped — the upstream body's only
// reference is `bun.assert(length >= 4)`, replaced here with
// `std.debug.assert`.

const CommandComplete = @This();

command_tag: Data = .{ .empty = {} },

pub fn deinit(this: *@This()) void {
    this.command_tag.deinit();
}

pub fn decodeInternal(this: *@This(), comptime Container: type, reader: NewReader(Container)) !void {
    const length = try reader.length();
    std.debug.assert(length >= 4);

    const tag = try reader.readZ();
    this.* = .{
        .command_tag = tag,
    };
}

pub const decode = DecoderWrap(CommandComplete, decodeInternal).decode;

test "CommandComplete defaults to empty command_tag" {
    const std_local = @import("std");
    var c: CommandComplete = .{};
    try std_local.testing.expectEqualStrings("", c.command_tag.slice());
    c.deinit();
}

test "CommandComplete decodes command tag" {
    var offset: usize = 0;
    var message_start: usize = 0;
    const reader = StackReader.init(&.{ 0, 0, 0, 13, 'S', 'E', 'L', 'E', 'C', 'T', ' ', '1', 0 }, &offset, &message_start);
    var command: CommandComplete = .{};

    try command.decode(reader);
    defer command.deinit();

    try std.testing.expectEqualStrings("SELECT 1", command.command_tag.slice());
}

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
const StackReader = @import("./StackReader.zig");
