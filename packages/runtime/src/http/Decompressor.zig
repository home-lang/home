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
//   1. `@import("bun")` collapses to `@import("home_rt")`. `Brotli` /
//      `zstd` / `Zlib` resolve to `home_rt.brotli.brotli` /
//      `home_rt.zstd.zstd` / `home_rt.zlib.zlib`. The latter two
//      already exist; this file is the consumer that motivated the
//      brotli + zlib wrapper ports in this batch.
//   2. `bun.MutableString` is parked — the upstream type pulls in
//      `string.MutableString` (allocator-owned `ArrayListUnmanaged(u8)`
//      with a JSC writer/sourcemap surface). We use a local stub with
//      just the two fields this file reads (`list`, `allocator`); the
//      stub re-attaches to a real `home_rt.MutableString` once that
//      lands. Tests below verify the shape.
//   3. `bun.http.default_allocator` falls back to
//      `home_rt.default_allocator` (no separate http allocator yet).
//   4. `bun.assert` routes through `home_rt.assert`.

const Decompressor = @This();

pub const Variant = union(enum) {
    zlib: *Zlib.ZlibReaderArrayList,
    brotli: *Brotli.BrotliReaderArrayList,
    zstd: *zstd.ZstdReaderArrayList,
    none: void,
};

variant: Variant = .{ .none = {} },

/// Local stub for upstream `bun.MutableString`. Decompressor only reads
/// `.list` and `.allocator`; the upstream type adds JSC-visible writers,
/// owned-slice helpers, and a sourcemap-string overlay we don't need
/// here. Re-attaches when the real `home_rt.MutableString` lands.
pub const MutableStringStub = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8) = .empty,
};

pub fn deinit(this: *Decompressor) void {
    switch (this.variant) {
        inline .brotli, .zlib, .zstd => |that| {
            that.deinit();
            this.variant = .{ .none = {} };
        },
        .none => {},
    }
}

pub fn updateBuffers(this: *Decompressor, encoding: Encoding, buffer: []const u8, body_out_str: *MutableStringStub) !void {
    if (!encoding.isCompressed()) {
        return;
    }

    if (this.variant == .none) {
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
                this.variant = .{ .zlib = reader };
                return;
            },
            .brotli => {
                const reader = try Brotli.BrotliReaderArrayList.newWithOptions(
                    buffer,
                    &body_out_str.list,
                    body_out_str.allocator,
                    .{},
                );
                this.variant = .{ .brotli = reader };
                return;
            },
            .zstd => {
                const reader = try zstd.ZstdReaderArrayList.initWithListAllocator(
                    buffer,
                    &body_out_str.list,
                    body_out_str.allocator,
                    default_allocator,
                );
                this.variant = .{ .zstd = reader };
                return;
            },
            else => @panic("Invalid encoding. This code should not be reachable"),
        }
    }

    switch (this.variant) {
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
    switch (this.variant) {
        .zlib => |z| try z.readAll(is_done),
        .brotli => |b| try b.readAll(is_done),
        .zstd => |reader| try reader.readAll(is_done),
        .none => {},
    }
}

const std = @import("std");

const home_rt = @import("home_rt");
const default_allocator = home_rt.default_allocator;
const Zlib = @import("../zlib/zlib.zig");
const Brotli = @import("../brotli/brotli.zig");
const zstd = home_rt.zstd.zstd;
const Encoding = home_rt.http_types.Encoding;

test "Decompressor.none deinit is a no-op" {
    var d: Decompressor = .{};
    d.deinit();
    try std.testing.expect(d.variant == .none);
}

test "Decompressor.updateBuffers skips identity encoding" {
    var d: Decompressor = .{};
    defer d.deinit();
    var mut = MutableStringStub{ .allocator = std.testing.allocator };
    defer mut.list.deinit(std.testing.allocator);
    try d.updateBuffers(.identity, "", &mut);
    try std.testing.expect(d.variant == .none);
}

test "Decompressor.readAll on none is a no-op" {
    var d: Decompressor = .{};
    try d.readAll(true);
}
