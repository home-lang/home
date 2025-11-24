// Home Video Library - Crop Filter
// Crops a video frame to a specified region

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Crop Filter
// ============================================================================

pub const CropFilter = struct {
    /// X offset from left edge
    x: u32,
    /// Y offset from top edge
    y: u32,
    /// Output width
    width: u32,
    /// Output height
    height: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, x: u32, y: u32, width: u32, height: u32) Self {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Create a centered crop
    pub fn initCentered(allocator: std.mem.Allocator, src_width: u32, src_height: u32, width: u32, height: u32) !Self {
        if (width > src_width or height > src_height) {
            return VideoError.InvalidDimensions;
        }

        const x = (src_width - width) / 2;
        const y = (src_height - height) / 2;

        return Self.init(allocator, x, y, width, height);
    }

    /// Apply crop to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        // Validate crop region
        if (self.x + self.width > input.width or
            self.y + self.height > input.height)
        {
            return VideoError.InvalidDimensions;
        }

        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        // Copy Y plane (or RGB)
        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const bytes_per_pixel = getBytesPerPixel(input.format);
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..self.height) |dst_y| {
                    const src_y = self.y + @as(u32, @intCast(dst_y));
                    const src_offset = src_y * src_stride + self.x * bytes_per_pixel;
                    const dst_offset = dst_y * dst_stride;
                    const row_bytes = self.width * bytes_per_pixel;

                    if (src_offset + row_bytes <= src_plane.len and
                        dst_offset + row_bytes <= dst_plane.len)
                    {
                        @memcpy(
                            dst_plane[dst_offset..][0..row_bytes],
                            src_plane[src_offset..][0..row_bytes],
                        );
                    }
                }
            }
        }

        // Handle UV planes for YUV formats
        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            const chroma_x = getChromaOffset(input.format, self.x);
            const chroma_y = getChromaOffset(input.format, self.y);
            const chroma_width = getChromaDim(input.format, self.width);
            const chroma_height = getChromaDimY(input.format, self.height);

            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const src_stride = input.linesize[plane_idx];
                        const dst_stride = output.linesize[plane_idx];

                        for (0..chroma_height) |dst_y| {
                            const src_y_idx = chroma_y + dst_y;
                            const src_offset = src_y_idx * src_stride + chroma_x;
                            const dst_offset = dst_y * dst_stride;

                            if (src_offset + chroma_width <= src_plane.len and
                                dst_offset + chroma_width <= dst_plane.len)
                            {
                                @memcpy(
                                    dst_plane[dst_offset..][0..chroma_width],
                                    src_plane[src_offset..][0..chroma_width],
                                );
                            }
                        }
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    /// Get the output dimensions
    pub fn getOutputSize(self: *const Self) struct { width: u32, height: u32 } {
        return .{ .width = self.width, .height = self.height };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getBytesPerPixel(format: PixelFormat) usize {
    return switch (format) {
        .rgb24, .bgr24 => 3,
        .rgba32, .bgra32, .argb32, .abgr32 => 4,
        .gray8 => 1,
        else => 1,
    };
}

fn getChromaOffset(format: PixelFormat, luma_offset: u32) usize {
    return switch (format) {
        .yuv420p, .yuv422p => luma_offset / 2,
        else => luma_offset,
    };
}

fn getChromaDim(format: PixelFormat, luma_dim: u32) usize {
    return switch (format) {
        .yuv420p, .yuv422p => luma_dim / 2,
        else => luma_dim,
    };
}

fn getChromaDimY(format: PixelFormat, luma_height: u32) usize {
    return switch (format) {
        .yuv420p => luma_height / 2,
        else => luma_height,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "CropFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = CropFilter.init(allocator, 100, 50, 800, 600);

    try std.testing.expectEqual(@as(u32, 100), filter.x);
    try std.testing.expectEqual(@as(u32, 50), filter.y);
    try std.testing.expectEqual(@as(u32, 800), filter.width);
    try std.testing.expectEqual(@as(u32, 600), filter.height);
}

test "CropFilter centered" {
    const allocator = std.testing.allocator;
    const filter = try CropFilter.initCentered(allocator, 1920, 1080, 1280, 720);

    try std.testing.expectEqual(@as(u32, 320), filter.x);
    try std.testing.expectEqual(@as(u32, 180), filter.y);
}

test "CropFilter invalid centered" {
    const allocator = std.testing.allocator;
    const result = CropFilter.initCentered(allocator, 800, 600, 1920, 1080);
    try std.testing.expectError(VideoError.InvalidDimensions, result);
}

test "CropFilter output size" {
    const allocator = std.testing.allocator;
    const filter = CropFilter.init(allocator, 0, 0, 640, 480);
    const size = filter.getOutputSize();

    try std.testing.expectEqual(@as(u32, 640), size.width);
    try std.testing.expectEqual(@as(u32, 480), size.height);
}
