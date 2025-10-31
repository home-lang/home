// Home Programming Language - Stack Allocator
// LIFO allocator for scoped temporary allocations

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

pub const StackAllocator = struct {
    buffer: []u8,
    offset: usize,
    prev_offset: usize,
    stats: MemStats,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent: std.mem.Allocator, size: usize) AllocatorError!StackAllocator {
        const buffer = parent.alloc(u8, size) catch return AllocatorError.OutOfMemory;
        return StackAllocator{
            .buffer = buffer,
            .offset = 0,
            .prev_offset = 0,
            .stats = MemStats.init(),
            .parent_allocator = parent,
        };
    }

    pub fn deinit(self: *StackAllocator) void {
        self.parent_allocator.free(self.buffer);
    }

    pub fn allocator(self: *StackAllocator) std.mem.Allocator {
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
        const self: *StackAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;

        const alignment = ptr_align.toByteUnits();
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const new_offset = aligned_offset + len;

        if (new_offset > self.buffer.len) {
            return null; // Stack overflow
        }

        const result = self.buffer.ptr + aligned_offset;
        self.prev_offset = self.offset;
        self.offset = new_offset;
        self.stats.recordAlloc(len);

        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StackAllocator = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;

        // Only resize if this is the most recent allocation
        const buf_addr = @intFromPtr(buf.ptr);
        const buffer_addr = @intFromPtr(self.buffer.ptr);
        const expected_addr = buffer_addr + self.prev_offset;

        if (buf_addr != expected_addr) {
            return false; // Not the top of stack
        }

        const aligned_offset = std.mem.alignForward(usize, self.prev_offset, @alignOf(u8));
        const new_offset = aligned_offset + new_len;

        if (new_offset > self.buffer.len) {
            return false; // Would overflow
        }

        // Update stats
        if (new_len > buf.len) {
            self.stats.recordAlloc(new_len - buf.len);
        } else {
            self.stats.recordFree(buf.len - new_len);
        }

        self.offset = new_offset;
        return true;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *StackAllocator = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;

        // Only free if this is the most recent allocation (LIFO)
        const buf_addr = @intFromPtr(buf.ptr);
        const buffer_addr = @intFromPtr(self.buffer.ptr);
        const expected_addr = buffer_addr + self.prev_offset;

        if (buf_addr == expected_addr) {
            self.offset = self.prev_offset;
            self.stats.recordFree(buf.len);
        }
    }

    pub fn reset(self: *StackAllocator) void {
        self.offset = 0;
        self.prev_offset = 0;
        self.stats = MemStats.init();
    }

    pub fn getStats(self: *const StackAllocator) MemStats {
        return self.stats;
    }
};

test "stack allocator" {
    const testing = std.testing;

    var stack = try StackAllocator.init(testing.allocator, 1024);
    defer stack.deinit();

    const allocator = stack.allocator();

    // Allocate in stack order
    const first = try allocator.alloc(u8, 100);
    const second = try allocator.alloc(u32, 50);
    const third = try allocator.alloc(u64, 25);

    try testing.expectEqual(@as(usize, 100), first.len);
    try testing.expectEqual(@as(usize, 50), second.len);
    try testing.expectEqual(@as(usize, 25), third.len);

    // Free in LIFO order
    allocator.free(third);
    allocator.free(second);
    allocator.free(first);

    // Reset and reuse
    stack.reset();
    const reused = try allocator.alloc(u8, 200);
    try testing.expectEqual(@as(usize, 200), reused.len);
}
