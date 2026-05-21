// Copied from bun/src/sql/postgres/protocol/NegotiateProtocolVersion.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` -> `home_rt`; upstream `bun.String`
// is represented with FieldMessage.String's heap-owned UTF-8 stand-in until
// Home ports Bun's tagged WTF-String substrate. The decode body keeps the
// upstream reader shape and naturally depends on the wave-16 NewReader stub
// methods if exercised.

const NegotiateProtocolVersion = @This();

version: int4 = 0,
unrecognized_options: std.ArrayListUnmanaged(String) = .empty,

pub fn deinit(this: *@This()) void {
    for (this.unrecognized_options.items) |*option| {
        option.deref();
    }
    this.unrecognized_options.deinit(home_rt.default_allocator);
    this.unrecognized_options = .empty;
}

pub fn decodeInternal(
    this: *@This(),
    comptime Container: type,
    reader: NewReader(Container),
) !void {
    const length = try reader.length();
    std.debug.assert(length >= 4);

    const version = try reader.int4();
    this.* = .{
        .version = version,
    };

    const unrecognized_options_count: u32 = @intCast(@max(try reader.int4(), 0));
    try this.unrecognized_options.ensureTotalCapacity(home_rt.default_allocator, unrecognized_options_count);
    errdefer {
        for (this.unrecognized_options.items) |*option| {
            option.deref();
        }
        this.unrecognized_options.deinit(home_rt.default_allocator);
    }
    for (0..unrecognized_options_count) |_| {
        var option = try reader.readZ();
        if (option.slice().len == 0) break;
        defer option.deinit();
        this.unrecognized_options.appendAssumeCapacity(
            String.cloneUTF8(option.slice()),
        );
    }
}

pub const decode = DecoderWrap(NegotiateProtocolVersion, decodeInternal).decode;

test "NegotiateProtocolVersion defaults to version zero and no options" {
    var message: NegotiateProtocolVersion = .{};
    defer message.deinit();

    try std.testing.expectEqual(@as(int4, 0), message.version);
    try std.testing.expectEqual(@as(usize, 0), message.unrecognized_options.items.len);
}

test "NegotiateProtocolVersion deinit releases cloned option strings" {
    var message: NegotiateProtocolVersion = .{};
    try message.unrecognized_options.append(home_rt.default_allocator, String.cloneUTF8("unknown"));
    try std.testing.expectEqualStrings("unknown", message.unrecognized_options.items[0].slice());
    message.deinit();
    try std.testing.expectEqual(@as(usize, 0), message.unrecognized_options.items.len);
}

const std = @import("std");
const home_rt = @import("home_rt");
const DecoderWrap = @import("./DecoderWrap.zig").DecoderWrap;
const NewReader = @import("./NewReader.zig").NewReader;
const String = @import("./FieldMessage.zig").FieldMessage.String;

const int_types = @import("../types/int_types.zig");
const int4 = int_types.int4;
