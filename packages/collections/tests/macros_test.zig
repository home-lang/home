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

// ==================== Additional Numeric Macros Tests ====================

test "Built-in macro: decrement" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(10);
    try col.push(15);

    const decrement_fn = macros_module.decrementMacro(i32);
    _ = col.macro(decrement_fn);

    try testing.expectEqual(@as(i32, 4), col.get(0).?);
    try testing.expectEqual(@as(i32, 9), col.get(1).?);
    try testing.expectEqual(@as(i32, 14), col.get(2).?);
}

test "Built-in macro: halve (integer)" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    const halve_fn = macros_module.halveMacro(i32);
    _ = col.macro(halve_fn);

    try testing.expectEqual(@as(i32, 5), col.get(0).?);
    try testing.expectEqual(@as(i32, 10), col.get(1).?);
    try testing.expectEqual(@as(i32, 15), col.get(2).?);
}

test "Built-in macro: halve (float)" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(10.0);
    try col.push(20.5);
    try col.push(30.0);

    const halve_fn = macros_module.halveMacro(f64);
    _ = col.macro(halve_fn);

    try testing.expectEqual(@as(f64, 5.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 10.25), col.get(1).?);
    try testing.expectEqual(@as(f64, 15.0), col.get(2).?);
}

test "Built-in macro: triple" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(2);
    try col.push(3);
    try col.push(4);

    const triple_fn = macros_module.tripleMacro(i32);
    _ = col.macro(triple_fn);

    try testing.expectEqual(@as(i32, 6), col.get(0).?);
    try testing.expectEqual(@as(i32, 9), col.get(1).?);
    try testing.expectEqual(@as(i32, 12), col.get(2).?);
}

test "Built-in macro: abs" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(-5);
    try col.push(10);
    try col.push(-15);
    try col.push(0);

    const abs_fn = macros_module.absMacro(i32);
    _ = col.macro(abs_fn);

    try testing.expectEqual(@as(i32, 5), col.get(0).?);
    try testing.expectEqual(@as(i32, 10), col.get(1).?);
    try testing.expectEqual(@as(i32, 15), col.get(2).?);
    try testing.expectEqual(@as(i32, 0), col.get(3).?);
}

test "Built-in macro: cube" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(2);
    try col.push(3);
    try col.push(4);

    const cube_fn = macros_module.cubeMacro(i32);
    _ = col.macro(cube_fn);

    try testing.expectEqual(@as(i32, 8), col.get(0).?);
    try testing.expectEqual(@as(i32, 27), col.get(1).?);
    try testing.expectEqual(@as(i32, 64), col.get(2).?);
}

test "Built-in macro: multiplyBy" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(2);
    try col.push(3);
    try col.push(4);

    const multiply_fn = macros_module.multiplyByMacro(i32, 5);
    _ = col.macro(multiply_fn);

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 15), col.get(1).?);
    try testing.expectEqual(@as(i32, 20), col.get(2).?);
}

test "Built-in macro: add" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    const add_fn = macros_module.addMacro(i32, 10);
    _ = col.macro(add_fn);

    try testing.expectEqual(@as(i32, 11), col.get(0).?);
    try testing.expectEqual(@as(i32, 12), col.get(1).?);
    try testing.expectEqual(@as(i32, 13), col.get(2).?);
}

test "Built-in macro: subtract" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(20);
    try col.push(30);
    try col.push(40);

    const subtract_fn = macros_module.subtractMacro(i32, 5);
    _ = col.macro(subtract_fn);

    try testing.expectEqual(@as(i32, 15), col.get(0).?);
    try testing.expectEqual(@as(i32, 25), col.get(1).?);
    try testing.expectEqual(@as(i32, 35), col.get(2).?);
}

test "Built-in macro: divideBy" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    const divide_fn = macros_module.divideByMacro(i32, 2);
    _ = col.macro(divide_fn);

    try testing.expectEqual(@as(i32, 5), col.get(0).?);
    try testing.expectEqual(@as(i32, 10), col.get(1).?);
    try testing.expectEqual(@as(i32, 15), col.get(2).?);
}

test "Built-in macro: modulo" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(11);
    try col.push(12);
    try col.push(13);

    const modulo_fn = macros_module.moduloMacro(i32, 3);
    _ = col.macro(modulo_fn);

    try testing.expectEqual(@as(i32, 1), col.get(0).?);
    try testing.expectEqual(@as(i32, 2), col.get(1).?);
    try testing.expectEqual(@as(i32, 0), col.get(2).?);
    try testing.expectEqual(@as(i32, 1), col.get(3).?);
}

// ==================== Clamping Macros Tests ====================

test "Built-in macro: clampMax" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(15);
    try col.push(25);

    const clamp_fn = macros_module.clampMaxMacro(i32, 20);
    _ = col.macro(clamp_fn);

    try testing.expectEqual(@as(i32, 5), col.get(0).?);
    try testing.expectEqual(@as(i32, 15), col.get(1).?);
    try testing.expectEqual(@as(i32, 20), col.get(2).?);
}

test "Built-in macro: clampMin" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(15);
    try col.push(25);

    const clamp_fn = macros_module.clampMinMacro(i32, 10);
    _ = col.macro(clamp_fn);

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 15), col.get(1).?);
    try testing.expectEqual(@as(i32, 25), col.get(2).?);
}

test "Built-in macro: clampRange" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(15);
    try col.push(25);
    try col.push(35);

    const clamp_fn = macros_module.clampRangeMacro(i32, 10, 30);
    _ = col.macro(clamp_fn);

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 15), col.get(1).?);
    try testing.expectEqual(@as(i32, 25), col.get(2).?);
    try testing.expectEqual(@as(i32, 30), col.get(3).?);
}

// ==================== Rounding Macros Tests ====================

test "Built-in macro: round" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.4);
    try col.push(1.5);
    try col.push(2.6);

    const round_fn = macros_module.roundMacro(f64);
    _ = col.macro(round_fn);

    try testing.expectEqual(@as(f64, 1.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 2.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(2).?);
}

test "Built-in macro: floor" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.9);
    try col.push(2.1);
    try col.push(3.8);

    const floor_fn = macros_module.floorMacro(f64);
    _ = col.macro(floor_fn);

    try testing.expectEqual(@as(f64, 1.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 2.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(2).?);
}

test "Built-in macro: ceil" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.1);
    try col.push(2.9);
    try col.push(3.0);

    const ceil_fn = macros_module.ceilMacro(f64);
    _ = col.macro(ceil_fn);

    try testing.expectEqual(@as(f64, 2.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(2).?);
}

test "Built-in macro: trunc" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.9);
    try col.push(-2.9);
    try col.push(3.5);

    const trunc_fn = macros_module.truncMacro(f64);
    _ = col.macro(trunc_fn);

    try testing.expectEqual(@as(f64, 1.0), col.get(0).?);
    try testing.expectEqual(@as(f64, -2.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(2).?);
}

// ==================== Boolean Macros Tests ====================

test "Built-in macro: not" {
    var col = Collection(bool).init(testing.allocator);
    defer col.deinit();

    try col.push(true);
    try col.push(false);
    try col.push(true);

    const not_fn = macros_module.notMacro(bool);
    _ = col.macro(not_fn);

    try testing.expectEqual(false, col.get(0).?);
    try testing.expectEqual(true, col.get(1).?);
    try testing.expectEqual(false, col.get(2).?);
}

// ==================== Power & Root Macros Tests ====================

test "Built-in macro: sqrt" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(4.0);
    try col.push(9.0);
    try col.push(16.0);

    const sqrt_fn = macros_module.sqrtMacro(f64);
    _ = col.macro(sqrt_fn);

    try testing.expectEqual(@as(f64, 2.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 3.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 4.0), col.get(2).?);
}

test "Built-in macro: pow" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(2.0);
    try col.push(3.0);
    try col.push(4.0);

    const pow_fn = macros_module.powMacro(f64, 3.0);
    _ = col.macro(pow_fn);

    try testing.expectEqual(@as(f64, 8.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 27.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 64.0), col.get(2).?);
}

// ==================== Normalization Macros Tests ====================

test "Built-in macro: normalize" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(50.0);
    try col.push(100.0);

    const normalize_fn = macros_module.normalizeMacro(f64, 0.0, 100.0);
    _ = col.macro(normalize_fn);

    try testing.expectEqual(@as(f64, 0.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 0.5), col.get(1).?);
    try testing.expectEqual(@as(f64, 1.0), col.get(2).?);
}

test "Built-in macro: denormalize" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(0.5);
    try col.push(1.0);

    const denormalize_fn = macros_module.denormalizeMacro(f64, 0.0, 100.0);
    _ = col.macro(denormalize_fn);

    try testing.expectEqual(@as(f64, 0.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 50.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 100.0), col.get(2).?);
}

// ==================== Advanced Chained Macros ====================

test "Advanced chain: double -> increment -> clamp" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(10);
    try col.push(20);

    _ = col.macro(macros_module.doubleMacro(i32))
        .macro(macros_module.incrementMacro(i32))
        .macro(macros_module.clampMaxMacro(i32, 25));

    try testing.expectEqual(@as(i32, 11), col.get(0).?); // 5 * 2 + 1 = 11
    try testing.expectEqual(@as(i32, 21), col.get(1).?); // 10 * 2 + 1 = 21
    try testing.expectEqual(@as(i32, 25), col.get(2).?); // 20 * 2 + 1 = 41, clamped to 25
}

// ==================== Statistical Macros Tests ====================

test "Built-in macro: zScore" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(10.0);
    try col.push(20.0);
    try col.push(30.0);

    // Mean = 20.0, StdDev = 10.0
    const zscore_fn = macros_module.zScoreMacro(f64, 20.0, 10.0);
    _ = col.macro(zscore_fn);

    try testing.expectEqual(@as(f64, -1.0), col.get(0).?);
    try testing.expectEqual(@as(f64, 0.0), col.get(1).?);
    try testing.expectEqual(@as(f64, 1.0), col.get(2).?);
}

test "Built-in macro: log" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.0);
    try col.push(2.718281828459045); // e

    const log_fn = macros_module.logMacro(f64);
    _ = col.macro(log_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), col.get(1).?, 0.0001);
}

test "Built-in macro: log10" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(1.0);
    try col.push(10.0);
    try col.push(100.0);

    const log10_fn = macros_module.log10Macro(f64);
    _ = col.macro(log10_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), col.get(1).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), col.get(2).?, 0.0001);
}

test "Built-in macro: exp" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(1.0);

    const exp_fn = macros_module.expMacro(f64);
    _ = col.macro(exp_fn);

    try testing.expectApproxEqAbs(@as(f64, 1.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 2.718281828459045), col.get(1).?, 0.0001);
}

test "Built-in macro: sigmoid" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(1.0);
    try col.push(-1.0);

    const sigmoid_fn = macros_module.sigmoidMacro(f64);
    _ = col.macro(sigmoid_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.5), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.7310585786300049), col.get(1).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.2689414213699951), col.get(2).?, 0.0001);
}

test "Built-in macro: tanh" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(1.0);
    try col.push(-1.0);

    const tanh_fn = macros_module.tanhMacro(f64);
    _ = col.macro(tanh_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.7615941559557649), col.get(1).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -0.7615941559557649), col.get(2).?, 0.0001);
}

test "Built-in macro: scaleToRange" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(50.0);
    try col.push(100.0);

    // Scale from [0, 100] to [0, 10]
    const scale_fn = macros_module.scaleToRangeMacro(f64, 0.0, 100.0, 0.0, 10.0);
    _ = col.macro(scale_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 5.0), col.get(1).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 10.0), col.get(2).?, 0.0001);
}

test "Built-in macro: percentileRank" {
    var col = Collection(f64).init(testing.allocator);
    defer col.deinit();

    try col.push(0.0);
    try col.push(50.0);
    try col.push(100.0);

    const percentile_fn = macros_module.percentileRankMacro(f64, 0.0, 100.0);
    _ = col.macro(percentile_fn);

    try testing.expectApproxEqAbs(@as(f64, 0.0), col.get(0).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 50.0), col.get(1).?, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 100.0), col.get(2).?, 0.0001);
}
