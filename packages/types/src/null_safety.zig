const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Nullability state for variables
pub const Nullability = enum(u8) {
    /// Value is guaranteed non-null
    NonNull = 0,
    /// Value may be null (needs null check)
    Nullable = 1,
    /// Value is definitely null
    Null = 2,
    /// Unknown nullability
    Unknown = 3,

    pub fn toString(self: Nullability) []const u8 {
        return switch (self) {
            .NonNull => "NonNull",
            .Nullable => "Nullable",
            .Null => "Null",
            .Unknown => "Unknown",
        };
    }

    /// Merge two nullability states (union)
    pub fn merge(self: Nullability, other: Nullability) Nullability {
        if (self == .Null and other == .Null) return .Null;
        if (self == .NonNull and other == .NonNull) return .NonNull;
        return .Nullable; // Conservative: might be null
    }

    /// Can this value be safely dereferenced?
    pub fn canDereference(self: Nullability) bool {
        return self == .NonNull;
    }
};

/// Nullable type wrapper
pub const NullableType = struct {
    base_type: Type,
    nullability: Nullability,
    location: ?ast.SourceLocation,

    pub fn init(base: Type, nullable: Nullability) NullableType {
        return .{
            .base_type = base,
            .nullability = nullable,
            .location = null,
        };
    }

    pub fn initWithLocation(base: Type, nullable: Nullability, loc: ast.SourceLocation) NullableType {
        return .{
            .base_type = base,
            .nullability = nullable,
            .location = loc,
        };
    }

    pub fn nonNull(base: Type) NullableType {
        return init(base, .NonNull);
    }

    pub fn nullable(base: Type) NullableType {
        return init(base, .Nullable);
    }

    pub fn canDereference(self: NullableType) bool {
        return self.nullability.canDereference();
    }
};

/// Null safety tracker for program analysis
pub const NullSafetyTracker = struct {
    allocator: std.mem.Allocator,
    /// Nullability state of variables
    var_nullability: std.StringHashMap(Nullability),
    /// Null-checked variables (in current scope)
    checked_vars: std.StringHashMap(bool),
    /// Function signatures with nullability
    functions: std.StringHashMap(FunctionSignature),
    /// Errors found
    errors: std.ArrayList(NullSafetyError),
    /// Warnings
    warnings: std.ArrayList(NullSafetyWarning),
    /// Scope depth (for tracking null checks)
    scope_depth: usize,

    pub fn init(allocator: std.mem.Allocator) NullSafetyTracker {
        return .{
            .allocator = allocator,
            .var_nullability = std.StringHashMap(Nullability).init(allocator),
            .checked_vars = std.StringHashMap(bool).init(allocator),
            .functions = std.StringHashMap(FunctionSignature).init(allocator),
            .errors = std.ArrayList(NullSafetyError).init(allocator),
            .warnings = std.ArrayList(NullSafetyWarning).init(allocator),
            .scope_depth = 0,
        };
    }

    pub fn deinit(self: *NullSafetyTracker) void {
        self.var_nullability.deinit();
        self.checked_vars.deinit();
        self.functions.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Set nullability for a variable
    pub fn setNullability(self: *NullSafetyTracker, var_name: []const u8, nullability: Nullability) !void {
        try self.var_nullability.put(var_name, nullability);
    }

    /// Get nullability for a variable
    pub fn getNullability(self: *NullSafetyTracker, var_name: []const u8) Nullability {
        return self.var_nullability.get(var_name) orelse .Unknown;
    }

    /// Register a function signature
    pub fn registerFunction(self: *NullSafetyTracker, func: FunctionSignature) !void {
        try self.functions.put(func.name, func);
    }

    /// Check if dereference is safe
    pub fn checkDereference(
        self: *NullSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const nullability = self.getNullability(var_name);

        if (!nullability.canDereference()) {
            // Check if variable was null-checked
            if (self.checked_vars.get(var_name)) |_| {
                // Variable was null-checked, it's safe
                return;
            }

            try self.addError(.{
                .kind = .UnsafeDereference,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Unsafe dereference of potentially null variable '{s}' (nullability: {s})",
                    .{ var_name, nullability.toString() },
                ),
                .location = loc,
                .variable_name = var_name,
            });
        }
    }

    /// Check if assignment is safe
    pub fn checkAssignment(
        self: *NullSafetyTracker,
        target_var: []const u8,
        target_nullability: Nullability,
        source_nullability: Nullability,
        loc: ast.SourceLocation,
    ) !void {
        // Cannot assign nullable to non-null without check
        if (target_nullability == .NonNull and source_nullability != .NonNull) {
            try self.addError(.{
                .kind = .NullableToNonNull,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot assign {s} value to non-null variable '{s}' without null check",
                    .{ source_nullability.toString(), target_var },
                ),
                .location = loc,
                .variable_name = target_var,
            });
        }

        // Update variable nullability
        try self.setNullability(target_var, source_nullability);
    }

    /// Record that a variable was null-checked
    pub fn recordNullCheck(self: *NullSafetyTracker, var_name: []const u8) !void {
        try self.checked_vars.put(var_name, true);

        // Update nullability to non-null in this scope
        try self.setNullability(var_name, .NonNull);
    }

    /// Clear null checks (when exiting scope)
    pub fn clearNullChecks(self: *NullSafetyTracker) void {
        self.checked_vars.clearRetainingCapacity();
    }

    /// Enter a new scope
    pub fn enterScope(self: *NullSafetyTracker) void {
        self.scope_depth += 1;
    }

    /// Exit current scope
    pub fn exitScope(self: *NullSafetyTracker) void {
        if (self.scope_depth > 0) {
            self.scope_depth -= 1;
            // Clear null checks when exiting scope
            if (self.scope_depth == 0) {
                self.clearNullChecks();
            }
        }
    }

    /// Check function call with nullable arguments
    pub fn checkFunctionCall(
        self: *NullSafetyTracker,
        func_name: []const u8,
        args: []const Nullability,
        loc: ast.SourceLocation,
    ) !NullableType {
        const func = self.functions.get(func_name) orelse {
            // Unknown function - assume non-null return
            return NullableType.nonNull(Type.Int);
        };

        // Check argument count
        if (args.len != func.param_nullability.len) {
            return NullableType.nonNull(Type.Int); // Error handled elsewhere
        }

        // Check each parameter
        for (args, func.param_nullability, 0..) |arg_null, expected_null, i| {
            if (expected_null == .NonNull and arg_null != .NonNull) {
                try self.addError(.{
                    .kind = .NullableArgument,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Argument {} to '{s}': cannot pass {s} value to non-null parameter",
                        .{ i, func_name, arg_null.toString() },
                    ),
                    .location = loc,
                    .variable_name = func_name,
                });
            }
        }

        return NullableType.init(func.return_type, func.return_nullability);
    }

    /// Check conditional with null check
    pub fn checkNullConditional(
        self: *NullSafetyTracker,
        var_name: []const u8,
        is_null_check: bool,
        loc: ast.SourceLocation,
    ) !void {
        _ = loc;

        if (is_null_check) {
            try self.recordNullCheck(var_name);
        }
    }

    /// Check return statement nullability
    pub fn checkReturn(
        self: *NullSafetyTracker,
        return_nullability: Nullability,
        expected_nullability: Nullability,
        loc: ast.SourceLocation,
    ) !void {
        if (expected_nullability == .NonNull and return_nullability != .NonNull) {
            try self.addError(.{
                .kind = .NullableReturn,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot return {s} value from function expecting non-null return",
                    .{return_nullability.toString()},
                ),
                .location = loc,
                .variable_name = "return",
            });
        }
    }

    /// Warn about redundant null checks
    pub fn warnRedundantCheck(
        self: *NullSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const nullability = self.getNullability(var_name);

        if (nullability == .NonNull) {
            try self.addWarning(.{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Redundant null check: '{s}' is guaranteed non-null",
                    .{var_name},
                ),
                .location = loc,
            });
        }
    }

    fn addError(self: *NullSafetyTracker, err: NullSafetyError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *NullSafetyTracker, warning: NullSafetyWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *NullSafetyTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Function signature with nullability information
pub const FunctionSignature = struct {
    name: []const u8,
    param_nullability: []const Nullability,
    return_type: Type,
    return_nullability: Nullability,

    pub fn init(
        name: []const u8,
        params: []const Nullability,
        ret_type: Type,
        ret_null: Nullability,
    ) FunctionSignature {
        return .{
            .name = name,
            .param_nullability = params,
            .return_type = ret_type,
            .return_nullability = ret_null,
        };
    }
};

/// Null safety error
pub const NullSafetyError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    variable_name: []const u8,

    pub const ErrorKind = enum {
        UnsafeDereference,
        NullableToNonNull,
        NullableArgument,
        NullableReturn,
        NullPointerAssignment,
    };
};

/// Null safety warning
pub const NullSafetyWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Null-Safe Type Constructors
// ============================================================================

pub const NullSafeConstructors = struct {
    /// Create a non-null reference (panics if null)
    pub fn unwrap(comptime T: type, value: ?T) T {
        return value orelse @panic("Attempted to unwrap null value");
    }

    /// Create a non-null reference with custom message
    pub fn expect(comptime T: type, value: ?T, message: []const u8) T {
        return value orelse @panic(message);
    }

    /// Get value or default
    pub fn orDefault(comptime T: type, value: ?T, default: T) T {
        return value orelse default;
    }

    /// Map nullable value
    pub fn map(comptime T: type, comptime U: type, value: ?T, func: fn (T) U) ?U {
        if (value) |v| {
            return func(v);
        }
        return null;
    }

    /// Flat map nullable value
    pub fn flatMap(comptime T: type, comptime U: type, value: ?T, func: fn (T) ?U) ?U {
        if (value) |v| {
            return func(v);
        }
        return null;
    }
};

// ============================================================================
// Built-in Function Signatures
// ============================================================================

pub const BuiltinNullableFunctions = struct {
    pub fn register(tracker: *NullSafetyTracker) !void {
        const allocator = tracker.allocator;

        // String operations
        {
            const params = try allocator.alloc(Nullability, 1);
            params[0] = .NonNull; // Requires non-null string

            try tracker.registerFunction(FunctionSignature.init(
                "string_length",
                params,
                Type.Int,
                .NonNull, // Always returns non-null length
            ));
        }

        // Optional operations
        {
            const params = try allocator.alloc(Nullability, 1);
            params[0] = .Nullable; // Accepts nullable value

            try tracker.registerFunction(FunctionSignature.init(
                "is_null",
                params,
                Type.Bool,
                .NonNull, // Always returns non-null bool
            ));
        }

        // Safe unwrap
        {
            const params = try allocator.alloc(Nullability, 2);
            params[0] = .Nullable; // Nullable value
            params[1] = .NonNull; // Non-null default

            try tracker.registerFunction(FunctionSignature.init(
                "unwrap_or",
                params,
                Type.Int,
                .NonNull, // Always returns non-null (value or default)
            ));
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "nullability merging" {
    const non_null = Nullability.NonNull;
    const nullable = Nullability.Nullable;
    const null_val = Nullability.Null;

    try std.testing.expect(non_null.merge(non_null) == .NonNull);
    try std.testing.expect(non_null.merge(nullable) == .Nullable);
    try std.testing.expect(null_val.merge(null_val) == .Null);
}

test "nullable type" {
    const non_null_int = NullableType.nonNull(Type.Int);
    const nullable_int = NullableType.nullable(Type.Int);

    try std.testing.expect(non_null_int.canDereference());
    try std.testing.expect(!nullable_int.canDereference());
}

test "null safety tracker basic" {
    var tracker = NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const nullability = tracker.getNullability("ptr");
    try std.testing.expect(nullability == .Nullable);
}

test "unsafe dereference detection" {
    var tracker = NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "null check tracking" {
    var tracker = NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.setNullability("ptr", .Nullable);
    try tracker.recordNullCheck("ptr");

    const nullability = tracker.getNullability("ptr");
    try std.testing.expect(nullability == .NonNull);

    // Now dereference should be safe
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkDereference("ptr", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "nullable to non-null assignment" {
    var tracker = NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkAssignment("var", .NonNull, .Nullable, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "scope management" {
    var tracker = NullSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.enterScope();
    try tracker.recordNullCheck("ptr");

    tracker.exitScope();

    // Null checks should be cleared
    try std.testing.expect(tracker.checked_vars.count() == 0);
}

test "null-safe constructors" {
    const value: ?i32 = 42;
    const result = NullSafeConstructors.unwrap(i32, value);
    try std.testing.expect(result == 42);

    const default_result = NullSafeConstructors.orDefault(i32, null, 100);
    try std.testing.expect(default_result == 100);
}
