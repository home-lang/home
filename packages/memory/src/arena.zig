// Home Programming Language - Arena Allocator
// Fast bump allocator for temporary allocations

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

pub const Arena = struct {
    buffer: []u8,
    offset: usize,
    stats: MemStats,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent: std.mem.Allocator, size: usize) AllocatorError!Arena {
        const buffer = parent.alloc(u8, size) catch return AllocatorError.OutOfMemory;
        return Arena{
            .buffer = buffer,
            .offset = 0,
            .stats = MemStats.init(),
            .parent_allocator = parent,
        };
    }

    pub fn deinit(self: *Arena) void {
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
        _ = ret_addr;

        const alignment = ptr_align.toByteUnits();
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const new_offset = aligned_offset + len;

        if (new_offset > self.buffer.len) {
            return null; // Out of arena memory
        }

        const result = self.buffer.ptr + aligned_offset;
        self.offset = new_offset;
        self.stats.recordAlloc(len);

        return result;
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
