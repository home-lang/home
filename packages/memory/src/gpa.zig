// Home Programming Language - General Purpose Allocator
// Variable-size allocator with best-fit strategy

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

pub const GeneralPurpose = struct {
    inner: std.heap.GeneralPurposeAllocator(.{}),
    stats: MemStats,

    pub fn init() GeneralPurpose {
        return GeneralPurpose{
            .inner = std.heap.GeneralPurposeAllocator(.{}){},
            .stats = MemStats.init(),
        };
    }

    pub fn deinit(self: *GeneralPurpose) bool {
        return self.inner.deinit() == .leak;
    }

    pub fn allocator(self: *GeneralPurpose) std.mem.Allocator {
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
        const self: *GeneralPurpose = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();

        const result = inner_alloc.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        self.stats.recordAlloc(len);

        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GeneralPurpose = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();

        const result = inner_alloc.rawResize(buf, buf_align, new_len, ret_addr);

        if (result) {
            if (new_len > buf.len) {
                self.stats.recordAlloc(new_len - buf.len);
            } else {
                self.stats.recordFree(buf.len - new_len);
            }
        }

        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *GeneralPurpose = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();

        inner_alloc.rawFree(buf, buf_align, ret_addr);
        self.stats.recordFree(buf.len);
    }

    pub fn getStats(self: *const GeneralPurpose) MemStats {
        return self.stats;
    }
};

test "gpa allocator" {
    const testing = std.testing;

    var gpa = GeneralPurpose.init();
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Allocate various sizes
    const small = try allocator.alloc(u8, 10);
    const medium = try allocator.alloc(u32, 100);
    const large = try allocator.alloc(u64, 1000);

    try testing.expectEqual(@as(usize, 10), small.len);
    try testing.expectEqual(@as(usize, 100), medium.len);
    try testing.expectEqual(@as(usize, 1000), large.len);

    // Free in different order
    allocator.free(medium);
    allocator.free(small);
    allocator.free(large);

    // Verify stats
    const stats = gpa.getStats();
    try testing.expect(stats.num_allocations == 3);
    try testing.expect(stats.num_frees == 3);
}
