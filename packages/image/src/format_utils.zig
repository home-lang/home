const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;
const PixelFormat = @import("image.zig").PixelFormat;
const exif = @import("metadata/exif.zig");
const icc = @import("metadata/icc.zig");

// ============================================================================
// EXIF Orientation Auto-Correction
// ============================================================================

/// EXIF orientation values
pub const Orientation = enum(u16) {
    normal = 1,
    flip_horizontal = 2,
    rotate_180 = 3,
    flip_vertical = 4,
    transpose = 5, // 90 CW + flip horizontal
    rotate_90_cw = 6,
    transverse = 7, // 90 CCW + flip horizontal
    rotate_90_ccw = 8,
    unknown = 0,

    pub fn fromExif(value: u16) Orientation {
        return switch (value) {
            1 => .normal,
            2 => .flip_horizontal,
            3 => .rotate_180,
            4 => .flip_vertical,
            5 => .transpose,
            6 => .rotate_90_cw,
            7 => .transverse,
            8 => .rotate_90_ccw,
            else => .unknown,
        };
    }
};

/// Auto-rotate image based on EXIF orientation
pub fn autoRotate(image: *Image, exif_data: *const exif.ExifData, allocator: std.mem.Allocator) !void {
    const orientation = Orientation.fromExif(exif_data.orientation);

    switch (orientation) {
        .normal, .unknown => return,
        .flip_horizontal => flipHorizontal(image),
        .rotate_180 => rotate180(image),
        .flip_vertical => flipVertical(image),
        .transpose => {
            try rotateImage(image, .cw_90, allocator);
            flipHorizontal(image);
        },
        .rotate_90_cw => try rotateImage(image, .cw_90, allocator),
        .transverse => {
            try rotateImage(image, .ccw_90, allocator);
            flipHorizontal(image);
        },
        .rotate_90_ccw => try rotateImage(image, .ccw_90, allocator),
    }
}

pub const RotateDirection = enum {
    cw_90,
    ccw_90,
    rotate_180,
};

/// Rotate image 90 degrees
pub fn rotateImage(image: *Image, direction: RotateDirection, allocator: std.mem.Allocator) !void {
    if (direction == .rotate_180) {
        rotate180(image);
        return;
    }

    const new_width = image.height;
    const new_height = image.width;
    const bpp = image.format.bytesPerPixel();

    const new_pixels = try allocator.alloc(u8, new_width * new_height * bpp);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const src_idx = (y * image.width + x) * bpp;

            const dst_x: u32 = switch (direction) {
                .cw_90 => image.height - 1 - y,
                .ccw_90 => y,
                .rotate_180 => unreachable,
            };
            const dst_y: u32 = switch (direction) {
                .cw_90 => x,
                .ccw_90 => image.width - 1 - x,
                .rotate_180 => unreachable,
            };

            const dst_idx = (dst_y * new_width + dst_x) * bpp;

            for (0..bpp) |i| {
                new_pixels[dst_idx + i] = image.pixels[src_idx + i];
            }
        }
    }

    allocator.free(image.pixels);
    image.pixels = new_pixels;
    image.width = new_width;
    image.height = new_height;
}

/// Flip image horizontally in-place
pub fn flipHorizontal(image: *Image) void {
    const bpp = image.format.bytesPerPixel();

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width / 2) : (x += 1) {
            const left_idx = (y * image.width + x) * bpp;
            const right_idx = (y * image.width + (image.width - 1 - x)) * bpp;

            for (0..bpp) |i| {
                const temp = image.pixels[left_idx + i];
                image.pixels[left_idx + i] = image.pixels[right_idx + i];
                image.pixels[right_idx + i] = temp;
            }
        }
    }
}

/// Flip image vertically in-place
pub fn flipVertical(image: *Image) void {
    const bpp = image.format.bytesPerPixel();
    const row_size = image.width * bpp;

    var y: u32 = 0;
    while (y < image.height / 2) : (y += 1) {
        const top_row = y * row_size;
        const bottom_row = (image.height - 1 - y) * row_size;

        for (0..row_size) |i| {
            const temp = image.pixels[top_row + i];
            image.pixels[top_row + i] = image.pixels[bottom_row + i];
            image.pixels[bottom_row + i] = temp;
        }
    }
}

/// Rotate image 180 degrees in-place
pub fn rotate180(image: *Image) void {
    const bpp = image.format.bytesPerPixel();
    const total_pixels = image.width * image.height;

    var i: u32 = 0;
    while (i < total_pixels / 2) : (i += 1) {
        const j = total_pixels - 1 - i;

        for (0..bpp) |c| {
            const temp = image.pixels[i * bpp + c];
            image.pixels[i * bpp + c] = image.pixels[j * bpp + c];
            image.pixels[j * bpp + c] = temp;
        }
    }
}

// ============================================================================
// ICC Profile Conversion
// ============================================================================

/// ICC conversion options
pub const ICCConversionOptions = struct {
    intent: RenderingIntent = .perceptual,
    black_point_compensation: bool = true,
};

pub const RenderingIntent = enum {
    perceptual,
    relative_colorimetric,
    saturation,
    absolute_colorimetric,
};

/// Convert image between ICC profiles
pub fn convertICCProfile(
    image: *Image,
    source_profile: *const icc.ICCProfile,
    dest_profile: *const icc.ICCProfile,
    options: ICCConversionOptions,
) !void {
    _ = options;

    // Get source and destination white points
    const src_white = source_profile.getWhitePoint();
    const dst_white = dest_profile.getWhitePoint();

    // Simple chromatic adaptation if white points differ
    const adapt = !std.meta.eql(src_white, dst_white);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            var color = image.getPixel(x, y) orelse continue;

            // Convert to XYZ using source profile
            var xyz = rgbToXYZ(color, source_profile);

            // Chromatic adaptation if needed
            if (adapt) {
                xyz = chromaticAdapt(xyz, src_white, dst_white);
            }

            // Convert from XYZ to RGB using destination profile
            color = xyzToRGB(xyz, dest_profile);

            image.setPixel(x, y, color);
        }
    }
}

const XYZ = struct { x: f64, y: f64, z: f64 };

fn rgbToXYZ(color: Color, profile: *const icc.ICCProfile) XYZ {
    // Linearize
    const r = gammaToLinear(@as(f64, @floatFromInt(color.r)) / 255.0, profile.gamma);
    const g = gammaToLinear(@as(f64, @floatFromInt(color.g)) / 255.0, profile.gamma);
    const b = gammaToLinear(@as(f64, @floatFromInt(color.b)) / 255.0, profile.gamma);

    // Apply matrix
    const matrix = profile.getColorMatrix();
    return XYZ{
        .x = r * matrix[0][0] + g * matrix[0][1] + b * matrix[0][2],
        .y = r * matrix[1][0] + g * matrix[1][1] + b * matrix[1][2],
        .z = r * matrix[2][0] + g * matrix[2][1] + b * matrix[2][2],
    };
}

fn xyzToRGB(xyz: XYZ, profile: *const icc.ICCProfile) Color {
    // Apply inverse matrix
    const inv_matrix = profile.getInverseMatrix();
    const r = xyz.x * inv_matrix[0][0] + xyz.y * inv_matrix[0][1] + xyz.z * inv_matrix[0][2];
    const g = xyz.x * inv_matrix[1][0] + xyz.y * inv_matrix[1][1] + xyz.z * inv_matrix[1][2];
    const b = xyz.x * inv_matrix[2][0] + xyz.y * inv_matrix[2][1] + xyz.z * inv_matrix[2][2];

    // Apply gamma
    return Color{
        .r = @intFromFloat(std.math.clamp(linearToGamma(r, profile.gamma) * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(linearToGamma(g, profile.gamma) * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(linearToGamma(b, profile.gamma) * 255.0, 0, 255)),
        .a = 255,
    };
}

fn gammaToLinear(value: f64, gamma: f64) f64 {
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return std.math.pow(f64, (value + 0.055) / 1.055, gamma);
}

fn linearToGamma(value: f64, gamma: f64) f64 {
    if (value <= 0.0031308) {
        return value * 12.92;
    }
    return 1.055 * std.math.pow(f64, value, 1.0 / gamma) - 0.055;
}

fn chromaticAdapt(xyz: XYZ, src_white: [3]f64, dst_white: [3]f64) XYZ {
    // Bradford adaptation matrix
    const scale_x = dst_white[0] / src_white[0];
    const scale_y = dst_white[1] / src_white[1];
    const scale_z = dst_white[2] / src_white[2];

    return XYZ{
        .x = xyz.x * scale_x,
        .y = xyz.y * scale_y,
        .z = xyz.z * scale_z,
    };
}

// ============================================================================
// Animation Timeline Editing
// ============================================================================

/// Animation frame
pub const AnimationFrame = struct {
    image: *Image,
    delay_ms: u32,
    dispose_op: DisposeOp = .none,
    blend_op: BlendOp = .source,
    x_offset: u32 = 0,
    y_offset: u32 = 0,
};

pub const DisposeOp = enum {
    none, // Leave as-is
    background, // Clear to background
    previous, // Restore previous frame
};

pub const BlendOp = enum {
    source, // Replace
    over, // Alpha blend
};

/// Animation timeline for editing
pub const AnimationTimeline = struct {
    frames: std.ArrayList(AnimationFrame),
    width: u32,
    height: u32,
    loop_count: u32 = 0, // 0 = infinite
    background_color: Color = Color.TRANSPARENT,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) AnimationTimeline {
        return AnimationTimeline{
            .frames = std.ArrayList(AnimationFrame).init(allocator),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnimationTimeline) void {
        for (self.frames.items) |frame| {
            frame.image.deinit();
            self.allocator.destroy(frame.image);
        }
        self.frames.deinit();
    }

    /// Add a frame to the end
    pub fn addFrame(self: *AnimationTimeline, image: *Image, delay_ms: u32) !void {
        try self.frames.append(AnimationFrame{
            .image = image,
            .delay_ms = delay_ms,
        });
    }

    /// Insert frame at specific index
    pub fn insertFrame(self: *AnimationTimeline, index: usize, image: *Image, delay_ms: u32) !void {
        try self.frames.insert(index, AnimationFrame{
            .image = image,
            .delay_ms = delay_ms,
        });
    }

    /// Remove frame at index
    pub fn removeFrame(self: *AnimationTimeline, index: usize) void {
        if (index >= self.frames.items.len) return;
        const frame = self.frames.orderedRemove(index);
        frame.image.deinit();
        self.allocator.destroy(frame.image);
    }

    /// Duplicate frame
    pub fn duplicateFrame(self: *AnimationTimeline, index: usize) !void {
        if (index >= self.frames.items.len) return;

        const original = self.frames.items[index];
        const new_image = try self.allocator.create(Image);
        new_image.* = try original.image.clone();

        try self.frames.insert(index + 1, AnimationFrame{
            .image = new_image,
            .delay_ms = original.delay_ms,
            .dispose_op = original.dispose_op,
            .blend_op = original.blend_op,
        });
    }

    /// Move frame to new position
    pub fn moveFrame(self: *AnimationTimeline, from: usize, to: usize) void {
        if (from >= self.frames.items.len or to >= self.frames.items.len) return;
        const frame = self.frames.orderedRemove(from);
        self.frames.insert(to, frame) catch {};
    }

    /// Set delay for all frames
    pub fn setGlobalDelay(self: *AnimationTimeline, delay_ms: u32) void {
        for (self.frames.items) |*frame| {
            frame.delay_ms = delay_ms;
        }
    }

    /// Get total duration in milliseconds
    pub fn getTotalDuration(self: *const AnimationTimeline) u64 {
        var total: u64 = 0;
        for (self.frames.items) |frame| {
            total += frame.delay_ms;
        }
        return total;
    }

    /// Reverse animation order
    pub fn reverse(self: *AnimationTimeline) void {
        std.mem.reverse(AnimationFrame, self.frames.items);
    }

    /// Create ping-pong animation (forward then backward)
    pub fn pingPong(self: *AnimationTimeline) !void {
        const original_len = self.frames.items.len;
        if (original_len < 2) return;

        // Add reversed frames (excluding first and last to avoid duplicates)
        var i: usize = original_len - 2;
        while (i > 0) : (i -= 1) {
            try self.duplicateFrame(i);
        }
    }

    /// Resize all frames
    pub fn resizeFrames(self: *AnimationTimeline, new_width: u32, new_height: u32) !void {
        for (self.frames.items) |*frame| {
            try frame.image.resizeBilinear(new_width, new_height);
        }
        self.width = new_width;
        self.height = new_height;
    }

    /// Apply operation to all frames
    pub fn applyToAll(self: *AnimationTimeline, operation: fn (*Image) anyerror!void) !void {
        for (self.frames.items) |frame| {
            try operation(frame.image);
        }
    }

    /// Extract frames to individual images
    pub fn extractFrames(self: *const AnimationTimeline, allocator: std.mem.Allocator) ![]Image {
        var images = try allocator.alloc(Image, self.frames.items.len);

        for (self.frames.items, 0..) |frame, i| {
            images[i] = try frame.image.clone();
        }

        return images;
    }

    /// Create from animated image
    pub fn fromImage(image: *const Image, allocator: std.mem.Allocator) !AnimationTimeline {
        var timeline = AnimationTimeline.init(allocator, image.width, image.height);

        if (image.frames) |frames| {
            for (frames) |frame| {
                const frame_image = try allocator.create(Image);
                frame_image.* = try Image.init(allocator, image.width, image.height, image.format);
                @memcpy(frame_image.pixels, frame.pixels);

                try timeline.addFrame(frame_image, frame.delay_ms);
            }
        } else {
            // Single frame
            const frame_image = try allocator.create(Image);
            frame_image.* = try image.clone();
            try timeline.addFrame(frame_image, 100);
        }

        return timeline;
    }

    /// Export back to image with frames
    pub fn toImage(self: *const AnimationTimeline) !Image {
        if (self.frames.items.len == 0) return error.NoFrames;

        var result = try self.frames.items[0].image.clone();

        if (self.frames.items.len > 1) {
            result.frames = try self.allocator.alloc(Image.Frame, self.frames.items.len);

            for (self.frames.items, 0..) |frame, i| {
                const pixels = try self.allocator.alloc(u8, frame.image.pixels.len);
                @memcpy(pixels, frame.image.pixels);

                result.frames.?[i] = Image.Frame{
                    .pixels = pixels,
                    .delay_ms = frame.delay_ms,
                    .x_offset = frame.x_offset,
                    .y_offset = frame.y_offset,
                    .dispose_op = switch (frame.dispose_op) {
                        .none => .none,
                        .background => .background,
                        .previous => .previous,
                    },
                    .blend_op = switch (frame.blend_op) {
                        .source => .source,
                        .over => .over,
                    },
                };
            }

            result.loop_count = self.loop_count;
        }

        return result;
    }
};

// ============================================================================
// Multi-Page Document Support
// ============================================================================

/// Multi-page document (TIFF, PDF, etc.)
pub const MultiPageDocument = struct {
    pages: std.ArrayList(*Image),
    metadata: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MultiPageDocument {
        return MultiPageDocument{
            .pages = std.ArrayList(*Image).init(allocator),
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiPageDocument) void {
        for (self.pages.items) |page| {
            page.deinit();
            self.allocator.destroy(page);
        }
        self.pages.deinit();

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }

    /// Add a page
    pub fn addPage(self: *MultiPageDocument, image: *Image) !void {
        try self.pages.append(image);
    }

    /// Insert page at index
    pub fn insertPage(self: *MultiPageDocument, index: usize, image: *Image) !void {
        try self.pages.insert(index, image);
    }

    /// Remove page
    pub fn removePage(self: *MultiPageDocument, index: usize) void {
        if (index >= self.pages.items.len) return;
        const page = self.pages.orderedRemove(index);
        page.deinit();
        self.allocator.destroy(page);
    }

    /// Move page
    pub fn movePage(self: *MultiPageDocument, from: usize, to: usize) void {
        if (from >= self.pages.items.len or to >= self.pages.items.len) return;
        const page = self.pages.orderedRemove(from);
        self.pages.insert(to, page) catch {};
    }

    /// Get page count
    pub fn pageCount(self: *const MultiPageDocument) usize {
        return self.pages.items.len;
    }

    /// Get specific page
    pub fn getPage(self: *const MultiPageDocument, index: usize) ?*Image {
        if (index >= self.pages.items.len) return null;
        return self.pages.items[index];
    }

    /// Set metadata
    pub fn setMetadata(self: *MultiPageDocument, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.metadata.put(key_copy, value_copy);
    }

    /// Get metadata
    pub fn getMetadata(self: *const MultiPageDocument, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }

    /// Merge another document
    pub fn merge(self: *MultiPageDocument, other: *const MultiPageDocument) !void {
        for (other.pages.items) |page| {
            const new_page = try self.allocator.create(Image);
            new_page.* = try page.clone();
            try self.pages.append(new_page);
        }
    }

    /// Split into separate documents
    pub fn split(self: *const MultiPageDocument, pages_per_doc: usize) ![]MultiPageDocument {
        const num_docs = (self.pages.items.len + pages_per_doc - 1) / pages_per_doc;
        var docs = try self.allocator.alloc(MultiPageDocument, num_docs);

        for (0..num_docs) |i| {
            docs[i] = MultiPageDocument.init(self.allocator);

            const start = i * pages_per_doc;
            const end = @min(start + pages_per_doc, self.pages.items.len);

            for (start..end) |j| {
                const new_page = try self.allocator.create(Image);
                new_page.* = try self.pages.items[j].clone();
                try docs[i].pages.append(new_page);
            }
        }

        return docs;
    }

    /// Create thumbnail sheet (contact sheet)
    pub fn createContactSheet(
        self: *const MultiPageDocument,
        thumb_width: u32,
        thumb_height: u32,
        cols: u32,
        padding: u32,
        bg_color: Color,
        allocator: std.mem.Allocator,
    ) !Image {
        const rows = (self.pages.items.len + cols - 1) / cols;
        const sheet_width = cols * (thumb_width + padding) + padding;
        const sheet_height = rows * (thumb_height + padding) + padding;

        var sheet = try Image.init(allocator, sheet_width, sheet_height, .rgba8);

        // Fill background
        var y: u32 = 0;
        while (y < sheet_height) : (y += 1) {
            var x: u32 = 0;
            while (x < sheet_width) : (x += 1) {
                sheet.setPixel(x, y, bg_color);
            }
        }

        // Draw thumbnails
        for (self.pages.items, 0..) |page, i| {
            const col = i % cols;
            const row = i / cols;

            const offset_x = padding + col * (thumb_width + padding);
            const offset_y = padding + row * (thumb_height + padding);

            // Create thumbnail (simplified - just copy scaled)
            const scale_x: f32 = @as(f32, @floatFromInt(thumb_width)) / @as(f32, @floatFromInt(page.width));
            const scale_y: f32 = @as(f32, @floatFromInt(thumb_height)) / @as(f32, @floatFromInt(page.height));
            const scale = @min(scale_x, scale_y);

            const scaled_w: u32 = @intFromFloat(@as(f32, @floatFromInt(page.width)) * scale);
            const scaled_h: u32 = @intFromFloat(@as(f32, @floatFromInt(page.height)) * scale);

            const x_off = (thumb_width - scaled_w) / 2;
            const y_off = (thumb_height - scaled_h) / 2;

            var ty: u32 = 0;
            while (ty < scaled_h) : (ty += 1) {
                var tx: u32 = 0;
                while (tx < scaled_w) : (tx += 1) {
                    const src_x: u32 = @intFromFloat(@as(f32, @floatFromInt(tx)) / scale);
                    const src_y: u32 = @intFromFloat(@as(f32, @floatFromInt(ty)) / scale);

                    if (page.getPixel(src_x, src_y)) |c| {
                        sheet.setPixel(
                            @intCast(offset_x + x_off + tx),
                            @intCast(offset_y + y_off + ty),
                            c,
                        );
                    }
                }
            }
        }

        return sheet;
    }
};

// ============================================================================
// Format Detection Helpers
// ============================================================================

/// Detect if file is multi-page capable
pub fn isMultiPageFormat(data: []const u8) bool {
    // TIFF
    if (data.len >= 4 and
        ((data[0] == 'I' and data[1] == 'I' and data[2] == 42 and data[3] == 0) or
        (data[0] == 'M' and data[1] == 'M' and data[2] == 0 and data[3] == 42)))
    {
        return true;
    }

    // PDF
    if (data.len >= 5 and std.mem.eql(u8, data[0..5], "%PDF-")) {
        return true;
    }

    return false;
}

/// Detect if file is animated
pub fn isAnimatedFormat(data: []const u8) bool {
    // GIF
    if (data.len >= 6 and data[0] == 'G' and data[1] == 'I' and data[2] == 'F') {
        return true;
    }

    // APNG (check for acTL chunk)
    if (data.len >= 8 and data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') {
        // Search for acTL chunk
        var i: usize = 8;
        while (i + 8 < data.len) {
            const chunk_len = (@as(u32, data[i]) << 24) | (@as(u32, data[i + 1]) << 16) |
                (@as(u32, data[i + 2]) << 8) | @as(u32, data[i + 3]);

            if (std.mem.eql(u8, data[i + 4 .. i + 8], "acTL")) {
                return true;
            }

            i += chunk_len + 12;
        }
    }

    // WebP (check for ANIM chunk)
    if (data.len >= 16 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
        // Search for ANIM chunk
        var i: usize = 12;
        while (i + 8 < data.len) {
            if (std.mem.eql(u8, data[i .. i + 4], "ANIM")) {
                return true;
            }
            const chunk_size = (@as(u32, data[i + 7]) << 24) | (@as(u32, data[i + 6]) << 16) |
                (@as(u32, data[i + 5]) << 8) | @as(u32, data[i + 4]);
            i += 8 + chunk_size + (chunk_size % 2);
        }
    }

    return false;
}

/// Get animation frame count from file data
pub fn getFrameCount(data: []const u8) u32 {
    // GIF
    if (data.len >= 6 and data[0] == 'G' and data[1] == 'I' and data[2] == 'F') {
        var count: u32 = 0;
        var i: usize = 13; // Skip header

        // Skip global color table
        const flags = data[10];
        if ((flags & 0x80) != 0) {
            const table_size: usize = @as(usize, 3) << @intCast((flags & 7) + 1);
            i += table_size;
        }

        // Count image descriptors
        while (i < data.len) {
            if (data[i] == 0x2C) { // Image descriptor
                count += 1;
                i += 10;
                // Skip local color table
                const local_flags = data[i - 1];
                if ((local_flags & 0x80) != 0) {
                    const local_size: usize = @as(usize, 3) << @intCast((local_flags & 7) + 1);
                    i += local_size;
                }
                // Skip image data
                i += 1; // LZW minimum code size
                while (i < data.len and data[i] != 0) {
                    i += @as(usize, data[i]) + 1;
                }
                i += 1;
            } else if (data[i] == 0x21) { // Extension
                i += 2;
                while (i < data.len and data[i] != 0) {
                    i += @as(usize, data[i]) + 1;
                }
                i += 1;
            } else if (data[i] == 0x3B) { // Trailer
                break;
            } else {
                i += 1;
            }
        }

        return if (count > 0) count else 1;
    }

    // APNG
    if (data.len >= 8 and data[0] == 0x89 and data[1] == 'P') {
        var i: usize = 8;
        while (i + 8 < data.len) {
            const chunk_len = (@as(u32, data[i]) << 24) | (@as(u32, data[i + 1]) << 16) |
                (@as(u32, data[i + 2]) << 8) | @as(u32, data[i + 3]);

            if (std.mem.eql(u8, data[i + 4 .. i + 8], "acTL")) {
                // Frame count is at offset 8 in acTL
                return (@as(u32, data[i + 8]) << 24) | (@as(u32, data[i + 9]) << 16) |
                    (@as(u32, data[i + 10]) << 8) | @as(u32, data[i + 11]);
            }

            i += chunk_len + 12;
        }
    }

    return 1;
}
