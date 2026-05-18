// Copied from bun/src/http/lshpack.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"); upstream
// `bun.mimalloc.mi_malloc` / `bun.mimalloc.mi_free` (mimalloc-backed alloc
// hooks passed to the C wrapper) are replaced with libc `malloc`/`free`
// until the mimalloc surface lands on home_rt. `bun.outOfMemory()` →
// inline OOM panic. The C wrapper symbol `lshpack_wrapper_*` lives in
// `packages/bun-usockets` / Bun's `src/jsc/bindings/c-bindings.cpp`; this
// file is the pure-Zig FFI surface and remains link-time-resolved.

const lshpack_header = extern struct {
    name: [*]const u8 = undefined,
    name_len: usize = 0,
    value: [*]const u8 = undefined,
    value_len: usize = 0,
    never_index: bool = false,
    hpack_index: u16 = 255,
};

/// wrapper implemented at src/jsc/bindings/c-bindings.cpp
pub const HPACK = extern struct {
    self: *anyopaque,

    pub const DecodeResult = struct {
        name: []const u8,
        value: []const u8,
        never_index: bool,
        well_know: u16,
        // offset of the next header position in src
        next: usize,
    };

    pub const LSHPACK_MAX_HEADER_SIZE: usize = 65536;

    pub fn init(max_capacity: u32) *HPACK {
        return lshpack_wrapper_init(c_malloc, c_free, max_capacity) orelse @panic("home_rt: out of memory");
    }

    /// DecodeResult name and value uses a thread_local shared buffer and should be copy/cloned before the next decode/encode call
    pub fn decode(self: *HPACK, src: []const u8) !DecodeResult {
        var header: lshpack_header = .{};
        const offset = lshpack_wrapper_decode(self, src.ptr, src.len, &header);
        if (offset == 0) return error.UnableToDecode;
        if (header.name_len == 0) return error.EmptyHeaderName;

        return .{
            .name = header.name[0..header.name_len],
            .value = header.value[0..header.value_len],
            .next = offset,
            .never_index = header.never_index,
            .well_know = header.hpack_index,
        };
    }

    /// encode name, value with never_index option into dst_buffer
    /// if name + value length is greater than LSHPACK_MAX_HEADER_SIZE this will return UnableToEncode
    pub fn encode(self: *HPACK, name: []const u8, value: []const u8, never_index: bool, dst_buffer: []u8, dst_buffer_offset: usize) !usize {
        const offset = lshpack_wrapper_encode(self, name.ptr, name.len, value.ptr, value.len, @intFromBool(never_index), dst_buffer.ptr, dst_buffer.len, dst_buffer_offset);
        if (offset <= 0) return error.UnableToEncode;
        return offset;
    }

    /// Adjust the encoder's dynamic-table capacity after init. Evicts entries
    /// to fit; the caller is responsible for emitting the RFC 7541 §6.3
    /// Dynamic Table Size Update opcode at the start of the next header block
    /// so the peer's decoder evicts in lockstep.
    pub fn setEncoderMaxCapacity(self: *HPACK, max_capacity: u32) void {
        lshpack_wrapper_enc_set_max_capacity(self, max_capacity);
    }

    pub fn deinit(self: *HPACK) void {
        lshpack_wrapper_deinit(self);
    }
};

const lshpack_wrapper_alloc = ?*const fn (size: usize) callconv(.c) ?*anyopaque;
const lshpack_wrapper_free = ?*const fn (ptr: ?*anyopaque) callconv(.c) void;
extern fn lshpack_wrapper_init(alloc: lshpack_wrapper_alloc, free: lshpack_wrapper_free, capacity: usize) ?*HPACK;
extern fn lshpack_wrapper_enc_set_max_capacity(self: *HPACK, max_capacity: c_uint) void;
extern fn lshpack_wrapper_deinit(self: *HPACK) void;
extern fn lshpack_wrapper_decode(self: *HPACK, src: [*]const u8, src_len: usize, output: *lshpack_header) usize;
extern fn lshpack_wrapper_encode(self: *HPACK, name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize, never_index: c_int, buffer: [*]u8, buffer_len: usize, buffer_offset: usize) usize;

// libc malloc/free shims — upstream Bun passes `bun.mimalloc.mi_malloc` /
// `mi_free`. Until home_rt exports a mimalloc namespace, fall back to libc.
extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
fn c_malloc(size: usize) callconv(.c) ?*anyopaque {
    return malloc(size);
}
fn c_free(ptr: ?*anyopaque) callconv(.c) void {
    free(ptr);
}

const home_rt = @import("home_rt");

test "lshpack.HPACK extern surface compiles" {
    // The lshpack_wrapper_* symbols are resolved at link time against the C
    // wrapper (src/jsc/bindings/c-bindings.cpp). We can't actually call
    // HPACK.init / .decode / .encode without that wrapper available, but we
    // can statically validate the type-level surface so the IR builds.
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 65536), HPACK.LSHPACK_MAX_HEADER_SIZE);
    try std.testing.expectEqual(@as(usize, @sizeOf(*anyopaque)), @sizeOf(HPACK));

    // The decode-result struct shape (consumed by the H2 frame parser) is
    // the documented one and stays stable.
    try std.testing.expect(@hasField(HPACK.DecodeResult, "name"));
    try std.testing.expect(@hasField(HPACK.DecodeResult, "value"));
    try std.testing.expect(@hasField(HPACK.DecodeResult, "never_index"));
    try std.testing.expect(@hasField(HPACK.DecodeResult, "well_know"));
    try std.testing.expect(@hasField(HPACK.DecodeResult, "next"));
}

test "lshpack.HPACK.DecodeResult shape is the documented one" {
    const std = @import("std");
    const r: HPACK.DecodeResult = .{
        .name = "x-hello",
        .value = "world",
        .never_index = false,
        .well_know = 17,
        .next = 42,
    };
    try std.testing.expectEqualStrings("x-hello", r.name);
    try std.testing.expectEqualStrings("world", r.value);
    try std.testing.expectEqual(@as(usize, 42), r.next);
    try std.testing.expectEqual(@as(u16, 17), r.well_know);
    try std.testing.expect(!r.never_index);
}
