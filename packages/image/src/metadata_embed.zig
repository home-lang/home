//! Owned ICC/Exif embedding into existing JPEG/PNG/classic TIFF containers.
//! Sample/scan/strip bytes are preserved; this is not a pixel color transform.
const std = @import("std");
const layout = @import("metadata/icc_layout.zig");
const zlib = @import("formats/zlib_stream.zig");
pub const Format = enum { jpeg, png, tiff };
const List = std.ArrayList(u8);
const jpeg_metadata = @import("jpeg_metadata.zig");
pub const Metadata = jpeg_metadata.Metadata;
/// Validate metadata separately from image I/O. Returned slices are borrowed;
/// Exif is normalized to bare TIFF bytes (without the optional Exif prefix).
pub fn check(format: Format, metadata: Metadata) !Metadata {
    if (format == .jpeg) return jpeg_metadata.check(metadata);
    var result = metadata;
    if (metadata.icc) |profile| {
        _ = try layout.validateRgb(profile);
    }
    if (metadata.exif) |bytes| {
        const view = try @import("metadata/exif_layout.zig").validate(bytes);
        if (format == .tiff) try @import("metadata_tiff.zig").check(view);
        result.exif = view.data;
    }
    return result;
}
pub fn embed(allocator: std.mem.Allocator, format: Format, image: []const u8, profile: []const u8) ![]u8 {
    return embedMetadata(allocator, format, image, .{ .icc = profile });
}
pub fn embedMetadata(allocator: std.mem.Allocator, format: Format, image: []const u8, metadata: Metadata) ![]u8 {
    const checked = try check(format, metadata);
    if (checked.icc == null and checked.exif == null) return allocator.dupe(u8, image);
    if (format == .tiff) return @import("metadata_tiff.zig").merge(allocator, image, checked.icc, if (checked.exif) |bytes| try @import("metadata/exif_layout.zig").validate(bytes) else null);
    var out: List = .empty;
    errdefer out.deinit(allocator);
    switch (format) {
        .jpeg => try jpeg(allocator, &out, image, checked),
        .png => try png(allocator, &out, image, checked),
        .tiff => unreachable,
    }
    return out.toOwnedSlice(allocator);
}
fn number(allocator: std.mem.Allocator, out: *List, comptime T: type, value: T, endian: std.builtin.Endian) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, endian);
    try out.appendSlice(allocator, &bytes);
}
fn jpeg(allocator: std.mem.Allocator, out: *List, image: []const u8, metadata: Metadata) !void {
    if (image.len < 4 or !std.mem.eql(u8, image[0..2], "\xff\xd8") or !std.mem.eql(u8, image[image.len - 2 ..], "\xff\xd9")) return error.InvalidImage;
    const capacity = try extra(image.len, jpeg_metadata.lengthChecked(metadata));
    try out.ensureTotalCapacityPrecise(allocator, capacity);
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
            try jpeg_metadata.appendChecked(allocator, out, metadata);
            inserted = true;
        }
        if (marker == 0xd9) return error.InvalidImage; // A scan is required.
        if (image.len - at < 2) return error.InvalidImage;
        const size: usize = std.mem.readInt(u16, image[at..][0..2], .big);
        if (size < 2 or size > image.len - at) return error.InvalidImage;
        const payload = image[at + 2 .. at + size];
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            if (payload.len < 6 or payload[5] == 0 or payload.len != 6 + @as(usize, payload[5]) * 3) return error.InvalidImage;
            if (metadata.icc != null and payload[5] != 3) return error.UnsupportedFormat;
            frame = true;
        }
        if (marker == 0xda) {
            if (!frame) return error.InvalidImage;
            // Keep entropy, byte stuffing, restart markers and subsequent scans.
            try out.appendSlice(allocator, image[start..]);
            return;
        }
        const old_icc = metadata.icc != null and marker == 0xe2 and std.mem.startsWith(u8, payload, "ICC_PROFILE\x00");
        const old_exif = metadata.exif != null and marker == 0xe1 and std.mem.startsWith(u8, payload, "Exif\x00\x00");
        if (!old_icc and !old_exif) try out.appendSlice(allocator, image[start .. at + size]);
        at += size;
    }
    return error.InvalidImage;
}
const png_signature = "\x89PNG\r\n\x1a\n";
fn extra(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch return error.MetadataTooLarge;
}
fn chunk(allocator: std.mem.Allocator, out: *List, kind: *const [4]u8, bytes: []const u8) !void {
    return chunkParts(allocator, out, kind, "", bytes);
}
fn chunkParts(allocator: std.mem.Allocator, out: *List, kind: *const [4]u8, prefix: []const u8, bytes: []const u8) !void {
    const size = try extra(prefix.len, bytes.len);
    if (size > std.math.maxInt(u31)) return error.MetadataTooLarge;
    try number(allocator, out, u32, @intCast(size), .big);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, bytes);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(prefix);
    crc.update(bytes);
    try number(allocator, out, u32, crc.final(), .big);
}
fn png(allocator: std.mem.Allocator, out: *List, image: []const u8, metadata: Metadata) !void {
    if (!std.mem.startsWith(u8, image, png_signature)) return error.InvalidImage;
    const compressed = if (metadata.icc) |profile| try zlib.compress(allocator, profile, 1) else null;
    defer if (compressed) |bytes| allocator.free(bytes);
    var capacity = image.len;
    if (metadata.exif) |bytes| capacity = try extra(capacity, bytes.len + 12);
    if (compressed) |bytes| capacity = try extra(capacity, bytes.len + 22);
    try out.ensureTotalCapacityPrecise(allocator, capacity);
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
            if (!std.mem.eql(u8, kind, "IHDR") or size != 13) return error.InvalidImage;
            if (payload[9] != 0 and payload[9] != 2 and payload[9] != 3 and payload[9] != 4 and payload[9] != 6) return error.UnsupportedFormat;
            if (metadata.icc != null and payload[9] != 2 and payload[9] != 3 and payload[9] != 6) return error.UnsupportedFormat;
            header = true;
            try out.appendSlice(allocator, image[at..end]);
            if (compressed) |bytes| try chunkParts(allocator, out, "iCCP", "Home ICC\x00\x00", bytes);
            if (metadata.exif) |bytes| try chunk(allocator, out, "eXIf", bytes);
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
            const old_exif = metadata.exif != null and std.mem.eql(u8, kind, "eXIf");
            if (!(metadata.icc != null and color_chunk) and !old_exif) try out.appendSlice(allocator, image[at..end]);
        }
        at = end;
    }
    return error.InvalidImage;
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

fn exifFixture(allocator: std.mem.Allocator, thumbnail: bool) ![]u8 {
    var writer = @import("metadata/exif_builder.zig").Builder.init(allocator);
    defer writer.deinit();
    try writer.ascii(.image, 0x010f, "Home Camera Company");
    try writer.short(.image, 0x0112, 6);
    try writer.rational(.exif, 0x829a, 12345, 1_000_000);
    try writer.srational(.exif, 0x9204, -2, 3);
    try writer.long(.exif, 0xa002, 1);
    try writer.long(.exif, 0xa003, 1);
    try writer.bytes(.gps, 1, 2, 2, "S\x00");
    var coordinates: [24]u8 = undefined;
    for ([_]u32{ 40, 26, 46 }, 0..) |value, i| {
        std.mem.writeInt(u32, coordinates[i * 8 ..][0..4], value, .little);
        std.mem.writeInt(u32, coordinates[i * 8 + 4 ..][0..4], 1, .little);
    }
    try writer.bytes(.gps, 2, 5, 3, &coordinates);
    try writer.bytes(.gps, 5, 1, 1, &.{1});
    try writer.rational(.gps, 6, 1234, 10);
    try writer.bytes(.interoperability, 1, 2, 4, "R98\x00");
    return writer.finish(.{ .thumbnail = if (thumbnail) "\xff\xd8\xff\xd9" else null });
}
fn embedMetadataFree(allocator: std.mem.Allocator, format: Format, image: []const u8, metadata: Metadata) !void {
    const result = try embedMetadata(allocator, format, image, metadata);
    allocator.free(result);
}
fn pngChunk(image: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 8;
    while (at + 12 <= image.len) {
        const size: usize = std.mem.readInt(u32, image[at..][0..4], .big);
        if (std.mem.eql(u8, image[at + 4 ..][0..4], name)) return image[at + 8 ..][0..size];
        at += 12 + size;
    }
    return null;
}
test "combined JPEG metadata replaces only selected APP1 APP2 records and preserves scans" {
    const t = std.testing;
    const exif = try exifFixture(t.allocator, true);
    defer t.allocator.free(exif);
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    const image = "\xff\xd8\xff\xe0\x00\x04HI\xff\xe1\x00\x0bExif\x00\x00old\xff\xe1\x00\x05XMP\xff\xc0\x00\x11\x08\x00\x01\x00\x01\x03\x01\x11\x00\x02\x11\x00\x03\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x11\xff\x00\x22\xff\xd9";
    const encoded = try embedMetadata(t.allocator, .jpeg, image, .{ .exif = exif, .icc = profile });
    defer t.allocator.free(encoded);
    try t.expectEqualSlices(u8, image[0..8], encoded[0..8]);
    try t.expectEqualSlices(u8, "\xff\xe1", encoded[8..10]);
    try t.expectEqual(exif.len + 8, std.mem.readInt(u16, encoded[10..12], .big));
    try t.expectEqualSlices(u8, "Exif\x00\x00", encoded[12..18]);
    try t.expectEqualSlices(u8, exif, encoded[18..][0..exif.len]);
    try t.expect(std.mem.indexOf(u8, encoded, "Exif\x00\x00old") == null);
    try t.expect(std.mem.indexOf(u8, encoded, "\xff\xe1\x00\x05XMP") != null);
    const tail = std.mem.indexOf(u8, image, "\xff\xc0").?;
    try t.expect(std.mem.endsWith(u8, encoded, image[tail..]));
    const preserved = try embed(t.allocator, .jpeg, image, profile);
    defer t.allocator.free(preserved);
    try t.expect(std.mem.indexOf(u8, preserved, "Exif\x00\x00old") != null);
    const replaced = try embedMetadata(t.allocator, .jpeg, encoded, .{ .exif = exif });
    defer t.allocator.free(replaced);
    try t.expectEqualSlices(u8, encoded, replaced);
    for (0..image.len) |length| try t.expectError(error.InvalidImage, embedMetadata(t.allocator, .jpeg, image[0..length], .{ .exif = exif }));
    try t.checkAllAllocationFailures(t.allocator, embedMetadataFree, .{ Format.jpeg, image, Metadata{ .icc = profile, .exif = exif } });
}
test "PNG eXIf replaces active Exif and preserves ICC and IDAT independently" {
    const t = std.testing;
    const exif = try exifFixture(t.allocator, true);
    defer t.allocator.free(exif);
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    const image = try @import("formats/raster_encoder.zig").png(t.allocator, .{ .data = "\x12\x34\x56", .width = 1, .height = 1, .stride = 3 }, .{});
    defer t.allocator.free(image);
    const encoded = try embedMetadata(t.allocator, .png, image, .{ .exif = exif, .icc = profile });
    defer t.allocator.free(encoded);
    try t.expectEqualSlices(u8, exif, pngChunk(encoded, "eXIf").?);
    try t.expectEqualSlices(u8, pngChunk(image, "IDAT").?, pngChunk(encoded, "IDAT").?);
    const replaced = try embedMetadata(t.allocator, .png, encoded, .{ .exif = exif });
    defer t.allocator.free(replaced);
    try t.expectEqualSlices(u8, pngChunk(encoded, "iCCP").?, pngChunk(replaced, "iCCP").?);
    try t.expectEqualSlices(u8, pngChunk(encoded, "IDAT").?, pngChunk(replaced, "IDAT").?);
    const reprofiled = try embed(t.allocator, .png, encoded, profile);
    defer t.allocator.free(reprofiled);
    try t.expectEqualSlices(u8, exif, pngChunk(reprofiled, "eXIf").?);
    var count: usize = 0;
    var at: usize = 8;
    while (at < replaced.len) {
        if (std.mem.eql(u8, replaced[at + 4 ..][0..4], "eXIf")) count += 1;
        at += 12 + std.mem.readInt(u32, replaced[at..][0..4], .big);
    }
    try t.expectEqual(@as(usize, 1), count);
    try t.checkAllAllocationFailures(t.allocator, embedMetadataFree, .{ Format.png, image, Metadata{ .icc = profile, .exif = exif } });
}
test "TIFF merged Exif relocates all directories bodies thumbnail and endianness without touching strips" {
    const t = std.testing;
    const exif = try exifFixture(t.allocator, true);
    defer t.allocator.free(exif);
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var image: [62]u8 = @splat(0);
        @memcpy(image[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, image[2..4], 42, endian);
        std.mem.writeInt(u32, image[4..8], 8, endian);
        std.mem.writeInt(u16, image[8..10], 3, endian);
        for ([_]u16{ 262, 273, 279 }, 0..) |tag, i| {
            const row = image[10 + i * 12 ..][0..12];
            std.mem.writeInt(u16, row[0..2], tag, endian);
            std.mem.writeInt(u16, row[2..4], if (i == 0) 3 else 4, endian);
            std.mem.writeInt(u32, row[4..8], 1, endian);
            if (i == 0) std.mem.writeInt(u16, row[8..10], 2, endian) else std.mem.writeInt(u32, row[8..12], if (i == 1) 50 else 6, endian);
        }
        std.mem.writeInt(u32, image[46..50], 56, endian);
        @memcpy(image[50..56], "pixels");
        const encoded = try embedMetadata(t.allocator, .tiff, &image, .{ .exif = exif, .icc = profile });
        defer t.allocator.free(encoded);
        try t.expectEqualSlices(u8, image[8..], encoded[8..image.len]);
        const view = try @import("metadata/exif_layout.zig").validate(encoded);
        try t.expectEqual(endian, view.endian);
        try t.expectEqual(@as(usize, 6), view.count); // metadata graph plus original page
        const root = view.directories[0];
        try t.expectEqual(@as(u32, 50), std.mem.readInt(u32, view.find(root, 273).?.bytes[0..4], endian));
        try t.expectEqualSlices(u8, profile, view.find(root, 34675).?.bytes);
        var parsed = try @import("metadata/exif.zig").parse(t.allocator, encoded);
        defer parsed.deinit();
        try t.expectEqualStrings("Home Camera Company", parsed.make.?);
        try t.expectEqual(@as(u16, 6), parsed.orientation);
        try t.expectEqual(@as(u32, 1), parsed.width);
        try t.expectEqual(@as(u32, 12345), parsed.exposure_time.?.numerator);
        try t.expectEqual(@as(i32, -2), parsed.exposure_bias.?.numerator);
        try t.expectEqual(@as(u8, 'S'), parsed.gps_latitude.?.ref);
        try t.expectEqual(@as(f64, -123.4), parsed.gps_altitude.?);
        try t.expectEqualSlices(u8, "\xff\xd8\xff\xd9", parsed.thumbnail.?);
        var previous: u16 = 0;
        for (0..root.count) |i| {
            const tag = view.entry(root, i).tag;
            if (i != 0) try t.expect(tag > previous);
            previous = tag;
        }
        const last = view.directories[view.count - 1];
        try t.expectEqual(@as(usize, 56), last.offset);
        try t.checkAllAllocationFailures(t.allocator, embedMetadataFree, .{ Format.tiff, &image, Metadata{ .icc = profile, .exif = exif } });
    }
}
test "metadata preflight rejects JPEG overflow and TIFF pixel pointers before image allocation" {
    const t = std.testing;
    var writer = @import("metadata/exif_builder.zig").Builder.init(t.allocator);
    defer writer.deinit();
    try writer.long(.image, 273, 8);
    const protected = try writer.finish(.{});
    defer t.allocator.free(protected);
    try t.expectError(error.ProtectedImageTag, check(.tiff, .{ .exif = protected }));
    const oversized = try t.allocator.alloc(u8, 65528);
    defer t.allocator.free(oversized);
    @memset(oversized, 0);
    @memcpy(oversized[0..8], "II*\x00\x08\x00\x00\x00");
    try t.expectError(error.MetadataTooLarge, check(.jpeg, .{ .exif = oversized }));
    oversized[0] = 0;
    try t.expectError(error.InvalidExif, check(.jpeg, .{ .exif = oversized }));
}

test "TIFF thumbnail replacement keeps only the new reduced image and original pages" {
    const t = std.testing;
    const first_exif = try exifFixture(t.allocator, true);
    defer t.allocator.free(first_exif);
    var writer = @import("metadata/exif_builder.zig").Builder.init(t.allocator);
    defer writer.deinit();
    try writer.ascii(.image, 0x010f, "Replacement Camera");
    const new_thumb = "\xff\xd8NEW\xff\xd9";
    const next_exif = try writer.finish(.{ .thumbnail = new_thumb });
    defer t.allocator.free(next_exif);
    const base = try @import("formats/raster_encoder.zig").tiff(t.allocator, .{ .data = "\x12\x34\x56", .width = 1, .height = 1, .stride = 3 });
    defer t.allocator.free(base);
    const first = try embedMetadata(t.allocator, .tiff, base, .{ .exif = first_exif });
    defer t.allocator.free(first);
    const second = try embedMetadata(t.allocator, .tiff, first, .{ .exif = next_exif });
    defer t.allocator.free(second);
    const layout_exif = @import("metadata/exif_layout.zig");
    const view = try layout_exif.validate(second);
    var images: usize = 0;
    for (view.directories[0..view.count]) |dir| if (dir.kind == .image) {
        images += 1;
    };
    try t.expectEqual(@as(usize, 2), images);
    var parsed = try @import("metadata/exif.zig").parse(t.allocator, second);
    defer parsed.deinit();
    try t.expectEqualSlices(u8, new_thumb, parsed.thumbnail.?);
    try t.expectEqualStrings("Replacement Camera", parsed.make.?);
    // An unmarked old JPEG page is retained as original image content. Parsing
    // still selects the first thumbnail, independently of later JPEG pages.
    const old_view = try layout_exif.validate(first);
    for (old_view.directories[0..old_view.count]) |dir| {
        if (dir.kind != .image or dir.primary) continue;
        for (0..dir.count) |n| if (old_view.entry(dir, n).tag == 254) std.mem.writeInt(u32, first[dir.offset + 2 + n * 12 + 8 ..][0..4], 0, .little);
    }
    const retained = try embedMetadata(t.allocator, .tiff, first, .{ .exif = next_exif });
    defer t.allocator.free(retained);
    var retained_parsed = try @import("metadata/exif.zig").parse(t.allocator, retained);
    defer retained_parsed.deinit();
    try t.expectEqualSlices(u8, new_thumb, retained_parsed.thumbnail.?);
    try t.checkAllAllocationFailures(t.allocator, embedMetadataFree, .{ Format.tiff, second, Metadata{ .exif = next_exif } });
}

test "Exif-only grayscale images preserve samples and reject incompatible RGB profiles" {
    const t = std.testing;
    const exif = try exifFixture(t.allocator, false);
    defer t.allocator.free(exif);
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    const raster = @import("formats/raster_encoder.zig");
    const view = raster.View{ .data = "\x42", .width = 1, .height = 1, .stride = 1, .format = .gray };
    const gray_png = try raster.png(t.allocator, view, .{});
    defer t.allocator.free(gray_png);
    const png_exif = try embedMetadata(t.allocator, .png, gray_png, .{ .exif = exif });
    defer t.allocator.free(png_exif);
    try t.expectEqualSlices(u8, pngChunk(gray_png, "IDAT").?, pngChunk(png_exif, "IDAT").?);
    try t.expectError(error.UnsupportedFormat, embedMetadata(t.allocator, .png, gray_png, .{ .icc = profile, .exif = exif }));
    const gray_tiff = try raster.tiff(t.allocator, view);
    defer t.allocator.free(gray_tiff);
    const tiff_exif = try embedMetadata(t.allocator, .tiff, gray_tiff, .{ .exif = exif });
    defer t.allocator.free(tiff_exif);
    try t.expectEqualSlices(u8, gray_tiff[8..], tiff_exif[8..gray_tiff.len]);
    try t.expectError(error.UnsupportedFormat, embedMetadata(t.allocator, .tiff, gray_tiff, .{ .icc = profile, .exif = exif }));
    var writer = @import("metadata/exif_builder.zig").Builder.init(t.allocator);
    defer writer.deinit();
    try writer.long(.thumbnail, 273, 8);
    const strip_thumbnail = try writer.finish(.{ .thumbnail = "\xff\xd8\xff\xd9" });
    defer t.allocator.free(strip_thumbnail);
    try t.expectError(error.UnsupportedThumbnail, check(.tiff, .{ .exif = strip_thumbnail }));
}
