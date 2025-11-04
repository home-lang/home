// Collections Library - Standard Library Integration
// Main entry point for the Home Collections API
//
// Usage:
//   const collections = @import("collections");
//   var list = collections.Collection(i32).init(allocator);
//   var lazy = collections.LazyCollection(i32).init(allocator);

const std = @import("std");

// Export core types
pub const Collection = @import("collection.zig").Collection;
pub const LazyCollection = @import("lazy_collection.zig").LazyCollection;

// Export traits
pub const traits = @import("traits.zig");
pub const Collectible = traits.Collectible;
pub const Comparable = traits.Comparable;
pub const Aggregatable = traits.Aggregatable;
pub const Hashable = traits.Hashable;
pub const Displayable = traits.Displayable;
pub const Equatable = traits.Equatable;
pub const Cloneable = traits.Cloneable;
pub const Serializable = traits.Serializable;
pub const Iterable = traits.Iterable;

// Export macros
pub const macros = @import("macros.zig");

// ==================== Collection Builders ====================

/// Create a collection from an array/slice
pub fn collect(comptime T: type, items: []const T, allocator: std.mem.Allocator) !Collection(T) {
    var col = Collection(T).init(allocator);
    for (items) |item| {
        try col.push(item);
    }
    return col;
}

/// Create a collection from a range
pub fn range(comptime T: type, start: T, end: T, allocator: std.mem.Allocator) !Collection(T) {
    var col = Collection(T).init(allocator);
    var i = start;
    while (i < end) : (i += 1) {
        try col.push(i);
    }
    return col;
}

/// Create a collection by repeating a callback n times
pub fn times(comptime T: type, n: usize, callback: fn (usize) T, allocator: std.mem.Allocator) !Collection(T) {
    var col = Collection(T).init(allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try col.push(callback(i));
    }
    return col;
}

/// Wrap a single value in a collection
pub fn wrap(comptime T: type, value: T, allocator: std.mem.Allocator) !Collection(T) {
    var col = Collection(T).init(allocator);
    try col.push(value);
    return col;
}

/// Create an empty collection
pub fn empty(comptime T: type, allocator: std.mem.Allocator) Collection(T) {
    return Collection(T).init(allocator);
}

// ==================== Lazy Collection Builders ====================

/// Create a lazy collection from an array/slice
pub fn collectLazy(comptime T: type, items: []const T, allocator: std.mem.Allocator) !LazyCollection(T) {
    var col = LazyCollection(T).init(allocator);
    for (items) |item| {
        try col.push(item);
    }
    return col;
}

/// Create a lazy collection from a range
pub fn rangeLazy(comptime T: type, start: T, end: T, allocator: std.mem.Allocator) !LazyCollection(T) {
    var col = LazyCollection(T).init(allocator);
    var i = start;
    while (i < end) : (i += 1) {
        try col.push(i);
    }
    return col;
}

/// Create an empty lazy collection
pub fn emptyLazy(comptime T: type, allocator: std.mem.Allocator) LazyCollection(T) {
    return LazyCollection(T).init(allocator);
}

// ==================== Utility Functions ====================

/// Verify a type satisfies all collection traits
pub fn verifyCollectionType(comptime T: type) void {
    traits.verifyCollectible(T);
}

/// Verify a type can be used in sorting operations
pub fn verifySortableType(comptime T: type) void {
    traits.verifyCollectible(T);
    traits.verifyComparable(T);
}

/// Verify a type can be used in aggregation operations
pub fn verifyAggregatableType(comptime T: type) void {
    traits.verifyCollectible(T);
    traits.verifyAggregatable(T);
}

// ==================== Type Checking Helpers ====================

/// Check if a type is a Collection
pub fn isCollection(comptime T: type) bool {
    return @hasDecl(T, "isCollection") and T.isCollection;
}

/// Check if a type is a LazyCollection
pub fn isLazyCollection(comptime T: type) bool {
    return @hasDecl(T, "isLazyCollection") and T.isLazyCollection;
}

/// Get the element type of a collection
pub fn ElementType(comptime CollectionType: type) type {
    if (@hasDecl(CollectionType, "ElementType")) {
        return CollectionType.ElementType;
    } else {
        @compileError("Type is not a collection");
    }
}

// ==================== Constants ====================

pub const VERSION = "1.0.0";
pub const AUTHOR = "Home Language Team";
pub const LICENSE = "MIT";

// Export test utilities for users
pub const testing = struct {
    pub const std_testing = std.testing;

    /// Helper to create a test collection
    pub fn testCollection(comptime T: type, items: []const T) !Collection(T) {
        return collect(T, items, std_testing.allocator);
    }

    /// Helper to create a test lazy collection
    pub fn testLazyCollection(comptime T: type, items: []const T) !LazyCollection(T) {
        return collectLazy(T, items, std_testing.allocator);
    }
};
