// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/bake/DevServer/SourceMapStore.zig
// See LICENSE.bun.md for full license text.
//
// Lifetime-only subset for HMR socket cleanup. Bun's full store owns source
// map payloads and weak references; this Home slice preserves refcount and
// weak-ref upgrade/removal semantics so DevServer/HmrSocket deinit can be
// tested without the bundler.

const std = @import("std");

pub const SourceMapStore = struct {
    pub const Key = u32;

    pub const WeakRefAction = enum {
        remove,
        upgrade,
    };

    ref_counts: std.AutoHashMap(Key, usize),
    weak_refs: std.AutoHashMap(Key, void),

    pub fn init(allocator: std.mem.Allocator) SourceMapStore {
        return .{
            .ref_counts = std.AutoHashMap(Key, usize).init(allocator),
            .weak_refs = std.AutoHashMap(Key, void).init(allocator),
        };
    }

    pub fn deinit(this: *SourceMapStore) void {
        this.ref_counts.deinit();
        this.weak_refs.deinit();
    }

    pub fn putOrIncrementRefCount(this: *SourceMapStore, key: Key) !void {
        const entry = try this.ref_counts.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = 1;
            return;
        }
        entry.value_ptr.* += 1;
    }

    pub fn unref(this: *SourceMapStore, key: Key) void {
        const count = this.ref_counts.getPtr(key) orelse return;
        if (count.* <= 1) {
            _ = this.ref_counts.remove(key);
            return;
        }
        count.* -= 1;
    }

    pub fn putWeakRef(this: *SourceMapStore, key: Key) !void {
        try this.weak_refs.put(key, {});
    }

    pub fn removeOrUpgradeWeakRef(this: *SourceMapStore, key: Key, action: WeakRefAction) !bool {
        if (!this.weak_refs.remove(key)) return false;
        if (action == .upgrade) try this.putOrIncrementRefCount(key);
        return true;
    }

    pub fn refCount(this: *const SourceMapStore, key: Key) usize {
        return this.ref_counts.get(key) orelse 0;
    }

    pub fn hasWeakRef(this: *const SourceMapStore, key: Key) bool {
        return this.weak_refs.contains(key);
    }
};

test "SourceMapStore increments decrements and removes refcounts" {
    var store = SourceMapStore.init(std.testing.allocator);
    defer store.deinit();

    try store.putOrIncrementRefCount(7);
    try store.putOrIncrementRefCount(7);
    try std.testing.expectEqual(@as(usize, 2), store.refCount(7));

    store.unref(7);
    try std.testing.expectEqual(@as(usize, 1), store.refCount(7));

    store.unref(7);
    try std.testing.expectEqual(@as(usize, 0), store.refCount(7));
}

test "SourceMapStore upgrades weak refs into strong refs" {
    var store = SourceMapStore.init(std.testing.allocator);
    defer store.deinit();

    try store.putWeakRef(9);
    try std.testing.expect(store.hasWeakRef(9));
    try std.testing.expect(try store.removeOrUpgradeWeakRef(9, .upgrade));
    try std.testing.expect(!store.hasWeakRef(9));
    try std.testing.expectEqual(@as(usize, 1), store.refCount(9));
}
