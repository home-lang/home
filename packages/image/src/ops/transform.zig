// Image Transform Operations
// Rotate, flip, affine transformations

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
/// Allocation-free exact orientation geometry for strided image/video planes.
pub const OrthogonalTransform = @import("orientation.zig").Transform;

// ============================================================================
// Rotation
// ============================================================================

pub const RotateMode = enum {
    degrees_90,
    degrees_180,
    degrees_270,
};

/// Rotate image by 90, 180, or 270 degrees
pub fn rotate(img: *const Image, mode: RotateMode) !Image {
    return switch (mode) {
        .degrees_90 => rotate90(img),
        .degrees_180 => rotate180(img),
        .degrees_270 => rotate270(img),
    };
}

/// Rotate image by arbitrary angle (in degrees)
pub fn rotateAngle(img: *const Image, degrees: f64, background: Color) !Image {
    const radians = degrees * std.math.pi / 180.0;
    const cos_a = @cos(radians);
    const sin_a = @sin(radians);

    // Calculate new dimensions to fit rotated image
    const w: f64 = @floatFromInt(img.width);
    const h: f64 = @floatFromInt(img.height);

    const corners = [4][2]f64{
        .{ 0, 0 },
        .{ w, 0 },
        .{ 0, h },
        .{ w, h },
    };

    var min_x: f64 = std.math.floatMax(f64);
    var max_x: f64 = std.math.floatMin(f64);
    var min_y: f64 = std.math.floatMax(f64);
    var max_y: f64 = std.math.floatMin(f64);

    for (corners) |corner| {
        const rx = corner[0] * cos_a - corner[1] * sin_a;
        const ry = corner[0] * sin_a + corner[1] * cos_a;
        min_x = @min(min_x, rx);
        max_x = @max(max_x, rx);
        min_y = @min(min_y, ry);
        max_y = @max(max_y, ry);
    }

    const new_width: u32 = @intFromFloat(@ceil(max_x - min_x));
    const new_height: u32 = @intFromFloat(@ceil(max_y - min_y));

    if (new_width == 0 or new_height == 0) {
        return error.InvalidDimensions;
    }

    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    // Fill with background
    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            result.setPixel(x, y, background);
        }
    }

    // Center of source and destination
    const src_cx = w / 2.0;
    const src_cy = h / 2.0;
    const dst_cx = @as(f64, @floatFromInt(new_width)) / 2.0;
    const dst_cy = @as(f64, @floatFromInt(new_height)) / 2.0;

    // Inverse transform to map destination to source
    y = 0;
    while (y < new_height) : (y += 1) {
        const dy = @as(f64, @floatFromInt(y)) - dst_cy;

        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) - dst_cx;

            // Inverse rotation
            const sx = dx * cos_a + dy * sin_a + src_cx;
            const sy = -dx * sin_a + dy * cos_a + src_cy;

            // Bilinear interpolation
            if (sx >= 0 and sx < w - 1 and sy >= 0 and sy < h - 1) {
                const sx0: u32 = @intFromFloat(sx);
                const sy0: u32 = @intFromFloat(sy);
                const sx1: u32 = sx0 + 1;
                const sy1: u32 = sy0 + 1;

                const fx = sx - @as(f64, @floatFromInt(sx0));
                const fy = sy - @as(f64, @floatFromInt(sy0));

                const c00 = img.getPixel(sx0, sy0) orelse background;
                const c10 = img.getPixel(sx1, sy0) orelse background;
                const c01 = img.getPixel(sx0, sy1) orelse background;
                const c11 = img.getPixel(sx1, sy1) orelse background;

                const color = bilinearInterpolate(c00, c10, c01, c11, fx, fy);
                result.setPixel(x, y, color);
            } else if (sx >= 0 and sx < w and sy >= 0 and sy < h) {
                if (img.getPixel(@intFromFloat(sx), @intFromFloat(sy))) |c| {
                    result.setPixel(x, y, c);
                }
            }
        }
    }

    return result;
}

fn bilinearInterpolate(c00: Color, c10: Color, c01: Color, c11: Color, fx: f64, fy: f64) Color {
    const inv_fx = 1.0 - fx;
    const inv_fy = 1.0 - fy;

    return Color{
        .r = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.r)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.r)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.r)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.r)) * fx * fy,
            0,
            255,
        )),
        .g = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.g)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.g)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.g)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.g)) * fx * fy,
            0,
            255,
        )),
        .b = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.b)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.b)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.b)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.b)) * fx * fy,
            0,
            255,
        )),
        .a = @intFromFloat(std.math.clamp(
            @as(f64, @floatFromInt(c00.a)) * inv_fx * inv_fy +
                @as(f64, @floatFromInt(c10.a)) * fx * inv_fy +
                @as(f64, @floatFromInt(c01.a)) * inv_fx * fy +
                @as(f64, @floatFromInt(c11.a)) * fx * fy,
            0,
            255,
        )),
    };
}

const oriented = @import("../oriented_pixels.zig");
const pixel_views = @import("../formats/pixel_view.zig");
fn pixelView(img: *const Image, bytes: []const u8, width: u32, height: u32) !pixel_views.View {
    const format: pixel_views.Format = switch (img.format) {
        .grayscale8, .grayscale16, .indexed8 => .gray,
        .rgb8, .rgb16 => .rgb,
        .rgba8, .rgba16 => .rgba,
    };
    const bits: u8 = switch (img.format) {
        .grayscale16, .rgb16, .rgba16 => 16,
        else => 8,
    };
    const row = try pixel_views.packedRow(width, format, bits);
    const view = pixel_views.View{ .data = bytes, .width = width, .height = height, .stride = row, .format = format, .bits = bits };
    _ = try view.validate();
    return view;
}
fn frameView(img: *const Image, frame: Image.Frame) !pixel_views.View {
    const w = frame.width orelse img.width;
    const h = frame.height orelse img.height;
    if (frame.x_offset > img.width or frame.y_offset > img.height or w > img.width - frame.x_offset or h > img.height - frame.y_offset) return error.InvalidGeometry;
    return pixelView(img, frame.pixels, w, h);
}
fn validateOrthogonal(img: *const Image) !pixel_views.View {
    const view = try pixelView(img, img.pixels, img.width, img.height);
    if (img.frames) |frames| {
        for (frames) |frame| _ = try frameView(img, frame);
    }
    return view;
}
fn movedFrame(img: *const Image, frame: Image.Frame, transform: OrthogonalTransform) Image.Frame {
    const w = frame.width orelse img.width;
    const h = frame.height orelse img.height;
    const x = if (transform.hflip) img.width - frame.x_offset - w else frame.x_offset;
    const y = if (transform.vflip) img.height - frame.y_offset - h else frame.y_offset;
    var result = frame;
    result.width = if (transform.transpose) frame.height else frame.width;
    result.height = if (transform.transpose) frame.width else frame.height;
    result.x_offset = if (transform.transpose) y else x;
    result.y_offset = if (transform.transpose) x else y;
    return result;
}
/// Exact byte permutation, including native sixteen-bit samples and indexed
/// palette entries. Animation rectangles, timing/disposal/blend and loop count
/// retain independent owned storage and transform with the canvas.
pub fn orthogonal(img: *const Image, transform: OrthogonalTransform) !Image {
    const source = try validateOrthogonal(img);
    const planned = try oriented.info(source, transform);
    var result = try Image.init(img.allocator, planned.width, planned.height, img.format);
    errdefer result.deinit();
    try oriented.into(source, transform, result.pixels, planned.row_bytes);
    result.palette = if (img.palette) |palette| try img.allocator.dupe(Color, palette) else null;
    result.loop_count = img.loop_count;
    if (img.frames) |frames| {
        const targets = try img.allocator.alloc(Image.Frame, frames.len);
        errdefer img.allocator.free(targets);
        var done: usize = 0;
        errdefer for (targets[0..done]) |frame| img.allocator.free(frame.pixels);
        for (frames, targets) |frame, *target| {
            const owned = try oriented.copy(img.allocator, try frameView(img, frame), transform);
            target.* = movedFrame(img, frame, transform);
            target.pixels = @constCast(owned.view.data);
            done += 1;
        }
        result.frames = targets;
    }
    return result;
}
fn rotate90(img: *const Image) !Image {
    return orthogonal(img, try OrthogonalTransform.fromRotation(90, false, false));
}
fn rotate180(img: *const Image) !Image {
    return orthogonal(img, try OrthogonalTransform.fromRotation(180, false, false));
}
fn rotate270(img: *const Image) !Image {
    return orthogonal(img, try OrthogonalTransform.fromRotation(270, false, false));
}

// ============================================================================
// Flip Operations
// ============================================================================

/// Flip vertically with exact pixels and owned palette/animation data.
pub fn flip(img: *const Image) !Image {
    return orthogonal(img, .{ .vflip = true });
}
/// Flip horizontally with exact pixels and owned palette/animation data.
pub fn flop(img: *const Image) !Image {
    return orthogonal(img, .{ .hflip = true });
}
fn mirror(view: pixel_views.View, pixels: []u8, vertical: bool) void {
    const row = view.stride;
    if (vertical) {
        for (0..view.height / 2) |y| for (0..row) |byte| {
            std.mem.swap(u8, &pixels[y * row + byte], &pixels[(@as(usize, view.height) - 1 - y) * row + byte]);
        };
    } else {
        const bpp = view.format.channels() * (view.bits / 8);
        for (0..view.height) |y| for (0..view.width / 2) |x| for (0..bpp) |byte| {
            std.mem.swap(u8, &pixels[y * row + x * bpp + byte], &pixels[y * row + (@as(usize, view.width) - 1 - x) * bpp + byte]);
        };
    }
}
fn mirrorInPlace(img: *Image, vertical: bool) void {
    // Public void methods preserve all owners/pixels if any frame is invalid.
    const source = validateOrthogonal(img) catch return;
    mirror(source, img.pixels, vertical);
    const transform = OrthogonalTransform{ .hflip = !vertical, .vflip = vertical };
    if (img.frames) |frames| for (frames) |*frame| {
        const view = frameView(img, frame.*) catch unreachable;
        mirror(view, frame.pixels, vertical);
        frame.* = movedFrame(img, frame.*, transform);
    };
}
/// Existing void API: invalid input leaves every pixel/frame unchanged.
pub fn flipInPlace(img: *Image) void {
    mirrorInPlace(img, true);
}
pub fn flopInPlace(img: *Image) void {
    mirrorInPlace(img, false);
}

// ============================================================================
// Affine Transform
// ============================================================================

/// 2D affine transformation matrix (3x3, but only using 2x3)
/// | a  b  tx |
/// | c  d  ty |
/// | 0  0  1  |
pub const AffineMatrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,

    pub fn identity() AffineMatrix {
        return .{};
    }

    pub fn translation(dx: f64, dy: f64) AffineMatrix {
        return .{ .tx = dx, .ty = dy };
    }

    pub fn scale(sx: f64, sy: f64) AffineMatrix {
        return .{ .a = sx, .d = sy };
    }

    pub fn rotation(radians: f64) AffineMatrix {
        const cos_a = @cos(radians);
        const sin_a = @sin(radians);
        return .{ .a = cos_a, .b = -sin_a, .c = sin_a, .d = cos_a };
    }

    pub fn shear(shx: f64, shy: f64) AffineMatrix {
        return .{ .b = shx, .c = shy };
    }

    /// Multiply two matrices
    pub fn multiply(self: AffineMatrix, other: AffineMatrix) AffineMatrix {
        return .{
            .a = self.a * other.a + self.b * other.c,
            .b = self.a * other.b + self.b * other.d,
            .c = self.c * other.a + self.d * other.c,
            .d = self.c * other.b + self.d * other.d,
            .tx = self.a * other.tx + self.b * other.ty + self.tx,
            .ty = self.c * other.tx + self.d * other.ty + self.ty,
        };
    }

    /// Invert the matrix
    pub fn invert(self: AffineMatrix) ?AffineMatrix {
        const det = self.a * self.d - self.b * self.c;
        if (@abs(det) < 1e-10) return null;

        const inv_det = 1.0 / det;
        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .tx = (self.b * self.ty - self.d * self.tx) * inv_det,
            .ty = (self.c * self.tx - self.a * self.ty) * inv_det,
        };
    }

    /// Transform a point
    pub fn transformPoint(self: AffineMatrix, x: f64, y: f64) struct { x: f64, y: f64 } {
        return .{
            .x = self.a * x + self.b * y + self.tx,
            .y = self.c * x + self.d * y + self.ty,
        };
    }
};

pub fn affine(img: *const Image, matrix: AffineMatrix, new_width: u32, new_height: u32, background: Color) !Image {
    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    // Get inverse matrix to map destination to source
    const inv = matrix.invert() orelse return error.InvalidTransform;

    var y: u32 = 0;
    while (y < new_height) : (y += 1) {
        var x: u32 = 0;
        while (x < new_width) : (x += 1) {
            // Map destination point to source
            const src = inv.transformPoint(@floatFromInt(x), @floatFromInt(y));

            if (src.x >= 0 and src.x < @as(f64, @floatFromInt(img.width)) and
                src.y >= 0 and src.y < @as(f64, @floatFromInt(img.height)))
            {
                // Bilinear interpolation
                const sx0: u32 = @intFromFloat(src.x);
                const sy0: u32 = @intFromFloat(src.y);
                const sx1: u32 = @min(sx0 + 1, img.width - 1);
                const sy1: u32 = @min(sy0 + 1, img.height - 1);

                const fx = src.x - @as(f64, @floatFromInt(sx0));
                const fy = src.y - @as(f64, @floatFromInt(sy0));

                const c00 = img.getPixel(sx0, sy0) orelse background;
                const c10 = img.getPixel(sx1, sy0) orelse background;
                const c01 = img.getPixel(sx0, sy1) orelse background;
                const c11 = img.getPixel(sx1, sy1) orelse background;

                const color = bilinearInterpolate(c00, c10, c01, c11, fx, fy);
                result.setPixel(x, y, color);
            } else {
                result.setPixel(x, y, background);
            }
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "Rotate 90 degrees" {
    var img = try Image.init(std.testing.allocator, 4, 2, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(3, 0, Color.GREEN);

    var rotated = try rotate(&img, .degrees_90);
    defer rotated.deinit();

    try std.testing.expectEqual(@as(u32, 2), rotated.width);
    try std.testing.expectEqual(@as(u32, 4), rotated.height);

    // RED (0,0) should now be at (1,0)
    const pixel = rotated.getPixel(1, 0);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Rotate 270 degrees" {
    var img = try Image.init(std.testing.allocator, 4, 2, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);

    var rotated = try rotate(&img, .degrees_270);
    defer rotated.deinit();

    // RED (0,0) should now be at (0,3).
    const pixel = rotated.getPixel(0, 3);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "Flip vertical" {
    var img = try Image.init(std.testing.allocator, 2, 4, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(0, 3, Color.BLUE);

    var flipped = try flip(&img);
    defer flipped.deinit();

    // RED should now be at bottom, BLUE at top
    const top = flipped.getPixel(0, 0);
    try std.testing.expect(top != null);
    try std.testing.expectEqual(@as(u8, 0), top.?.r);
    try std.testing.expectEqual(@as(u8, 0), top.?.g);
    try std.testing.expectEqual(@as(u8, 255), top.?.b);
}

test "Affine matrix multiplication" {
    const scale = AffineMatrix.scale(2, 2);
    const translate = AffineMatrix.translation(10, 20);

    // Matrix multiplication composes right-to-left.
    const scale_after_translate = scale.multiply(translate);
    const translated_then_scaled = scale_after_translate.transformPoint(5, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 30), translated_then_scaled.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), translated_then_scaled.y, 0.001);

    const translate_after_scale = translate.multiply(scale);
    const scaled_then_translated = translate_after_scale.transformPoint(5, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 20), scaled_then_translated.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), scaled_then_translated.y, 0.001);
}

test "Affine matrix inverse" {
    const scale = AffineMatrix.scale(2, 3);
    const inv = scale.invert();

    try std.testing.expect(inv != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), inv.?.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), inv.?.d, 0.001);
}

test "orthogonal Image operations preserve low words raw indices and independent palette owners" {
    const t = std.testing;
    for ([_]image.PixelFormat{ .rgb8, .rgba8, .grayscale8, .rgb16, .rgba16, .grayscale16, .indexed8 }) |format| {
        var img = try Image.init(t.allocator, 3, 2, format);
        defer img.deinit();
        if (format == .indexed8) img.palette = try t.allocator.dupe(Color, &.{ Color.RED, Color.BLUE });
        for (img.pixels, 0..) |*byte, i| byte.* = if (format == .indexed8) @intCast(i % 2) else @intCast((i * 37 + 0x34) % 256);
        const bpp = format.bytesPerPixel();
        for (0..8) |bits| {
            const transform = try OrthogonalTransform.fromBits(@intCast(bits));
            var result = try orthogonal(&img, transform);
            defer result.deinit();
            try t.expectEqual(if (bits & 4 != 0) @as(u32, 2) else 3, result.width);
            try t.expectEqual(if (bits & 4 != 0) @as(u32, 3) else 2, result.height);
            for (0..2) |y| for (0..3) |x| {
                const sx = if (bits & 1 != 0) 2 - x else x;
                const sy = if (bits & 2 != 0) 1 - y else y;
                const dx = if (bits & 4 != 0) sy else sx;
                const dy = if (bits & 4 != 0) sx else sy;
                try t.expectEqualSlices(u8, img.pixels[(y * 3 + x) * bpp ..][0..bpp], result.pixels[(dy * result.width + dx) * bpp ..][0..bpp]);
            };
            if (format == .indexed8) {
                try t.expectEqualSlices(Color, img.palette.?, result.palette.?);
                result.palette.?[0] = Color.GREEN;
                try t.expectEqual(Color.RED, img.palette.?[0]);
            }
        }
        var vertical = try flip(&img);
        defer vertical.deinit();
        var horizontal = try flop(&img);
        defer horizontal.deinit();
        var in_place = try img.clone();
        defer in_place.deinit();
        flipInPlace(&in_place);
        try t.expectEqualSlices(u8, vertical.pixels, in_place.pixels);
        flipInPlace(&in_place);
        try t.expectEqualSlices(u8, img.pixels, in_place.pixels);
        flopInPlace(&in_place);
        try t.expectEqualSlices(u8, horizontal.pixels, in_place.pixels);
        flopInPlace(&in_place);
        try t.expectEqualSlices(u8, img.pixels, in_place.pixels);
    }
}
fn animatedFixture(a: std.mem.Allocator) !Image {
    var img = try Image.init(a, 5, 4, .grayscale16);
    errdefer img.deinit();
    img.palette = try a.dupe(Color, &.{Color.RED});
    img.loop_count = 7;
    for (img.pixels, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const frames = try a.alloc(Image.Frame, 3);
    errdefer a.free(frames);
    var done: usize = 0;
    errdefer for (frames[0..done]) |frame| a.free(frame.pixels);
    const partial = try a.dupe(u8, &.{ 0x34, 0x12, 0x78, 0x56 });
    frames[0] = .{ .width = 2, .height = 1, .x_offset = 1, .y_offset = 2, .pixels = partial, .delay_ms = 17, .dispose_op = .previous, .blend_op = .over };
    done += 1;
    frames[1] = .{ .pixels = try a.dupe(u8, img.pixels), .delay_ms = 23 };
    done += 1;
    frames[2] = .{ .height = 1, .y_offset = 1, .pixels = try a.dupe(u8, img.pixels[0..10]), .delay_ms = 31, .dispose_op = .background };
    done += 1;
    img.frames = frames;
    return img;
}
fn animationAllocations(a: std.mem.Allocator) !void {
    const t = std.testing;
    var img = try animatedFixture(a);
    defer img.deinit();
    for (0..8) |bits| {
        var result = try orthogonal(&img, try OrthogonalTransform.fromBits(@intCast(bits)));
        defer result.deinit();
        try t.expectEqual(@as(u32, 7), result.loop_count);
        const first = result.frames.?[0];
        try t.expectEqual(@as(u32, 17), first.delay_ms);
        try t.expectEqual(Image.DisposeOp.previous, first.dispose_op);
        try t.expectEqual(Image.BlendOp.over, first.blend_op);
        const x: u32 = if (bits & 1 != 0) 2 else 1;
        const y: u32 = if (bits & 2 != 0) 1 else 2;
        try t.expectEqual(if (bits & 4 != 0) y else x, first.x_offset);
        try t.expectEqual(if (bits & 4 != 0) x else y, first.y_offset);
        try t.expectEqual(@as(?u32, if (bits & 4 != 0) 1 else 2), first.width);
        try t.expectEqual(@as(?u32, if (bits & 4 != 0) 2 else 1), first.height);
        const expected = if (bits & 1 != 0) &[_]u8{ 0x78, 0x56, 0x34, 0x12 } else &[_]u8{ 0x34, 0x12, 0x78, 0x56 };
        try t.expectEqualSlices(u8, expected, first.pixels);
        try t.expectEqual(@as(?u32, null), result.frames.?[1].width);
        try t.expectEqual(@as(?u32, null), result.frames.?[1].height);
        try t.expectEqualSlices(u8, result.pixels, result.frames.?[1].pixels);
        result.frames.?[0].pixels[0] = 0;
        try t.expectEqual(@as(u8, 0x34), img.frames.?[0].pixels[0]);
        result.palette.?[0] = Color.BLUE;
        try t.expectEqual(Color.RED, img.palette.?[0]);
    }
    var vertical = try flip(&img);
    defer vertical.deinit();
    flipInPlace(&img);
    try t.expectEqualSlices(u8, vertical.pixels, img.pixels);
    for (vertical.frames.?, img.frames.?) |expected, actual| {
        try t.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try t.expectEqual(expected.x_offset, actual.x_offset);
        try t.expectEqual(expected.y_offset, actual.y_offset);
    }
    var horizontal = try flop(&img);
    defer horizontal.deinit();
    flopInPlace(&img);
    try t.expectEqualSlices(u8, horizontal.pixels, img.pixels);
    for (horizontal.frames.?, img.frames.?) |expected, actual| {
        try t.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try t.expectEqual(expected.x_offset, actual.x_offset);
        try t.expectEqual(expected.y_offset, actual.y_offset);
    }
}
test "orthogonal Image animation rectangles palette and disposal survive all transforms and allocator failures" {
    try animationAllocations(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, animationAllocations, .{});
}
test "orthogonal malformed late frame rejects allocating and in-place changes before mutating any owner" {
    const t = std.testing;
    var img = try animatedFixture(t.allocator);
    defer img.deinit();
    const before = try img.clone();
    var copy_before = before;
    defer copy_before.deinit();
    img.frames.?[2].x_offset = 1; // null width means full-canvas width, which no longer fits.
    try t.expectError(error.InvalidGeometry, flip(&img));
    flipInPlace(&img);
    flopInPlace(&img);
    try t.expectEqualSlices(u8, before.pixels, img.pixels);
    for (before.frames.?, img.frames.?) |previous, current| try t.expectEqualSlices(u8, previous.pixels, current.pixels);
    try t.expectEqual(@as(u32, 1), img.frames.?[2].x_offset);
}
