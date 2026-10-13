const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn randomSecure(buffer: []u8) !void {
    try std.Io.randomSecure(io(), buffer);
}

pub fn httpHeaderValue(message: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, message, "\r\n");
    _ = lines.next(); // Request/status line.
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(field_name, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub fn websocketAccept(key: []const u8) ![28]u8 {
    if (key.len != 24) return error.InvalidWebSocketKey;

    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var accept_data: [24 + magic.len]u8 = undefined;
    @memcpy(accept_data[0..key.len], key);
    @memcpy(accept_data[key.len..], magic);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&accept_data, &hash, .{});

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &hash);
    return accept_key;
}

test "RFC 6455 handshake accept key" {
    const accept_key = try websocketAccept("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept_key);
    try std.testing.expectError(error.InvalidWebSocketKey, websocketAccept("too short"));
}

test "HTTP header lookup is case insensitive" {
    const response = "HTTP/1.1 101 Switching Protocols\r\nsec-websocket-accept: proof\r\n\r\n";
    try std.testing.expectEqualStrings("proof", httpHeaderValue(response, "Sec-WebSocket-Accept").?);
}
