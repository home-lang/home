// Home Programming Language - Thread-Safe Allocator
// Wrapper that adds mutex protection to any allocator

const std = @import("std");
const AllocatorError = @import("memory.zig").AllocatorError;
const MemStats = @import("memory.zig").MemStats;
const Mutex = @import("memory.zig").Mutex;

pub const ThreadSafeAllocator = struct {
    inner_allocator: std.mem.Allocator,
    mutex: Mutex,
    stats: MemStats,

    pub fn init(inner: std.mem.Allocator) ThreadSafeAllocator {
        return ThreadSafeAllocator{
            .inner_allocator = inner,
            .mutex = Mutex.init(),
            .stats = MemStats.init(),
        };
    }

    pub fn deinit(self: *ThreadSafeAllocator) void {
        self.mutex.deinit();
    }

    pub fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
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
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock() catch return null;
        defer self.mutex.unlock() catch {};

        const result = self.inner_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.stats.recordAlloc(len);
        }

        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock() catch return false;
        defer self.mutex.unlock() catch {};

        const result = self.inner_allocator.rawResize(buf, buf_align, new_len, ret_addr);

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
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock() catch return;
        defer self.mutex.unlock() catch {};

        self.inner_allocator.rawFree(buf, buf_align, ret_addr);
        self.stats.recordFree(buf.len);
    }

    pub fn getStats(self: *ThreadSafeAllocator) MemStats {
        self.mutex.lock() catch return MemStats.init();
        defer self.mutex.unlock() catch {};

        return self.stats;
    }
};

test "thread safe allocator" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var thread_safe = ThreadSafeAllocator.init(gpa.allocator());
    defer thread_safe.deinit();

    const allocator = thread_safe.allocator();

    // Basic allocation test
    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(usize, 100), bytes.len);

    // Verify stats
    const stats = thread_safe.getStats();
    try testing.expect(stats.num_allocations >= 1);
}

test "thread safe concurrent access" {
    const testing = std.testing;
    const Thread = std.Thread;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var thread_safe = ThreadSafeAllocator.init(gpa.allocator());
    defer thread_safe.deinit();

    const allocator = thread_safe.allocator();

    const WorkerContext = struct {
        alloc: std.mem.Allocator,

        fn worker(ctx: @This()) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                const bytes = ctx.alloc.alloc(u8, 100) catch return;
                ctx.alloc.free(bytes);
            }
        }
    };

    const ctx = WorkerContext{ .alloc = allocator };

    // Spawn multiple threads
    const t1 = try Thread.spawn(testing.allocator, WorkerContext.worker, .{ctx});
    const t2 = try Thread.spawn(testing.allocator, WorkerContext.worker, .{ctx});

    try t1.join();
    try t2.join();

    // Verify stats show allocations from both threads
    const stats = thread_safe.getStats();
    try testing.expect(stats.num_allocations >= 20);
}
