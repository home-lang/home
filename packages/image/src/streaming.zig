// Streaming Image Processing
// For handling large images that don't fit in memory

const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// Tile-Based Processing
// ============================================================================

/// A tile represents a rectangular portion of an image
pub const Tile = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pixels: []u8,
    format: PixelFormat,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, x: u32, y: u32, width: u32, height: u32, format: PixelFormat) !Tile {
        const bpp = format.bytesPerPixel();
        const size = @as(usize, width) * @as(usize, height) * bpp;
        const pixels = try allocator.alloc(u8, size);

        return Tile{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .pixels = pixels,
            .format = format,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tile) void {
        self.allocator.free(self.pixels);
    }

    pub fn getPixel(self: *const Tile, local_x: u32, local_y: u32) ?Color {
        if (local_x >= self.width or local_y >= self.height) return null;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, local_y) * @as(usize, self.width) + @as(usize, local_x)) * bpp;

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
            else => null,
        };
    }

    pub fn setPixel(self: *Tile, local_x: u32, local_y: u32, color: Color) void {
        if (local_x >= self.width or local_y >= self.height) return;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, local_y) * @as(usize, self.width) + @as(usize, local_x)) * bpp;

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

    /// Copy tile to an image at the tile's position
    pub fn copyToImage(self: *const Tile, img: *Image) void {
        const bpp = self.format.bytesPerPixel();

        for (0..self.height) |local_y| {
            const img_y = self.y + @as(u32, @intCast(local_y));
            if (img_y >= img.height) continue;

            const src_offset = local_y * @as(usize, self.width) * bpp;
            const dst_offset = (@as(usize, img_y) * @as(usize, img.width) + @as(usize, self.x)) * bpp;
            const copy_width = @min(self.width, img.width - self.x);
            const copy_bytes = copy_width * bpp;

            @memcpy(img.pixels[dst_offset..][0..copy_bytes], self.pixels[src_offset..][0..copy_bytes]);
        }
    }

    /// Copy from an image to this tile
    pub fn copyFromImage(self: *Tile, img: *const Image) void {
        const bpp = self.format.bytesPerPixel();

        for (0..self.height) |local_y| {
            const img_y = self.y + @as(u32, @intCast(local_y));
            if (img_y >= img.height) continue;

            const src_offset = (@as(usize, img_y) * @as(usize, img.width) + @as(usize, self.x)) * bpp;
            const dst_offset = local_y * @as(usize, self.width) * bpp;
            const copy_width = @min(self.width, img.width - self.x);
            const copy_bytes = copy_width * bpp;

            @memcpy(self.pixels[dst_offset..][0..copy_bytes], img.pixels[src_offset..][0..copy_bytes]);
        }
    }
};

// ============================================================================
// Tiled Image Iterator
// ============================================================================

/// Iterates over an image in tiles
pub const TileIterator = struct {
    img_width: u32,
    img_height: u32,
    tile_width: u32,
    tile_height: u32,
    current_x: u32,
    current_y: u32,
    format: PixelFormat,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        img_width: u32,
        img_height: u32,
        tile_width: u32,
        tile_height: u32,
        format: PixelFormat,
    ) TileIterator {
        return TileIterator{
            .img_width = img_width,
            .img_height = img_height,
            .tile_width = tile_width,
            .tile_height = tile_height,
            .current_x = 0,
            .current_y = 0,
            .format = format,
            .allocator = allocator,
        };
    }

    /// Get next tile position (doesn't allocate)
    pub fn next(self: *TileIterator) ?struct { x: u32, y: u32, width: u32, height: u32 } {
        if (self.current_y >= self.img_height) return null;

        const x = self.current_x;
        const y = self.current_y;
        const w = @min(self.tile_width, self.img_width - x);
        const h = @min(self.tile_height, self.img_height - y);

        // Advance position
        self.current_x += self.tile_width;
        if (self.current_x >= self.img_width) {
            self.current_x = 0;
            self.current_y += self.tile_height;
        }

        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    /// Create a tile at the next position
    pub fn nextTile(self: *TileIterator) !?Tile {
        const pos = self.next() orelse return null;
        return try Tile.init(self.allocator, pos.x, pos.y, pos.width, pos.height, self.format);
    }

    /// Reset iterator to beginning
    pub fn reset(self: *TileIterator) void {
        self.current_x = 0;
        self.current_y = 0;
    }

    /// Get total number of tiles
    pub fn tileCount(self: *const TileIterator) usize {
        const tiles_x = (self.img_width + self.tile_width - 1) / self.tile_width;
        const tiles_y = (self.img_height + self.tile_height - 1) / self.tile_height;
        return @as(usize, tiles_x) * @as(usize, tiles_y);
    }
};

// ============================================================================
// Scanline Processing
// ============================================================================

/// Represents a single scanline for row-by-row processing
pub const Scanline = struct {
    y: u32,
    width: u32,
    pixels: []u8,
    format: PixelFormat,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, y: u32, width: u32, format: PixelFormat) !Scanline {
        const bpp = format.bytesPerPixel();
        const pixels = try allocator.alloc(u8, @as(usize, width) * bpp);

        return Scanline{
            .y = y,
            .width = width,
            .pixels = pixels,
            .format = format,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scanline) void {
        self.allocator.free(self.pixels);
    }

    pub fn getPixel(self: *const Scanline, x: u32) ?Color {
        if (x >= self.width) return null;

        const bpp = self.format.bytesPerPixel();
        const idx = @as(usize, x) * bpp;

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
            else => null,
        };
    }

    pub fn setPixel(self: *Scanline, x: u32, color: Color) void {
        if (x >= self.width) return;

        const bpp = self.format.bytesPerPixel();
        const idx = @as(usize, x) * bpp;

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
            else => {},
        }
    }
};

/// Iterates over image scanlines
pub const ScanlineIterator = struct {
    img_width: u32,
    img_height: u32,
    current_y: u32,
    format: PixelFormat,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: PixelFormat) ScanlineIterator {
        return ScanlineIterator{
            .img_width = width,
            .img_height = height,
            .current_y = 0,
            .format = format,
            .allocator = allocator,
        };
    }

    pub fn next(self: *ScanlineIterator) !?Scanline {
        if (self.current_y >= self.img_height) return null;

        const scanline = try Scanline.init(self.allocator, self.current_y, self.img_width, self.format);
        self.current_y += 1;

        return scanline;
    }

    pub fn reset(self: *ScanlineIterator) void {
        self.current_y = 0;
    }
};

// ============================================================================
// Streaming Reader
// ============================================================================

pub const StreamingReader = struct {
    allocator: std.mem.Allocator,
    io_context: std.Io,
    file: ?std.Io.File,
    buffer: []u8,
    buffer_size: usize,
    position: usize,
    file_size: usize,

    const DEFAULT_BUFFER_SIZE = 64 * 1024; // 64KB

    pub fn init(allocator: std.mem.Allocator, buffer_size: ?usize) StreamingReader {
        return initWithIo(allocator, std.Io.Threaded.global_single_threaded.io(), buffer_size);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io_context: std.Io, buffer_size: ?usize) StreamingReader {
        return StreamingReader{
            .allocator = allocator,
            .io_context = io_context,
            .file = null,
            .buffer = &.{},
            .buffer_size = buffer_size orelse DEFAULT_BUFFER_SIZE,
            .position = 0,
            .file_size = 0,
        };
    }

    pub fn open(self: *StreamingReader, path: []const u8) !void {
        if (self.file != null) return error.AlreadyOpen;

        const file = try std.Io.Dir.cwd().openFile(self.io_context, path, .{});
        errdefer file.close(self.io_context);
        const file_size = std.math.cast(usize, try file.length(self.io_context)) orelse return error.FileTooBig;
        const buffer = try self.allocator.alloc(u8, self.buffer_size);

        self.file = file;
        self.file_size = file_size;
        self.buffer = buffer;
        self.position = 0;
    }

    pub fn deinit(self: *StreamingReader) void {
        if (self.file) |f| f.close(self.io_context);
        if (self.buffer.len > 0) self.allocator.free(self.buffer);
    }

    pub fn read(self: *StreamingReader, dest: []u8) !usize {
        const file = self.file orelse return 0;
        const bytes_read = try file.readPositional(self.io_context, &.{dest}, self.position);
        self.position += bytes_read;
        return bytes_read;
    }

    pub fn seek(self: *StreamingReader, offset: u64) !void {
        if (self.file == null) return;
        self.position = std.math.cast(usize, offset) orelse return error.FileTooBig;
    }

    pub fn getPosition(self: *const StreamingReader) usize {
        return self.position;
    }

    pub fn getSize(self: *const StreamingReader) usize {
        return self.file_size;
    }
};

// ============================================================================
// Streaming Writer
// ============================================================================

pub const StreamingWriter = struct {
    allocator: std.mem.Allocator,
    io_context: std.Io,
    file: ?std.Io.File,
    buffer: []u8,
    buffer_pos: usize,

    const DEFAULT_BUFFER_SIZE = 64 * 1024; // 64KB

    pub fn init(allocator: std.mem.Allocator, buffer_size: ?usize) !StreamingWriter {
        return initWithIo(allocator, std.Io.Threaded.global_single_threaded.io(), buffer_size);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io_context: std.Io, buffer_size: ?usize) !StreamingWriter {
        const size = buffer_size orelse DEFAULT_BUFFER_SIZE;
        if (size == 0) return error.InvalidBufferSize;
        return StreamingWriter{
            .allocator = allocator,
            .io_context = io_context,
            .file = null,
            .buffer = try allocator.alloc(u8, size),
            .buffer_pos = 0,
        };
    }

    pub fn create(self: *StreamingWriter, path: []const u8) !void {
        if (self.file != null) return error.AlreadyOpen;
        self.file = try std.Io.Dir.cwd().createFile(self.io_context, path, .{});
    }

    pub fn deinit(self: *StreamingWriter) void {
        self.flush() catch {};
        if (self.file) |f| f.close(self.io_context);
        self.allocator.free(self.buffer);
    }

    pub fn write(self: *StreamingWriter, data: []const u8) !void {
        var remaining = data;

        while (remaining.len > 0) {
            const available = self.buffer.len - self.buffer_pos;
            const to_copy = @min(remaining.len, available);

            @memcpy(self.buffer[self.buffer_pos..][0..to_copy], remaining[0..to_copy]);
            self.buffer_pos += to_copy;
            remaining = remaining[to_copy..];

            if (self.buffer_pos >= self.buffer.len) {
                try self.flush();
            }
        }
    }

    pub fn flush(self: *StreamingWriter) !void {
        if (self.buffer_pos > 0 and self.file != null) {
            try self.file.?.writeStreamingAll(self.io_context, self.buffer[0..self.buffer_pos]);
            self.buffer_pos = 0;
        }
    }
};

// ============================================================================
// Chunked Processing Pipeline
// ============================================================================

/// Callback function type for processing chunks
pub const ChunkProcessor = *const fn (chunk: []u8, x: u32, y: u32, width: u32, height: u32, context: ?*anyopaque) void;

/// Process an image in chunks with a callback
pub fn processInChunks(
    img: *Image,
    chunk_width: u32,
    chunk_height: u32,
    processor: ChunkProcessor,
    context: ?*anyopaque,
) void {
    var iter = TileIterator.init(
        img.allocator,
        img.width,
        img.height,
        chunk_width,
        chunk_height,
        img.format,
    );

    const bpp = img.format.bytesPerPixel();

    while (iter.next()) |pos| {
        // Get pointer to chunk in image
        const row_stride = @as(usize, img.width) * bpp;
        const chunk_stride = @as(usize, pos.width) * bpp;

        // Process row by row within chunk
        for (0..pos.height) |local_y| {
            const img_y = pos.y + @as(u32, @intCast(local_y));
            const row_offset = @as(usize, img_y) * row_stride + @as(usize, pos.x) * bpp;

            processor(
                img.pixels[row_offset..][0..chunk_stride],
                pos.x,
                pos.y + @as(u32, @intCast(local_y)),
                pos.width,
                1,
                context,
            );
        }
    }
}

// ============================================================================
// Memory-Mapped Image (for very large images)
// ============================================================================

pub const MappedImage = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    io_context: std.Io,
    file: std.Io.File,
    mapping: ?[]align(std.heap.page_size_min) u8,

    pub fn open(path: []const u8, width: u32, height: u32, format: PixelFormat) !MappedImage {
        return openWithIo(std.Io.Threaded.global_single_threaded.io(), path, width, height, format);
    }

    pub fn openWithIo(io_context: std.Io, path: []const u8, width: u32, height: u32, format: PixelFormat) !MappedImage {
        const file = try std.Io.Dir.cwd().openFile(io_context, path, .{ .mode = .read_write });
        errdefer file.close(io_context);

        const bpp = format.bytesPerPixel();
        const size = @as(usize, width) * @as(usize, height) * bpp;

        const mapping = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        return MappedImage{
            .width = width,
            .height = height,
            .format = format,
            .io_context = io_context,
            .file = file,
            .mapping = mapping,
        };
    }

    pub fn deinit(self: *MappedImage) void {
        if (self.mapping) |m| {
            std.posix.munmap(m);
        }
        self.file.close(self.io_context);
    }

    pub fn getPixel(self: *const MappedImage, x: u32, y: u32) ?Color {
        if (x >= self.width or y >= self.height) return null;
        if (self.mapping == null) return null;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;
        const data = self.mapping.?;

        return switch (self.format) {
            .rgba8 => Color{
                .r = data[idx],
                .g = data[idx + 1],
                .b = data[idx + 2],
                .a = data[idx + 3],
            },
            .rgb8 => Color{
                .r = data[idx],
                .g = data[idx + 1],
                .b = data[idx + 2],
                .a = 255,
            },
            else => null,
        };
    }

    pub fn setPixel(self: *MappedImage, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        if (self.mapping == null) return;

        const bpp = self.format.bytesPerPixel();
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;
        const data = self.mapping.?;

        switch (self.format) {
            .rgba8 => {
                data[idx] = color.r;
                data[idx + 1] = color.g;
                data[idx + 2] = color.b;
                data[idx + 3] = color.a;
            },
            .rgb8 => {
                data[idx] = color.r;
                data[idx + 1] = color.g;
                data[idx + 2] = color.b;
            },
            else => {},
        }
    }

    pub fn sync(self: *MappedImage) !void {
        if (self.mapping) |m| {
            try std.posix.msync(m, .{ .SYNC = true });
        }
    }
};

// ============================================================================
// Progressive Loading Callback
// ============================================================================

/// Callback for progressive image loading
pub const ProgressCallback = *const fn (
    loaded_rows: u32,
    total_rows: u32,
    context: ?*anyopaque,
) bool; // Return false to cancel

/// Progressive image loader state
pub const ProgressiveLoader = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: PixelFormat,
    rows_loaded: u32,
    pixels: []u8,
    callback: ?ProgressCallback,
    callback_context: ?*anyopaque,
    cancelled: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        format: PixelFormat,
        callback: ?ProgressCallback,
        context: ?*anyopaque,
    ) !ProgressiveLoader {
        const bpp = format.bytesPerPixel();
        const size = @as(usize, width) * @as(usize, height) * bpp;
        const pixels = try allocator.alloc(u8, size);

        return ProgressiveLoader{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
            .rows_loaded = 0,
            .pixels = pixels,
            .callback = callback,
            .callback_context = context,
            .cancelled = false,
        };
    }

    pub fn deinit(self: *ProgressiveLoader) void {
        self.allocator.free(self.pixels);
    }

    pub fn addRow(self: *ProgressiveLoader, row_data: []const u8) !void {
        if (self.cancelled) return error.Cancelled;
        if (self.rows_loaded >= self.height) return;

        const bpp = self.format.bytesPerPixel();
        const row_size = @as(usize, self.width) * bpp;
        const offset = @as(usize, self.rows_loaded) * row_size;

        @memcpy(self.pixels[offset..][0..row_size], row_data[0..row_size]);
        self.rows_loaded += 1;

        if (self.callback) |cb| {
            if (!cb(self.rows_loaded, self.height, self.callback_context)) {
                self.cancelled = true;
                return error.Cancelled;
            }
        }
    }

    pub fn toImage(self: *ProgressiveLoader) !Image {
        const new_pixels = try self.allocator.alloc(u8, self.pixels.len);
        @memcpy(new_pixels, self.pixels);

        return Image{
            .width = self.width,
            .height = self.height,
            .pixels = new_pixels,
            .format = self.format,
            .allocator = self.allocator,
            .palette = null,
            .frames = null,
        };
    }

    pub fn progress(self: *const ProgressiveLoader) f32 {
        return @as(f32, @floatFromInt(self.rows_loaded)) / @as(f32, @floatFromInt(self.height));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Tile creation and pixel access" {
    var tile = try Tile.init(std.testing.allocator, 10, 20, 64, 64, .rgba8);
    defer tile.deinit();

    tile.setPixel(0, 0, Color.RED);
    const pixel = tile.getPixel(0, 0);

    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
}

test "TileIterator counts correctly" {
    const iter = TileIterator.init(std.testing.allocator, 100, 100, 32, 32, .rgba8);

    // 100x100 with 32x32 tiles = 4x4 = 16 tiles
    try std.testing.expectEqual(@as(usize, 16), iter.tileCount());
}

test "TileIterator iteration" {
    var iter = TileIterator.init(std.testing.allocator, 100, 100, 64, 64, .rgba8);

    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }

    // 100x100 with 64x64 tiles = 2x2 = 4 tiles
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "Scanline iterator" {
    var iter = ScanlineIterator.init(std.testing.allocator, 100, 50, .rgba8);

    var count: u32 = 0;
    while (try iter.next()) |*scanline| {
        var sl = scanline.*;
        defer sl.deinit();
        count += 1;
    }

    try std.testing.expectEqual(@as(u32, 50), count);
}

test "Streaming reader and writer preserve position and all bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "stream.bin" });
    defer allocator.free(path);

    {
        var writer = try StreamingWriter.initWithIo(allocator, std.testing.io, 3);
        defer writer.deinit();
        try writer.create(path);
        try writer.write("hello");
        try writer.write(" world");
        try writer.flush();
    }

    var reader = StreamingReader.initWithIo(allocator, std.testing.io, 4);
    defer reader.deinit();
    try reader.open(path);
    try std.testing.expectEqual(@as(usize, 11), reader.getSize());

    var prefix: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, prefix.len), try reader.read(&prefix));
    try std.testing.expectEqualStrings("hello ", &prefix);
    try std.testing.expectEqual(@as(usize, 6), reader.getPosition());

    try reader.seek(6);
    var suffix: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, suffix.len), try reader.read(&suffix));
    try std.testing.expectEqualStrings("world", &suffix);
}

test "Mapped image uses caller-provided I/O" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "mapped.rgba" });
    defer allocator.free(path);

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, 16);
    }

    var mapped = try MappedImage.openWithIo(std.testing.io, path, 2, 2, .rgba8);
    defer mapped.deinit();
    mapped.setPixel(1, 1, Color.GREEN);
    try mapped.sync();
    try std.testing.expectEqual(Color.GREEN, mapped.getPixel(1, 1).?);
}
