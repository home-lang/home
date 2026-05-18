// Copied from bun/src/collections/hive_array.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").
// Rewrites:
//   * `bun.bit_set.IntegerBitSet` → `std.bit_set.IntegerBitSet`
//     (bit_set is not ported yet; std's IntegerBitSet has the same API
//      for the methods this file uses, with the exception that
//      `findFirstUnset` does not exist upstream — we recover the
//      semantic via `complement().findFirstSet()`).
//   * `bun.asan.*` calls (unpoison / assertUnpoisoned / poison) are
//     dropped to inline no-ops. asan tooling is not wired into Home yet;
//     when it lands these can be re-introduced via a thin shim.

/// An array that efficiently tracks which elements are in use.
/// The pointers are intended to be stable
/// Sorta related to https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2021/p0447r15.html
pub fn HiveArray(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T,
        used: std.bit_set.IntegerBitSet(capacity),

        pub const size = capacity;

        /// This is deliberately a `var` instead of a `const`.
        ///
        /// https://github.com/ziglang/zig/issues/22462
        /// https://github.com/ziglang/zig/issues/21988
        pub var empty: Self = .{
            .buffer = undefined,
            .used = .initEmpty(),
        };

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .used = .initEmpty(),
            };
        }

        pub fn get(self: *Self) ?*T {
            // `bun.bit_set.IntegerBitSet` had `findFirstUnset`; std doesn't.
            // Use the complement (set ↔ unset) and look for the first set bit.
            const index = self.used.complement().findFirstSet() orelse return null;
            self.used.set(index);
            const ret = &self.buffer[index];
            return ret;
        }

        pub fn at(self: *Self, index: u16) *T {
            assert(index < capacity);
            const ret = &self.buffer[index];
            return ret;
        }

        pub fn indexOf(self: *const Self, value: *const T) ?u32 {
            const start = &self.buffer;
            const end = @as([*]const T, @ptrCast(start)) + capacity;
            if (!(@intFromPtr(value) >= @intFromPtr(start) and @intFromPtr(value) < @intFromPtr(end)))
                return null;

            // aligned to the size of T
            const index = (@intFromPtr(value) - @intFromPtr(start)) / @sizeOf(T);
            assert(index < capacity);
            assert(&self.buffer[index] == value);
            return @as(u32, @intCast(index));
        }

        pub fn in(self: *const Self, value: *const T) bool {
            const start = &self.buffer;
            const end = @as([*]const T, @ptrCast(start)) + capacity;
            return (@intFromPtr(value) >= @intFromPtr(start) and @intFromPtr(value) < @intFromPtr(end));
        }

        pub fn put(self: *Self, value: *T) bool {
            const index = self.indexOf(value) orelse return false;

            assert(self.used.isSet(index));
            assert(&self.buffer[index] == value);

            value.* = undefined;

            self.used.unset(index);
            return true;
        }

        pub const Fallback = struct {
            hive: if (capacity > 0) Self else void,
            allocator: std.mem.Allocator,

            pub const This = @This();

            pub fn init(allocator: std.mem.Allocator) This {
                return .{
                    .allocator = allocator,
                    .hive = if (comptime capacity > 0) Self.empty,
                };
            }

            pub fn get(self: *This) *T {
                const value = getImpl(self);
                return value;
            }

            fn getImpl(self: *This) *T {
                if (comptime capacity > 0) {
                    if (self.hive.get()) |value| {
                        return value;
                    }
                }

                return home_rt.handleOom(self.allocator.create(T));
            }

            pub fn getAndSeeIfNew(self: *This, new: *bool) *T {
                if (comptime capacity > 0) {
                    if (self.hive.get()) |value| {
                        new.* = false;
                        return value;
                    }
                }

                return home_rt.handleOom(self.allocator.create(T));
            }

            pub fn tryGet(self: *This) OOM!*T {
                if (comptime capacity > 0) {
                    if (self.hive.get()) |value| {
                        return value;
                    }
                }

                return try self.allocator.create(T);
            }

            pub fn in(self: *const This, value: *const T) bool {
                if (comptime capacity > 0) {
                    if (self.hive.in(value)) return true;
                }

                return false;
            }

            pub fn put(self: *This, value: *T) void {
                if (comptime capacity > 0) {
                    if (self.hive.put(value)) return;
                }

                self.allocator.destroy(value);
            }
        };
    };
}

test "HiveArray" {
    const size = 64;

    // Choose an integer with a weird alignment
    const Int = u127;

    var a = HiveArray(Int, size).init();

    {
        const b = a.get().?;
        try testing.expect(a.get().? != b);
        try testing.expectEqual(@as(?u32, 0), a.indexOf(b));
        try testing.expect(a.put(b));
        try testing.expect(a.get().? == b);
        const c = a.get().?;
        c.* = 123;
        var d: Int = 12345;
        try testing.expect(a.put(&d) == false);
        try testing.expect(a.in(&d) == false);
    }

    a.used = @TypeOf(a.used).initEmpty();
    {
        for (0..size) |i| {
            const b = a.get().?;
            try testing.expectEqual(@as(?u32, @intCast(i)), a.indexOf(b));
            try testing.expect(a.put(b));
            try testing.expect(a.get().? == b);
        }
        for (0..size) |_| {
            try testing.expect(a.get() == null);
        }
    }
}

test "HiveArray.Fallback overflows into its allocator" {
    var fb = HiveArray(u64, 2).Fallback.init(std.testing.allocator);
    const a = fb.get();
    a.* = 1;
    const b = fb.get();
    b.* = 2;
    // Hive is now full (capacity = 2); next get() should allocate.
    const c = fb.get();
    c.* = 3;
    try testing.expect(fb.in(a));
    try testing.expect(fb.in(b));
    try testing.expect(!fb.in(c));
    fb.put(a);
    fb.put(b);
    fb.put(c);
}

const home_rt = @import("home_rt");
const OOM = home_rt.OOM;
const assert = home_rt.assert;

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
