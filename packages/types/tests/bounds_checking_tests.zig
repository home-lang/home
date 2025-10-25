const std = @import("std");
const bounds = @import("../src/bounds_checking.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// BoundsCheckMode Tests
// ============================================================================

test "bounds check mode values" {
    const modes = [_]bounds.BoundsCheckMode{
        .Unchecked,
        .Runtime,
        .CompileTime,
        .Debug,
    };

    // Just verify all modes are defined
    try std.testing.expect(modes.len == 4);
}

// ============================================================================
// BoundsInfo Tests
// ============================================================================

test "bounds info - constant" {
    const info = bounds.BoundsInfo.constant(100);

    try std.testing.expect(info.known_length.? == 100);
    try std.testing.expect(info.min_length == 100);
    try std.testing.expect(info.max_length.? == 100);
}

test "bounds info - unknown" {
    const info = bounds.BoundsInfo.unknown();

    try std.testing.expect(info.known_length == null);
    try std.testing.expect(info.min_length == 0);
    try std.testing.expect(info.max_length == null);
}

test "bounds info - init with known length" {
    const info = bounds.BoundsInfo.init(50);

    try std.testing.expect(info.known_length.? == 50);
    try std.testing.expect(info.min_length == 50);
    try std.testing.expect(info.max_length.? == 50);
}

test "bounds info - init with null length" {
    const info = bounds.BoundsInfo.init(null);

    try std.testing.expect(info.known_length == null);
    try std.testing.expect(info.min_length == 0);
    try std.testing.expect(info.max_length == null);
}

test "bounds info - isInBounds valid" {
    const info = bounds.BoundsInfo.constant(100);
    const index = bounds.IndexRange.constant(50);

    try std.testing.expect(info.isInBounds(index));
}

test "bounds info - isInBounds invalid" {
    const info = bounds.BoundsInfo.constant(100);
    const index = bounds.IndexRange.constant(150);

    try std.testing.expect(!info.isInBounds(index));
}

test "bounds info - isInBounds boundary" {
    const info = bounds.BoundsInfo.constant(100);
    const index = bounds.IndexRange.constant(99);

    try std.testing.expect(info.isInBounds(index));
}

test "bounds info - mightBeOutOfBounds with known length" {
    const info = bounds.BoundsInfo.constant(100);

    const valid_index = bounds.IndexRange.constant(50);
    try std.testing.expect(!info.mightBeOutOfBounds(valid_index));

    const invalid_index = bounds.IndexRange.constant(150);
    try std.testing.expect(info.mightBeOutOfBounds(invalid_index));

    const negative_index = bounds.IndexRange.constant(-5);
    try std.testing.expect(info.mightBeOutOfBounds(negative_index));
}

test "bounds info - mightBeOutOfBounds with unknown length" {
    const info = bounds.BoundsInfo.unknown();
    const index = bounds.IndexRange.constant(50);

    // Unknown length always might be out of bounds
    try std.testing.expect(info.mightBeOutOfBounds(index));
}

// ============================================================================
// IndexRange Tests
// ============================================================================

test "index range - constant" {
    const range = bounds.IndexRange.constant(42);

    try std.testing.expect(range.min_index == 42);
    try std.testing.expect(range.max_index == 42);
}

test "index range - init" {
    const range = bounds.IndexRange.init(10, 20);

    try std.testing.expect(range.min_index == 10);
    try std.testing.expect(range.max_index == 20);
}

test "index range - unknown" {
    const range = bounds.IndexRange.unknown();

    try std.testing.expect(range.min_index == std.math.minInt(i64));
    try std.testing.expect(range.max_index == std.math.maxInt(i64));
}

test "index range - isDefinitelyValid" {
    const info = bounds.BoundsInfo.constant(100);

    const valid = bounds.IndexRange.init(10, 50);
    try std.testing.expect(valid.isDefinitelyValid(info));

    const invalid = bounds.IndexRange.init(10, 150);
    try std.testing.expect(!invalid.isDefinitelyValid(info));
}

test "index range - isDefinitelyInvalid negative" {
    const info = bounds.BoundsInfo.constant(100);

    const negative = bounds.IndexRange.init(-5, 10);
    try std.testing.expect(negative.isDefinitelyInvalid(info));
}

test "index range - isDefinitelyInvalid exceeds length" {
    const info = bounds.BoundsInfo.constant(100);

    const too_large = bounds.IndexRange.init(50, 150);
    try std.testing.expect(too_large.isDefinitelyInvalid(info));
}

test "index range - valid range" {
    const info = bounds.BoundsInfo.constant(100);

    const valid = bounds.IndexRange.init(0, 99);
    try std.testing.expect(!valid.isDefinitelyInvalid(info));
    try std.testing.expect(valid.isDefinitelyValid(info));
}

// ============================================================================
// BoundsTracker Tests
// ============================================================================

test "bounds tracker - initialization" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.default_mode == .Runtime);
}

test "bounds tracker - set mode" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);
    try std.testing.expect(tracker.default_mode == .CompileTime);
}

test "bounds tracker - set and get bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const info = bounds.BoundsInfo.constant(100);
    try tracker.setBounds("array", info);

    const retrieved = tracker.getBounds("array");
    try std.testing.expect(retrieved.known_length.? == 100);
}

test "bounds tracker - get unknown bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const info = tracker.getBounds("unknown_array");
    try std.testing.expect(info.known_length == null);
}

test "bounds tracker - set and get index range" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const range = bounds.IndexRange.init(0, 100);
    try tracker.setIndexRange("i", range);

    const retrieved = tracker.getIndexRange("i");
    try std.testing.expect(retrieved.min_index == 0);
    try std.testing.expect(retrieved.max_index == 100);
}

test "bounds tracker - get unknown index range" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const range = tracker.getIndexRange("unknown");
    try std.testing.expect(range.min_index == std.math.minInt(i64));
    try std.testing.expect(range.max_index == std.math.maxInt(i64));
}

// ============================================================================
// Access Checking Tests
// ============================================================================

test "bounds tracker - definitely out of bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(10));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(15), loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DefinitelyOutOfBounds);
}

test "bounds tracker - definitely in bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(50), loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "bounds tracker - boundary access (valid)" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(99), loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "bounds tracker - boundary access (invalid)" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(100), loc);

    try std.testing.expect(tracker.hasErrors());
}

test "bounds tracker - negative index" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(-5), loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DefinitelyOutOfBounds);
}

test "bounds tracker - possibly out of bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    const range = bounds.IndexRange.init(50, 150); // Might overflow
    try tracker.checkAccess("arr", range, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .PossiblyOutOfBounds);
}

test "bounds tracker - record bounds check" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const range = bounds.IndexRange.init(0, 50);
    try tracker.recordBoundsCheck("arr", range);

    // Should be recorded (implementation detail, just verify no crash)
    try std.testing.expect(tracker.checked_indices.count() > 0);
}

// ============================================================================
// Slice Tests
// ============================================================================

test "bounds tracker - valid slice" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const start = bounds.IndexRange.constant(10);
    const end = bounds.IndexRange.constant(50);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const slice_info = try tracker.checkSlice("arr", start, end, loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(slice_info.known_length != null);
}

test "bounds tracker - invalid slice (start > end)" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const start = bounds.IndexRange.constant(50);
    const end = bounds.IndexRange.constant(10);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkSlice("arr", start, end, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .InvalidSlice);
}

test "bounds tracker - slice out of bounds" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const start = bounds.IndexRange.constant(50);
    const end = bounds.IndexRange.constant(150);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkSlice("arr", start, end, loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Loop Tests
// ============================================================================

test "bounds tracker - loop with known length" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkLoop("arr", "i", loc);

    const i_range = tracker.getIndexRange("i");
    try std.testing.expect(i_range.min_index == 0);
    try std.testing.expect(i_range.max_index == 99);
}

test "bounds tracker - loop with unknown length" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setBounds("arr", bounds.BoundsInfo.unknown());

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkLoop("arr", "i", loc);

    try std.testing.expect(tracker.warnings.items.len > 0);
}

// ============================================================================
// Conditional Inference Tests
// ============================================================================

test "bounds tracker - infer from less than" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 100));

    const refined = try tracker.inferFromConditional("i", .LessThan, 50);

    try std.testing.expect(refined.min_index == 0);
    try std.testing.expect(refined.max_index == 49);
}

test "bounds tracker - infer from less equal" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 100));

    const refined = try tracker.inferFromConditional("i", .LessEqual, 50);

    try std.testing.expect(refined.min_index == 0);
    try std.testing.expect(refined.max_index == 50);
}

test "bounds tracker - infer from greater than" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 100));

    const refined = try tracker.inferFromConditional("i", .GreaterThan, 50);

    try std.testing.expect(refined.min_index == 51);
    try std.testing.expect(refined.max_index == 100);
}

test "bounds tracker - infer from greater equal" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 100));

    const refined = try tracker.inferFromConditional("i", .GreaterEqual, 50);

    try std.testing.expect(refined.min_index == 50);
    try std.testing.expect(refined.max_index == 100);
}

test "bounds tracker - infer from equal" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 100));

    const refined = try tracker.inferFromConditional("i", .Equal, 50);

    try std.testing.expect(refined.min_index == 50);
    try std.testing.expect(refined.max_index == 50);
}

// ============================================================================
// Runtime Checks Tests
// ============================================================================

test "runtime bounds check - valid index" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    try bounds.RuntimeBoundsChecks.checkIndex(2, array.len);
    // Should not error
}

test "runtime bounds check - invalid index" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.checkIndex(10, array.len);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "runtime bounds check - boundary index" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    try bounds.RuntimeBoundsChecks.checkIndex(4, array.len);

    const result = bounds.RuntimeBoundsChecks.checkIndex(5, array.len);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "runtime slice check - valid" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    try bounds.RuntimeBoundsChecks.checkSlice(1, 3, array.len);
}

test "runtime slice check - invalid (start > end)" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.checkSlice(3, 1, array.len);
    try std.testing.expectError(error.InvalidSlice, result);
}

test "runtime slice check - out of bounds" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.checkSlice(1, 10, array.len);
    try std.testing.expectError(error.SliceOutOfBounds, result);
}

test "runtime safe get - success" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const value = try bounds.RuntimeBoundsChecks.safeGet(i32, &array, 2);
    try std.testing.expect(value == 3);
}

test "runtime safe get - out of bounds" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.safeGet(i32, &array, 10);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "runtime safe set - success" {
    var array = [_]i32{ 1, 2, 3, 4, 5 };

    try bounds.RuntimeBoundsChecks.safeSet(i32, &array, 2, 42);
    try std.testing.expect(array[2] == 42);
}

test "runtime safe set - out of bounds" {
    var array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.safeSet(i32, &array, 10, 42);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "runtime safe slice - success" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const slice = try bounds.RuntimeBoundsChecks.safeSlice(i32, &array, 1, 4);
    try std.testing.expect(slice.len == 3);
    try std.testing.expect(slice[0] == 2);
}

test "runtime safe slice - invalid" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result = bounds.RuntimeBoundsChecks.safeSlice(i32, &array, 3, 1);
    try std.testing.expectError(error.InvalidSlice, result);
}

// ============================================================================
// Static Analysis Tests
// ============================================================================

test "static analysis - range add" {
    const a = bounds.IndexRange.init(10, 20);
    const b = bounds.IndexRange.init(5, 15);

    const result = bounds.StaticAnalysis.rangeAdd(a, b);

    try std.testing.expect(result.min_index == 15); // 10 + 5
    try std.testing.expect(result.max_index == 35); // 20 + 15
}

test "static analysis - range sub" {
    const a = bounds.IndexRange.init(50, 100);
    const b = bounds.IndexRange.init(10, 20);

    const result = bounds.StaticAnalysis.rangeSub(a, b);

    try std.testing.expect(result.min_index == 30); // 50 - 20
    try std.testing.expect(result.max_index == 90); // 100 - 10
}

test "static analysis - range mul" {
    const a = bounds.IndexRange.init(2, 5);
    const b = bounds.IndexRange.init(3, 7);

    const result = bounds.StaticAnalysis.rangeMul(a, b);

    try std.testing.expect(result.min_index == 6); // 2 * 3
    try std.testing.expect(result.max_index == 35); // 5 * 7
}

test "static analysis - range intersect" {
    const a = bounds.IndexRange.init(0, 100);
    const b = bounds.IndexRange.init(50, 150);

    const result = bounds.StaticAnalysis.rangeIntersect(a, b);

    try std.testing.expect(result.min_index == 50);
    try std.testing.expect(result.max_index == 100);
}

test "static analysis - range union" {
    const a = bounds.IndexRange.init(0, 50);
    const b = bounds.IndexRange.init(25, 100);

    const result = bounds.StaticAnalysis.rangeUnion(a, b);

    try std.testing.expect(result.min_index == 0);
    try std.testing.expect(result.max_index == 100);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - zero length array" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(0));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", bounds.IndexRange.constant(0), loc);

    try std.testing.expect(tracker.hasErrors());
}

test "edge case - max i64 index" {
    const range = bounds.IndexRange.constant(std.math.maxInt(i64));
    const info = bounds.BoundsInfo.constant(100);

    try std.testing.expect(range.isDefinitelyInvalid(info));
}

test "edge case - min i64 index" {
    const range = bounds.IndexRange.constant(std.math.minInt(i64));
    const info = bounds.BoundsInfo.constant(100);

    try std.testing.expect(range.isDefinitelyInvalid(info));
}

test "stress test - many bounds checks" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(1000));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const index = bounds.IndexRange.constant(@as(i64, @intCast(i)));
        try tracker.checkAccess("arr", index, loc);
    }

    try std.testing.expect(!tracker.hasErrors());
}

test "complex scenario - loop with array access" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // for i in 0..100 { arr[i] = ... }
    try tracker.checkLoop("arr", "i", loc);

    const i_range = tracker.getIndexRange("i");
    try tracker.checkAccess("arr", i_range, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "complex scenario - conditional bounds refinement" {
    var tracker = bounds.BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", bounds.BoundsInfo.constant(100));
    try tracker.setIndexRange("i", bounds.IndexRange.init(0, 150));

    // if (i < 100) { arr[i] = ... }
    const refined = try tracker.inferFromConditional("i", .LessThan, 100);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", refined, loc);

    try std.testing.expect(!tracker.hasErrors());
}
