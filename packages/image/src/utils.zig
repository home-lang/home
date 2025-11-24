const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;
const ImageFormat = @import("image.zig").ImageFormat;

// ============================================================================
// Image Diff Visualization
// ============================================================================

/// Diff visualization mode
pub const DiffMode = enum {
    absolute, // Absolute difference
    highlighted, // Highlight differences on original
    side_by_side, // Show both images side by side
    heatmap, // Color-coded difference intensity
    blink, // For animation (returns two frames)
};

/// Diff visualization options
pub const DiffOptions = struct {
    mode: DiffMode = .heatmap,
    threshold: u8 = 10, // Minimum difference to consider
    highlight_color: Color = Color.RED,
    scale: f32 = 1.0,
};

/// Create a visual diff between two images
pub fn createDiff(
    image1: *const Image,
    image2: *const Image,
    options: DiffOptions,
    allocator: std.mem.Allocator,
) !Image {
    const width = @max(image1.width, image2.width);
    const height = @max(image1.height, image2.height);

    switch (options.mode) {
        .absolute => {
            var result = try Image.init(allocator, width, height, .rgba8);

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const c1 = if (x < image1.width and y < image1.height)
                        image1.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const c2 = if (x < image2.width and y < image2.height)
                        image2.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const dr = @as(i16, c1.r) - @as(i16, c2.r);
                    const dg = @as(i16, c1.g) - @as(i16, c2.g);
                    const db = @as(i16, c1.b) - @as(i16, c2.b);

                    result.setPixel(x, y, Color{
                        .r = @intCast(@abs(dr)),
                        .g = @intCast(@abs(dg)),
                        .b = @intCast(@abs(db)),
                        .a = 255,
                    });
                }
            }

            return result;
        },
        .highlighted => {
            var result = try image1.clone();

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const c1 = if (x < image1.width and y < image1.height)
                        image1.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const c2 = if (x < image2.width and y < image2.height)
                        image2.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const diff = colorDifference(c1, c2);
                    if (diff > options.threshold) {
                        result.setPixel(x, y, options.highlight_color);
                    }
                }
            }

            return result;
        },
        .side_by_side => {
            var result = try Image.init(allocator, width * 2 + 10, height, .rgba8);

            // Fill with separator color
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < result.width) : (x += 1) {
                    if (x >= width and x < width + 10) {
                        result.setPixel(x, y, Color{ .r = 128, .g = 128, .b = 128, .a = 255 });
                    }
                }
            }

            // Copy first image
            y = 0;
            while (y < image1.height) : (y += 1) {
                var x: u32 = 0;
                while (x < image1.width) : (x += 1) {
                    if (image1.getPixel(x, y)) |c| {
                        result.setPixel(x, y, c);
                    }
                }
            }

            // Copy second image
            y = 0;
            while (y < image2.height) : (y += 1) {
                var x: u32 = 0;
                while (x < image2.width) : (x += 1) {
                    if (image2.getPixel(x, y)) |c| {
                        result.setPixel(x + width + 10, y, c);
                    }
                }
            }

            return result;
        },
        .heatmap => {
            var result = try Image.init(allocator, width, height, .rgba8);

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const c1 = if (x < image1.width and y < image1.height)
                        image1.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const c2 = if (x < image2.width and y < image2.height)
                        image2.getPixel(x, y) orelse Color.BLACK
                    else
                        Color.BLACK;

                    const diff = colorDifference(c1, c2);
                    result.setPixel(x, y, diffToHeatmap(diff));
                }
            }

            return result;
        },
        .blink => {
            // Just return first image - caller should create animation
            return try image1.clone();
        },
    }
}

fn colorDifference(c1: Color, c2: Color) u8 {
    const dr = @as(i16, c1.r) - @as(i16, c2.r);
    const dg = @as(i16, c1.g) - @as(i16, c2.g);
    const db = @as(i16, c1.b) - @as(i16, c2.b);
    const sum = @abs(dr) + @abs(dg) + @abs(db);
    return @intCast(@min(sum / 3, 255));
}

fn diffToHeatmap(diff: u8) Color {
    // Blue (0) -> Cyan -> Green -> Yellow -> Red (255)
    if (diff < 64) {
        return Color{ .r = 0, .g = @intCast(diff * 4), .b = 255, .a = 255 };
    } else if (diff < 128) {
        return Color{ .r = 0, .g = 255, .b = @intCast(255 - (diff - 64) * 4), .a = 255 };
    } else if (diff < 192) {
        return Color{ .r = @intCast((diff - 128) * 4), .g = 255, .b = 0, .a = 255 };
    } else {
        return Color{ .r = 255, .g = @intCast(255 - (diff - 192) * 4), .b = 0, .a = 255 };
    }
}

// ============================================================================
// Batch Processing
// ============================================================================

/// Batch operation to apply
pub const BatchOperation = union(enum) {
    resize: struct { width: u32, height: u32 },
    crop: struct { x: u32, y: u32, width: u32, height: u32 },
    rotate: enum { cw90, ccw90, rotate180, flip_h, flip_v },
    brightness: i16,
    contrast: f32,
    grayscale: void,
    blur: u32,
    sharpen: void,
    format: ImageFormat,
};

/// Batch processing options
pub const BatchOptions = struct {
    operations: []const BatchOperation,
    output_dir: []const u8,
    output_format: ?ImageFormat = null,
    preserve_structure: bool = true, // Preserve subdirectory structure
    overwrite: bool = false,
    on_progress: ?*const fn (current: usize, total: usize, path: []const u8) void = null,
    on_error: ?*const fn (path: []const u8, err: anyerror) void = null,
};

/// Process a batch of images
pub fn processBatch(
    input_paths: []const []const u8,
    options: BatchOptions,
    allocator: std.mem.Allocator,
) !BatchResult {
    var result = BatchResult{
        .processed = 0,
        .failed = 0,
        .skipped = 0,
        .errors = std.ArrayList(BatchError).init(allocator),
    };

    for (input_paths, 0..) |path, i| {
        if (options.on_progress) |callback| {
            callback(i, input_paths.len, path);
        }

        processOne(path, options, allocator) catch |err| {
            result.failed += 1;
            try result.errors.append(BatchError{
                .path = path,
                .err = err,
            });

            if (options.on_error) |callback| {
                callback(path, err);
            }
            continue;
        };

        result.processed += 1;
    }

    return result;
}

fn processOne(path: []const u8, options: BatchOptions, allocator: std.mem.Allocator) !void {
    // Load image
    var image = try Image.load(allocator, path);
    defer image.deinit();

    // Apply operations
    for (options.operations) |op| {
        switch (op) {
            .resize => |r| {
                try image.resizeBilinear(r.width, r.height);
            },
            .brightness => |b| {
                image.adjustBrightness(b);
            },
            .contrast => |c| {
                image.adjustContrast(c);
            },
            .grayscale => {
                try image.toGrayscale();
            },
            .blur => |r| {
                _ = r;
                try image.blur();
            },
            .sharpen => {
                try image.sharpen();
            },
            else => {},
        }
    }

    // Determine output path
    const basename = std.fs.path.basename(path);
    const output_path = try std.fs.path.join(allocator, &.{ options.output_dir, basename });
    defer allocator.free(output_path);

    // Save
    const format = options.output_format orelse ImageFormat.fromExtension(std.fs.path.extension(path));
    try image.saveAs(output_path, format);
}

pub const BatchResult = struct {
    processed: usize,
    failed: usize,
    skipped: usize,
    errors: std.ArrayList(BatchError),

    pub fn deinit(self: *BatchResult) void {
        self.errors.deinit();
    }
};

pub const BatchError = struct {
    path: []const u8,
    err: anyerror,
};

// ============================================================================
// Memory Pool
// ============================================================================

/// Memory pool for image operations
pub const ImagePool = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayList([]u8),
    free_list: std.ArrayList(usize),
    buffer_size: usize,
    max_buffers: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_buffers: usize) ImagePool {
        return ImagePool{
            .allocator = allocator,
            .buffers = std.ArrayList([]u8).init(allocator),
            .free_list = std.ArrayList(usize).init(allocator),
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
        };
    }

    pub fn deinit(self: *ImagePool) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit();
        self.free_list.deinit();
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *ImagePool) ![]u8 {
        if (self.free_list.items.len > 0) {
            const idx = self.free_list.pop();
            return self.buffers.items[idx];
        }

        if (self.buffers.items.len >= self.max_buffers) {
            return error.PoolExhausted;
        }

        const buffer = try self.allocator.alloc(u8, self.buffer_size);
        try self.buffers.append(buffer);
        return buffer;
    }

    /// Release a buffer back to the pool
    pub fn release(self: *ImagePool, buffer: []u8) void {
        for (self.buffers.items, 0..) |buf, i| {
            if (buf.ptr == buffer.ptr) {
                self.free_list.append(i) catch {};
                return;
            }
        }
    }

    /// Create an image using pool memory
    pub fn createImage(self: *ImagePool, width: u32, height: u32) !PooledImage {
        const required_size = @as(usize, width) * height * 4;
        if (required_size > self.buffer_size) {
            return error.ImageTooLarge;
        }

        const buffer = try self.acquire();

        return PooledImage{
            .width = width,
            .height = height,
            .pixels = buffer[0..required_size],
            .pool = self,
        };
    }
};

/// Image backed by pool memory
pub const PooledImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    pool: *ImagePool,

    pub fn release(self: *PooledImage) void {
        self.pool.release(self.pixels.ptr[0..self.pool.buffer_size]);
    }

    pub fn getPixel(self: *const PooledImage, x: u32, y: u32) ?Color {
        if (x >= self.width or y >= self.height) return null;
        const idx = (y * self.width + x) * 4;
        return Color{
            .r = self.pixels[idx],
            .g = self.pixels[idx + 1],
            .b = self.pixels[idx + 2],
            .a = self.pixels[idx + 3],
        };
    }

    pub fn setPixel(self: *PooledImage, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (y * self.width + x) * 4;
        self.pixels[idx] = color.r;
        self.pixels[idx + 1] = color.g;
        self.pixels[idx + 2] = color.b;
        self.pixels[idx + 3] = color.a;
    }
};

// ============================================================================
// Progress Reporting
// ============================================================================

/// Progress callback type
pub const ProgressCallback = *const fn (progress: f32, stage: []const u8) void;

/// Operation with progress reporting
pub const ProgressOperation = struct {
    callback: ?ProgressCallback = null,
    cancel_flag: *std.atomic.Value(bool),

    pub fn init(cancel_flag: *std.atomic.Value(bool)) ProgressOperation {
        return ProgressOperation{
            .cancel_flag = cancel_flag,
        };
    }

    pub fn isCancelled(self: *const ProgressOperation) bool {
        return self.cancel_flag.load(.acquire);
    }

    pub fn report(self: *const ProgressOperation, progress: f32, stage: []const u8) void {
        if (self.callback) |cb| {
            cb(progress, stage);
        }
    }
};

/// Context for long-running operations
pub const OperationContext = struct {
    allocator: std.mem.Allocator,
    progress: ?ProgressCallback = null,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *OperationContext) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const OperationContext) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn reportProgress(self: *const OperationContext, value: f32, stage: []const u8) void {
        if (self.progress) |cb| {
            cb(value, stage);
        }
    }
};

// ============================================================================
// Async Processing
// ============================================================================

/// Async operation result
pub fn AsyncResult(comptime T: type) type {
    return struct {
        result: ?T = null,
        err: ?anyerror = null,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mutex: std.Thread.Mutex = .{},

        const Self = @This();

        pub fn wait(self: *Self) !T {
            while (!self.completed.load(.acquire)) {
                std.time.sleep(1_000_000); // 1ms
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.err) |e| {
                return e;
            }
            return self.result.?;
        }

        pub fn isCompleted(self: *const Self) bool {
            return self.completed.load(.acquire);
        }

        fn setResult(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.result = value;
            self.completed.store(true, .release);
        }

        fn setError(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.err = err;
            self.completed.store(true, .release);
        }
    };
}

/// Load image asynchronously
pub fn loadAsync(
    allocator: std.mem.Allocator,
    path: []const u8,
) !*AsyncResult(Image) {
    const result = try allocator.create(AsyncResult(Image));
    result.* = .{};

    const path_copy = try allocator.dupe(u8, path);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(res: *AsyncResult(Image), p: []const u8, alloc: std.mem.Allocator) void {
            const image = Image.load(alloc, p) catch |err| {
                res.setError(err);
                alloc.free(p);
                return;
            };
            res.setResult(image);
            alloc.free(p);
        }
    }.run, .{ result, path_copy, allocator });

    thread.detach();

    return result;
}

/// Process image asynchronously with callback
pub fn processAsync(
    image: *Image,
    operation: fn (*Image) anyerror!void,
    on_complete: ?*const fn (err: ?anyerror) void,
) !void {
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(img: *Image, op: fn (*Image) anyerror!void, callback: ?*const fn (err: ?anyerror) void) void {
            const result = op(img);
            if (callback) |cb| {
                if (result) |_| {
                    cb(null);
                } else |err| {
                    cb(err);
                }
            }
        }
    }.run, .{ image, operation, on_complete });

    thread.detach();
}

// ============================================================================
// Image Utilities
// ============================================================================

/// Check if two images are identical
pub fn imagesEqual(img1: *const Image, img2: *const Image) bool {
    if (img1.width != img2.width or img1.height != img2.height) return false;
    if (img1.format != img2.format) return false;
    return std.mem.eql(u8, img1.pixels, img2.pixels);
}

/// Calculate image hash for quick comparison
pub fn imageHash(image: *const Image) u64 {
    var hash: u64 = 0;
    const step = @max(1, image.pixels.len / 64);

    var i: usize = 0;
    while (i < image.pixels.len) : (i += step) {
        hash = hash *% 31 +% image.pixels[i];
    }

    return hash;
}

/// Create thumbnail preserving aspect ratio
pub fn createThumbnail(
    image: *const Image,
    max_width: u32,
    max_height: u32,
    allocator: std.mem.Allocator,
) !Image {
    const aspect = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(image.height));
    var new_width = max_width;
    var new_height = max_height;

    if (@as(f32, @floatFromInt(max_width)) / aspect > @as(f32, @floatFromInt(max_height))) {
        new_width = @intFromFloat(@as(f32, @floatFromInt(max_height)) * aspect);
    } else {
        new_height = @intFromFloat(@as(f32, @floatFromInt(max_width)) / aspect);
    }

    var result = try image.clone();
    try result.resizeBilinear(new_width, new_height);
    _ = allocator;

    return result;
}

/// Tile image into a grid
pub fn tileImage(
    image: *const Image,
    cols: u32,
    rows: u32,
    allocator: std.mem.Allocator,
) !Image {
    const result_width = image.width * cols;
    const result_height = image.height * rows;

    var result = try Image.init(allocator, result_width, result_height, image.format);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const offset_x = col * image.width;
            const offset_y = row * image.height;

            var y: u32 = 0;
            while (y < image.height) : (y += 1) {
                var x: u32 = 0;
                while (x < image.width) : (x += 1) {
                    if (image.getPixel(x, y)) |c| {
                        result.setPixel(offset_x + x, offset_y + y, c);
                    }
                }
            }
        }
    }

    return result;
}

/// Split image into tiles
pub fn splitIntoTiles(
    image: *const Image,
    tile_width: u32,
    tile_height: u32,
    allocator: std.mem.Allocator,
) ![]Image {
    const cols = (image.width + tile_width - 1) / tile_width;
    const rows = (image.height + tile_height - 1) / tile_height;
    const num_tiles = cols * rows;

    var tiles = try allocator.alloc(Image, num_tiles);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const tile_idx = row * cols + col;
            const src_x = col * tile_width;
            const src_y = row * tile_height;
            const actual_width = @min(tile_width, image.width - src_x);
            const actual_height = @min(tile_height, image.height - src_y);

            tiles[tile_idx] = try Image.init(allocator, actual_width, actual_height, image.format);

            var y: u32 = 0;
            while (y < actual_height) : (y += 1) {
                var x: u32 = 0;
                while (x < actual_width) : (x += 1) {
                    if (image.getPixel(src_x + x, src_y + y)) |c| {
                        tiles[tile_idx].setPixel(x, y, c);
                    }
                }
            }
        }
    }

    return tiles;
}

/// Pad image to specific dimensions
pub fn padImage(
    image: *const Image,
    target_width: u32,
    target_height: u32,
    pad_color: Color,
    allocator: std.mem.Allocator,
) !Image {
    var result = try Image.init(allocator, target_width, target_height, image.format);

    // Fill with pad color
    var y: u32 = 0;
    while (y < target_height) : (y += 1) {
        var x: u32 = 0;
        while (x < target_width) : (x += 1) {
            result.setPixel(x, y, pad_color);
        }
    }

    // Copy original image centered
    const offset_x = (target_width - image.width) / 2;
    const offset_y = (target_height - image.height) / 2;

    y = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            if (image.getPixel(x, y)) |c| {
                result.setPixel(offset_x + x, offset_y + y, c);
            }
        }
    }

    return result;
}

// ============================================================================
// Arena Allocator Helper
// ============================================================================

/// Create arena allocator for image operations
pub fn createArena(backing_allocator: std.mem.Allocator) std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(backing_allocator);
}

/// Image operation scope with automatic cleanup
pub fn withArena(
    backing_allocator: std.mem.Allocator,
    comptime operation: fn (allocator: std.mem.Allocator) anyerror!void,
) !void {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();

    try operation(arena.allocator());
}
