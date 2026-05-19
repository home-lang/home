// Copied from bun/src/sql/mysql/protocol/HandshakeV10.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// MySQL HandshakeV10 — server → client first packet on connect (Initial
// Handshake Packet, protocol version 10). Carries server version,
// thread / connection id, an 8-byte + ≥13-byte auth scramble, the
// joined 32-bit capability mask, the server-default character set,
// status flags, and the auth plugin name (when CLIENT_PLUGIN_AUTH is
// set).
//
// The decoder reaches into wave-21 NewReader method stubs (int / read /
// readZ / skip) and the wave-22 `home_rt.default_allocator`-dupe path;
// exercising decode() trips a natural compile error which is the
// trigger to port the real `bun.ByteList`-backed reader (Phase 12.2).

const HandshakeV10 = @This();
protocol_version: u8 = 10,
server_version: Data = .{ .empty = {} },
connection_id: u32 = 0,
auth_plugin_data_part_1: [8]u8 = undefined,
auth_plugin_data_part_2: []const u8 = &[_]u8{},
capability_flags: Capabilities = .{},
character_set: CharacterSet = CharacterSet.default,
status_flags: StatusFlags = .{},
auth_plugin_name: Data = .{ .empty = {} },

pub fn deinit(this: *HandshakeV10) void {
    this.server_version.deinit();
    this.auth_plugin_name.deinit();
}

pub fn decodeInternal(this: *HandshakeV10, comptime Context: type, reader: NewReader(Context)) !void {
    // Protocol version
    this.protocol_version = try reader.int(u8);
    if (this.protocol_version != 10) {
        return error.UnsupportedProtocolVersion;
    }

    // Server version (null-terminated string)
    this.server_version = try reader.readZ();

    // Connection ID (4 bytes)
    this.connection_id = try reader.int(u32);

    // Auth plugin data part 1 (8 bytes)
    var auth_data = try reader.read(8);
    defer auth_data.deinit();
    @memcpy(&this.auth_plugin_data_part_1, auth_data.slice());

    // Skip filler byte
    _ = try reader.int(u8);

    // Capability flags (lower 2 bytes)
    const capabilities_lower = try reader.int(u16);

    // Character set
    this.character_set = @enumFromInt(try reader.int(u8));

    // Status flags
    this.status_flags = StatusFlags.fromInt(try reader.int(u16));

    // Capability flags (upper 2 bytes)
    const capabilities_upper = try reader.int(u16);
    this.capability_flags = Capabilities.fromInt(@as(u32, capabilities_upper) << 16 | capabilities_lower);

    // Length of auth plugin data
    var auth_plugin_data_len = try reader.int(u8);
    if (auth_plugin_data_len < 21) {
        auth_plugin_data_len = 21;
    }

    // Skip reserved bytes
    reader.skip(10);

    // Auth plugin data part 2
    const remaining_auth_len = @max(13, auth_plugin_data_len - 8);
    var auth_data_2 = try reader.read(remaining_auth_len);
    defer auth_data_2.deinit();
    this.auth_plugin_data_part_2 = try home_rt.default_allocator.dupe(u8, auth_data_2.slice());

    // Auth plugin name
    if (this.capability_flags.CLIENT_PLUGIN_AUTH) {
        this.auth_plugin_name = try reader.readZ();
    }
}

pub const decode = decoderWrap(HandshakeV10, decodeInternal).decode;

test "HandshakeV10 default fields match the protocol-version-10 marker" {
    const std = @import("std");
    var pkt: HandshakeV10 = .{};
    try std.testing.expectEqual(@as(u8, 10), pkt.protocol_version);
    try std.testing.expectEqual(@as(u32, 0), pkt.connection_id);
    try std.testing.expectEqual(CharacterSet.default, pkt.character_set);
    pkt.deinit();
}

const Capabilities = @import("../Capabilities.zig");
const home_rt = @import("home_rt");
const CharacterSet = @import("./CharacterSet.zig").CharacterSet;
const Data = @import("../../shared/Data.zig").Data;
const StatusFlags = @import("../StatusFlags.zig").StatusFlags;

const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;
