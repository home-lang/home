const std = @import("std");
const overflow = @import("../src/overflow_detection.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// IntegerInfo Tests
// ============================================================================

test "integer info - signed types" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;
    try std.testing.expect(i8_info.is_signed);
    try std.testing.expect(i8_info.bit_width == 8);
    try std.testing.expect(i8_info.min_value == -128);
    try std.testing.expect(i8_info.max_value == 127);

    const i32_info = overflow.IntegerInfo.fromType(.I32).?;
    try std.testing.expect(i32_info.is_signed);
    try std.testing.expect(i32_info.bit_width == 32);
    try std.testing.expect(i32_info.min_value == -2147483648);
    try std.testing.expect(i32_info.max_value == 2147483647);
}

test "integer info - unsigned types" {
    const u8_info = overflow.IntegerInfo.fromType(.U8).?;
    try std.testing.expect(!u8_info.is_signed);
    try std.testing.expect(u8_info.bit_width == 8);
    try std.testing.expect(u8_info.min_value == 0);
    try std.testing.expect(u8_info.max_value == 255);

    const u32_info = overflow.IntegerInfo.fromType(.U32).?;
    try std.testing.expect(!u32_info.is_signed);
    try std.testing.expect(u32_info.bit_width == 32);
    try std.testing.expect(u32_info.min_value == 0);
    try std.testing.expect(u32_info.max_value == 4294967295);
}

test "integer info - non-integer type" {
    const string_info = overflow.IntegerInfo.fromType(.String);
    try std.testing.expect(string_info == null);
}

test "integer info - inRange" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;

    try std.testing.expect(i8_info.inRange(0));
    try std.testing.expect(i8_info.inRange(127));
    try std.testing.expect(i8_info.inRange(-128));
    try std.testing.expect(!i8_info.inRange(128));
    try std.testing.expect(!i8_info.inRange(-129));
}

// ============================================================================
// ValueRange Tests
// ============================================================================

test "value range - constant" {
    const range = overflow.ValueRange.fromConstant(42);
    try std.testing.expect(range.min == 42);
    try std.testing.expect(range.max == 42);
}

test "value range - init" {
    const range = overflow.ValueRange.init(-10, 100);
    try std.testing.expect(range.min == -10);
    try std.testing.expect(range.max == 100);
}

test "value range - addition overflow detection" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;

    const range1 = overflow.ValueRange.init(100, 120);
    const range2 = overflow.ValueRange.init(20, 30);

    // 120 + 30 = 150 > 127 (i8 max)
    try std.testing.expect(range1.canOverflowAdd(range2, i8_info));
}

test "value range - addition no overflow" {
    const i16_info = overflow.IntegerInfo.fromType(.I16).?;

    const range1 = overflow.ValueRange.init(10, 20);
    const range2 = overflow.ValueRange.init(5, 10);

    // 20 + 10 = 30 < 32767 (i16 max)
    try std.testing.expect(!range1.canOverflowAdd(range2, i16_info));
}

test "value range - subtraction underflow" {
    const u8_info = overflow.IntegerInfo.fromType(.U8).?;

    const range1 = overflow.ValueRange.init(10, 20);
    const range2 = overflow.ValueRange.init(30, 40);

    // 10 - 40 = -30 < 0 (u8 min)
    try std.testing.expect(range1.canOverflowSub(range2, u8_info));
}

test "value range - multiplication overflow" {
    const i16_info = overflow.IntegerInfo.fromType(.I16).?;

    const range1 = overflow.ValueRange.init(200, 300);
    const range2 = overflow.ValueRange.init(100, 200);

    // 300 * 200 = 60000 > 32767 (i16 max)
    try std.testing.expect(range1.canOverflowMul(range2, i16_info));
}

test "value range - division by zero" {
    const range1 = overflow.ValueRange.init(100, 200);
    const range2 = overflow.ValueRange.init(-5, 5); // Includes zero

    try std.testing.expect(range2.canOverflowDiv(range1));
}

test "value range - division by non-zero" {
    const range1 = overflow.ValueRange.init(100, 200);
    const range2 = overflow.ValueRange.init(1, 10); // Does not include zero

    try std.testing.expect(!range2.canOverflowDiv(range1));
}

test "value range - add computation" {
    const i32_info = overflow.IntegerInfo.fromType(.I32).?;

    const range1 = overflow.ValueRange.init(10, 20);
    const range2 = overflow.ValueRange.init(5, 15);

    const result = range1.add(range2, i32_info);

    try std.testing.expect(result.min == 15); // 10 + 5
    try std.testing.expect(result.max == 35); // 20 + 15
}

test "value range - sub computation" {
    const i32_info = overflow.IntegerInfo.fromType(.I32).?;

    const range1 = overflow.ValueRange.init(50, 100);
    const range2 = overflow.ValueRange.init(10, 20);

    const result = range1.sub(range2, i32_info);

    try std.testing.expect(result.min == 30); // 50 - 20
    try std.testing.expect(result.max == 90); // 100 - 10
}

test "value range - mul computation" {
    const i32_info = overflow.IntegerInfo.fromType(.I32).?;

    const range1 = overflow.ValueRange.init(2, 5);
    const range2 = overflow.ValueRange.init(3, 7);

    const result = range1.mul(range2, i32_info);

    try std.testing.expect(result.min == 6); // 2 * 3
    try std.testing.expect(result.max == 35); // 5 * 7
}

test "value range - mul with negative numbers" {
    const i32_info = overflow.IntegerInfo.fromType(.I32).?;

    const range1 = overflow.ValueRange.init(-5, -2);
    const range2 = overflow.ValueRange.init(3, 7);

    const result = range1.mul(range2, i32_info);

    try std.testing.expect(result.min == -35); // -5 * 7
    try std.testing.expect(result.max == -6); // -2 * 3
}

// ============================================================================
// OverflowTracker Tests
// ============================================================================

test "overflow tracker - mode setting" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.default_mode == .Runtime);

    tracker.setMode(.CompileTime);
    try std.testing.expect(tracker.default_mode == .CompileTime);
}

test "overflow tracker - set and get range" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const range = overflow.ValueRange.init(0, 100);
    try tracker.setRange("x", range);

    const retrieved = tracker.getRange("x");
    try std.testing.expect(retrieved.?.min == 0);
    try std.testing.expect(retrieved.?.max == 100);
}

test "overflow tracker - check addition with overflow" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range1 = overflow.ValueRange.init(100, 120);
    const range2 = overflow.ValueRange.init(20, 30);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkAdd(range1, range2, .I8, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .Addition);
}

test "overflow tracker - check addition without overflow" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range1 = overflow.ValueRange.init(10, 20);
    const range2 = overflow.ValueRange.init(5, 10);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkAdd(range1, range2, .I16, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "overflow tracker - check subtraction underflow" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range1 = overflow.ValueRange.init(10, 20);
    const range2 = overflow.ValueRange.init(30, 40);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkSub(range1, range2, .U8, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .Subtraction);
}

test "overflow tracker - check multiplication overflow" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range1 = overflow.ValueRange.init(200, 300);
    const range2 = overflow.ValueRange.init(100, 200);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkMul(range1, range2, .I16, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .Multiplication);
}

test "overflow tracker - check division by zero" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const dividend = overflow.ValueRange.init(100, 200);
    const divisor = overflow.ValueRange.init(-5, 5); // Includes zero
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDiv(dividend, divisor, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DivisionByZero);
}

test "overflow tracker - check cast truncation" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range = overflow.ValueRange.init(1000, 2000);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Cast i32 range to i8 (max 127)
    try tracker.checkCast(range, .I32, .I8, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .Truncation);
}

test "overflow tracker - unchecked mode warning" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.Unchecked);

    const range1 = overflow.ValueRange.init(100, 120);
    const range2 = overflow.ValueRange.init(20, 30);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkAdd(range1, range2, .I8, loc);

    // Should have warning, not error
    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(tracker.warnings.items.len > 0);
}

// ============================================================================
// Runtime Checks Tests
// ============================================================================

test "runtime checked addition - success" {
    const result = try overflow.RuntimeChecks.addChecked(i32, 100, 200);
    try std.testing.expect(result == 300);
}

test "runtime checked addition - overflow" {
    const result = overflow.RuntimeChecks.addChecked(i8, 100, 100);
    try std.testing.expectError(error.Overflow, result);
}

test "runtime checked subtraction - success" {
    const result = try overflow.RuntimeChecks.subChecked(i32, 500, 200);
    try std.testing.expect(result == 300);
}

test "runtime checked subtraction - underflow" {
    const result = overflow.RuntimeChecks.subChecked(u8, 50, 100);
    try std.testing.expectError(error.Overflow, result);
}

test "runtime checked multiplication - success" {
    const result = try overflow.RuntimeChecks.mulChecked(i32, 100, 200);
    try std.testing.expect(result == 20000);
}

test "runtime checked multiplication - overflow" {
    const result = overflow.RuntimeChecks.mulChecked(i8, 50, 50);
    try std.testing.expectError(error.Overflow, result);
}

test "saturating addition - normal" {
    const result = overflow.RuntimeChecks.addSaturating(i8, 50, 30);
    try std.testing.expect(result == 80);
}

test "saturating addition - overflow" {
    const result = overflow.RuntimeChecks.addSaturating(i8, 100, 100);
    try std.testing.expect(result == 127); // Saturated to max
}

test "saturating subtraction - normal" {
    const result = overflow.RuntimeChecks.subSaturating(i8, 50, 30);
    try std.testing.expect(result == 20);
}

test "saturating subtraction - underflow" {
    const result = overflow.RuntimeChecks.subSaturating(u8, 10, 50);
    try std.testing.expect(result == 0); // Saturated to min
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - max value operations" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;

    const max_range = overflow.ValueRange.fromConstant(127);
    const one = overflow.ValueRange.fromConstant(1);

    // Adding to max should overflow
    try std.testing.expect(max_range.canOverflowAdd(one, i8_info));
}

test "edge case - min value operations" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;

    const min_range = overflow.ValueRange.fromConstant(-128);
    const one = overflow.ValueRange.fromConstant(1);

    // Subtracting from min should underflow
    try std.testing.expect(min_range.canOverflowSub(one, i8_info));
}

test "edge case - zero multiplication" {
    const i32_info = overflow.IntegerInfo.fromType(.I32).?;

    const range1 = overflow.ValueRange.fromConstant(0);
    const range2 = overflow.ValueRange.init(std.math.minInt(i32), std.math.maxInt(i32));

    // 0 * anything = 0 (no overflow)
    try std.testing.expect(!range1.canOverflowMul(range2, i32_info));
}

test "edge case - negative overflow in multiplication" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;

    const range1 = overflow.ValueRange.fromConstant(-128);
    const range2 = overflow.ValueRange.fromConstant(-1);

    // -128 * -1 = 128 > 127 (overflow for i8)
    try std.testing.expect(range1.canOverflowMul(range2, i8_info));
}

test "edge case - full range" {
    const i8_info = overflow.IntegerInfo.fromType(.I8).?;
    const full_range = overflow.ValueRange.full(i8_info);

    try std.testing.expect(full_range.min == -128);
    try std.testing.expect(full_range.max == 127);
}

test "stress test - many range checks" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const range1 = overflow.ValueRange.init(@as(i64, @intCast(i)), @as(i64, @intCast(i + 10)));
        const range2 = overflow.ValueRange.init(@as(i64, @intCast(i + 5)), @as(i64, @intCast(i + 15)));

        _ = try tracker.checkAdd(range1, range2, .I32, loc);
    }

    // Should complete without crashing
}

test "complex scenario - loop counter" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Simulate: for i in 0..100 { x = i * 2 }
    const i_range = overflow.ValueRange.init(0, 100);
    const two = overflow.ValueRange.fromConstant(2);

    const result = try tracker.checkMul(i_range, two, .U8, loc);

    // 100 * 2 = 200 < 255 (u8 max), should be OK
    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(result.max == 200);
}

test "complex scenario - accumulator" {
    var tracker = overflow.OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Simulate: acc = 0; for i in 0..50 { acc += i }
    var acc_range = overflow.ValueRange.fromConstant(0);

    var i: i64 = 0;
    while (i < 50) : (i += 1) {
        const i_range = overflow.ValueRange.fromConstant(i);
        acc_range = try tracker.checkAdd(acc_range, i_range, .I32, loc);
    }

    // Sum of 0..49 = 1225
    try std.testing.expect(acc_range.max >= 1225);
    try std.testing.expect(!tracker.hasErrors());
}
