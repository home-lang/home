// Home Collections Module
// Fluent, Laravel-inspired collections API for data transformation
//
// Usage:
//   const Basics = @import("basics");
//   const Collection = Basics.Collection;
//   const LazyCollection = Basics.LazyCollection;
//
// Or directly:
//   const collections = @import("collections");
//   var col = collections.Collection(i32).init(allocator);

const std = @import("std");

// Re-export collection types
pub const collection_module = @import("collections/collection.zig");
pub const lazy_collection_module = @import("collections/lazy_collection.zig");

pub const Collection = collection_module.Collection;
pub const LazyCollection = lazy_collection_module.LazyCollection;

// Re-export builder functions for convenience
pub const range = collection_module.range;
pub const times = collection_module.times;
pub const wrap = collection_module.wrap;
pub const empty = collection_module.empty;
pub const lazy = lazy_collection_module.lazy;

// Test to ensure imports work
test "collections module" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Collection
    var col = Collection(i32).init(allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    try testing.expectEqual(@as(usize, 3), col.count());

    // Test LazyCollection
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    const lzy = LazyCollection(i32).fromSlice(allocator, &items);
    try testing.expectEqual(@as(usize, 5), lzy.count());
}
