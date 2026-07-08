// Copied from bun/src/http/H2FrameParser.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); upstream
// `bun.debugAssert` (Debug-mode invariant check) is rerouted through
// `home_rt.assert`, which has identical Debug-build semantics.

//! HTTP/2 wire-format types for the fetch() HTTP/2 client. Kept free of JSC
//! and socket dependencies so the node:http2 JS bindings (which currently
//! carry their own copies in src/runtime/api/bun/h2_frame_parser.zig) can later
//! share them.

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const MAX_WINDOW_SIZE = std.math.maxInt(i32);
pub const MAX_HEADER_TABLE_SIZE = std.math.maxInt(u32);
pub const MAX_STREAM_ID = std.math.maxInt(i32);
pub const MAX_FRAME_SIZE = std.math.maxInt(u24);
pub const DEFAULT_WINDOW_SIZE = std.math.maxInt(u16);
pub const DEFAULT_MAX_FRAME_SIZE: u24 = 16384;

pub const FrameType = enum(u8) {
    HTTP_FRAME_DATA = 0x00,
    HTTP_FRAME_HEADERS = 0x01,
    HTTP_FRAME_PRIORITY = 0x02,
    HTTP_FRAME_RST_STREAM = 0x03,
    HTTP_FRAME_SETTINGS = 0x04,
    HTTP_FRAME_PUSH_PROMISE = 0x05,
    HTTP_FRAME_PING = 0x06,
    HTTP_FRAME_GOAWAY = 0x07,
    HTTP_FRAME_WINDOW_UPDATE = 0x08,
    HTTP_FRAME_CONTINUATION = 0x09,
    HTTP_FRAME_ALTSVC = 0x0A,
    HTTP_FRAME_ORIGIN = 0x0C,
    _,
};

pub const PingFrameFlags = enum(u8) {
    ACK = 0x1,
};

pub const DataFrameFlags = enum(u8) {
    END_STREAM = 0x1,
    PADDED = 0x8,
};

pub const HeadersFrameFlags = enum(u8) {
    END_STREAM = 0x1,
    END_HEADERS = 0x4,
    PADDED = 0x8,
    PRIORITY = 0x20,
};

pub const SettingsFlags = enum(u8) {
    ACK = 0x1,
};

pub const ErrorCode = enum(u32) {
    NO_ERROR = 0x0,
    PROTOCOL_ERROR = 0x1,
    INTERNAL_ERROR = 0x2,
    FLOW_CONTROL_ERROR = 0x3,
    SETTINGS_TIMEOUT = 0x4,
    STREAM_CLOSED = 0x5,
    FRAME_SIZE_ERROR = 0x6,
    REFUSED_STREAM = 0x7,
    CANCEL = 0x8,
    COMPRESSION_ERROR = 0x9,
    CONNECT_ERROR = 0xa,
    ENHANCE_YOUR_CALM = 0xb,
    INADEQUATE_SECURITY = 0xc,
    HTTP_1_1_REQUIRED = 0xd,
    MAX_PENDING_SETTINGS_ACK = 0xe,
    _,
};

pub const SettingsType = enum(u16) {
    SETTINGS_HEADER_TABLE_SIZE = 0x1,
    SETTINGS_ENABLE_PUSH = 0x2,
    SETTINGS_MAX_CONCURRENT_STREAMS = 0x3,
    SETTINGS_INITIAL_WINDOW_SIZE = 0x4,
    SETTINGS_MAX_FRAME_SIZE = 0x5,
    SETTINGS_MAX_HEADER_LIST_SIZE = 0x6,
    SETTINGS_ENABLE_CONNECT_PROTOCOL = 0x8,
    SETTINGS_NO_RFC7540_PRIORITIES = 0x9,
    _,
};

pub inline fn u32FromBytes(src: []const u8) u32 {
    home_rt.assert(src.len == 4);
    return std.mem.readInt(u32, src[0..4], .big);
}

pub const UInt31WithReserved = packed struct(u32) {
    reserved: bool = false,
    uint31: u31 = 0,

    pub inline fn from(value: u32) UInt31WithReserved {
        return .{ .uint31 = @truncate(value & 0x7fffffff), .reserved = value & 0x80000000 != 0 };
    }

    pub inline fn init(value: u31, reserved: bool) UInt31WithReserved {
        return .{ .uint31 = value, .reserved = reserved };
    }

    pub inline fn toUInt32(value: UInt31WithReserved) u32 {
        return @bitCast(value);
    }

    pub inline fn fromBytes(src: []const u8) UInt31WithReserved {
        const value: u32 = u32FromBytes(src);
        return .{ .uint31 = @truncate(value & 0x7fffffff), .reserved = value & 0x80000000 != 0 };
    }
};

pub const StreamPriority = packed struct(u40) {
    streamIdentifier: u32 = 0,
    weight: u8 = 0,

    pub const byteSize: usize = 5;

    pub inline fn from(dst: *StreamPriority, src: []const u8) void {
        @memcpy(@as(*[StreamPriority.byteSize]u8, @ptrCast(dst)), src);
        h2_byteswap.byteSwapAllFields(StreamPriority, dst);
    }
};

pub const FrameHeader = packed struct(u72) {
    length: u24 = 0,
    type: u8 = @intFromEnum(FrameType.HTTP_FRAME_SETTINGS),
    flags: u8 = 0,
    streamIdentifier: u32 = 0,

    pub const byteSize: usize = 9;

    pub inline fn from(dst: *FrameHeader, src: []const u8, offset: usize, comptime end: bool) void {
        @memcpy(@as(*[FrameHeader.byteSize]u8, @ptrCast(dst))[offset .. src.len + offset], src);
        if (comptime end) {
            h2_byteswap.byteSwapAllFields(FrameHeader, dst);
        }
    }
};

pub const SettingsPayloadUnit = packed struct(u48) {
    type: u16,
    value: u32,
    pub const byteSize: usize = 6;
    pub inline fn from(dst: *SettingsPayloadUnit, src: []const u8, offset: usize, comptime end: bool) void {
        @memcpy(@as(*[SettingsPayloadUnit.byteSize]u8, @ptrCast(dst))[offset .. src.len + offset], src);
        if (comptime end) {
            h2_byteswap.byteSwapAllFields(SettingsPayloadUnit, dst);
        }
    }
    pub inline fn encode(dst: *[byteSize]u8, setting: SettingsType, value: u32) void {
        std.mem.writeInt(u16, dst[0..2], @intFromEnum(setting), .big);
        std.mem.writeInt(u32, dst[2..6], value, .big);
    }
};

const home_rt = @import("home");
const std = @import("std");
const h2_byteswap = @import("h2_byteswap.zig");

test "H2FrameParser.u32FromBytes decodes big-endian u32" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(@as(u32, 0x01020304), u32FromBytes(&bytes));
}

test "H2FrameParser.UInt31WithReserved.from splits the reserved bit" {
    // Upstream Bun reads `reserved` from the wire-format MSB but packs it
    // in the LSB-positioned `reserved` field of the packed struct(u32);
    // `from` and `toUInt32` are intentionally NOT inverses for the same
    // 32-bit value. This test only validates the field split that callers
    // rely on (HTTP/2 frame parsing inspects `.reserved` and `.uint31`).
    const a = UInt31WithReserved.from(0x80000005);
    try std.testing.expect(a.reserved);
    try std.testing.expectEqual(@as(u31, 5), a.uint31);

    const b = UInt31WithReserved.from(0x00000005);
    try std.testing.expect(!b.reserved);
    try std.testing.expectEqual(@as(u31, 5), b.uint31);
}

test "H2FrameParser.SettingsPayloadUnit.encode writes big-endian" {
    var buf: [SettingsPayloadUnit.byteSize]u8 = undefined;
    SettingsPayloadUnit.encode(&buf, SettingsType.SETTINGS_INITIAL_WINDOW_SIZE, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x04, 0x01, 0x02, 0x03, 0x04 }, &buf);
}

test "H2FrameParser.FrameType enum tags match the wire values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(FrameType.HTTP_FRAME_DATA));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(FrameType.HTTP_FRAME_HEADERS));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(FrameType.HTTP_FRAME_GOAWAY));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(FrameType.HTTP_FRAME_ALTSVC));
}

test "H2FrameParser client_preface is the RFC 9113 connection preface" {
    try std.testing.expectEqualStrings("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", client_preface);
}
