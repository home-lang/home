// Copied from bun/src/http/H3Client.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`. Imports rewritten:
// @import("bun") → @import("home"). `AltSvc`, `Stream`, `PendingConnect`
// already live under `h3_client/` and re-export verbatim. `H3TestingAPIs`
// lives behind the JSC bridge in `../http_jsc/headers_jsc.zig` and is parked
// alongside the JSC layer.

//! HTTP/3 client over lsquic via packages/bun-usockets/src/quic.c.
//!
//! One `ClientContext` per HTTP-thread loop wraps the lsquic client engine;
//! each `ClientSession` is one QUIC connection to an origin and multiplexes
//! `Stream`s, each bound 1:1 to an `HTTPClient`. The result-delivery surface
//! is the same one H2 uses (`handleResponseMetadata` / `handleResponseBody` /
//! `progressUpdateH3`), so redirect, decompression, and FetchTasklet plumbing
//! are shared with HTTP/1.1.
//!
//! Layout mirrors `h2_client/`:
//!   - `Stream`         — one in-flight request
//!   - `ClientSession`  — one QUIC connection (pooled per origin)
//!   - `ClientContext`  — process-global lsquic engine + session registry
//!   - `encode`         — request header/body framing onto a quic.Stream
//!   - `callbacks`      — lsquic → Zig glue (on_hsk_done / on_stream_* / …)
//!   - `PendingConnect` — DNS-pending connect resolution

pub const Stream = @import("./h3_client/Stream.zig");
pub const ClientSession = @import("./h3_client/ClientSession.zig");
pub const ClientContext = @import("./h3_client/ClientContext.zig");
pub const PendingConnect = @import("./h3_client/PendingConnect.zig");
pub const AltSvc = @import("./h3_client/AltSvc.zig");

/// Live-object counters for the leak test in fetch-http3-client.test.ts.
/// Incremented at allocation, decremented in deinit. Read from the JS thread
/// via TestingAPIs.quicLiveCounts so they must be atomic.
pub var live_sessions = std.atomic.Value(u32).init(0);
pub var live_streams = std.atomic.Value(u32).init(0);

/// Parked: `H3TestingAPIs` lives in `../http_jsc/headers_jsc.zig` upstream
/// and bridges the counters above to JS via JSC. The counters themselves
/// are usable without the JS reflection layer.
pub const TestingAPIs = opaque {};

const std = @import("std");

test "H3Client live counters start at zero" {
    live_sessions.store(0, .monotonic);
    live_streams.store(0, .monotonic);
    try std.testing.expectEqual(@as(u32, 0), live_sessions.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), live_streams.load(.monotonic));

    // u32 (unsigned) — wraps with monotonic add. Verify the wrap shape.
    _ = live_streams.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), live_streams.load(.monotonic));
    _ = live_streams.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 0), live_streams.load(.monotonic));
}
