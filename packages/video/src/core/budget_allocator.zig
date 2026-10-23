//! Allocation-free live-byte ceiling over an existing allocator. One serialized
//! owner; keep this object at a stable address until all its allocations retire.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
pub const Budget = struct {
    parent: Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: usize = 0,
    pub fn init(parent: Allocator, limit: usize) Budget {
        return .{ .parent = parent, .limit = limit };
    }
    pub fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn room(self: *Budget, old: usize, new: usize) bool {
        std.debug.assert(old <= self.live and self.live <= self.limit);
        if (new <= old or new - old <= self.limit - self.live) return true;
        self.denied +|= 1;
        return false;
    }
    fn account(self: *Budget, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    /// Transfer an allocation to an owner that frees through the SAME underlying
    /// allocator. Does not free, resize, copy or inspect memory. The caller must
    /// retire every alias/use of this wrapper for that exact allocation first.
    pub fn disown(self: *Budget, memory: []u8) void {
        std.debug.assert(memory.len <= self.live);
        self.account(memory.len, 0);
    }
    fn owner(ctx: *anyopaque) *Budget {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self = owner(ctx);
        if (!self.room(0, len)) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.account(0, len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self = owner(ctx);
        if (!self.room(memory.len, len) or !self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.account(memory.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self = owner(ctx);
        if (!self.room(memory.len, len)) return null;
        const result = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.account(memory.len, len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self = owner(ctx);
        self.parent.rawFree(memory, alignment, ra);
        self.account(memory.len, 0);
    }
};
test "budget denies before parent allocation and failed parent calls leave accounting unchanged" {
    const t = std.testing;
    var failed = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var budget = Budget.init(failed.allocator(), 8);
    const a = budget.allocator();
    try t.expectError(error.OutOfMemory, a.alloc(u8, 9));
    try t.expect(!failed.has_induced_failure);
    try t.expectEqual(@as(usize, 1), budget.denied);
    try t.expectError(error.OutOfMemory, a.alloc(u8, 8));
    try t.expect(failed.has_induced_failure);
    try t.expectEqual(@as(usize, 0), budget.live);
    try t.expectEqual(@as(usize, 0), budget.peak);
}
test "live allocations saturate exact budget, preserve old data on realloc failure and permit reuse" {
    const t = std.testing;
    var budget = Budget.init(t.allocator, 16);
    const a = budget.allocator();
    const first = try a.alloc(u8, 12);
    @memset(first, 73);
    const second = try a.alloc(u8, 4);
    try t.expectError(error.OutOfMemory, a.realloc(first, 13));
    try t.expect(std.mem.allEqual(u8, first, 73));
    try t.expectEqual(@as(usize, 16), budget.live);
    a.free(second);
    a.free(first);
    try t.expectEqual(@as(usize, 0), budget.live);
    const full = try a.alloc(u8, 16);
    a.free(full);
    try t.expectEqual(@as(usize, 16), budget.peak);
}
test "resize and remap account shrink growth and rejection atomically including maximum-size requests" {
    const t = std.testing;
    var memory: [64]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&memory);
    var budget = Budget.init(arena.allocator(), 16);
    const a = budget.allocator();
    const first = try a.alloc(u8, 8);
    try t.expect(!a.rawResize(first, .@"1", 17, @returnAddress()));
    try t.expectEqual(@as(usize, 8), budget.live);
    try t.expect(a.rawResize(first, .@"1", 4, @returnAddress()));
    try t.expectEqual(@as(usize, 4), budget.live);
    const grown = a.rawRemap(first[0..4], .@"1", 16, @returnAddress()).?;
    try t.expectEqual(@as(usize, 16), budget.live);
    try t.expect(a.rawRemap(grown[0..16], .@"1", std.math.maxInt(usize), @returnAddress()) == null);
    a.free(grown[0..16]);
    try t.expectEqual(@as(usize, 0), budget.live);
}
test "parent resize failure and zero-limit allocation do not consume budget" {
    const t = std.testing;
    var failed = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    var budget = Budget.init(failed.allocator(), 64);
    const a = budget.allocator();
    const bytes = try a.alloc(u8, 8);
    try t.expect(!a.rawResize(bytes, .@"1", 16, @returnAddress()));
    try t.expect(a.rawRemap(bytes, .@"1", 16, @returnAddress()) == null);
    try t.expectEqual(@as(usize, 8), budget.live);
    a.free(bytes);
    var zero = Budget.init(t.allocator, 0);
    try t.expectError(error.OutOfMemory, zero.allocator().alloc(u8, 1));
    try t.expectEqual(@as(usize, 0), zero.live);
}
test "disown transfers exact base allocation ownership while retaining peak and allowing wrapper destruction" {
    const t = std.testing;
    var budget = Budget.init(t.allocator, 16);
    const bytes = try budget.allocator().alloc(u8, 16);
    @memset(bytes, 42);
    budget.disown(bytes);
    try t.expectEqual(@as(usize, 0), budget.live);
    try t.expectEqual(@as(usize, 16), budget.peak);
    try t.expect(std.mem.allEqual(u8, bytes, 42));
    t.allocator.free(bytes);
}
