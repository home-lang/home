// Copied from bun/src/http/websocket_http_client.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`. Upstream imports are two
// JSC-coupled siblings under `../http_jsc/`:
//   - `websocket_client/WebSocketUpgradeClient.zig`  → `NewHTTPUpgradeClient`
//   - `websocket_client.zig`                         → `NewWebSocketClient`
// Both pull in `bun.webcore` / JSC / uws TLS sockets and are parked until the
// JSC bridge re-attaches. Local generic stubs preserve the upstream alias
// shape (`pub const X = factory(false)` / `factory(true)`) so call sites
// referencing `WebSocketHTTPClient` etc. as a type name still compile.

// Before the websocket handshaking step is completed, we use this:
pub const WebSocketHTTPClient = upgrade_client.NewHTTPUpgradeClient(false);
pub const WebSocketHTTPSClient = upgrade_client.NewHTTPUpgradeClient(true);

// After the websocket handshaking step is completed, we use this:
pub const WebSocketClient = websocket_client.NewWebSocketClient(false);
pub const WebSocketClientTLS = websocket_client.NewWebSocketClient(true);

/// Parked stubs — the JSC-coupled implementations live in
/// `../http_jsc/websocket_client/WebSocketUpgradeClient.zig` and
/// `../http_jsc/websocket_client.zig` upstream. The factories produce
/// `*ActiveSocket` variants the HTTPContext dispatchers union over, so for
/// now an `enum(u8) { tls, plain }` discriminant + opaque body keeps the
/// `*WebSocketHTTPClient` field-type spelling stable downstream.
const upgrade_client = struct {
    pub fn NewHTTPUpgradeClient(comptime ssl: bool) type {
        return opaque {
            pub const is_ssl: bool = ssl;

            pub fn exportAll() void {}
        };
    }
};

const websocket_client = struct {
    pub fn NewWebSocketClient(comptime ssl: bool) type {
        return opaque {
            pub const is_ssl: bool = ssl;

            pub fn exportAll() void {}
        };
    }
};

const std = @import("std");

test "websocket_http_client TLS / plain variants are distinct" {
    // The `ssl` const-generic threads through to each opaque's namespace,
    // so the TLS and plain variants are distinct types and carry the right
    // `is_ssl` value.
    try std.testing.expect(WebSocketHTTPClient != WebSocketHTTPSClient);
    try std.testing.expect(WebSocketClient != WebSocketClientTLS);
    try std.testing.expect(WebSocketHTTPClient != WebSocketClient);

    try std.testing.expectEqual(false, WebSocketHTTPClient.is_ssl);
    try std.testing.expectEqual(true, WebSocketHTTPSClient.is_ssl);
    try std.testing.expectEqual(false, WebSocketClient.is_ssl);
    try std.testing.expectEqual(true, WebSocketClientTLS.is_ssl);
}
