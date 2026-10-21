//! Owned ICC embedding into existing RGB JPEG/PNG/classic TIFF containers.
//! Sample/scan/strip bytes are preserved; this is not a pixel color transform.
const std = @import("std");
const layout = @import("metadata/icc_layout.zig");
const zlib = @import("formats/zlib_stream.zig");
pub const Format = enum { jpeg, png, tiff };
const List = std.ArrayList(u8);
pub fn embed(allocator: std.mem.Allocator, format: Format, image: []const u8, profile: []const u8) ![]u8 {
    _ = try layout.validateRgb(profile);
    var out: List = .empty;
    errdefer out.deinit(allocator);
    switch (format) {
        .jpeg => try jpeg(allocator, &out, image, profile),
        .png => try png(allocator, &out, image, profile),
        .tiff => try tiff(allocator, &out, image, profile),
    }
    return out.toOwnedSlice(allocator);
}
fn number(allocator: std.mem.Allocator, out: *List, comptime T: type, value: T, endian: std.builtin.Endian) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, endian);
    try out.appendSlice(allocator, &bytes);
}
const jpeg_part = 65519;
fn jpegProfile(allocator: std.mem.Allocator, out: *List, profile: []const u8) !void {
    const count = (profile.len + jpeg_part - 1) / jpeg_part;
    if (count > 255) return error.MetadataTooLarge;
    for (0..count) |i| {
        const bytes = profile[i * jpeg_part .. @min(profile.len, (i + 1) * jpeg_part)];
        try out.appendSlice(allocator, "\xff\xe2");
        try number(allocator, out, u16, @intCast(bytes.len + 16), .big);
        try out.appendSlice(allocator, "ICC_PROFILE\x00");
        try out.append(allocator, @intCast(i + 1));
        try out.append(allocator, @intCast(count));
        try out.appendSlice(allocator, bytes);
    }
}
fn jpeg(allocator: std.mem.Allocator, out: *List, image: []const u8, profile: []const u8) !void {
    if (image.len < 4 or !std.mem.eql(u8, image[0..2], "\xff\xd8") or !std.mem.eql(u8, image[image.len - 2 ..], "\xff\xd9")) return error.InvalidImage;
    try out.appendSlice(allocator, image[0..2]);
    var at: usize = 2;
    var inserted = false;
    var frame = false;
    while (at < image.len) {
        const start = at;
        if (image[at] != 255) return error.InvalidImage;
        while (at < image.len and image[at] == 255) : (at += 1) {}
        if (at == image.len) return error.InvalidImage;
        const marker = image[at];
        at += 1;
        if (marker == 0 or marker == 0xd8 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) return error.InvalidImage;
        if (!inserted and marker != 0xe0) {
            try jpegProfile(allocator, out, profile);
            inserted = true;
        }
        if (marker == 0xd9) return error.InvalidImage; // A scan is required.
        if (image.len - at < 2) return error.InvalidImage;
        const size: usize = std.mem.readInt(u16, image[at..][0..2], .big);
        if (size < 2 or size > image.len - at) return error.InvalidImage;
        const payload = image[at + 2 .. at + size];
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            if (payload.len < 6 or payload[5] != 3) return error.UnsupportedFormat;
            if (payload.len != 15) return error.InvalidImage;
            frame = true;
        }
        if (marker == 0xda) {
            if (!frame) return error.InvalidImage;
            // Keep entropy, byte stuffing, restart markers and subsequent scans.
            try out.appendSlice(allocator, image[start..]);
            return;
        }
        if (!(marker == 0xe2 and std.mem.startsWith(u8, payload, "ICC_PROFILE\x00"))) try out.appendSlice(allocator, image[start .. at + size]);
        at += size;
    }
    return error.InvalidImage;
}
const png_signature = "\x89PNG\r\n\x1a\n";
fn chunk(allocator: std.mem.Allocator, out: *List, kind: *const [4]u8, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u31)) return error.MetadataTooLarge;
    try number(allocator, out, u32, @intCast(bytes.len), .big);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, bytes);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(bytes);
    try number(allocator, out, u32, crc.final(), .big);
}
fn png(allocator: std.mem.Allocator, out: *List, image: []const u8, profile: []const u8) !void {
    if (!std.mem.startsWith(u8, image, png_signature)) return error.InvalidImage;
    try out.appendSlice(allocator, png_signature);
    var at: usize = 8;
    var header = false;
    var data = false;
    while (at < image.len) {
        if (image.len - at < 12) return error.InvalidImage;
        const size: usize = std.mem.readInt(u32, image[at..][0..4], .big);
        if (size > std.math.maxInt(u31) or size > image.len - at - 12) return error.InvalidImage;
        const kind = image[at + 4 ..][0..4];
        const payload = image[at + 8 ..][0..size];
        const end = at + 12 + size;
        var crc: std.hash.Crc32 = .init();
        crc.update(kind);
        crc.update(payload);
        if (crc.final() != std.mem.readInt(u32, image[end - 4 ..][0..4], .big)) return error.InvalidImage;
        if (!header) {
            if (!std.mem.eql(u8, kind, "IHDR") or size != 13 or (payload[9] != 2 and payload[9] != 3 and payload[9] != 6)) return error.UnsupportedFormat;
            header = true;
            try out.appendSlice(allocator, image[at..end]);
            const compressed = try zlib.compress(allocator, profile, 1);
            defer allocator.free(compressed);
            var body: List = .empty;
            defer body.deinit(allocator);
            try body.appendSlice(allocator, "Home ICC\x00\x00"); // keyword, NUL, deflate method
            try body.appendSlice(allocator, compressed);
            try chunk(allocator, out, "iCCP", body.items);
        } else {
            if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidImage;
            if (std.mem.eql(u8, kind, "IDAT")) data = true;
            if (std.mem.eql(u8, kind, "IEND")) {
                if (size != 0 or !data or end != image.len) return error.InvalidImage;
                try out.appendSlice(allocator, image[at..end]);
                return;
            }
            var color_chunk = false;
            inline for (.{ "iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI" }) |name| {
                if (std.mem.eql(u8, kind, name)) color_chunk = true;
            }
            if (!color_chunk) try out.appendSlice(allocator, image[at..end]);
        }
        at = end;
    }
    return error.InvalidImage;
}
fn tiff(allocator: std.mem.Allocator, out: *List, image: []const u8, profile: []const u8) !void {
    if (image.len < 8 or image.len > std.math.maxInt(u32)) return error.InvalidImage;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, image[0..2], "II")) .little else if (std.mem.eql(u8, image[0..2], "MM")) .big else return error.InvalidImage;
    if (std.mem.readInt(u16, image[2..4], endian) != 42) return error.UnsupportedFormat;
    const offset: usize = std.mem.readInt(u32, image[4..8], endian);
    if (offset < 8 or offset % 2 != 0 or offset > image.len - 2) return error.InvalidImage;
    const count: usize = std.mem.readInt(u16, image[offset..][0..2], endian);
    if (count > 4096 or image.len - offset - 2 < 4 or count > (image.len - offset - 6) / 12) return error.InvalidImage;
    const next = image[offset + 2 + count * 12 ..][0..4];
    const next_offset = std.mem.readInt(u32, next, endian);
    if (next_offset != 0 and (next_offset < 8 or next_offset % 2 != 0 or next_offset > image.len - 2 or next_offset == offset)) return error.InvalidImage;
    var previous: u16 = 0;
    var existing = false;
    var rgb = false;
    for (0..count) |i| {
        const entry = image[offset + 2 + i * 12 ..][0..12];
        const tag = std.mem.readInt(u16, entry[0..2], endian);
        const kind = std.mem.readInt(u16, entry[2..4], endian);
        const length = std.mem.readInt(u32, entry[4..8], endian);
        if (i != 0 and tag <= previous) return error.InvalidImage;
        previous = tag;
        const sizes = [_]u8{ 0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 };
        if (kind == 0 or kind >= sizes.len) return error.UnsupportedFormat;
        const bytes = std.math.mul(usize, length, sizes[kind]) catch return error.InvalidImage;
        if (bytes > 4) {
            const start: usize = std.mem.readInt(u32, entry[8..12], endian);
            if (start > image.len or bytes > image.len - start) return error.InvalidImage;
        }
        if (tag == 262) rgb = kind == 3 and length == 1 and std.mem.readInt(u16, entry[8..10], endian) == 2;
        if (tag == 34675) existing = true;
    }
    if (!rgb) return error.UnsupportedFormat;
    const entries = count + @intFromBool(!existing);
    const start = std.math.add(usize, image.len, image.len % 2) catch return error.MetadataTooLarge;
    const profile_offset = std.math.add(usize, start, 6 + entries * 12) catch return error.MetadataTooLarge;
    const total = std.math.add(usize, profile_offset, profile.len) catch return error.MetadataTooLarge;
    if (total > std.math.maxInt(u32)) return error.MetadataTooLarge;
    try out.appendSlice(allocator, image);
    if (image.len % 2 != 0) try out.append(allocator, 0);
    std.mem.writeInt(u32, out.items[4..8], @intCast(start), endian);
    try number(allocator, out, u16, @intCast(entries), endian);
    var inserted = false;
    for (0..count) |i| {
        const entry = image[offset + 2 + i * 12 ..][0..12];
        const tag = std.mem.readInt(u16, entry[0..2], endian);
        if (!inserted and tag >= 34675) {
            try tiffEntry(allocator, out, profile, @intCast(profile_offset), endian);
            inserted = true;
        }
        if (tag != 34675) try out.appendSlice(allocator, entry);
    }
    if (!inserted) try tiffEntry(allocator, out, profile, @intCast(profile_offset), endian);
    try out.appendSlice(allocator, next);
    try out.appendSlice(allocator, profile);
}
fn tiffEntry(allocator: std.mem.Allocator, out: *List, profile: []const u8, offset: u32, endian: std.builtin.Endian) !void {
    try number(allocator, out, u16, 34675, endian);
    try number(allocator, out, u16, 7, endian);
    try number(allocator, out, u32, @intCast(profile.len), endian);
    try number(allocator, out, u32, offset, endian);
}

test "JPEG ICC splits numbered segments, replaces prior profiles and preserves scan bytes" {
    const t = std.testing;
    const base = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(base);
    const profile = try t.allocator.alloc(u8, 131100);
    defer t.allocator.free(profile);
    @memset(profile, 0);
    @memcpy(profile[0..base.len], base);
    std.mem.writeInt(u32, profile[0..4], @intCast(profile.len), .big);
    const image = "\xff\xd8\xff\xe0\x00\x04HI\xff\xe2\x00\x10ICC_PROFILE\x00\x01\x01\xff\xc0\x00\x11\x08\x00\x01\x00\x01\x03\x01\x11\x00\x02\x11\x00\x03\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x11\xff\x00\x22\xff\xd9";
    const encoded = try embed(t.allocator, .jpeg, image, profile);
    defer t.allocator.free(encoded);
    try t.expectEqualSlices(u8, image[0..8], encoded[0..8]); // JFIF position retained.
    var at: usize = 8;
    var copied: usize = 0;
    for (1..4) |sequence| {
        try t.expectEqualSlices(u8, "\xff\xe2", encoded[at..][0..2]);
        const size: usize = std.mem.readInt(u16, encoded[at + 2 ..][0..2], .big);
        try t.expectEqualSlices(u8, "ICC_PROFILE\x00", encoded[at + 4 ..][0..12]);
        try t.expectEqual(sequence, encoded[at + 16]);
        try t.expectEqual(@as(u8, 3), encoded[at + 17]);
        try t.expectEqualSlices(u8, profile[copied..][0 .. size - 16], encoded[at + 18 ..][0 .. size - 16]);
        copied += size - 16;
        at += size + 2;
    }
    try t.expectEqual(profile.len, copied);
    try t.expectEqualSlices(u8, image[26..], encoded[at..]);
    for (0..image.len) |length| try t.expectError(error.InvalidImage, embed(t.allocator, .jpeg, image[0..length], base));
    try t.checkAllAllocationFailures(t.allocator, embedFree, .{ Format.jpeg, image, base });
}
fn embedFree(allocator: std.mem.Allocator, format: Format, image: []const u8, profile: []const u8) !void {
    const result = try embed(allocator, format, image, profile);
    allocator.free(result);
}
test "PNG ICC replaces conflicting color chunks without changing IDAT and checks every CRC" {
    const t = std.testing;
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    const image = try @import("formats/raster_encoder.zig").png(t.allocator, .{ .data = "\x12\x34\x56", .width = 1, .height = 1, .stride = 3 }, .{});
    defer t.allocator.free(image);
    var original: List = .empty;
    defer original.deinit(t.allocator);
    try original.appendSlice(t.allocator, image[0..33]);
    inline for (.{ "iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI" }) |name| try chunk(t.allocator, &original, name, "old");
    try chunk(t.allocator, &original, "tEXt", "Comment\x00keep");
    try original.appendSlice(t.allocator, image[33..]);
    const encoded = try embed(t.allocator, .png, original.items, profile);
    defer t.allocator.free(encoded);
    try t.expectEqualSlices(u8, image[0..33], encoded[0..33]);
    const size = std.mem.readInt(u32, encoded[33..37], .big);
    try t.expectEqualSlices(u8, "iCCPHome ICC\x00\x00", encoded[37..51]);
    // Independent Zig inflate reads the profile emitted by system zlib.
    var input: std.Io.Reader = .fixed(encoded[51 .. 41 + size]);
    var scratch: [65536]u8 = undefined;
    var inflater = std.compress.flate.Decompress.init(&input, .zlib, &scratch);
    const decoded = try inflater.reader.allocRemaining(t.allocator, .limited(profile.len + 1));
    defer t.allocator.free(decoded);
    try t.expectEqualSlices(u8, profile, decoded);
    const text_start = 45 + size;
    const text_end = text_start + 12 + "Comment\x00keep".len;
    try t.expectEqualSlices(u8, "tEXt", encoded[text_start + 4 ..][0..4]);
    try t.expectEqualSlices(u8, image[33..], encoded[text_end..]);
    original.items[original.items.len - 1] ^= 1;
    try t.expectError(error.InvalidImage, embed(t.allocator, .png, original.items, profile));
    for (0..image.len) |length| try t.expectError(error.InvalidImage, embed(t.allocator, .png, image[0..length], profile));
    try t.checkAllAllocationFailures(t.allocator, embedFree, .{ Format.png, image, profile });
}
test "TIFF ICC keeps existing strips and next IFD, sorts primary entries and replaces in either endian" {
    const t = std.testing;
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var image: [62]u8 = @splat(0);
        @memcpy(image[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, image[2..4], 42, endian);
        std.mem.writeInt(u32, image[4..8], 8, endian);
        std.mem.writeInt(u16, image[8..10], 3, endian);
        for ([_]u16{ 262, 273, 279 }, 0..) |tag, i| {
            const at = 10 + i * 12;
            std.mem.writeInt(u16, image[at..][0..2], tag, endian);
            std.mem.writeInt(u16, image[at + 2 ..][0..2], if (i == 0) 3 else 4, endian);
            std.mem.writeInt(u32, image[at + 4 ..][0..4], 1, endian);
            if (i == 0) std.mem.writeInt(u16, image[at + 8 ..][0..2], 2, endian) else std.mem.writeInt(u32, image[at + 8 ..][0..4], if (i == 1) 50 else 6, endian);
        }
        std.mem.writeInt(u32, image[46..50], 56, endian);
        @memcpy(image[50..56], "pixels");
        const encoded = try embed(t.allocator, .tiff, &image, profile);
        defer t.allocator.free(encoded);
        try t.expectEqualSlices(u8, image[8..], encoded[8..image.len]);
        try t.expectEqual(@as(u32, 62), std.mem.readInt(u32, encoded[4..8], endian));
        try t.expectEqual(@as(u16, 4), std.mem.readInt(u16, encoded[62..64], endian));
        try t.expectEqual(@as(u16, 34675), std.mem.readInt(u16, encoded[100..102], endian));
        try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, encoded[108..112], endian));
        try t.expectEqual(@as(u32, 56), std.mem.readInt(u32, encoded[112..116], endian));
        try t.expectEqualSlices(u8, profile, encoded[116..]);
        const replaced = try embed(t.allocator, .tiff, encoded, profile);
        defer t.allocator.free(replaced);
        const offset = std.mem.readInt(u32, replaced[4..8], endian);
        try t.expectEqual(@as(u16, 4), std.mem.readInt(u16, replaced[offset..][0..2], endian));
        try t.checkAllAllocationFailures(t.allocator, embedFree, .{ Format.tiff, &image, profile });
        std.mem.writeInt(u16, image[22..24], 262, endian);
        try t.expectError(error.InvalidImage, embed(t.allocator, .tiff, &image, profile));
    }
}
