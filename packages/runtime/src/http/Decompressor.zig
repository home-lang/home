// Copied from bun/src/http/Decompressor.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Tagged union over the three decompression backends an HTTP response
// body can use (gzip/deflate via zlib, br via brotli, zstd). The
// underlying `*ReaderArrayList` lifetimes are owned by this union; the
// `body_out_str: *MutableString` argument is shared back-pressure on
// the ArrayList the reader populates.
//
// Rewrites versus upstream:
//   1. `@import("bun")` collapses to `@import("home")`. `Brotli` /
//      `zstd` / `Zlib` resolve to `home_rt.brotli.brotli` /
//      `home_rt.zstd.zstd` / `home_rt.zlib.zlib`.
//   2. `bun.http.default_allocator` falls back to
//      `home_rt.default_allocator` (no separate http allocator yet).
//   3. `bun.assert` routes through `home_rt.assert`.

pub const Decompressor = union(enum) {
    zlib: *Zlib.ZlibReaderArrayList,
    brotli: *Brotli.BrotliReaderArrayList,
    zstd: *zstd.ZstdReaderArrayList,
    none: void,

    pub fn deinit(this: *Decompressor) void {
        switch (this.*) {
            inline .brotli, .zlib, .zstd => |that| {
                // Robustness guard: an all-zero Decompressor reads as the first
                // union tag (`.zlib`) with a null reader pointer. That happens
                // when a not-yet-initialized HTTPClient's `state` (which lives in
                // `undefined` memory until init) is torn down on the HTTP Client
                // thread — a release-only, timing-flaky crash on the in-process
                // serve+fetch path. A live reader is never null, so skipping the
                // deinit here only affects the uninitialized/zeroed case.
                if (@intFromPtr(that) != 0) that.deinit();
                this.* = .{ .none = {} };
            },
            .none => {},
        }
    }

    pub fn updateBuffers(this: *Decompressor, encoding: Encoding, buffer: []const u8, body_out_str: *MutableString) !void {
        if (!encoding.isCompressed()) {
            return;
        }

        if (this.* == .none) {
            switch (encoding) {
                .gzip, .deflate => {
                    const reader = try Zlib.ZlibReaderArrayList.initWithOptionsAndListAllocator(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        default_allocator,
                        .{
                            // zlib.MAX_WBITS = 15
                            // to (de-)compress deflate format, use wbits = -zlib.MAX_WBITS
                            // to (de-)compress deflate format with headers we use wbits = 0 (we can detect the first byte using 120)
                            // to (de-)compress gzip format, use wbits = zlib.MAX_WBITS | 16
                            .windowBits = if (encoding == Encoding.gzip) Zlib.MAX_WBITS | 16 else (if (buffer.len > 1 and buffer[0] == 120) 0 else -Zlib.MAX_WBITS),
                        },
                    );
                    this.* = .{ .zlib = reader };
                    return;
                },
                .brotli => {
                    const reader = try Brotli.BrotliReaderArrayList.newWithOptions(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        .{},
                    );
                    this.* = .{ .brotli = reader };
                    return;
                },
                .zstd => {
                    const reader = try zstd.ZstdReaderArrayList.initWithListAllocator(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        default_allocator,
                    );
                    this.* = .{ .zstd = reader };
                    return;
                },
                else => @panic("Invalid encoding. This code should not be reachable"),
            }
        }

        switch (this.*) {
            .zlib => |reader| {
                home_rt.assert(reader.zlib.avail_in == 0);
                reader.zlib.next_in = buffer.ptr;
                reader.zlib.avail_in = @as(u32, @truncate(buffer.len));

                const initial = body_out_str.list.items.len;
                body_out_str.list.expandToCapacity();
                if (body_out_str.list.capacity == initial) {
                    try body_out_str.list.ensureUnusedCapacity(body_out_str.allocator, 4096);
                    body_out_str.list.expandToCapacity();
                }
                reader.list = body_out_str.list;
                reader.zlib.next_out = @ptrCast(&body_out_str.list.items[initial]);
                reader.zlib.avail_out = @as(u32, @truncate(body_out_str.list.capacity - initial));
                // we reset the total out so we can track how much we decompressed this time
                reader.zlib.total_out = @truncate(initial);
            },
            .brotli => |reader| {
                reader.input = buffer;
                reader.total_in = 0;

                const initial = body_out_str.list.items.len;
                reader.list = body_out_str.list;
                reader.total_out = @truncate(initial);
            },
            .zstd => |reader| {
                reader.input = buffer;
                reader.total_in = 0;

                const initial = body_out_str.list.items.len;
                reader.list = body_out_str.list;
                reader.total_out = @truncate(initial);
            },
            else => @panic("Invalid encoding. This code should not be reachable"),
        }
    }

    pub fn readAll(this: *Decompressor, is_done: bool) !void {
        switch (this.*) {
            .zlib => |z| try z.readAll(is_done),
            .brotli => |b| try b.readAll(is_done),
            .zstd => |reader| try reader.readAll(is_done),
            .none => {},
        }
    }
};

const std = @import("std");

const home_rt = @import("home");
const default_allocator = home_rt.default_allocator;
const Zlib = @import("../zlib/zlib.zig");
const Brotli = @import("../brotli/brotli.zig");
const zstd = home_rt.zstd.zstd;
const MutableString = home_rt.MutableString;
const Encoding = home_rt.http_types.Encoding;

test "Decompressor.none deinit is a no-op" {
    var d: Decompressor = .{ .none = {} };
    d.deinit();
    try std.testing.expect(d == .none);
}

test "Decompressor.updateBuffers skips identity encoding" {
    var d: Decompressor = .{ .none = {} };
    defer d.deinit();
    var mut = MutableString{ .allocator = std.testing.allocator, .list = .empty };
    defer mut.list.deinit(std.testing.allocator);
    try d.updateBuffers(.identity, "", &mut);
    try std.testing.expect(d == .none);
}

test "Decompressor.readAll on none is a no-op" {
    var d: Decompressor = .{ .none = {} };
    try d.readAll(true);
}
