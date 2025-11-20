const std = @import("std");
const ast = @import("ast");
const type_system = @import("types");
const LifetimeTracker = type_system.LifetimeTracker;
const Lifetime = type_system.Lifetime;
const OwnershipState = type_system.OwnershipState;

/// Integration layer for borrow checking and lifetime analysis in the compiler.
///
/// This module bridges the lifetime analysis system with the code generator,
/// providing:
/// - Borrow checking for shared (&T) and mutable (&mut T) references
/// - Lifetime tracking and validation
/// - Dangling reference detection
/// - Conflicting borrow detection
/// - Scope-based lifetime management
pub const BorrowChecker = struct {
    allocator: std.mem.Allocator,
    /// Lifetime tracker for analysis
    tracker: LifetimeTracker,
    /// Errors encountered during checking
    errors: std.ArrayList(BorrowCheckError),
    /// Current scope stack (for nested scopes)
    scope_stack: std.ArrayList(u32),

    pub const BorrowCheckError = struct {
        message: []const u8,
        location: ?ast.SourceLocation,
        kind: ErrorKind,

        pub const ErrorKind = enum {
            DanglingReference,
            ConflictingBorrow,
            CannotBorrow,
            CannotBorrowMut,
            UseAfterMove,
            LifetimeViolation,
        };
    };

    pub fn init(allocator: std.mem.Allocator) BorrowChecker {
        return .{
            .allocator = allocator,
            .tracker = LifetimeTracker.init(allocator),
            .errors = std.ArrayList(BorrowCheckError).init(allocator),
            .scope_stack = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *BorrowChecker) void {
        self.tracker.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit();
        self.scope_stack.deinit();
    }

    /// Check borrow rules for an entire program
    pub fn checkProgram(self: *BorrowChecker, program: *const ast.Program) !void {
        // Enter program scope
        const program_scope = self.tracker.enterScope();
        try self.scope_stack.append(program_scope);
        defer {
            _ = self.scope_stack.pop();
            self.tracker.exitScope(program_scope) catch {};
        }

        // Check each statement in the program
        for (program.statements) |stmt| {
            try self.checkStatement(stmt);
        }

        // Check all lifetime constraints
        try self.tracker.checkConstraints();

        // Transfer errors from tracker
        for (self.tracker.errors.items) |tracker_err| {
            try self.errors.append(.{
                .message = try self.allocator.dupe(u8, tracker_err.message),
                .location = tracker_err.location,
                .kind = switch (tracker_err.kind) {
                    .DanglingReference => .DanglingReference,
                    .ConflictingBorrow => .ConflictingBorrow,
                    .CannotBorrow => .CannotBorrow,
                    .CannotBorrowMut => .CannotBorrowMut,
                    .UseAfterMove => .UseAfterMove,
                    .LifetimeViolation => .LifetimeViolation,
                    else => .LifetimeViolation,
                },
            });
        }
    }

    /// Check a statement for borrow errors
    fn checkStatement(self: *BorrowChecker, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                try self.checkFunction(fn_decl);
            },
            .LetDecl => |let_decl| {
                const current_scope = self.getCurrentScope();

                // Declare the variable
                try self.tracker.declareOwned(let_decl.name, current_scope);

                // Check initializer if present
                if (let_decl.initializer) |init| {
                    const init_expr = @as(*const ast.Expr, @ptrCast(init));
                    try self.checkExpression(init_expr);

                    // Check if this is a borrow
                    if (self.isBorrowExpression(init_expr)) |borrow_info| {
                        const loc = ast.SourceLocation{
                            .line = 0,
                            .column = 0,
                            .file = "unknown",
                        };

                        if (borrow_info.is_mutable) {
                            try self.tracker.createBorrowMut(
                                let_decl.name,
                                borrow_info.source_var,
                                current_scope,
                                loc,
                            );
                        } else {
                            try self.tracker.createBorrow(
                                let_decl.name,
                                borrow_info.source_var,
                                current_scope,
                                loc,
                            );
                        }
                    }
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

                // Check then branch (new scope)
                const then_scope = self.tracker.enterScope();
                try self.scope_stack.append(then_scope);
                try self.checkBlock(if_stmt.then_block);
                _ = self.scope_stack.pop();
                try self.tracker.exitScope(then_scope);

                // Check else branch if present (new scope)
                if (if_stmt.else_block) |else_block| {
                    const else_scope = self.tracker.enterScope();
                    try self.scope_stack.append(else_scope);
                    try self.checkBlock(else_block);
                    _ = self.scope_stack.pop();
                    try self.tracker.exitScope(else_scope);
                }
            },
            .WhileStmt => |while_stmt| {
                const cond_expr = @as(*const ast.Expr, @ptrCast(&while_stmt.condition));
                try self.checkExpression(cond_expr);

                const loop_scope = self.tracker.enterScope();
                try self.scope_stack.append(loop_scope);
                try self.checkBlock(while_stmt.body);
                _ = self.scope_stack.pop();
                try self.tracker.exitScope(loop_scope);
            },
            .ForStmt => |for_stmt| {
                const iter_expr = @as(*const ast.Expr, @ptrCast(&for_stmt.iterable));
                try self.checkExpression(iter_expr);

                const loop_scope = self.tracker.enterScope();
                try self.scope_stack.append(loop_scope);

                // Declare loop variable
                try self.tracker.declareOwned(for_stmt.binding, loop_scope);

                try self.checkBlock(for_stmt.body);
                _ = self.scope_stack.pop();
                try self.tracker.exitScope(loop_scope);
            },
            .MatchStmt => |match_stmt| {
                const disc_expr = @as(*const ast.Expr, @ptrCast(&match_stmt.discriminant));
                try self.checkExpression(disc_expr);

                // Check each arm
                for (match_stmt.arms) |arm| {
                    const arm_scope = self.tracker.enterScope();
                    try self.scope_stack.append(arm_scope);
                    try self.checkExpression(arm.body);
                    _ = self.scope_stack.pop();
                    try self.tracker.exitScope(arm_scope);
                }
            },
            else => {},
        }
    }

    /// Check a function for borrow errors
    fn checkFunction(self: *BorrowChecker, fn_decl: *const ast.FnDecl) !void {
        const fn_scope = self.tracker.enterScope();
        try self.scope_stack.append(fn_scope);
        defer {
            _ = self.scope_stack.pop();
            self.tracker.exitScope(fn_scope) catch {};
        }

        // Declare parameters
        for (fn_decl.params) |param| {
            try self.tracker.declareOwned(param.name, fn_scope);
        }

        // Check function body
        for (fn_decl.body.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check a block for borrow errors
    fn checkBlock(self: *BorrowChecker, block: *const ast.BlockStmt) !void {
        for (block.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check an expression for borrow errors
    fn checkExpression(self: *BorrowChecker, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .Identifier => |ident| {
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

                // Check if this is a borrow operation (&expr or &mut expr)
                if (un.op == .Ref or un.op == .RefMut) {
                    if (un.operand.* == .Identifier) {
                        // This is a borrow - will be handled in let binding
                    }
                }
            },
            .CallExpr => |call| {
                try self.checkExpression(call.callee);
                for (call.arguments) |arg| {
                    try self.checkExpression(arg);
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
                const closure_scope = self.tracker.enterScope();
                try self.scope_stack.append(closure_scope);
                defer {
                    _ = self.scope_stack.pop();
                    self.tracker.exitScope(closure_scope) catch {};
                }

                for (closure.body.statements) |stmt| {
                    try self.checkStatement(stmt);
                }
            },
            // Literals don't have borrow semantics
            .IntLiteral, .FloatLiteral, .BoolLiteral, .StringLiteral => {},
            else => {},
        }
    }

    /// Check if an expression is a borrow operation
    fn isBorrowExpression(self: *BorrowChecker, expr: *const ast.Expr) ?BorrowInfo {
        _ = self;

        if (expr.* == .UnaryExpr) {
            const un = expr.UnaryExpr;
            if (un.op == .Ref or un.op == .RefMut) {
                if (un.operand.* == .Identifier) {
                    return BorrowInfo{
                        .source_var = un.operand.Identifier.name,
                        .is_mutable = (un.op == .RefMut),
                    };
                }
            }
        }

        return null;
    }

    fn getCurrentScope(self: *BorrowChecker) u32 {
        if (self.scope_stack.items.len > 0) {
            return self.scope_stack.items[self.scope_stack.items.len - 1];
        }
        return 0;
    }

    /// Check if there are any borrow errors
    pub fn hasErrors(self: *BorrowChecker) bool {
        return self.errors.items.len > 0 or self.tracker.hasErrors();
    }

    /// Print all borrow errors
    pub fn printErrors(self: *BorrowChecker) void {
        std.debug.print("\n=== Borrow Checking Errors ===\n", .{});

        for (self.errors.items) |err| {
            if (err.location) |loc| {
                std.debug.print(
                    "[{s}:{}:{}] {s}: {s}\n",
                    .{ loc.file, loc.line, loc.column, @tagName(err.kind), err.message },
                );
            } else {
                std.debug.print(
                    "{s}: {s}\n",
                    .{ @tagName(err.kind), err.message },
                );
            }
        }

        if (self.errors.items.len == 0) {
            std.debug.print("No errors\n", .{});
        }

        std.debug.print("==============================\n\n", .{});
    }

    /// Check if a variable is borrowed
    pub fn isBorrowed(self: *BorrowChecker, var_name: []const u8) bool {
        const state = self.tracker.var_ownership.get(var_name) orelse return false;
        return state == .Borrowed or state == .BorrowedMut;
    }

    /// Check if a variable has a mutable borrow
    pub fn hasMutableBorrow(self: *BorrowChecker, var_name: []const u8) bool {
        const state = self.tracker.var_ownership.get(var_name) orelse return false;
        return state == .BorrowedMut;
    }

    /// Get ownership state of a variable
    pub fn getOwnershipState(self: *BorrowChecker, var_name: []const u8) ?OwnershipState {
        return self.tracker.var_ownership.get(var_name);
    }
};

/// Information about a borrow expression
const BorrowInfo = struct {
    source_var: []const u8,
    is_mutable: bool,
};
