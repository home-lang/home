const std = @import("std");
const ast = @import("ast");
const ownership = @import("../../types/src/ownership.zig");
const Type = @import("../../types/src/type_system.zig").Type;

/// Full borrow checker implementation for Home
pub const BorrowChecker = struct {
    allocator: std.mem.Allocator,
    tracker: ownership.OwnershipTracker,
    scopes: std.ArrayList(Scope),
    errors: std.ArrayList(BorrowError),
    current_function: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) BorrowChecker {
        return .{
            .allocator = allocator,
            .tracker = ownership.OwnershipTracker.init(allocator),
            .scopes = std.ArrayList(Scope).init(allocator),
            .errors = std.ArrayList(BorrowError).init(allocator),
            .current_function = null,
        };
    }

    pub fn deinit(self: *BorrowChecker) void {
        self.tracker.deinit();
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit();
    }

    /// Check a full program
    pub fn checkProgram(self: *BorrowChecker, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check a statement
    fn checkStatement(self: *BorrowChecker, stmt: ast.Stmt) !void {
        switch (stmt) {
            .LetDecl => |let_decl| try self.checkLetDecl(let_decl),
            .FnDecl => |fn_decl| try self.checkFnDecl(fn_decl),
            .ReturnStmt => |ret_stmt| try self.checkReturnStmt(ret_stmt),
            .IfStmt => |if_stmt| try self.checkIfStmt(if_stmt),
            .WhileStmt => |while_stmt| try self.checkWhileStmt(while_stmt),
            .ForStmt => |for_stmt| try self.checkForStmt(for_stmt),
            .BlockStmt => |block| try self.checkBlock(block),
            .ExprStmt => |expr_stmt| try self.checkExprStmt(expr_stmt),
            .AssignmentExpr => |assign| try self.checkAssignment(assign),
            else => {},
        }
    }

    /// Check let declaration
    fn checkLetDecl(self: *BorrowChecker, decl: *ast.LetDecl) !void {
        // Check initializer expression
        if (decl.initializer) |init| {
            try self.checkExpression(init);
        }

        // Register variable in ownership tracker
        const typ = Type.Int; // TODO: Get actual type from type system
        try self.tracker.define(decl.name, typ, decl.node.loc);
    }

    /// Check function declaration
    fn checkFnDecl(self: *BorrowChecker, decl: *ast.FnDecl) !void {
        const prev_function = self.current_function;
        self.current_function = decl.name;
        defer self.current_function = prev_function;

        // Enter new scope for function
        try self.enterScope();
        defer self.exitScope() catch {};

        // Register parameters
        for (decl.params) |param| {
            const typ = Type.Int; // TODO: Parse actual type
            try self.tracker.define(param.name, typ, param.loc);
        }

        // Check function body
        try self.checkBlock(decl.body);
    }

    /// Check return statement
    fn checkReturnStmt(self: *BorrowChecker, ret: *ast.ReturnStmt) !void {
        if (ret.value) |val| {
            try self.checkExpression(val);

            // Check if returning borrowed reference (not allowed)
            if (try self.isReturningBorrow(val)) {
                try self.addError(.{
                    .kind = .ReturnBorrowedValue,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "cannot return borrowed value from function",
                        .{},
                    ),
                    .loc = ret.node.loc,
                    .suggestion = "return an owned value or use a lifetime parameter",
                });
            }
        }
    }

    /// Check if statement
    fn checkIfStmt(self: *BorrowChecker, if_stmt: *ast.IfStmt) !void {
        try self.checkExpression(if_stmt.condition);
        try self.checkBlock(if_stmt.then_branch);

        if (if_stmt.else_branch) |else_branch| {
            try self.checkBlock(else_branch);
        }
    }

    /// Check while statement
    fn checkWhileStmt(self: *BorrowChecker, while_stmt: *ast.WhileStmt) !void {
        try self.checkExpression(while_stmt.condition);
        try self.checkBlock(while_stmt.body);
    }

    /// Check for statement
    fn checkForStmt(self: *BorrowChecker, for_stmt: *ast.ForStmt) !void {
        try self.enterScope();
        defer self.exitScope() catch {};

        if (for_stmt.initializer) |init| {
            try self.checkStatement(init);
        }
        if (for_stmt.condition) |cond| {
            try self.checkExpression(cond);
        }
        if (for_stmt.increment) |inc| {
            try self.checkExpression(inc);
        }
        try self.checkBlock(for_stmt.body);
    }

    /// Check block statement
    fn checkBlock(self: *BorrowChecker, block: *ast.BlockStmt) !void {
        try self.enterScope();
        defer self.exitScope() catch {};

        for (block.statements) |stmt| {
            try self.checkStatement(stmt);
        }
    }

    /// Check expression statement
    fn checkExprStmt(self: *BorrowChecker, expr_stmt: *ast.ExprStmt) !void {
        try self.checkExpression(expr_stmt.expression);
    }

    /// Check assignment
    fn checkAssignment(self: *BorrowChecker, assign: *ast.AssignmentExpr) !void {
        // Check if assigning to a moved value
        if (assign.target == .Identifier) {
            const name = assign.target.Identifier.name;
            try self.tracker.checkUse(name, assign.node.loc);
        }

        try self.checkExpression(assign.value);

        // If assigning a move, mark as moved
        if (assign.target == .Identifier and try self.isMovingValue(assign.value)) {
            const name = assign.target.Identifier.name;
            try self.tracker.markMoved(name);
        }
    }

    /// Check expression
    fn checkExpression(self: *BorrowChecker, expr: *ast.Expr) !void {
        switch (expr.*) {
            .Identifier => |id| {
                try self.tracker.checkUse(id.name, id.node.loc);
            },
            .BinaryExpr => |binary| {
                try self.checkExpression(binary.left);
                try self.checkExpression(binary.right);
            },
            .UnaryExpr => |unary| {
                try self.checkExpression(unary.operand);

                // Check for reference/dereference operations
                if (std.mem.eql(u8, unary.operator, "&")) {
                    try self.checkBorrow(unary.operand, false);
                } else if (std.mem.eql(u8, unary.operator, "&mut")) {
                    try self.checkBorrow(unary.operand, true);
                } else if (std.mem.eql(u8, unary.operator, "*")) {
                    try self.checkDereference(unary.operand);
                }
            },
            .CallExpr => |call| {
                try self.checkExpression(call.callee);
                for (call.args) |arg| {
                    try self.checkExpression(arg);
                }
            },
            .MemberExpr => |member| {
                try self.checkExpression(member.object);
            },
            .IndexExpr => |index| {
                try self.checkExpression(index.object);
                try self.checkExpression(index.index);
            },
            else => {},
        }
    }

    /// Check borrow operation
    fn checkBorrow(self: *BorrowChecker, expr: *ast.Expr, is_mutable: bool) !void {
        if (expr.* == .Identifier) {
            const name = expr.Identifier.name;
            const loc = expr.Identifier.node.loc;

            if (is_mutable) {
                try self.tracker.borrowMut(name, loc);
            } else {
                try self.tracker.borrow(name, loc);
            }
        }
    }

    /// Check dereference operation
    fn checkDereference(self: *BorrowChecker, expr: *ast.Expr) !void {
        try self.checkExpression(expr);
        // Additional checks for dereferencing raw pointers would go here
    }

    /// Check if expression is moving a value
    fn isMovingValue(self: *BorrowChecker, expr: *ast.Expr) !bool {
        _ = self;
        return switch (expr.*) {
            .Identifier => true,
            .CallExpr => true,
            else => false,
        };
    }

    /// Check if returning a borrowed reference
    fn isReturningBorrow(self: *BorrowChecker, expr: *ast.Expr) !bool {
        _ = self;
        return switch (expr.*) {
            .UnaryExpr => |unary| std.mem.eql(u8, unary.operator, "&"),
            else => false,
        };
    }

    /// Enter a new scope
    fn enterScope(self: *BorrowChecker) !void {
        try self.scopes.append(Scope.init(self.allocator));
    }

    /// Exit current scope
    fn exitScope(self: *BorrowChecker) !void {
        if (self.scopes.items.len > 0) {
            var scope = self.scopes.pop();
            scope.deinit();
        }
    }

    /// Add error
    fn addError(self: *BorrowChecker, err: BorrowError) !void {
        try self.errors.append(err);
    }

    /// Get all errors
    pub fn getErrors(self: *BorrowChecker) []BorrowError {
        return self.errors.items;
    }

    /// Check if there are any errors
    pub fn hasErrors(self: *BorrowChecker) bool {
        return self.errors.items.len > 0;
    }
};

/// Scope tracking for borrow checker
const Scope = struct {
    variables: std.StringHashMap(ScopeVar),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Scope {
        return .{
            .variables = std.StringHashMap(ScopeVar).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Scope) void {
        self.variables.deinit();
    }
};

const ScopeVar = struct {
    name: []const u8,
    is_borrowed: bool,
    is_mut_borrowed: bool,
};

/// Borrow checker errors
pub const BorrowError = struct {
    kind: BorrowErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
    suggestion: ?[]const u8 = null,
};

pub const BorrowErrorKind = enum {
    UseAfterMove,
    MultipleMutableBorrows,
    BorrowWhileMutablyBorrowed,
    MutBorrowWhileBorrowed,
    ReturnBorrowedValue,
    CannotMoveBorrowed,
    InvalidLifetime,
};

/// Lifetime annotations for advanced borrow checking
pub const Lifetime = struct {
    name: []const u8,
    scope_level: usize,
};

/// Reference type tracking
pub const ReferenceType = enum {
    Shared, // &T
    Mutable, // &mut T
    Owned, // T
};
