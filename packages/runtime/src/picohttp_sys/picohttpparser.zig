// Copied verbatim from bun/src/picohttp_sys/picohttpparser.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Pure FFI extern declarations for the vendored picohttpparser C library.
// `phr_*` extern symbols stay verbatim — they are the C ABI surface the
// linked `libpicohttpparser.a` exposes and must not be renamed.

// TODO: use translate-c for this
pub const struct_phr_header = extern struct {
    name: [*c]const u8,
    name_len: usize,
    value: [*c]const u8,
    value_len: usize,
};
pub extern fn phr_parse_request(buf: [*c]const u8, len: usize, method: [*c][*c]const u8, method_len: [*c]usize, path: [*c][*c]const u8, path_len: [*c]usize, minor_version: [*c]c_int, headers: [*c]struct_phr_header, num_headers: [*c]usize, last_len: usize) c_int;
pub extern fn phr_parse_response(_buf: [*c]const u8, len: usize, minor_version: [*c]c_int, status: [*c]c_int, msg: [*c][*c]const u8, msg_len: [*c]usize, headers: [*c]struct_phr_header, num_headers: [*c]usize, last_len: usize) c_int;
pub extern fn phr_parse_headers(buf: [*c]const u8, len: usize, headers: [*c]struct_phr_header, num_headers: [*c]usize, last_len: usize) c_int;
pub const struct_phr_chunked_decoder = extern struct {
    bytes_left_in_chunk: usize = 0,
    consume_trailer: u8 = 0,
    _hex_count: u8 = 0,
    _state: ChunkedEncodingState = .CHUNKED_IN_CHUNK_SIZE,
};
pub extern fn phr_decode_chunked(decoder: *struct_phr_chunked_decoder, buf: [*]u8, bufsz: *usize) isize;
pub extern fn phr_decode_chunked_is_in_data(decoder: *struct_phr_chunked_decoder) c_int;
pub const phr_header = struct_phr_header;
pub const phr_chunked_decoder = struct_phr_chunked_decoder;

pub const ChunkedEncodingState = enum(u8) {
    CHUNKED_IN_CHUNK_SIZE = 0,
    CHUNKED_IN_CHUNK_EXT = 1,
    CHUNKED_IN_CHUNK_DATA = 2,
    CHUNKED_IN_CHUNK_CRLF = 3,
    CHUNKED_IN_TRAILERS_LINE_HEAD = 4,
    CHUNKED_IN_TRAILERS_LINE_MIDDLE = 5,
    _,
};

test "phr extern symbols have well-formed type signatures" {
    const std = @import("std");
    // Pure FFI: verify each extern fn type is well-formed and the layout of
    // the C-shared structs matches the picohttpparser headers.
    _ = @typeName(@TypeOf(phr_parse_request));
    _ = @typeName(@TypeOf(phr_parse_response));
    _ = @typeName(@TypeOf(phr_parse_headers));
    _ = @typeName(@TypeOf(phr_decode_chunked));
    _ = @typeName(@TypeOf(phr_decode_chunked_is_in_data));

    try std.testing.expectEqual(@sizeOf(struct_phr_header), @sizeOf([*c]const u8) * 2 + @sizeOf(usize) * 2);
    try std.testing.expect(@alignOf(struct_phr_chunked_decoder) >= 1);

    const decoder: struct_phr_chunked_decoder = .{};
    try std.testing.expectEqual(@as(usize, 0), decoder.bytes_left_in_chunk);
    try std.testing.expectEqual(ChunkedEncodingState.CHUNKED_IN_CHUNK_SIZE, decoder._state);
}

test "ChunkedEncodingState tag values stable" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ChunkedEncodingState.CHUNKED_IN_CHUNK_SIZE));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(ChunkedEncodingState.CHUNKED_IN_TRAILERS_LINE_MIDDLE));
}
