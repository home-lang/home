//! Checked JPEG APP1 Exif and numbered APP2 ICC marker generation. No image,
//! encoder, raster or compressor dependency. Caller retains supplied bytes.
const std = @import("std");
pub const Metadata = struct { icc: ?[]const u8 = null, exif: ?[]const u8 = null };
pub const part_size = 65519;
pub fn check(metadata: Metadata) !Metadata {
    var result = metadata;
    if (metadata.icc) |profile| {
        _ = try @import("metadata/icc_layout.zig").validateRgb(profile);
        if (profile.len > part_size * 255) return error.MetadataTooLarge;
    }
    if (metadata.exif) |raw| {
        const view = try @import("metadata/exif_layout.zig").validate(raw);
        if (view.data.len > 65527) return error.MetadataTooLarge;
        result.exif = view.data;
    }
    return result;
}
/// Requires check()'s normalized metadata and immutable input until completion.
pub fn lengthChecked(metadata: Metadata) usize {
    var result: usize = 0;
    if (metadata.exif) |bytes| result += bytes.len + 10;
    if (metadata.icc) |bytes| result += bytes.len + 18 * ((bytes.len + part_size - 1) / part_size);
    return result;
}
fn size(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try out.appendSlice(allocator, &bytes);
}
/// Requires check()'s normalized metadata. Outputs complete marker records;
/// pixel encoding and an enclosing JPEG frame remain the caller's responsibility.
pub fn appendChecked(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metadata: Metadata) !void {
    try out.ensureUnusedCapacity(allocator, lengthChecked(metadata));
    if (metadata.exif) |bytes| {
        try out.appendSlice(allocator, "\xff\xe1");
        try size(allocator, out, @intCast(bytes.len + 8));
        try out.appendSlice(allocator, "Exif\x00\x00");
        try out.appendSlice(allocator, bytes);
    }
    if (metadata.icc) |profile| {
        const count = (profile.len + part_size - 1) / part_size;
        for (0..count) |i| {
            const bytes = profile[i * part_size .. @min(profile.len, (i + 1) * part_size)];
            try out.appendSlice(allocator, "\xff\xe2");
            try size(allocator, out, @intCast(bytes.len + 16));
            try out.appendSlice(allocator, "ICC_PROFILE\x00");
            try out.append(allocator, @intCast(i + 1));
            try out.append(allocator, @intCast(count));
            try out.appendSlice(allocator, bytes);
        }
    }
}
pub fn encode(allocator: std.mem.Allocator, metadata: Metadata) ![]u8 {
    const checked = try check(metadata);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendChecked(allocator, &out, checked);
    return out.toOwnedSlice(allocator);
}
test "JPEG markers normalize prefixed Exif and count exact header bytes" {
    const t = std.testing;
    const exif = "Exif\x00\x00II*\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const checked = try check(.{ .exif = exif });
    const encoded = try encode(t.allocator, .{ .exif = exif });
    defer t.allocator.free(encoded);
    try t.expectEqual(lengthChecked(checked), encoded.len);
    try t.expectEqualSlices(u8, "\xff\xe1\x00\x16Exif\x00\x00", encoded[0..10]);
    try t.expectEqualSlices(u8, checked.exif.?, encoded[10..]);
}
