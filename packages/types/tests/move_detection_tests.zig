const std = @import("std");
const move = @import("../src/move_detection.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// MoveSemantics Tests
// ============================================================================

test "move semantics - copy" {
    const copy_sem = move.MoveSemantics.Copy;

    try std.testing.expect(copy_sem.canCopy());
    try std.testing.expect(copy_sem.canMove());
}

test "move semantics - move" {
    const move_sem = move.MoveSemantics.Move;

    try std.testing.expect(!move_sem.canCopy());
    try std.testing.expect(move_sem.canMove());
}

test "move semantics - non-movable" {
    const non_movable = move.MoveSemantics.NonMovable;

    try std.testing.expect(!non_movable.canCopy());
    try std.testing.expect(!non_movable.canMove());
}

// ============================================================================
// MoveState Tests
// ============================================================================

test "move state - initialized" {
    const initialized = move.MoveState.Initialized;

    try std.testing.expect(initialized.canUse());
    try std.testing.expect(initialized.canMove());
    try std.testing.expect(initialized.canPartiallyMove());
}

test "move state - fully moved" {
    const fully_moved = move.MoveState.FullyMoved;

    try std.testing.expect(!fully_moved.canUse());
    try std.testing.expect(!fully_moved.canMove());
    try std.testing.expect(!fully_moved.canPartiallyMove());
}

test "move state - partially moved" {
    const partially_moved = move.MoveState.PartiallyMoved;

    try std.testing.expect(!partially_moved.canUse());
    try std.testing.expect(!partially_moved.canMove());
    try std.testing.expect(partially_moved.canPartiallyMove());
}

test "move state - uninitialized" {
    const uninitialized = move.MoveState.Uninitialized;

    try std.testing.expect(!uninitialized.canUse());
    try std.testing.expect(!uninitialized.canMove());
}

test "move state - conditionally moved" {
    const cond_moved = move.MoveState.ConditionallyMoved;

    try std.testing.expect(!cond_moved.canUse());
    try std.testing.expect(!cond_moved.canMove());
}

// ============================================================================
// MoveTracker Tests
// ============================================================================

test "move tracker - initialization" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Just verify it initializes
}

test "move tracker - register type" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Move);

    const sem = tracker.getSemantics("String");
    try std.testing.expect(sem == .Move);
}

test "move tracker - get unknown type defaults to move" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const sem = tracker.getSemantics("UnknownType");
    try std.testing.expect(sem == .Move);
}

test "move tracker - initialize variable" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const state = tracker.getState("x");
    try std.testing.expect(state == .Initialized);
}

test "move tracker - get uninitialized variable" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const state = tracker.getState("unknown");
    try std.testing.expect(state == .Uninitialized);
}

// ============================================================================
// Use After Move Tests
// ============================================================================

test "move tracker - check use of initialized" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkUse("x", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "move tracker - check use after move" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.moveValue("x", "y", "String", loc);

    // Try to use x after move
    try tracker.checkUse("x", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseAfterMove);
}

test "move tracker - use after move shows location" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const move_loc = ast.SourceLocation{ .line = 10, .column = 5, .file = "test.ion" };
    try tracker.moveValue("x", "y", "String", move_loc);

    const use_loc = ast.SourceLocation{ .line = 20, .column = 10, .file = "test.ion" };
    try tracker.checkUse("x", use_loc);

    try std.testing.expect(tracker.hasErrors());
    const err = tracker.errors.items[0];
    try std.testing.expect(err.move_location != null);
    try std.testing.expect(err.move_location.?.line == 10);
}

// ============================================================================
// Move Value Tests
// ============================================================================

test "move tracker - move value" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveValue("x", "y", "String", loc);

    try std.testing.expect(tracker.getState("x") == .FullyMoved);
    try std.testing.expect(tracker.getState("y") == .Initialized);
}

test "move tracker - copy type does not move" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("Int", .Copy);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveValue("x", "y", "Int", loc);

    // x should still be initialized (copy, not move)
    try std.testing.expect(tracker.getState("x") == .Initialized);
    try std.testing.expect(tracker.getState("y") == .Initialized);
}

test "move tracker - move from moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move once
    try tracker.moveValue("x", "y", "String", loc);

    // Try to move again
    try tracker.moveValue("x", "z", "String", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .MoveFromMovedValue);
}

test "move tracker - move from uninitialized" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveValue("x", "y", "String", loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Partial Move Tests
// ============================================================================

test "move tracker - move field" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveField("s", "field1", "x", loc);

    try std.testing.expect(tracker.getState("s") == .PartiallyMoved);
    try std.testing.expect(tracker.getState("x") == .Initialized);
}

test "move tracker - move field twice" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move field once
    try tracker.moveField("s", "field1", "x", loc);

    // Try to move same field again
    try tracker.moveField("s", "field1", "y", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseAfterMove);
}

test "move tracker - move different fields" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move different fields
    try tracker.moveField("s", "field1", "x", loc);
    try tracker.moveField("s", "field2", "y", loc);
    try tracker.moveField("s", "field3", "z", loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(tracker.getState("s") == .PartiallyMoved);
}

test "move tracker - move field from fully moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");
    try tracker.registerType("Struct", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Fully move the struct
    try tracker.moveValue("s", "t", "Struct", loc);

    // Try to move a field
    try tracker.moveField("s", "field1", "x", loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Conditional Move Tests
// ============================================================================

test "move tracker - conditional move first time" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.conditionalMove("x", loc);

    try std.testing.expect(tracker.getState("x") == .ConditionallyMoved);
}

test "move tracker - conditional move twice becomes fully moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // First conditional move
    try tracker.conditionalMove("x", loc);
    try std.testing.expect(tracker.getState("x") == .ConditionallyMoved);

    // Second conditional move
    try tracker.conditionalMove("x", loc);
    try std.testing.expect(tracker.getState("x") == .FullyMoved);
}

test "move tracker - conditional move from fully moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Fully move
    try tracker.moveValue("x", "y", "String", loc);

    // Try conditional move
    try tracker.conditionalMove("x", loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Path Merging Tests
// ============================================================================

test "move tracker - merge initialized paths" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.mergePaths("x", .Initialized, .Initialized);

    const state = tracker.getState("x");
    try std.testing.expect(state == .Initialized);
}

test "move tracker - merge initialized and moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.mergePaths("x", .Initialized, .FullyMoved);

    const state = tracker.getState("x");
    try std.testing.expect(state == .ConditionallyMoved);
}

test "move tracker - merge moved and initialized" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.mergePaths("x", .FullyMoved, .Initialized);

    const state = tracker.getState("x");
    try std.testing.expect(state == .ConditionallyMoved);
}

test "move tracker - merge both moved" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.mergePaths("x", .FullyMoved, .FullyMoved);

    const state = tracker.getState("x");
    try std.testing.expect(state == .FullyMoved);
}

// ============================================================================
// Reinitialization Tests
// ============================================================================

test "move tracker - reinitialize after move" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move x
    try tracker.moveValue("x", "y", "String", loc);
    try std.testing.expect(tracker.getState("x") == .FullyMoved);

    // Reinitialize
    try tracker.reinitialize("x", loc);
    try std.testing.expect(tracker.getState("x") == .Initialized);

    // Should be usable now
    try tracker.checkUse("x", loc);
    try std.testing.expect(!tracker.hasErrors());
}

test "move tracker - reinitialize clears field states" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Partially move
    try tracker.moveField("s", "field1", "x", loc);
    try std.testing.expect(tracker.getState("s") == .PartiallyMoved);

    // Reinitialize
    try tracker.reinitialize("s", loc);
    try std.testing.expect(tracker.getState("s") == .Initialized);
}

// ============================================================================
// Built-in Type Semantics Tests
// ============================================================================

test "builtin move semantics - primitives are copy" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try move.BuiltinMoveSemantics.register(&tracker);

    const types = [_][]const u8{
        "Int",  "U8",   "U16",  "U32",
        "U64",  "I8",   "I16",  "I32",
        "I64",  "F32",  "F64",  "Bool",
    };

    for (types) |type_name| {
        const sem = tracker.getSemantics(type_name);
        try std.testing.expect(sem == .Copy);
    }
}

test "builtin move semantics - string is move" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try move.BuiltinMoveSemantics.register(&tracker);

    const sem = tracker.getSemantics("String");
    try std.testing.expect(sem == .Move);
}

test "builtin move semantics - smart pointers" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try move.BuiltinMoveSemantics.register(&tracker);

    try std.testing.expect(tracker.getSemantics("Box") == .Move);
    try std.testing.expect(tracker.getSemantics("Rc") == .Copy);
    try std.testing.expect(tracker.getSemantics("Arc") == .Copy);
    try std.testing.expect(tracker.getSemantics("Mutex") == .Move);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - move copy type multiple times" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("Int", .Copy);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // "Move" multiple times (actually copy)
    try tracker.moveValue("x", "y", "Int", loc);
    try tracker.moveValue("x", "z", "Int", loc);
    try tracker.moveValue("x", "w", "Int", loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(tracker.getState("x") == .Initialized);
}

test "edge case - empty field list" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const state = tracker.getState("s");
    try std.testing.expect(state == .Initialized);
}

test "edge case - non-movable type" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("PinnedType", .NonMovable);

    const sem = tracker.getSemantics("PinnedType");
    try std.testing.expect(!sem.canMove());
}

test "stress test - many variables" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        try tracker.initialize(var_name);
    }

    try std.testing.expect(tracker.var_states.count() == 100);
}

test "stress test - many moves" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Int", .Copy); // Use copy so we can move many times

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.initialize("x");

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "y_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        try tracker.moveValue("x", var_name, "Int", loc);
    }

    try std.testing.expect(!tracker.hasErrors());
}

test "complex scenario - ownership transfer chain" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.initialize("a");
    try tracker.moveValue("a", "b", "String", loc);
    try tracker.moveValue("b", "c", "String", loc);
    try tracker.moveValue("c", "d", "String", loc);

    try std.testing.expect(tracker.getState("a") == .FullyMoved);
    try std.testing.expect(tracker.getState("b") == .FullyMoved);
    try std.testing.expect(tracker.getState("c") == .FullyMoved);
    try std.testing.expect(tracker.getState("d") == .Initialized);
}

test "complex scenario - conditional with merge" {
    var tracker = move.MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (cond) { move x } else { keep x }
    // After merge, x is conditionally moved
    try tracker.moveValue("x", "y", "String", loc);
    try tracker.mergePaths("x", .FullyMoved, .Initialized);

    try std.testing.expect(tracker.getState("x") == .ConditionallyMoved);

    // Can't use conditionally moved value
    try tracker.checkUse("x", loc);
    try std.testing.expect(tracker.hasErrors());
}
