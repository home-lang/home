// Copied from bun/src/http/h2_client/Stream.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home_rt"). The sibling
// `ClientSession` / `H2Client` modules and the `HTTPClient` / `picohttp.Header`
// types are not yet ported — local opaque/struct stubs stand in for the
// pointer-typed fields so callers can spell `*Stream`. The actual frame
// dispatch (which would dereference the stubs) re-lands alongside the full
// h2 client port in a later wave.

//! One in-flight request on a multiplexed HTTP/2 `ClientSession`. Owned by the
//! session's `streams` map; `client` is a weak back-pointer to the `HTTPClient`
//! that the request belongs to (cleared before any terminal callback so the
//! deliver loop never dereferences a freed client).

// `bun.TrivialNew` / `bun.destroy` aren't in home_rt yet; the helper below
// allocates from `home_rt.default_allocator` with the matching contract so
// the upstream call sites compile unchanged.
pub const new = trivialNew(@This());

id: u31,
session: *ClientSession,
client: ?*HTTPClient,

/// HEADERS + CONTINUATION fragments, decoded once END_HEADERS arrives.
header_block: std.ArrayListUnmanaged(u8) = .empty,
/// DATA payload accumulated across one onData() pass.
body_buffer: std.ArrayListUnmanaged(u8) = .empty,

/// HPACK is decoded eagerly at parse time so the dynamic table stays
/// consistent across multiple HEADERS in one read; the resulting strings
/// land here until `deliverStream` hands them to handleResponseMetadata.
decoded_bytes: std.ArrayListUnmanaged(u8) = .empty,
decoded_headers: std.ArrayListUnmanaged(picohttp.Header) = .empty,
/// Final (non-1xx) status code; 0 until the response HEADERS arrive.
status_code: u32 = 0,

state: State = .open,
/// `.closed` was reached via RST_STREAM (sent or received). Kept distinct
/// from `state` so `rst()` stays idempotent (never answers an inbound RST,
/// per §5.4.2) and so RST(NO_ERROR) can be told apart from a clean close.
rst_done: bool = false,
/// Set once a non-1xx HEADERS block has been decoded and is awaiting
/// delivery. Subsequent HEADERS are trailers and decoded-then-dropped.
headers_ready: bool = false,
headers_end_stream: bool = false,
/// Expect: 100-continue is in effect: hold the request body until a 1xx
/// or final status arrives.
awaiting_continue: bool = false,
fatal_error: ?anyerror = null,
/// DATA bytes consumed since the last WINDOW_UPDATE for this stream.
unacked_bytes: u32 = 0,
/// Σ DATA payload bytes (post-padding) for §8.1.1 Content-Length check —
/// `total_body_received` is clamped at content_length so it can't catch
/// overshoot.
data_bytes_received: u64 = 0,
/// Per-stream send window (server's INITIAL_WINDOW_SIZE plus any
/// WINDOW_UPDATEs minus DATA bytes already framed).
send_window: i32,
/// Unsent suffix of a `.bytes` request body, parked while the send
/// window is exhausted. Borrows from `client.state.request_body`.
pending_body: []const u8 = "",

/// RFC 9113 §5.1. A `Stream` is created by sending HEADERS, so it starts
/// `.open`; `idle`/`reserved` are never represented as objects. END_STREAM
/// half-closes one side; both, or any RST_STREAM, transitions to `.closed`.
pub const State = enum(u2) {
    open,
    /// We have written END_STREAM; no more DATA may be queued.
    half_closed_local,
    /// Peer has sent END_STREAM; further DATA is STREAM_CLOSED.
    half_closed_remote,
    closed,
};

pub fn deinit(this: *@This()) void {
    _ = H2.live_streams.fetchSub(1, .monotonic);
    this.header_block.deinit(home_rt.default_allocator);
    this.body_buffer.deinit(home_rt.default_allocator);
    this.decoded_bytes.deinit(home_rt.default_allocator);
    this.decoded_headers.deinit(home_rt.default_allocator);
    destroy(this);
}

pub fn rst(this: *@This(), code: wire.ErrorCode) void {
    if (this.rst_done or this.state == .closed) return;
    this.rst_done = true;
    this.state = .closed;
    var value: u32 = @byteSwap(@intFromEnum(code));
    this.session.writeFrame(.HTTP_FRAME_RST_STREAM, 0, this.id, std.mem.asBytes(&value));
}

pub fn sentEndStream(this: *@This()) void {
    this.state = switch (this.state) {
        .open => .half_closed_local,
        .half_closed_remote => .closed,
        else => this.state,
    };
}

pub fn recvEndStream(this: *@This()) void {
    this.state = switch (this.state) {
        .open => .half_closed_remote,
        .half_closed_local => .closed,
        else => this.state,
    };
}

/// We have sent END_STREAM (or RST): no more request DATA may be queued.
pub inline fn localClosed(this: *const @This()) bool {
    return this.state == .half_closed_local or this.state == .closed;
}

/// Peer has sent END_STREAM (or RST): the response body is complete and
/// further inbound DATA is a protocol error.
pub inline fn remoteClosed(this: *const @This()) bool {
    return this.state == .half_closed_remote or this.state == .closed;
}

// ---------------------------------------------------------------------------
// Local stubs (off-list bun.X symbols)
// ---------------------------------------------------------------------------

/// Sibling `ClientSession.zig` is parked alongside `dispatch.zig` /
/// `encode.zig` (the frame state machine that the full client needs).
/// An opaque stand-in lets `*ClientSession` typecheck; methods that route
/// through it (`writeFrame`) are only reachable from `rst()` callers that
/// have a real session in hand.
pub const ClientSession = opaque {
    pub fn writeFrame(
        _: *ClientSession,
        _: wire.FrameType,
        _: u8,
        _: u31,
        _: []const u8,
    ) void {}
};

/// Upstream `bun.http` (the HTTPClient struct) isn't ported yet — it's the
/// fetch() state machine + its connection lookup tables. Use an opaque
/// pointer so this file can spell `?*HTTPClient` for the weak back-ref.
pub const HTTPClient = opaque {};

/// `bun.picohttp.Header` is the trivial name+value byte-slice struct used
/// by picohttpparser for parsed response headers. Mirror its shape here
/// until the wider picohttp wrapper lands on `home_rt`.
pub const picohttp = struct {
    pub const Header = struct {
        name: []const u8 = "",
        value: []const u8 = "",
    };
};

/// `../H2Client.zig` (the module-level live-counts + tuning constants) is
/// also parked — only `live_streams` is touched from this file. Define a
/// minimal stub so `H2.live_streams.fetchSub` still compiles; the same
/// symbol will resolve through the home_rt re-export once H2Client lands.
const H2 = struct {
    pub var live_streams: std.atomic.Value(u32) = .init(0);
};

/// Shim for `bun.TrivialNew` — upstream's helper that returns a `fn(T)
/// *T` closure allocating from `bun.default_allocator`. The home_rt
/// substrate hasn't re-attached the smart-pointer helpers yet
/// (TaggedPointer family is parked); mirror the signature so call sites
/// (`Stream.new(.{...})`) typecheck unchanged.
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

/// Shim for `bun.destroy` — frees a heap pointer allocated via
/// `home_rt.default_allocator.create`.
fn destroy(ptr: anytype) void {
    home_rt.default_allocator.destroy(ptr);
}

const wire = home_rt.http.H2FrameParser;
const std = @import("std");
const home_rt = @import("home_rt");

test "Stream.State transitions: sentEndStream open -> half_closed_local" {
    var s: @This() = .{
        .id = 1,
        .session = undefined,
        .client = null,
        .send_window = 0,
    };
    try std.testing.expectEqual(State.open, s.state);
    s.sentEndStream();
    try std.testing.expectEqual(State.half_closed_local, s.state);
    try std.testing.expect(s.localClosed());
    try std.testing.expect(!s.remoteClosed());
}

test "Stream.State transitions: recvEndStream half_closed_local -> closed" {
    var s: @This() = .{
        .id = 1,
        .session = undefined,
        .client = null,
        .send_window = 0,
        .state = .half_closed_local,
    };
    s.recvEndStream();
    try std.testing.expectEqual(State.closed, s.state);
    try std.testing.expect(s.localClosed());
    try std.testing.expect(s.remoteClosed());
}

test "Stream.localClosed / remoteClosed match the state ladder" {
    var s: @This() = .{
        .id = 3,
        .session = undefined,
        .client = null,
        .send_window = 0,
    };
    try std.testing.expect(!s.localClosed());
    try std.testing.expect(!s.remoteClosed());

    s.state = .half_closed_remote;
    try std.testing.expect(!s.localClosed());
    try std.testing.expect(s.remoteClosed());

    s.state = .closed;
    try std.testing.expect(s.localClosed());
    try std.testing.expect(s.remoteClosed());
}

test "Stream defaults: open / no error / zeroed counters" {
    const s: @This() = .{
        .id = 7,
        .session = undefined,
        .client = null,
        .send_window = 65535,
    };
    try std.testing.expectEqual(State.open, s.state);
    try std.testing.expect(!s.rst_done);
    try std.testing.expect(!s.headers_ready);
    try std.testing.expect(!s.awaiting_continue);
    try std.testing.expectEqual(@as(?anyerror, null), s.fatal_error);
    try std.testing.expectEqual(@as(u32, 0), s.unacked_bytes);
    try std.testing.expectEqual(@as(u64, 0), s.data_bytes_received);
    try std.testing.expectEqual(@as(u32, 0), s.status_code);
    try std.testing.expectEqual(@as(usize, 0), s.pending_body.len);
}

test "Stream.new allocates and round-trips via destroy" {
    const s = @This().new(.{
        .id = 9,
        .session = undefined,
        .client = null,
        .send_window = 100,
    });
    try std.testing.expectEqual(@as(u31, 9), s.id);
    try std.testing.expectEqual(@as(i32, 100), s.send_window);
    destroy(s);
}
