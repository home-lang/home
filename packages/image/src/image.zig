// Home Image Processing Library
// Native support for common image formats with Sharp-like manipulation API

const std = @import("std");
const png = @import("formats/png.zig");
const bmp = @import("formats/bmp.zig");
const jpeg = @import("formats/jpeg.zig");
const gif = @import("formats/gif.zig");
const webp = @import("formats/webp.zig");
const avif = @import("formats/avif.zig");
const heic = @import("formats/heic.zig");
const jp2 = @import("formats/jp2.zig");
const tiff = @import("formats/tiff.zig");
const svg = @import("formats/svg.zig");

// ============================================================================
// Core Types
// ============================================================================

pub const PixelFormat = enum {
    rgba8, // 4 bytes per pixel (default)
    rgb8, // 3 bytes per pixel
    grayscale8, // 1 byte per pixel
    grayscale16, // 2 bytes per pixel
    rgba16, // 8 bytes per pixel
    rgb16, // 6 bytes per pixel
    indexed8, // 1 byte per pixel (palette-based)

    pub fn bytesPerPixel(self: PixelFormat) u8 {
        return switch (self) {
            .rgba8 => 4,
            .rgb8 => 3,
            .grayscale8 => 1,
            .grayscale16 => 2,
            .rgba16 => 8,
            .rgb16 => 6,
            .indexed8 => 1,
        };
    }

    pub fn hasAlpha(self: PixelFormat) bool {
        return switch (self) {
            .rgba8, .rgba16 => true,
            else => false,
        };
    }
};

pub const ImageFormat = enum {
    png,
    jpeg,
    webp,
    gif,
    bmp,
    tiff,
    avif,
    heic,
    jp2, // JPEG 2000
    svg,
    ico,
    unknown,

    pub fn fromExtension(ext: []const u8) ImageFormat {
        if (std.mem.eql(u8, ext, ".png")) return .png;
        if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return .jpeg;
        if (std.mem.eql(u8, ext, ".webp")) return .webp;
        if (std.mem.eql(u8, ext, ".gif")) return .gif;
        if (std.mem.eql(u8, ext, ".bmp")) return .bmp;
        if (std.mem.eql(u8, ext, ".tiff") or std.mem.eql(u8, ext, ".tif")) return .tiff;
        if (std.mem.eql(u8, ext, ".avif")) return .avif;
        if (std.mem.eql(u8, ext, ".heic") or std.mem.eql(u8, ext, ".heif")) return .heic;
        if (std.mem.eql(u8, ext, ".jp2") or std.mem.eql(u8, ext, ".j2k") or std.mem.eql(u8, ext, ".jpx")) return .jp2;
        if (std.mem.eql(u8, ext, ".svg")) return .svg;
        if (std.mem.eql(u8, ext, ".ico")) return .ico;
        return .unknown;
    }

    pub fn fromMagicBytes(data: []const u8) ImageFormat {
        if (data.len < 2) return .unknown;

        // BMP: BM (check early since it's only 2 bytes)
        if (data[0] == 'B' and data[1] == 'M') {
            return .bmp;
        }

        // JPEG: FF D8 FF
        if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
            return .jpeg;
        }

        // GIF: GIF87a or GIF89a
        if (data.len >= 6 and data[0] == 'G' and data[1] == 'I' and data[2] == 'F') {
            return .gif;
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (data.len >= 8 and data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') {
            return .png;
        }

        // WebP: RIFF....WEBP
        if (data.len >= 12 and data[0] == 'R' and data[1] == 'I' and data[2] == 'F' and data[3] == 'F' and data[8] == 'W' and data[9] == 'E' and data[10] == 'B' and data[11] == 'P') {
            return .webp;
        }

        // TIFF: II (little endian) or MM (big endian)
        if (data.len >= 4) {
            if ((data[0] == 'I' and data[1] == 'I' and data[2] == 42 and data[3] == 0) or
                (data[0] == 'M' and data[1] == 'M' and data[2] == 0 and data[3] == 42))
            {
                return .tiff;
            }
        }

        // JPEG 2000: 00 00 00 0C 6A 50 20 20 (JP2 signature box)
        if (data.len >= 12 and data[0] == 0x00 and data[1] == 0x00 and data[2] == 0x00 and data[3] == 0x0C and
            data[4] == 0x6A and data[5] == 0x50 and data[6] == 0x20 and data[7] == 0x20)
        {
            return .jp2;
        }

        // JPEG 2000 codestream: FF 4F FF 51
        if (data.len >= 4 and data[0] == 0xFF and data[1] == 0x4F and data[2] == 0xFF and data[3] == 0x51) {
            return .jp2;
        }

        // AVIF/HEIC: Check for ftyp box with appropriate brands
        if (data.len >= 12 and data[4] == 'f' and data[5] == 't' and data[6] == 'y' and data[7] == 'p') {
            // Check major brand
            if (std.mem.eql(u8, data[8..12], "avif") or std.mem.eql(u8, data[8..12], "avis")) {
                return .avif;
            }
            if (std.mem.eql(u8, data[8..12], "heic") or std.mem.eql(u8, data[8..12], "heix") or
                std.mem.eql(u8, data[8..12], "hevc") or std.mem.eql(u8, data[8..12], "hevx") or
                std.mem.eql(u8, data[8..12], "mif1"))
            {
                return .heic;
            }
        }

        // SVG: Check for <?xml or <svg
        if (data.len >= 5) {
            // Skip leading whitespace
            var i: usize = 0;
            while (i < data.len and i < 256 and std.ascii.isWhitespace(data[i])) {
                i += 1;
            }
            if (i + 5 <= data.len and std.mem.eql(u8, data[i..][0..5], "<?xml")) {
                return .svg;
            }
            if (i + 4 <= data.len and std.mem.eql(u8, data[i..][0..4], "<svg")) {
                return .svg;
            }
        }

        return .unknown;
    }

    pub fn mimeType(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
            .bmp => "image/bmp",
            .tiff => "image/tiff",
            .avif => "image/avif",
            .heic => "image/heic",
            .jp2 => "image/jp2",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
            .unknown => "application/octet-stream",
        };
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const WHITE = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const RED = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const GREEN = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const BLUE = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pub const TRANSPARENT = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn fromRgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @truncate((hex >> 24) & 0xFF),
            .g = @truncate((hex >> 16) & 0xFF),
            .b = @truncate((hex >> 8) & 0xFF),
            .a = @truncate(hex & 0xFF),
        };
    }

    pub fn toGrayscale(self: Color) u8 {
        // ITU-R BT.601 luma coefficients
        const r: u32 = self.r;
        const g: u32 = self.g;
        const b: u32 = self.b;
        return @truncate((r * 299 + g * 587 + b * 114) / 1000);
    }

    pub fn blend(self: Color, other: Color) Color {
        // Alpha blending: result = src * src_alpha + dst * (1 - src_alpha)
        const src_a: u32 = other.a;
        const dst_a: u32 = 255 - src_a;

        return .{
            .r = @truncate((self.r * dst_a + other.r * src_a) / 255),
            .g = @truncate((self.g * dst_a + other.g * src_a) / 255),
            .b = @truncate((self.b * dst_a + other.b * src_a) / 255),
            .a = @truncate(@max(self.a, other.a)),
        };
    }
};

// ============================================================================
// Image Structure
// ============================================================================

pub const Image = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    pixels: []u8,
    palette: ?[]Color, // For indexed images
    allocator: std.mem.Allocator,

    // Animation data (for GIF, WebP, APNG)
    frames: ?[]Frame = null,
    loop_count: u32 = 0, // 0 = infinite

    const Self = @This();

    pub const Frame = struct {
        pixels: []u8,
        delay_ms: u32,
        x_offset: u32 = 0,
        y_offset: u32 = 0,
        dispose_op: DisposeOp = .none,
        blend_op: BlendOp = .source,
    };

    pub const DisposeOp = enum {
        none,
        background,
        previous,
    };

    pub const BlendOp = enum {
        source,
        over,
    };

    // ========================================================================
    // Construction & Destruction
    // ========================================================================

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: PixelFormat) !Self {
        const size = @as(usize, width) * @as(usize, height) * format.bytesPerPixel();
        const pixels = try allocator.alloc(u8, size);
        @memset(pixels, 0);

        return Self{
            .width = width,
            .height = height,
            .format = format,
            .pixels = pixels,
            .palette = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels);
        if (self.palette) |pal| {
            self.allocator.free(pal);
        }
        if (self.frames) |frames| {
            for (frames) |frame| {
                self.allocator.free(frame.pixels);
            }
            self.allocator.free(frames);
        }
    }

    pub fn clone(self: *const Self) !Self {
        const new_pixels = try self.allocator.alloc(u8, self.pixels.len);
        @memcpy(new_pixels, self.pixels);

        var new_palette: ?[]Color = null;
        if (self.palette) |pal| {
            new_palette = try self.allocator.alloc(Color, pal.len);
            @memcpy(new_palette.?, pal);
        }

        return Self{
            .width = self.width,
            .height = self.height,
            .format = self.format,
            .pixels = new_pixels,
            .palette = new_palette,
            .allocator = self.allocator,
        };
    }

    // ========================================================================
    // Loading & Saving
    // ========================================================================

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 256); // 256MB max
        defer allocator.free(data);

        return loadFromMemory(allocator, data);
    }

    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        const format = ImageFormat.fromMagicBytes(data);

        return switch (format) {
            .png => png.decode(allocator, data),
            .jpeg => jpeg.decode(allocator, data),
            .bmp => bmp.decode(allocator, data),
            .gif => gif.decode(allocator, data),
            .webp => webp.decode(allocator, data),
            .avif => avif.decode(allocator, data),
            .heic => heic.decode(allocator, data),
            .jp2 => jp2.decode(allocator, data),
            .tiff => tiff.decode(allocator, data),
            .svg => svg.decode(allocator, data),
            else => error.UnsupportedFormat,
        };
    }

    pub fn save(self: *const Self, path: []const u8) !void {
        // Determine format from extension
        const ext = std.fs.path.extension(path);
        const format = ImageFormat.fromExtension(ext);

        try self.saveAs(path, format);
    }

    pub fn saveAs(self: *const Self, path: []const u8, format: ImageFormat) !void {
        const data = try self.encode(format);
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn encode(self: *const Self, format: ImageFormat) ![]u8 {
        return switch (format) {
            .png => png.encode(self.allocator, self),
            .jpeg => jpeg.encode(self.allocator, self),
            .bmp => bmp.encode(self.allocator, self),
            .gif => gif.encode(self.allocator, self),
            .webp => webp.encode(self.allocator, self),
            .avif => avif.encode(self.allocator, self),
            .heic => heic.encode(self.allocator, self),
            .jp2 => jp2.encode(self.allocator, self),
            .tiff => tiff.encode(self.allocator, self),
            .svg => svg.encode(self.allocator, self),
            else => error.UnsupportedFormat,
        };
    }

    // ========================================================================
    // Pixel Access
    // ========================================================================

    pub fn getPixel(self: *const Self, x: u32, y: u32) ?Color {
        if (x >= self.width or y >= self.height) return null;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;

        return switch (self.format) {
            .rgba8 => Color{
                .r = self.pixels[idx],
                .g = self.pixels[idx + 1],
                .b = self.pixels[idx + 2],
                .a = self.pixels[idx + 3],
            },
            .rgb8 => Color{
                .r = self.pixels[idx],
                .g = self.pixels[idx + 1],
                .b = self.pixels[idx + 2],
                .a = 255,
            },
            .grayscale8 => Color{
                .r = self.pixels[idx],
                .g = self.pixels[idx],
                .b = self.pixels[idx],
                .a = 255,
            },
            .indexed8 => {
                if (self.palette) |pal| {
                    const index = self.pixels[idx];
                    if (index < pal.len) {
                        return pal[index];
                    }
                }
                return null;
            },
            else => null,
        };
    }

    pub fn setPixel(self: *Self, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;

        switch (self.format) {
            .rgba8 => {
                self.pixels[idx] = color.r;
                self.pixels[idx + 1] = color.g;
                self.pixels[idx + 2] = color.b;
                self.pixels[idx + 3] = color.a;
            },
            .rgb8 => {
                self.pixels[idx] = color.r;
                self.pixels[idx + 1] = color.g;
                self.pixels[idx + 2] = color.b;
            },
            .grayscale8 => {
                self.pixels[idx] = color.toGrayscale();
            },
            else => {},
        }
    }

    // ========================================================================
    // Format Conversion
    // ========================================================================

    pub fn toFormat(self: *Self, new_format: PixelFormat) !void {
        if (self.format == new_format) return;

        const new_bpp = new_format.bytesPerPixel();
        const new_size = @as(usize, self.width) * @as(usize, self.height) * new_bpp;
        const new_pixels = try self.allocator.alloc(u8, new_size);

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const color = self.getPixel(x, y) orelse Color.BLACK;
                const new_idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * new_bpp;

                switch (new_format) {
                    .rgba8 => {
                        new_pixels[new_idx] = color.r;
                        new_pixels[new_idx + 1] = color.g;
                        new_pixels[new_idx + 2] = color.b;
                        new_pixels[new_idx + 3] = color.a;
                    },
                    .rgb8 => {
                        new_pixels[new_idx] = color.r;
                        new_pixels[new_idx + 1] = color.g;
                        new_pixels[new_idx + 2] = color.b;
                    },
                    .grayscale8 => {
                        new_pixels[new_idx] = color.toGrayscale();
                    },
                    else => {},
                }
            }
        }

        self.allocator.free(self.pixels);
        self.pixels = new_pixels;
        self.format = new_format;
    }

    // ========================================================================
    // Image Information
    // ========================================================================

    pub fn byteSize(self: *const Self) usize {
        return self.pixels.len;
    }

    pub fn dimensions(self: *const Self) struct { width: u32, height: u32 } {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn isAnimated(self: *const Self) bool {
        return self.frames != null and self.frames.?.len > 1;
    }

    pub fn frameCount(self: *const Self) usize {
        if (self.frames) |frames| {
            return frames.len;
        }
        return 1;
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const ImageError = error{
    InvalidFormat,
    UnsupportedFormat,
    CorruptData,
    OutOfMemory,
    InvalidDimensions,
    DecompressionFailed,
    CompressionFailed,
    InvalidColorType,
    InvalidBitDepth,
    InvalidHeader,
    TruncatedData,
};

// ============================================================================
// Re-exports
// ============================================================================

pub const Png = png;
pub const Jpeg = jpeg;
pub const Bmp = bmp;
pub const Gif = gif;
pub const Webp = webp;
pub const Avif = avif;
pub const Heic = heic;
pub const Jp2 = jp2;
pub const Tiff = tiff;
pub const Svg = svg;

// ============================================================================
// Tests
// ============================================================================

test "Image creation" {
    var img = try Image.init(std.testing.allocator, 100, 100, .rgba8);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 100), img.width);
    try std.testing.expectEqual(@as(u32, 100), img.height);
    try std.testing.expectEqual(PixelFormat.rgba8, img.format);
}

test "Pixel get/set" {
    var img = try Image.init(std.testing.allocator, 10, 10, .rgba8);
    defer img.deinit();

    img.setPixel(5, 5, Color.RED);
    const pixel = img.getPixel(5, 5);

    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
    try std.testing.expectEqual(@as(u8, 0), pixel.?.g);
    try std.testing.expectEqual(@as(u8, 0), pixel.?.b);
}

test "Color grayscale conversion" {
    const red = Color.RED;
    const gray = red.toGrayscale();
    // Red has luma ~76 (299/1000 * 255)
    try std.testing.expect(gray > 70 and gray < 80);
}

test "Format detection from magic bytes" {
    const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqual(ImageFormat.png, ImageFormat.fromMagicBytes(&png_magic));

    const jpeg_magic = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expectEqual(ImageFormat.jpeg, ImageFormat.fromMagicBytes(&jpeg_magic));

    const bmp_magic = [_]u8{ 'B', 'M', 0, 0 };
    try std.testing.expectEqual(ImageFormat.bmp, ImageFormat.fromMagicBytes(&bmp_magic));
}
