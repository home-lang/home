// Home Video Library - Filter Tests
// Unit tests for video and audio filters

const std = @import("std");
const testing = std.testing;
const video = @import("video");

// ============================================================================
// Video Filter Tests
// ============================================================================

test "Filter - Scale nearest neighbor" {
    const allocator = testing.allocator;

    // Create test frame
    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.ScaleFilter{
        .width = 50,
        .height = 50,
        .algorithm = video.ScaleAlgorithm.nearest,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(@as(u32, 50), dst.width);
    try testing.expectEqual(@as(u32, 50), dst.height);
}

test "Filter - Crop" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.CropFilter{
        .x = 10,
        .y = 10,
        .width = 50,
        .height = 50,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(@as(u32, 50), dst.width);
    try testing.expectEqual(@as(u32, 50), dst.height);
}

test "Filter - Grayscale" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 10, 10, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.GrayscaleFilter{};

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Rotate 90 degrees" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 50, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.RotateFilter{
        .angle = video.RotationAngle.rotate_90,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    // 90 degree rotation swaps dimensions
    try testing.expectEqual(@as(u32, 50), dst.width);
    try testing.expectEqual(@as(u32, 100), dst.height);
}

test "Filter - Rotate 180 degrees" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 50, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.RotateFilter{
        .angle = video.RotationAngle.rotate_180,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    // 180 degree rotation preserves dimensions
    try testing.expectEqual(@as(u32, 100), dst.width);
    try testing.expectEqual(@as(u32, 50), dst.height);
}

test "Filter - Flip horizontal" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 10, 10, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.FlipFilter{
        .direction = video.FlipDirection.horizontal,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Flip vertical" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 10, 10, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.FlipFilter{
        .direction = video.FlipDirection.vertical,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Color adjustment" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 10, 10, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.ColorFilter{
        .adjustment = video.ColorAdjustment{
            .brightness = 0.1,
            .contrast = 1.2,
            .saturation = 1.1,
            .hue = 0.0,
        },
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Invert colors" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 10, 10, video.PixelFormat.rgb24);
    defer src.deinit();

    // Fill with white
    for (0..10) |y| {
        for (0..10) |x| {
            const idx = (y * 10 + x) * 3;
            src.data[0][idx] = 255; // R
            src.data[0][idx + 1] = 255; // G
            src.data[0][idx + 2] = 255; // B
        }
    }

    var filter = video.InvertFilter{};
    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    // Should be black after inversion
    try testing.expectEqual(@as(u8, 0), dst.data[0][0]);
    try testing.expectEqual(@as(u8, 0), dst.data[0][1]);
    try testing.expectEqual(@as(u8, 0), dst.data[0][2]);
}

test "Filter - Blur" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.BlurFilter{ .sigma = 1.5 };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Sharpen" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.SharpenFilter{
        .sigma = 1.0,
        .flat = 1.0,
        .jagged = 2.0,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Edge detection" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.EdgeDetectionFilter{};

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Convolution 3x3" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    // Sharpen kernel
    const kernel = video.Kernel{
        .size = 3,
        .data = &[_]f32{
            0, -1, 0,
            -1, 5, -1,
            0, -1, 0,
        },
        .divisor = 1.0,
        .bias = 0.0,
    };

    var filter = video.ConvolutionFilter{ .kernel = kernel };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Deinterlace blend" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.DeinterlaceFilter{
        .method = video.DeinterlaceMethod.blend,
        .field_order = video.FieldOrder.top_first,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

test "Filter - Denoise temporal" {
    const allocator = testing.allocator;

    var src = try video.VideoFrame.init(allocator, 100, 100, video.PixelFormat.rgb24);
    defer src.deinit();

    var filter = video.DenoiseFilter{
        .method = video.DenoiseMethod.temporal,
        .strength = 0.5,
    };

    var dst = try filter.apply(allocator, &src);
    defer dst.deinit();

    try testing.expectEqual(src.width, dst.width);
    try testing.expectEqual(src.height, dst.height);
}

// ============================================================================
// Color Space Conversion Tests
// ============================================================================

test "ColorSpace - RGB to YUV" {
    const r: u8 = 255;
    const g: u8 = 128;
    const b: u8 = 64;

    var converter = video.ColorSpaceConverter{
        .src_standard = video.ColorStandard.bt709,
        .dst_standard = video.ColorStandard.bt709,
    };

    const yuv = converter.rgbToYuv(r, g, b);

    // Basic sanity checks
    try testing.expect(yuv.y >= 0 and yuv.y <= 255);
    try testing.expect(yuv.u >= 0 and yuv.u <= 255);
    try testing.expect(yuv.v >= 0 and yuv.v <= 255);
}

test "ColorSpace - YUV to RGB" {
    const y: u8 = 128;
    const u: u8 = 128;
    const v: u8 = 128;

    var converter = video.ColorSpaceConverter{
        .src_standard = video.ColorStandard.bt709,
        .dst_standard = video.ColorStandard.bt709,
    };

    const rgb = converter.yuvToRgb(y, u, v);

    // Basic sanity checks
    try testing.expect(rgb.r >= 0 and rgb.r <= 255);
    try testing.expect(rgb.g >= 0 and rgb.g <= 255);
    try testing.expect(rgb.b >= 0 and rgb.b <= 255);
}

test "ColorSpace - Round trip RGB->YUV->RGB" {
    const orig_r: u8 = 200;
    const orig_g: u8 = 150;
    const orig_b: u8 = 100;

    var converter = video.ColorSpaceConverter{
        .src_standard = video.ColorStandard.bt709,
        .dst_standard = video.ColorStandard.bt709,
    };

    const yuv = converter.rgbToYuv(orig_r, orig_g, orig_b);
    const rgb = converter.yuvToRgb(yuv.y, yuv.u, yuv.v);

    // Allow some error due to rounding
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(orig_r)), @as(f32, @floatFromInt(rgb.r)), 2.0);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(orig_g)), @as(f32, @floatFromInt(rgb.g)), 2.0);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(orig_b)), @as(f32, @floatFromInt(rgb.b)), 2.0);
}

// ============================================================================
// Pixel Format Tests
// ============================================================================

test "PixelFormat - Has alpha" {
    try testing.expect(video.PixelFormat.rgba32.hasAlpha());
    try testing.expect(!video.PixelFormat.rgb24.hasAlpha());
    try testing.expect(!video.PixelFormat.yuv420p.hasAlpha());
}

test "PixelFormat - Plane count" {
    try testing.expectEqual(@as(u8, 1), video.PixelFormat.rgb24.planeCount());
    try testing.expectEqual(@as(u8, 1), video.PixelFormat.rgba32.planeCount());
    try testing.expectEqual(@as(u8, 3), video.PixelFormat.yuv420p.planeCount());
    try testing.expectEqual(@as(u8, 3), video.PixelFormat.yuv422p.planeCount());
    try testing.expectEqual(@as(u8, 3), video.PixelFormat.yuv444p.planeCount());
}

test "PixelFormat - Bits per pixel" {
    try testing.expectEqual(@as(u8, 24), video.PixelFormat.rgb24.bitsPerPixel());
    try testing.expectEqual(@as(u8, 32), video.PixelFormat.rgba32.bitsPerPixel());
    try testing.expectEqual(@as(u8, 12), video.PixelFormat.yuv420p.bitsPerPixel());
    try testing.expectEqual(@as(u8, 8), video.PixelFormat.gray8.bitsPerPixel());
}

// ============================================================================
// Audio Filter Tests
// ============================================================================

test "Audio Filter - Volume" {
    const allocator = testing.allocator;

    var frame = try video.AudioFrame.init(allocator, 1, 100, video.SampleFormat.f32le, 48000);
    defer frame.deinit();

    var filter = video.VolumeFilter{ .gain_db = 0.0 };
    var result = try filter.apply(allocator, &frame);
    defer result.deinit();

    try testing.expectEqual(frame.num_samples, result.num_samples);
}

test "Audio Filter - Channel mixer" {
    const allocator = testing.allocator;

    var frame = try video.AudioFrame.init(allocator, 2, 100, video.SampleFormat.f32le, 48000);
    defer frame.deinit();

    var filter = video.ChannelMixer{
        .src_layout = video.ChannelLayout.stereo,
        .dst_layout = video.ChannelLayout.mono,
    };

    var result = try filter.apply(allocator, &frame);
    defer result.deinit();

    try testing.expectEqual(@as(u8, 1), result.channels);
}
