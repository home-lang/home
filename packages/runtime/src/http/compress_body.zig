//! Request-body compression, ported from Bun 4982b91e3702094330f3be3883354c52b8c01323.
//! HTTP-thread-only. Shared output must be copied before yielding; the slow
//! paths write directly into the request's owned buffer.

const std = @import("std");
const bun = @import("home");
const zlib = bun.zlib;
const brotli = bun.brotli.c;
const zstd = bun.zstd.zstd;
const LibdeflateState = @import("HTTPThread.zig").LibdeflateState;

pub const CompressEncoding = enum {
    gzip,
    deflate,
    br,
    zstd,

    pub fn headerValue(this: @This()) []const u8 {
        return @tagName(this);
    }
};

pub const CompressOption = struct {
    encoding: CompressEncoding,
    level: ?i32 = null,
};

pub const default_deflate_level: i32 = 6;
pub const default_brotli_quality: i32 = 6;
pub const default_zstd_level: i32 = 3;

pub const CompressOutput = union(enum) {
    shared: usize,
    spilled,
};

pub fn compressInto(state: *LibdeflateState, input: []const u8, opt: CompressOption, spill: *std.ArrayListUnmanaged(u8)) !CompressOutput {
    spill.clearRetainingCapacity();
    switch (opt.encoding) {
        .gzip, .deflate => {
            const encoding: bun.libdeflate.Encoding = if (opt.encoding == .gzip) .gzip else .zlib;
            const cached = state.compressor();
            if (cached.maxBytesNeeded(input, encoding) <= state.shared_buffer.len) {
                const temporary = if (opt.level != null and opt.level.? != default_deflate_level)
                    bun.libdeflate.Compressor.alloc(opt.level.?) orelse bun.outOfMemory()
                else
                    null;
                defer if (temporary) |c| c.deinit();
                const written = (temporary orelse cached).compress(input, &state.shared_buffer, encoding).written;
                if (written == 0) return error.CompressionFailed;
                return .{ .shared = written };
            }
            try compressZlibStreaming(input, opt.encoding == .gzip, opt.level, spill);
            return .spilled;
        },
        .br => {
            const quality = opt.level orelse default_brotli_quality;
            const bound = brotli.BrotliEncoderMaxCompressedSize(input.len);
            if (bound != 0 and bound <= state.shared_buffer.len) {
                var written = state.shared_buffer.len;
                if (brotli.BrotliEncoderCompress(quality, brotli.BROTLI_DEFAULT_WINDOW, .generic, input.len, input.ptr, &written, &state.shared_buffer) != 0)
                    return .{ .shared = written };
            }
            const capacity = if (bound != 0) bound else std.math.add(usize, input.len, 1024) catch return error.CompressionFailed;
            try spill.resize(bun.default_allocator, capacity);
            var written = spill.items.len;
            if (brotli.BrotliEncoderCompress(quality, brotli.BROTLI_DEFAULT_WINDOW, .generic, input.len, input.ptr, &written, spill.items.ptr) == 0) {
                spill.clearRetainingCapacity();
                return error.CompressionFailed;
            }
            spill.items.len = written;
            return .spilled;
        },
        .zstd => {
            const bound = zstd.compressBound(input.len);
            if (zstd.c.ZSTD_isError(bound) != 0) return error.CompressionFailed;
            if (bound <= state.shared_buffer.len) {
                return switch (zstd.compress(&state.shared_buffer, input, opt.level)) {
                    .success => |n| .{ .shared = n },
                    .err => error.CompressionFailed,
                };
            }
            try spill.resize(bun.default_allocator, bound);
            switch (zstd.compress(spill.items, input, opt.level)) {
                .success => |n| spill.items.len = n,
                .err => {
                    spill.clearRetainingCapacity();
                    return error.CompressionFailed;
                },
            }
            return .spilled;
        },
    }
}

/// Feed at most u32::MAX input bytes at a time, and grow output in 64 KiB
/// increments rather than reserving the worst-case bound for a large body.
fn compressZlibStreaming(input: []const u8, gzip: bool, level: ?i32, out: *std.ArrayListUnmanaged(u8)) !void {
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    if (zlib.deflateInit2_(&stream, @min(level orelse default_deflate_level, 9), 8, if (gzip) 31 else 15, 8, 0, zlib.zlibVersion(), @sizeOf(zlib.z_stream)) != .Ok)
        return error.CompressionFailed;
    defer _ = zlib.deflateEnd(&stream);
    var remaining = input;
    while (true) {
        if (stream.avail_in == 0 and remaining.len > 0) {
            const n = @min(remaining.len, std.math.maxInt(u32));
            stream.next_in = remaining.ptr;
            stream.avail_in = @intCast(n);
            remaining = remaining[n..];
        }
        if (out.capacity == out.items.len) try out.ensureUnusedCapacity(bun.default_allocator, 64 * 1024);
        stream.next_out = out.items.ptr + out.items.len;
        stream.avail_out = @intCast(@min(out.capacity - out.items.len, std.math.maxInt(u32)));
        const before = stream.avail_out;
        const rc = zlib.deflate(&stream, if (remaining.len == 0) .Finish else .NoFlush);
        out.items.len += before - stream.avail_out;
        switch (rc) {
            .StreamEnd => return,
            .Ok => continue,
            else => {
                out.clearRetainingCapacity();
                return error.CompressionFailed;
            },
        }
    }
}

test "request compression round-trips shared and spilled bytes in all encodings" {
    const state = LibdeflateState.new(.{ .decompressor = bun.libdeflate.Decompressor.alloc() orelse return error.OutOfMemory });
    defer state.deinit();
    const input = try std.testing.allocator.alloc(u8, 600 * 1024);
    defer std.testing.allocator.free(input);
    const decoded = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(decoded);
    var spill: std.ArrayListUnmanaged(u8) = .empty;
    defer spill.deinit(bun.default_allocator);
    var random = std.Random.DefaultPrng.init(0x531);
    for ([_]bool{ false, true }) |incompressible| {
        if (incompressible) random.random().bytes(input) else @memset(input, 'a');
        for ([_]usize{ 512, input.len }) |length| {
            for ([_]CompressEncoding{ .gzip, .deflate, .br, .zstd }) |encoding| {
                const result = try compressInto(state, input[0..length], .{ .encoding = encoding }, &spill);
                try std.testing.expectEqual(length == 512, result == .shared);
                const bytes = switch (result) {
                    .shared => |n| state.shared_buffer[0..n],
                    .spilled => spill.items,
                };
                switch (encoding) {
                    .gzip, .deflate => {
                        const out = state.decompressor.decompress(bytes, decoded, if (encoding == .gzip) .gzip else .zlib);
                        try std.testing.expectEqual(bun.libdeflate.Status.success, out.status);
                        try std.testing.expectEqual(length, out.written);
                    },
                    .br => {
                        var n = decoded.len;
                        try std.testing.expectEqual(brotli.BrotliDecoderResult.success, brotli.BrotliDecoderDecompress(bytes.len, bytes.ptr, &n, decoded.ptr));
                        try std.testing.expectEqual(length, n);
                    },
                    .zstd => {
                        const out = zstd.decompress(decoded, bytes);
                        try std.testing.expect(out == .success);
                        try std.testing.expectEqual(length, out.success);
                    },
                }
                try std.testing.expectEqualSlices(u8, input[0..length], decoded[0..length]);
            }
        }
    }
}
