//! Checked borrowed-raster PNG/BMP/TIFF encoders, adapted from Home's format
//! encoders. Rows may be padded; no image object or full RGB copy is required.
const std = @import("std");
const Deflater = @import("zlib_stream.zig").Deflater;
pub const Format = enum {
    gray,
    rgb,
    rgba,
    pub fn channels(self: Format) usize {
        return switch (self) {
            .gray => 1,
            .rgb => 3,
            .rgba => 4,
        };
    }
};
pub const View = struct {
    data: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: Format = .rgb,
    bits: u8 = 8,
    endian: std.builtin.Endian = .little,

    pub fn validate(self: View) !usize {
        if (self.width == 0 or self.height == 0 or self.width > std.math.maxInt(i32) or self.height > std.math.maxInt(i32) or (self.bits != 8 and self.bits != 16)) return error.InvalidGeometry;
        const bytes = std.math.mul(usize, self.format.channels(), self.bits / 8) catch return error.InvalidGeometry;
        const row_bytes = std.math.mul(usize, self.width, bytes) catch return error.InvalidGeometry;
        if (self.stride < row_bytes) return error.InvalidGeometry;
        const last = std.math.mul(usize, self.height - 1, self.stride) catch return error.InvalidGeometry;
        const needed = std.math.add(usize, last, row_bytes) catch return error.InvalidGeometry;
        if (self.data.len < needed) return error.BufferTooSmall;
        return row_bytes;
    }
    fn row(self: View, y: usize, row_bytes: usize) []const u8 {
        return self.data[y * self.stride ..][0..row_bytes];
    }
};
pub const Filter = enum(u32) { adaptive, none, sub, up, average, paeth };
pub const PngOptions = struct { compression: u32 = 1, filter: Filter = .adaptive };
/// Home Image's interleaved 16-bit samples use little-endian storage. Indexed
/// palettes require expansion by the caller; no palette or pixel owner is kept.
pub fn fromImage(img: anytype) !View {
    const format: Format = switch (img.format) {
        .grayscale8, .grayscale16 => .gray,
        .rgb8, .rgb16 => .rgb,
        .rgba8, .rgba16 => .rgba,
        else => return error.UnsupportedFormat,
    };
    const bits: u8 = switch (img.format) {
        .grayscale16, .rgb16, .rgba16 => 16,
        else => 8,
    };
    const view = View{ .data = img.pixels, .width = img.width, .height = img.height, .stride = try mul(img.width, format.channels() * (bits / 8)), .format = format, .bits = bits };
    _ = try view.validate();
    return view;
}

/// Writes one complete zlib image stream to a synchronous sink. Scratch space is
/// two scanlines plus the bounded Deflater owner, independent of image height.
/// The sink receives compressed bytes only; callers supply IDAT/fdAT framing.
pub fn writePngData(allocator: std.mem.Allocator, view: View, options: PngOptions, sink: anytype) !void {
    const row_bytes = try view.validate();
    try checkPngOptions(options);
    const size = std.math.add(usize, row_bytes, 1) catch return error.InvalidGeometry;
    var best = try allocator.alloc(u8, size);
    defer allocator.free(best);
    var candidate = try allocator.alloc(u8, size);
    defer allocator.free(candidate);
    const compressor = try Deflater.create(allocator, options.compression);
    defer compressor.deinit();
    for (0..view.height) |y| {
        if (options.filter == .adaptive) {
            var score = filtered(view, y, row_bytes, 0, best);
            for (1..5) |kind| {
                const next = filtered(view, y, row_bytes, @intCast(kind), candidate);
                if (next < score) {
                    score = next;
                    std.mem.swap([]u8, &best, &candidate);
                }
            }
        } else _ = filtered(view, y, row_bytes, @intCast(@intFromEnum(options.filter) - 1), best);
        try compressor.write(best, sink);
    }
    try compressor.finish(sink);
}
pub fn checkPngOptions(options: PngOptions) !void {
    if (options.compression > 9) return error.InvalidCompressionLevel;
}
/// Writes the signature and IHDR for a validated, noninterlaced raster.
pub fn writePngHeader(sink: anytype, view: View) !void {
    _ = try view.validate();
    try sink.writeAll(&.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], view.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], view.height, .big);
    ihdr[8] = view.bits;
    ihdr[9] = switch (view.format) {
        .gray => 0,
        .rgb => 2,
        .rgba => 6,
    };
    try writePngChunk(sink, "IHDR", &.{&ihdr});
}
/// Parts are borrowed only for this call. Splitting an fdAT sequence prefix from
/// compressor output avoids a second allocation/copy of the compressed chunk.
pub fn writePngChunk(sink: anytype, kind: *const [4]u8, parts: []const []const u8) !void {
    var size: usize = 0;
    for (parts) |part| size = std.math.add(usize, size, part.len) catch return error.InvalidGeometry;
    if (size > std.math.maxInt(u31)) return error.InvalidGeometry;
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, @intCast(size), .big);
    try sink.writeAll(&number);
    try sink.writeAll(kind);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    for (parts) |part| {
        crc.update(part);
        try sink.writeAll(part);
    }
    std.mem.writeInt(u32, &number, crc.final(), .big);
    try sink.writeAll(&number);
}
const ArraySink = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    pub fn writeAll(self: *ArraySink, bytes: []const u8) !void {
        try self.output.appendSlice(self.allocator, bytes);
    }
};
pub fn png(allocator: std.mem.Allocator, view: View, options: PngOptions) ![]u8 {
    _ = try view.validate();
    try checkPngOptions(options);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var sink = ArraySink{ .allocator = allocator, .output = &output };
    try writePngHeader(&sink, view);
    var compressed = PngSink{ .sink = &sink };
    try writePngData(allocator, view, options, &compressed);
    try writePngChunk(&sink, "IEND", &.{});
    return output.toOwnedSlice(allocator);
}
const PngSink = struct {
    sink: *ArraySink,
    pub fn writeAll(self: *PngSink, bytes: []const u8) !void {
        if (bytes.len != 0) try writePngChunk(self.sink, "IDAT", &.{bytes});
    }
};
fn pngByte(view: View, row: []const u8, index: usize) u8 {
    return row[if (view.bits == 16 and view.endian == .little) index ^ 1 else index];
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const da = @abs(p - a);
    const db = @abs(p - b);
    const dc = @abs(p - c);
    return if (da <= db and da <= dc) a else if (db <= dc) b else c;
}
fn filtered(view: View, y: usize, row_bytes: usize, kind: u8, output: []u8) u64 {
    const current = view.row(y, row_bytes);
    const previous = if (y != 0) view.row(y - 1, row_bytes) else null;
    const bpp = view.format.channels() * (view.bits / 8);
    output[0] = kind;
    var score: u64 = 0;
    for (0..row_bytes) |i| {
        const a = if (i >= bpp) pngByte(view, current, i - bpp) else 0;
        const b = if (previous) |row| pngByte(view, row, i) else 0;
        const c = if (previous) |row| (if (i >= bpp) pngByte(view, row, i - bpp) else 0) else 0;
        const prediction: u8 = switch (kind) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => paeth(a, b, c),
            else => unreachable,
        };
        const value = pngByte(view, current, i) -% prediction;
        output[i + 1] = value;
        score += @min(@as(u16, value), 256 - @as(u16, value));
    }
    return score;
}
fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}
fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidGeometry;
}
fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.InvalidGeometry;
}
fn sample8(view: View, row: []const u8, sample: usize) u8 {
    return row[sample * (view.bits / 8) + @as(usize, if (view.bits == 16 and view.endian == .little) 1 else 0)];
}

pub fn bmp(allocator: std.mem.Allocator, view: View) ![]u8 {
    const row_bytes = try view.validate();
    const channels = view.format.channels();
    const header: usize = if (view.format == .rgba) 108 else 40;
    const palette: usize = if (view.format == .gray) 1024 else 0;
    const offset = 14 + header + palette;
    const stride = (try add(try mul(view.width, channels), 3)) & ~@as(usize, 3);
    const pixels = try mul(stride, view.height);
    const total = try add(offset, pixels);
    if (total > std.math.maxInt(u32)) return error.InvalidGeometry;
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..2], "BM");
    put32(out, 2, @intCast(total));
    put32(out, 10, @intCast(offset));
    put32(out, 14, @intCast(header));
    put32(out, 18, view.width);
    put32(out, 22, view.height);
    put16(out, 26, 1);
    put16(out, 28, @intCast(channels * 8));
    put32(out, 34, @intCast(pixels));
    put32(out, 38, 2835);
    put32(out, 42, 2835);
    if (view.format == .gray) {
        put32(out, 46, 256);
        for (0..256) |i| @memset(out[54 + i * 4 ..][0..3], @intCast(i));
    } else if (view.format == .rgba) {
        put32(out, 30, 3); // BI_BITFIELDS and V4 masks preserve unassociated alpha.
        put32(out, 54, 0x00ff0000);
        put32(out, 58, 0x0000ff00);
        put32(out, 62, 0x000000ff);
        put32(out, 66, 0xff000000);
        put32(out, 70, 0x73524742); // LCS_sRGB
    }
    for (0..view.height) |y| {
        const src = view.row(y, row_bytes);
        const dest = out[offset + (@as(usize, view.height) - 1 - y) * stride ..][0..stride];
        for (0..view.width) |x| {
            if (view.format == .gray) dest[x] = sample8(view, src, x) else {
                dest[x * channels] = sample8(view, src, x * channels + 2);
                dest[x * channels + 1] = sample8(view, src, x * channels + 1);
                dest[x * channels + 2] = sample8(view, src, x * channels);
                if (channels == 4) dest[x * channels + 3] = sample8(view, src, x * channels + 3);
            }
        }
    }
    return out;
}

fn entry(out: []u8, index: *usize, tag: u16, kind: u16, count: u32, value: u32) void {
    const pos = 10 + index.* * 12;
    put16(out, pos, tag);
    put16(out, pos + 2, kind);
    put32(out, pos + 4, count);
    put32(out, pos + 8, value);
    index.* += 1;
}
pub fn tiff(allocator: std.mem.Allocator, view: View) ![]u8 {
    const row_bytes = try view.validate();
    const channels = view.format.channels();
    const count: u16 = if (view.format == .rgba) 15 else 14;
    const bits_offset: usize = 8 + 2 + @as(usize, count) * 12 + 4;
    const resolution = (bits_offset + (if (channels > 1) channels * 2 else 0) + 3) & ~@as(usize, 3);
    const offset = resolution + 16;
    const pixels = try mul(row_bytes, view.height);
    const total = try add(offset, pixels);
    if (total > std.math.maxInt(u32)) return error.InvalidGeometry;
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..2], "II");
    put16(out, 2, 42);
    put32(out, 4, 8);
    put16(out, 8, count);
    var i: usize = 0;
    entry(out, &i, 256, 4, 1, view.width);
    entry(out, &i, 257, 4, 1, view.height);
    entry(out, &i, 258, 3, @intCast(channels), if (channels == 1) view.bits else @intCast(bits_offset));
    entry(out, &i, 259, 3, 1, 1);
    entry(out, &i, 262, 3, 1, if (view.format == .gray) 1 else 2);
    entry(out, &i, 273, 4, 1, @intCast(offset));
    entry(out, &i, 274, 3, 1, 1);
    entry(out, &i, 277, 3, 1, @intCast(channels));
    entry(out, &i, 278, 4, 1, view.height);
    entry(out, &i, 279, 4, 1, @intCast(pixels));
    entry(out, &i, 282, 5, 1, @intCast(resolution));
    entry(out, &i, 283, 5, 1, @intCast(resolution + 8));
    entry(out, &i, 284, 3, 1, 1);
    entry(out, &i, 296, 3, 1, 2);
    if (view.format == .rgba) entry(out, &i, 338, 3, 1, 2);
    std.debug.assert(i == count);
    if (channels > 1) for (0..channels) |component| put16(out, bits_offset + component * 2, view.bits);
    put32(out, resolution, 72);
    put32(out, resolution + 4, 1);
    put32(out, resolution + 8, 72);
    put32(out, resolution + 12, 1);
    for (0..view.height) |y| {
        const src = view.row(y, row_bytes);
        const dest = out[offset + y * row_bytes ..][0..row_bytes];
        if (view.bits == 16 and view.endian == .big) {
            for (0..row_bytes / 2) |sample| {
                dest[sample * 2] = src[sample * 2 + 1];
                dest[sample * 2 + 1] = src[sample * 2];
            }
        } else @memcpy(dest, src);
    }
    return out;
}

test "raster validation rejects truncation, invalid depths and overflow before allocation" {
    const base = View{ .data = &.{ 1, 2, 3, 4, 5, 6, 99, 99, 7, 8, 9, 10, 11, 12 }, .width = 2, .height = 2, .stride = 8 };
    try std.testing.expectEqual(@as(usize, 6), try base.validate());
    var invalid = base;
    invalid.stride = 5;
    try std.testing.expectError(error.InvalidGeometry, png(std.testing.failing_allocator, invalid, .{}));
    invalid = base;
    invalid.data = base.data[0..13];
    try std.testing.expectError(error.BufferTooSmall, bmp(std.testing.failing_allocator, invalid));
    invalid = base;
    invalid.stride = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidGeometry, tiff(std.testing.failing_allocator, invalid));
    invalid = base;
    invalid.bits = 12;
    try std.testing.expectError(error.InvalidGeometry, tiff(std.testing.failing_allocator, invalid));
    try std.testing.expectError(error.InvalidCompressionLevel, png(std.testing.failing_allocator, base, .{ .compression = 10 }));
}
test "TIFF and BMP preserve padded RGB rows with correct tags and byte order" {
    const view = View{ .data = &.{ 1, 2, 3, 4, 5, 6, 99, 99, 7, 8, 9, 10, 11, 12 }, .width = 2, .height = 2, .stride = 8 };
    const a = std.testing.allocator;
    const bm = try bmp(a, view);
    defer a.free(bm);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 12, 11, 10, 0, 0, 3, 2, 1, 6, 5, 4, 0, 0 }, bm[54..]);
    const tif = try tiff(a, view);
    defer a.free(tif);
    const offset = std.mem.readInt(u32, tif[10 + 5 * 12 + 8 ..][0..4], .little);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, tif[offset..]);
    const bits_at = std.mem.readInt(u32, tif[10 + 2 * 12 + 8 ..][0..4], .little);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 8, 0, 8, 0 }, tif[bits_at..][0..6]);
}
test "sixteen-bit TIFF preserves samples and BMP explicitly reduces to high bytes" {
    const view = View{ .data = &.{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 }, .width = 1, .height = 1, .stride = 8, .format = .rgba, .bits = 16, .endian = .big };
    const a = std.testing.allocator;
    const tif = try tiff(a, view);
    defer a.free(tif);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde }, tif[tif.len - 8 ..]);
    const bm = try bmp(a, view);
    defer a.free(bm);
    try std.testing.expectEqualSlices(u8, &.{ 0x9a, 0x56, 0x12, 0xde }, bm[122..]);
}
test "PNG chunks have valid CRCs, streaming zlib and big-endian sixteen-bit samples" {
    const a = std.testing.allocator;
    const view = View{ .data = &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 99, 99, 0xf0, 0xde, 0x22, 0x11, 0x44, 0x33 }, .width = 1, .height = 2, .stride = 8, .bits = 16 };
    for ([_]u32{ 0, 1, 6, 9 }) |level| {
        const bytes = try png(a, view, .{ .compression = level, .filter = .none });
        defer a.free(bytes);
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(a);
        var at: usize = 8;
        var ended = false;
        while (at < bytes.len) {
            const n = std.mem.readInt(u32, bytes[at..][0..4], .big);
            const body = bytes[at + 4 ..][0 .. 4 + n];
            try std.testing.expectEqual(std.hash.Crc32.hash(body), std.mem.readInt(u32, bytes[at + 8 + n ..][0..4], .big));
            if (std.mem.eql(u8, body[0..4], "IDAT")) try compressed.appendSlice(a, body[4..]);
            if (std.mem.eql(u8, body[0..4], "IEND")) ended = true;
            at += n + 12;
        }
        try std.testing.expect(ended);
        var reader: std.Io.Reader = .fixed(compressed.items);
        var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
        var decoded: std.Io.Writer.Allocating = .init(a);
        defer decoded.deinit();
        _ = try inflate.reader.streamRemaining(&decoded.writer);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44 }, decoded.written());
    }
}
fn allocationCase(a: std.mem.Allocator) !void {
    const view = View{ .data = &.{ 1, 2, 3, 4, 5, 6 }, .width = 1, .height = 2, .stride = 3 };
    const p = try png(a, view, .{});
    defer a.free(p);
    const b = try bmp(a, view);
    defer a.free(b);
    const t = try tiff(a, view);
    defer a.free(t);
}
test "allocation failures unwind every encoder without publishing partial data" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
