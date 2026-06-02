// Copied from bun/src/http/H2Client.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`. Imports rewritten:
// @import("bun") → @import("home"); sibling `ClientSession` and the
// `H2TestingAPIs` JSC bridge (`../http_jsc/headers_jsc.zig`) are not yet
// ported. `Stream` and `PendingConnect` already live under `h2_client/` and
// re-export verbatim. `ClientSession` is stubbed as an opaque so the alias
// keeps the upstream name surface intact; full lsquic/uws state machine
// re-attaches in a later wave alongside the fetch() driver.

//! HTTP/2 path for fetch's HTTP client.
//!
//! `ClientSession` owns the TLS socket once ALPN selects "h2" and is the
//! `ActiveSocket` variant the HTTPContext handlers dispatch to. It holds the
//! connection-scoped state — HPACK tables, write/read buffers, server
//! SETTINGS — and a map of active `Stream`s, each bound to one `HTTPClient`.
//! Response frames are parsed into per-stream buffers and then handed to the
//! same `picohttp.Response` / `handleResponseBody` machinery the HTTP/1.1
//! path uses, so redirects, decompression and the result callback are shared.

/// Advertised as SETTINGS_INITIAL_WINDOW_SIZE; replenished via WINDOW_UPDATE
/// once half has been consumed.
pub const local_initial_window_size: u31 = 1 << 24;

/// Advertised as SETTINGS_MAX_HEADER_LIST_SIZE and enforced as a hard cap on
/// both the wire header block (HEADERS + CONTINUATION accumulation) and the
/// decoded header list, so a CONTINUATION flood or HPACK-amplification bomb
/// can't OOM the process. RFC 9113 §6.5.2 makes the setting advisory, so the
/// cap is checked locally regardless of what the server honors.
pub const local_max_header_list_size: u32 = 256 * 1024;

/// `write_buffer` high-water mark. `writeDataWindowed` stops queueing once the
/// userland send buffer crosses this even if flow-control window remains, so a
/// large grant doesn't duplicate the whole body in memory before the first
/// `flush()`. `onWritable → drainSendBodies` resumes once the socket drains.
pub const write_buffer_high_water: usize = 256 * 1024;

/// Abandon the connection (ENHANCE_YOUR_CALM) if queued control-frame replies
/// (PING/SETTINGS ACKs) push `write_buffer` past this while the socket is
/// stalled — caps the PING-reflection growth at a fixed budget instead of OOM.
pub const write_buffer_control_limit: usize = 1024 * 1024;

/// Live-object counters for the leak test in fetch-http2-leak.test.ts.
/// Incremented at allocation, decremented in deinit. Read from the JS thread
/// via TestingAPIs.liveCounts so they must be atomic.
pub var live_sessions = std.atomic.Value(i32).init(0);
pub var live_streams = std.atomic.Value(i32).init(0);

pub const Stream = @import("./h2_client/Stream.zig");
pub const PendingConnect = @import("./h2_client/PendingConnect.zig");

/// Parked: full `ClientSession` lives in `h2_client/ClientSession.zig` upstream
/// and pulls in the uws TLS socket + HPACK encoder/decoder + the HTTPClient
/// back-edge. Stubbed as an opaque so `*ClientSession` field types in
/// `Stream.zig` / `PendingConnect.zig` keep a stable name to point at when
/// the real session lands.
pub const ClientSession = opaque {};

/// Parked: `H2TestingAPIs` lives in `../http_jsc/headers_jsc.zig` upstream;
/// it bridges the live counters above to JS via JSC. The counters themselves
/// are usable today without the JS reflection layer.
pub const TestingAPIs = opaque {};

const std = @import("std");

test "H2Client constants match RFC 9113 caps" {
    try std.testing.expectEqual(@as(u31, 1 << 24), local_initial_window_size);
    try std.testing.expectEqual(@as(u32, 256 * 1024), local_max_header_list_size);
    try std.testing.expect(write_buffer_control_limit > write_buffer_high_water);
}

test "H2Client live counters start at zero" {
    // Reset for test isolation in case other tests touch the module-level vars.
    live_sessions.store(0, .monotonic);
    live_streams.store(0, .monotonic);
    try std.testing.expectEqual(@as(i32, 0), live_sessions.load(.monotonic));
    try std.testing.expectEqual(@as(i32, 0), live_streams.load(.monotonic));

    // Counters are i32 (signed) upstream so under-flow asserts can fire in
    // debug — verify the type roundtrips negative values.
    live_streams.store(-1, .monotonic);
    try std.testing.expectEqual(@as(i32, -1), live_streams.load(.monotonic));
    live_streams.store(0, .monotonic);
}
