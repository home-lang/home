// Forward-port shim: Home's pinned Zig (0.17-dev.263 Bun fork) removed the
// *managed* array hash maps from `std` — only the unmanaged `Auto`/`Custom`
// variants survive (their methods take an explicit `gpa: Allocator`). Bun's
// pinned source still uses `std.AutoArrayHashMap` / `std.ArrayHashMap` (managed,
// `.init(alloc)` then allocator-free `.put`/`.get`/...), so this file restores
// that managed API by wrapping the unmanaged map + an `allocator` field — the
// exact shape the old `std.array_hash_map.ArrayHashMapWithAllocator` had. This
// lets the copied Bun maps compile unchanged against Home's Zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Managed `AutoArrayHashMap(K, V)` — see file banner.
pub fn AutoArrayHashMap(comptime K: type, comptime V: type) type {
    return ArrayHashMap(K, V, std.array_hash_map.AutoContext(K), !std.array_hash_map.autoEqlIsCheap(K));
}

/// Managed `ArrayHashMap(K, V, Context, store_hash)` — see file banner.
pub fn ArrayHashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime store_hash: bool,
) type {
    return struct {
        unmanaged: Unmanaged,
        allocator: Allocator,

        const Self = @This();
        pub const Unmanaged = std.ArrayHashMapUnmanaged(K, V, Context, store_hash);
        pub const Entry = Unmanaged.Entry;
        pub const KV = Unmanaged.KV;
        pub const Hash = Unmanaged.Hash;
        pub const GetOrPutResult = Unmanaged.GetOrPutResult;
        pub const Iterator = Unmanaged.Iterator;
        pub const KeyIterator = FieldIterator(K);
        pub const ValueIterator = FieldIterator(V);
        pub const Size = u32;
        pub const Data = Unmanaged.Data;

        fn FieldIterator(comptime T: type) type {
            return struct {
                items: []T,
                index: usize = 0,

                pub fn next(self: *@This()) ?*T {
                    if (self.index >= self.items.len) return null;
                    defer self.index += 1;
                    return &self.items[self.index];
                }
            };
        }

        pub fn init(allocator: Allocator) Self {
            return .{ .unmanaged = .empty, .allocator = allocator };
        }

        pub fn initContext(allocator: Allocator, ctx: Context) Self {
            _ = ctx;
            return init(allocator);
        }

        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.unmanaged.clearRetainingCapacity();
        }

        pub fn capacity(self: Self) usize {
            return self.unmanaged.capacity();
        }

        pub fn shrinkAndFree(self: *Self, new_len: usize) void {
            self.unmanaged.shrinkAndFree(self.allocator, new_len);
        }

        pub fn clearAndFree(self: *Self) void {
            self.unmanaged.clearAndFree(self.allocator);
        }

        pub fn count(self: Self) usize {
            return self.unmanaged.count();
        }

        pub fn keys(self: Self) []K {
            return self.unmanaged.keys();
        }

        pub fn values(self: Self) []V {
            return self.unmanaged.values();
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.unmanaged.iterator();
        }

        pub fn keyIterator(self: Self) KeyIterator {
            return .{ .items = self.unmanaged.keys() };
        }

        pub fn valueIterator(self: Self) ValueIterator {
            return .{ .items = self.unmanaged.values() };
        }

        pub fn getOrPut(self: *Self, key: K) Allocator.Error!GetOrPutResult {
            return self.unmanaged.getOrPut(self.allocator, key);
        }

        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            return self.unmanaged.getOrPutAssumeCapacity(key);
        }

        pub fn getOrPutAssumeCapacityContext(self: *Self, key: K, ctx: Context) GetOrPutResult {
            return self.unmanaged.getOrPutAssumeCapacityContext(key, ctx);
        }

        pub fn getOrPutAssumeCapacityAdapted(self: *Self, key: anytype, ctx: anytype) GetOrPutResult {
            return self.unmanaged.getOrPutAssumeCapacityAdapted(key, ctx);
        }

        pub fn getOrPutValue(self: *Self, key: K, value: V) Allocator.Error!GetOrPutResult {
            return self.unmanaged.getOrPutValue(self.allocator, key, value);
        }

        pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
            return self.unmanaged.put(self.allocator, key, value);
        }

        pub fn putNoClobber(self: *Self, key: K, value: V) Allocator.Error!void {
            return self.unmanaged.putNoClobber(self.allocator, key, value);
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            self.unmanaged.putAssumeCapacity(key, value);
        }

        pub fn putAssumeCapacityContext(self: *Self, key: K, value: V, ctx: Context) void {
            self.unmanaged.putAssumeCapacityContext(key, value, ctx);
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            self.unmanaged.putAssumeCapacityNoClobber(key, value);
        }

        pub fn putAssumeCapacityNoClobberContext(self: *Self, key: K, value: V, ctx: Context) void {
            self.unmanaged.putAssumeCapacityNoClobberContext(key, value, ctx);
        }

        pub fn fetchPut(self: *Self, key: K, value: V) Allocator.Error!?KV {
            return self.unmanaged.fetchPut(self.allocator, key, value);
        }

        pub fn get(self: Self, key: K) ?V {
            return self.unmanaged.get(key);
        }

        pub fn getPtr(self: Self, key: K) ?*V {
            return self.unmanaged.getPtr(key);
        }

        pub fn getEntry(self: Self, key: K) ?Entry {
            return self.unmanaged.getEntry(key);
        }

        pub fn getKey(self: Self, key: K) ?K {
            return self.unmanaged.getKey(key);
        }

        pub fn getIndex(self: Self, key: K) ?usize {
            return self.unmanaged.getIndex(key);
        }

        pub fn contains(self: Self, key: K) bool {
            return self.unmanaged.contains(key);
        }

        pub fn swapRemove(self: *Self, key: K) bool {
            return self.unmanaged.swapRemove(key);
        }

        pub fn swapRemoveAt(self: *Self, index: usize) void {
            self.unmanaged.swapRemoveAt(index);
        }

        pub fn fetchSwapRemove(self: *Self, key: K) ?KV {
            return self.unmanaged.fetchSwapRemove(key);
        }

        pub fn orderedRemove(self: *Self, key: K) bool {
            return self.unmanaged.orderedRemove(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            return self.orderedRemove(key);
        }

        pub fn fetchOrderedRemove(self: *Self, key: K) ?KV {
            return self.unmanaged.fetchOrderedRemove(key);
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) Allocator.Error!void {
            return self.unmanaged.ensureTotalCapacity(self.allocator, new_capacity);
        }

        pub fn ensureUnusedCapacity(self: *Self, additional_capacity: usize) Allocator.Error!void {
            return self.unmanaged.ensureUnusedCapacity(self.allocator, additional_capacity);
        }

        pub fn sort(self: *Self, sort_ctx: anytype) void {
            return self.unmanaged.sort(sort_ctx);
        }

        pub fn reIndex(self: *Self) Allocator.Error!void {
            return self.unmanaged.reIndex(self.allocator);
        }

        pub fn sortUnstable(self: *Self, sort_ctx: anytype) void {
            return self.unmanaged.sortUnstable(sort_ctx);
        }

        pub fn sortContext(self: *Self, sort_ctx: anytype, ctx: Context) void {
            return self.unmanaged.sortContext(sort_ctx, ctx);
        }

        pub fn sortUnstableContext(self: *Self, sort_ctx: anytype, ctx: Context) void {
            return self.unmanaged.sortUnstableContext(sort_ctx, ctx);
        }

        pub fn clone(self: Self) Allocator.Error!Self {
            return .{ .unmanaged = try self.unmanaged.clone(self.allocator), .allocator = self.allocator };
        }

        pub fn cloneWithAllocator(self: Self, new_allocator: Allocator) Allocator.Error!Self {
            return .{ .unmanaged = try self.unmanaged.clone(new_allocator), .allocator = new_allocator };
        }
    };
}

test "managed AutoArrayHashMap round-trips" {
    var m = AutoArrayHashMap(u32, u32).init(std.testing.allocator);
    defer m.deinit();
    try m.put(1, 10);
    try m.put(2, 20);
    try std.testing.expectEqual(@as(?u32, 10), m.get(1));
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expect(m.swapRemove(1));
    try std.testing.expectEqual(@as(?u32, null), m.get(1));
}
