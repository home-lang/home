const std = @import("std");
const null_safety = @import("../src/null_safety.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// Nullability Tests
// ============================================================================

test "nullability merge - both non-null" {
    const non_null = null_safety.Nullability.NonNull;
    const result = non_null.merge(non_null);
    try std.testing.expect(result == .NonNull);
}

test "nullability merge - both null" {
    const null_val = null_safety.Nullability.Null;
    const result = null_val.merge(null_val);
    try std.testing.expect(result == .Null);
}

test "nullability merge - mixed" {
    const non_null = null_safety.Nullability.NonNull;
    const nullable = null_safety.Nullability.Nullable;

    const result1 = non_null.merge(nullable);
    try std.testing.expect(result1 == .Nullable);

    const result2 = nullable.merge(non_null);
    try std.testing.expect(result2 == .Nullable);
}

test "nullability merge - with unknown" {
    const non_null = null_safety.Nullability.NonNull;
    const unknown = null_safety.Nullability.Unknown;

    const result = non_null.merge(unknown);
    try std.testing.expect(result == .Nullable);
}

test "nullability can dereference" {
    const non_null = null_safety.Nullability.NonNull;
    const nullable = null_safety.Nullability.Nullable;
    const null_val = null_safety.Nullability.Null;
    const unknown = null_safety.Nullability.Unknown;

    try std.testing.expect(non_null.canDereference());
    try std.testing.expect(!nullable.canDereference());
    try std.testing.expect(!null_val.canDereference());
    try std.testing.expect(!unknown.canDereference());
}

test "nullability string conversion" {
    const states = [_]null_safety.Nullability{
        .NonNull,
        .Nullable,
        .Null,
        .Unknown,
    };

    for (states) |state| {
        const str = state.toString();
        try std.testing.expect(str.len > 0);
    }
}

// ============================================================================
// NullableType Tests
// ============================================================================

test "nullable type - nonNull constructor" {
    const non_null_int = null_safety.NullableType.nonNull(Type.Int);

    try std.testing.expect(non_null_int.base_type == Type.Int);
    try std.testing.expect(non_null_int.nullability == .NonNull);
    try std.testing.expect(non_null_int.canDereference());
}

test "nullable type - nullable constructor" {
    const nullable_string = null_safety.NullableType.nullable(Type.String);

    try std.testing.expect(nullable_string.base_type == Type.String);
    try std.testing.expect(nullable_string.nullability == .Nullable);
    try std.testing.expect(!nullable_string.canDereference());
}

// ============================================================================
// NullSafetyTracker Tests
// ============================================================================

test "null safety tracker - set and get nullability" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const nullability = tracker.getNullability("ptr");
    try std.testing.expect(nullability == .Nullable);
}

test "null safety tracker - unknown variable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const nullability = tracker.getNullability("unknown");
    try std.testing.expect(nullability == .Unknown);
}

test "null safety tracker - safe dereference" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .NonNull);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "null safety tracker - unsafe dereference" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UnsafeDereference);
}

test "null safety tracker - dereference null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Null);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Null Check Tracking Tests
// ============================================================================

test "null check - enables safe dereference" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);
    try tracker.recordNullCheck("ptr");

    const nullability = tracker.getNullability("ptr");
    try std.testing.expect(nullability == .NonNull);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "null check - multiple variables" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr1", .Nullable);
    try tracker.setNullability("ptr2", .Nullable);

    try tracker.recordNullCheck("ptr1");

    try std.testing.expect(tracker.getNullability("ptr1") == .NonNull);
    try std.testing.expect(tracker.getNullability("ptr2") == .Nullable);
}

// ============================================================================
// Assignment Tests
// ============================================================================

test "assignment - non-null to non-null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("var", .NonNull, .NonNull, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "assignment - nullable to non-null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("var", .NonNull, .Nullable, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .NullableToNonNull);
}

test "assignment - non-null to nullable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("var", .Nullable, .NonNull, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "assignment - nullable to nullable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("var", .Nullable, .Nullable, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "assignment - updates nullability" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("var", .NonNull);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAssignment("var", .Nullable, .Nullable, loc);

    // Should update to nullable
    const new_nullability = tracker.getNullability("var");
    try std.testing.expect(new_nullability == .Nullable);
}

// ============================================================================
// Scope Management Tests
// ============================================================================

test "scope - enter and exit" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.scope_depth == 0);

    tracker.enterScope();
    try std.testing.expect(tracker.scope_depth == 1);

    tracker.exitScope();
    try std.testing.expect(tracker.scope_depth == 0);
}

test "scope - clears null checks on exit" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    tracker.enterScope();
    try tracker.recordNullCheck("ptr");
    try std.testing.expect(tracker.checked_vars.count() > 0);

    tracker.exitScope();

    // Null checks should be cleared
    try std.testing.expect(tracker.checked_vars.count() == 0);
}

test "scope - nested scopes" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.enterScope(); // depth = 1
    tracker.enterScope(); // depth = 2
    tracker.enterScope(); // depth = 3

    try std.testing.expect(tracker.scope_depth == 3);

    tracker.exitScope();
    try std.testing.expect(tracker.scope_depth == 2);

    tracker.exitScope();
    try std.testing.expect(tracker.scope_depth == 1);

    tracker.exitScope();
    try std.testing.expect(tracker.scope_depth == 0);
}

// ============================================================================
// Function Call Tests
// ============================================================================

test "function call - non-null arguments" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(null_safety.Nullability, 2);
    defer std.testing.allocator.free(params);
    params[0] = .NonNull;
    params[1] = .NonNull;

    const func = null_safety.FunctionSignature.init(
        "process",
        params,
        Type.Int,
        .NonNull,
    );
    try tracker.registerFunction(func);

    const args = [_]null_safety.Nullability{ .NonNull, .NonNull };
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("process", &args, loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(result.nullability == .NonNull);
}

test "function call - nullable argument to non-null parameter" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(null_safety.Nullability, 1);
    defer std.testing.allocator.free(params);
    params[0] = .NonNull;

    const func = null_safety.FunctionSignature.init(
        "requires_non_null",
        params,
        Type.Int,
        .NonNull,
    );
    try tracker.registerFunction(func);

    const args = [_]null_safety.Nullability{.Nullable};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkFunctionCall("requires_non_null", &args, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .NullableArgument);
}

test "function call - nullable parameter accepts non-null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(null_safety.Nullability, 1);
    defer std.testing.allocator.free(params);
    params[0] = .Nullable;

    const func = null_safety.FunctionSignature.init(
        "accepts_nullable",
        params,
        Type.Int,
        .NonNull,
    );
    try tracker.registerFunction(func);

    const args = [_]null_safety.Nullability{.NonNull};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("accepts_nullable", &args, loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(result.nullability == .NonNull);
}

test "function call - unknown function" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const args = [_]null_safety.Nullability{.NonNull};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("unknown_func", &args, loc);

    // Should not error, assumes non-null
    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(result.nullability == .NonNull);
}

// ============================================================================
// Return Statement Tests
// ============================================================================

test "return - non-null to non-null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkReturn(.NonNull, .NonNull, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "return - nullable to non-null" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkReturn(.Nullable, .NonNull, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .NullableReturn);
}

test "return - non-null to nullable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkReturn(.NonNull, .Nullable, loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Redundant Check Warning Tests
// ============================================================================

test "redundant check - non-null variable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .NonNull);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.warnRedundantCheck("ptr", loc);

    try std.testing.expect(tracker.warnings.items.len > 0);
}

test "redundant check - nullable variable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.warnRedundantCheck("ptr", loc);

    // Should not warn
    try std.testing.expect(tracker.warnings.items.len == 0);
}

// ============================================================================
// NullSafeConstructors Tests
// ============================================================================

test "null safe constructors - unwrap success" {
    const value: ?i32 = 42;
    const result = null_safety.NullSafeConstructors.unwrap(i32, value);
    try std.testing.expect(result == 42);
}

test "null safe constructors - orDefault with value" {
    const value: ?i32 = 42;
    const result = null_safety.NullSafeConstructors.orDefault(i32, value, 100);
    try std.testing.expect(result == 42);
}

test "null safe constructors - orDefault with null" {
    const value: ?i32 = null;
    const result = null_safety.NullSafeConstructors.orDefault(i32, value, 100);
    try std.testing.expect(result == 100);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - multiple assignments to same variable" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Start as non-null
    try tracker.checkAssignment("var", .NonNull, .NonNull, loc);
    try std.testing.expect(tracker.getNullability("var") == .NonNull);

    // Assign nullable
    try tracker.checkAssignment("var", .Nullable, .Nullable, loc);
    try std.testing.expect(tracker.getNullability("var") == .Nullable);

    // Assign non-null again
    try tracker.checkAssignment("var", .Nullable, .NonNull, loc);
    try std.testing.expect(tracker.getNullability("var") == .NonNull);
}

test "edge case - null check then reassign" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);
    try tracker.recordNullCheck("ptr");
    try std.testing.expect(tracker.getNullability("ptr") == .NonNull);

    // Reassign to nullable
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAssignment("ptr", .Nullable, .Nullable, loc);

    // Should be nullable again
    try std.testing.expect(tracker.getNullability("ptr") == .Nullable);
}

test "stress test - many variables" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        const nullability: null_safety.Nullability = if (i % 2 == 0) .NonNull else .Nullable;
        try tracker.setNullability(var_name, nullability);
    }

    try std.testing.expect(tracker.var_nullability.count() == 1000);
}

test "builtin nullable functions registration" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try null_safety.BuiltinNullableFunctions.register(&tracker);

    try std.testing.expect(tracker.functions.get("string_length") != null);
    try std.testing.expect(tracker.functions.get("is_null") != null);
    try std.testing.expect(tracker.functions.get("unwrap_or") != null);
}

test "complex scenario - conditional null check" {
    var tracker = null_safety.NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (ptr != null) { use(ptr); }
    tracker.enterScope();
    try tracker.recordNullCheck("ptr");
    try tracker.checkDereference("ptr", loc);
    tracker.exitScope();

    try std.testing.expect(!tracker.hasErrors());
}
