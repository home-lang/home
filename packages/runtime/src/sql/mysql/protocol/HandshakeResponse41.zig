// Copied from bun/src/sql/mysql/protocol/HandshakeResponse41.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Client authentication response packet writer. Import rewrites:
// `bun.StringHashMapUnmanaged` -> `std.StringHashMapUnmanaged`,
// `bun.default_allocator` -> `home_rt.default_allocator`,
// `bun.Output.scoped` -> `home_rt.Output.scoped`.
// Writer bodies remain gated by the current MySQL `NewWriter` stub until
// the full packet writer lands.

// Client authentication response
const HandshakeResponse41 = @This();
capability_flags: Capabilities,
max_packet_size: u32 = 0xFFFFFF, // 16MB default
character_set: CharacterSet = CharacterSet.default,
username: Data,
auth_response: Data,
database: Data,
auth_plugin_name: Data,
connect_attrs: std.StringHashMapUnmanaged([]const u8) = .empty,
sequence_id: u8,

pub fn deinit(this: *HandshakeResponse41) void {
    this.username.deinit();
    this.auth_response.deinit();
    this.database.deinit();
    this.auth_plugin_name.deinit();

    var it = this.connect_attrs.iterator();
    while (it.next()) |entry| {
        home_rt.default_allocator.free(entry.key_ptr.*);
        home_rt.default_allocator.free(entry.value_ptr.*);
    }
    this.connect_attrs.deinit(home_rt.default_allocator);
}

pub fn writeInternal(this: *HandshakeResponse41, comptime Context: type, writer: NewWriter(Context)) !void {
    var packet = try writer.start(this.sequence_id);

    this.capability_flags.CLIENT_CONNECT_ATTRS = this.connect_attrs.count() > 0;

    // Write client capabilities flags (4 bytes)
    const caps = this.capability_flags.toInt();
    try writer.int4(caps);
    debug("Client capabilities: [{f}] 0x{x:0>8} sequence_id: {d}", .{ this.capability_flags, caps, this.sequence_id });

    // Write max packet size (4 bytes)
    try writer.int4(this.max_packet_size);

    // Write character set (1 byte)
    try writer.int1(@intFromEnum(this.character_set));

    // Write 23 bytes of padding
    const padding: [23]u8 = @splat(0);
    try writer.write(&padding);

    // Write username (null terminated)
    try writer.writeZ(this.username.slice());

    // Write auth response based on capabilities
    const auth_data = this.auth_response.slice();
    if (this.capability_flags.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) {
        try writer.writeLengthEncodedString(auth_data);
    } else if (this.capability_flags.CLIENT_SECURE_CONNECTION) {
        try writer.int1(@intCast(auth_data.len));
        try writer.write(auth_data);
    } else {
        try writer.writeZ(auth_data);
    }

    // Write database name if requested
    if (this.capability_flags.CLIENT_CONNECT_WITH_DB and this.database.slice().len > 0) {
        try writer.writeZ(this.database.slice());
    }

    // Write auth plugin name if supported
    if (this.capability_flags.CLIENT_PLUGIN_AUTH) {
        try writer.writeZ(this.auth_plugin_name.slice());
    }

    // Write connect attributes if enabled
    if (this.capability_flags.CLIENT_CONNECT_ATTRS) {
        var total_length: usize = 0;
        var it = this.connect_attrs.iterator();
        while (it.next()) |entry| {
            total_length += encodeLengthInt(entry.key_ptr.*.len).len;
            total_length += entry.key_ptr.*.len;
            total_length += encodeLengthInt(entry.value_ptr.*.len).len;
            total_length += entry.value_ptr.*.len;
        }

        try writer.writeLengthEncodedInt(total_length);

        it = this.connect_attrs.iterator();
        while (it.next()) |entry| {
            try writer.writeLengthEncodedString(entry.key_ptr.*);
            try writer.writeLengthEncodedString(entry.value_ptr.*);
        }
    }

    if (this.capability_flags.CLIENT_ZSTD_COMPRESSION_ALGORITHM) {
        @panic("zstd compression algorithm is not supported");
    }

    try packet.end();
}

pub const write = writeWrap(HandshakeResponse41, writeInternal).write;

test "HandshakeResponse41 defaults packet size, charset, and empty attrs" {
    const testing = std.testing;
    var response: HandshakeResponse41 = .{
        .capability_flags = .{},
        .username = .{ .temporary = "user" },
        .auth_response = .{ .temporary = "auth" },
        .database = .{ .empty = {} },
        .auth_plugin_name = .{ .temporary = "mysql_native_password" },
        .sequence_id = 1,
    };
    defer response.deinit();

    try testing.expectEqual(@as(u32, 0xFFFFFF), response.max_packet_size);
    try testing.expectEqual(CharacterSet.default, response.character_set);
    try testing.expectEqual(@as(usize, 0), response.connect_attrs.count());
}

test "HandshakeResponse41 write entrypoint is addressable" {
    const testing = std.testing;
    try testing.expect(@typeInfo(@TypeOf(write)) == .@"fn");
}

test "HandshakeResponse41 writes a secure connection packet" {
    const testing = std.testing;
    var response: HandshakeResponse41 = .{
        .capability_flags = .{
            .CLIENT_PROTOCOL_41 = true,
            .CLIENT_SECURE_CONNECTION = true,
            .CLIENT_PLUGIN_AUTH = true,
        },
        .username = .{ .temporary = "home" },
        .auth_response = .{ .temporary = "token" },
        .database = .{ .empty = {} },
        .auth_plugin_name = .{ .temporary = "mysql_native_password" },
        .sequence_id = 1,
    };
    defer response.deinit();

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    const ctx = TestWriter.init(&buf, &len);

    try response.write(ctx);

    const out = ctx.slice();
    try testing.expectEqualSlices(u8, &.{ 65, 0, 0, 1 }, out[0..4]);
    try testing.expectEqual(@as(u8, 'h'), out[36]);
    try testing.expectEqual(@as(u8, 0), out[40]);
    try testing.expectEqual(@as(u8, 5), out[41]);
    try testing.expectEqualSlices(u8, "token", out[42..47]);
    try testing.expectEqualSlices(u8, "mysql_native_password", out[47..68]);
    try testing.expectEqual(@as(u8, 0), out[68]);
}

const debug = home_rt.Output.scoped(.MySQLConnection, .hidden);

const Capabilities = @import("../Capabilities.zig");
const home_rt = @import("home");
const std = @import("std");
const CharacterSet = @import("./CharacterSet.zig").CharacterSet;
const Data = @import("../../shared/Data.zig").Data;
const encodeLengthInt = @import("./EncodeInt.zig").encodeLengthInt;

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;

const TestWriter = struct {
    bytes: []u8,
    len: *usize,

    fn init(bytes: []u8, len: *usize) TestWriter {
        len.* = 0;
        return .{ .bytes = bytes, .len = len };
    }

    fn slice(this: TestWriter) []const u8 {
        return this.bytes[0..this.len.*];
    }

    pub fn offset(this: TestWriter) usize {
        return this.len.*;
    }

    pub fn write(this: TestWriter, bytes: []const u8) AnyMySQLError.Error!void {
        if (this.len.* + bytes.len > this.bytes.len) return error.ShortRead;
        @memcpy(this.bytes[this.len.*..][0..bytes.len], bytes);
        this.len.* += bytes.len;
    }

    pub fn pwrite(this: TestWriter, bytes: []const u8, offset_value: usize) AnyMySQLError.Error!void {
        if (offset_value + bytes.len > this.len.*) return error.ShortRead;
        @memcpy(this.bytes[offset_value..][0..bytes.len], bytes);
    }
};

const AnyMySQLError = @import("./AnyMySQLError.zig");
