const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Taint levels representing trust levels of data
pub const TaintLevel = enum(u8) {
    /// Fully trusted data (sanitized, validated)
    Trusted = 0,
    /// User input from forms, CLI args
    UserInput = 1,
    /// Network data (HTTP requests, sockets)
    Network = 2,
    /// Filesystem data (file contents)
    FileSystem = 3,
    /// Database query results
    Database = 4,
    /// Completely untrusted data
    Untrusted = 5,

    pub fn canAssignTo(self: TaintLevel, target: TaintLevel) bool {
        // Can only assign to same or higher taint level
        return @intFromEnum(self) >= @intFromEnum(target);
    }

    pub fn toString(self: TaintLevel) []const u8 {
        return switch (self) {
            .Trusted => "Trusted",
            .UserInput => "UserInput",
            .Network => "Network",
            .FileSystem => "FileSystem",
            .Database => "Database",
            .Untrusted => "Untrusted",
        };
    }
};

/// A type with taint information attached
pub const TaintedType = struct {
    base_type: Type,
    taint_level: TaintLevel,
    source_location: ?ast.SourceLocation,

    pub fn init(base: Type, taint: TaintLevel) TaintedType {
        return .{
            .base_type = base,
            .taint_level = taint,
            .source_location = null,
        };
    }

    pub fn initWithLocation(base: Type, taint: TaintLevel, loc: ast.SourceLocation) TaintedType {
        return .{
            .base_type = base,
            .taint_level = taint,
            .source_location = loc,
        };
    }

    /// Check if this tainted value can be assigned to target type
    pub fn canAssignTo(self: TaintedType, target: TaintedType) bool {
        // Base types must match
        if (!self.base_type.equals(target.base_type)) {
            return false;
        }

        // Taint levels must be compatible
        return self.taint_level.canAssignTo(target.taint_level);
    }

    /// Merge two tainted types (take higher taint level)
    pub fn merge(self: TaintedType, other: TaintedType) TaintedType {
        const max_taint = if (@intFromEnum(self.taint_level) > @intFromEnum(other.taint_level))
            self.taint_level
        else
            other.taint_level;

        return TaintedType.init(self.base_type, max_taint);
    }
};

/// Taint tracking context for analyzing a program
pub const TaintTracker = struct {
    allocator: std.mem.Allocator,
    /// Map of variable names to their taint info
    taint_map: std.StringHashMap(TaintedType),
    /// Sanitization functions (remove taint)
    sanitizers: std.StringHashMap(SanitizerInfo),
    /// Errors found during taint analysis
    errors: std.ArrayList(TaintError),
    /// Warnings
    warnings: std.ArrayList(TaintWarning),

    pub fn init(allocator: std.mem.Allocator) TaintTracker {
        return .{
            .allocator = allocator,
            .taint_map = std.StringHashMap(TaintedType).init(allocator),
            .sanitizers = std.StringHashMap(SanitizerInfo).init(allocator),
            .errors = std.ArrayList(TaintError).init(allocator),
            .warnings = std.ArrayList(TaintWarning).init(allocator),
        };
    }

    pub fn deinit(self: *TaintTracker) void {
        self.taint_map.deinit();
        self.sanitizers.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Register a sanitization function
    pub fn registerSanitizer(
        self: *TaintTracker,
        func_name: []const u8,
        info: SanitizerInfo,
    ) !void {
        try self.sanitizers.put(func_name, info);
    }

    /// Set taint level for a variable
    pub fn setTaint(self: *TaintTracker, var_name: []const u8, tainted: TaintedType) !void {
        try self.taint_map.put(var_name, tainted);
    }

    /// Get taint level for a variable
    pub fn getTaint(self: *TaintTracker, var_name: []const u8) ?TaintedType {
        return self.taint_map.get(var_name);
    }

    /// Check if assignment is safe
    pub fn checkAssignment(
        self: *TaintTracker,
        target_var: []const u8,
        target_type: TaintedType,
        source_taint: TaintedType,
        loc: ast.SourceLocation,
    ) !void {
        if (!source_taint.canAssignTo(target_type)) {
            try self.addError(.{
                .kind = .TaintViolation,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot assign {s} data to {s} variable '{s}'",
                    .{ source_taint.taint_level.toString(), target_type.taint_level.toString(), target_var },
                ),
                .location = loc,
                .source_taint = source_taint.taint_level,
                .target_taint = target_type.taint_level,
            });
        }
    }

    /// Check function call with tainted arguments
    pub fn checkFunctionCall(
        self: *TaintTracker,
        func_name: []const u8,
        args: []const TaintedType,
        expected_params: []const TaintedType,
        loc: ast.SourceLocation,
    ) !TaintedType {
        // Check if function is a sanitizer
        if (self.sanitizers.get(func_name)) |sanitizer| {
            if (args.len != 1) {
                try self.addError(.{
                    .kind = .InvalidSanitizer,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Sanitizer '{s}' expects 1 argument, got {}",
                        .{ func_name, args.len },
                    ),
                    .location = loc,
                    .source_taint = .Untrusted,
                    .target_taint = .Trusted,
                });
                return args[0];
            }

            // Sanitizer removes taint
            return TaintedType.init(args[0].base_type, sanitizer.output_taint);
        }

        // Regular function - check all parameters
        if (args.len != expected_params.len) {
            return TaintedType.init(Type.Int, .Trusted); // Error handled elsewhere
        }

        for (args, expected_params, 0..) |arg, expected, i| {
            if (!arg.canAssignTo(expected)) {
                try self.addError(.{
                    .kind = .TaintViolation,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Argument {} to '{s}': cannot pass {s} data to {s} parameter",
                        .{ i, func_name, arg.taint_level.toString(), expected.taint_level.toString() },
                    ),
                    .location = loc,
                    .source_taint = arg.taint_level,
                    .target_taint = expected.taint_level,
                });
            }
        }

        // Return type inherits highest taint from arguments
        var result_taint = TaintLevel.Trusted;
        for (args) |arg| {
            if (@intFromEnum(arg.taint_level) > @intFromEnum(result_taint)) {
                result_taint = arg.taint_level;
            }
        }

        return TaintedType.init(Type.Int, result_taint);
    }

    /// Check if tainted data is used in dangerous context
    pub fn checkDangerousContext(
        self: *TaintTracker,
        context: DangerousContext,
        tainted: TaintedType,
        loc: ast.SourceLocation,
    ) !void {
        const required_level = context.requiredTaintLevel();

        if (@intFromEnum(tainted.taint_level) > @intFromEnum(required_level)) {
            try self.addError(.{
                .kind = .DangerousContext,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} context requires {s} data, but got {s}",
                    .{ @tagName(context), required_level.toString(), tainted.taint_level.toString() },
                ),
                .location = loc,
                .source_taint = tainted.taint_level,
                .target_taint = required_level,
            });
        }
    }

    fn addError(self: *TaintTracker, err: TaintError) !void {
        try self.errors.append(err);
    }

    pub fn hasErrors(self: *TaintTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Information about a sanitization function
pub const SanitizerInfo = struct {
    /// What taint level the function accepts
    input_taint: TaintLevel,
    /// What taint level it produces
    output_taint: TaintLevel,
    /// What it sanitizes against
    sanitizes_for: []const DangerousContext,

    pub fn init(output: TaintLevel) SanitizerInfo {
        return .{
            .input_taint = .Untrusted,
            .output_taint = output,
            .sanitizes_for = &[_]DangerousContext{},
        };
    }
};

/// Dangerous contexts where tainted data must not be used
pub const DangerousContext = enum {
    /// SQL query construction
    SqlQuery,
    /// HTML output
    HtmlOutput,
    /// Shell command execution
    ShellCommand,
    /// File path operations
    FilePath,
    /// Code evaluation
    CodeEval,
    /// Serialization format
    Serialization,

    pub fn requiredTaintLevel(self: DangerousContext) TaintLevel {
        return switch (self) {
            .SqlQuery, .ShellCommand, .CodeEval => .Trusted,
            .HtmlOutput, .FilePath => .Trusted,
            .Serialization => .Database,
        };
    }
};

/// Taint tracking error
pub const TaintError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    source_taint: TaintLevel,
    target_taint: TaintLevel,

    pub const ErrorKind = enum {
        TaintViolation,
        DangerousContext,
        InvalidSanitizer,
    };
};

/// Taint tracking warning
pub const TaintWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Built-in Sanitizers
// ============================================================================

pub const BuiltinSanitizers = struct {
    pub fn register(tracker: *TaintTracker) !void {
        // SQL sanitization
        try tracker.registerSanitizer("sanitize_sql", .{
            .input_taint = .Untrusted,
            .output_taint = .Trusted,
            .sanitizes_for = &[_]DangerousContext{.SqlQuery},
        });

        // HTML sanitization
        try tracker.registerSanitizer("escape_html", .{
            .input_taint = .Untrusted,
            .output_taint = .Trusted,
            .sanitizes_for = &[_]DangerousContext{.HtmlOutput},
        });

        // Shell command sanitization
        try tracker.registerSanitizer("sanitize_shell", .{
            .input_taint = .Untrusted,
            .output_taint = .Trusted,
            .sanitizes_for = &[_]DangerousContext{.ShellCommand},
        });

        // File path sanitization
        try tracker.registerSanitizer("sanitize_path", .{
            .input_taint = .Untrusted,
            .output_taint = .Trusted,
            .sanitizes_for = &[_]DangerousContext{.FilePath},
        });

        // Validation functions (untrusted -> trusted if valid)
        try tracker.registerSanitizer("validate_int", SanitizerInfo.init(.Trusted));
        try tracker.registerSanitizer("validate_string", SanitizerInfo.init(.Trusted));
        try tracker.registerSanitizer("validate_email", SanitizerInfo.init(.Trusted));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "taint level assignment" {
    const trusted = TaintLevel.Trusted;
    const user_input = TaintLevel.UserInput;
    const untrusted = TaintLevel.Untrusted;

    // Can assign trusted to anything
    try std.testing.expect(trusted.canAssignTo(trusted));
    try std.testing.expect(trusted.canAssignTo(user_input));
    try std.testing.expect(trusted.canAssignTo(untrusted));

    // Cannot assign untrusted to trusted
    try std.testing.expect(!untrusted.canAssignTo(trusted));

    // Can assign same level
    try std.testing.expect(user_input.canAssignTo(user_input));
}

test "tainted type assignment" {
    const trusted_int = TaintedType.init(Type.Int, .Trusted);
    const tainted_int = TaintedType.init(Type.Int, .UserInput);
    const trusted_string = TaintedType.init(Type.String, .Trusted);

    // Same type, compatible taint
    try std.testing.expect(trusted_int.canAssignTo(tainted_int));

    // Different types
    try std.testing.expect(!trusted_int.canAssignTo(trusted_string));

    // Incompatible taint
    try std.testing.expect(!tainted_int.canAssignTo(trusted_int));
}

test "taint tracker basic" {
    var tracker = TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    // Set taint for variable
    const tainted = TaintedType.init(Type.String, .UserInput);
    try tracker.setTaint("user_input", tainted);

    // Get taint back
    const retrieved = tracker.getTaint("user_input");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.taint_level == .UserInput);
}

test "sanitizer registration" {
    var tracker = TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerSanitizer("sanitize_sql", SanitizerInfo.init(.Trusted));

    const info = tracker.sanitizers.get("sanitize_sql");
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.output_taint == .Trusted);
}

test "dangerous context check" {
    var tracker = TaintTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const tainted = TaintedType.init(Type.String, .UserInput);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDangerousContext(.SqlQuery, tainted, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "tainted type merge" {
    const trusted = TaintedType.init(Type.Int, .Trusted);
    const user_input = TaintedType.init(Type.Int, .UserInput);

    const merged = trusted.merge(user_input);

    // Should take higher taint level
    try std.testing.expect(merged.taint_level == .UserInput);
}
