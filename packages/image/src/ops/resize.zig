// Image Resizing Operations
// Implements various resampling algorithms

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const resample = @import("../formats/pixel_resample.zig");
const raster = @import("../formats/raster_encoder.zig");

// ============================================================================
// Resize Algorithms
// ============================================================================

pub const ResizeAlgorithm = resample.Algorithm;

pub const FitMode = enum {
    fill, // Stretch to fill exactly (may distort aspect ratio)
    contain, // Fit within bounds, maintaining aspect ratio (may have letterboxing)
    cover, // Fill bounds, maintaining aspect ratio (may crop)
    inside, // Like contain, but never upscale
    outside, // Like cover, but never downscale
};

// ============================================================================
// Main Resize Function
// ============================================================================

/// Owned, native-precision output. Indexed input expands through the same checked
/// palette path as PNG/GIF. Resizing animation rectangles needs a compositor and
/// is rejected rather than silently dropping frames.
pub fn resize(img: *const Image, new_width: u32, new_height: u32, algorithm: ResizeAlgorithm) !Image {
    const indexed = @import("../formats/indexed_raster.zig");
    const raw = if (img.format == .indexed8) try indexed.indexedView(img.pixels, img.width, img.height) else try raster.fromImage(img);
    if (img.format == .indexed8) try indexed.validateIndices(img, raw);
    // Validate target before allocating even the indexed expansion.
    var shape = raw;
    if (img.format == .indexed8) shape.format = .rgba;
    const target_row = try resample.pixel.packedRow(new_width, shape.format, shape.bits);
    if (new_height == 0 or new_height > std.math.maxInt(i32)) return error.InvalidGeometry;
    const target_size = std.math.mul(usize, target_row, new_height) catch return error.InvalidGeometry;
    if (target_size > (resample.Limits{}).max_output_bytes) return error.WorkLimit;
    if (new_width == img.width and new_height == img.height) return img.clone();
    if (img.frames) |frames| if (frames.len != 0) return error.UnsupportedAnimation;
    if (img.format == .indexed8) {
        const expanded_row = try resample.pixel.packedRow(img.width, .rgba, 8);
        const expanded_size = std.math.mul(usize, expanded_row, img.height) catch return error.InvalidGeometry;
        if (expanded_size > (resample.Limits{}).max_output_bytes) return error.WorkLimit;
    }
    const expanded = if (img.format == .indexed8) try indexed.expandIndices(img.allocator, img, raw) else null;
    defer if (expanded) |view| img.allocator.free(view.data);
    const result = try resample.resize(img.allocator, expanded orelse raw, new_width, new_height, algorithm, .{});
    return .{ .allocator = img.allocator, .width = new_width, .height = new_height, .format = if (img.format == .indexed8) .rgba8 else img.format, .pixels = @constCast(result.view.data), .palette = null, .loop_count = img.loop_count };
}

pub fn resizeWithFit(img: *const Image, max_width: u32, max_height: u32, mode: FitMode, algorithm: ResizeAlgorithm, background: Color) !Image {
    const target = try calculateTargetSize(img.width, img.height, max_width, max_height, mode);

    if (target.width == img.width and target.height == img.height) {
        return img.clone();
    }

    // First resize
    var resized = try resize(img, target.width, target.height, algorithm);

    // If contain or inside mode, add padding
    if ((mode == .contain or mode == .inside) and (target.width < max_width or target.height < max_height)) {
        defer resized.deinit();

        _ = try resample.outputSize(try raster.fromImage(&resized), max_width, max_height, .{});
        var final = try Image.init(img.allocator, max_width, max_height, resized.format);
        errdefer final.deinit();

        // Fill with background
        var y: u32 = 0;
        while (y < max_height) : (y += 1) {
            var x: u32 = 0;
            while (x < max_width) : (x += 1) {
                final.setPixel(x, y, background);
            }
        }

        // Center the resized image
        const offset_x = (max_width - target.width) / 2;
        const offset_y = (max_height - target.height) / 2;

        y = 0;
        while (y < target.height) : (y += 1) {
            var x: u32 = 0;
            while (x < target.width) : (x += 1) {
                if (resized.getPixel16(x, y)) |color| {
                    final.setPixel16(offset_x + x, offset_y + y, color);
                }
            }
        }

        return final;
    }

    return resized;
}

fn calculateTargetSize(src_width: u32, src_height: u32, max_width: u32, max_height: u32, mode: FitMode) !struct { width: u32, height: u32 } {
    for ([_]u32{ src_width, src_height, max_width, max_height }) |v| if (v == 0 or v > std.math.maxInt(i32)) return error.InvalidGeometry;
    if (mode == .fill) return .{ .width = max_width, .height = max_height };
    if (mode == .inside and src_width <= max_width and src_height <= max_height) return .{ .width = src_width, .height = src_height };
    if (mode == .outside and src_width >= max_width and src_height >= max_height) return .{ .width = src_width, .height = src_height };
    const wide = @as(u64, src_width) * max_height > @as(u64, max_width) * src_height;
    const contain = mode == .contain or mode == .inside;
    var width: u64 = max_width;
    var height: u64 = max_height;
    if (wide == contain) height = @max(1, @as(u64, src_height) * max_width / src_width) else width = @max(1, @as(u64, src_width) * max_height / src_height);
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidGeometry;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

// ============================================================================
// Tests
// ============================================================================

test "Resize nearest neighbor" {
    var img = try Image.init(std.testing.allocator, 4, 4, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.GREEN);
    img.setPixel(0, 1, Color.BLUE);
    img.setPixel(1, 1, Color.WHITE);

    var resized = try resize(&img, 2, 2, .nearest);
    defer resized.deinit();

    try std.testing.expectEqual(@as(u32, 2), resized.width);
    try std.testing.expectEqual(@as(u32, 2), resized.height);
}

test "Calculate target size - contain" {
    const result = try calculateTargetSize(1000, 500, 200, 200, .contain);
    try std.testing.expectEqual(@as(u32, 200), result.width);
    try std.testing.expectEqual(@as(u32, 100), result.height);
}

fn resizeFailure(a: std.mem.Allocator) !void {
    var img = try Image.init(a, 2, 1, .rgb16);
    defer img.deinit();
    img.setPixel16(0, 0, .{ .r = 12345, .g = 23456, .b = 34567 });
    img.setPixel16(1, 0, .{ .r = 54321, .g = 43210, .b = 32109 });
    const original = img.pixels.ptr;
    img.resizeBilinear(1, 1) catch |err| {
        try std.testing.expectEqual(@as(u32, 2), img.width);
        try std.testing.expect(img.pixels.ptr == original);
        try std.testing.expectEqual(@as(u16, 12345), img.getPixel16(0, 0).?.r);
        return err;
    };
    try std.testing.expectEqual(@as(u16, 33333), img.getPixel16(0, 0).?.r);
    try std.testing.expectEqual(@as(u16, 33333), img.getPixel16(0, 0).?.g);
    try std.testing.expectEqual(@as(u16, 33338), img.getPixel16(0, 0).?.b);
}
test "native Image resize retains words and original owners on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, resizeFailure, .{});
}
test "indexed resize expands palette alpha and rejects animation and invalid geometry" {
    const t = std.testing;
    var img = try Image.init(t.allocator, 2, 1, .indexed8);
    defer img.deinit();
    img.palette = try t.allocator.dupe(Color, &.{ .{ .r = 255, .g = 0, .b = 0, .a = 0 }, Color.BLUE });
    @memcpy(img.pixels, &[_]u8{ 0, 1 });
    var out = try resize(&img, 1, 1, .bilinear);
    defer out.deinit();
    try t.expectEqual(image.PixelFormat.rgba8, out.format);
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, out.pixels);
    try t.expectError(error.InvalidGeometry, img.resizeNearest(0, 1));
    img.pixels[1] = 2;
    try t.expectError(error.InvalidPalette, resize(&img, 1, 1, .nearest));
    img.pixels[1] = 1;
    img.frames = try t.allocator.alloc(Image.Frame, 1);
    img.frames.?[0] = .{ .pixels = try t.allocator.dupe(u8, img.pixels), .delay_ms = 10 };
    try t.expectError(error.UnsupportedAnimation, img.resizeBilinear(1, 1));
    try t.expectEqual(@as(usize, 1), img.frames.?.len);
    try t.expectError(error.InvalidGeometry, calculateTargetSize(1, 1, 0, 1, .contain));
    try t.expectError(error.InvalidGeometry, calculateTargetSize(1, 0x7fffffff, 0x7fffffff, 1, .cover));
}
