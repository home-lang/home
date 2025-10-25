const std = @import("std");
const taint = @import("../src/taint_tracking.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// Basic Taint Level Tests
// ============================================================================

test "taint level ordering" {
    const trusted = taint.TaintLevel.Trusted;
    const user_input = taint.TaintLevel.UserInput;
    const network = taint.TaintLevel.Network;
    const filesystem = taint.TaintLevel.FileSystem;
    const database = taint.TaintLevel.Database;
    const untrusted = taint.TaintLevel.Untrusted;

    // Test complete ordering
    try std.testing.expect(trusted.canAssignTo(trusted));
    try std.testing.expect(trusted.canAssignTo(user_input));
    try std.testing.expect(trusted.canAssignTo(network));
    try std.testing.expect(trusted.canAssignTo(database));
    try std.testing.expect(trusted.canAssignTo(untrusted));

    // Reverse should fail
    try std.testing.expect(!untrusted.canAssignTo(trusted));
    try std.testing.expect(!database.canAssignTo(user_input));
    try std.testing.expect(!network.canAssignTo(trusted));
}

test "taint level string conversion" {
    const levels = [_]taint.TaintLevel{
        .Trusted,
        .UserInput,
        .Network,
        .FileSystem,
        .Database,
        .Untrusted,
    };

    for (levels) |level| {
        const str = level.toString();
        try std.testing.expect(str.len > 0);
    }
}

// ============================================================================
// Tainted Type Tests
// ============================================================================

test "tainted type assignment - same type, compatible taint" {
    const trusted_int = taint.TaintedType.init(Type.Int, .Trusted);
    const untrusted_int = taint.TaintedType.init(Type.Int, .Untrusted);

    try std.testing.expect(trusted_int.canAssignTo(untrusted_int));
    try std.testing.expect(!untrusted_int.canAssignTo(trusted_int));
}

test "tainted type assignment - different types" {
    const trusted_int = taint.TaintedType.init(Type.Int, .Trusted);
    const trusted_string = taint.TaintedType.init(Type.String, .Trusted);

    try std.testing.expect(!trusted_int.canAssignTo(trusted_string));
    try std.testing.expect(!trusted_string.canAssignTo(trusted_int));
}

test "tainted type merge - takes higher taint" {
    const trusted = taint.TaintedType.init(Type.Int, .Trusted);
    const user_input = taint.TaintedType.init(Type.Int, .UserInput);
    const untrusted = taint.TaintedType.init(Type.Int, .Untrusted);

    const merged1 = trusted.merge(user_input);
    try std.testing.expect(merged1.taint_level == .UserInput);

    const merged2 = user_input.merge(untrusted);
    try std.testing.expect(merged2.taint_level == .Untrusted);

    const merged3 = trusted.merge(untrusted);
    try std.testing.expect(merged3.taint_level == .Untrusted);
}

// ============================================================================
// Taint Tracker Tests
// ============================================================================

test "taint tracker - set and get taint" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const tainted = taint.TaintedType.init(Type.String, .UserInput);
    try tracker.setTaint("username", tainted);

    const retrieved = tracker.getTaint("username");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.taint_level == .UserInput);

    // Non-existent variable
    const none = tracker.getTaint("nonexistent");
    try std.testing.expect(none == null);
}

test "taint tracker - assignment check violations" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const public_var = taint.TaintedType.init(Type.String, .Trusted);
    const secret_data = taint.TaintedType.init(Type.String, .Untrusted);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Try to assign untrusted to trusted (should error)
    try tracker.checkAssignment("public_var", public_var, secret_data, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items.len == 1);
    try std.testing.expect(tracker.errors.items[0].kind == .TaintViolation);
}

test "taint tracker - assignment check success" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const untrusted_var = taint.TaintedType.init(Type.String, .Untrusted);
    const trusted_data = taint.TaintedType.init(Type.String, .Trusted);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Assign trusted to untrusted (OK)
    try tracker.checkAssignment("untrusted_var", untrusted_var, trusted_data, loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Sanitizer Tests
// ============================================================================

test "sanitizer registration and lookup" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const sanitizer_info = taint.SanitizerInfo.init(.Trusted);
    try tracker.registerSanitizer("sanitize_sql", sanitizer_info);

    const retrieved = tracker.sanitizers.get("sanitize_sql");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.output_taint == .Trusted);
}

test "sanitizer - removes taint" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerSanitizer("sanitize_sql", taint.SanitizerInfo.init(.Trusted));

    const untrusted_arg = taint.TaintedType.init(Type.String, .Untrusted);
    const args = [_]taint.TaintedType{untrusted_arg};
    const params = [_]taint.TaintedType{untrusted_arg}; // Sanitizer accepts any taint
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("sanitize_sql", &args, &params, loc);

    // Result should be trusted after sanitization
    try std.testing.expect(result.taint_level == .Trusted);
}

test "sanitizer - wrong argument count" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerSanitizer("sanitize_sql", taint.SanitizerInfo.init(.Trusted));

    const arg1 = taint.TaintedType.init(Type.String, .Untrusted);
    const arg2 = taint.TaintedType.init(Type.String, .Untrusted);
    const args = [_]taint.TaintedType{ arg1, arg2 };
    const params = [_]taint.TaintedType{arg1};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkFunctionCall("sanitize_sql", &args, &params, loc);

    try std.testing.expect(tracker.hasErrors());
}

// ============================================================================
// Dangerous Context Tests
// ============================================================================

test "dangerous context - sql query" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const untrusted_data = taint.TaintedType.init(Type.String, .Untrusted);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDangerousContext(.SqlQuery, untrusted_data, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .DangerousContext);
}

test "dangerous context - html output" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const network_data = taint.TaintedType.init(Type.String, .Network);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDangerousContext(.HtmlOutput, network_data, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "dangerous context - shell command" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const user_input = taint.TaintedType.init(Type.String, .UserInput);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDangerousContext(.ShellCommand, user_input, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "dangerous context - trusted data allowed" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const trusted_data = taint.TaintedType.init(Type.String, .Trusted);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDangerousContext(.SqlQuery, trusted_data, loc);
    try tracker.checkDangerousContext(.HtmlOutput, trusted_data, loc);
    try tracker.checkDangerousContext(.ShellCommand, trusted_data, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "dangerous context - all contexts" {
    const contexts = [_]taint.DangerousContext{
        .SqlQuery,
        .HtmlOutput,
        .ShellCommand,
        .FilePath,
        .CodeEval,
        .Serialization,
    };

    for (contexts) |ctx| {
        const required = ctx.requiredTaintLevel();
        try std.testing.expect(@intFromEnum(required) <= @intFromEnum(taint.TaintLevel.Database));
    }
}

// ============================================================================
// Function Call Tests
// ============================================================================

test "function call - taint propagation" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const untrusted_arg = taint.TaintedType.init(Type.String, .Untrusted);
    const trusted_arg = taint.TaintedType.init(Type.String, .Trusted);

    const args = [_]taint.TaintedType{ untrusted_arg, trusted_arg };
    const params = [_]taint.TaintedType{ untrusted_arg, trusted_arg };
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("some_func", &args, &params, loc);

    // Result should have highest taint level from arguments
    try std.testing.expect(result.taint_level == .Untrusted);
}

test "function call - parameter mismatch" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const untrusted_arg = taint.TaintedType.init(Type.String, .Untrusted);
    const trusted_param = taint.TaintedType.init(Type.String, .Trusted);

    const args = [_]taint.TaintedType{untrusted_arg};
    const params = [_]taint.TaintedType{trusted_param};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkFunctionCall("secure_func", &args, &params, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .TaintViolation);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - multiple assignments" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Set initial taint
    try tracker.setTaint("var", taint.TaintedType.init(Type.String, .Trusted));

    // Reassign with different taint
    try tracker.setTaint("var", taint.TaintedType.init(Type.String, .Untrusted));

    const current = tracker.getTaint("var");
    try std.testing.expect(current.?.taint_level == .Untrusted);

    _ = loc;
}

test "edge case - empty function arguments" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const args = [_]taint.TaintedType{};
    const params = [_]taint.TaintedType{};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("no_args_func", &args, &params, loc);

    // Should return trusted with no arguments
    try std.testing.expect(result.taint_level == .Trusted);
}

test "edge case - all taint levels in merge" {
    const trusted = taint.TaintedType.init(Type.Int, .Trusted);
    const user_input = taint.TaintedType.init(Type.Int, .UserInput);
    const network = taint.TaintedType.init(Type.Int, .Network);
    const filesystem = taint.TaintedType.init(Type.Int, .FileSystem);
    const database = taint.TaintedType.init(Type.Int, .Database);
    const untrusted = taint.TaintedType.init(Type.Int, .Untrusted);

    // Merge should always take highest taint
    var current = trusted;
    current = current.merge(user_input);
    try std.testing.expect(current.taint_level == .UserInput);

    current = current.merge(network);
    try std.testing.expect(current.taint_level == .Network);

    current = current.merge(filesystem);
    try std.testing.expect(current.taint_level == .FileSystem);

    current = current.merge(database);
    try std.testing.expect(current.taint_level == .Database);

    current = current.merge(untrusted);
    try std.testing.expect(current.taint_level == .Untrusted);
}

test "edge case - sanitizer chain" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Register multiple sanitizers
    try tracker.registerSanitizer("sanitize1", taint.SanitizerInfo.init(.Database));
    try tracker.registerSanitizer("sanitize2", taint.SanitizerInfo.init(.Trusted));

    const untrusted = taint.TaintedType.init(Type.String, .Untrusted);
    const args1 = [_]taint.TaintedType{untrusted};
    const params = [_]taint.TaintedType{untrusted};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // First sanitization: Untrusted -> Database
    const result1 = try tracker.checkFunctionCall("sanitize1", &args1, &params, loc);
    try std.testing.expect(result1.taint_level == .Database);

    // Second sanitization: Database -> Trusted
    const args2 = [_]taint.TaintedType{result1};
    const result2 = try tracker.checkFunctionCall("sanitize2", &args2, &params, loc);
    try std.testing.expect(result2.taint_level == .Trusted);
}

test "stress test - many variables" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Create many tainted variables
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        const level: taint.TaintLevel = @enumFromInt(@as(u8, @intCast(i % 6)));
        try tracker.setTaint(var_name, taint.TaintedType.init(Type.Int, level));
    }

    try std.testing.expect(tracker.taint_map.count() == 1000);
}

test "builtin sanitizers registration" {
    var tracker = taint.TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try taint.BuiltinSanitizers.register(&tracker);

    // Check all built-in sanitizers are registered
    try std.testing.expect(tracker.sanitizers.get("sanitize_sql") != null);
    try std.testing.expect(tracker.sanitizers.get("escape_html") != null);
    try std.testing.expect(tracker.sanitizers.get("sanitize_shell") != null);
    try std.testing.expect(tracker.sanitizers.get("sanitize_path") != null);
    try std.testing.expect(tracker.sanitizers.get("validate_int") != null);
    try std.testing.expect(tracker.sanitizers.get("validate_string") != null);
    try std.testing.expect(tracker.sanitizers.get("validate_email") != null);
}
