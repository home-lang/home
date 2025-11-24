// Home Video Library - Thumbnail/Frame Extraction
// Extract video frames and export as images
// Uses the image package for encoding (JPEG, PNG, BMP, WebP)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Thumbnail Extraction
// ============================================================================

/// Output format for extracted thumbnails
pub const ThumbnailFormat = enum {
    jpeg,
    png,
    bmp,
    webp,

    pub fn extension(self: ThumbnailFormat) []const u8 {
        return switch (self) {
            .jpeg => "jpg",
            .png => "png",
            .bmp => "bmp",
            .webp => "webp",
        };
    }

    pub fn mimeType(self: ThumbnailFormat) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .bmp => "image/bmp",
            .webp => "image/webp",
        };
    }
};

/// Options for thumbnail extraction
pub const ThumbnailOptions = struct {
    format: ThumbnailFormat = .jpeg,
    quality: u8 = 80, // 1-100 for JPEG/WebP
    max_width: ?u32 = null, // Scale down if larger
    max_height: ?u32 = null,
    preserve_aspect: bool = true,
};

/// Represents an extracted frame ready for encoding
pub const ExtractedFrame = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGB24 format
    pts: i64 = 0, // Presentation timestamp
    allocator: Allocator,

    pub fn deinit(self: *ExtractedFrame) void {
        self.allocator.free(self.pixels);
    }

    /// Scale the frame to fit within max dimensions
    pub fn scale(self: *ExtractedFrame, max_width: u32, max_height: u32, preserve_aspect: bool) !void {
        if (self.width <= max_width and self.height <= max_height) return;

        var new_width = max_width;
        var new_height = max_height;

        if (preserve_aspect) {
            const aspect = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
            if (self.width > self.height) {
                new_width = max_width;
                new_height = @intFromFloat(@as(f32, @floatFromInt(max_width)) / aspect);
            } else {
                new_height = max_height;
                new_width = @intFromFloat(@as(f32, @floatFromInt(max_height)) * aspect);
            }
        }

        // Allocate new buffer
        const new_size = new_width * new_height * 3;
        const new_pixels = try self.allocator.alloc(u8, new_size);
        errdefer self.allocator.free(new_pixels);

        // Simple bilinear scaling
        bilinearScale(self.pixels, self.width, self.height, new_pixels, new_width, new_height);

        // Replace old buffer
        self.allocator.free(self.pixels);
        self.pixels = new_pixels;
        self.width = new_width;
        self.height = new_height;
    }
};

/// Bilinear interpolation for scaling
fn bilinearScale(
    src: []const u8,
    src_width: u32,
    src_height: u32,
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_width - 1)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src_height - 1)) / @as(f32, @floatFromInt(dst_height));

    var y: u32 = 0;
    while (y < dst_height) : (y += 1) {
        var x: u32 = 0;
        while (x < dst_width) : (x += 1) {
            const src_x = @as(f32, @floatFromInt(x)) * x_ratio;
            const src_y = @as(f32, @floatFromInt(y)) * y_ratio;

            const x_low = @as(u32, @intFromFloat(src_x));
            const y_low = @as(u32, @intFromFloat(src_y));
            const x_high = @min(x_low + 1, src_width - 1);
            const y_high = @min(y_low + 1, src_height - 1);

            const x_weight = src_x - @as(f32, @floatFromInt(x_low));
            const y_weight = src_y - @as(f32, @floatFromInt(y_low));

            const dst_idx = (y * dst_width + x) * 3;

            // Interpolate each channel
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const tl = src[(y_low * src_width + x_low) * 3 + c];
                const tr = src[(y_low * src_width + x_high) * 3 + c];
                const bl = src[(y_high * src_width + x_low) * 3 + c];
                const br = src[(y_high * src_width + x_high) * 3 + c];

                const top = @as(f32, @floatFromInt(tl)) * (1 - x_weight) + @as(f32, @floatFromInt(tr)) * x_weight;
                const bottom = @as(f32, @floatFromInt(bl)) * (1 - x_weight) + @as(f32, @floatFromInt(br)) * x_weight;
                const value = top * (1 - y_weight) + bottom * y_weight;

                dst[dst_idx + c] = @intFromFloat(std.math.clamp(value, 0, 255));
            }
        }
    }
}

// ============================================================================
// Frame Position Helpers
// ============================================================================

/// Calculate frame positions for thumbnail grid
pub fn calculateGridPositions(
    total_duration_ms: u64,
    count: u32,
    skip_start_ms: u64,
    skip_end_ms: u64,
) ![]u64 {
    const allocator = std.heap.page_allocator;

    if (total_duration_ms <= skip_start_ms + skip_end_ms) {
        return error.InvalidDuration;
    }

    const effective_duration = total_duration_ms - skip_start_ms - skip_end_ms;
    const interval = effective_duration / (count + 1);

    var positions = try allocator.alloc(u64, count);
    errdefer allocator.free(positions);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        positions[i] = skip_start_ms + interval * (i + 1);
    }

    return positions;
}

/// Calculate position for a single thumbnail at percentage
pub fn calculatePercentagePosition(total_duration_ms: u64, percentage: f32) u64 {
    const clamped = std.math.clamp(percentage, 0.0, 100.0);
    return @intFromFloat(@as(f64, @floatFromInt(total_duration_ms)) * clamped / 100.0);
}

// ============================================================================
// YUV to RGB Conversion
// ============================================================================

/// Convert YUV420P frame to RGB24
pub fn yuv420pToRgb24(
    y_plane: []const u8,
    u_plane: []const u8,
    v_plane: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) ![]u8 {
    const rgb_size = width * height * 3;
    var rgb = try allocator.alloc(u8, rgb_size);
    errdefer allocator.free(rgb);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y_idx = row * width + col;
            const uv_idx = (row / 2) * (width / 2) + (col / 2);
            const rgb_idx = (row * width + col) * 3;

            const y: i32 = y_plane[y_idx];
            const u: i32 = @as(i32, u_plane[uv_idx]) - 128;
            const v: i32 = @as(i32, v_plane[uv_idx]) - 128;

            // BT.601 conversion
            var r = y + ((351 * v) >> 8);
            var g = y - ((179 * v + 86 * u) >> 8);
            var b = y + ((443 * u) >> 8);

            r = std.math.clamp(r, 0, 255);
            g = std.math.clamp(g, 0, 255);
            b = std.math.clamp(b, 0, 255);

            rgb[rgb_idx] = @intCast(r);
            rgb[rgb_idx + 1] = @intCast(g);
            rgb[rgb_idx + 2] = @intCast(b);
        }
    }

    return rgb;
}

/// Convert NV12 frame to RGB24
pub fn nv12ToRgb24(
    y_plane: []const u8,
    uv_plane: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) ![]u8 {
    const rgb_size = width * height * 3;
    var rgb = try allocator.alloc(u8, rgb_size);
    errdefer allocator.free(rgb);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y_idx = row * width + col;
            const uv_row = row / 2;
            const uv_col = (col / 2) * 2;
            const uv_idx = uv_row * width + uv_col;
            const rgb_idx = (row * width + col) * 3;

            const y: i32 = y_plane[y_idx];
            const u: i32 = @as(i32, uv_plane[uv_idx]) - 128;
            const v: i32 = @as(i32, uv_plane[uv_idx + 1]) - 128;

            var r = y + ((351 * v) >> 8);
            var g = y - ((179 * v + 86 * u) >> 8);
            var b = y + ((443 * u) >> 8);

            r = std.math.clamp(r, 0, 255);
            g = std.math.clamp(g, 0, 255);
            b = std.math.clamp(b, 0, 255);

            rgb[rgb_idx] = @intCast(r);
            rgb[rgb_idx + 1] = @intCast(g);
            rgb[rgb_idx + 2] = @intCast(b);
        }
    }

    return rgb;
}

// ============================================================================
// Sprite Sheet Generation
// ============================================================================

/// Generate a sprite sheet from multiple frames
pub const SpriteSheet = struct {
    width: u32,
    height: u32,
    columns: u32,
    rows: u32,
    frame_width: u32,
    frame_height: u32,
    pixels: []u8,
    allocator: Allocator,

    pub fn deinit(self: *SpriteSheet) void {
        self.allocator.free(self.pixels);
    }
};

/// Create a sprite sheet from extracted frames
pub fn createSpriteSheet(
    frames: []const ExtractedFrame,
    columns: u32,
    allocator: Allocator,
) !SpriteSheet {
    if (frames.len == 0) return error.NoFrames;

    const frame_width = frames[0].width;
    const frame_height = frames[0].height;
    const rows = (@as(u32, @intCast(frames.len)) + columns - 1) / columns;

    const sheet_width = frame_width * columns;
    const sheet_height = frame_height * rows;
    const sheet_size = sheet_width * sheet_height * 3;

    var pixels = try allocator.alloc(u8, sheet_size);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    // Copy frames into sprite sheet
    for (frames, 0..) |frame, i| {
        const col = @as(u32, @intCast(i)) % columns;
        const row = @as(u32, @intCast(i)) / columns;
        const x_offset = col * frame_width;
        const y_offset = row * frame_height;

        var y: u32 = 0;
        while (y < frame_height) : (y += 1) {
            const src_offset = y * frame_width * 3;
            const dst_offset = ((y_offset + y) * sheet_width + x_offset) * 3;
            @memcpy(pixels[dst_offset..][0 .. frame_width * 3], frame.pixels[src_offset..][0 .. frame_width * 3]);
        }
    }

    return SpriteSheet{
        .width = sheet_width,
        .height = sheet_height,
        .columns = columns,
        .rows = rows,
        .frame_width = frame_width,
        .frame_height = frame_height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Calculate grid positions" {
    const testing = std.testing;

    const positions = try calculateGridPositions(60000, 3, 0, 0);
    defer std.heap.page_allocator.free(positions);

    try testing.expectEqual(@as(usize, 3), positions.len);
    try testing.expectEqual(@as(u64, 15000), positions[0]);
    try testing.expectEqual(@as(u64, 30000), positions[1]);
    try testing.expectEqual(@as(u64, 45000), positions[2]);
}

test "Calculate percentage position" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), calculatePercentagePosition(60000, 0));
    try testing.expectEqual(@as(u64, 30000), calculatePercentagePosition(60000, 50));
    try testing.expectEqual(@as(u64, 60000), calculatePercentagePosition(60000, 100));
}

test "Bilinear scale" {
    const testing = std.testing;

    // 2x2 image with red, green, blue, white
    const src = [_]u8{
        255, 0,   0,   0, 255, 0,
        0,   0,   255, 255, 255, 255,
    };

    var dst: [12]u8 = undefined;
    bilinearScale(&src, 2, 2, &dst, 2, 2);

    // Same size should produce same output
    try testing.expectEqualSlices(u8, &src, &dst);
}

test "Thumbnail format" {
    const testing = std.testing;

    try testing.expectEqualStrings("jpg", ThumbnailFormat.jpeg.extension());
    try testing.expectEqualStrings("image/png", ThumbnailFormat.png.mimeType());
}
