const std = @import("std");
const ast = @import("ast");
const type_system = @import("types");
const MoveTracker = type_system.MoveTracker;
const MoveSemantics = type_system.MoveSemantics;
const MoveState = type_system.MoveState;
const BuiltinMoveSemantics = type_system.BuiltinMoveSemantics;

/// Integration layer for move semantics checking in the compiler.
///
/// This module bridges the move detection system with the code generator,
/// providing:
/// - Move semantics checking for the entire program
/// - Use-after-move detection
/// - Partial move tracking
/// - Error reporting
pub const MoveChecker = struct {
    allocator: std.mem.Allocator,
    /// Move tracker for analysis
    tracker: MoveTracker,
    /// Errors encountered during checking
    errors: std.ArrayList(MoveCheckError),

    pub const MoveCheckError = struct {
        message: []const u8,
        location: ast.SourceLocation,
        kind: ErrorKind,

        pub const ErrorKind = enum {
            UseAfterMove,
            MoveFromMovedValue,
            PartialMoveNotAllowed,
            ConditionalMoveConflict,
        };
    };

    pub fn init(allocator: std.mem.Allocator) MoveChecker {
        return .{
            .allocator = allocator,
            .tracker = MoveTracker.init(allocator),
            .errors = std.ArrayList(MoveCheckError).init(allocator),
        };
    }

    pub fn deinit(self: *MoveChecker) void {
        self.tracker.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit();
    }

    /// Check move semantics for an entire program
    pub fn checkProgram(self: *MoveChecker, program: *const ast.Program) !void {
        // Register built-in type move semantics
        try BuiltinMoveSemantics.register(&self.tracker);

        // Check each statement in the program
        for (program.statements) |stmt| {
            try self.checkStatement(stmt);
        }

        // Transfer errors from tracker
        for (self.tracker.errors.items) |tracker_err| {
            try self.errors.append(.{
                .message = try self.allocator.dupe(u8, tracker_err.message),
                .location = tracker_err.location,
                .kind = switch (tracker_err.kind) {
                    .UseAfterMove => .UseAfterMove,
                    .MoveFromMovedValue => .MoveFromMovedValue,
                    .PartialMoveError => .PartialMoveNotAllowed,
                    .ConditionalMoveError, .DoubleMove => .ConditionalMoveConflict,
                },
            });
        }
    }

    /// Check a statement for move errors
    fn checkStatement(self: *MoveChecker, stmt: ast.Stmt) !void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                try self.checkFunction(fn_decl);
            },
            .LetDecl => |let_decl| {
                // Initialize the variable
                try self.tracker.initialize(let_decl.name);

                // Check initializer if present
                if (let_decl.initializer) |initializer| {
                    const init_expr = @as(*const ast.Expr, @ptrCast(initializer));
                    try self.checkExpression(init_expr);
                }
            },
            .ExprStmt => |expr_stmt| {
                const expr = @as(*const ast.Expr, @ptrCast(&expr_stmt.expression));
                try self.checkExpression(expr);
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    const expr = @as(*const ast.Expr, @ptrCast(val));
                    try self.checkExpression(expr);
                }
            },
            .IfStmt => |if_stmt| {
                // Check condition
                const cond_expr = @as(*const ast.Expr, @ptrCast(&if_stmt.condition));
                try self.checkExpression(cond_expr);

                // Save state before branching
                const saved_states = try self.saveStates();
                defer self.freeStates(saved_states);

                // Check then branch
                try self.checkBlock(if_stmt.then_block);
                const then_states = try self.saveStates();

                // Restore state for else branch
                try self.restoreStates(saved_states);

                // Check else branch if present
                if (if_stmt.else_block) |else_block| {
                    try self.checkBlock(else_block);
                }

                // Merge states from both branches
                try self.mergeStates(then_states);
                self.freeStates(then_states);
            },
            .WhileStmt => |while_stmt| {
                const cond_expr = @as(*const ast.Expr, @ptrCast(&while_stmt.condition));
                try self.checkExpression(cond_expr);
                try self.checkBlock(while_stmt.body);
            },
            .ForStmt => |for_stmt| {
                const iter_expr = @as(*const ast.Expr, @ptrCast(&for_stmt.iterable));
                try self.checkExpression(iter_expr);

                // Initialize loop variable
                try self.tracker.initialize(for_stmt.binding);

                try self.checkBlock(for_stmt.body);
            },
            .MatchStmt => |match_stmt| {
                // Check discriminant
                const disc_expr = @as(*const ast.Expr, @ptrCast(&match_stmt.discriminant));
                try self.checkExpression(disc_expr);

                // Check each arm
                for (match_stmt.arms) |arm| {
                    try self.checkExpression(arm.body);
                }
            },
            else => {
                // Other statement types
            },
        }
    }

    /// Check a function for move errors
    fn checkFunction(self: *MoveChecker, fn_decl: *const ast.FnDecl) !void {
        // Initialize parameters
        for (fn_decl.params) |param| {
            try self.tracker.initialize(param.name);
        }

        // Check function body
        for (fn_decl.body.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check a block for move errors
    fn checkBlock(self: *MoveChecker, block: *const ast.BlockStmt) !void {
        for (block.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check an expression for move errors
    fn checkExpression(self: *MoveChecker, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .Identifier => |ident| {
                // Check if variable can be used
                const loc = ast.SourceLocation{
                    .line = 0,
                    .column = 0,
                    .file = "unknown",
                };
                try self.tracker.checkUse(ident.name, loc);
            },
            .BinaryExpr => |bin| {
                try self.checkExpression(bin.left);
                try self.checkExpression(bin.right);
            },
            .UnaryExpr => |un| {
                try self.checkExpression(un.operand);
            },
            .CallExpr => |call| {
                try self.checkExpression(call.callee);
                for (call.arguments) |arg| {
                    try self.checkExpression(arg);

                    // If argument is an identifier, it might be moved
                    if (arg.* == .Identifier) {
                        const arg_name = arg.Identifier.name;
                        const type_name = "unknown"; // TODO: Get actual type
                        const loc = ast.SourceLocation{
                            .line = 0,
                            .column = 0,
                            .file = "unknown",
                        };

                        // Check if this is a move (depends on parameter type)
                        const semantics = self.tracker.getSemantics(type_name);
                        if (!semantics.canCopy()) {
                            // This is a move
                            const temp_name = try std.fmt.allocPrint(
                                self.allocator,
                                "__temp_{}",
                                .{@intFromPtr(arg)},
                            );
                            defer self.allocator.free(temp_name);

                            try self.tracker.moveValue(arg_name, temp_name, type_name, loc);
                        }
                    }
                }
            },
            .MemberAccess => |member| {
                try self.checkExpression(member.object);
            },
            .ArrayAccess => |arr_access| {
                try self.checkExpression(arr_access.array);
                try self.checkExpression(arr_access.index);
            },
            .ArrayLiteral => |arr_lit| {
                for (arr_lit.elements) |elem| {
                    try self.checkExpression(elem);
                }
            },
            .TernaryExpr => |tern| {
                try self.checkExpression(tern.condition);
                try self.checkExpression(tern.then_expr);
                try self.checkExpression(tern.else_expr);
            },
            .ClosureExpr => |closure| {
                // Check closure body
                for (closure.body.statements) |stmt| {
                    try self.checkStatement(stmt);
                }
            },
            // Literals don't have move semantics
            .IntLiteral, .FloatLiteral, .BoolLiteral, .StringLiteral => {},
            else => {
                // Other expression types
            },
        }
    }

    /// Save current variable states
    fn saveStates(self: *MoveChecker) !std.StringHashMap(MoveState) {
        var states = std.StringHashMap(MoveState).init(self.allocator);

        var iter = self.tracker.var_states.iterator();
        while (iter.next()) |entry| {
            try states.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return states;
    }

    /// Restore variable states
    fn restoreStates(self: *MoveChecker, states: std.StringHashMap(MoveState)) !void {
        var iter = states.iterator();
        while (iter.next()) |entry| {
            try self.tracker.var_states.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Merge variable states from different control flow paths
    fn mergeStates(self: *MoveChecker, other_states: std.StringHashMap(MoveState)) !void {
        var iter = other_states.iterator();
        while (iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const other_state = entry.value_ptr.*;
            const current_state = self.tracker.getState(var_name);

            try self.tracker.mergePaths(var_name, current_state, other_state);
        }
    }

    /// Free saved states
    fn freeStates(self: *MoveChecker, states: std.StringHashMap(MoveState)) void {
        _ = self;
        var owned_states = states;
        owned_states.deinit();
    }

    /// Check if there are any move errors
    pub fn hasErrors(self: *MoveChecker) bool {
        return self.errors.items.len > 0 or self.tracker.hasErrors();
    }

    /// Print all move errors
    pub fn printErrors(self: *MoveChecker) void {
        std.debug.print("\n=== Move Semantics Errors ===\n", .{});

        for (self.errors.items) |err| {
            std.debug.print(
                "[{s}:{}:{}] {s}: {s}\n",
                .{ err.location.file, err.location.line, err.location.column, @tagName(err.kind), err.message },
            );
        }

        if (self.errors.items.len == 0) {
            std.debug.print("No errors\n", .{});
        }

        std.debug.print("============================\n\n", .{});
    }

    /// Register custom type move semantics
    pub fn registerType(self: *MoveChecker, type_name: []const u8, semantics: MoveSemantics) !void {
        try self.tracker.registerType(type_name, semantics);
    }

    /// Get move semantics for a type
    pub fn getSemantics(self: *MoveChecker, type_name: []const u8) MoveSemantics {
        return self.tracker.getSemantics(type_name);
    }

    /// Check if a variable has been moved
    pub fn isMoved(self: *MoveChecker, var_name: []const u8) bool {
        const state = self.tracker.getState(var_name);
        return state == .FullyMoved or state == .PartiallyMoved;
    }

    /// Get the current move state of a variable
    pub fn getState(self: *MoveChecker, var_name: []const u8) MoveState {
        return self.tracker.getState(var_name);
    }
};

/// Helper to determine if an assignment is a move
pub fn isMove(lhs: *const ast.Expr, rhs: *const ast.Expr) bool {
    _ = lhs;

    // If RHS is an identifier, it might be a move
    if (rhs.* == .Identifier) {
        return true;
    }

    return false;
}

/// Helper to extract variable name from expression
pub fn getVariableName(expr: *const ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .Identifier => |ident| ident.name,
        else => null,
    };
}
