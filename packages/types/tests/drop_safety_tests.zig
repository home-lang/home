const std = @import("std");
const drop = @import("../src/drop_safety.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// DropOrder Tests
// ============================================================================

test "drop order values" {
    const orders = [_]drop.DropOrder{
        .Unordered,
        .DropFirst,
        .DropLast,
        .Custom,
    };

    try std.testing.expect(orders.len == 4);
}

// ============================================================================
// DropBehavior Tests
// ============================================================================

test "drop behavior - trivial" {
    const trivial = drop.DropBehavior.Trivial;

    try std.testing.expect(!trivial.needsDrop());
    try std.testing.expect(!trivial.mayPanic());
}

test "drop behavior - simple" {
    const simple = drop.DropBehavior.Simple;

    try std.testing.expect(simple.needsDrop());
    try std.testing.expect(!simple.mayPanic());
}

test "drop behavior - complex" {
    const complex = drop.DropBehavior.Complex;

    try std.testing.expect(complex.needsDrop());
    try std.testing.expect(complex.mayPanic());
}

test "drop behavior - no drop" {
    const no_drop = drop.DropBehavior.NoDrop;

    try std.testing.expect(!no_drop.needsDrop());
}

// ============================================================================
// DropState Tests
// ============================================================================

test "drop state - alive" {
    const alive = drop.DropState.Alive;

    try std.testing.expect(alive.canDrop());
    try std.testing.expect(alive.canAccess());
}

test "drop state - dropping" {
    const dropping = drop.DropState.Dropping;

    try std.testing.expect(!dropping.canDrop());
    try std.testing.expect(dropping.canAccess());
}

test "drop state - dropped" {
    const dropped = drop.DropState.Dropped;

    try std.testing.expect(!dropped.canDrop());
    try std.testing.expect(!dropped.canAccess());
}

test "drop state - moved" {
    const moved = drop.DropState.Moved;

    try std.testing.expect(!moved.canDrop());
}

test "drop state - leaked" {
    const leaked = drop.DropState.Leaked;

    try std.testing.expect(!leaked.canDrop());
}

// ============================================================================
// DropSafetyTracker Tests
// ============================================================================

test "drop safety tracker - initialization" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.scope_depth == 0);
}

test "drop safety tracker - register type" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);

    const behavior = tracker.getBehavior("String");
    try std.testing.expect(behavior == .Simple);
}

test "drop safety tracker - get unknown type defaults to simple" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const behavior = tracker.getBehavior("UnknownType");
    try std.testing.expect(behavior == .Simple);
}

test "drop safety tracker - register variable" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.enterScope();
    try tracker.registerVariable("s", "String");

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Alive);
}

test "drop safety tracker - register trivial type not in scope drops" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Int", .Trivial);
    try tracker.enterScope();
    try tracker.registerVariable("i", "Int");

    // Trivial types don't need drop, so not added to scope list
    const current_scope = &tracker.scope_drops.items[tracker.scope_drops.items.len - 1];
    try std.testing.expect(current_scope.items.len == 0);
}

// ============================================================================
// Scope Management Tests
// ============================================================================

test "drop safety tracker - enter scope" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.enterScope();
    try std.testing.expect(tracker.scope_depth == 1);

    try tracker.enterScope();
    try std.testing.expect(tracker.scope_depth == 2);
}

test "drop safety tracker - exit scope" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.enterScope();
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    try std.testing.expect(tracker.scope_depth == 0);
}

test "drop safety tracker - exit scope without enter" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .ScopeError);
}

// ============================================================================
// Drop Variable Tests
// ============================================================================

test "drop safety tracker - drop variable" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.dropVariable("s", loc);

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Dropped);
}

test "drop safety tracker - drop undefined" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.dropVariable("undefined", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DropUndefined);
}

test "drop safety tracker - double drop" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Drop once
    try tracker.dropVariable("s", loc);

    // Try to drop again
    try tracker.dropVariable("s", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DoubleDrop);
}

test "drop safety tracker - drop moved" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    // Mark as moved
    try tracker.markMoved("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.dropVariable("s", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DoubleDrop);
}

// ============================================================================
// Drop Order Tests
// ============================================================================

test "drop safety tracker - add dependency" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.addDependency("a", "b", "b depends on a");

    try std.testing.expect(tracker.dependencies.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, tracker.dependencies.items[0].first, "a"));
    try std.testing.expect(std.mem.eql(u8, tracker.dependencies.items[0].second, "b"));
}

test "drop safety tracker - drop order violation" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Handle", .Simple);
    try tracker.registerVariable("a", "Handle");
    try tracker.registerVariable("b", "Handle");

    // b depends on a (a must be dropped first)
    try tracker.addDependency("a", "b", "b depends on a");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Try to drop b before a
    try tracker.dropVariable("b", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DropOrderViolation);
}

test "drop safety tracker - drop order correct" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Handle", .Simple);
    try tracker.registerVariable("a", "Handle");
    try tracker.registerVariable("b", "Handle");

    // b depends on a (a must be dropped first)
    try tracker.addDependency("a", "b", "b depends on a");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Drop in correct order
    try tracker.dropVariable("a", loc);
    try tracker.dropVariable("b", loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Scope Drop Order Tests
// ============================================================================

test "drop safety tracker - scope drops in LIFO order" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.enterScope();

    try tracker.registerVariable("a", "String");
    try tracker.registerVariable("b", "String");
    try tracker.registerVariable("c", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // Check drop order: c, b, a (LIFO)
    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 3);
    try std.testing.expect(std.mem.eql(u8, drop_order[0], "c"));
    try std.testing.expect(std.mem.eql(u8, drop_order[1], "b"));
    try std.testing.expect(std.mem.eql(u8, drop_order[2], "a"));
}

test "drop safety tracker - nested scope drops" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.enterScope();
    try tracker.registerVariable("a", "String");

    try tracker.enterScope();
    try tracker.registerVariable("b", "String");

    // Exit inner scope (drops b)
    try tracker.exitScope(loc);

    // Exit outer scope (drops a)
    try tracker.exitScope(loc);

    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 2);
    try std.testing.expect(std.mem.eql(u8, drop_order[0], "b"));
    try std.testing.expect(std.mem.eql(u8, drop_order[1], "a"));
}

// ============================================================================
// Mark Moved Tests
// ============================================================================

test "drop safety tracker - mark moved" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.enterScope();
    try tracker.registerVariable("s", "String");

    try tracker.markMoved("s");

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Moved);
}

test "drop safety tracker - moved not dropped on scope exit" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.enterScope();
    try tracker.registerVariable("s", "String");

    // Mark as moved
    try tracker.markMoved("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // s should not be in drop order (it was moved)
    const drop_order = tracker.getDropOrder();
    for (drop_order) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "s"));
    }
}

// ============================================================================
// Mark Leaked Tests
// ============================================================================

test "drop safety tracker - mark leaked" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.markLeaked("s", loc);

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Leaked);

    // Should have warning
    try std.testing.expect(tracker.warnings.items.len > 0);
}

// ============================================================================
// Access During Drop Tests
// ============================================================================

test "drop safety tracker - access during drop warning" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    // Manually set to dropping state
    try tracker.var_states.put("s", .Dropping);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccessDuringDrop("s", loc);

    try std.testing.expect(tracker.warnings.items.len > 0);
}

test "drop safety tracker - access after drop error" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.dropVariable("s", loc);

    // Try to access after drop
    try tracker.checkAccessDuringDrop("s", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseAfterDrop);
}

// ============================================================================
// Drop Panic Warning Tests
// ============================================================================

test "drop safety tracker - complex drop may panic warning" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Mutex", .Complex);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDropPanic("Mutex", loc);

    try std.testing.expect(tracker.warnings.items.len > 0);
}

test "drop safety tracker - simple drop no warning" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDropPanic("String", loc);

    try std.testing.expect(tracker.warnings.items.len == 0);
}

// ============================================================================
// Built-in Drop Behaviors Tests
// ============================================================================

test "builtin drop behaviors - primitives are trivial" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try drop.BuiltinDropBehaviors.register(&tracker);

    const types = [_][]const u8{
        "Int",  "U8",   "U16",  "U32",
        "U64",  "I8",   "I16",  "I32",
        "I64",  "F32",  "F64",  "Bool",
    };

    for (types) |type_name| {
        const behavior = tracker.getBehavior(type_name);
        try std.testing.expect(behavior == .Trivial);
    }
}

test "builtin drop behaviors - string needs drop" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try drop.BuiltinDropBehaviors.register(&tracker);

    const behavior = tracker.getBehavior("String");
    try std.testing.expect(behavior == .Simple);
}

test "builtin drop behaviors - collections need drop" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try drop.BuiltinDropBehaviors.register(&tracker);

    try std.testing.expect(tracker.getBehavior("Array") == .Simple);
    try std.testing.expect(tracker.getBehavior("Vec") == .Simple);
    try std.testing.expect(tracker.getBehavior("HashMap") == .Simple);
}

test "builtin drop behaviors - smart pointers" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try drop.BuiltinDropBehaviors.register(&tracker);

    try std.testing.expect(tracker.getBehavior("Box") == .Simple);
    try std.testing.expect(tracker.getBehavior("Rc") == .Simple);
    try std.testing.expect(tracker.getBehavior("Arc") == .Simple);
}

test "builtin drop behaviors - sync primitives are complex" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try drop.BuiltinDropBehaviors.register(&tracker);

    try std.testing.expect(tracker.getBehavior("Mutex") == .Complex);
    try std.testing.expect(tracker.getBehavior("RwLock") == .Complex);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - empty scope" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.enterScope();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // Should work fine with no variables
    try std.testing.expect(!tracker.hasErrors());
}

test "edge case - all trivial types in scope" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Int", .Trivial);
    try tracker.enterScope();

    try tracker.registerVariable("a", "Int");
    try tracker.registerVariable("b", "Int");
    try tracker.registerVariable("c", "Int");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // No drops needed
    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 0);
}

test "edge case - circular dependency" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Node", .Simple);
    try tracker.registerVariable("a", "Node");
    try tracker.registerVariable("b", "Node");

    // Create circular dependency
    try tracker.addDependency("a", "b", "b depends on a");
    try tracker.addDependency("b", "a", "a depends on b");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Try to drop either one
    try tracker.dropVariable("a", loc);

    // Should detect violation
    try std.testing.expect(tracker.hasErrors());
}

test "stress test - many variables in scope" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.enterScope();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        try tracker.registerVariable(var_name, "String");
    }

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // All 100 should be dropped in reverse order
    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 100);
}

test "complex scenario - dependency chain" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Resource", .Simple);

    try tracker.registerVariable("a", "Resource");
    try tracker.registerVariable("b", "Resource");
    try tracker.registerVariable("c", "Resource");
    try tracker.registerVariable("d", "Resource");

    // Create chain: d -> c -> b -> a
    try tracker.addDependency("a", "b", "b depends on a");
    try tracker.addDependency("b", "c", "c depends on b");
    try tracker.addDependency("c", "d", "d depends on c");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Drop in correct order
    try tracker.dropVariable("a", loc);
    try tracker.dropVariable("b", loc);
    try tracker.dropVariable("c", loc);
    try tracker.dropVariable("d", loc);

    try std.testing.expect(!tracker.hasErrors());

    const drop_order = tracker.getDropOrder();
    try std.testing.expect(std.mem.eql(u8, drop_order[0], "a"));
    try std.testing.expect(std.mem.eql(u8, drop_order[1], "b"));
    try std.testing.expect(std.mem.eql(u8, drop_order[2], "c"));
    try std.testing.expect(std.mem.eql(u8, drop_order[3], "d"));
}

test "complex scenario - mixed trivial and non-trivial" {
    var tracker = drop.DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Int", .Trivial);
    try tracker.registerType("String", .Simple);

    try tracker.enterScope();

    try tracker.registerVariable("i1", "Int");
    try tracker.registerVariable("s1", "String");
    try tracker.registerVariable("i2", "Int");
    try tracker.registerVariable("s2", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.exitScope(loc);

    // Only strings should be dropped
    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 2);
}
