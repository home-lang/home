const std = @import("std");
const testing = std.testing;
const collection_module = @import("collection");
const macros_module = @import("macros");
const Collection = collection_module.Collection;

// ==================== Collection Macro Tests ====================

test "Collection: macro (inline transform)" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* = item.* * 3;
        }
    }.call);

    try testing.expectEqual(@as(i32, 3), col.get(0).?);
    try testing.expectEqual(@as(i32, 6), col.get(1).?);
    try testing.expectEqual(@as(i32, 9), col.get(2).?);
}

test "Collection: macroFallible" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    // Test successful transformation
    _ = try col.macroFallible(struct {
        fn call(item: *i32) !void {
            item.* += 10;
        }
    }.call);

    try testing.expectEqual(@as(i32, 11), col.get(0).?);
    try testing.expectEqual(@as(i32, 12), col.get(1).?);
    try testing.expectEqual(@as(i32, 13), col.get(2).?);
}

test "Collection: chaining macros" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(10);
    try col.push(15);

    // Chain macros manually
    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* *= 2;
        }
    }.call);

    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* += 1;
        }
    }.call);

    try testing.expectEqual(@as(i32, 11), col.get(0).?); // 5 * 2 + 1 = 11
    try testing.expectEqual(@as(i32, 21), col.get(1).?); // 10 * 2 + 1 = 21
    try testing.expectEqual(@as(i32, 31), col.get(2).?); // 15 * 2 + 1 = 31
}

// ==================== Built-in Macros Tests ====================

test "Built-in macro: double" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    const double_fn = macros_module.doubleMacro(i32);
    _ = col.macro(double_fn);

    try testing.expectEqual(@as(i32, 2), col.get(0).?);
    try testing.expectEqual(@as(i32, 4), col.get(1).?);
    try testing.expectEqual(@as(i32, 6), col.get(2).?);
}

test "Built-in macro: increment" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(10);

    const increment_fn = macros_module.incrementMacro(i32);
    _ = col.macro(increment_fn);

    try testing.expectEqual(@as(i32, 6), col.get(0).?);
    try testing.expectEqual(@as(i32, 11), col.get(1).?);
}

test "Built-in macro: zero" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(42);
    try col.push(-10);
    try col.push(100);

    const zero_fn = macros_module.zeroMacro(i32);
    _ = col.macro(zero_fn);

    try testing.expectEqual(@as(i32, 0), col.get(0).?);
    try testing.expectEqual(@as(i32, 0), col.get(1).?);
    try testing.expectEqual(@as(i32, 0), col.get(2).?);
}

test "Built-in macro: negate" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(-3);
    try col.push(0);

    const negate_fn = macros_module.negateMacro(i32);
    _ = col.macro(negate_fn);

    try testing.expectEqual(@as(i32, -5), col.get(0).?);
    try testing.expectEqual(@as(i32, 3), col.get(1).?);
    try testing.expectEqual(@as(i32, 0), col.get(2).?);
}

test "Built-in macro: square" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(2);
    try col.push(3);
    try col.push(4);

    const square_fn = macros_module.squareMacro(i32);
    _ = col.macro(square_fn);

    try testing.expectEqual(@as(i32, 4), col.get(0).?);
    try testing.expectEqual(@as(i32, 9), col.get(1).?);
    try testing.expectEqual(@as(i32, 16), col.get(2).?);
}

test "Built-in macro: transformMacro" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    const custom_fn = struct {
        fn call(n: i32) i32 {
            return n * 10 + 5;
        }
    }.call;

    const transform_fn = macros_module.transformMacro(i32, custom_fn);
    _ = col.macro(transform_fn);

    try testing.expectEqual(@as(i32, 15), col.get(0).?); // 1 * 10 + 5
    try testing.expectEqual(@as(i32, 25), col.get(1).?); // 2 * 10 + 5
    try testing.expectEqual(@as(i32, 35), col.get(2).?); // 3 * 10 + 5
}

// ==================== Real-World Macro Usage Tests ====================

test "Real-world: Custom data normalization macro" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(100);
    try col.push(250);
    try col.push(0);
    try col.push(500);
    try col.push(-50);

    // Normalize to 0-100 range
    _ = col.macro(struct {
        fn call(item: *i32) void {
            if (item.* < 0) item.* = 0;
            if (item.* > 100) item.* = 100;
        }
    }.call);

    try testing.expectEqual(@as(i32, 100), col.get(0).?);
    try testing.expectEqual(@as(i32, 100), col.get(1).?);
    try testing.expectEqual(@as(i32, 0), col.get(2).?);
    try testing.expectEqual(@as(i32, 100), col.get(3).?);
    try testing.expectEqual(@as(i32, 0), col.get(4).?);
}

test "Real-world: Multiple macros for data pipeline" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    // Pipeline: double, then add 5, then clamp to max 50
    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* *= 2;
        }
    }.call);

    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* += 5;
        }
    }.call);

    _ = col.macro(struct {
        fn call(item: *i32) void {
            if (item.* > 50) item.* = 50;
        }
    }.call);

    try testing.expectEqual(@as(i32, 25), col.get(0).?); // 10 * 2 + 5 = 25
    try testing.expectEqual(@as(i32, 45), col.get(1).?); // 20 * 2 + 5 = 45
    try testing.expectEqual(@as(i32, 50), col.get(2).?); // 30 * 2 + 5 = 65, clamped to 50
}

test "Real-world: Percentage calculation macro" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(50);
    try col.push(75);
    try col.push(100);

    // Convert to percentages of 200
    _ = col.macro(struct {
        fn call(item: *i32) void {
            item.* = @divTrunc((item.* * 100), 200);
        }
    }.call);

    try testing.expectEqual(@as(i32, 25), col.get(0).?); // 50/200 * 100 = 25%
    try testing.expectEqual(@as(i32, 37), col.get(1).?); // 75/200 * 100 = 37%
    try testing.expectEqual(@as(i32, 50), col.get(2).?); // 100/200 * 100 = 50%
}
