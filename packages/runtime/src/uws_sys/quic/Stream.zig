// Copied from bun/src/uws_sys/quic/Stream.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: `uws.quic.{Header, Socket}` upstream — we resolve
// these via sibling files since the broader `uws` aggregator isn't
// ported yet.

//! `us_quic_stream_t` — one bidirectional HTTP/3 request stream. Valid
//! until its `on_stream_close` callback returns.

pub const Stream = opaque {
    extern fn us_quic_stream_socket(s: *Stream) ?*Socket;
    pub const socket = us_quic_stream_socket;

    extern fn us_quic_stream_shutdown(s: *Stream) void;
    pub const shutdown = us_quic_stream_shutdown;

    extern fn us_quic_stream_close(s: *Stream) void;
    pub const close = us_quic_stream_close;

    extern fn us_quic_stream_reset(s: *Stream) void;
    pub const reset = us_quic_stream_reset;

    extern fn us_quic_stream_header_count(s: *Stream) c_uint;
    pub const headerCount = us_quic_stream_header_count;

    extern fn us_quic_stream_header(s: *Stream, i: c_uint) ?*const Header;
    pub const header = us_quic_stream_header;

    extern fn us_quic_stream_ext(s: *Stream) *anyopaque;
    pub fn ext(s: *Stream, comptime T: type) *?*T {
        return @ptrCast(@alignCast(us_quic_stream_ext(s)));
    }

    extern fn us_quic_stream_write(s: *Stream, data: [*]const u8, len: c_uint) c_int;
    pub fn write(s: *Stream, data: []const u8) c_int {
        return us_quic_stream_write(s, data.ptr, @intCast(data.len));
    }

    extern fn us_quic_stream_want_write(s: *Stream, want: c_int) void;
    pub fn wantWrite(s: *Stream, want: bool) void {
        us_quic_stream_want_write(s, @intFromBool(want));
    }

    extern fn us_quic_stream_send_headers(s: *Stream, h: [*]const Header, n: c_uint, end_stream: c_int) c_int;
    pub fn sendHeaders(s: *Stream, headers: []const Header, end_stream: bool) c_int {
        return us_quic_stream_send_headers(s, headers.ptr, @intCast(headers.len), @intFromBool(end_stream));
    }
};

const Header = @import("./Header.zig").Header;
const Socket = @import("./Socket.zig").Socket;
