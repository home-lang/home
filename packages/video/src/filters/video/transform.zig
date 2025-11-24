// Home Video Library - Transform Filters
// Rotation, flip, and transpose operations

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Rotation Angle
// ============================================================================

pub const RotationAngle = enum {
    rotate_90,
    rotate_180,
    rotate_270,
};

// ============================================================================
// Flip Direction
// ============================================================================

pub const FlipDirection = enum {
    horizontal,
    vertical,
    both,
};

// ============================================================================
// Rotate Filter
// ============================================================================

pub const RotateFilter = struct {
    angle: RotationAngle,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, angle: RotationAngle) Self {
        return .{
            .angle = angle,
            .allocator = allocator,
        };
    }

    /// Apply rotation to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        return switch (self.angle) {
            .rotate_90 => try self.rotate90(input),
            .rotate_180 => try self.rotate180(input),
            .rotate_270 => try self.rotate270(input),
        };
    }

    fn rotate90(self: *const Self, input: *const VideoFrame) !VideoFrame {
        // 90 degrees clockwise: new_width = old_height, new_height = old_width
        var output = try VideoFrame.init(
            self.allocator,
            input.height, // swapped
            input.width, // swapped
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        // Rotate Y/RGB plane
        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        // (x, y) -> (height - 1 - y, x) for 90° CW
                        const new_x = input.height - 1 - y;
                        const new_y = x;

                        const src_offset = y * src_stride + x * bytes_per_pixel;
                        const dst_offset = new_y * dst_stride + new_x * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src.len and dst_offset + i < dst.len) {
                                dst[dst_offset + i] = src[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        // Rotate chroma planes for YUV formats
        if (isYuvPlanar(input.format)) {
            try self.rotateChromaPlanes90(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn rotate180(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        const new_x = input.width - 1 - x;
                        const new_y = input.height - 1 - y;

                        const src_offset = y * src_stride + x * bytes_per_pixel;
                        const dst_offset = new_y * dst_stride + new_x * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src.len and dst_offset + i < dst.len) {
                                dst[dst_offset + i] = src[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        if (isYuvPlanar(input.format)) {
            try self.rotateChromaPlanes180(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn rotate270(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.height,
            input.width,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        // (x, y) -> (y, width - 1 - x) for 270° CW (90° CCW)
                        const new_x = y;
                        const new_y = input.width - 1 - x;

                        const src_offset = y * src_stride + x * bytes_per_pixel;
                        const dst_offset = new_y * dst_stride + new_x * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src.len and dst_offset + i < dst.len) {
                                dst[dst_offset + i] = src[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        if (isYuvPlanar(input.format)) {
            try self.rotateChromaPlanes270(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn rotateChromaPlanes90(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        _ = self;
        const chroma_width_in = getChromaWidth(input.format, input.width);
        const chroma_height_in = getChromaHeight(input.format, input.height);

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height_in) |y| {
                        for (0..chroma_width_in) |x| {
                            const new_x = chroma_height_in - 1 - y;
                            const new_y = x;

                            const src_offset = y * src_stride + x;
                            const dst_offset = new_y * dst_stride + new_x;

                            if (src_offset < src.len and dst_offset < dst.len) {
                                dst[dst_offset] = src[src_offset];
                            }
                        }
                    }
                }
            }
        }
    }

    fn rotateChromaPlanes180(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        _ = self;
        const chroma_width = getChromaWidth(input.format, input.width);
        const chroma_height = getChromaHeight(input.format, input.height);

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height) |y| {
                        for (0..chroma_width) |x| {
                            const new_x = chroma_width - 1 - x;
                            const new_y = chroma_height - 1 - y;

                            const src_offset = y * src_stride + x;
                            const dst_offset = new_y * dst_stride + new_x;

                            if (src_offset < src.len and dst_offset < dst.len) {
                                dst[dst_offset] = src[src_offset];
                            }
                        }
                    }
                }
            }
        }
    }

    fn rotateChromaPlanes270(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        _ = self;
        const chroma_width_in = getChromaWidth(input.format, input.width);
        const chroma_height_in = getChromaHeight(input.format, input.height);

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height_in) |y| {
                        for (0..chroma_width_in) |x| {
                            const new_x = y;
                            const new_y = chroma_width_in - 1 - x;

                            const src_offset = y * src_stride + x;
                            const dst_offset = new_y * dst_stride + new_x;

                            if (src_offset < src.len and dst_offset < dst.len) {
                                dst[dst_offset] = src[src_offset];
                            }
                        }
                    }
                }
            }
        }
    }
};

// ============================================================================
// Flip Filter
// ============================================================================

pub const FlipFilter = struct {
    direction: FlipDirection,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, direction: FlipDirection) Self {
        return .{
            .direction = direction,
            .allocator = allocator,
        };
    }

    /// Apply flip to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        const new_x: usize = switch (self.direction) {
                            .horizontal, .both => input.width - 1 - x,
                            .vertical => x,
                        };
                        const new_y: usize = switch (self.direction) {
                            .vertical, .both => input.height - 1 - y,
                            .horizontal => y,
                        };

                        const src_offset = y * src_stride + x * bytes_per_pixel;
                        const dst_offset = new_y * dst_stride + new_x * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src.len and dst_offset + i < dst.len) {
                                dst[dst_offset + i] = src[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        if (isYuvPlanar(input.format)) {
            try self.flipChromaPlanes(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn flipChromaPlanes(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        const chroma_width = getChromaWidth(input.format, input.width);
        const chroma_height = getChromaHeight(input.format, input.height);

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height) |y| {
                        for (0..chroma_width) |x| {
                            const new_x: usize = switch (self.direction) {
                                .horizontal, .both => chroma_width - 1 - x,
                                .vertical => x,
                            };
                            const new_y: usize = switch (self.direction) {
                                .vertical, .both => chroma_height - 1 - y,
                                .horizontal => y,
                            };

                            const src_offset = y * src_stride + x;
                            const dst_offset = new_y * dst_stride + new_x;

                            if (src_offset < src.len and dst_offset < dst.len) {
                                dst[dst_offset] = src[src_offset];
                            }
                        }
                    }
                }
            }
        }
    }
};

// ============================================================================
// Transpose Filter
// ============================================================================

pub const TransposeFilter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Transpose a video frame (swap x and y coordinates)
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.height, // swapped
            input.width, // swapped
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        const src_offset = y * src_stride + x * bytes_per_pixel;
                        const dst_offset = x * dst_stride + y * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src.len and dst_offset + i < dst.len) {
                                dst[dst_offset + i] = src[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        if (isYuvPlanar(input.format)) {
            try self.transposeChromaPlanes(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn transposeChromaPlanes(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        _ = self;
        const chroma_width_in = getChromaWidth(input.format, input.width);
        const chroma_height_in = getChromaHeight(input.format, input.height);

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height_in) |y| {
                        for (0..chroma_width_in) |x| {
                            const src_offset = y * src_stride + x;
                            const dst_offset = x * dst_stride + y;

                            if (src_offset < src.len and dst_offset < dst.len) {
                                dst[dst_offset] = src[src_offset];
                            }
                        }
                    }
                }
            }
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getBytesPerPixel(format: PixelFormat) usize {
    return switch (format) {
        .rgb24, .bgr24 => 3,
        .rgba32, .bgra32, .argb32, .abgr32 => 4,
        else => 1,
    };
}

fn isYuvPlanar(format: PixelFormat) bool {
    return switch (format) {
        .yuv420p, .yuv422p, .yuv444p => true,
        else => false,
    };
}

fn getChromaWidth(format: PixelFormat, luma_width: u32) usize {
    return switch (format) {
        .yuv420p, .yuv422p => luma_width / 2,
        else => luma_width,
    };
}

fn getChromaHeight(format: PixelFormat, luma_height: u32) usize {
    return switch (format) {
        .yuv420p => luma_height / 2,
        else => luma_height,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "RotateFilter initialization" {
    const allocator = std.testing.allocator;

    const filter90 = RotateFilter.init(allocator, .rotate_90);
    try std.testing.expectEqual(RotationAngle.rotate_90, filter90.angle);

    const filter180 = RotateFilter.init(allocator, .rotate_180);
    try std.testing.expectEqual(RotationAngle.rotate_180, filter180.angle);

    const filter270 = RotateFilter.init(allocator, .rotate_270);
    try std.testing.expectEqual(RotationAngle.rotate_270, filter270.angle);
}

test "FlipFilter initialization" {
    const allocator = std.testing.allocator;

    const filter_h = FlipFilter.init(allocator, .horizontal);
    try std.testing.expectEqual(FlipDirection.horizontal, filter_h.direction);

    const filter_v = FlipFilter.init(allocator, .vertical);
    try std.testing.expectEqual(FlipDirection.vertical, filter_v.direction);

    const filter_both = FlipFilter.init(allocator, .both);
    try std.testing.expectEqual(FlipDirection.both, filter_both.direction);
}

test "TransposeFilter initialization" {
    const allocator = std.testing.allocator;
    _ = TransposeFilter.init(allocator);
}

test "Helper functions" {
    try std.testing.expectEqual(@as(usize, 3), getBytesPerPixel(.rgb24));
    try std.testing.expectEqual(@as(usize, 4), getBytesPerPixel(.rgba32));
    try std.testing.expectEqual(@as(usize, 1), getBytesPerPixel(.yuv420p));

    try std.testing.expect(isYuvPlanar(.yuv420p));
    try std.testing.expect(!isYuvPlanar(.rgb24));

    try std.testing.expectEqual(@as(usize, 960), getChromaWidth(.yuv420p, 1920));
    try std.testing.expectEqual(@as(usize, 540), getChromaHeight(.yuv420p, 1080));
}
