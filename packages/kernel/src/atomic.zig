// Home Programming Language - Kernel Atomic Operations
// Type-safe atomic operations and memory ordering for OS development

const std = @import("std");

// ============================================================================
// Memory Ordering
// ============================================================================

pub const MemoryOrder = enum {
    Relaxed,
    Acquire,
    Release,
    AcqRel,
    SeqCst,

    /// Convert to Zig's atomic ordering
    pub fn toZigOrder(self: MemoryOrder) std.builtin.AtomicOrder {
        return switch (self) {
            .Relaxed => .monotonic,
            .Acquire => .acquire,
            .Release => .release,
            .AcqRel => .acq_rel,
            .SeqCst => .seq_cst,
        };
    }
};

// ============================================================================
// Memory Barriers
// ============================================================================

pub const Barrier = struct {
    /// Full memory barrier (mfence)
    pub inline fn full() void {
        asm volatile ("mfence" ::: "memory");
    }

    /// Load barrier (lfence)
    pub inline fn load() void {
        asm volatile ("lfence" ::: "memory");
    }

    /// Store barrier (sfence)
    pub inline fn store() void {
        asm volatile ("sfence" ::: "memory");
    }

    /// Compiler barrier only
    pub inline fn compiler() void {
        asm volatile ("" ::: "memory");
    }

    /// Acquire barrier (load + compiler)
    pub inline fn acquire() void {
        asm volatile ("lfence" ::: "memory");
    }

    /// Release barrier (compiler + store)
    pub inline fn release() void {
        asm volatile ("sfence" ::: "memory");
    }
};

// ============================================================================
// Atomic Type
// ============================================================================

pub fn Atomic(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,

        comptime {
            const size = @sizeOf(T);
            if (size != 1 and size != 2 and size != 4 and size != 8) {
                @compileError("Atomic type must be 1, 2, 4, or 8 bytes");
            }
        }

        pub fn init(initial: T) Self {
            return .{ .value = initial };
        }

        /// Load with specified memory order
        pub fn load(self: *const Self, comptime order: MemoryOrder) T {
            return switch (order) {
                .Relaxed => @atomicLoad(T, &self.value, .monotonic),
                .Acquire => @atomicLoad(T, &self.value, .acquire),
                .SeqCst => @atomicLoad(T, &self.value, .seq_cst),
                else => @compileError("Invalid load ordering"),
            };
        }

        /// Store with specified memory order
        pub fn store(self: *Self, val: T, comptime order: MemoryOrder) void {
            switch (order) {
                .Relaxed => @atomicStore(T, &self.value, val, .monotonic),
                .Release => @atomicStore(T, &self.value, val, .release),
                .SeqCst => @atomicStore(T, &self.value, val, .seq_cst),
                else => @compileError("Invalid store ordering"),
            }
        }

        /// Exchange (swap) with specified memory order
        pub fn swap(self: *Self, val: T, comptime order: MemoryOrder) T {
            return @atomicRmw(T, &self.value, .Xchg, val, comptime order.toZigOrder());
        }

        /// Compare and exchange (strong)
        pub fn compareExchange(
            self: *Self,
            expected: T,
            desired: T,
            comptime success_order: MemoryOrder,
            comptime failure_order: MemoryOrder,
        ) ?T {
            return @cmpxchgStrong(T, &self.value, expected, desired, comptime success_order.toZigOrder(), comptime failure_order.toZigOrder());
        }

        /// Compare and exchange (weak) - may spuriously fail
        pub fn compareExchangeWeak(
            self: *Self,
            expected: T,
            desired: T,
            comptime success_order: MemoryOrder,
            comptime failure_order: MemoryOrder,
        ) ?T {
            return @cmpxchgWeak(T, &self.value, expected, desired, comptime success_order.toZigOrder(), comptime failure_order.toZigOrder());
        }

        /// Fetch and add
        pub fn fetchAdd(self: *Self, val: T, comptime order: MemoryOrder) T {
            return @atomicRmw(T, &self.value, .Add, val, comptime order.toZigOrder());
        }

        /// Fetch and subtract
        pub fn fetchSub(self: *Self, val: T, comptime order: MemoryOrder) T {
            return @atomicRmw(T, &self.value, .Sub, val, comptime order.toZigOrder());
        }

        /// Fetch and bitwise AND
        pub fn fetchAnd(self: *Self, val: T, comptime order: MemoryOrder) T {
            var current = self.load(.Relaxed);
            while (true) {
                const new_val = current & val;
                if (self.compareExchange(current, new_val, order, .Relaxed)) |actual| {
                    current = actual;
                } else {
                    return current;
                }
            }
        }

        /// Fetch and bitwise OR
        pub fn fetchOr(self: *Self, val: T, comptime order: MemoryOrder) T {
            var current = self.load(.Relaxed);
            while (true) {
                const new_val = current | val;
                if (self.compareExchange(current, new_val, order, .Relaxed)) |actual| {
                    current = actual;
                } else {
                    return current;
                }
            }
        }

        /// Fetch and bitwise XOR
        pub fn fetchXor(self: *Self, val: T, comptime order: MemoryOrder) T {
            var current = self.load(.Relaxed);
            while (true) {
                const new_val = current ^ val;
                if (self.compareExchange(current, new_val, order, .Relaxed)) |actual| {
                    current = actual;
                } else {
                    return current;
                }
            }
        }

        /// Increment by 1
        pub fn inc(self: *Self, comptime order: MemoryOrder) T {
            return self.fetchAdd(1, order);
        }

        /// Decrement by 1
        pub fn dec(self: *Self, comptime order: MemoryOrder) T {
            return self.fetchSub(1, order);
        }
    };
}

// ============================================================================
// Common Atomic Types
// ============================================================================

pub const AtomicBool = Atomic(bool);
pub const AtomicU8 = Atomic(u8);
pub const AtomicU16 = Atomic(u16);
pub const AtomicU32 = Atomic(u32);
pub const AtomicU64 = Atomic(u64);
pub const AtomicI8 = Atomic(i8);
pub const AtomicI16 = Atomic(i16);
pub const AtomicI32 = Atomic(i32);
pub const AtomicI64 = Atomic(i64);
pub const AtomicUsize = Atomic(usize);
pub const AtomicIsize = Atomic(isize);

// ============================================================================
// Atomic Pointer
// ============================================================================

pub fn AtomicPtr(comptime T: type) type {
    return struct {
        const Self = @This();
        const PtrInt = usize;

        value: *T,

        pub fn init(ptr: *T) Self {
            return .{ .value = ptr };
        }

        pub fn load(self: *const Self, comptime order: MemoryOrder) *T {
            const ptr_to_int: *const PtrInt = @ptrCast(&self.value);
            const int_val = @atomicLoad(PtrInt, ptr_to_int, comptime order.toZigOrder());
            return @ptrFromInt(int_val);
        }

        pub fn store(self: *Self, ptr: *T, comptime order: MemoryOrder) void {
            const int_val: PtrInt = @intFromPtr(ptr);
            const ptr_to_int: *PtrInt = @ptrCast(&self.value);
            @atomicStore(PtrInt, ptr_to_int, int_val, comptime order.toZigOrder());
        }

        pub fn swap(self: *Self, ptr: *T, comptime order: MemoryOrder) *T {
            const int_val: PtrInt = @intFromPtr(ptr);
            const ptr_to_int: *PtrInt = @ptrCast(&self.value);
            const old_int = @atomicRmw(PtrInt, ptr_to_int, .Xchg, int_val, comptime order.toZigOrder());
            return @ptrFromInt(old_int);
        }

        pub fn compareExchange(
            self: *Self,
            expected: *T,
            desired: *T,
            comptime success_order: MemoryOrder,
            comptime failure_order: MemoryOrder,
        ) ?*T {
            const expected_int: PtrInt = @intFromPtr(expected);
            const desired_int: PtrInt = @intFromPtr(desired);
            const ptr_to_int: *PtrInt = @ptrCast(&self.value);
            const result = @cmpxchgStrong(PtrInt, ptr_to_int, expected_int, desired_int, comptime success_order.toZigOrder(), comptime failure_order.toZigOrder());

            if (result) |actual| {
                return @ptrFromInt(actual);
            } else {
                return null;
            }
        }
    };
}

// ============================================================================
// Atomic Flag
// ============================================================================

pub const AtomicFlag = struct {
    value: AtomicBool,

    pub fn init(initial: bool) AtomicFlag {
        return .{ .value = AtomicBool.init(initial) };
    }

    /// Test and set (returns old value)
    pub fn testAndSet(self: *AtomicFlag, comptime order: MemoryOrder) bool {
        return self.value.swap(true, order);
    }

    /// Clear the flag
    pub fn clear(self: *AtomicFlag, comptime order: MemoryOrder) void {
        self.value.store(false, order);
    }

    /// Test the flag without modifying
    pub fn isSet(self: *const AtomicFlag, comptime order: MemoryOrder) bool {
        return self.value.load(order);
    }
};

// ============================================================================
// Reference Counter
// ============================================================================

pub const AtomicRefCount = struct {
    count: AtomicUsize,

    pub fn init(initial: usize) AtomicRefCount {
        return .{ .count = AtomicUsize.init(initial) };
    }

    /// Increment reference count
    pub fn inc(self: *AtomicRefCount) usize {
        return self.count.inc(.AcqRel) + 1;
    }

    /// Decrement reference count, returns true if count reached zero
    pub fn dec(self: *AtomicRefCount) bool {
        const old = self.count.dec(.AcqRel);
        return old == 1;
    }

    /// Get current count
    pub fn get(self: *const AtomicRefCount) usize {
        return self.count.load(.Acquire);
    }
};

// ============================================================================
// Lock-Free Stack
// ============================================================================

pub fn AtomicStack(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: ?*Node,
        };

        head: AtomicPtr(?Node),

        pub fn init() Self {
            return .{
                .head = AtomicPtr(?Node).init(@ptrCast(&@as(?*Node, null))),
            };
        }

        pub fn push(self: *Self, node: *Node) void {
            var current_head = self.head.load(.Acquire);
            while (true) {
                node.next = current_head;
                if (self.head.compareExchange(
                    current_head,
                    @ptrCast(node),
                    .Release,
                    .Acquire,
                )) |actual| {
                    current_head = actual;
                } else {
                    break;
                }
            }
        }

        pub fn pop(self: *Self) ?*Node {
            var current_head = self.head.load(.Acquire);
            while (current_head) |head| {
                const next = head.next;
                if (self.head.compareExchange(
                    current_head,
                    @ptrCast(next),
                    .Release,
                    .Acquire,
                )) |actual| {
                    current_head = actual;
                } else {
                    return head;
                }
            } else {
                return null;
            }
        }
    };
}

// ============================================================================
// Lock-Free Queue (MPSC - Multiple Producer Single Consumer)
// ============================================================================

pub fn AtomicQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            data: T,
            next: AtomicPtr(?Node),
        };

        head: AtomicPtr(?Node),
        tail: *Node,

        pub fn init(stub: *Node) Self {
            stub.next = AtomicPtr(?Node).init(@ptrCast(&@as(?*Node, null)));
            return .{
                .head = AtomicPtr(?Node).init(@ptrCast(stub)),
                .tail = stub,
            };
        }

        pub fn enqueue(self: *Self, node: *Node) void {
            node.next = AtomicPtr(?Node).init(@ptrCast(&@as(?*Node, null)));
            const prev = self.head.swap(@ptrCast(node), .AcqRel);
            prev.?.next.store(@ptrCast(node), .Release);
        }

        pub fn dequeue(self: *Self) ?*Node {
            var tail = self.tail;
            const next = tail.next.load(.Acquire);

            if (next) |next_node| {
                self.tail = next_node;
                return next_node;
            }

            return null;
        }
    };
}

// ============================================================================
// Atomic Bitset
// ============================================================================

pub fn AtomicBitset(comptime size: usize) type {
    return struct {
        const Self = @This();
        const WordType = u64;
        const WORD_BITS = @bitSizeOf(WordType);
        const NUM_WORDS = (size + WORD_BITS - 1) / WORD_BITS;

        words: [NUM_WORDS]Atomic(WordType),

        pub fn init() Self {
            return .{
                .words = [_]Atomic(WordType){Atomic(WordType).init(0)} ** NUM_WORDS,
            };
        }

        pub fn set(self: *Self, bit: usize, comptime order: MemoryOrder) void {
            if (bit >= size) return;
            const word_idx = bit / WORD_BITS;
            const bit_idx = bit % WORD_BITS;
            const mask: WordType = @as(WordType, 1) << @intCast(bit_idx);
            _ = self.words[word_idx].fetchOr(mask, order);
        }

        pub fn clear(self: *Self, bit: usize, comptime order: MemoryOrder) void {
            if (bit >= size) return;
            const word_idx = bit / WORD_BITS;
            const bit_idx = bit % WORD_BITS;
            const mask: WordType = ~(@as(WordType, 1) << @intCast(bit_idx));
            _ = self.words[word_idx].fetchAnd(mask, order);
        }

        pub fn isSet(self: *const Self, bit: usize, comptime order: MemoryOrder) bool {
            if (bit >= size) return false;
            const word_idx = bit / WORD_BITS;
            const bit_idx = bit % WORD_BITS;
            const word = self.words[word_idx].load(order);
            return (word & (@as(WordType, 1) << @intCast(bit_idx))) != 0;
        }

        pub fn testAndSet(self: *Self, bit: usize, comptime order: MemoryOrder) bool {
            if (bit >= size) return false;
            const word_idx = bit / WORD_BITS;
            const bit_idx = bit % WORD_BITS;
            const mask: WordType = @as(WordType, 1) << @intCast(bit_idx);
            const old = self.words[word_idx].fetchOr(mask, order);
            return (old & mask) != 0;
        }
    };
}

// ============================================================================
// Sequence Lock
// ============================================================================

pub const SeqLock = struct {
    sequence: AtomicUsize,

    pub fn init() SeqLock {
        return .{ .sequence = AtomicUsize.init(0) };
    }

    pub fn beginWrite(self: *SeqLock) usize {
        const seq = self.sequence.fetchAdd(1, .Acquire);
        Barrier.full();
        return seq;
    }

    pub fn endWrite(self: *SeqLock) void {
        Barrier.full();
        _ = self.sequence.fetchAdd(1, .Release);
    }

    pub fn beginRead(self: *const SeqLock) usize {
        while (true) {
            const seq = self.sequence.load(.Acquire);
            if (seq & 1 == 0) {
                return seq;
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn retryRead(self: *const SeqLock, seq: usize) bool {
        Barrier.full();
        return self.sequence.load(.Acquire) != seq;
    }
};

// Tests
test "atomic load/store" {
    var atomic = AtomicU64.init(42);
    try std.testing.expectEqual(@as(u64, 42), atomic.load(.SeqCst));

    atomic.store(100, .SeqCst);
    try std.testing.expectEqual(@as(u64, 100), atomic.load(.SeqCst));
}

test "atomic swap" {
    var atomic = AtomicU32.init(10);
    const old = atomic.swap(20, .SeqCst);
    try std.testing.expectEqual(@as(u32, 10), old);
    try std.testing.expectEqual(@as(u32, 20), atomic.load(.SeqCst));
}

test "atomic compare exchange" {
    var atomic = AtomicU64.init(42);

    // Successful exchange
    const result1 = atomic.compareExchange(42, 100, .SeqCst, .SeqCst);
    try std.testing.expectEqual(@as(?u64, null), result1);
    try std.testing.expectEqual(@as(u64, 100), atomic.load(.SeqCst));

    // Failed exchange
    const result2 = atomic.compareExchange(42, 200, .SeqCst, .SeqCst);
    try std.testing.expectEqual(@as(u64, 100), result2.?);
    try std.testing.expectEqual(@as(u64, 100), atomic.load(.SeqCst));
}

test "atomic inc/dec" {
    var atomic = AtomicU32.init(10);

    const old1 = atomic.inc(.SeqCst);
    try std.testing.expectEqual(@as(u32, 10), old1);
    try std.testing.expectEqual(@as(u32, 11), atomic.load(.SeqCst));

    const old2 = atomic.dec(.SeqCst);
    try std.testing.expectEqual(@as(u32, 11), old2);
    try std.testing.expectEqual(@as(u32, 10), atomic.load(.SeqCst));
}

test "atomic flag" {
    var flag = AtomicFlag.init(false);
    try std.testing.expect(!flag.isSet(.SeqCst));

    const was_set = flag.testAndSet(.SeqCst);
    try std.testing.expect(!was_set);
    try std.testing.expect(flag.isSet(.SeqCst));

    flag.clear(.SeqCst);
    try std.testing.expect(!flag.isSet(.SeqCst));
}

test "atomic ref count" {
    var refcount = AtomicRefCount.init(1);
    try std.testing.expectEqual(@as(usize, 1), refcount.get());

    _ = refcount.inc();
    try std.testing.expectEqual(@as(usize, 2), refcount.get());

    try std.testing.expect(!refcount.dec());
    try std.testing.expect(refcount.dec());
}

test "atomic bitset" {
    var bitset = AtomicBitset(128).init();

    try std.testing.expect(!bitset.isSet(5, .SeqCst));
    bitset.set(5, .SeqCst);
    try std.testing.expect(bitset.isSet(5, .SeqCst));

    const was_set = bitset.testAndSet(10, .SeqCst);
    try std.testing.expect(!was_set);
    try std.testing.expect(bitset.isSet(10, .SeqCst));

    bitset.clear(5, .SeqCst);
    try std.testing.expect(!bitset.isSet(5, .SeqCst));
}
