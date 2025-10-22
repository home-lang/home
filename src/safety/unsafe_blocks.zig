const std = @import("std");
const ast = @import("../ast/ast.zig");
const types = @import("../types/type_system.zig");
const ownership = @import("../types/ownership.zig");

/// Unsafe block tracking and validation
pub const UnsafeContext = struct {
    allocator: std.mem.Allocator,
    unsafe_blocks: std.ArrayList(UnsafeBlock),
    current_scope: ?*UnsafeScope,
    errors: std.ArrayList(UnsafeError),
    warnings: std.ArrayList(UnsafeWarning),

    pub fn init(allocator: std.mem.Allocator) UnsafeContext {
        return .{
            .allocator = allocator,
            .unsafe_blocks = std.ArrayList(UnsafeBlock).init(allocator),
            .current_scope = null,
            .errors = std.ArrayList(UnsafeError).init(allocator),
            .warnings = std.ArrayList(UnsafeWarning).init(allocator),
        };
    }

    pub fn deinit(self: *UnsafeContext) void {
        self.unsafe_blocks.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Enter an unsafe block
    pub fn enterUnsafe(self: *UnsafeContext, loc: ast.SourceLocation) !*UnsafeScope {
        const scope = try self.allocator.create(UnsafeScope);
        scope.* = UnsafeScope{
            .loc = loc,
            .parent = self.current_scope,
            .allowed_operations = UnsafeOperations.all(),
            .performed_operations = std.ArrayList(UnsafeOperation).init(self.allocator),
        };
        self.current_scope = scope;
        return scope;
    }

    /// Exit current unsafe block
    pub fn exitUnsafe(self: *UnsafeContext) !void {
        if (self.current_scope) |scope| {
            // Record the block
            try self.unsafe_blocks.append(.{
                .loc = scope.loc,
                .operations = try scope.performed_operations.toOwnedSlice(),
            });

            // Warn if unsafe block is empty
            if (scope.performed_operations.items.len == 0) {
                try self.addWarning(.{
                    .kind = .EmptyUnsafeBlock,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "empty unsafe block - consider removing",
                        .{},
                    ),
                    .loc = scope.loc,
                });
            }

            self.current_scope = scope.parent;
            self.allocator.destroy(scope);
        }
    }

    /// Check if currently in an unsafe context
    pub fn isUnsafe(self: *UnsafeContext) bool {
        return self.current_scope != null;
    }

    /// Perform an unsafe operation
    pub fn performUnsafe(self: *UnsafeContext, operation: UnsafeOperation) !void {
        if (!self.isUnsafe()) {
            try self.addError(.{
                .kind = .UnsafeOperationOutsideBlock,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "unsafe operation '{s}' requires unsafe block",
                    .{@tagName(operation.kind)},
                ),
                .loc = operation.loc,
                .suggestion = "wrap in 'unsafe { ... }' block",
            });
            return error.UnsafeOperationOutsideBlock;
        }

        if (self.current_scope) |scope| {
            try scope.performed_operations.append(operation);
        }
    }

    /// Check if an operation is safe or requires unsafe
    pub fn requiresUnsafe(self: *UnsafeContext, operation: UnsafeOperationKind) bool {
        _ = self;
        return switch (operation) {
            .RawPointerDeref,
            .RawPointerWrite,
            .UnionFieldAccess,
            .CallUnsafeFunction,
            .AccessMutableStatic,
            .InlineAssembly,
            .TransmuteType,
            .FFICall,
            => true,
            else => false,
        };
    }

    fn addError(self: *UnsafeContext, err: UnsafeError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *UnsafeContext, warning: UnsafeWarning) !void {
        try self.warnings.append(warning);
    }
};

pub const UnsafeScope = struct {
    loc: ast.SourceLocation,
    parent: ?*UnsafeScope,
    allowed_operations: UnsafeOperations,
    performed_operations: std.ArrayList(UnsafeOperation),
};

pub const UnsafeBlock = struct {
    loc: ast.SourceLocation,
    operations: []UnsafeOperation,
};

pub const UnsafeOperation = struct {
    kind: UnsafeOperationKind,
    loc: ast.SourceLocation,
    details: ?[]const u8,
};

pub const UnsafeOperationKind = enum {
    // Pointer operations
    RawPointerDeref,
    RawPointerWrite,
    RawPointerArithmetic,

    // Type operations
    TransmuteType,
    UnionFieldAccess,

    // Function calls
    CallUnsafeFunction,
    FFICall,

    // Static/global access
    AccessMutableStatic,
    WriteMutableStatic,

    // Low-level operations
    InlineAssembly,
    DirectMemoryAccess,

    // Concurrency
    UnsafeSend,
    UnsafeSync,
};

pub const UnsafeOperations = struct {
    allowed: std.EnumSet(UnsafeOperationKind),

    pub fn all() UnsafeOperations {
        var ops = UnsafeOperations{
            .allowed = std.EnumSet(UnsafeOperationKind).initEmpty(),
        };
        // Allow all unsafe operations by default in unsafe blocks
        var iter = std.enums.values(UnsafeOperationKind);
        while (iter.next()) |kind| {
            ops.allowed.insert(kind);
        }
        return ops;
    }

    pub fn isAllowed(self: *const UnsafeOperations, kind: UnsafeOperationKind) bool {
        return self.allowed.contains(kind);
    }
};

pub const UnsafeError = struct {
    kind: UnsafeErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
    suggestion: ?[]const u8,
};

pub const UnsafeErrorKind = enum {
    UnsafeOperationOutsideBlock,
    DisallowedUnsafeOperation,
    UnsafeFunctionNotMarked,
    InvalidTransmute,
};

pub const UnsafeWarning = struct {
    kind: UnsafeWarningKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const UnsafeWarningKind = enum {
    EmptyUnsafeBlock,
    UnnecessaryUnsafe,
    UndocumentedUnsafe,
};

/// Function safety analysis
pub const FunctionSafety = struct {
    allocator: std.mem.Allocator,
    unsafe_functions: std.StringHashMap(UnsafeFunctionInfo),

    pub fn init(allocator: std.mem.Allocator) FunctionSafety {
        return .{
            .allocator = allocator,
            .unsafe_functions = std.StringHashMap(UnsafeFunctionInfo).init(allocator),
        };
    }

    pub fn deinit(self: *FunctionSafety) void {
        self.unsafe_functions.deinit();
    }

    /// Mark a function as unsafe
    pub fn markUnsafe(self: *FunctionSafety, name: []const u8, info: UnsafeFunctionInfo) !void {
        try self.unsafe_functions.put(name, info);
    }

    /// Check if a function is marked unsafe
    pub fn isUnsafe(self: *FunctionSafety, name: []const u8) bool {
        return self.unsafe_functions.contains(name);
    }

    /// Get unsafe function info
    pub fn getInfo(self: *FunctionSafety, name: []const u8) ?UnsafeFunctionInfo {
        return self.unsafe_functions.get(name);
    }
};

pub const UnsafeFunctionInfo = struct {
    name: []const u8,
    reason: []const u8,
    loc: ast.SourceLocation,
    required_capabilities: []UnsafeOperationKind,
};

/// Unsafe trait implementation checker
pub const UnsafeTraitChecker = struct {
    allocator: std.mem.Allocator,
    unsafe_traits: std.StringHashMap(UnsafeTraitInfo),

    pub fn init(allocator: std.mem.Allocator) UnsafeTraitChecker {
        return .{
            .allocator = allocator,
            .unsafe_traits = std.StringHashMap(UnsafeTraitInfo).init(allocator),
        };
    }

    pub fn deinit(self: *UnsafeTraitChecker) void {
        self.unsafe_traits.deinit();
    }

    /// Mark a trait as unsafe
    pub fn markUnsafe(self: *UnsafeTraitChecker, trait_name: []const u8, info: UnsafeTraitInfo) !void {
        try self.unsafe_traits.put(trait_name, info);
    }

    /// Check if implementing a trait requires unsafe
    pub fn requiresUnsafe(self: *UnsafeTraitChecker, trait_name: []const u8) bool {
        return self.unsafe_traits.contains(trait_name);
    }
};

pub const UnsafeTraitInfo = struct {
    name: []const u8,
    reason: []const u8,
    safety_requirements: []const u8,
};

/// Built-in unsafe operations registry
pub const UnsafeRegistry = struct {
    allocator: std.mem.Allocator,
    function_safety: FunctionSafety,
    trait_checker: UnsafeTraitChecker,

    pub fn init(allocator: std.mem.Allocator) UnsafeRegistry {
        var registry = UnsafeRegistry{
            .allocator = allocator,
            .function_safety = FunctionSafety.init(allocator),
            .trait_checker = UnsafeTraitChecker.init(allocator),
        };

        // Register built-in unsafe operations
        registry.registerBuiltins() catch {};

        return registry;
    }

    pub fn deinit(self: *UnsafeRegistry) void {
        self.function_safety.deinit();
        self.trait_checker.deinit();
    }

    fn registerBuiltins(self: *UnsafeRegistry) !void {
        // Built-in unsafe functions
        try self.function_safety.markUnsafe("ptr_read", .{
            .name = "ptr_read",
            .reason = "dereferences raw pointer",
            .loc = ast.SourceLocation{ .line = 0, .column = 0 },
            .required_capabilities = &[_]UnsafeOperationKind{.RawPointerDeref},
        });

        try self.function_safety.markUnsafe("ptr_write", .{
            .name = "ptr_write",
            .reason = "writes through raw pointer",
            .loc = ast.SourceLocation{ .line = 0, .column = 0 },
            .required_capabilities = &[_]UnsafeOperationKind{.RawPointerWrite},
        });

        try self.function_safety.markUnsafe("transmute", .{
            .name = "transmute",
            .reason = "bypasses type safety",
            .loc = ast.SourceLocation{ .line = 0, .column = 0 },
            .required_capabilities = &[_]UnsafeOperationKind{.TransmuteType},
        });

        // Built-in unsafe traits
        try self.trait_checker.markUnsafe("Send", .{
            .name = "Send",
            .reason = "requires thread-safety guarantees",
            .safety_requirements = "type must be safe to send between threads",
        });

        try self.trait_checker.markUnsafe("Sync", .{
            .name = "Sync",
            .reason = "requires synchronization guarantees",
            .safety_requirements = "type must be safe to share between threads",
        });
    }
};
