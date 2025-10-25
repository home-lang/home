const std = @import("std");
const cap = @import("../src/capability_types.zig");
const Type = @import("../src/type_system.zig").Type;
const ast = @import("ast");

// ============================================================================
// Capability Basic Tests
// ============================================================================

test "capability string conversion" {
    const capabilities = [_]cap.Capability{
        .CAP_READ_FILE,
        .CAP_WRITE_FILE,
        .CAP_EXEC_FILE,
        .CAP_NET_BIND_SERVICE,
        .CAP_SYS_ADMIN,
        .CAP_KILL,
    };

    for (capabilities) |capability| {
        const str = capability.toString();
        try std.testing.expect(str.len > 0);
    }
}

test "capability from string" {
    const read_cap = cap.Capability.fromString("CAP_READ_FILE");
    try std.testing.expect(read_cap != null);
    try std.testing.expect(read_cap.? == .CAP_READ_FILE);

    const invalid = cap.Capability.fromString("INVALID_CAP");
    try std.testing.expect(invalid == null);
}

test "capability enum values" {
    // Ensure capabilities fit in u5 (0-31)
    try std.testing.expect(@intFromEnum(cap.Capability.CAP_READ_FILE) == 0);
    try std.testing.expect(@intFromEnum(cap.Capability.CAP_DAC_OVERRIDE) == 31);
}

// ============================================================================
// CapabilitySet Tests
// ============================================================================

test "capability set - basic operations" {
    var caps = cap.CapabilitySet.initEmpty();

    try std.testing.expect(!caps.contains(.CAP_READ_FILE));

    caps.insert(.CAP_READ_FILE);
    try std.testing.expect(caps.contains(.CAP_READ_FILE));

    caps.remove(.CAP_READ_FILE);
    try std.testing.expect(!caps.contains(.CAP_READ_FILE));
}

test "capability set - multiple capabilities" {
    var caps = cap.CapabilitySet.initEmpty();

    caps.insert(.CAP_READ_FILE);
    caps.insert(.CAP_WRITE_FILE);
    caps.insert(.CAP_EXEC_FILE);

    try std.testing.expect(caps.contains(.CAP_READ_FILE));
    try std.testing.expect(caps.contains(.CAP_WRITE_FILE));
    try std.testing.expect(caps.contains(.CAP_EXEC_FILE));
    try std.testing.expect(!caps.contains(.CAP_NET_ADMIN));
}

test "capability set - containsAll" {
    var available = cap.CapabilitySet.initEmpty();
    available.insert(.CAP_READ_FILE);
    available.insert(.CAP_WRITE_FILE);
    available.insert(.CAP_NET_ADMIN);

    var required1 = cap.CapabilitySet.initEmpty();
    required1.insert(.CAP_READ_FILE);
    required1.insert(.CAP_WRITE_FILE);

    try std.testing.expect(available.containsAll(required1));

    var required2 = cap.CapabilitySet.initEmpty();
    required2.insert(.CAP_READ_FILE);
    required2.insert(.CAP_SYS_ADMIN); // Not in available

    try std.testing.expect(!available.containsAll(required2));
}

test "capability set - iterator" {
    var caps = cap.CapabilitySet.initEmpty();
    caps.insert(.CAP_READ_FILE);
    caps.insert(.CAP_WRITE_FILE);
    caps.insert(.CAP_EXEC_FILE);

    var count: usize = 0;
    var iter = caps.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expect(count == 3);
}

test "capability set - all 32 capabilities" {
    var caps = cap.CapabilitySet.initEmpty();

    // Insert all 32 capabilities
    inline for (std.meta.fields(cap.Capability)) |field| {
        const capability: cap.Capability = @enumFromInt(field.value);
        caps.insert(capability);
    }

    // Verify all are present
    inline for (std.meta.fields(cap.Capability)) |field| {
        const capability: cap.Capability = @enumFromInt(field.value);
        try std.testing.expect(caps.contains(capability));
    }
}

// ============================================================================
// CapableType Tests
// ============================================================================

test "capable type - initialization" {
    var caps = cap.CapabilitySet.initEmpty();
    caps.insert(.CAP_READ_FILE);

    const capable = cap.CapableType.init(Type.String, caps);

    try std.testing.expect(capable.required_caps.contains(.CAP_READ_FILE));
}

test "capable type - initSingle" {
    const capable = cap.CapableType.initSingle(Type.Int, .CAP_SYS_ADMIN);

    try std.testing.expect(capable.required_caps.contains(.CAP_SYS_ADMIN));
    try std.testing.expect(!capable.required_caps.contains(.CAP_READ_FILE));
}

test "capable type - check with sufficient capabilities" {
    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_READ_FILE);

    const capable = cap.CapableType.init(Type.String, required);

    var available = cap.CapabilitySet.initEmpty();
    available.insert(.CAP_READ_FILE);
    available.insert(.CAP_WRITE_FILE);

    try std.testing.expect(capable.check(available));
}

test "capable type - check with insufficient capabilities" {
    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_READ_FILE);
    required.insert(.CAP_WRITE_FILE);

    const capable = cap.CapableType.init(Type.String, required);

    var available = cap.CapabilitySet.initEmpty();
    available.insert(.CAP_READ_FILE);
    // Missing CAP_WRITE_FILE

    try std.testing.expect(!capable.check(available));
}

test "capable type - merge capabilities" {
    var caps1 = cap.CapabilitySet.initEmpty();
    caps1.insert(.CAP_READ_FILE);

    var caps2 = cap.CapabilitySet.initEmpty();
    caps2.insert(.CAP_WRITE_FILE);

    const type1 = cap.CapableType.init(Type.String, caps1);
    const type2 = cap.CapableType.init(Type.String, caps2);

    const merged = type1.merge(type2);

    try std.testing.expect(merged.required_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(merged.required_caps.contains(.CAP_WRITE_FILE));
}

// ============================================================================
// CapableFunction Tests
// ============================================================================

test "capable function - getAllRequiredCaps" {
    const allocator = std.testing.allocator;

    var param_caps = cap.CapabilitySet.initEmpty();
    param_caps.insert(.CAP_READ_FILE);

    var return_caps = cap.CapabilitySet.initEmpty();
    return_caps.insert(.CAP_WRITE_FILE);

    var func_caps = cap.CapabilitySet.initEmpty();
    func_caps.insert(.CAP_NET_ADMIN);

    const params = try allocator.alloc(cap.CapableType, 1);
    defer allocator.free(params);
    params[0] = cap.CapableType.init(Type.String, param_caps);

    const ret = cap.CapableType.init(Type.Int, return_caps);

    const func = cap.CapableFunction.init("test_func", params, ret, func_caps);

    const all_caps = func.getAllRequiredCaps();

    // Should include param, return, and function caps
    try std.testing.expect(all_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(all_caps.contains(.CAP_WRITE_FILE));
    try std.testing.expect(all_caps.contains(.CAP_NET_ADMIN));
}

// ============================================================================
// CapabilityTracker Tests
// ============================================================================

test "capability tracker - grant and revoke" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(!tracker.available_caps.contains(.CAP_READ_FILE));

    tracker.grantCapability(.CAP_READ_FILE);
    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));

    tracker.revokeCapability(.CAP_READ_FILE);
    try std.testing.expect(!tracker.available_caps.contains(.CAP_READ_FILE));
}

test "capability tracker - setAvailable" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var caps = cap.CapabilitySet.initEmpty();
    caps.insert(.CAP_READ_FILE);
    caps.insert(.CAP_WRITE_FILE);
    caps.insert(.CAP_NET_ADMIN);

    tracker.setAvailable(caps);

    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(tracker.available_caps.contains(.CAP_WRITE_FILE));
    try std.testing.expect(tracker.available_caps.contains(.CAP_NET_ADMIN));
    try std.testing.expect(!tracker.available_caps.contains(.CAP_SYS_ADMIN));
}

test "capability tracker - check operation success" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);
    tracker.grantCapability(.CAP_WRITE_FILE);

    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_READ_FILE);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkOperation(required, "read_operation", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "capability tracker - check operation failure" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_WRITE_FILE);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkOperation(required, "write_operation", loc);

    try std.testing.expect(tracker.hasErrors());
    try std.testing.expect(tracker.errors.items[0].kind == .MissingCapability);
}

test "capability tracker - multiple missing capabilities" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_WRITE_FILE);
    required.insert(.CAP_NET_ADMIN);
    required.insert(.CAP_SYS_ADMIN);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkOperation(required, "privileged_operation", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "capability tracker - function registration" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var caps = cap.CapabilitySet.initEmpty();
    caps.insert(.CAP_READ_FILE);

    const params = try std.testing.allocator.alloc(cap.CapableType, 1);
    defer std.testing.allocator.free(params);
    params[0] = cap.CapableType.init(Type.String, cap.CapabilitySet.initEmpty());

    const ret = cap.CapableType.init(Type.Int, cap.CapabilitySet.initEmpty());
    const func = cap.CapableFunction.init("open_file", params, ret, caps);

    try tracker.registerFunction(func);

    const retrieved = tracker.functions.get("open_file");
    try std.testing.expect(retrieved != null);
}

test "capability tracker - function call check" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var caps = cap.CapabilitySet.initEmpty();
    caps.insert(.CAP_WRITE_FILE);

    const params = try std.testing.allocator.alloc(cap.CapableType, 1);
    defer std.testing.allocator.free(params);
    params[0] = cap.CapableType.init(Type.String, cap.CapabilitySet.initEmpty());

    const ret = cap.CapableType.init(Type.Int, cap.CapabilitySet.initEmpty());
    const func = cap.CapableFunction.init("write_file", params, ret, caps);

    try tracker.registerFunction(func);

    // Grant capability
    tracker.grantCapability(.CAP_WRITE_FILE);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkFunctionCall("write_file", loc);

    try std.testing.expect(!tracker.hasErrors());
}

// ============================================================================
// Capability Scope Tests
// ============================================================================

test "capability tracker - scope management" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);
    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));

    // Enter elevated scope
    var elevated_caps = cap.CapabilitySet.initEmpty();
    elevated_caps.insert(.CAP_SYS_ADMIN);
    try tracker.enterScope(elevated_caps);

    try std.testing.expect(tracker.available_caps.contains(.CAP_SYS_ADMIN));
    try std.testing.expect(!tracker.available_caps.contains(.CAP_READ_FILE));

    // Exit scope
    try tracker.exitScope();

    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(!tracker.available_caps.contains(.CAP_SYS_ADMIN));
}

test "capability tracker - nested scopes" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    var caps1 = cap.CapabilitySet.initEmpty();
    caps1.insert(.CAP_WRITE_FILE);
    try tracker.enterScope(caps1);

    var caps2 = cap.CapabilitySet.initEmpty();
    caps2.insert(.CAP_NET_ADMIN);
    try tracker.enterScope(caps2);

    try std.testing.expect(tracker.available_caps.contains(.CAP_NET_ADMIN));

    try tracker.exitScope();
    try std.testing.expect(tracker.available_caps.contains(.CAP_WRITE_FILE));

    try tracker.exitScope();
    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));
}

test "capability tracker - exit scope without enter" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const result = tracker.exitScope();
    try std.testing.expectError(error.NoScopeToExit, result);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "edge case - empty capability set" {
    var caps = cap.CapabilitySet.initEmpty();

    var iter = caps.iterator();
    try std.testing.expect(iter.next() == null);

    var required = cap.CapabilitySet.initEmpty();
    try std.testing.expect(caps.containsAll(required));
}

test "edge case - no capabilities required" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var required = cap.CapabilitySet.initEmpty();
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkOperation(required, "no_caps_needed", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "edge case - all capabilities granted" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Grant all capabilities
    inline for (std.meta.fields(cap.Capability)) |field| {
        const capability: cap.Capability = @enumFromInt(field.value);
        tracker.grantCapability(capability);
    }

    // Any operation should succeed
    var required = cap.CapabilitySet.initEmpty();
    required.insert(.CAP_SYS_ADMIN);
    required.insert(.CAP_NET_ADMIN);
    required.insert(.CAP_WRITE_FILE);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkOperation(required, "any_operation", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "stress test - many function registrations" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const func_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "func_{d}",
            .{i},
        );
        defer std.testing.allocator.free(func_name);

        var caps = cap.CapabilitySet.initEmpty();
        const capability: cap.Capability = @enumFromInt(@as(u5, @intCast(i % 32)));
        caps.insert(capability);

        const params = try std.testing.allocator.alloc(cap.CapableType, 0);
        defer std.testing.allocator.free(params);

        const ret = cap.CapableType.init(Type.Int, cap.CapabilitySet.initEmpty());
        const func = cap.CapableFunction.init(func_name, params, ret, caps);

        try tracker.registerFunction(func);
    }

    try std.testing.expect(tracker.functions.count() == 100);
}

test "builtin capabilities registration" {
    var tracker = cap.CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try cap.BuiltinCapabilities.register(&tracker);

    try std.testing.expect(tracker.functions.get("open_file") != null);
    try std.testing.expect(tracker.functions.get("write_file") != null);
    try std.testing.expect(tracker.functions.get("bind_port") != null);
    try std.testing.expect(tracker.functions.get("set_system_time") != null);
    try std.testing.expect(tracker.functions.get("kill_process") != null);
}
