// Home Programming Language - Arena Allocator
// Fast bump allocator for temporary allocations

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

/// Arena configuration
pub const ArenaConfig = struct {
    /// Initial buffer size
    initial_size: usize,
    /// Enable automatic growth when buffer is full
    auto_grow: bool = false,
    /// Growth factor for automatic expansion
    growth_factor: f64 = 2.0,
    /// Maximum total size (0 = unlimited)
    max_size: usize = 0,
};

/// Buffer segment in multi-buffer arena
const BufferSegment = struct {
    buffer: []u8,
    offset: usize,
    next: ?*BufferSegment,
};

pub const Arena = struct {
    buffer: []u8,
    offset: usize,
    stats: MemStats,
    parent_allocator: std.mem.Allocator,
    config: ArenaConfig,
    segments: ?*BufferSegment, // For multi-buffer support
    total_capacity: usize,

    pub fn init(parent: std.mem.Allocator, size: usize) AllocatorError!Arena {
        return initWithConfig(parent, .{ .initial_size = size });
    }

    pub fn initWithConfig(parent: std.mem.Allocator, config: ArenaConfig) AllocatorError!Arena {
        const buffer = parent.alloc(u8, config.initial_size) catch return AllocatorError.OutOfMemory;
        return Arena{
            .buffer = buffer,
            .offset = 0,
            .stats = MemStats.init(),
            .parent_allocator = parent,
            .config = config,
            .segments = null,
            .total_capacity = config.initial_size,
        };
    }

    pub fn deinit(self: *Arena) void {
        // Free all segments
        var current = self.segments;
        while (current) |segment| {
            const next = segment.next;
            self.parent_allocator.free(segment.buffer);
            self.parent_allocator.destroy(segment);
            current = next;
        }
        self.parent_allocator.free(self.buffer);
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));

        const alignment = ptr_align.toByteUnits();
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const new_offset = aligned_offset + len;

        if (new_offset > self.buffer.len) {
            // Try to grow if enabled
            if (self.config.auto_grow) {
                const success = self.grow(len) catch return null;
                if (success) {
                    // Retry allocation after growth
                    return alloc(ctx, len, ptr_align, ret_addr);
                }
            }
            return null; // Out of arena memory
        }

        const result = self.buffer.ptr + aligned_offset;
        self.offset = new_offset;
        self.stats.recordAlloc(len);

        return result;
    }

    /// Grow the arena by allocating a new buffer segment
    fn grow(self: *Arena, min_size: usize) !bool {
        // Calculate new buffer size
        const current_size = self.buffer.len;
        const growth_size = @max(
            min_size,
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(current_size)) * self.config.growth_factor)),
        );

        // Check max size limit
        if (self.config.max_size > 0 and self.total_capacity + growth_size > self.config.max_size) {
            return false;
        }

        // Allocate new buffer
        const new_buffer = self.parent_allocator.alloc(u8, growth_size) catch return false;

        // Create new segment for old buffer
        const segment = self.parent_allocator.create(BufferSegment) catch {
            self.parent_allocator.free(new_buffer);
            return false;
        };

        segment.* = .{
            .buffer = self.buffer,
            .offset = self.offset,
            .next = self.segments,
        };
        self.segments = segment;

        // Switch to new buffer
        self.buffer = new_buffer;
        self.offset = 0;
        self.total_capacity += growth_size;

        return true;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return false; // Arena doesn't support resize
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;
        // Arena doesn't free individual allocations
        self.stats.recordFree(buf.len);
    }

    pub fn reset(self: *Arena) void {
        self.offset = 0;
        self.stats = MemStats.init();
    }

    pub fn getStats(self: *const Arena) MemStats {
        return self.stats;
    }
};

test "arena allocator" {
    const testing = std.testing;

    var arena = try Arena.init(testing.allocator, 1024);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Allocate some memory
    const bytes = try allocator.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 100), bytes.len);

    // Allocate more
    const more = try allocator.alloc(u32, 10);
    try testing.expectEqual(@as(usize, 10), more.len);

    // Reset and reuse
    arena.reset();
    const reused = try allocator.alloc(u8, 50);
    try testing.expectEqual(@as(usize, 50), reused.len);
}

test "arena auto-grow" {
    const testing = std.testing;

    var arena = try Arena.initWithConfig(testing.allocator, .{
        .initial_size = 512,
        .auto_grow = true,
        .growth_factor = 2.0,
    });
    defer arena.deinit();

    const allocator = arena.allocator();

    // Fill initial buffer
    const first = try allocator.alloc(u8, 400);
    try testing.expectEqual(@as(usize, 400), first.len);

    // This should trigger growth
    const second = try allocator.alloc(u8, 200);
    try testing.expectEqual(@as(usize, 200), second.len);

    // Verify we have at least 2 buffers (original + 1 segment)
    try testing.expect(arena.total_capacity > 512);
}

test "arena max size limit" {
    const testing = std.testing;

    var arena = try Arena.initWithConfig(testing.allocator, .{
        .initial_size = 256,
        .auto_grow = true,
        .max_size = 1024,
    });
    defer arena.deinit();

    const allocator = arena.allocator();

    // Fill up to limit
    _ = try allocator.alloc(u8, 200);
    _ = try allocator.alloc(u8, 400);

    // This should fail - would exceed max_size
    const result = allocator.alloc(u8, 500);
    try testing.expectError(error.OutOfMemory, result);
}
