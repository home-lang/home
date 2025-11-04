# Collections Best Practices Guide

This guide provides recommendations and patterns for using the Collections library effectively in your Zig projects.

## Table of Contents

- [When to Use Collections](#when-to-use-collections)
- [Memory Management](#memory-management)
- [Performance Considerations](#performance-considerations)
- [Lazy vs Eager Evaluation](#lazy-vs-eager-evaluation)
- [Method Chaining](#method-chaining)
- [Common Patterns](#common-patterns)
- [Error Handling](#error-handling)
- [Testing](#testing)

## When to Use Collections

### Use Collections When:

✅ **Data Transformation Pipelines**: You need to filter, map, or transform data through multiple steps
```zig
var scores = try Collection(i32).fromSlice(allocator, &raw_scores);
defer scores.deinit();

var top_scores = try scores
    .filter(isPassingScore)
    .sortDesc()
    .take(10);
defer top_scores.deinit();
```

✅ **Statistical Analysis**: You need to compute aggregates, statistics, or group data
```zig
const avg = collection.avg();
const median_val = collection.median();
const mode_val = collection.mode();
```

✅ **Complex Data Operations**: Working with nested data, grouping, partitioning, or set operations
```zig
var grouped = try collection.groupBy(u8, getCategory);
var partitioned = try collection.partition(isValid);
```

### Stick with Arrays When:

❌ **Simple Iterations**: Basic for loops over data without transformations
```zig
// Don't create a collection just for this:
for (items) |item| {
    std.debug.print("{}\n", .{item});
}
```

❌ **Performance Critical Code**: Hot paths where allocations must be minimized
❌ **Static Data**: Compile-time known arrays that never change

## Memory Management

### Always Use defer

**Rule #1**: Every collection must have a corresponding `deinit()` call.

```zig
// ✅ GOOD: Proper cleanup
var col = Collection(i32).init(allocator);
defer col.deinit();

// ❌ BAD: Memory leak
var col = Collection(i32).init(allocator);
// Forgot to call deinit()
```

### Cleanup Chained Operations

When chaining, each intermediate result needs cleanup:

```zig
// ✅ GOOD: All intermediate collections cleaned up
var filtered = try collection.filter(predicate);
defer filtered.deinit();

var mapped = try filtered.map(i32, mapper);
defer mapped.deinit();

var result = try mapped.take(10);
defer result.deinit();
```

### Special Cases: Nested Collections

Collections of collections require nested cleanup:

```zig
var chunks = try collection.chunk(3);
defer {
    // Clean up each inner collection first
    for (chunks.all()) |chunk| {
        chunk.deinit();
    }
    // Then clean up outer collection
    chunks.deinit();
}
```

### HashMap Results (groupBy)

GroupBy returns a HashMap with Collection values:

```zig
var grouped = try collection.groupBy(u8, keyFn);
defer {
    var it = grouped.valueIterator();
    while (it.next()) |group| {
        group.deinit();  // Clean up each group
    }
    grouped.deinit();  // Clean up the map
}
```

## Performance Considerations

### Prefer Lazy Collections for Large Datasets

Lazy collections avoid creating intermediate allocations:

```zig
// ❌ EAGER: Creates 3 intermediate collections (1000 items each)
const items = [_]i32{0} ** 1000;
var col = try Collection(i32).fromSlice(allocator, &items);
defer col.deinit();

var filtered = try col.filter(predicate);  // Allocation #1
defer filtered.deinit();

var mapped = try filtered.map(i32, mapper);  // Allocation #2
defer mapped.deinit();

var result = try mapped.take(10);  // Allocation #3, but only need 10 items!
defer result.deinit();

// ✅ LAZY: Only allocates final result (10 items)
const lzy = LazyCollection(i32).fromSlice(allocator, &items);
const chain = lzy.filter(&predicate).map(&mapper);
var result = try chain.take(10);  // Short-circuits after 10 items
defer result.deinit();
```

### Minimize Allocations in Hot Loops

```zig
// ❌ BAD: Creating collection in loop
for (data_batches) |batch| {
    var col = try Collection(i32).fromSlice(allocator, batch);
    defer col.deinit();
    // Process...
}

// ✅ GOOD: Reuse collection
var col = Collection(i32).init(allocator);
defer col.deinit();

for (data_batches) |batch| {
    col.clear();  // Reuse existing allocation
    for (batch) |item| {
        try col.push(item);
    }
    // Process...
}
```

### Use Appropriate Methods

- **`contains()`** is O(n) - consider a HashSet for frequent lookups
- **`sort()`** is O(n log n) - don't sort unnecessarily
- **`unique()`** uses a HashMap internally - efficient for large datasets
- **`reduce()`** is more efficient than chaining multiple operations

### Pre-allocate When Size is Known

```zig
var col = Collection(i32).init(allocator);
defer col.deinit();

// ✅ GOOD: Pre-allocate if you know the size
try col.items.ensureTotalCapacity(expected_size);

for (items) |item| {
    try col.push(item);
}
```

## Lazy vs Eager Evaluation

### When to Use Lazy Collections

Use `LazyCollection` when:

1. **Processing large datasets** where you only need a subset
2. **Memory is constrained** and you can't afford intermediate allocations
3. **Short-circuit evaluation** is beneficial (take, find, etc.)

```zig
// Perfect for lazy: Only need first 10 items
const lzy = LazyCollection(i32).fromSlice(allocator, &large_array);
var result = try lzy.filter(&predicate).map(&mapper).take(10);
defer result.deinit();
```

### When to Use Eager Collections

Use regular `Collection` when:

1. **Need to reuse results** multiple times
2. **Multiple passes** over the same data
3. **Need mutable operations** (sort, reverse, shuffle)
4. **Full materialization** is required anyway

```zig
// Better eager: Will iterate multiple times
var col = try Collection(i32).fromSlice(allocator, &items);
defer col.deinit();

const sum = col.sum();
const avg = col.avg();
const max_val = col.max();
```

## Method Chaining

### Pattern: Filter → Transform → Aggregate

```zig
const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
var col = try Collection(i32).fromSlice(allocator, &items);
defer col.deinit();

// 1. Filter
var evens = try col.filter(isEven);
defer evens.deinit();

// 2. Transform
var doubled = try evens.map(i32, double);
defer doubled.deinit();

// 3. Aggregate
const sum = doubled.sum();
```

### Pattern: Group → Process → Flatten

```zig
// Group by category
var grouped = try collection.groupBy(u8, getCategory);
defer {
    var it = grouped.valueIterator();
    while (it.next()) |group| {
        group.deinit();
    }
    grouped.deinit();
}

// Process each group
var it = grouped.iterator();
while (it.next()) |entry| {
    const category = entry.key_ptr.*;
    const group = entry.value_ptr.*;

    const avg = group.avg();
    std.debug.print("Category {} avg: {}\n", .{ category, avg });
}
```

### Pattern: Partition → Process Separately → Merge

```zig
var result = try collection.partition(predicate);
defer result.pass.deinit();
defer result.fail.deinit();

// Process each partition differently
var passed_processed = try result.pass.map(i32, processValid);
defer passed_processed.deinit();

var failed_processed = try result.fail.map(i32, processInvalid);
defer failed_processed.deinit();

// Merge back
var merged = try passed_processed.merge(&failed_processed);
defer merged.deinit();
```

## Common Patterns

### Removing Duplicates

```zig
// Simple deduplication
var unique_items = try collection.unique();
defer unique_items.deinit();

// Keep track of duplicates
var dups = try collection.duplicates();
defer dups.deinit();
```

### Top-N Selection

```zig
// Get top 10 scores
var sorted = try collection.clone();
defer sorted.deinit();
sorted.sortDesc();

var top10 = try sorted.take(10);
defer top10.deinit();
```

### Data Validation

```zig
// Check if all/any items meet condition
const all_valid = collection.every(isValid);
const has_invalid = collection.some(isInvalid);

// Partition valid/invalid
var result = try collection.partition(isValid);
defer result.pass.deinit();
defer result.fail.deinit();

if (result.fail.count() > 0) {
    std.debug.print("Found {} invalid items\n", .{result.fail.count()});
}
```

### Sliding Window Processing

```zig
// Process data in overlapping windows
var windows = try collection.sliding(3, 1);  // size=3, step=1
defer windows.deinit();

for (windows.all()) |window| {
    // Each window is a []const T slice
    var sum: i32 = 0;
    for (window) |val| sum += val;

    if (sum > threshold) {
        // Handle spike
    }
}
```

### Batch Processing

```zig
// Process data in non-overlapping chunks
var batches = try collection.chunk(100);
defer batches.deinit();

for (batches.all()) |batch| {
    // Process each batch
    processBatch(batch);
}
```

## Error Handling

### Handle Allocation Failures

Most collection operations return `!Collection(T)`, indicating they can fail with OOM:

```zig
var filtered = collection.filter(predicate) catch |err| {
    std.debug.print("Failed to filter: {}\n", .{err});
    return err;
};
defer filtered.deinit();
```

### Verify Results

Some operations return optionals for missing data:

```zig
const first = collection.first();
if (first) |value| {
    std.debug.print("First: {}\n", .{value});
} else {
    std.debug.print("Collection is empty\n", .{});
}

// Or use orelse for defaults
const max_val = collection.max() orelse 0;
```

### Validate Indices

```zig
// Check before accessing
if (collection.has(index)) {
    const value = collection.get(index).?;
    // Safe to use
}

// Or check multiple indices
const indices = [_]usize{ 5, 10, 15 };
if (collection.hasAny(&indices)) {
    // At least one index exists
}
```

## Testing

### Test Collection Operations

```zig
test "process user scores" {
    const allocator = std.testing.allocator;

    const scores = [_]i32{ 85, 92, 78, 95, 88 };
    var col = try Collection(i32).fromSlice(allocator, &scores);
    defer col.deinit();

    const avg = col.avg();
    try std.testing.expectApproxEqRel(@as(f64, 87.6), avg, 0.01);
}
```

### Test Memory Cleanup

Use `std.testing.allocator` to detect memory leaks:

```zig
test "no memory leaks" {
    const allocator = std.testing.allocator;

    var col = Collection(i32).init(allocator);
    defer col.deinit();  // This will fail the test if memory leaks

    try col.push(1);
    try col.push(2);
    try col.push(3);
}
```

### Test Edge Cases

```zig
test "empty collection" {
    const allocator = std.testing.allocator;

    var col = Collection(i32).init(allocator);
    defer col.deinit();

    try std.testing.expectEqual(@as(usize, 0), col.count());
    try std.testing.expect(col.isEmpty());
    try std.testing.expect(col.first() == null);
    try std.testing.expect(col.max() == null);
}

test "single item" {
    const allocator = std.testing.allocator;

    var col = Collection(i32).init(allocator);
    defer col.deinit();

    try col.push(42);

    try std.testing.expectEqual(@as(i32, 42), col.first().?);
    try std.testing.expectEqual(@as(i32, 42), col.last().?);
    try std.testing.expectEqual(@as(i32, 42), col.max().?);
    try std.testing.expectEqual(@as(i32, 42), col.min().?);
}
```

## Summary

### Key Takeaways

1. **Always call `deinit()`** - Use `defer` immediately after creation
2. **Choose lazy for large datasets** - Avoid unnecessary intermediate allocations
3. **Pre-allocate when possible** - Use `ensureTotalCapacity()` if size is known
4. **Chain operations thoughtfully** - Balance readability with performance
5. **Handle errors properly** - Most operations can fail with OOM
6. **Test with std.testing.allocator** - Catches memory leaks automatically

### Performance Quick Reference

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `push()` | O(1) amortized | May reallocate |
| `get()` | O(1) | Direct array access |
| `contains()` | O(n) | Linear search |
| `filter()` | O(n) | Creates new collection |
| `map()` | O(n) | Creates new collection |
| `reduce()` | O(n) | No allocation |
| `sort()` | O(n log n) | In-place |
| `unique()` | O(n) | Uses HashMap |
| `groupBy()` | O(n) | Uses HashMap |
| `take()` | O(n) | Creates new collection |
| `LazyCollection.take()` | O(n) | Short-circuits! |

---

For more examples, see the `examples/` directory and `tests/` for comprehensive usage patterns.
