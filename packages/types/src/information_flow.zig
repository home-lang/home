const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Security levels for information flow control
/// Lower levels can flow to higher levels (public -> secret)
/// Higher levels CANNOT flow to lower levels (prevents data leakage)
pub const SecurityLevel = enum(u8) {
    Public = 0,
    Internal = 1,
    Confidential = 2,
    Secret = 3,
    TopSecret = 4,

    pub fn canFlowTo(self: SecurityLevel, target: SecurityLevel) bool {
        // Can only flow to same or higher security level
        return @intFromEnum(self) <= @intFromEnum(target);
    }

    pub fn toString(self: SecurityLevel) []const u8 {
        return switch (self) {
            .Public => "Public",
            .Internal => "Internal",
            .Confidential => "Confidential",
            .Secret => "Secret",
            .TopSecret => "TopSecret",
        };
    }

    pub fn fromString(name: []const u8) ?SecurityLevel {
        if (std.mem.eql(u8, name, "Public")) return .Public;
        if (std.mem.eql(u8, name, "Internal")) return .Internal;
        if (std.mem.eql(u8, name, "Confidential")) return .Confidential;
        if (std.mem.eql(u8, name, "Secret")) return .Secret;
        if (std.mem.eql(u8, name, "TopSecret")) return .TopSecret;
        return null;
    }

    /// Join two security levels (take higher level)
    pub fn join(self: SecurityLevel, other: SecurityLevel) SecurityLevel {
        return if (@intFromEnum(self) > @intFromEnum(other)) self else other;
    }

    /// Meet two security levels (take lower level)
    pub fn meet(self: SecurityLevel, other: SecurityLevel) SecurityLevel {
        return if (@intFromEnum(self) < @intFromEnum(other)) self else other;
    }
};

/// A type with security level attached for information flow control
pub const SecureType = struct {
    base_type: Type,
    security_level: SecurityLevel,
    location: ?ast.SourceLocation,

    pub fn init(base: Type, level: SecurityLevel) SecureType {
        return .{
            .base_type = base,
            .security_level = level,
            .location = null,
        };
    }

    pub fn initWithLocation(base: Type, level: SecurityLevel, loc: ast.SourceLocation) SecureType {
        return .{
            .base_type = base,
            .security_level = level,
            .location = loc,
        };
    }

    /// Check if this value can flow to target type
    pub fn canFlowTo(self: SecureType, target: SecureType) bool {
        // Base types must match
        if (!self.base_type.equals(target.base_type)) {
            return false;
        }

        // Security levels must allow flow
        return self.security_level.canFlowTo(target.security_level);
    }

    /// Join two secure types (take higher security level)
    pub fn join(self: SecureType, other: SecureType) SecureType {
        return SecureType.init(
            self.base_type,
            self.security_level.join(other.security_level),
        );
    }

    /// Meet two secure types (take lower security level)
    pub fn meet(self: SecureType, other: SecureType) SecureType {
        return SecureType.init(
            self.base_type,
            self.security_level.meet(other.security_level),
        );
    }
};

/// Information flow context for analyzing a program
pub const FlowTracker = struct {
    allocator: std.mem.Allocator,
    /// Map of variable names to their security levels
    var_levels: std.StringHashMap(SecureType),
    /// Function security signatures
    functions: std.StringHashMap(FunctionFlow),
    /// Errors found during flow analysis
    errors: std.ArrayList(FlowError),
    /// Warnings
    warnings: std.ArrayList(FlowWarning),
    /// Current security context (for declassification)
    current_context: SecurityLevel,

    pub fn init(allocator: std.mem.Allocator) FlowTracker {
        return .{
            .allocator = allocator,
            .var_levels = std.StringHashMap(SecureType).init(allocator),
            .functions = std.StringHashMap(FunctionFlow).init(allocator),
            .errors = std.ArrayList(FlowError).init(allocator),
            .warnings = std.ArrayList(FlowWarning).init(allocator),
            .current_context = .Public,
        };
    }

    pub fn deinit(self: *FlowTracker) void {
        self.var_levels.deinit();
        self.functions.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Set security level for a variable
    pub fn setLevel(self: *FlowTracker, var_name: []const u8, secure: SecureType) !void {
        try self.var_levels.put(var_name, secure);
    }

    /// Get security level for a variable
    pub fn getLevel(self: *FlowTracker, var_name: []const u8) ?SecureType {
        return self.var_levels.get(var_name);
    }

    /// Register a function with its flow signature
    pub fn registerFunction(self: *FlowTracker, func: FunctionFlow) !void {
        try self.functions.put(func.name, func);
    }

    /// Check if assignment respects information flow
    pub fn checkAssignment(
        self: *FlowTracker,
        target_var: []const u8,
        target_type: SecureType,
        source_type: SecureType,
        loc: ast.SourceLocation,
    ) !void {
        if (!source_type.canFlowTo(target_type)) {
            try self.addError(.{
                .kind = .IllegalFlow,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Illegal information flow: cannot assign {s} data to {s} variable '{s}'",
                    .{ source_type.security_level.toString(), target_type.security_level.toString(), target_var },
                ),
                .location = loc,
                .source_level = source_type.security_level,
                .target_level = target_type.security_level,
            });
        }
    }

    /// Check function call with secure arguments
    pub fn checkFunctionCall(
        self: *FlowTracker,
        func_name: []const u8,
        args: []const SecureType,
        loc: ast.SourceLocation,
    ) !SecureType {
        const func = self.functions.get(func_name) orelse {
            // Unknown function - assume public
            return SecureType.init(Type.Int, .Public);
        };

        // Check argument count
        if (args.len != func.param_types.len) {
            return SecureType.init(Type.Int, .Public); // Error handled elsewhere
        }

        // Check each parameter flow
        for (args, func.param_types, 0..) |arg, expected, i| {
            if (!arg.canFlowTo(expected)) {
                try self.addError(.{
                    .kind = .IllegalFlow,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Argument {} to '{s}': cannot pass {s} data to {s} parameter",
                        .{ i, func_name, arg.security_level.toString(), expected.security_level.toString() },
                    ),
                    .location = loc,
                    .source_level = arg.security_level,
                    .target_level = expected.security_level,
                });
            }
        }

        // Return type computation: join of all argument levels + function level
        var result_level = func.return_level;
        for (args) |arg| {
            result_level = result_level.join(arg.security_level);
        }

        return SecureType.init(func.return_type, result_level);
    }

    /// Check conditional statement (prevents implicit flows)
    pub fn checkConditional(
        self: *FlowTracker,
        condition_level: SecurityLevel,
        branch_assignments: []const SecureType,
        loc: ast.SourceLocation,
    ) !void {
        // All assignments in conditional must be at least as secure as condition
        for (branch_assignments) |assignment| {
            if (!condition_level.canFlowTo(assignment.security_level)) {
                try self.addError(.{
                    .kind = .ImplicitFlow,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Implicit flow: {s} condition affects {s} variable",
                        .{ condition_level.toString(), assignment.security_level.toString() },
                    ),
                    .location = loc,
                    .source_level = condition_level,
                    .target_level = assignment.security_level,
                });
            }
        }
    }

    /// Check loop (prevents timing channels)
    pub fn checkLoop(
        self: *FlowTracker,
        condition_level: SecurityLevel,
        body_level: SecurityLevel,
        loc: ast.SourceLocation,
    ) !void {
        // Loop condition can create timing channel
        if (@intFromEnum(condition_level) > @intFromEnum(body_level)) {
            try self.addWarning(.{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Potential timing channel: {s} condition controls loop with {s} body",
                    .{ condition_level.toString(), body_level.toString() },
                ),
                .location = loc,
            });
        }
    }

    /// Declassify data (requires explicit authorization)
    pub fn declassify(
        self: *FlowTracker,
        var_name: []const u8,
        from_level: SecurityLevel,
        to_level: SecurityLevel,
        loc: ast.SourceLocation,
    ) !void {
        // Can only declassify if current context allows it
        if (@intFromEnum(self.current_context) < @intFromEnum(from_level)) {
            try self.addError(.{
                .kind = .UnauthorizedDeclassification,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot declassify '{s}' from {s} to {s} in {s} context",
                    .{ var_name, from_level.toString(), to_level.toString(), self.current_context.toString() },
                ),
                .location = loc,
                .source_level = from_level,
                .target_level = to_level,
            });
        }

        // Log declassification (security audit trail)
        try self.addWarning(.{
            .message = try std.fmt.allocPrint(
                self.allocator,
                "Declassification: '{s}' from {s} to {s}",
                .{ var_name, from_level.toString(), to_level.toString() },
            ),
            .location = loc,
        });
    }

    /// Enter a security context (for declassification)
    pub fn enterContext(self: *FlowTracker, level: SecurityLevel) void {
        self.current_context = level;
    }

    /// Exit security context
    pub fn exitContext(self: *FlowTracker) void {
        self.current_context = .Public;
    }

    fn addError(self: *FlowTracker, err: FlowError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *FlowTracker, warning: FlowWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *FlowTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Function signature with information flow
pub const FunctionFlow = struct {
    name: []const u8,
    param_types: []const SecureType,
    return_type: Type,
    return_level: SecurityLevel,

    pub fn init(
        name: []const u8,
        params: []const SecureType,
        ret_type: Type,
        ret_level: SecurityLevel,
    ) FunctionFlow {
        return .{
            .name = name,
            .param_types = params,
            .return_type = ret_type,
            .return_level = ret_level,
        };
    }
};

/// Information flow error
pub const FlowError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    source_level: SecurityLevel,
    target_level: SecurityLevel,

    pub const ErrorKind = enum {
        IllegalFlow,
        ImplicitFlow,
        UnauthorizedDeclassification,
    };
};

/// Information flow warning
pub const FlowWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Built-in Flow Policies
// ============================================================================

pub const BuiltinFlowPolicies = struct {
    pub fn register(tracker: *FlowTracker) !void {
        const allocator = tracker.allocator;

        // Public API functions
        {
            const params = try allocator.alloc(SecureType, 1);
            params[0] = SecureType.init(Type.String, .Public);

            try tracker.registerFunction(FunctionFlow.init(
                "public_api",
                params,
                Type.String,
                .Public,
            ));
        }

        // Internal functions
        {
            const params = try allocator.alloc(SecureType, 1);
            params[0] = SecureType.init(Type.String, .Internal);

            try tracker.registerFunction(FunctionFlow.init(
                "internal_function",
                params,
                Type.String,
                .Internal,
            ));
        }

        // Cryptographic operations (high security)
        {
            const params = try allocator.alloc(SecureType, 1);
            params[0] = SecureType.init(Type.String, .Secret);

            try tracker.registerFunction(FunctionFlow.init(
                "encrypt_data",
                params,
                Type.String,
                .Public, // Encrypted data can be public
            ));
        }

        // Logging (declassification point)
        {
            const params = try allocator.alloc(SecureType, 1);
            params[0] = SecureType.init(Type.String, .Internal);

            try tracker.registerFunction(FunctionFlow.init(
                "log_message",
                params,
                Type.Int,
                .Public,
            ));
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "security level flow" {
    const public = SecurityLevel.Public;
    const secret = SecurityLevel.Secret;

    // Can flow from low to high
    try std.testing.expect(public.canFlowTo(secret));

    // Cannot flow from high to low
    try std.testing.expect(!secret.canFlowTo(public));

    // Can flow to same level
    try std.testing.expect(public.canFlowTo(public));
}

test "security level join/meet" {
    const public = SecurityLevel.Public;
    const secret = SecurityLevel.Secret;

    // Join takes higher
    try std.testing.expect(public.join(secret) == .Secret);

    // Meet takes lower
    try std.testing.expect(public.meet(secret) == .Public);
}

test "secure type flow" {
    const public_int = SecureType.init(Type.Int, .Public);
    const secret_int = SecureType.init(Type.Int, .Secret);
    const public_string = SecureType.init(Type.String, .Public);

    // Same type, compatible levels
    try std.testing.expect(public_int.canFlowTo(secret_int));

    // Different types
    try std.testing.expect(!public_int.canFlowTo(public_string));

    // Incompatible levels
    try std.testing.expect(!secret_int.canFlowTo(public_int));
}

test "flow tracker basic" {
    var tracker = FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Set security level for variable
    const secure = SecureType.init(Type.String, .Confidential);
    try tracker.setLevel("password", secure);

    // Get level back
    const retrieved = tracker.getLevel("password");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.security_level == .Confidential);
}

test "illegal flow detection" {
    var tracker = FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_data = SecureType.init(Type.String, .Secret);
    const public_var = SecureType.init(Type.String, .Public);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("public_var", public_var, secret_data, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "conditional implicit flow" {
    var tracker = FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const secret_condition = SecurityLevel.Secret;
    const public_assignments = [_]SecureType{
        SecureType.init(Type.Int, .Public),
    };
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkConditional(secret_condition, &public_assignments, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "declassification" {
    var tracker = FlowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Enter high-security context
    tracker.enterContext(.Secret);

    // Should succeed
    try tracker.declassify("data", .Secret, .Public, loc);

    tracker.exitContext();
}

test "secure type join/meet" {
    const public_int = SecureType.init(Type.Int, .Public);
    const secret_int = SecureType.init(Type.Int, .Secret);

    const joined = public_int.join(secret_int);
    try std.testing.expect(joined.security_level == .Secret);

    const met = public_int.meet(secret_int);
    try std.testing.expect(met.security_level == .Public);
}
