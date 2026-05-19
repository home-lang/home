// Copied from bun/src/sql/mysql/protocol/SSLRequest.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// MySQL SSLRequest packet — client → server during the TLS upgrade
// handshake (sent right before the regular HandshakeResponse41 once
// CLIENT_SSL is negotiated). 32-byte fixed body: 4-byte capability
// flags, 4-byte max packet size, 1-byte charset, 23 bytes of padding.
// See
//   https://dev.mysql.com/doc/dev/mysql-server/8.4.6/page_protocol_connection_phase_packets_protocol_ssl_request.html
//
// The body reaches into wave-21 NewWriter method stubs (start / int4 /
// int1 / write); compile errors out only if exercised, which is the
// trigger to port the real `bun.ByteList`-backed writer.

const SSLRequest = @This();
capability_flags: Capabilities,
max_packet_size: u32 = 0xFFFFFF, // 16MB default
character_set: CharacterSet = CharacterSet.default,
has_connection_attributes: bool = false,

pub fn deinit(_: *SSLRequest) void {}

pub fn writeInternal(this: *SSLRequest, comptime Context: type, writer: NewWriter(Context)) !void {
    var packet = try writer.start(1);

    this.capability_flags.CLIENT_CONNECT_ATTRS = this.has_connection_attributes;

    // Write client capabilities flags (4 bytes)
    const caps = this.capability_flags.toInt();
    try writer.int4(caps);
    debug("Client capabilities: [{f}] 0x{x:0>8}", .{ this.capability_flags, caps });

    // Write max packet size (4 bytes)
    try writer.int4(this.max_packet_size);

    // Write character set (1 byte)
    try writer.int1(@intFromEnum(this.character_set));

    // Write 23 bytes of padding. `[N]u8{0} ** K` is the upstream form;
    // Zig 0.17 dropped that syntax for tuple-init repetition, so
    // `[K]u8{0} ** 1` (or simply a fixed-size zero-init) is the local
    // shape. Mirrors the `Aligner.zig` / `thumbhash.zig` migration.
    const padding: [23]u8 = @splat(0);
    try writer.write(&padding);

    try packet.end();
}

pub const write = writeWrap(SSLRequest, writeInternal).write;

test "SSLRequest defaults max_packet_size to 16MB and charset to default" {
    const std = @import("std");
    var req: SSLRequest = .{ .capability_flags = .{} };
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), req.max_packet_size);
    try std.testing.expectEqual(CharacterSet.default, req.character_set);
    try std.testing.expectEqual(false, req.has_connection_attributes);
    req.deinit();
}

const debug = home_rt.Output.scoped(.MySQLConnection, .hidden);

const Capabilities = @import("../Capabilities.zig");
const home_rt = @import("home_rt");
const CharacterSet = @import("./CharacterSet.zig").CharacterSet;

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;
