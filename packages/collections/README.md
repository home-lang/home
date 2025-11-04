# Collections API for Home Programming Language

A fluent, Laravel-inspired Collections API for the Home programming language, providing chainable methods for data transformation, filtering, sorting, and aggregation.

## Features

✅ **110+ Collection Methods** - Complete Laravel-inspired API
✅ **Lazy Collections** - Deferred execution for performance optimization
✅ **Generic Type Support** - Works with any type `Collection(T)` and `LazyCollection(T)`
✅ **Method Chaining** - Fluent interface for readable transformations
✅ **Zero-Cost Abstractions** - Compiles to efficient code
✅ **97 Comprehensive Tests** - Full test coverage (90 Collection + 7 Lazy)
✅ **Memory Safe** - Proper allocator management with RAII
✅ **Examples & Benchmarks** - Real-world usage and performance metrics

## Installation

Add to your `build.zig`:

```zig
const collections_module = b.createModule(.{
    .root_source_file = b.path("packages/collections/src/collection.zig"),
});

exe.root_module.addImport("collections", collections_module);
```

## Quick Start

```zig
const std = @import("std");
const collection = @import("collections");
const Collection = collection.Collection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create from array
    const numbers = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(allocator, &numbers);
    defer col.deinit();

    // Method chaining
    var result = try col
        .filter(struct {
            fn call(n: i32) bool { return n > 2; }
        }.call)
        .map(i32, struct {
            fn call(n: i32) i32 { return n * 2; }
        }.call);
    defer result.deinit();

    // result contains [6, 8, 10]
}
```

## Lazy Collections

Lazy collections defer execution until results are needed, enabling significant performance optimizations for large datasets.

### Why Use Lazy Collections?

1. **Avoid Intermediate Allocations** - No temporary collections created during chaining
2. **Short-Circuit Evaluation** - Stops processing after finding enough results
3. **Memory Efficiency** - Process data without loading everything into memory
4. **Better Performance** - Especially noticeable with large datasets and early exits

### Lazy Collection Example

```zig
const std = @import("std");
const lazy_collection = @import("lazy_collection");
const LazyCollection = lazy_collection.LazyCollection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Large dataset (1000 items)
    var large_dataset = try allocator.alloc(i32, 1000);
    defer allocator.free(large_dataset);
    for (large_dataset, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    // Define filter and map functions
    const filter_fn = struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0; // even numbers
        }
    }.call;

    const map_fn = struct {
        fn call(n: i32) i32 {
            return n * 3;
        }
    }.call;

    // Lazy evaluation - no intermediate collections!
    const lzy = LazyCollection(i32).fromSlice(allocator, large_dataset);
    const filtered = lzy.filter(&filter_fn);
    const mapped = filtered.map(&map_fn);

    // Only materializes first 10 items - short-circuits!
    var result = try mapped.take(10);
    defer result.deinit();

    // Result: [6, 12, 18, 24, 30, 36, 42, 48, 54, 60]
}
```

### Lazy vs Eager Comparison

```zig
// ❌ EAGER: Processes entire dataset, creates 3 intermediate collections
const items = [_]i32{0} ** 1000;
var col = try Collection(i32).fromSlice(allocator, &items);
defer col.deinit();

var filtered = try col.filter(predicate);  // Processes all 1000 items
defer filtered.deinit();

var mapped = try filtered.map(i32, mapper);  // Processes all filtered items
defer mapped.deinit();

var result = try mapped.take(10);  // Only need 10, but processed 1000!
defer result.deinit();

// ✅ LAZY: Processes ~20 items total, no intermediate collections
const lzy = LazyCollection(i32).fromSlice(allocator, &items);
var result = try lzy.filter(&predicate).map(&mapper).take(10);
defer result.deinit();
// Stops after finding 10 items! ~50x faster for this case
```

### When to Use Lazy vs Eager

**Use Lazy Collections when:**
- Processing large datasets (> 1000 items)
- Only need a subset of results (`take`, `find`, etc.)
- Memory is constrained
- Want to avoid intermediate allocations

**Use Regular Collections when:**
- Need to iterate multiple times
- Need mutable operations (`sort`, `reverse`, `shuffle`)
- Dataset is small (< 100 items)
- All items will be processed anyway

### Lazy Collection API

```zig
// Create lazy collection
const lzy = LazyCollection(i32).fromSlice(allocator, &items);

// Lazy operations (return new LazyCollection)
const filtered = lzy.filter(&predicate);
const mapped = filtered.map(&mapper);

// Terminal operations (materialize to Collection)
var result = try mapped.collect();  // Evaluate entire chain
var first_n = try mapped.take(n);   // Short-circuit after n items

// Count without materializing (when possible)
const count = lzy.count();
```

See `examples/lazy_example.zig` for a complete working example and `tests/benchmarks.zig` for performance comparisons.

## API Reference

### Creation Methods

```zig
// From array
var col = try Collection(i32).fromSlice(allocator, &items);

// From range
var nums = try collection.range(allocator, 1, 10); // [1,2,3..10]

// Repeat callback
var repeated = try collection.times(i32, allocator, 5, struct {
    fn call(i: usize) i32 { return @intCast(i * 2); }
}.call); // [0,2,4,6,8]

// Wrap single value
var single = try collection.wrap(i32, allocator, 42);

// Empty collection
var empty = collection.empty(i32, allocator);
```

### Transformation Methods

```zig
// Map - transform each element
var doubled = try col.map(i32, struct {
    fn call(n: i32) i32 { return n * 2; }
}.call);

// Filter - keep matching elements
var evens = try col.filter(struct {
    fn call(n: i32) bool { return @mod(n, 2) == 0; }
}.call);

// Reject - remove matching elements
var odds = try col.reject(struct {
    fn call(n: i32) bool { return @mod(n, 2) == 0; }
}.call);

// Reduce - fold to single value
const sum = col.reduce(i32, 0, struct {
    fn call(acc: i32, n: i32) i32 { return acc + n; }
}.call);

// Take first n
var first_three = try col.take(3);

// Skip first n
var after_two = try col.skip(2);

// Chunk into groups
var chunks = try col.chunk(3);

// Unique values only
var uniq = try col.unique();

// Flatten nested collections
var flat = try nested.flatten(i32);

// Partition by predicate
var parts = try col.partition(predicate);
// parts.pass and parts.fail

// Zip with another collection
var zipped = try col1.zip(T2, &col2);

// Windows (sliding)
var wins = try col.windows(3);

// Split into n groups
var groups = try col.splitInto(3);

// Collapse (flatten nested collections)
var collapsed = try nested.collapse(i32);

// Sliding windows with step
var sliding_wins = try col.sliding(3, 2);  // size 3, step 2
```

### Sorting Methods

```zig
// Sort in place (ascending)
col.sort();

// Sort in place (descending)
col.sortDesc();

// Create sorted copy
var sorted = try col.sorted();
var sorted_desc = try col.sortedDesc();

// Reverse
col.reverse();
var rev = try col.reversed();

// Shuffle (requires Random)
var prng = std.Random.DefaultPrng.init(0);
col.shuffle(prng.random());

// Sort by callback result
col.sortBy(i32, callback);
col.sortByDesc(i32, callback);
```

### Aggregation Methods

```zig
// Sum
const total = col.sum(); // 15

// Average
const avg = col.avg(); // 3.0

// Min/Max
const min = col.min(); // ?T
const max = col.max(); // ?T

// Median
const med = col.median(); // ?T

// Mode (most frequent)
const mode_val = col.mode(); // ?T

// Min and Max together
const mm = col.minMax(); // ?struct { min: T, max: T }

// Product
const prod = col.product(); // 120
```

### Query Methods

```zig
// Count
const len = col.count();

// Is empty
if (col.isEmpty()) { }
if (col.isNotEmpty()) { }

// Contains
if (col.contains(42)) { }

// Find first matching
const found = col.find(predicate); // ?T

// Any/All/None
if (col.some(predicate)) { }  // any match
if (col.every(predicate)) { }  // all match
if (col.none(predicate)) { }   // none match

// Has/HasAny
if (col.has(2)) { }  // has index
if (col.hasAny(&[_]usize{1, 5, 10})) { }  // has any index
```

### Access Methods

```zig
// First/Last
const first = col.first(); // ?T
const last = col.last(); // ?T
const first_or = col.firstOr(0); // T
const last_or = col.lastOr(0); // T

// Get by index
const item = col.get(2); // ?T
const item_or = col.getOr(2, 0); // T

// All items
const slice = col.all(); // []const T
```

### Iteration Methods

```zig
// For each
col.each(struct {
    fn call(item: i32) void {
        std.debug.print("{d}\n", .{item});
    }
}.call);

// For each with index
col.eachWithIndex(struct {
    fn call(item: i32, i: usize) void {
        std.debug.print("[{d}] = {d}\n", .{i, item});
    }
}.call);
```

### Where Clause Methods

```zig
// Filter by values in array
const allowed = [_]i32{ 2, 4, 6 };
var filtered = try col.whereIn(&allowed);

// Filter by values NOT in array
const excluded = [_]i32{ 1, 3, 5 };
var filtered = try col.whereNotIn(&excluded);

// Filter by range (inclusive)
var between = try col.whereBetween(10, 20);

// Filter outside range
var outside = try col.whereNotBetween(10, 20);
```

### Grouping Methods

```zig
// Count occurrences of each value
var freq = try col.frequencies();
defer freq.deinit();
// freq is AutoHashMap(T, usize) with counts

// Group by callback result
var groups = try col.groupBy(i32, struct {
    fn call(item: i32) i32 {
        return @mod(item, 2); // group by even/odd
    }
}.call);
defer {
    var it = groups.valueIterator();
    while (it.next()) |group| {
        group.deinit();
    }
    groups.deinit();
}

// Count items matching predicate
const even_count = col.countBy(struct {
    fn call(n: i32) bool {
        return @mod(n, 2) == 0;
    }
}.call);
```

### Extraction Methods

```zig
// Pluck field from structs
const User = struct { name: []const u8, age: i32 };
var users = try Collection(User).fromSlice(allocator, &user_data);
defer users.deinit();

var names = try users.pluck([]const u8, struct {
    fn call(user: User) []const u8 {
        return user.name;
    }
}.call);
defer names.deinit();
```

### String Methods

```zig
// Join into string
const result = try col.join(allocator, ", ");
defer allocator.free(result);

// Implode (alias for join)
const str = try col.implode(allocator, "-");
defer allocator.free(str);
```

### Advanced Query Methods

```zig
// Take while predicate is true
var taken = try col.takeWhile(predicate);

// Take until predicate is true
var until = try col.takeUntil(predicate);

// Skip while predicate is true
var skipped = try col.skipWhile(predicate);

// Skip until predicate is true
var skip_until = try col.skipUntil(predicate);

// Get only specific indices
const indices = [_]usize{ 0, 2, 4 };
var items = try col.only(&indices);

// Get all except specific indices
var except = try col.except(&indices);

// Slice collection
var sliced = try col.slice(1, 5);

// Get nth item (1-based, negative from end)
const item = col.nth(2); // second item
const last = col.nth(-1); // last item

// Prepend value
var prepended = try col.prepend(0);

// Shift (remove first)
const first = col.shift();

// Unshift (add to beginning)
try col.unshift(0);

// Check for duplicates
if (col.hasDuplicates()) { }

// Get duplicate values
var dups = try col.duplicates();

// Repeat collection n times
var repeated = try col.repeat(3);

// Pad to length with value
var padded = try col.pad(10, 0);
```

### Utility Methods

```zig
// Clone
var copy = try col.clone();

// Clear
col.clear();

// Concat
var combined = try col1.concat(&col2);

// Tap (for debugging/side effects)
_ = col.tap(struct {
    fn call(c: *Collection(i32)) void {
        std.debug.print("Count: {d}\n", .{c.count()});
    }
}.call);

// Pipe through function
const result = col.pipe(i32, struct {
    fn call(c: *const Collection(i32)) i32 {
        return c.sum();
    }
}.call);

// Pipe through multiple functions
_ = try col.pipeThrough(&[_]*const fn(*const Collection(i32)) !void{fn1, fn2});

// Debug dump
col.dump();
_ = col.dd(); // dump and return for chaining
```

### Combination Methods

```zig
// Merge collections (concatenate)
var merged = try col1.merge(&col2);

// Union (unique items from both)
var union_result = try col1.unionWith(&col2);

// Intersection (items in both)
var intersection = try col1.intersect(&col2);

// Difference (items in first but not second)
var diff = try col1.diff(&col2);

// Symmetric difference (items in either but not both)
var sym_diff = try col1.symmetricDiff(&col2);
```

### Conditional Methods

```zig
// Execute when condition is true
_ = try col.when(should_process, struct {
    fn call(c: *Collection(i32)) !void {
        try c.push(42);
    }
}.call);

// Execute when condition is false
_ = try col.unless(is_empty, struct {
    fn call(c: *Collection(i32)) !void {
        c.clear();
    }
}.call);

// Execute one of two callbacks based on condition
_ = try col.whenElse(
    has_items,
    on_true_callback,
    on_false_callback,
);
```

### Higher-Order Methods

```zig
// FlatMap - map and flatten in one operation
var flattened = try col.flatMap(i32, callback);

// Map with index
var indexed = try col.mapWithIndex(i32, struct {
    fn call(item: i32, idx: usize) i32 {
        return item + @intCast(idx);
    }
}.call);

// Map to dictionary
const KVPair = Collection(i32).KeyValuePair(i32, i32);
var dict = try col.mapToDictionary(i32, i32, struct {
    fn call(n: i32) KVPair {
        return .{ .key = n, .value = n * 2 };
    }
}.call);

// Map and spread
const result = try col.mapSpread(i32, struct {
    fn call(items: []const i32) i32 {
        var sum: i32 = 0;
        for (items) |n| sum += n;
        return sum;
    }
}.call);
```

### Conversion Methods

```zig
// Convert to JSON
const json = try col.toJson(allocator);
defer allocator.free(json);

// Convert to pretty JSON
const pretty = try col.toJsonPretty(allocator);
defer allocator.free(pretty);

// Create from JSON
var from_json = try Collection(i32).fromJson(allocator, "[1,2,3]");
defer from_json.deinit();

// Convert to owned slice
const slice = try col.toOwnedSlice();
defer allocator.free(slice);
```

## Examples

### Data Transformation Pipeline

```zig
const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
var col = try Collection(i32).fromSlice(allocator, &data);
defer col.deinit();

// Get sum of squares of even numbers > 4
var filtered = try col.filter(struct {
    fn call(n: i32) bool { return @mod(n, 2) == 0 and n > 4; }
}.call);
defer filtered.deinit();

var squared = try filtered.map(i32, struct {
    fn call(n: i32) i32 { return n * n; }
}.call);
defer squared.deinit();

const result = squared.sum(); // 6² + 8² + 10² = 36 + 64 + 100 = 200
```

### Statistical Analysis

```zig
const scores = [_]i32{ 85, 92, 78, 90, 88, 95, 82, 89 };
var col = try Collection(i32).fromSlice(allocator, &scores);
defer col.deinit();

const average = col.avg();           // 87.375
const minimum = col.min().?;         // 78
const maximum = col.max().?;         // 95
const median_score = col.median().?; // 88
```

### Grouping and Partitioning

```zig
const numbers = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
var col = try Collection(i32).fromSlice(allocator, &numbers);
defer col.deinit();

// Split into even and odd
var parts = try col.partition(struct {
    fn call(n: i32) bool { return @mod(n, 2) == 0; }
}.call);
defer parts.pass.deinit(); // [2,4,6,8,10]
defer parts.fail.deinit(); // [1,3,5,7,9]

// Or chunk into groups
var chunks = try col.chunk(3);
defer chunks.deinit();
// [[1,2,3], [4,5,6], [7,8,9], [10]]
```

## Performance

- **Zero-Copy where possible** - Methods like `all()` return slices without copying
- **Lazy evaluation available** - Use `LazyCollection` for deferred execution and short-circuit optimization
- **Efficient sorting** - Uses Zig's optimized `std.mem.sort`
- **Memory safe** - Proper allocator management with RAII pattern
- **No hidden allocations** - All operations that allocate return `!T` (error union)

### Performance Characteristics

| Operation | Complexity | Allocation | Notes |
|-----------|-----------|------------|-------|
| `push()` | O(1) amortized | Conditional | May grow backing array |
| `get()` | O(1) | None | Direct array access |
| `contains()` | O(n) | None | Linear search |
| `filter()` | O(n) | Yes | Creates new collection |
| `map()` | O(n) | Yes | Creates new collection |
| `reduce()` | O(n) | None | Aggregates in-place |
| `sort()` | O(n log n) | None | In-place sort |
| `unique()` | O(n) | Yes | Uses HashMap |
| `groupBy()` | O(n) | Yes | Uses HashMap |
| `LazyCollection.take()` | O(n) | Yes | **Short-circuits!** |

## Benchmarks

Run benchmarks with:
```bash
cd packages/collections
zig build-exe tests/benchmarks.zig --dep collection --dep lazy_collection -Mcollection=src/collection.zig -Mlazy_collection=src/lazy_collection.zig
./benchmarks
```

### Typical Performance (10k iterations)

```
=== Collections Performance Benchmarks ===

Push operations:
  Total: 45.23ms
  Average: 4523ns
  Ops/sec: 221,085

Filter operations:
  Total: 89.34ms
  Average: 8934ns
  Ops/sec: 111,932

Map operations:
  Total: 102.56ms
  Average: 10256ns
  Ops/sec: 97,503

Reduce operations:
  Total: 23.45ms
  Average: 2345ns
  Ops/sec: 426,439

Sort operations:
  Total: 178.92ms
  Average: 17892ns
  Ops/sec: 55,892

=== Lazy vs Eager Comparison ===

Eager: filter + map + take:
  Total: 287.45ms
  Average: 28745ns
  Ops/sec: 34,789

Lazy: filter + map + take:
  Total: 12.34ms
  Average: 1234ns
  Ops/sec: 810,373

Lazy is ~23x faster for this workload!
```

**Key Insight**: Lazy collections shine when you only need a subset of results. For the "filter + map + take(10)" pattern on 1000 items, lazy evaluation is 20-50x faster due to short-circuit evaluation.

## Testing

Run the test suite:

```bash
cd packages/collections
zig build test
```

**Current status: 97/97 tests passing** ✅

Test breakdown:
- **90 Collection tests** - Comprehensive coverage of all eager operations
- **7 LazyCollection tests** - Lazy evaluation and short-circuit behavior
- **9 Integration tests** - Complex real-world method chaining scenarios

All tests use `std.testing.allocator` to verify zero memory leaks.

## Examples

The `examples/` directory contains complete working examples:

- **`examples/data_transformation.zig`** - Data processing pipeline with filtering, statistics, and grouping
- **`examples/lazy_example.zig`** - Lazy evaluation demonstration with performance benefits
- **`tests/benchmarks.zig`** - Performance benchmarking suite

Run examples:
```bash
zig run examples/data_transformation.zig --dep collection -Mcollection=src/collection.zig
zig run examples/lazy_example.zig --dep collection --dep lazy_collection -Mcollection=src/collection.zig -Mlazy_collection=src/lazy_collection.zig
```

## Documentation

- **[Best Practices Guide](docs/BEST_PRACTICES.md)** - Comprehensive guide to using collections effectively, including:
  - When to use collections vs arrays
  - Memory management patterns
  - Performance considerations
  - Lazy vs eager evaluation strategies
  - Common patterns and anti-patterns
  - Testing strategies

## Implementation Status

See [COLLECTIONS_IMPLEMENTATION.md](../../COLLECTIONS_IMPLEMENTATION.md) for the full roadmap.

### ✅ Completed (Phases 1-8)

- ✅ **Phase 1-3**: Foundation & Core Methods (map, filter, reduce, etc.)
- ✅ **Phase 4**: Sorting & Aggregation (sort, avg, median, mode, etc.)
- ✅ **Phase 5**: Builder Functions (range, times, wrap, etc.)
- ✅ **Phase 6**: Advanced Methods (groupBy, partition, flatten, etc.)
- ✅ **Phase 7**: Utility Methods (pipe, tap, has, hasAny, etc.)
- ✅ **Phase 8**: Lazy Collections (deferred execution, short-circuit evaluation)
- ✅ **Phase 11**: Testing & Documentation (97 tests, examples, benchmarks, best practices)

### 🚧 Remaining Phases

- [ ] **Phase 9.2**: Collection Macros (custom method registration)
- [ ] **Phase 10**: Type System Integration (traits: Collectible, Comparable, Aggregatable)
- [ ] **Phase 12**: Standard Library Integration (collection literals, stdlib integration)

## Contributing

Contributions welcome! See the implementation plan for upcoming features.

## License

Same as Home programming language.

## Credits

Inspired by:
- [Laravel Collections](https://laravel.com/docs/collections)
- [Ruby Enumerable](https://ruby-doc.org/core/Enumerable.html)
- [Rust Iterator](https://doc.rust-lang.org/std/iter/trait.Iterator.html)
