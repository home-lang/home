// Copied from bun/src/http/h3_client/Stream.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home").
//   - `bun.uws.quic` → `home_rt.uws_sys.quic` (the lsquic opaque types
//     already ported under uws_sys/quic/).
//   - `bun.http` (HTTPClient), `bun.picohttp`, and the sibling
//     `ClientSession` / `../H3Client.zig` are now real ports, so this file
//     keeps those identities shared with callbacks/encode/ClientSession.

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
const ClientSession = @import("./ClientSession.zig");
const H3 = @import("../H3Client.zig");
const HTTPClient = home_rt.http;
const picohttp = home_rt.picohttp;
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
