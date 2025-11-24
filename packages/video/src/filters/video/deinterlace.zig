// Home Video Library - Deinterlace Filter
// Convert interlaced video to progressive

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Deinterlace Methods
// ============================================================================

pub const DeinterlaceMethod = enum {
    /// Simple line weaving (fast, lower quality)
    weave,
    /// Bob deinterlacing - double frame rate
    bob,
    /// Blend adjacent lines (medium quality)
    blend,
    /// Linear interpolation (good quality)
    linear,
    /// Yadif-style edge-directed interpolation (high quality)
    yadif,
};

pub const FieldOrder = enum {
    /// Top field first (TFF)
    top_first,
    /// Bottom field first (BFF)
    bottom_first,
    /// Auto-detect from frame
    auto,
};

// ============================================================================
// Deinterlace Filter
// ============================================================================

pub const DeinterlaceFilter = struct {
    method: DeinterlaceMethod,
    field_order: FieldOrder,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, method: DeinterlaceMethod) Self {
        return .{
            .method = method,
            .field_order = .auto,
            .allocator = allocator,
        };
    }

    pub fn initWithFieldOrder(allocator: std.mem.Allocator, method: DeinterlaceMethod, field_order: FieldOrder) Self {
        return .{
            .method = method,
            .field_order = field_order,
            .allocator = allocator,
        };
    }

    /// Apply deinterlacing to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        return switch (self.method) {
            .weave => try self.weaveDeinterlace(input),
            .bob => try self.bobDeinterlace(input, true), // Top field
            .blend => try self.blendDeinterlace(input),
            .linear => try self.linearDeinterlace(input),
            .yadif => try self.yadifDeinterlace(input),
        };
    }

    /// Bob deinterlacing with field selection
    pub fn applyBob(self: *const Self, input: *const VideoFrame, top_field: bool) !VideoFrame {
        return try self.bobDeinterlace(input, top_field);
    }

    // ========================================================================
    // Weave Deinterlacing
    // ========================================================================

    fn weaveDeinterlace(self: *const Self, input: *const VideoFrame) !VideoFrame {
        // Weave just returns the frame as-is (combines both fields)
        // This is essentially a copy, but maintains field structure
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        // Copy all planes
        for (0..4) |i| {
            if (input.data[i]) |src| {
                if (output.data[i]) |dst| {
                    const len = @min(src.len, dst.len);
                    @memcpy(dst[0..len], src[0..len]);
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Bob Deinterlacing
    // ========================================================================

    fn bobDeinterlace(self: *const Self, input: *const VideoFrame, top_field: bool) !VideoFrame {
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
                    const is_field_line = if (top_field) (y % 2 == 0) else (y % 2 == 1);

                    if (is_field_line) {
                        // Copy from source field line
                        const src_offset = y * src_stride;
                        const dst_offset = y * dst_stride;
                        const line_bytes = input.width * bytes_per_pixel;

                        if (src_offset + line_bytes <= src.len and dst_offset + line_bytes <= dst.len) {
                            @memcpy(dst[dst_offset..][0..line_bytes], src[src_offset..][0..line_bytes]);
                        }
                    } else {
                        // Interpolate from adjacent field lines
                        const above_y = if (y > 0) y - 1 else y;
                        const below_y = if (y < input.height - 1) y + 1 else y;

                        const above_offset = above_y * src_stride;
                        const below_offset = below_y * src_stride;
                        const dst_offset = y * dst_stride;

                        for (0..input.width * bytes_per_pixel) |x| {
                            if (above_offset + x < src.len and below_offset + x < src.len and dst_offset + x < dst.len) {
                                const above: u16 = src[above_offset + x];
                                const below: u16 = src[below_offset + x];
                                dst[dst_offset + x] = @intCast((above + below) / 2);
                            }
                        }
                    }
                }
            }
        }

        // Handle YUV chroma planes
        if (isYuvPlanar(input.format)) {
            const chroma_subsamp = getChromaSubsampling(input.format);
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const chroma_height = input.height / chroma_subsamp.y;
                        const chroma_width = input.width / chroma_subsamp.x;
                        const src_stride = input.linesize[plane_idx];
                        const dst_stride = output.linesize[plane_idx];

                        for (0..chroma_height) |y| {
                            const is_field_line = if (top_field) (y % 2 == 0) else (y % 2 == 1);

                            if (is_field_line) {
                                const src_offset = y * src_stride;
                                const dst_offset = y * dst_stride;
                                if (src_offset + chroma_width <= src_plane.len and dst_offset + chroma_width <= dst_plane.len) {
                                    @memcpy(dst_plane[dst_offset..][0..chroma_width], src_plane[src_offset..][0..chroma_width]);
                                }
                            } else {
                                const above_y = if (y > 0) y - 1 else y;
                                const below_y = if (y < chroma_height - 1) y + 1 else y;

                                for (0..chroma_width) |x| {
                                    const above_offset = above_y * src_stride + x;
                                    const below_offset = below_y * src_stride + x;
                                    const dst_offset = y * dst_stride + x;

                                    if (above_offset < src_plane.len and below_offset < src_plane.len and dst_offset < dst_plane.len) {
                                        const above: u16 = src_plane[above_offset];
                                        const below: u16 = src_plane[below_offset];
                                        dst_plane[dst_offset] = @intCast((above + below) / 2);
                                    }
                                }
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

    // ========================================================================
    // Blend Deinterlacing
    // ========================================================================

    fn blendDeinterlace(self: *const Self, input: *const VideoFrame) !VideoFrame {
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
                    const above_y = if (y > 0) y - 1 else y;
                    const below_y = if (y < input.height - 1) y + 1 else y;

                    for (0..input.width * bytes_per_pixel) |x| {
                        const curr_offset = y * src_stride + x;
                        const above_offset = above_y * src_stride + x;
                        const below_offset = below_y * src_stride + x;
                        const dst_offset = y * dst_stride + x;

                        if (curr_offset < src.len and above_offset < src.len and below_offset < src.len and dst_offset < dst.len) {
                            const curr: u32 = src[curr_offset];
                            const above: u32 = src[above_offset];
                            const below: u32 = src[below_offset];
                            // 50% current, 25% above, 25% below
                            dst[dst_offset] = @intCast((curr * 2 + above + below) / 4);
                        }
                    }
                }
            }
        }

        // Copy chroma planes (less visible interlacing)
        if (isYuvPlanar(input.format)) {
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const len = @min(src_plane.len, dst_plane.len);
                        @memcpy(dst_plane[0..len], src_plane[0..len]);
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Linear Interpolation Deinterlacing
    // ========================================================================

    fn linearDeinterlace(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const top_field = self.field_order != .bottom_first;

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..input.height) |y| {
                    const is_field_line = if (top_field) (y % 2 == 0) else (y % 2 == 1);

                    if (is_field_line) {
                        // Keep original field lines
                        const src_offset = y * src_stride;
                        const dst_offset = y * dst_stride;
                        const line_bytes = input.width * bytes_per_pixel;

                        if (src_offset + line_bytes <= src.len and dst_offset + line_bytes <= dst.len) {
                            @memcpy(dst[dst_offset..][0..line_bytes], src[src_offset..][0..line_bytes]);
                        }
                    } else {
                        // Linear interpolation from field lines (2 lines apart)
                        const above_y = if (y >= 2) y - 2 else 0;
                        const below_y = if (y + 2 < input.height) y + 2 else input.height - 1;

                        // Also use immediate neighbors for smoother result
                        const near_above_y = if (y > 0) y - 1 else y;
                        const near_below_y = if (y < input.height - 1) y + 1 else y;

                        for (0..input.width * bytes_per_pixel) |x| {
                            const above_offset = above_y * src_stride + x;
                            const below_offset = below_y * src_stride + x;
                            const near_above_offset = near_above_y * src_stride + x;
                            const near_below_offset = near_below_y * src_stride + x;
                            const dst_offset = y * dst_stride + x;

                            if (above_offset < src.len and below_offset < src.len and near_above_offset < src.len and near_below_offset < src.len and dst_offset < dst.len) {
                                const above: u32 = src[above_offset];
                                const below: u32 = src[below_offset];
                                const near_above: u32 = src[near_above_offset];
                                const near_below: u32 = src[near_below_offset];

                                // Weight: 40% near neighbors, 10% far neighbors
                                const result = (near_above * 4 + near_below * 4 + above + below) / 10;
                                dst[dst_offset] = @intCast(@min(255, result));
                            }
                        }
                    }
                }
            }
        }

        // Handle chroma planes similarly
        if (isYuvPlanar(input.format)) {
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const len = @min(src_plane.len, dst_plane.len);
                        @memcpy(dst_plane[0..len], src_plane[0..len]);
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Yadif-style Edge-Directed Interpolation
    // ========================================================================

    fn yadifDeinterlace(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const top_field = self.field_order != .bottom_first;

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const width = input.width;
                const height = input.height;

                for (0..height) |y| {
                    const is_field_line = if (top_field) (y % 2 == 0) else (y % 2 == 1);

                    if (is_field_line) {
                        // Keep original field lines
                        const src_offset = y * src_stride;
                        const dst_offset = y * dst_stride;
                        const line_bytes = width * bytes_per_pixel;

                        if (src_offset + line_bytes <= src.len and dst_offset + line_bytes <= dst.len) {
                            @memcpy(dst[dst_offset..][0..line_bytes], src[src_offset..][0..line_bytes]);
                        }
                    } else {
                        // Edge-directed interpolation
                        const above_y = if (y > 0) y - 1 else y;
                        const below_y = if (y < height - 1) y + 1 else y;

                        for (0..width) |px| {
                            for (0..bytes_per_pixel) |ch| {
                                const x = px * bytes_per_pixel + ch;
                                const dst_offset = y * dst_stride + x;

                                if (dst_offset >= dst.len) continue;

                                // Get vertical neighbors
                                const above_offset = above_y * src_stride + x;
                                const below_offset = below_y * src_stride + x;

                                if (above_offset >= src.len or below_offset >= src.len) continue;

                                const above: i32 = src[above_offset];
                                const below: i32 = src[below_offset];

                                // Calculate spatial prediction
                                var spatial_pred: i32 = (above + below) / 2;

                                // Edge detection - check diagonal neighbors
                                if (px > 0 and px < width - 1) {
                                    const left_above_offset = above_y * src_stride + (px - 1) * bytes_per_pixel + ch;
                                    const right_above_offset = above_y * src_stride + (px + 1) * bytes_per_pixel + ch;
                                    const left_below_offset = below_y * src_stride + (px - 1) * bytes_per_pixel + ch;
                                    const right_below_offset = below_y * src_stride + (px + 1) * bytes_per_pixel + ch;

                                    if (left_above_offset < src.len and right_above_offset < src.len and left_below_offset < src.len and right_below_offset < src.len) {
                                        const left_above: i32 = src[left_above_offset];
                                        const right_above: i32 = src[right_above_offset];
                                        const left_below: i32 = src[left_below_offset];
                                        const right_below: i32 = src[right_below_offset];

                                        // Check for edges
                                        const vert_diff = @abs(above - below);
                                        const diag1_diff = @abs(left_above - right_below);
                                        const diag2_diff = @abs(right_above - left_below);

                                        // Use diagonal interpolation if it has less difference
                                        if (diag1_diff < vert_diff and diag1_diff <= diag2_diff) {
                                            spatial_pred = (left_above + right_below) / 2;
                                        } else if (diag2_diff < vert_diff) {
                                            spatial_pred = (right_above + left_below) / 2;
                                        }
                                    }
                                }

                                // Clamp to valid range
                                dst[dst_offset] = @intCast(@max(0, @min(255, spatial_pred)));
                            }
                        }
                    }
                }
            }
        }

        // Handle chroma planes
        if (isYuvPlanar(input.format)) {
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const len = @min(src_plane.len, dst_plane.len);
                        @memcpy(dst_plane[0..len], src_plane[0..len]);
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }
};

// ============================================================================
// Field Separator - Extract single field
// ============================================================================

pub const FieldSeparator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Extract a single field (half height)
    pub fn extractField(self: *const Self, input: *const VideoFrame, top_field: bool) !VideoFrame {
        const new_height = input.height / 2;

        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            new_height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..new_height) |y| {
                    const src_y = y * 2 + (if (top_field) @as(usize, 0) else @as(usize, 1));
                    const src_offset = src_y * src_stride;
                    const dst_offset = y * dst_stride;
                    const line_bytes = input.width * bytes_per_pixel;

                    if (src_offset + line_bytes <= src.len and dst_offset + line_bytes <= dst.len) {
                        @memcpy(dst[dst_offset..][0..line_bytes], src[src_offset..][0..line_bytes]);
                    }
                }
            }
        }

        // Handle chroma planes for YUV
        if (isYuvPlanar(input.format)) {
            const chroma_subsamp = getChromaSubsampling(input.format);
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const src_chroma_height = input.height / chroma_subsamp.y;
                        const new_chroma_height = new_height / chroma_subsamp.y;
                        const chroma_width = input.width / chroma_subsamp.x;
                        const src_stride = input.linesize[plane_idx];
                        const dst_stride = output.linesize[plane_idx];

                        for (0..new_chroma_height) |y| {
                            const src_y = @min(y * 2 + (if (top_field) @as(usize, 0) else @as(usize, 1)), src_chroma_height - 1);
                            const src_offset = src_y * src_stride;
                            const dst_offset = y * dst_stride;

                            if (src_offset + chroma_width <= src_plane.len and dst_offset + chroma_width <= dst_plane.len) {
                                @memcpy(dst_plane[dst_offset..][0..chroma_width], src_plane[src_offset..][0..chroma_width]);
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

    /// Combine two fields into one frame
    pub fn combineFields(self: *const Self, top_field: *const VideoFrame, bottom_field: *const VideoFrame) !VideoFrame {
        const new_height = top_field.height * 2;

        var output = try VideoFrame.init(
            self.allocator,
            top_field.width,
            new_height,
            top_field.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(top_field.format);

        // Interleave top and bottom fields
        if (top_field.data[0]) |top_src| {
            if (bottom_field.data[0]) |bottom_src| {
                if (output.data[0]) |dst| {
                    const top_stride = top_field.linesize[0];
                    const bottom_stride = bottom_field.linesize[0];
                    const dst_stride = output.linesize[0];

                    for (0..top_field.height) |y| {
                        // Top field line
                        const top_offset = y * top_stride;
                        const dst_top_offset = (y * 2) * dst_stride;
                        const line_bytes = top_field.width * bytes_per_pixel;

                        if (top_offset + line_bytes <= top_src.len and dst_top_offset + line_bytes <= dst.len) {
                            @memcpy(dst[dst_top_offset..][0..line_bytes], top_src[top_offset..][0..line_bytes]);
                        }

                        // Bottom field line
                        const bottom_offset = y * bottom_stride;
                        const dst_bottom_offset = (y * 2 + 1) * dst_stride;

                        if (bottom_offset + line_bytes <= bottom_src.len and dst_bottom_offset + line_bytes <= dst.len) {
                            @memcpy(dst[dst_bottom_offset..][0..line_bytes], bottom_src[bottom_offset..][0..line_bytes]);
                        }
                    }
                }
            }
        }

        output.pts = top_field.pts;
        output.dts = top_field.dts;
        output.duration = top_field.duration;
        return output;
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

const ChromaSubsampling = struct { x: usize, y: usize };

fn getChromaSubsampling(format: PixelFormat) ChromaSubsampling {
    return switch (format) {
        .yuv420p => .{ .x = 2, .y = 2 },
        .yuv422p => .{ .x = 2, .y = 1 },
        .yuv444p => .{ .x = 1, .y = 1 },
        else => .{ .x = 1, .y = 1 },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "DeinterlaceFilter initialization" {
    const allocator = std.testing.allocator;

    const filter = DeinterlaceFilter.init(allocator, .bob);
    try std.testing.expectEqual(DeinterlaceMethod.bob, filter.method);
    try std.testing.expectEqual(FieldOrder.auto, filter.field_order);

    const filter2 = DeinterlaceFilter.initWithFieldOrder(allocator, .yadif, .top_first);
    try std.testing.expectEqual(DeinterlaceMethod.yadif, filter2.method);
    try std.testing.expectEqual(FieldOrder.top_first, filter2.field_order);
}

test "FieldSeparator initialization" {
    const allocator = std.testing.allocator;
    const separator = FieldSeparator.init(allocator);
    _ = separator;
}

test "DeinterlaceMethod enum" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(DeinterlaceMethod).@"enum".fields.len);
}

test "FieldOrder enum" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(FieldOrder).@"enum".fields.len);
}
