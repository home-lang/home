//! Test-only C boundary. Production has no independent reader dependencies.
const std = @import("std");
const media = @import("media");
const allocator = std.heap.c_allocator;
fn format(value: u32) !media.Embed.Format {
    return switch (value) {
        0 => .jpeg,
        1 => .png,
        2 => .tiff,
        else => error.UnsupportedFormat,
    };
}
fn base(value: u32) ![]u8 {
    const rgb = "\x12\x34\x56";
    const view = media.Raster.View{ .data = rgb, .width = 1, .height = 1, .stride = 3 };
    return switch (try format(value)) {
        .png => media.Raster.png(allocator, view, .{}),
        .tiff => media.Raster.tiff(allocator, view),
        .jpeg => blk: {
            var encoder = media.Jpeg.Encoder.init(allocator);
            defer encoder.deinit();
            break :blk allocator.dupe(u8, try encoder.encode(rgb, 1, 1, 3, 3, 98));
        },
    };
}
pub export fn home_test_metadata_base(value: u32, length: *usize) ?[*]u8 {
    length.* = 0;
    const bytes = base(value) catch return null;
    length.* = bytes.len;
    return bytes.ptr;
}
pub export fn home_test_metadata_embed(value: u32, image: [*]const u8, image_length: usize, exif: [*]const u8, exif_length: usize, icc: c_int, length: *usize) ?[*]u8 {
    length.* = 0;
    const profile = if (icc != 0) media.Icc.createSRGBProfile(allocator) catch return null else null;
    defer if (profile) |bytes| allocator.free(bytes);
    const bytes = media.Embed.embedMetadata(allocator, format(value) catch return null, image[0..image_length], .{ .icc = profile, .exif = exif[0..exif_length] }) catch return null;
    length.* = bytes.len;
    return bytes.ptr;
}
pub export fn home_test_metadata_free(bytes: [*]u8, length: usize) void {
    allocator.free(bytes[0..length]);
}

pub export fn home_test_metadata_inline_jpeg(exif: [*]const u8, exif_length: usize, icc: c_int, length: *usize) ?[*]u8 {
    length.* = 0;
    const profile = if (icc != 0) media.Icc.createSRGBProfile(allocator) catch return null else null;
    defer if (profile) |bytes| allocator.free(bytes);
    var encoder = media.Jpeg.Encoder.init(allocator);
    defer encoder.deinit();
    const bytes = encoder.encodeOwned("\x12\x34\x56", 1, 1, 3, 3, 98, .{ .icc = profile, .exif = exif[0..exif_length] }) catch return null;
    length.* = bytes.len;
    return bytes.ptr;
}

/// Defaults fixture only: caller fields, original byte order and original value
/// locations win over these proposed defaults.
pub export fn home_test_metadata_defaults(input: [*]const u8, input_length: usize, length: *usize) ?[*]u8 {
    length.* = 0;
    var fields = media.Exif.Builder.init(allocator);
    defer fields.deinit();
    fields.ascii(.image, 0x010f, "Do not override Make") catch return null;
    fields.ascii(.image, 0x0110, "Default Model") catch return null;
    fields.ascii(.image, 0x0131, "zig-camera") catch return null;
    fields.rational(.exif, 0x829a, 1, 125) catch return null;
    fields.rational(.exif, 0x829d, 28, 10) catch return null;
    const bytes = media.Exif.withDefaults(allocator, input[0..input_length], fields.fields.items) catch return null;
    length.* = bytes.len;
    return bytes.ptr;
}
