// Home Programming Language - Pool Allocator
// Fixed-size block allocator for objects

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

pub const Pool = struct {
    block_size: usize,
    block_count: usize,
    free_list: ?*FreeNode,
    buffer: []u8,
    stats: MemStats,
    parent_allocator: std.mem.Allocator,

    const FreeNode = struct {
        next: ?*FreeNode,
    };

    pub fn init(parent: std.mem.Allocator, block_size: usize, block_count: usize) AllocatorError!Pool {
        const actual_block_size = @max(block_size, @sizeOf(FreeNode));
        const buffer_size = actual_block_size * block_count;
        const buffer = parent.alloc(u8, buffer_size) catch return AllocatorError.OutOfMemory;

        var pool = Pool{
            .block_size = actual_block_size,
            .block_count = block_count,
            .free_list = null,
            .buffer = buffer,
            .stats = MemStats.init(),
            .parent_allocator = parent,
        };

        // Initialize free list
        var i: usize = 0;
        while (i < block_count) : (i += 1) {
            const block_ptr = @as(*FreeNode, @ptrCast(@alignCast(buffer.ptr + (i * actual_block_size))));
            block_ptr.next = pool.free_list;
            pool.free_list = block_ptr;
        }

        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.parent_allocator.free(self.buffer);
    }

    pub fn allocator(self: *Pool) std.mem.Allocator {
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
        const self: *Pool = @ptrCast(@alignCast(ctx));
        _ = ptr_align;
        _ = ret_addr;

        if (len > self.block_size) {
            return null; // Block too large
        }

        const node = self.free_list orelse return null; // Pool exhausted
        self.free_list = node.next;
        self.stats.recordAlloc(self.block_size);

        return @ptrCast(node);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        return new_len <= self.block_size;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;

        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = self.free_list;
        self.free_list = node;
        self.stats.recordFree(self.block_size);
    }

    pub fn getStats(self: *const Pool) MemStats {
        return self.stats;
    }
};

test "pool allocator" {
    const testing = std.testing;

    var pool = try Pool.init(testing.allocator, 64, 10);
    defer pool.deinit();

    const allocator = pool.allocator();

    // Allocate blocks
    const block1 = try allocator.alloc(u8, 32);
    const block2 = try allocator.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 32), block1.len);
    try testing.expectEqual(@as(usize, 64), block2.len);

    // Free and reuse
    allocator.free(block1);
    const block3 = try allocator.alloc(u8, 16);
    try testing.expectEqual(@as(usize, 16), block3.len);
}
