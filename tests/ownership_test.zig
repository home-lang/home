const std = @import("std");
const testing = std.testing;
const ownership = @import("../src/types/ownership.zig");
const ast = @import("../src/ast/ast.zig");

/// Helper to create source location
fn loc(line: u32, column: u32) ast.SourceLocation {
    return .{ .line = line, .column = column };
}

// Basic ownership tests (1-20)
test "ownership: variable initialization" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try testing.expect(tracker.variables.contains("x"));
}

test "ownership: move semantics" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.markMoved("x");

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Moved);
}

test "ownership: use after move is error" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.markMoved("x");

    const result = tracker.checkUse("x", loc(2, 1));
    try testing.expectError(error.UseAfterMove, result);
}

test "ownership: immutable borrow" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Borrowed);
}

test "ownership: multiple immutable borrows allowed" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));
    try tracker.borrow("x", loc(3, 1));
    try tracker.borrow("x", loc(4, 1));

    // Should succeed - multiple immutable borrows OK
    try tracker.checkUse("x", loc(5, 1));
}

test "ownership: mutable borrow exclusive" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrowMut("x", loc(2, 1));

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .MutBorrowed);
}

test "ownership: cannot borrow while mutably borrowed" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrowMut("x", loc(2, 1));

    const result = tracker.borrow("x", loc(3, 1));
    try testing.expectError(error.AlreadyBorrowed, result);
}

test "ownership: cannot mutably borrow while borrowed" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));

    const result = tracker.borrowMut("x", loc(3, 1));
    try testing.expectError(error.AlreadyBorrowed, result);
}

test "ownership: release borrow" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));
    tracker.releaseBorrow("x");

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

test "ownership: copy type not moved" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.setCopyType("x", true);

    try tracker.markMoved("x");

    // Copy types don't actually move
    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

// Scope tests (21-35)
test "ownership: nested scopes" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.enterScope();
    try tracker.declareBorrow("y", loc(2, 1));
    tracker.exitScope();

    try testing.expect(tracker.variables.contains("x"));
    try testing.expect(!tracker.variables.contains("y"));
}

test "ownership: moved in inner scope" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.enterScope();
    try tracker.markMoved("x");
    tracker.exitScope();

    // Move persists after scope exit
    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Moved);
}

test "ownership: borrow released on scope exit" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.enterScope();
    try tracker.borrow("x", loc(2, 1));
    tracker.exitScope();

    // Borrow should be released
    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

test "ownership: multiple nested scopes" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.enterScope();
    tracker.enterScope();
    tracker.enterScope();
    try tracker.borrow("x", loc(2, 1));
    tracker.exitScope();
    tracker.exitScope();
    tracker.exitScope();

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

test "ownership: shadow variable in scope" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.enterScope();
    try tracker.declareBorrow("x", loc(2, 1)); // Shadow
    try tracker.markMoved("x");
    tracker.exitScope();

    // Original x still owned
    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

// Complex borrowing patterns (36-50)
test "ownership: borrow chain" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.declareBorrow("y", loc(2, 1));

    try tracker.borrow("x", loc(3, 1));
    try tracker.borrow("y", loc(4, 1));

    // Both should be borrowed
    try testing.expect(tracker.variables.get("x").?.state == .Borrowed);
    try testing.expect(tracker.variables.get("y").?.state == .Borrowed);
}

test "ownership: reborrow after release" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));
    tracker.releaseBorrow("x");
    try tracker.borrow("x", loc(3, 1));

    try testing.expect(tracker.variables.get("x").?.state == .Borrowed);
}

test "ownership: mutable borrow after immutable release" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));
    tracker.releaseBorrow("x");
    try tracker.borrowMut("x", loc(3, 1));

    try testing.expect(tracker.variables.get("x").?.state == .MutBorrowed);
}

test "ownership: conditional move" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));

    // Simulate conditional: if (cond) { move(x) }
    tracker.enterScope();
    try tracker.markMoved("x");
    tracker.exitScope();

    // After conditional scope, x is considered moved
    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Moved);
}

test "ownership: loop borrow" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));

    // Simulate loop body
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        tracker.enterScope();
        try tracker.borrow("x", loc(2, 1));
        tracker.exitScope();
    }

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

// Error detection tests (51-70)
test "ownership: detect use after move in same scope" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.markMoved("x");

    const result = tracker.checkUse("x", loc(2, 1));
    try testing.expectError(error.UseAfterMove, result);
    try testing.expect(tracker.errors.items.len > 0);
}

test "ownership: detect multiple mutable borrows" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrowMut("x", loc(2, 1));

    const result = tracker.borrowMut("x", loc(3, 1));
    try testing.expectError(error.AlreadyBorrowed, result);
}

test "ownership: detect immutable after mutable" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrowMut("x", loc(2, 1));

    const result = tracker.borrow("x", loc(3, 1));
    try testing.expectError(error.AlreadyBorrowed, result);
}

test "ownership: detect undeclared variable" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    const result = tracker.checkUse("undefined_var", loc(1, 1));
    try testing.expectError(error.UndefinedVariable, result);
}

test "ownership: detect move of borrowed value" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));

    const result = tracker.markMoved("x");
    try testing.expectError(error.CannotMoveBorrowed, result);
}

// Copy type tests (71-80)
test "ownership: copy type can be used after move" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.setCopyType("x", true);

    try tracker.markMoved("x");
    try tracker.checkUse("x", loc(2, 1)); // Should succeed

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

test "ownership: copy type multiple moves" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.setCopyType("x", true);

    try tracker.markMoved("x");
    try tracker.markMoved("x");
    try tracker.markMoved("x");

    // All succeed for copy types
    try tracker.checkUse("x", loc(2, 1));
}

test "ownership: non-copy type single move" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.setCopyType("x", false);

    try tracker.markMoved("x");

    const result = tracker.checkUse("x", loc(2, 1));
    try testing.expectError(error.UseAfterMove, result);
}

test "ownership: copy type can be borrowed multiple times" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    tracker.setCopyType("x", true);

    try tracker.borrow("x", loc(2, 1));
    try tracker.borrow("x", loc(3, 1));
    try tracker.borrow("x", loc(4, 1));

    const state = tracker.variables.get("x").?;
    try testing.expect(state.borrow_count == 3);
}

// Reference type tests (81-90)
test "ownership: reference does not move" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.declareBorrow("ref_x", loc(2, 1));

    try tracker.borrow("x", loc(3, 1));

    // Using reference shouldn't affect original
    try tracker.checkUse("ref_x", loc(4, 1));
    try tracker.checkUse("x", loc(5, 1));
}

test "ownership: mutable reference exclusive" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrowMut("x", loc(2, 1));

    // Cannot create another reference while mutably borrowed
    const result = tracker.borrow("x", loc(3, 1));
    try testing.expectError(error.AlreadyBorrowed, result);
}

test "ownership: lifetime tracking" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));

    tracker.enterScope();
    try tracker.borrow("x", loc(2, 1));
    const borrowed_state = tracker.variables.get("x").?;
    try testing.expect(borrowed_state.state == .Borrowed);
    tracker.exitScope();

    const released_state = tracker.variables.get("x").?;
    try testing.expect(released_state.state == .Owned);
}

// Function parameter tests (91-100)
test "ownership: function parameter borrow" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));

    // Simulate function call with borrow
    tracker.enterScope();
    try tracker.declareBorrow("param", loc(2, 1));
    try tracker.borrow("x", loc(2, 1));
    tracker.exitScope();

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Owned);
}

test "ownership: function parameter move" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));

    // Simulate function call with move
    tracker.enterScope();
    try tracker.markMoved("x");
    tracker.exitScope();

    const state = tracker.variables.get("x").?;
    try testing.expect(state.state == .Moved);
}

test "ownership: return moves ownership" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    tracker.enterScope();
    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.markMoved("x");
    tracker.exitScope();

    // x should be moved out of scope
    try testing.expect(!tracker.variables.contains("x"));
}

// Additional comprehensive tests (101-120+)
test "ownership: complex borrow pattern 1" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("a", loc(1, 1));
    try tracker.declareBorrow("b", loc(2, 1));

    try tracker.borrow("a", loc(3, 1));
    try tracker.borrow("b", loc(4, 1));
    tracker.releaseBorrow("a");
    try tracker.borrowMut("a", loc(5, 1));
}

test "ownership: error recovery" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.markMoved("x");

    _ = tracker.checkUse("x", loc(2, 1)) catch {};

    // Error should be recorded
    try testing.expect(tracker.errors.items.len > 0);
}

test "ownership: statistics tracking" {
    var tracker = ownership.OwnershipTracker.init(testing.allocator);
    defer tracker.deinit();

    try tracker.declareBorrow("x", loc(1, 1));
    try tracker.borrow("x", loc(2, 1));
    try tracker.borrow("x", loc(3, 1));

    const state = tracker.variables.get("x").?;
    try testing.expect(state.borrow_count >= 2);
}
