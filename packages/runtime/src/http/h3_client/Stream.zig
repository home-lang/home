// Copied from bun/src/http/h3_client/Stream.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home").
//   - `bun.uws.quic` → `home_rt.uws_sys.quic` (the lsquic opaque types
//     already ported under uws_sys/quic/).
//   - `bun.http` (HTTPClient) and the sibling `ClientSession` /
//     `../H3Client.zig` are not yet ported; opaque/struct stubs let this
//     file spell `*ClientSession` / `?*HTTPClient` and reference the
//     `live_streams` counter the way the upstream module does.
//   - `bun.picohttp.Header` is shimmed as a local struct mirroring its
//     wire shape (name + value byte slices).

//! One in-flight HTTP/3 request. Created when the request is enqueued on a
//! `ClientSession`; the lsquic stream is bound later from
//! `callbacks.onStreamOpen` (lsquic creates streams asynchronously once
//! MAX_STREAMS credit is available). Owned by the session's `pending` list
//! until `ClientSession.detach`.

const Stream = @This();

pub const new = trivialNew(@This());

session: *ClientSession,
client: ?*HTTPClient,
qstream: ?*quic.Stream = null,

/// Slices into the lsquic-owned hset buffer; valid only for the duration
/// of the `onStreamHeaders` callback that populated it. `cloneMetadata`
/// deep-copies synchronously inside that callback, so nothing reads these
/// after they go stale.
decoded_headers: std.ArrayListUnmanaged(picohttp.Header) = .empty,
body_buffer: std.ArrayListUnmanaged(u8) = .empty,
status_code: u16 = 0,

pending_body: []const u8 = "",
request_body_done: bool = false,
is_streaming_body: bool = false,
headers_delivered: bool = false,

pub fn deinit(this: *Stream) void {
    this.decoded_headers.deinit(home_rt.default_allocator);
    this.body_buffer.deinit(home_rt.default_allocator);
    _ = H3.live_streams.fetchSub(1, .monotonic);
    destroy(this);
}

pub fn abort(this: *Stream) void {
    if (this.qstream) |qs| closeQuicStream(qs);
}

/// Indirection so the `us_quic_stream_close` extern is only emitted as a
/// reachable symbol when the C runtime is linked (non-test builds). The
/// inline tests park `qstream` at null and never reach `abort`'s callee.
inline fn closeQuicStream(qs: *quic.Stream) void {
    if (@import("builtin").is_test) return;
    qs.close();
}

// ---------------------------------------------------------------------------
// Local stubs (off-list bun.X symbols)
// ---------------------------------------------------------------------------

/// Sibling `ClientSession.zig` is parked alongside `callbacks.zig` and
/// `encode.zig` (the lsquic-driven state machine). Opaque is enough for
/// the `session: *ClientSession` back-pointer to typecheck.
pub const ClientSession = opaque {};

/// Upstream `bun.http` (the HTTPClient struct) — opaque until the fetch()
/// state machine ports.
pub const HTTPClient = opaque {};

/// `bun.picohttp.Header` — trivial name+value byte-slice pair.
pub const picohttp = struct {
    pub const Header = struct {
        name: []const u8 = "",
        value: []const u8 = "",
    };
};

/// `../H3Client.zig` (module-level live-counts + retries) is parked. Only
/// the `live_streams` atomic is touched from this file; stub it here so
/// `fetchSub` resolves.
const H3 = struct {
    pub var live_streams: std.atomic.Value(u32) = .init(0);
};

/// `bun.TrivialNew` shim — allocates via `home_rt.default_allocator`.
fn trivialNew(comptime T: type) fn (T) *T {
    return struct {
        fn create(value: T) *T {
            const ptr = home_rt.default_allocator.create(T) catch
                @panic("OOM in Stream.new");
            ptr.* = value;
            return ptr;
        }
    }.create;
}

/// `bun.destroy` shim.
fn destroy(ptr: anytype) void {
    home_rt.default_allocator.destroy(ptr);
}

const quic = home_rt.uws_sys.quic;
const std = @import("std");
const home_rt = @import("home");

test "Stream defaults: no qstream, zero status, body not done" {
    const s: Stream = .{
        .session = undefined,
        .client = null,
    };
    try std.testing.expectEqual(@as(?*quic.Stream, null), s.qstream);
    try std.testing.expectEqual(@as(u16, 0), s.status_code);
    try std.testing.expect(!s.request_body_done);
    try std.testing.expect(!s.is_streaming_body);
    try std.testing.expect(!s.headers_delivered);
    try std.testing.expectEqual(@as(usize, 0), s.pending_body.len);
}

test "Stream.abort: no-op when qstream is null" {
    var s: Stream = .{
        .session = undefined,
        .client = null,
    };
    s.abort();
    try std.testing.expectEqual(@as(?*quic.Stream, null), s.qstream);
}

test "Stream.new + deinit round-trip" {
    const before = H3.live_streams.load(.monotonic);
    const s = Stream.new(.{
        .session = undefined,
        .client = null,
    });
    _ = H3.live_streams.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u16, 0), s.status_code);
    s.deinit();
    try std.testing.expectEqual(before, H3.live_streams.load(.monotonic));
}
