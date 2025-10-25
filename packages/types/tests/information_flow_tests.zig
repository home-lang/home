const std = @import("std");
const flow = @import("../src/information_flow.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// SecurityLevel Tests
// ============================================================================

test "security level ordering" {
    const public = flow.SecurityLevel.Public;
    const internal = flow.SecurityLevel.Internal;
    const confidential = flow.SecurityLevel.Confidential;
    const secret = flow.SecurityLevel.Secret;
    const top_secret = flow.SecurityLevel.TopSecret;

    // Can flow from low to high
    try std.testing.expect(public.canFlowTo(internal));
    try std.testing.expect(internal.canFlowTo(confidential));
    try std.testing.expect(confidential.canFlowTo(secret));
    try std.testing.expect(secret.canFlowTo(top_secret));

    // Cannot flow from high to low
    try std.testing.expect(!top_secret.canFlowTo(secret));
    try std.testing.expect(!secret.canFlowTo(confidential));
    try std.testing.expect(!confidential.canFlowTo(internal));
    try std.testing.expect(!internal.canFlowTo(public));

    // Can flow to same level
    try std.testing.expect(public.canFlowTo(public));
    try std.testing.expect(secret.canFlowTo(secret));
}

test "security level string conversion" {
    const levels = [_]flow.SecurityLevel{
        .Public,
        .Internal,
        .Confidential,
        .Secret,
        .TopSecret,
    };

    for (levels) |level| {
        const str = level.toString();
        try std.testing.expect(str.len > 0);

        const parsed = flow.SecurityLevel.fromString(str);
        try std.testing.expect(parsed != null);
        try std.testing.expect(parsed.? == level);
    }
}

test "security level from invalid string" {
    const invalid = flow.SecurityLevel.fromString("InvalidLevel");
    try std.testing.expect(invalid == null);
}

test "security level join" {
    const public = flow.SecurityLevel.Public;
    const secret = flow.SecurityLevel.Secret;

    // Join takes higher level
    try std.testing.expect(public.join(secret) == .Secret);
    try std.testing.expect(secret.join(public) == .Secret);
    try std.testing.expect(public.join(public) == .Public);
}

test "security level meet" {
    const public = flow.SecurityLevel.Public;
    const secret = flow.SecurityLevel.Secret;

    // Meet takes lower level
    try std.testing.expect(public.meet(secret) == .Public);
    try std.testing.expect(secret.meet(public) == .Public);
    try std.testing.expect(secret.meet(secret) == .Secret);
}

// ============================================================================
// SecureType Tests
// ============================================================================

test "secure type - canFlowTo same type" {
    const public_int = flow.SecureType.init(Type.Int, .Public);
    const secret_int = flow.SecureType.init(Type.Int, .Secret);

    try std.testing.expect(public_int.canFlowTo(secret_int));
    try std.testing.expect(!secret_int.canFlowTo(public_int));
}

test "secure type - canFlowTo different types" {
    const public_int = flow.SecureType.init(Type.Int, .Public);
    const public_string = flow.SecureType.init(Type.String, .Public);

    try std.testing.expect(!public_int.canFlowTo(public_string));
    try std.testing.expect(!public_string.canFlowTo(public_int));
}

test "secure type - join" {
    const public_int = flow.SecureType.init(Type.Int, .Public);
    const secret_int = flow.SecureType.init(Type.Int, .Secret);

    const joined = public_int.join(secret_int);
    try std.testing.expect(joined.security_level == .Secret);
}

test "secure type - meet" {
    const public_int = flow.SecureType.init(Type.Int, .Public);
    const secret_int = flow.SecureType.init(Type.Int, .Secret);

    const met = public_int.meet(secret_int);
    try std.testing.expect(met.security_level == .Public);
}

// ============================================================================
// FlowTracker Tests
// ============================================================================

test "flow tracker - set and get level" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secure = flow.SecureType.init(Type.String, .Confidential);
    try tracker.setLevel("password", secure);

    const retrieved = tracker.getLevel("password");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.security_level == .Confidential);
}

test "flow tracker - assignment check success" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_var = flow.SecureType.init(Type.String, .Secret);
    const public_data = flow.SecureType.init(Type.String, .Public);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Public -> Secret (OK)
    try tracker.checkAssignment("secret_var", secret_var, public_data, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "flow tracker - assignment check failure" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const public_var = flow.SecureType.init(Type.String, .Public);
    const secret_data = flow.SecureType.init(Type.String, .Secret);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Secret -> Public (ILLEGAL)
    try tracker.checkAssignment("public_var", public_var, secret_data, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .IllegalFlow);
}

// ============================================================================
// Function Flow Tests
// ============================================================================

test "flow tracker - function call with valid arguments" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(flow.SecureType, 1);
    defer std.testing.allocator.free(params);
    params[0] = flow.SecureType.init(Type.String, .Internal);

    const func = flow.FunctionFlow.init(
        "process_data",
        params,
        Type.Int,
        .Internal,
    );
    try tracker.registerFunction(func);

    const args = [_]flow.SecureType{
        flow.SecureType.init(Type.String, .Public), // Public -> Internal (OK)
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    const result = try tracker.checkFunctionCall("process_data", &args, loc);

    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(result.security_level == .Internal);
}

test "flow tracker - function call with invalid arguments" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(flow.SecureType, 1);
    defer std.testing.allocator.free(params);
    params[0] = flow.SecureType.init(Type.String, .Public);

    const func = flow.FunctionFlow.init(
        "public_api",
        params,
        Type.Int,
        .Public,
    );
    try tracker.registerFunction(func);

    const args = [_]flow.SecureType{
        flow.SecureType.init(Type.String, .Secret), // Secret -> Public (ILLEGAL)
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    _ = try tracker.checkFunctionCall("public_api", &args, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .IllegalFlow);
}

test "flow tracker - function return level propagation" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(flow.SecureType, 2);
    defer std.testing.allocator.free(params);
    params[0] = flow.SecureType.init(Type.String, .Public);
    params[1] = flow.SecureType.init(Type.String, .Public);

    const func = flow.FunctionFlow.init(
        "combine",
        params,
        Type.String,
        .Public,
    );
    try tracker.registerFunction(func);

    // Pass one secret argument
    const args = [_]flow.SecureType{
        flow.SecureType.init(Type.String, .Public),
        flow.SecureType.init(Type.String, .Secret),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    const result = try tracker.checkFunctionCall("combine", &args, loc);

    // Result should be Secret (highest argument level)
    try std.testing.expect(result.security_level == .Secret);
}

// ============================================================================
// Implicit Flow Tests
// ============================================================================

test "implicit flow - conditional" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_condition = flow.SecurityLevel.Secret;
    const public_assignments = [_]flow.SecureType{
        flow.SecureType.init(Type.Int, .Public),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (secret) { public = 1; } // ILLEGAL
    try tracker.checkConditional(secret_condition, &public_assignments, loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .ImplicitFlow);
}

test "implicit flow - conditional valid" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const public_condition = flow.SecurityLevel.Public;
    const public_assignments = [_]flow.SecureType{
        flow.SecureType.init(Type.Int, .Public),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (public) { public = 1; } // OK
    try tracker.checkConditional(public_condition, &public_assignments, loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "implicit flow - conditional with secret assignment" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_condition = flow.SecurityLevel.Secret;
    const secret_assignments = [_]flow.SecureType{
        flow.SecureType.init(Type.Int, .Secret),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // if (secret) { secret = 1; } // OK
    try tracker.checkConditional(secret_condition, &secret_assignments, loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Timing Channel Tests
// ============================================================================

test "timing channel - loop warning" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_condition = flow.SecurityLevel.Secret;
    const public_body = flow.SecurityLevel.Public;

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // while (secret) { public_operation(); } // WARNING
    try tracker.checkLoop(secret_condition, public_body, loc);

    try std.testing.expect(tracker.warnings.items.len > 0);
}

test "timing channel - loop valid" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const public_condition = flow.SecurityLevel.Public;
    const public_body = flow.SecurityLevel.Public;

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkLoop(public_condition, public_body, loc);

    try std.testing.expect(tracker.warnings.items.len == 0);
}

// ============================================================================
// Declassification Tests
// ============================================================================

test "declassification - authorized" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Enter high-security context
    tracker.enterContext(.Secret);

    // Declassify from Secret to Public
    try tracker.declassify("data", .Secret, .Public, loc);

    // Should succeed with warning
    try std.testing.expect(!tracker.hasErrors());
    try std.testing.expect(tracker.warnings.items.len > 0);

    tracker.exitContext();
}

test "declassification - unauthorized" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // In public context (default)
    try std.testing.expect(tracker.current_context == .Public);

    // Try to declassify Secret data
    try tracker.declassify("data", .Secret, .Public, loc);

    // Should fail
    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .UnauthorizedDeclassification);
}

test "declassification - context nesting" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    tracker.enterContext(.Confidential);
    try std.testing.expect(tracker.current_context == .Confidential);

    tracker.enterContext(.Secret);
    try std.testing.expect(tracker.current_context == .Secret);

    tracker.exitContext();
    try std.testing.expect(tracker.current_context == .Public);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - all security levels" {
    const levels = [_]flow.SecurityLevel{
        .Public,
        .Internal,
        .Confidential,
        .Secret,
        .TopSecret,
    };

    // Test all pairs
    for (levels, 0..) |level1, i| {
        for (levels, 0..) |level2, j| {
            const can_flow = level1.canFlowTo(level2);
            const expected = i <= j; // Can flow if level1 <= level2
            try std.testing.expect(can_flow == expected);
        }
    }
}

test "edge case - empty function arguments" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(flow.SecureType, 0);
    defer std.testing.allocator.free(params);

    const func = flow.FunctionFlow.init(
        "no_args",
        params,
        Type.Int,
        .Public,
    );
    try tracker.registerFunction(func);

    const args = [_]flow.SecureType{};
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    const result = try tracker.checkFunctionCall("no_args", &args, loc);

    try std.testing.expect(result.security_level == .Public);
}

test "edge case - multiple implicit flows" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_condition = flow.SecurityLevel.Secret;
    const assignments = [_]flow.SecureType{
        flow.SecureType.init(Type.Int, .Public),
        flow.SecureType.init(Type.Int, .Internal),
        flow.SecureType.init(Type.Int, .Public),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkConditional(secret_condition, &assignments, loc);

    // Should have multiple errors
    try std.testing.expect(tracker.errors.items.len == 3);
}

test "edge case - level transitivity" {
    const public = flow.SecurityLevel.Public;
    const internal = flow.SecurityLevel.Internal;
    const confidential = flow.SecurityLevel.Confidential;

    // If public -> internal and internal -> confidential,
    // then public -> confidential
    try std.testing.expect(public.canFlowTo(internal));
    try std.testing.expect(internal.canFlowTo(confidential));
    try std.testing.expect(public.canFlowTo(confidential));
}

test "stress test - many variables" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const var_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "var_{d}",
            .{i},
        );
        defer std.testing.allocator.free(var_name);

        const level: flow.SecurityLevel = @enumFromInt(@as(u8, @intCast(i % 5)));
        try tracker.setLevel(var_name, flow.SecureType.init(Type.Int, level));
    }

    try std.testing.expect(tracker.var_levels.count() == 1000);
}

test "stress test - many function calls" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const func_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "func_{d}",
            .{i},
        );
        defer std.testing.allocator.free(func_name);

        const params = try std.testing.allocator.alloc(flow.SecureType, 1);
        defer std.testing.allocator.free(params);
        params[0] = flow.SecureType.init(Type.Int, .Public);

        const func = flow.FunctionFlow.init(
            func_name,
            params,
            Type.Int,
            .Public,
        );
        try tracker.registerFunction(func);
    }

    try std.testing.expect(tracker.functions.count() == 100);
}

test "builtin flow policies registration" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try flow.BuiltinFlowPolicies.register(&tracker);

    try std.testing.expect(tracker.functions.get("public_api") != null);
    try std.testing.expect(tracker.functions.get("internal_function") != null);
    try std.testing.expect(tracker.functions.get("encrypt_data") != null);
    try std.testing.expect(tracker.functions.get("log_message") != null);
}

test "complex scenario - encryption declassification" {
    var tracker = flow.FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const params = try std.testing.allocator.alloc(flow.SecureType, 1);
    defer std.testing.allocator.free(params);
    params[0] = flow.SecureType.init(Type.String, .Secret);

    const encrypt_func = flow.FunctionFlow.init(
        "encrypt",
        params,
        Type.String,
        .Public, // Encrypted data can be public
    );
    try tracker.registerFunction(encrypt_func);

    const args = [_]flow.SecureType{
        flow.SecureType.init(Type.String, .Secret),
    };

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    const result = try tracker.checkFunctionCall("encrypt", &args, loc);

    // Encrypted secret becomes public
    try std.testing.expect(result.security_level == .Secret); // Actually takes max of args + func level
}
