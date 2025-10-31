// Home Programming Language - Atomic Intrinsics
// Lock-free atomic operations

const std = @import("std");

pub const AtomicOrdering = enum {
    unordered,
    monotonic,
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn toStdOrdering(self: AtomicOrdering) std.builtin.AtomicOrder {
        return switch (self) {
            .unordered => .unordered,
            .monotonic => .monotonic,
            .acquire => .acquire,
            .release => .release,
            .acq_rel => .acq_rel,
            .seq_cst => .seq_cst,
        };
    }
};

pub fn AtomicValue(comptime T: type) type {
    return struct {
        value: std.atomic.Value(T),

        const Self = @This();

        pub fn init(initial: T) Self {
            return .{ .value = std.atomic.Value(T).init(initial) };
        }

        pub fn load(self: *const Self, comptime ordering: AtomicOrdering) T {
            return self.value.load(ordering.toStdOrdering());
        }

        pub fn store(self: *Self, val: T, comptime ordering: AtomicOrdering) void {
            self.value.store(val, ordering.toStdOrdering());
        }

        pub fn swap(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.swap(val, ordering.toStdOrdering());
        }

        pub fn compareAndSwap(
            self: *Self,
            expected: T,
            desired: T,
            comptime success: AtomicOrdering,
            comptime failure: AtomicOrdering,
        ) ?T {
            return self.value.cmpxchgWeak(
                expected,
                desired,
                success.toStdOrdering(),
                failure.toStdOrdering(),
            );
        }

        pub fn compareAndSwapStrong(
            self: *Self,
            expected: T,
            desired: T,
            comptime success: AtomicOrdering,
            comptime failure: AtomicOrdering,
        ) ?T {
            return self.value.cmpxchgStrong(
                expected,
                desired,
                success.toStdOrdering(),
                failure.toStdOrdering(),
            );
        }

        pub fn fetchAdd(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchAdd(val, ordering.toStdOrdering());
        }

        pub fn fetchSub(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchSub(val, ordering.toStdOrdering());
        }

        pub fn fetchAnd(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchAnd(val, ordering.toStdOrdering());
        }

        pub fn fetchOr(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchOr(val, ordering.toStdOrdering());
        }

        pub fn fetchXor(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchXor(val, ordering.toStdOrdering());
        }

        pub fn fetchNand(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchNand(val, ordering.toStdOrdering());
        }

        pub fn fetchMin(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchMin(val, ordering.toStdOrdering());
        }

        pub fn fetchMax(self: *Self, val: T, comptime ordering: AtomicOrdering) T {
            return self.value.fetchMax(val, ordering.toStdOrdering());
        }
    };
}

// Atomic fence operations
pub fn fence(comptime ordering: AtomicOrdering) void {
    _ = ordering;
    asm volatile ("" ::: .{ .memory = true });
}

pub fn compilerFence(comptime ordering: AtomicOrdering) void {
    asm volatile ("" ::: .{ .memory = true });
    _ = ordering;
}

// Spin loop hint for busy-waiting
pub fn spinLoopHint() void {
    std.atomic.spinLoopHint();
}

test "atomic value operations" {
    const testing = std.testing;

    var atomic = AtomicValue(u32).init(0);

    atomic.store(42, .seq_cst);
    try testing.expectEqual(@as(u32, 42), atomic.load(.seq_cst));

    const old = atomic.swap(100, .seq_cst);
    try testing.expectEqual(@as(u32, 42), old);
    try testing.expectEqual(@as(u32, 100), atomic.load(.seq_cst));
}

test "atomic fetch operations" {
    const testing = std.testing;

    var atomic = AtomicValue(u32).init(10);

    const old_add = atomic.fetchAdd(5, .seq_cst);
    try testing.expectEqual(@as(u32, 10), old_add);
    try testing.expectEqual(@as(u32, 15), atomic.load(.seq_cst));

    const old_sub = atomic.fetchSub(3, .seq_cst);
    try testing.expectEqual(@as(u32, 15), old_sub);
    try testing.expectEqual(@as(u32, 12), atomic.load(.seq_cst));
}

test "atomic compare and swap" {
    const testing = std.testing;

    var atomic = AtomicValue(u32).init(42);

    const result1 = atomic.compareAndSwapStrong(42, 100, .seq_cst, .seq_cst);
    try testing.expectEqual(@as(?u32, null), result1);
    try testing.expectEqual(@as(u32, 100), atomic.load(.seq_cst));

    const result2 = atomic.compareAndSwapStrong(42, 200, .seq_cst, .seq_cst);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(u32, 100), atomic.load(.seq_cst));
}
