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

// Real JSC-coupled implementations (no longer parked): the upgrade client
// (pre-101 handshake) and the frame client (post-101). Their `exportAll()`
// emits the `Bun__WebSocket{,HTTP}Client*__*` C ABI the C++ WebSocket binding
// calls; previously these were empty stubs, so every WS native call no-op'd.
const upgrade_client = @import("../http_jsc/websocket_client/WebSocketUpgradeClient.zig");
const websocket_client = @import("../http_jsc/websocket_client.zig");

const std = @import("std");

test "websocket_http_client TLS / plain variants are distinct" {
    // The `ssl` const-generic threads through to each opaque's namespace,
    // so the TLS and plain variants are distinct types and carry the right
    // `is_ssl` value.
    try std.testing.expect(WebSocketHTTPClient != WebSocketHTTPSClient);
    try std.testing.expect(WebSocketClient != WebSocketClientTLS);
    try std.testing.expect(WebSocketHTTPClient != WebSocketClient);

}
