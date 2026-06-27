// Copied from bun/src/http/websocket.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); upstream
// `bun.Environment`, `bun.assert` map 1:1 to `home_rt.Environment`,
// `home_rt.assert`.

// This code is based on https://github.com/frmdstryr/zhp/blob/a4b5700c289c3619647206144e10fb414113a888/src/websocket.zig
// Thank you @frmdstryr.

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Res3 = 0x3,
    Res4 = 0x4,
    Res5 = 0x5,
    Res6 = 0x6,
    Res7 = 0x7,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    ResB = 0xB,
    ResC = 0xC,
    ResD = 0xD,
    ResE = 0xE,
    ResF = 0xF,

    pub fn isControl(opcode: Opcode) bool {
        return @intFromEnum(opcode) & 0x8 != 0;
    }
};

pub const WebsocketHeader = packed struct(u16) {
    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv: u2 = 0, //rsv2 and rsv3
    compressed: bool = false, // rsv1
    final: bool = true,

    pub fn writeHeader(header: WebsocketHeader, writer: anytype, n: usize) anyerror!void {
        // packed structs are sometimes buggy
        // lets check it worked right
        if (comptime Environment.allow_assert) {
            var buf_ = [2]u8{ 0, 0 };
            std.mem.writeInt(u16, &buf_, @as(u16, @bitCast(header)), .big);
            const casted = std.mem.readInt(u16, &buf_, .big);
            home_rt.assert(casted == @as(u16, @bitCast(header)));
            home_rt.assert(std.meta.eql(@as(WebsocketHeader, @bitCast(casted)), header));
        }

        try writer.writeInt(u16, @as(u16, @bitCast(header)), .big);
        home_rt.assert(header.len == packLength(n));
    }

    pub fn packLength(length: usize) u7 {
        return switch (length) {
            0...125 => @as(u7, @truncate(length)),
            126...0xFFFF => 126,
            else => 127,
        };
    }

    const mask_length = 4;
    const header_length = 2;

    pub fn lengthByteCount(byte_length: usize) usize {
        return switch (byte_length) {
            0...125 => 0,
            126...0xFFFF => @sizeOf(u16),
            else => @sizeOf(u64),
        };
    }

    pub fn frameSize(byte_length: usize) usize {
        return header_length + byte_length + lengthByteCount(byte_length);
    }

    pub fn frameSizeIncludingMask(byte_length: usize) usize {
        return frameSize(byte_length) + mask_length;
    }

    pub fn slice(self: WebsocketHeader) [2]u8 {
        return @as([2]u8, @bitCast(@byteSwap(@as(u16, @bitCast(self)))));
    }

    pub fn fromSlice(bytes: [2]u8) WebsocketHeader {
        return @as(WebsocketHeader, @bitCast(@byteSwap(@as(u16, @bitCast(bytes)))));
    }
};

const std = @import("std");

const home_rt = @import("home");
const Environment = home_rt.Environment;

test "websocket.Opcode.isControl flags control frames" {
    try std.testing.expect(Opcode.Close.isControl());
    try std.testing.expect(Opcode.Ping.isControl());
    try std.testing.expect(Opcode.Pong.isControl());
    try std.testing.expect(!Opcode.Text.isControl());
    try std.testing.expect(!Opcode.Binary.isControl());
    try std.testing.expect(!Opcode.Continue.isControl());
}

test "websocket.WebsocketHeader.packLength buckets per RFC 6455" {
    try std.testing.expectEqual(@as(u7, 0), WebsocketHeader.packLength(0));
    try std.testing.expectEqual(@as(u7, 125), WebsocketHeader.packLength(125));
    try std.testing.expectEqual(@as(u7, 126), WebsocketHeader.packLength(126));
    try std.testing.expectEqual(@as(u7, 126), WebsocketHeader.packLength(0xFFFF));
    try std.testing.expectEqual(@as(u7, 127), WebsocketHeader.packLength(0x10000));
}

test "websocket.WebsocketHeader.lengthByteCount sizes the length field" {
    try std.testing.expectEqual(@as(usize, 0), WebsocketHeader.lengthByteCount(0));
    try std.testing.expectEqual(@as(usize, 0), WebsocketHeader.lengthByteCount(125));
    try std.testing.expectEqual(@as(usize, @sizeOf(u16)), WebsocketHeader.lengthByteCount(126));
    try std.testing.expectEqual(@as(usize, @sizeOf(u16)), WebsocketHeader.lengthByteCount(0xFFFF));
    try std.testing.expectEqual(@as(usize, @sizeOf(u64)), WebsocketHeader.lengthByteCount(0x10000));
}

test "websocket.WebsocketHeader.frameSize composes header + payload + length-extension" {
    try std.testing.expectEqual(@as(usize, 2 + 10 + 0), WebsocketHeader.frameSize(10));
    try std.testing.expectEqual(@as(usize, 2 + 200 + @sizeOf(u16)), WebsocketHeader.frameSize(200));
    try std.testing.expectEqual(@as(usize, 2 + 10 + 0 + 4), WebsocketHeader.frameSizeIncludingMask(10));
}

test "websocket.WebsocketHeader.slice round-trips through fromSlice" {
    const header: WebsocketHeader = .{
        .len = 42,
        .mask = true,
        .opcode = .Text,
        .final = true,
    };
    const bytes = header.slice();
    const back = WebsocketHeader.fromSlice(bytes);
    try std.testing.expect(std.meta.eql(header, back));
}
