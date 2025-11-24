// Parallel Image Processing
// Multi-threaded operations for improved performance

const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;
const simd_ops = @import("simd.zig");

// ============================================================================
// Thread Pool
// ============================================================================

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    task_queue: TaskQueue,
    running: std.atomic.Value(bool),
    active_tasks: std.atomic.Value(u32),

    const TaskQueue = std.fifo.LinearFifo(Task, .Dynamic);

    pub fn init(allocator: std.mem.Allocator, thread_count: ?usize) !ThreadPool {
        const count = thread_count orelse (std.Thread.getCpuCount() catch 4);
        const threads = try allocator.alloc(std.Thread, count);

        var pool = ThreadPool{
            .allocator = allocator,
            .threads = threads,
            .task_queue = TaskQueue.init(allocator),
            .running = std.atomic.Value(bool).init(true),
            .active_tasks = std.atomic.Value(u32).init(0),
        };

        for (threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{ &pool, i });
        }

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        self.running.store(false, .release);

        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.task_queue.deinit();
    }

    pub fn submit(self: *ThreadPool, task: Task) !void {
        try self.task_queue.writeItem(task);
        _ = self.active_tasks.fetchAdd(1, .monotonic);
    }

    pub fn waitForAll(self: *ThreadPool) void {
        while (self.active_tasks.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
    }

    fn workerLoop(pool: *ThreadPool, thread_id: usize) void {
        _ = thread_id;
        while (pool.running.load(.acquire)) {
            if (pool.task_queue.readItem()) |task| {
                task.execute();
                _ = pool.active_tasks.fetchSub(1, .release);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

pub const Task = struct {
    func: *const fn (*anyopaque) void,
    context: *anyopaque,

    pub fn execute(self: Task) void {
        self.func(self.context);
    }
};

// ============================================================================
// Parallel Row Processing
// ============================================================================

pub const RowProcessor = *const fn (row: []u8, y: u32, width: u32, context: ?*anyopaque) void;

/// Context for row-parallel processing
const RowTaskContext = struct {
    img_pixels: []u8,
    width: u32,
    height: u32,
    bpp: u8,
    start_row: u32,
    end_row: u32,
    processor: RowProcessor,
    user_context: ?*anyopaque,
};

fn rowTaskExecutor(ctx_ptr: *anyopaque) void {
    const ctx: *RowTaskContext = @ptrCast(@alignCast(ctx_ptr));

    const row_stride = @as(usize, ctx.width) * ctx.bpp;

    var y = ctx.start_row;
    while (y < ctx.end_row) : (y += 1) {
        const row_offset = @as(usize, y) * row_stride;
        const row = ctx.img_pixels[row_offset..][0..row_stride];
        ctx.processor(row, y, ctx.width, ctx.user_context);
    }
}

/// Process image rows in parallel
pub fn processRowsParallel(
    img: *Image,
    processor: RowProcessor,
    context: ?*anyopaque,
    thread_count: ?usize,
) !void {
    const num_threads = thread_count orelse @min(
        std.Thread.getCpuCount() catch 4,
        img.height,
    );

    if (num_threads <= 1 or img.height < 4) {
        // Fall back to single-threaded
        const bpp = img.format.bytesPerPixel();
        const row_stride = @as(usize, img.width) * bpp;

        for (0..img.height) |y| {
            const row_offset = y * row_stride;
            processor(img.pixels[row_offset..][0..row_stride], @intCast(y), img.width, context);
        }
        return;
    }

    const bpp = img.format.bytesPerPixel();
    const rows_per_thread = img.height / @as(u32, @intCast(num_threads));

    var contexts = try std.heap.page_allocator.alloc(RowTaskContext, num_threads);
    defer std.heap.page_allocator.free(contexts);

    var threads = try std.heap.page_allocator.alloc(std.Thread, num_threads);
    defer std.heap.page_allocator.free(threads);

    for (0..num_threads) |i| {
        const start_row = @as(u32, @intCast(i)) * rows_per_thread;
        const end_row = if (i == num_threads - 1) img.height else start_row + rows_per_thread;

        contexts[i] = RowTaskContext{
            .img_pixels = img.pixels,
            .width = img.width,
            .height = img.height,
            .bpp = bpp,
            .start_row = start_row,
            .end_row = end_row,
            .processor = processor,
            .user_context = context,
        };

        threads[i] = try std.Thread.spawn(.{}, rowTaskExecutor, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }
}

// ============================================================================
// Parallel Tile Processing
// ============================================================================

pub const TileProcessor = *const fn (
    tile_pixels: []u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    img_width: u32,
    context: ?*anyopaque,
) void;

const TileTaskContext = struct {
    img_pixels: []u8,
    img_width: u32,
    img_height: u32,
    bpp: u8,
    tile_x: u32,
    tile_y: u32,
    tile_width: u32,
    tile_height: u32,
    processor: TileProcessor,
    user_context: ?*anyopaque,
};

fn tileTaskExecutor(ctx_ptr: *anyopaque) void {
    const ctx: *TileTaskContext = @ptrCast(@alignCast(ctx_ptr));

    const row_stride = @as(usize, ctx.img_width) * ctx.bpp;
    const actual_width = @min(ctx.tile_width, ctx.img_width - ctx.tile_x);
    const actual_height = @min(ctx.tile_height, ctx.img_height - ctx.tile_y);

    // Process each row of the tile
    for (0..actual_height) |local_y| {
        const img_y = ctx.tile_y + @as(u32, @intCast(local_y));
        const row_offset = @as(usize, img_y) * row_stride + @as(usize, ctx.tile_x) * ctx.bpp;
        const tile_row = ctx.img_pixels[row_offset..][0 .. @as(usize, actual_width) * ctx.bpp];

        ctx.processor(
            tile_row,
            ctx.tile_x,
            img_y,
            actual_width,
            1,
            ctx.img_width,
            ctx.user_context,
        );
    }
}

/// Process image tiles in parallel
pub fn processTilesParallel(
    img: *Image,
    tile_width: u32,
    tile_height: u32,
    processor: TileProcessor,
    context: ?*anyopaque,
) !void {
    const tiles_x = (img.width + tile_width - 1) / tile_width;
    const tiles_y = (img.height + tile_height - 1) / tile_height;
    const total_tiles = tiles_x * tiles_y;

    const num_threads = @min(
        std.Thread.getCpuCount() catch 4,
        total_tiles,
    );

    if (num_threads <= 1) {
        // Single-threaded fallback
        const bpp = img.format.bytesPerPixel();
        const row_stride = @as(usize, img.width) * bpp;

        for (0..tiles_y) |ty| {
            for (0..tiles_x) |tx| {
                const tile_x = @as(u32, @intCast(tx)) * tile_width;
                const tile_y = @as(u32, @intCast(ty)) * tile_height;
                const actual_width = @min(tile_width, img.width - tile_x);
                const actual_height = @min(tile_height, img.height - tile_y);

                for (0..actual_height) |local_y| {
                    const img_y = tile_y + @as(u32, @intCast(local_y));
                    const row_offset = @as(usize, img_y) * row_stride + @as(usize, tile_x) * bpp;
                    const tile_row = img.pixels[row_offset..][0 .. @as(usize, actual_width) * bpp];

                    processor(tile_row, tile_x, img_y, actual_width, 1, img.width, context);
                }
            }
        }
        return;
    }

    const bpp = img.format.bytesPerPixel();

    var contexts = try std.heap.page_allocator.alloc(TileTaskContext, total_tiles);
    defer std.heap.page_allocator.free(contexts);

    var threads = try std.heap.page_allocator.alloc(std.Thread, total_tiles);
    defer std.heap.page_allocator.free(threads);

    var task_idx: usize = 0;
    for (0..tiles_y) |ty| {
        for (0..tiles_x) |tx| {
            contexts[task_idx] = TileTaskContext{
                .img_pixels = img.pixels,
                .img_width = img.width,
                .img_height = img.height,
                .bpp = bpp,
                .tile_x = @as(u32, @intCast(tx)) * tile_width,
                .tile_y = @as(u32, @intCast(ty)) * tile_height,
                .tile_width = tile_width,
                .tile_height = tile_height,
                .processor = processor,
                .user_context = context,
            };

            threads[task_idx] = try std.Thread.spawn(.{}, tileTaskExecutor, .{&contexts[task_idx]});
            task_idx += 1;
        }
    }

    // Wait for all threads
    for (0..task_idx) |i| {
        threads[i].join();
    }
}

// ============================================================================
// Parallel SIMD Operations
// ============================================================================

/// Parallel brightness adjustment
pub fn adjustBrightnessParallel(img: *Image, adjustment: i16) !void {
    const Context = struct {
        adj: i16,
    };

    var ctx = Context{ .adj = adjustment };

    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, context: ?*anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            simd_ops.adjustBrightness(row, c.adj);
        }
    }.process;

    try processRowsParallel(img, processor, &ctx, null);
}

/// Parallel contrast adjustment
pub fn adjustContrastParallel(img: *Image, factor: f32) !void {
    const Context = struct {
        f: f32,
    };

    var ctx = Context{ .f = factor };

    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, context: ?*anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            simd_ops.adjustContrast(row, c.f);
        }
    }.process;

    try processRowsParallel(img, processor, &ctx, null);
}

/// Parallel gamma correction
pub fn adjustGammaParallel(img: *Image, gamma: f32) !void {
    const Context = struct {
        g: f32,
    };

    var ctx = Context{ .g = gamma };

    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, context: ?*anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            simd_ops.adjustGamma(row, c.g);
        }
    }.process;

    try processRowsParallel(img, processor, &ctx, null);
}

/// Parallel color inversion
pub fn invertColorsParallel(img: *Image) !void {
    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, _: ?*anyopaque) void {
            simd_ops.invertColors(row);
        }
    }.process;

    try processRowsParallel(img, processor, null, null);
}

/// Parallel RGBA to BGRA conversion
pub fn rgbaToBgraParallel(img: *Image) !void {
    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, _: ?*anyopaque) void {
            simd_ops.rgbaToBgra(row);
        }
    }.process;

    try processRowsParallel(img, processor, null, null);
}

/// Parallel grayscale conversion
pub fn toGrayscaleParallel(img: *Image) !void {
    if (img.format != .rgba8) return;

    const processor = struct {
        fn process(row: []u8, _: u32, width: u32, _: ?*anyopaque) void {
            // Convert each pixel to grayscale in place
            var i: usize = 0;
            while (i + 4 <= row.len) : (i += 4) {
                const r: u16 = row[i];
                const g: u16 = row[i + 1];
                const b: u16 = row[i + 2];
                const gray: u8 = @intCast((77 * r + 150 * g + 29 * b) >> 8);
                row[i] = gray;
                row[i + 1] = gray;
                row[i + 2] = gray;
                // Alpha unchanged
            }
            _ = width;
        }
    }.process;

    try processRowsParallel(img, processor, null, null);
}

/// Parallel alpha premultiplication
pub fn premultiplyAlphaParallel(img: *Image) !void {
    const processor = struct {
        fn process(row: []u8, _: u32, _: u32, _: ?*anyopaque) void {
            simd_ops.premultiplyAlpha(row);
        }
    }.process;

    try processRowsParallel(img, processor, null, null);
}

// ============================================================================
// Parallel Image Copy/Transform
// ============================================================================

/// Parallel image copy
pub fn copyParallel(src: *const Image, dst: *Image) !void {
    if (src.width != dst.width or src.height != dst.height) return error.DimensionMismatch;
    if (src.format != dst.format) return error.FormatMismatch;

    const Context = struct {
        src_pixels: []const u8,
        dst_pixels: []u8,
        row_size: usize,
    };

    const bpp = src.format.bytesPerPixel();
    var ctx = Context{
        .src_pixels = src.pixels,
        .dst_pixels = dst.pixels,
        .row_size = @as(usize, src.width) * bpp,
    };

    const processor = struct {
        fn process(_: []u8, y: u32, _: u32, context: ?*anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            const offset = @as(usize, y) * c.row_size;
            @memcpy(c.dst_pixels[offset..][0..c.row_size], c.src_pixels[offset..][0..c.row_size]);
        }
    }.process;

    try processRowsParallel(dst, processor, &ctx, null);
}

// ============================================================================
// Parallel Statistics
// ============================================================================

/// Compute histogram in parallel
pub fn computeHistogramParallel(img: *const Image) !struct { r: [256]u32, g: [256]u32, b: [256]u32 } {
    if (img.format != .rgba8) {
        return .{ .r = [_]u32{0} ** 256, .g = [_]u32{0} ** 256, .b = [_]u32{0} ** 256 };
    }

    const num_threads = std.Thread.getCpuCount() catch 4;
    const rows_per_thread = img.height / @as(u32, @intCast(num_threads));

    const PartialHist = struct {
        r: [256]u32,
        g: [256]u32,
        b: [256]u32,
    };

    var partial_hists = try std.heap.page_allocator.alloc(PartialHist, num_threads);
    defer std.heap.page_allocator.free(partial_hists);

    for (partial_hists) |*h| {
        h.r = [_]u32{0} ** 256;
        h.g = [_]u32{0} ** 256;
        h.b = [_]u32{0} ** 256;
    }

    const Context = struct {
        pixels: []const u8,
        width: u32,
        start_row: u32,
        end_row: u32,
        hist: *PartialHist,
    };

    var contexts = try std.heap.page_allocator.alloc(Context, num_threads);
    defer std.heap.page_allocator.free(contexts);

    var threads = try std.heap.page_allocator.alloc(std.Thread, num_threads);
    defer std.heap.page_allocator.free(threads);

    for (0..num_threads) |i| {
        const start_row = @as(u32, @intCast(i)) * rows_per_thread;
        const end_row = if (i == num_threads - 1) img.height else start_row + rows_per_thread;

        contexts[i] = Context{
            .pixels = img.pixels,
            .width = img.width,
            .start_row = start_row,
            .end_row = end_row,
            .hist = &partial_hists[i],
        };

        const worker = struct {
            fn run(ctx: *Context) void {
                const row_stride = @as(usize, ctx.width) * 4;

                var y = ctx.start_row;
                while (y < ctx.end_row) : (y += 1) {
                    const row_offset = @as(usize, y) * row_stride;

                    var x: usize = 0;
                    while (x + 4 <= row_stride) : (x += 4) {
                        ctx.hist.r[ctx.pixels[row_offset + x]] += 1;
                        ctx.hist.g[ctx.pixels[row_offset + x + 1]] += 1;
                        ctx.hist.b[ctx.pixels[row_offset + x + 2]] += 1;
                    }
                }
            }
        }.run;

        threads[i] = try std.Thread.spawn(.{}, worker, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Merge partial histograms
    var result: struct { r: [256]u32, g: [256]u32, b: [256]u32 } = .{
        .r = [_]u32{0} ** 256,
        .g = [_]u32{0} ** 256,
        .b = [_]u32{0} ** 256,
    };

    for (partial_hists) |h| {
        for (0..256) |i| {
            result.r[i] += h.r[i];
            result.g[i] += h.g[i];
            result.b[i] += h.b[i];
        }
    }

    return result;
}

// ============================================================================
// Batch Processing
// ============================================================================

/// Process multiple images in parallel
pub fn processBatch(
    allocator: std.mem.Allocator,
    images: []Image,
    processor: *const fn (*Image) anyerror!void,
) !void {
    var threads = try allocator.alloc(std.Thread, images.len);
    defer allocator.free(threads);

    const Context = struct {
        img: *Image,
        proc: *const fn (*Image) anyerror!void,
        err: ?anyerror,
    };

    var contexts = try allocator.alloc(Context, images.len);
    defer allocator.free(contexts);

    for (images, 0..) |*img, i| {
        contexts[i] = Context{
            .img = img,
            .proc = processor,
            .err = null,
        };

        const worker = struct {
            fn run(ctx: *Context) void {
                ctx.proc(ctx.img) catch |e| {
                    ctx.err = e;
                };
            }
        }.run;

        threads[i] = try std.Thread.spawn(.{}, worker, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (contexts) |ctx| {
        if (ctx.err) |e| {
            return e;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Parallel row processing" {
    var img = try Image.init(std.testing.allocator, 100, 100, .rgba8);
    defer img.deinit();

    // Fill with gray
    @memset(img.pixels, 128);

    // Apply brightness adjustment
    try adjustBrightnessParallel(&img, 50);

    // Check result
    try std.testing.expectEqual(@as(u8, 178), img.pixels[0]);
}

test "Parallel invert" {
    var img = try Image.init(std.testing.allocator, 64, 64, .rgba8);
    defer img.deinit();

    // Fill with value
    for (0..img.pixels.len / 4) |i| {
        img.pixels[i * 4] = 100;
        img.pixels[i * 4 + 1] = 150;
        img.pixels[i * 4 + 2] = 200;
        img.pixels[i * 4 + 3] = 255;
    }

    try invertColorsParallel(&img);

    // Check inverted values
    try std.testing.expectEqual(@as(u8, 155), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 105), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 55), img.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[3]); // Alpha unchanged
}
