const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Lifetime identifier
pub const Lifetime = struct {
    name: []const u8,
    scope_id: u32,

    pub fn init(name: []const u8, scope_id: u32) Lifetime {
        return .{ .name = name, .scope_id = scope_id };
    }

    pub fn static() Lifetime {
        return .{ .name = "static", .scope_id = 0 };
    }

    pub fn equals(self: Lifetime, other: Lifetime) bool {
        return self.scope_id == other.scope_id and std.mem.eql(u8, self.name, other.name);
    }

    /// Check if this lifetime outlives another
    pub fn outlives(self: Lifetime, other: Lifetime) bool {
        // Static lifetime outlives everything
        if (self.scope_id == 0) return true;
        if (other.scope_id == 0) return false;

        // Lower scope_id means outer scope (longer lifetime)
        return self.scope_id <= other.scope_id;
    }
};

/// Type with lifetime annotation
pub const TypeWithLifetime = struct {
    base_type: Type,
    lifetime: Lifetime,
    is_reference: bool,
    is_mutable: bool,

    pub fn init(base: Type, lifetime: Lifetime) TypeWithLifetime {
        return .{
            .base_type = base,
            .lifetime = lifetime,
            .is_reference = false,
            .is_mutable = false,
        };
    }

    pub fn reference(base: Type, lifetime: Lifetime) TypeWithLifetime {
        return .{
            .base_type = base,
            .lifetime = lifetime,
            .is_reference = true,
            .is_mutable = false,
        };
    }

    pub fn mutableReference(base: Type, lifetime: Lifetime) TypeWithLifetime {
        return .{
            .base_type = base,
            .lifetime = lifetime,
            .is_reference = true,
            .is_mutable = true,
        };
    }

    pub fn owned(base: Type) TypeWithLifetime {
        return .{
            .base_type = base,
            .lifetime = Lifetime.static(),
            .is_reference = false,
            .is_mutable = true,
        };
    }
};

/// Lifetime relationship
pub const LifetimeConstraint = struct {
    longer: Lifetime,
    shorter: Lifetime,

    pub fn init(longer: Lifetime, shorter: Lifetime) LifetimeConstraint {
        return .{ .longer = longer, .shorter = shorter };
    }

    pub fn check(self: LifetimeConstraint) bool {
        return self.longer.outlives(self.shorter);
    }
};

/// Variable ownership state
pub const OwnershipState = enum {
    /// Variable owns the value
    Owned,
    /// Variable is a shared reference
    Borrowed,
    /// Variable is a mutable reference
    BorrowedMut,
    /// Value has been moved out
    Moved,
    /// Value has been dropped
    Dropped,

    pub fn canUse(self: OwnershipState) bool {
        return self != .Moved and self != .Dropped;
    }

    pub fn canMove(self: OwnershipState) bool {
        return self == .Owned;
    }

    pub fn canBorrow(self: OwnershipState) bool {
        return self == .Owned or self == .Borrowed;
    }

    pub fn canBorrowMut(self: OwnershipState) bool {
        return self == .Owned;
    }
};

/// Lifetime analysis tracker
pub const LifetimeTracker = struct {
    allocator: std.mem.Allocator,
    /// Current scope depth
    scope_depth: u32,
    /// Next scope ID
    next_scope_id: u32,
    /// Variable lifetimes
    var_lifetimes: std.StringHashMap(Lifetime),
    /// Variable ownership states
    var_ownership: std.StringHashMap(OwnershipState),
    /// Active borrows (var_name -> borrowed_from)
    active_borrows: std.StringHashMap([]const u8),
    /// Lifetime constraints
    constraints: std.ArrayList(LifetimeConstraint),
    /// Errors
    errors: std.ArrayList(LifetimeError),
    /// Warnings
    warnings: std.ArrayList(LifetimeWarning),

    pub fn init(allocator: std.mem.Allocator) LifetimeTracker {
        return .{
            .allocator = allocator,
            .scope_depth = 0,
            .next_scope_id = 1,
            .var_lifetimes = std.StringHashMap(Lifetime).init(allocator),
            .var_ownership = std.StringHashMap(OwnershipState).init(allocator),
            .active_borrows = std.StringHashMap([]const u8).init(allocator),
            .constraints = std.ArrayList(LifetimeConstraint).init(allocator),
            .errors = std.ArrayList(LifetimeError).init(allocator),
            .warnings = std.ArrayList(LifetimeWarning).init(allocator),
        };
    }

    pub fn deinit(self: *LifetimeTracker) void {
        self.var_lifetimes.deinit();
        self.var_ownership.deinit();
        self.active_borrows.deinit();
        self.constraints.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Enter a new scope
    pub fn enterScope(self: *LifetimeTracker) u32 {
        self.scope_depth += 1;
        const scope_id = self.next_scope_id;
        self.next_scope_id += 1;
        return scope_id;
    }

    /// Exit current scope
    pub fn exitScope(self: *LifetimeTracker, scope_id: u32) !void {
        // Check for dangling references
        var iter = self.var_lifetimes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.scope_id == scope_id) {
                // Check if this variable is borrowed elsewhere
                var borrow_iter = self.active_borrows.iterator();
                while (borrow_iter.next()) |borrow| {
                    if (std.mem.eql(u8, borrow.value_ptr.*, entry.key_ptr.*)) {
                        try self.addError(.{
                            .kind = .DanglingReference,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Variable '{s}' goes out of scope but is still borrowed by '{s}'",
                                .{ entry.key_ptr.*, borrow.key_ptr.* },
                            ),
                            .location = null,
                            .variable_name = entry.key_ptr.*,
                        });
                    }
                }
            }
        }

        if (self.scope_depth > 0) {
            self.scope_depth -= 1;
        }
    }

    /// Declare a new variable with ownership
    pub fn declareOwned(self: *LifetimeTracker, var_name: []const u8, scope_id: u32) !void {
        const lifetime = Lifetime.init(var_name, scope_id);
        try self.var_lifetimes.put(var_name, lifetime);
        try self.var_ownership.put(var_name, .Owned);
    }

    /// Create a shared borrow
    pub fn createBorrow(
        self: *LifetimeTracker,
        borrow_name: []const u8,
        source_var: []const u8,
        scope_id: u32,
        loc: ast.SourceLocation,
    ) !void {
        const source_state = self.var_ownership.get(source_var) orelse {
            try self.addError(.{
                .kind = .UseOfUndefined,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow undefined variable '{s}'",
                    .{source_var},
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        };

        if (!source_state.canBorrow()) {
            try self.addError(.{
                .kind = .CannotBorrow,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow '{s}' (state: {s})",
                    .{ source_var, @tagName(source_state) },
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        }

        // Check for conflicting mutable borrows
        if (self.hasMutableBorrow(source_var)) {
            try self.addError(.{
                .kind = .ConflictingBorrow,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot create shared borrow while mutable borrow of '{s}' exists",
                    .{source_var},
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        }

        const source_lifetime = self.var_lifetimes.get(source_var).?;
        const borrow_lifetime = Lifetime.init(borrow_name, scope_id);

        try self.var_lifetimes.put(borrow_name, borrow_lifetime);
        try self.var_ownership.put(borrow_name, .Borrowed);
        try self.active_borrows.put(borrow_name, source_var);

        // Add constraint: source must outlive borrow
        try self.constraints.append(LifetimeConstraint.init(source_lifetime, borrow_lifetime));
    }

    /// Create a mutable borrow
    pub fn createBorrowMut(
        self: *LifetimeTracker,
        borrow_name: []const u8,
        source_var: []const u8,
        scope_id: u32,
        loc: ast.SourceLocation,
    ) !void {
        const source_state = self.var_ownership.get(source_var) orelse {
            try self.addError(.{
                .kind = .UseOfUndefined,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot borrow undefined variable '{s}'",
                    .{source_var},
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        };

        if (!source_state.canBorrowMut()) {
            try self.addError(.{
                .kind = .CannotBorrowMut,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot mutably borrow '{s}' (state: {s})",
                    .{ source_var, @tagName(source_state) },
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        }

        // Check for any existing borrows
        if (self.hasAnyBorrow(source_var)) {
            try self.addError(.{
                .kind = .ConflictingBorrow,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot create mutable borrow while other borrows of '{s}' exist",
                    .{source_var},
                ),
                .location = loc,
                .variable_name = source_var,
            });
            return;
        }

        const source_lifetime = self.var_lifetimes.get(source_var).?;
        const borrow_lifetime = Lifetime.init(borrow_name, scope_id);

        try self.var_lifetimes.put(borrow_name, borrow_lifetime);
        try self.var_ownership.put(borrow_name, .BorrowedMut);
        try self.active_borrows.put(borrow_name, source_var);

        try self.constraints.append(LifetimeConstraint.init(source_lifetime, borrow_lifetime));
    }

    /// Move value from one variable to another
    pub fn moveValue(
        self: *LifetimeTracker,
        from: []const u8,
        to: []const u8,
        scope_id: u32,
        loc: ast.SourceLocation,
    ) !void {
        const source_state = self.var_ownership.get(from) orelse {
            try self.addError(.{
                .kind = .UseOfUndefined,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot move from undefined variable '{s}'",
                    .{from},
                ),
                .location = loc,
                .variable_name = from,
            });
            return;
        };

        if (!source_state.canMove()) {
            try self.addError(.{
                .kind = .UseAfterMove,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot move from '{s}' (state: {s})",
                    .{ from, @tagName(source_state) },
                ),
                .location = loc,
                .variable_name = from,
            });
            return;
        }

        // Mark source as moved
        try self.var_ownership.put(from, .Moved);

        // Create new owned variable
        const new_lifetime = Lifetime.init(to, scope_id);
        try self.var_lifetimes.put(to, new_lifetime);
        try self.var_ownership.put(to, .Owned);
    }

    /// Check if variable can be used
    pub fn checkUse(
        self: *LifetimeTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.var_ownership.get(var_name) orelse {
            try self.addError(.{
                .kind = .UseOfUndefined,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Use of undefined variable '{s}'",
                    .{var_name},
                ),
                .location = loc,
                .variable_name = var_name,
            });
            return;
        };

        if (!state.canUse()) {
            try self.addError(.{
                .kind = .UseAfterMove,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Use of variable '{s}' after move",
                    .{var_name},
                ),
                .location = loc,
                .variable_name = var_name,
            });
        }
    }

    /// Check all lifetime constraints
    pub fn checkConstraints(self: *LifetimeTracker) !void {
        for (self.constraints.items) |constraint| {
            if (!constraint.check()) {
                try self.addError(.{
                    .kind = .LifetimeViolation,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Lifetime constraint violated: '{s}' does not outlive '{s}'",
                        .{ constraint.longer.name, constraint.shorter.name },
                    ),
                    .location = null,
                    .variable_name = constraint.shorter.name,
                });
            }
        }
    }

    fn hasAnyBorrow(self: *LifetimeTracker, source_var: []const u8) bool {
        var iter = self.active_borrows.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, source_var)) {
                return true;
            }
        }
        return false;
    }

    fn hasMutableBorrow(self: *LifetimeTracker, source_var: []const u8) bool {
        var iter = self.active_borrows.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, source_var)) {
                const state = self.var_ownership.get(entry.key_ptr.*) orelse continue;
                if (state == .BorrowedMut) {
                    return true;
                }
            }
        }
        return false;
    }

    fn addError(self: *LifetimeTracker, err: LifetimeError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *LifetimeTracker, warning: LifetimeWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *LifetimeTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Lifetime error
pub const LifetimeError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ?ast.SourceLocation,
    variable_name: []const u8,

    pub const ErrorKind = enum {
        DanglingReference,
        UseAfterMove,
        UseAfterFree,
        ConflictingBorrow,
        CannotBorrow,
        CannotBorrowMut,
        LifetimeViolation,
        UseOfUndefined,
    };
};

/// Lifetime warning
pub const LifetimeWarning = struct {
    message: []const u8,
    location: ?ast.SourceLocation,
};

// ============================================================================
// Tests
// ============================================================================

test "lifetime outlives" {
    const outer = Lifetime.init("outer", 1);
    const inner = Lifetime.init("inner", 2);
    const static = Lifetime.static();

    try std.testing.expect(outer.outlives(inner));
    try std.testing.expect(!inner.outlives(outer));
    try std.testing.expect(static.outlives(outer));
    try std.testing.expect(static.outlives(inner));
}

test "ownership state" {
    const owned = OwnershipState.Owned;
    const moved = OwnershipState.Moved;

    try std.testing.expect(owned.canUse());
    try std.testing.expect(owned.canMove());
    try std.testing.expect(!moved.canUse());
    try std.testing.expect(!moved.canMove());
}

test "lifetime tracker basic" {
    var tracker = LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const state = tracker.var_ownership.get("x");
    try std.testing.expect(state.? == .Owned);
}

test "move detection" {
    var tracker = LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move x to y
    try tracker.moveValue("x", "y", scope1, loc);

    // Check that x cannot be used
    try tracker.checkUse("x", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "borrow creation" {
    var tracker = LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create shared borrow
    try tracker.createBorrow("r", "x", scope1, loc);

    const state = tracker.var_ownership.get("r");
    try std.testing.expect(state.? == .Borrowed);
}

test "conflicting borrows" {
    var tracker = LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create mutable borrow
    try tracker.createBorrowMut("r1", "x", scope1, loc);

    // Try to create another borrow (should fail)
    try tracker.createBorrow("r2", "x", scope1, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "dangling reference detection" {
    var tracker = LifetimeTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const scope1 = tracker.enterScope();
    try tracker.declareOwned("x", scope1);

    const scope2 = tracker.enterScope();
    try tracker.declareOwned("y", scope2);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Create borrow from y in outer scope
    try tracker.createBorrow("r", "y", scope1, loc);

    // Exit inner scope (y goes out of scope)
    try tracker.exitScope(scope2);

    try std.testing.expect(tracker.hasErrors());
}
