// Home Programming Language - Atomic Operations
// Basic atomic operations for driver synchronization

const std = @import("std");

/// Atomic counter type
pub const AtomicCounter = struct {
    value: std.atomic.Value(u64),

    pub fn init(initial: u64) AtomicCounter {
        return .{
            .value = std.atomic.Value(u64).init(initial),
        };
    }

    pub fn load(self: *const AtomicCounter, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.load(ordering);
    }

    pub fn store(self: *AtomicCounter, val: u64, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }

    pub fn fetchAdd(self: *AtomicCounter, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.fetchAdd(val, ordering);
    }

    pub fn fetchSub(self: *AtomicCounter, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.fetchSub(val, ordering);
    }

    /// Increment counter and return the old value (before increment)
    pub fn increment(self: *AtomicCounter) u64 {
        return self.fetchAdd(1, .seq_cst);
    }

    /// Decrement counter and return the old value (before decrement)
    pub fn decrement(self: *AtomicCounter) u64 {
        return self.fetchSub(1, .seq_cst);
    }
};

/// Atomic U32 type
pub const AtomicU32 = struct {
    value: std.atomic.Value(u32),

    pub fn init(initial: u32) AtomicU32 {
        return .{
            .value = std.atomic.Value(u32).init(initial),
        };
    }

    pub fn load(self: *const AtomicU32, comptime ordering: std.builtin.AtomicOrder) u32 {
        return self.value.load(ordering);
    }

    pub fn store(self: *AtomicU32, val: u32, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }

    pub fn fetchAdd(self: *AtomicU32, val: u32, comptime ordering: std.builtin.AtomicOrder) u32 {
        return self.value.fetchAdd(val, ordering);
    }

    pub fn fetchSub(self: *AtomicU32, val: u32, comptime ordering: std.builtin.AtomicOrder) u32 {
        return self.value.fetchSub(val, ordering);
    }
};

/// Atomic U64 type
pub const AtomicU64 = struct {
    value: std.atomic.Value(u64),

    pub fn init(initial: u64) AtomicU64 {
        return .{
            .value = std.atomic.Value(u64).init(initial),
        };
    }

    pub fn load(self: *const AtomicU64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.load(ordering);
    }

    pub fn store(self: *AtomicU64, val: u64, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }

    pub fn fetchAdd(self: *AtomicU64, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.fetchAdd(val, ordering);
    }

    pub fn fetchSub(self: *AtomicU64, val: u64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.fetchSub(val, ordering);
    }
};

/// Atomic Usize type
pub const AtomicUsize = struct {
    value: std.atomic.Value(usize),

    pub fn init(initial: usize) AtomicUsize {
        return .{
            .value = std.atomic.Value(usize).init(initial),
        };
    }

    pub fn load(self: *const AtomicUsize, comptime ordering: std.builtin.AtomicOrder) usize {
        return self.value.load(ordering);
    }

    pub fn store(self: *AtomicUsize, val: usize, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }

    pub fn fetchAdd(self: *AtomicUsize, val: usize, comptime ordering: std.builtin.AtomicOrder) usize {
        return self.value.fetchAdd(val, ordering);
    }

    pub fn fetchSub(self: *AtomicUsize, val: usize, comptime ordering: std.builtin.AtomicOrder) usize {
        return self.value.fetchSub(val, ordering);
    }
};

/// Atomic flag for simple boolean state
pub const AtomicFlag = struct {
    value: std.atomic.Value(bool),

    pub fn init(initial: bool) AtomicFlag {
        return .{
            .value = std.atomic.Value(bool).init(initial),
        };
    }

    pub fn load(self: *const AtomicFlag, comptime ordering: std.builtin.AtomicOrder) bool {
        return self.value.load(ordering);
    }

    pub fn store(self: *AtomicFlag, val: bool, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }

    pub fn testAndSet(self: *AtomicFlag, comptime ordering: std.builtin.AtomicOrder) bool {
        return self.value.swap(true, ordering);
    }

    pub fn clear(self: *AtomicFlag, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(false, ordering);
    }
};

/// Atomic pointer wrapper
pub fn AtomicPtr(comptime T: type) type {
    return struct {
        value: std.atomic.Value(?*T),

        const Self = @This();

        pub fn init(initial: ?*T) Self {
            return .{
                .value = std.atomic.Value(?*T).init(initial),
            };
        }

        pub fn load(self: *const Self, comptime ordering: std.builtin.AtomicOrder) ?*T {
            return self.value.load(ordering);
        }

        pub fn store(self: *Self, ptr: ?*T, comptime ordering: std.builtin.AtomicOrder) void {
            self.value.store(ptr, ordering);
        }

        pub fn swap(self: *Self, ptr: ?*T, comptime ordering: std.builtin.AtomicOrder) ?*T {
            return self.value.swap(ptr, ordering);
        }

        pub fn compareAndSwap(
            self: *Self,
            expected: ?*T,
            new: ?*T,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) ?*T {
            return self.value.cmpxchgStrong(expected, new, success_order, failure_order);
        }
    };
}

test "atomic counter operations" {
    var counter = AtomicCounter.init(0);

    // increment() returns the old value before incrementing
    try std.testing.expectEqual(@as(u64, 0), counter.increment()); // 0 -> 1, returns 0
    try std.testing.expectEqual(@as(u64, 1), counter.increment()); // 1 -> 2, returns 1
    try std.testing.expectEqual(@as(u64, 2), counter.load(.seq_cst)); // now at 2

    // decrement() returns the old value before decrementing
    try std.testing.expectEqual(@as(u64, 2), counter.decrement()); // 2 -> 1, returns 2
    try std.testing.expectEqual(@as(u64, 1), counter.load(.seq_cst)); // now at 1
}

test "atomic flag operations" {
    var flag = AtomicFlag.init(false);

    try std.testing.expectEqual(false, flag.load(.seq_cst));
    try std.testing.expectEqual(false, flag.testAndSet(.seq_cst));
    try std.testing.expectEqual(true, flag.load(.seq_cst));

    flag.clear(.seq_cst);
    try std.testing.expectEqual(false, flag.load(.seq_cst));
}
