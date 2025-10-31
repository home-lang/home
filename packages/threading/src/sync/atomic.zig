// Home Programming Language - Atomic Operations
// Lock-free programming primitives

const std = @import("std");

/// Atomic counter with common operations
pub fn AtomicCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        value: std.atomic.Value(T),

        pub fn init(initial: T) Self {
            return .{ .value = std.atomic.Value(T).init(initial) };
        }

        pub fn load(self: *const Self) T {
            return self.value.load(.monotonic);
        }

        pub fn store(self: *Self, val: T) void {
            self.value.store(val, .monotonic);
        }

        pub fn increment(self: *Self) T {
            return self.value.fetchAdd(1, .monotonic);
        }

        pub fn decrement(self: *Self) T {
            return self.value.fetchSub(1, .monotonic);
        }

        pub fn add(self: *Self, delta: T) T {
            return self.value.fetchAdd(delta, .monotonic);
        }

        pub fn sub(self: *Self, delta: T) T {
            return self.value.fetchSub(delta, .monotonic);
        }

        pub fn compareAndSwap(self: *Self, expected: T, desired: T) ?T {
            return self.value.cmpxchgStrong(expected, desired, .monotonic, .monotonic);
        }
    };
}

/// Atomic flag for simple boolean synchronization
pub const AtomicFlag = struct {
    value: std.atomic.Value(bool),

    pub fn init() AtomicFlag {
        return .{ .value = std.atomic.Value(bool).init(false) };
    }

    pub fn testAndSet(self: *AtomicFlag) bool {
        return self.value.swap(true, .acquire);
    }

    pub fn clear(self: *AtomicFlag) void {
        self.value.store(false, .release);
    }

    pub fn isSet(self: *const AtomicFlag) bool {
        return self.value.load(.acquire);
    }
};

/// Atomic pointer with ABA protection (tagged pointer)
pub fn AtomicTaggedPtr(comptime T: type) type {
    return struct {
        const Self = @This();
        const TaggedValue = packed struct {
            ptr: usize,
            tag: u16,
        };

        value: std.atomic.Value(u64),

        pub fn init(ptr: ?*T) Self {
            const addr = if (ptr) |p| @intFromPtr(p) else 0;
            const tagged = (@as(u64, 0) << 48) | addr;
            return .{ .value = std.atomic.Value(u64).init(tagged) };
        }

        pub fn load(self: *const Self) ?*T {
            const val = self.value.load(.acquire);
            const addr = val & 0xFFFF_FFFF_FFFF;
            if (addr == 0) return null;
            return @ptrFromInt(addr);
        }

        pub fn store(self: *Self, ptr: ?*T) void {
            const old = self.value.load(.monotonic);
            const old_tag = (old >> 48) & 0xFFFF;
            const new_tag = old_tag +% 1;

            const addr = if (ptr) |p| @intFromPtr(p) else 0;
            const tagged = (@as(u64, new_tag) << 48) | addr;
            self.value.store(tagged, .release);
        }

        pub fn compareAndSwap(self: *Self, expected: ?*T, desired: ?*T) bool {
            const exp_addr = if (expected) |p| @intFromPtr(p) else 0;
            const des_addr = if (desired) |p| @intFromPtr(p) else 0;

            const old = self.value.load(.monotonic);
            const old_addr = old & 0xFFFF_FFFF_FFFF;

            if (old_addr != exp_addr) return false;

            const old_tag = (old >> 48) & 0xFFFF;
            const new_tag = old_tag +% 1;
            const new_val = (@as(u64, new_tag) << 48) | des_addr;

            return self.value.cmpxchgStrong(old, new_val, .acq_rel, .acquire) == null;
        }
    };
}

test "atomic counter" {
    const testing = std.testing;

    var counter = AtomicCounter(u32).init(0);

    _ = counter.increment();
    _ = counter.increment();
    try testing.expectEqual(@as(u32, 2), counter.load());

    _ = counter.decrement();
    try testing.expectEqual(@as(u32, 1), counter.load());
}

test "atomic flag" {
    const testing = std.testing;

    var flag = AtomicFlag.init();

    try testing.expect(!flag.isSet());

    const was_set = flag.testAndSet();
    try testing.expect(!was_set);
    try testing.expect(flag.isSet());

    flag.clear();
    try testing.expect(!flag.isSet());
}

test "atomic tagged pointer" {
    const testing = std.testing;

    var value: u32 = 42;
    var ptr = AtomicTaggedPtr(u32).init(&value);

    const loaded = ptr.load();
    try testing.expect(loaded != null);
    try testing.expectEqual(@as(u32, 42), loaded.?.*);

    var new_value: u32 = 100;
    const swapped = ptr.compareAndSwap(&value, &new_value);
    try testing.expect(swapped);

    const loaded2 = ptr.load();
    try testing.expectEqual(@as(u32, 100), loaded2.?.*);
}
