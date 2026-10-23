// PNG/APNG owned integer decoding and encoding. https://www.w3.org/TR/png-3/
const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;
const raster = @import("raster_encoder.zig");
pub const AnimationEncoder = @import("apng_encoder.zig");
pub const Decoder = @import("../png_decoder.zig");

/// The Image adapter retains integer depth, palette alpha and independent frame
/// owners. Use Decoder.decode for exact fractional delays and owned metadata.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    return decodeWithOptions(allocator, data, .{});
}
pub fn decodeWithOptions(allocator: std.mem.Allocator, data: []const u8, options: Decoder.Options) !Image {
    var result = try Decoder.decode(allocator, data, options);
    defer result.deinit();
    const source = result.default_image;
    const format: PixelFormat = switch (source.format) {
        .gray => if (source.bits == 16) .grayscale16 else .grayscale8,
        .rgb => if (source.bits == 16) .rgb16 else .rgb8,
        .rgba => if (source.bits == 16) .rgba16 else .rgba8,
        .indexed => .indexed8,
    };
    var img = Image{ .allocator = allocator, .width = source.width, .height = source.height, .format = format, .pixels = source.pixels, .palette = null, .loop_count = result.plays };
    result.default_image.pixels = &.{};
    errdefer img.deinit();
    if (format == .indexed8) {
        const palette = try allocator.alloc(Color, result.palette_count);
        img.palette = palette;
        for (palette, 0..) |*color, i| {
            const rgba = result.palette[i * 4 ..][0..4];
            color.* = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
        }
    }
    if (result.frames.len != 0) {
        const frames = try allocator.alloc(Image.Frame, result.frames.len);
        // All fallible allocations precede ownership transfer.
        for (frames, result.frames) |*frame, *decoded| {
            const control = decoded.control;
            const den: u32 = if (control.delay_den == 0) 100 else control.delay_den;
            frame.* = .{ .width = control.width, .height = control.height, .pixels = decoded.raster.pixels, .delay_ms = @as(u32, control.delay_num) * 1000 / den, .x_offset = control.x, .y_offset = control.y, .dispose_op = switch (control.dispose) {
                0 => .none,
                1 => .background,
                2 => .previous,
                else => unreachable,
            }, .blend_op = if (control.blend == 0) .source else .over };
            decoded.raster.pixels = &.{};
        }
        img.frames = frames;
    }
    return img;
}

/// Image.frames[0] is the default image when animation frames are present.
/// Its pixels, rather than Image.pixels, supply the first animation frame.
/// Indexed pixels expand to RGBA to retain the complete palette alpha channel.
pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    const source_frames = img.frames orelse &.{};
    if (source_frames.len == 0) {
        if (img.format != .indexed8) return raster.png(allocator, try raster.fromImage(img), .{});
        const view = try indexedView(img.pixels, img.width, img.height);
        try validateIndices(img, view);
        const rgba = try expandIndices(allocator, img, view);
        defer allocator.free(rgba.data);
        return raster.png(allocator, rgba, .{});
    }
    if (source_frames.len > std.math.maxInt(u31)) return error.InvalidAnimation;
    const frames = try allocator.alloc(AnimationEncoder.Frame, source_frames.len);
    defer allocator.free(frames);
    var expanded: usize = 0;
    defer for (frames[0..expanded]) |frame| allocator.free(frame.view.data);
    for (source_frames, frames) |frame, *out| {
        const width = frame.width orelse img.width;
        const height = frame.height orelse img.height;
        var source = img.*;
        source.width = width;
        source.height = height;
        source.pixels = frame.pixels;
        out.* = .{
            .view = if (img.format == .indexed8) try indexedView(frame.pixels, width, height) else try raster.fromImage(&source),
            .x = frame.x_offset,
            .y = frame.y_offset,
            .delay = try AnimationEncoder.Delay.fromMilliseconds(frame.delay_ms),
            .dispose = switch (frame.dispose_op) {
                .none => .none,
                .background => .background,
                .previous => .previous,
            },
            .blend = switch (frame.blend_op) {
                .source => .source,
                .over => .over,
            },
        };
    }
    const animation = AnimationEncoder.Animation{ .width = img.width, .height = img.height, .frames = frames, .plays = img.loop_count };
    try animation.validate();
    if (img.format == .indexed8) {
        for (frames) |frame| try validateIndices(img, frame.view);
        for (frames) |*frame| {
            frame.view = try expandIndices(allocator, img, frame.view);
            expanded += 1;
        }
    }
    return AnimationEncoder.encode(allocator, animation);
}
const indexedView = @import("indexed_raster.zig").indexedView;
const validateIndices = @import("indexed_raster.zig").validateIndices;
const expandIndices = @import("indexed_raster.zig").expandIndices;

test "PNG magic bytes" {
    try std.testing.expectEqual(
        @as(u8, 0x89),
        Decoder.signature[0],
    );
}
test "PNG public image encoding preserves sixteen-bit little-endian input in network byte order" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 1, 1, .rgb16);
    defer img.deinit();
    @memcpy(img.pixels, &[_]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a });
    const bytes = try encode(a, &img);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(PixelFormat.rgb16, decoded.format);
    try std.testing.expectEqualSlices(u8, img.pixels, decoded.pixels);
}

test "PNG encoder round trips RGBA pixels" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 2, .rgba8);
    defer img.deinit();
    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.GREEN);
    img.setPixel(0, 1, Color.BLUE);
    img.setPixel(1, 1, Color{ .r = 12, .g = 34, .b = 56, .a = 78 });

    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(Color.RED, decoded.getPixel(0, 0).?);
    try std.testing.expectEqual(Color.GREEN, decoded.getPixel(1, 0).?);
    try std.testing.expectEqual(Color.BLUE, decoded.getPixel(0, 1).?);
    try std.testing.expectEqual(Color{ .r = 12, .g = 34, .b = 56, .a = 78 }, decoded.getPixel(1, 1).?);
}

test "Image APNG uses frame zero pixels, explicit rectangles and exact long delays" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 2, 1, .rgb16);
    defer img.deinit();
    const frames = try a.alloc(Image.Frame, 2);
    @memset(frames, .{ .pixels = &.{}, .delay_ms = 0 });
    img.frames = frames;
    frames[0].pixels = try a.dupe(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde, 0x22, 0x11, 0x44, 0x33 });
    frames[0].delay_ms = 20;
    frames[1] = .{ .pixels = try a.dupe(u8, &.{ 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef }), .width = 1, .height = 1, .x_offset = 1, .delay_ms = 65536, .dispose_op = .previous, .blend_op = .over };
    img.loop_count = 3;
    const encoded = try img.encode(.png);
    defer a.free(encoded);
    var decoded = try decode(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, frames[0].pixels, decoded.pixels);
    const result = decoded.frames.?;
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 3), decoded.loop_count);
    try std.testing.expectEqual(@as(?u32, 1), result[1].width);
    try std.testing.expectEqual(@as(?u32, 1), result[1].height);
    try std.testing.expectEqual(@as(u32, 1), result[1].x_offset);
    try std.testing.expectEqual(@as(u32, 65536), result[1].delay_ms);
    try std.testing.expectEqual(Image.DisposeOp.previous, result[1].dispose_op);
    try std.testing.expectEqual(Image.BlendOp.over, result[1].blend_op);
    try std.testing.expectEqualSlices(u8, frames[1].pixels, result[1].pixels);
    frames[1].width = 2;
    try std.testing.expectError(error.BufferTooSmall, img.encode(.png));
}
test "indexed PNG expands palette alpha and rejects missing or out of range palette entries" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 2, 1, .indexed8);
    defer img.deinit();
    img.palette = try a.dupe(Color, &.{ .{ .r = 255, .g = 0, .b = 0, .a = 0 }, .{ .r = 0, .g = 0, .b = 255, .a = 91 } });
    @memcpy(img.pixels, &[_]u8{ 0, 1 });
    const bytes = try img.encode(.png);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0, 255, 91 }, decoded.pixels);
    img.pixels[1] = 2;
    try std.testing.expectError(error.InvalidPalette, img.encode(.png));
}
fn indexedAnimationAllocationCase(a: std.mem.Allocator) !void {
    var img = try Image.init(a, 2, 1, .indexed8);
    defer img.deinit();
    img.palette = try a.dupe(Color, &.{Color.RED});
    const frames = try a.alloc(Image.Frame, 2);
    @memset(frames, .{ .pixels = &.{}, .delay_ms = 10 });
    img.frames = frames;
    frames[0].pixels = try a.dupe(u8, &.{ 0, 0 });
    frames[1].pixels = try a.dupe(u8, &.{ 0, 0 });
    const bytes = try img.encode(.png);
    defer a.free(bytes);
}
test "indexed APNG adapter unwinds frame descriptors expansions and PNG data on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, indexedAnimationAllocationCase, .{});
}

fn decodeAdapterFailure(a: std.mem.Allocator, bytes: []const u8) !void {
    var result = try decode(a, bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.frames.?.len);
}
test "PNG public adapter retains all integer formats and unwinds independent animation ownership" {
    const a = std.testing.allocator;
    for ([_]PixelFormat{ .grayscale8, .grayscale16, .rgb8, .rgb16, .rgba8, .rgba16 }) |format| {
        var img = try Image.init(a, 2, 3, format);
        defer img.deinit();
        for (img.pixels, 0..) |*byte, i| byte.* = @truncate(i * 37 + 17);
        const encoded = try img.encode(.png);
        defer a.free(encoded);
        var decoded = try Image.loadFromMemory(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(format, decoded.format);
        try std.testing.expectEqualSlices(u8, img.pixels, decoded.pixels);
    }
    const view = raster.View{ .data = &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a }, .width = 1, .height = 1, .stride = 6, .format = .rgb, .bits = 16 };
    const frames = [_]AnimationEncoder.Frame{ .{ .view = view }, .{ .view = view } };
    const encoded = try AnimationEncoder.encode(a, .{ .width = 1, .height = 1, .frames = &frames });
    defer a.free(encoded);
    try std.testing.checkAllAllocationFailures(a, decodeAdapterFailure, .{encoded});
}
