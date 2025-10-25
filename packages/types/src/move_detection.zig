const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Move semantics for a type
pub const MoveSemantics = enum {
    /// Type is Copy (can be implicitly copied)
    Copy,
    /// Type is Move-only (must be explicitly moved)
    Move,
    /// Type cannot be moved (e.g., contains self-references)
    NonMovable,

    pub fn canCopy(self: MoveSemantics) bool {
        return self == .Copy;
    }

    pub fn canMove(self: MoveSemantics) bool {
        return self == .Move or self == .Copy;
    }
};

/// Variable state for move tracking
pub const MoveState = enum {
    /// Variable is fully initialized and usable
    Initialized,
    /// Variable has been partially moved from
    PartiallyMoved,
    /// Variable has been fully moved from
    FullyMoved,
    /// Variable is uninitialized
    Uninitialized,
    /// Variable has been conditionally moved
    ConditionallyMoved,

    pub fn canUse(self: MoveState) bool {
        return self == .Initialized;
    }

    pub fn canMove(self: MoveState) bool {
        return self == .Initialized;
    }

    pub fn canPartiallyMove(self: MoveState) bool {
        return self == .Initialized or self == .PartiallyMoved;
    }
};

/// Field-level move tracking for structs
pub const FieldMoveState = struct {
    field_name: []const u8,
    state: MoveState,
};

/// Move tracker for program analysis
pub const MoveTracker = struct {
    allocator: std.mem.Allocator,
    /// Type move semantics
    type_semantics: std.StringHashMap(MoveSemantics),
    /// Variable move states
    var_states: std.StringHashMap(MoveState),
    /// Field-level move tracking (for partial moves)
    field_states: std.StringHashMap(std.ArrayList(FieldMoveState)),
    /// Move history (for better error messages)
    move_history: std.StringHashMap(ast.SourceLocation),
    /// Errors
    errors: std.ArrayList(MoveError),
    /// Warnings
    warnings: std.ArrayList(MoveWarning),

    pub fn init(allocator: std.mem.Allocator) MoveTracker {
        return .{
            .allocator = allocator,
            .type_semantics = std.StringHashMap(MoveSemantics).init(allocator),
            .var_states = std.StringHashMap(MoveState).init(allocator),
            .field_states = std.StringHashMap(std.ArrayList(FieldMoveState)).init(allocator),
            .move_history = std.StringHashMap(ast.SourceLocation).init(allocator),
            .errors = std.ArrayList(MoveError).init(allocator),
            .warnings = std.ArrayList(MoveWarning).init(allocator),
        };
    }

    pub fn deinit(self: *MoveTracker) void {
        self.type_semantics.deinit();
        self.var_states.deinit();

        var iter = self.field_states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.field_states.deinit();

        self.move_history.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    /// Register type move semantics
    pub fn registerType(self: *MoveTracker, type_name: []const u8, semantics: MoveSemantics) !void {
        try self.type_semantics.put(type_name, semantics);
    }

    /// Get move semantics for a type
    pub fn getSemantics(self: *MoveTracker, type_name: []const u8) MoveSemantics {
        return self.type_semantics.get(type_name) orelse .Move; // Default to Move
    }

    /// Initialize a variable
    pub fn initialize(self: *MoveTracker, var_name: []const u8) !void {
        try self.var_states.put(var_name, .Initialized);
    }

    /// Get move state for a variable
    pub fn getState(self: *MoveTracker, var_name: []const u8) MoveState {
        return self.var_states.get(var_name) orelse .Uninitialized;
    }

    /// Check if variable can be used
    pub fn checkUse(
        self: *MoveTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.getState(var_name);

        if (!state.canUse()) {
            const move_loc = self.move_history.get(var_name);

            if (move_loc) |ml| {
                try self.addError(.{
                    .kind = .UseAfterMove,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Use of moved variable '{s}' (moved at {s}:{}:{})",
                        .{ var_name, ml.file, ml.line, ml.column },
                    ),
                    .location = loc,
                    .variable_name = var_name,
                    .move_location = move_loc,
                });
            } else {
                try self.addError(.{
                    .kind = .UseAfterMove,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Use of moved variable '{s}'",
                        .{var_name},
                    ),
                    .location = loc,
                    .variable_name = var_name,
                    .move_location = null,
                });
            }
        }
    }

    /// Move value from one variable to another
    pub fn moveValue(
        self: *MoveTracker,
        from: []const u8,
        to: []const u8,
        type_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const semantics = self.getSemantics(type_name);

        // Copy types don't actually move
        if (semantics.canCopy()) {
            try self.initialize(to);
            return;
        }

        // Check if source can be moved
        const state = self.getState(from);
        if (!state.canMove()) {
            try self.addError(.{
                .kind = .MoveFromMovedValue,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot move from '{s}' (state: {s})",
                    .{ from, @tagName(state) },
                ),
                .location = loc,
                .variable_name = from,
                .move_location = null,
            });
            return;
        }

        // Mark source as moved
        try self.var_states.put(from, .FullyMoved);
        try self.move_history.put(from, loc);

        // Initialize destination
        try self.initialize(to);
    }

    /// Move a field from a struct
    pub fn moveField(
        self: *MoveTracker,
        struct_var: []const u8,
        field_name: []const u8,
        to: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.getState(struct_var);

        if (!state.canPartiallyMove()) {
            try self.addError(.{
                .kind = .MoveFromMovedValue,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot move field from moved struct '{s}'",
                    .{struct_var},
                ),
                .location = loc,
                .variable_name = struct_var,
                .move_location = null,
            });
            return;
        }

        // Track field-level move
        var fields = self.field_states.get(struct_var) orelse blk: {
            var new_fields = std.ArrayList(FieldMoveState).init(self.allocator);
            try self.field_states.put(struct_var, new_fields);
            break :blk self.field_states.get(struct_var).?;
        };

        // Check if field already moved
        for (fields.items) |field_state| {
            if (std.mem.eql(u8, field_state.field_name, field_name)) {
                if (field_state.state == .FullyMoved) {
                    try self.addError(.{
                        .kind = .UseAfterMove,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Field '{s}.{s}' has already been moved",
                            .{ struct_var, field_name },
                        ),
                        .location = loc,
                        .variable_name = struct_var,
                        .move_location = null,
                    });
                    return;
                }
            }
        }

        // Record field move
        try fields.append(.{
            .field_name = field_name,
            .state = .FullyMoved,
        });

        // Mark struct as partially moved
        try self.var_states.put(struct_var, .PartiallyMoved);

        // Initialize destination
        try self.initialize(to);
    }

    /// Check if all fields of a struct have been moved
    fn allFieldsMoved(self: *MoveTracker, struct_var: []const u8, expected_fields: []const []const u8) bool {
        const fields = self.field_states.get(struct_var) orelse return false;

        for (expected_fields) |expected_field| {
            var found = false;
            for (fields.items) |field_state| {
                if (std.mem.eql(u8, field_state.field_name, expected_field) and
                    field_state.state == .FullyMoved)
                {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    /// Check conditional move (e.g., in if/match branches)
    pub fn conditionalMove(
        self: *MoveTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const state = self.getState(var_name);

        if (state == .ConditionallyMoved) {
            // Already conditionally moved - now it's definitely moved
            try self.var_states.put(var_name, .FullyMoved);
            try self.move_history.put(var_name, loc);
        } else if (state == .Initialized) {
            // First conditional move
            try self.var_states.put(var_name, .ConditionallyMoved);
        } else {
            try self.addError(.{
                .kind = .MoveFromMovedValue,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cannot conditionally move from '{s}' (state: {s})",
                    .{ var_name, @tagName(state) },
                ),
                .location = loc,
                .variable_name = var_name,
                .move_location = null,
            });
        }
    }

    /// Merge move states from different control flow paths
    pub fn mergePaths(
        self: *MoveTracker,
        var_name: []const u8,
        state1: MoveState,
        state2: MoveState,
    ) !void {
        const merged = switch (state1) {
            .Initialized => switch (state2) {
                .Initialized => MoveState.Initialized,
                .FullyMoved => MoveState.ConditionallyMoved,
                .ConditionallyMoved => MoveState.ConditionallyMoved,
                else => state2,
            },
            .FullyMoved => switch (state2) {
                .Initialized => MoveState.ConditionallyMoved,
                .FullyMoved => MoveState.FullyMoved,
                else => MoveState.FullyMoved,
            },
            .ConditionallyMoved => MoveState.ConditionallyMoved,
            else => state1,
        };

        try self.var_states.put(var_name, merged);
    }

    /// Reinitialize a moved variable
    pub fn reinitialize(
        self: *MoveTracker,
        var_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        _ = loc;
        try self.var_states.put(var_name, .Initialized);
        _ = self.move_history.remove(var_name);

        // Clear field states
        if (self.field_states.get(var_name)) |fields| {
            var owned_fields = fields;
            owned_fields.clearRetainingCapacity();
        }
    }

    fn addError(self: *MoveTracker, err: MoveError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *MoveTracker, warning: MoveWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *MoveTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Move error
pub const MoveError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    variable_name: []const u8,
    move_location: ?ast.SourceLocation,

    pub const ErrorKind = enum {
        UseAfterMove,
        MoveFromMovedValue,
        PartialMoveError,
        ConditionalMoveError,
        DoubleMove,
    };
};

/// Move warning
pub const MoveWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Built-in Type Move Semantics
// ============================================================================

pub const BuiltinMoveSemantics = struct {
    pub fn register(tracker: *MoveTracker) !void {
        // Primitive types are Copy
        try tracker.registerType("Int", .Copy);
        try tracker.registerType("U8", .Copy);
        try tracker.registerType("U16", .Copy);
        try tracker.registerType("U32", .Copy);
        try tracker.registerType("U64", .Copy);
        try tracker.registerType("I8", .Copy);
        try tracker.registerType("I16", .Copy);
        try tracker.registerType("I32", .Copy);
        try tracker.registerType("I64", .Copy);
        try tracker.registerType("F32", .Copy);
        try tracker.registerType("F64", .Copy);
        try tracker.registerType("Bool", .Copy);

        // String is Move-only (owns heap data)
        try tracker.registerType("String", .Move);

        // Arrays/Slices depend on element type
        // For simplicity, treat as Move-only
        try tracker.registerType("Array", .Move);
        try tracker.registerType("Slice", .Copy); // Slice is just a view

        // Smart pointers are Move-only
        try tracker.registerType("Box", .Move);
        try tracker.registerType("Rc", .Copy); // Reference counted can be copied
        try tracker.registerType("Arc", .Copy); // Atomic reference counted
        try tracker.registerType("Mutex", .Move);
        try tracker.registerType("RwLock", .Move);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "move semantics" {
    const copy = MoveSemantics.Copy;
    const move = MoveSemantics.Move;
    const non_movable = MoveSemantics.NonMovable;

    try std.testing.expect(copy.canCopy());
    try std.testing.expect(copy.canMove());

    try std.testing.expect(!move.canCopy());
    try std.testing.expect(move.canMove());

    try std.testing.expect(!non_movable.canCopy());
    try std.testing.expect(!non_movable.canMove());
}

test "move state" {
    const initialized = MoveState.Initialized;
    const moved = MoveState.FullyMoved;

    try std.testing.expect(initialized.canUse());
    try std.testing.expect(initialized.canMove());

    try std.testing.expect(!moved.canUse());
    try std.testing.expect(!moved.canMove());
}

test "move tracker basic" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const state = tracker.getState("x");
    try std.testing.expect(state == .Initialized);
}

test "use after move detection" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move x to y
    try tracker.moveValue("x", "y", "String", loc);

    // Try to use x (should error)
    try tracker.checkUse("x", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "copy type does not move" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("Int", .Copy);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // "Move" x to y (but it's Copy, so x is still usable)
    try tracker.moveValue("x", "y", "Int", loc);

    // x should still be usable
    try tracker.checkUse("x", loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "partial move" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("s");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move field from struct
    try tracker.moveField("s", "field1", "x", loc);

    const state = tracker.getState("s");
    try std.testing.expect(state == .PartiallyMoved);
}

test "conditional move" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // First conditional move
    try tracker.conditionalMove("x", loc);

    const state = tracker.getState("x");
    try std.testing.expect(state == .ConditionallyMoved);
}

test "reinitialize after move" {
    var tracker = MoveTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.initialize("x");
    try tracker.registerType("String", .Move);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    // Move x
    try tracker.moveValue("x", "y", "String", loc);

    // Reinitialize x
    try tracker.reinitialize("x", loc);

    // x should be usable again
    try tracker.checkUse("x", loc);

    try std.testing.expect(!tracker.hasErrors());
}
