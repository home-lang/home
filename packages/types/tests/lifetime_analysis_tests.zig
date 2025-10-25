const std = @import("std");
const lifetime = @import("../src/lifetime_analysis.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// Lifetime Tests
// ============================================================================

test "lifetime - initialization" {
    const lt = lifetime.Lifetime.init("outer", 1);

    try std.testing.expect(std.mem.eql(u8, lt.name, "outer"));
    try std.testing.expect(lt.scope_id == 1);
}

test "lifetime - static" {
    const lt = lifetime.Lifetime.static();

    try std.testing.expect(std.mem.eql(u8, lt.name, "static"));
    try std.testing.expect(lt.scope_id == 0);
}

test "lifetime - equals" {
    const lt1 = lifetime.Lifetime.init("a", 1);
    const lt2 = lifetime.Lifetime.init("a", 1);
    const lt3 = lifetime.Lifetime.init("b", 1);
    const lt4 = lifetime.Lifetime.init("a", 2);

    try std.testing.expect(lt1.equals(lt2));
    try std.testing.expect(!lt1.equals(lt3));
    try std.testing.expect(!lt1.equals(lt4));
}

test "lifetime - outlives same scope" {
    const outer = lifetime.Lifetime.init("outer", 1);
    const same = lifetime.Lifetime.init("same", 1);

    try std.testing.expect(outer.outlives(same));
    try std.testing.expect(same.outlives(outer));
}

test "lifetime - outlives different scopes" {
    const outer = lifetime.Lifetime.init("outer", 1);
    const inner = lifetime.Lifetime.init("inner", 2);

    try std.testing.expect(outer.outlives(inner));
    try std.testing.expect(!inner.outlives(outer));
}

test "lifetime - static outlives everything" {
    const static_lt = lifetime.Lifetime.static();
    const any_lt = lifetime.Lifetime.init("any", 999);

    try std.testing.expect(static_lt.outlives(any_lt));
    try std.testing.expect(!any_lt.outlives(static_lt));
}

// ============================================================================
// TypeWithLifetime Tests
// ============================================================================

test "type with lifetime - init" {
    const lt = lifetime.Lifetime.init("a", 1);
    const typed = lifetime.TypeWithLifetime.init(Type.Int, lt);

    try std.testing.expect(typed.base_type == Type.Int);
    try std.testing.expect(typed.lifetime.scope_id == 1);
    try std.testing.expect(!typed.is_reference);
    try std.testing.expect(!typed.is_mutable);
}

test "type with lifetime - reference" {
    const lt = lifetime.Lifetime.init("a", 1);
    const ref = lifetime.TypeWithLifetime.reference(Type.String, lt);

    try std.testing.expect(ref.is_reference);
    try std.testing.expect(!ref.is_mutable);
}

test "type with lifetime - mutable reference" {
    const lt = lifetime.Lifetime.init("a", 1);
    const mut_ref = lifetime.TypeWithLifetime.mutableReference(Type.String, lt);

    try std.testing.expect(mut_ref.is_reference);
    try std.testing.expect(mut_ref.is_mutable);
}

test "type with lifetime - owned" {
    const owned = lifetime.TypeWithLifetime.owned(Type.String);

    try std.testing.expect(!owned.is_reference);
    try std.testing.expect(owned.is_mutable);
    try std.testing.expect(owned.lifetime.scope_id == 0); // static
}

// ============================================================================
// LifetimeConstraint Tests
// ============================================================================

test "lifetime constraint - valid" {
    const longer = lifetime.Lifetime.init("outer", 1);
    const shorter = lifetime.Lifetime.init("inner", 2);

    const constraint = lifetime.LifetimeConstraint.init(longer, shorter);
    try std.testing.expect(constraint.check());
}

test "lifetime constraint - invalid" {
    const shorter = lifetime.Lifetime.init("inner", 2);
    const longer = lifetime.Lifetime.init("outer", 1);

    const constraint = lifetime.LifetimeConstraint.init(shorter, longer);
    try std.testing.expect(!constraint.check());
}

// ============================================================================
// OwnershipState Tests
// ============================================================================

test "ownership state - owned can use and move" {
    const owned = lifetime.OwnershipState.Owned;

    try std.testing.expect(owned.canUse());
    try std.testing.expect(owned.canMove());
    try std.testing.expect(owned.canBorrow());
    try std.testing.expect(owned.canBorrowMut());
}

test "ownership state - borrowed can use and borrow" {
    const borrowed = lifetime.OwnershipState.Borrowed;

    try std.testing.expect(borrowed.canUse());
    try std.testing.expect(!borrowed.canMove());
    try std.testing.expect(borrowed.canBorrow());
    try std.testing.expect(!borrowed.canBorrowMut());
}

test "ownership state - moved cannot use" {
    const moved = lifetime.OwnershipState.Moved;

    try std.testing.expect(!moved.canUse());
    try std.testing.expect(!moved.canMove());
    try std.testing.expect(!moved.canBorrow());
}

test "ownership state - dropped cannot use" {
    const dropped = lifetime.OwnershipState.Dropped;

    try std.testing.expect(!dropped.canUse());
    try std.testing.expect(!dropped.canMove());
}

// ============================================================================
// LifetimeTracker Tests
// ============================================================================

test "lifetime tracker - initialization" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.scope_depth == 0);
    try std.testing.expect(tracker.next_scope_id == 1);
}

test "lifetime tracker - enter scope" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try std.testing.expect(scope1 == 1);
    try std.testing.expect(tracker.scope_depth == 1);

    const scope2 = tracker.enterScope();
    try std.testing.expect(scope2 == 2);
    try std.testing.expect(tracker.scope_depth == 2);
}

test "lifetime tracker - exit scope" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try std.testing.expect(tracker.scope_depth == 1);

    try tracker.exitScope(scope_id);
    try std.testing.expect(tracker.scope_depth == 0);
}

test "lifetime tracker - declare owned" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const state = tracker.var_ownership.get("x");
    try std.testing.expect(state.? == .Owned);
}

// ============================================================================
// Borrow Tests
// ============================================================================

test "lifetime tracker - create borrow" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.createBorrow("r", "x", scope_id, loc);

    const state = tracker.var_ownership.get("r");
    try std.testing.expect(state.? == .Borrowed);
}

test "lifetime tracker - borrow from undefined" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.createBorrow("r", "undefined", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseOfUndefined);
}

test "lifetime tracker - borrow from moved" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    // Move x
    try tracker.var_ownership.put("x", .Moved);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.createBorrow("r", "x", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .CannotBorrow);
}

test "lifetime tracker - create mutable borrow" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.createBorrowMut("r", "x", scope_id, loc);

    const state = tracker.var_ownership.get("r");
    try std.testing.expect(state.? == .BorrowedMut);
}

test "lifetime tracker - conflicting mutable borrows" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create first mutable borrow
    try tracker.createBorrowMut("r1", "x", scope_id, loc);

    // Try to create second mutable borrow
    try tracker.createBorrowMut("r2", "x", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .ConflictingBorrow);
}

test "lifetime tracker - shared and mutable borrow conflict" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create mutable borrow
    try tracker.createBorrowMut("r1", "x", scope_id, loc);

    // Try to create shared borrow
    try tracker.createBorrow("r2", "x", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .ConflictingBorrow);
}

test "lifetime tracker - multiple shared borrows allowed" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create multiple shared borrows
    try tracker.createBorrow("r1", "x", scope_id, loc);
    try tracker.createBorrow("r2", "x", scope_id, loc);
    try tracker.createBorrow("r3", "x", scope_id, loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Move Tests
// ============================================================================

test "lifetime tracker - move value" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveValue("x", "y", scope_id, loc);

    const x_state = tracker.var_ownership.get("x");
    const y_state = tracker.var_ownership.get("y");

    try std.testing.expect(x_state.? == .Moved);
    try std.testing.expect(y_state.? == .Owned);
}

test "lifetime tracker - move from undefined" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.moveValue("undefined", "y", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseOfUndefined);
}

test "lifetime tracker - move from already moved" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move once
    try tracker.moveValue("x", "y", scope_id, loc);

    // Try to move again
    try tracker.moveValue("x", "z", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseAfterMove);
}

// ============================================================================
// Use Checking Tests
// ============================================================================

test "lifetime tracker - check use of owned" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkUse("x", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "lifetime tracker - check use of moved" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.moveValue("x", "y", scope_id, loc);

    // Try to use moved value
    try tracker.checkUse("x", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseAfterMove);
}

test "lifetime tracker - check use of undefined" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkUse("undefined", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UseOfUndefined);
}

test "lifetime tracker - check use of borrowed" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.createBorrow("r", "x", scope_id, loc);

    try tracker.checkUse("r", loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Dangling Reference Tests
// ============================================================================

test "lifetime tracker - dangling reference detection" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const scope2 = tracker.enterScope();
    try tracker.declareOwned("y", scope2);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create borrow from inner scope variable in outer scope
    try tracker.createBorrow("r", "y", scope1, loc);

    // Exit inner scope (y goes out of scope)
    try tracker.exitScope(scope2);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DanglingReference);
}

test "lifetime tracker - no dangling reference" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const scope2 = tracker.enterScope();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create borrow from outer scope variable in inner scope
    try tracker.createBorrow("r", "x", scope2, loc);

    // Exit inner scope (r goes out of scope, but x is still alive)
    try tracker.exitScope(scope2);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Constraint Checking Tests
// ============================================================================

test "lifetime tracker - check constraints valid" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.createBorrow("r", "x", scope1, loc);

    try tracker.checkConstraints();

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - nested scopes" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    const scope2 = tracker.enterScope();
    const scope3 = tracker.enterScope();

    try std.testing.expect(tracker.scope_depth == 3);

    try tracker.exitScope(scope3);
    try std.testing.expect(tracker.scope_depth == 2);

    try tracker.exitScope(scope2);
    try std.testing.expect(tracker.scope_depth == 1);

    try tracker.exitScope(scope1);
    try std.testing.expect(tracker.scope_depth == 0);
}

test "edge case - borrow of borrow" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create first borrow
    try tracker.createBorrow("r1", "x", scope_id, loc);

    // Try to borrow the borrow (should fail - borrowed can't be borrowed mutably)
    try tracker.createBorrowMut("r2", "r1", scope_id, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "edge case - move after borrow ends" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const scope2 = tracker.enterScope();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create borrow in inner scope
    try tracker.createBorrow("r", "x", scope2, loc);

    // Exit inner scope (borrow ends)
    try tracker.exitScope(scope2);

    // Now move should be OK
    try tracker.moveValue("x", "y", scope1, loc);

    // Should have no errors about the move (but might have dangling ref error from exit)
    var has_move_error = false;
    for (tracker.errors.items) |err| {
        if (err.kind == .UseAfterMove and std.mem.eql(u8, err.variable_name, "x")) {
            has_move_error = true;
        }
    }
    try std.testing.expect(!has_move_error);
}

test "stress test - many variables" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        try tracker.declareOwned(var_name, scope_id);
    }

    try std.testing.expect(tracker.var_ownership.count() == 100);
}

test "stress test - many borrows" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope_id = tracker.enterScope();
    try tracker.declareOwned("x", scope_id);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create many shared borrows
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const borrow_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "r_{d}",
            .{i},
        );
        defer std.testing.allocator.free(borrow_name);

        try tracker.createBorrow(borrow_name, "x", scope_id, loc);
    }

    try std.testing.expect(!tracker.hasErrors());
}

test "complex scenario - reborrow pattern" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create first scope with borrow
    const scope2 = tracker.enterScope();
    try tracker.createBorrow("r1", "x", scope2, loc);

    // Use borrow
    try tracker.checkUse("r1", loc);

    // Exit scope (r1 dies)
    try tracker.exitScope(scope2);

    // Create new scope with different borrow
    const scope3 = tracker.enterScope();
    try tracker.createBorrow("r2", "x", scope3, loc);

    try tracker.checkUse("r2", loc);

    // Should work fine
    try std.testing.expect(!tracker.hasErrors());
}

test "complex scenario - conditional ownership" {
    var tracker = lifetime.LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (condition) { move x to y }
    const scope2 = tracker.enterScope();
    try tracker.moveValue("x", "y", scope2, loc);
    try tracker.exitScope(scope2);

    // After conditional, x is moved
    try tracker.checkUse("x", loc);

    try std.testing.expect(tracker.hasErrors());
}
