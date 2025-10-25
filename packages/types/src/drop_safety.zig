const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Drop order requirements
pub const DropOrder = enum {
    /// No specific drop order required
    Unordered,
    /// Must be dropped before other values
    DropFirst,
    /// Must be dropped after other values
    DropLast,
    /// Custom drop order (e.g., for graph structures)
    Custom,
};

/// Drop behavior for a type
pub const DropBehavior = enum {
    /// Type has no drop logic (trivial destructor)
    Trivial,
    /// Type has simple drop logic (no panic, no side effects)
    Simple,
    /// Type has complex drop logic (may panic or have side effects)
    Complex,
    /// Type must not be dropped (e.g., leaked references)
    NoDrop,

    pub fn needsDrop(self: DropBehavior) bool {
        return self != .Trivial and self != .NoDrop;
    }

    pub fn mayPanic(self: DropBehavior) bool {
        return self == .Complex;
    }
};

/// Drop state for a variable
pub const DropState = enum {
    /// Not yet dropped
    Alive,
    /// Being dropped (in destructor)
    Dropping,
    /// Already dropped
    Dropped,
    /// Moved (drop responsibility transferred)
    Moved,
    /// Leaked (intentionally not dropped)
    Leaked,

    pub fn canDrop(self: DropState) bool {
        return self == .Alive;
    }

    pub fn canAccess(self: DropState) bool {
        return self == .Alive or self == .Dropping;
    }
};

/// Drop dependency (A must be dropped before B)
pub const DropDependency = struct {
    /// Variable that must be dropped first
    first: []const u8,
    /// Variable that must be dropped after
    second: []const u8,
    /// Reason for dependency
    reason: []const u8,
};

/// Drop safety tracker
pub const DropSafetyTracker = struct {
    allocator: std.mem.Allocator,
    /// Type drop behaviors
    type_behaviors: std.StringHashMap(DropBehavior),
    /// Variable drop states
    var_states: std.StringHashMap(DropState),
    /// Drop order dependencies
    dependencies: std.ArrayList(DropDependency),
    /// Variables in current drop order
    drop_order: std.ArrayList([]const u8),
    /// Scope depth
    scope_depth: usize,
    /// Scope drop lists (variables to drop when exiting scope)
    scope_drops: std.ArrayList(std.ArrayList([]const u8)),
    /// Errors
    errors: std.ArrayList(DropError),
    /// Warnings
    warnings: std.ArrayList(DropWarning),

    pub fn init(allocator: std.mem.Allocator) DropSafetyTracker {
        return .{
            .allocator = allocator,
            .type_behaviors = std.StringHashMap(DropBehavior).init(allocator),
            .var_states = std.StringHashMap(DropState).init(allocator),
            .dependencies = std.ArrayList(DropDependency).init(allocator),
            .drop_order = std.ArrayList([]const u8).init(allocator),
            .scope_depth = 0,
            .scope_drops = std.ArrayList(std.ArrayList([]const u8)).init(allocator),
            .errors = std.ArrayList(DropError).init(allocator),
            .warnings = std.ArrayList(DropWarning).init(allocator),
        };
    }

    pub fn deinit(self: *DropSafetyTracker) void {
        self.type_behaviors.deinit();
        self.var_states.deinit();
        self.dependencies.deinit();
        self.drop_order.deinit();

        for (self.scope_drops.items) |scope_list| {
            var owned_list = scope_list;
            owned_list.deinit();
        }
        self.scope_drops.deinit();

        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Register drop behavior for a type
    pub fn registerType(self: *DropSafetyTracker, type_name: []const u8, behavior: DropBehavior) !void {
        try self.type_behaviors.put(type_name, behavior);
    }

    /// Get drop behavior for a type
    pub fn getBehavior(self: *DropSafetyTracker, type_name: []const u8) DropBehavior {
        return self.type_behaviors.get(type_name) orelse .Simple;
    }

    /// Enter a new scope
    pub fn enterScope(self: *DropSafetyTracker) !void {
        self.scope_depth += 1;
        try self.scope_drops.append(std.ArrayList([]const u8).init(self.allocator));
    }

    /// Exit current scope (drop all variables in scope)
    pub fn exitScope(self: *DropSafetyTracker, loc: ast.SourceLocation) !void {
        if (self.scope_depth == 0) {
            try self.addError(.{
                .kind = .ScopeError,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot exit scope: no scope to exit",
                    .{},
                ),
                .location = loc,
                .variable_name = "",
            });
            return;
        }

        // Get variables to drop in this scope
        var scope_list = self.scope_drops.pop();
        defer scope_list.deinit();

        // Drop in reverse order (LIFO)
        var i = scope_list.items.len;
        while (i > 0) {
            i -= 1;
            const var_name = scope_list.items[i];
            try self.dropVariable(var_name, loc);
        }

        self.scope_depth -= 1;
    }

    /// Register a variable in current scope
    pub fn registerVariable(
        self: *DropSafetyTracker,
        var_name: []const u8,
        type_name: []const u8,
    ) !void {
        try self.var_states.put(var_name, .Alive);

        // Add to current scope's drop list if type needs drop
        const behavior = self.getBehavior(type_name);
        if (behavior.needsDrop()) {
            if (self.scope_drops.items.len > 0) {
                const current_scope = &self.scope_drops.items[self.scope_drops.items.len - 1];
                try current_scope.append(var_name);
            }
        }
    }

    /// Add drop dependency
    pub fn addDependency(
        self: *DropSafetyTracker,
        first: []const u8,
        second: []const u8,
        reason: []const u8,
    ) !void {
        try self.dependencies.append(.{
            .first = first,
            .second = second,
            .reason = reason,
        });
    }

    /// Drop a variable
    pub fn dropVariable(
        self: *DropSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.var_states.get(var_name) orelse {
            try self.addError(.{
                .kind = .DropUndefined,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot drop undefined variable '{s}'",
                    .{var_name},
                ),
                .location = loc,
                .variable_name = var_name,
            });
            return;
        };

        if (!state.canDrop()) {
            try self.addError(.{
                .kind = .DoubleDrop,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot drop variable '{s}' (state: {s})",
                    .{ var_name, @tagName(state) },
                ),
                .location = loc,
                .variable_name = var_name,
            });
            return;
        }

        // Check drop order dependencies
        try self.checkDropOrder(var_name, loc);

        // Mark as dropping
        try self.var_states.put(var_name, .Dropping);

        // Record drop order
        try self.drop_order.append(var_name);

        // Mark as dropped
        try self.var_states.put(var_name, .Dropped);
    }

    /// Check drop order constraints
    fn checkDropOrder(
        self: *DropSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        for (self.dependencies.items) |dep| {
            // Check if we're trying to drop `second` before `first`
            if (std.mem.eql(u8, dep.second, var_name)) {
                const first_state = self.var_states.get(dep.first) orelse continue;

                if (first_state.canDrop()) {
                    try self.addError(.{
                        .kind = .DropOrderViolation,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Drop order violation: '{s}' must be dropped before '{s}' ({s})",
                            .{ dep.first, dep.second, dep.reason },
                        ),
                        .location = loc,
                        .variable_name = var_name,
                    });
                }
            }
        }
    }

    /// Mark variable as moved (drop responsibility transferred)
    pub fn markMoved(self: *DropSafetyTracker, var_name: []const u8) !void {
        try self.var_states.put(var_name, .Moved);

        // Remove from scope drop list
        if (self.scope_drops.items.len > 0) {
            const current_scope = &self.scope_drops.items[self.scope_drops.items.len - 1];
            var i: usize = 0;
            while (i < current_scope.items.len) {
                if (std.mem.eql(u8, current_scope.items[i], var_name)) {
                    _ = current_scope.orderedRemove(i);
                    break;
                }
                i += 1;
            }
        }
    }

    /// Mark variable as leaked (intentionally not dropped)
    pub fn markLeaked(
        self: *DropSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        try self.var_states.put(var_name, .Leaked);

        try self.addWarning(.{
            .message = try std.fmt.allocPrint(
                self.allocator,
                "Variable '{s}' intentionally leaked (will not be dropped)",
                .{var_name},
            ),
            .location = loc,
        });
    }

    /// Check access during drop
    pub fn checkAccessDuringDrop(
        self: *DropSafetyTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.var_states.get(var_name) orelse return;

        if (state == .Dropping) {
            try self.addWarning(.{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Accessing variable '{s}' during its drop (may be unsafe)",
                    .{var_name},
                ),
                .location = loc,
            });
        } else if (state == .Dropped) {
            try self.addError(.{
                .kind = .UseAfterDrop,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Use of dropped variable '{s}'",
                    .{var_name},
                ),
                .location = loc,
                .variable_name = var_name,
            });
        }
    }

    /// Verify drop implementation doesn't panic
    pub fn checkDropPanic(
        self: *DropSafetyTracker,
        type_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const behavior = self.getBehavior(type_name);

        if (behavior.mayPanic()) {
            try self.addWarning(.{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Type '{s}' has complex drop logic that may panic",
                    .{type_name},
                ),
                .location = loc,
            });
        }
    }

    /// Get drop order for debugging
    pub fn getDropOrder(self: *DropSafetyTracker) []const []const u8 {
        return self.drop_order.items;
    }

    fn addError(self: *DropSafetyTracker, err: DropError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *DropSafetyTracker, warning: DropWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *DropSafetyTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Drop error
pub const DropError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    variable_name: []const u8,

    pub const ErrorKind = enum {
        DoubleDrop,
        UseAfterDrop,
        DropOrderViolation,
        DropUndefined,
        ScopeError,
        DropPanic,
    };
};

/// Drop warning
pub const DropWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Built-in Type Drop Behaviors
// ============================================================================

pub const BuiltinDropBehaviors = struct {
    pub fn register(tracker: *DropSafetyTracker) !void {
        // Primitives are trivial
        try tracker.registerType("Int", .Trivial);
        try tracker.registerType("U8", .Trivial);
        try tracker.registerType("U16", .Trivial);
        try tracker.registerType("U32", .Trivial);
        try tracker.registerType("U64", .Trivial);
        try tracker.registerType("I8", .Trivial);
        try tracker.registerType("I16", .Trivial);
        try tracker.registerType("I32", .Trivial);
        try tracker.registerType("I64", .Trivial);
        try tracker.registerType("F32", .Trivial);
        try tracker.registerType("F64", .Trivial);
        try tracker.registerType("Bool", .Trivial);

        // String needs drop (heap allocation)
        try tracker.registerType("String", .Simple);

        // Collections need drop
        try tracker.registerType("Array", .Simple);
        try tracker.registerType("Vec", .Simple);
        try tracker.registerType("HashMap", .Simple);

        // Smart pointers need drop
        try tracker.registerType("Box", .Simple);
        try tracker.registerType("Rc", .Simple);
        try tracker.registerType("Arc", .Simple);

        // Synchronization primitives may panic on drop
        try tracker.registerType("Mutex", .Complex);
        try tracker.registerType("RwLock", .Complex);

        // File handles need drop
        try tracker.registerType("File", .Simple);
        try tracker.registerType("Socket", .Simple);
    }
};

// ============================================================================
// RAII Guard Pattern
// ============================================================================

pub const ScopeGuard = struct {
    tracker: *DropSafetyTracker,
    var_name: []const u8,
    dropped: bool,

    pub fn init(tracker: *DropSafetyTracker, var_name: []const u8) ScopeGuard {
        return .{
            .tracker = tracker,
            .var_name = var_name,
            .dropped = false,
        };
    }

    pub fn release(self: *ScopeGuard) void {
        self.dropped = true;
    }

    pub fn deinit(self: *ScopeGuard, loc: ast.SourceLocation) !void {
        if (!self.dropped) {
            try self.tracker.dropVariable(self.var_name, loc);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "drop behavior" {
    const trivial = DropBehavior.Trivial;
    const simple = DropBehavior.Simple;
    const complex = DropBehavior.Complex;

    try std.testing.expect(!trivial.needsDrop());
    try std.testing.expect(simple.needsDrop());
    try std.testing.expect(!simple.mayPanic());
    try std.testing.expect(complex.mayPanic());
}

test "drop state" {
    const alive = DropState.Alive;
    const dropped = DropState.Dropped;

    try std.testing.expect(alive.canDrop());
    try std.testing.expect(alive.canAccess());

    try std.testing.expect(!dropped.canDrop());
    try std.testing.expect(!dropped.canAccess());
}

test "drop safety tracker basic" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Alive);
}

test "double drop detection" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Drop once (OK)
    try tracker.dropVariable("s", loc);

    // Try to drop again (should error)
    try tracker.dropVariable("s", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "drop order dependency" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("Handle", .Simple);
    try tracker.registerVariable("a", "Handle");
    try tracker.registerVariable("b", "Handle");

    // b depends on a (a must be dropped first)
    try tracker.addDependency("a", "b", "b references a");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Try to drop b before a (should error)
    try tracker.dropVariable("b", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "move prevents drop" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    // Mark as moved
    try tracker.markMoved("s");

    const state = tracker.var_states.get("s");
    try std.testing.expect(state.? == .Moved);
}

test "scope drop order" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.enterScope();

    try tracker.registerType("Int", .Trivial);
    try tracker.registerType("String", .Simple);

    try tracker.registerVariable("a", "String");
    try tracker.registerVariable("b", "String");
    try tracker.registerVariable("c", "String");

    // Exit scope - should drop in reverse order: c, b, a
    try tracker.exitScope(loc);

    const drop_order = tracker.getDropOrder();
    try std.testing.expect(drop_order.len == 3);
    try std.testing.expect(std.mem.eql(u8, drop_order[0], "c"));
    try std.testing.expect(std.mem.eql(u8, drop_order[1], "b"));
    try std.testing.expect(std.mem.eql(u8, drop_order[2], "a"));
}

test "use after drop" {
    var tracker = DropSafetyTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.registerType("String", .Simple);
    try tracker.registerVariable("s", "String");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.dropVariable("s", loc);

    // Try to access after drop
    try tracker.checkAccessDuringDrop("s", loc);

    try std.testing.expect(tracker.hasErrors());
}
