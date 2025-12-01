const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const OwnershipTracker = types.OwnershipTracker;
const OwnershipState = types.OwnershipState;
const diagnostics = @import("diagnostics");
const EnhancedReporter = diagnostics.enhanced_reporter.EnhancedReporter;

/// Borrow checking compiler pass
/// Validates ownership and borrowing rules at compile time
pub const BorrowCheckPass = struct {
    allocator: std.mem.Allocator,
    tracker: OwnershipTracker,
    reporter: *EnhancedReporter,
    errors: std.ArrayList(BorrowError),

    pub const BorrowError = struct {
        kind: ErrorKind,
        location: ast.SourceLocation,
        variable: []const u8,
        additional_info: ?[]const u8 = null,

        pub const ErrorKind = enum {
            UseAfterMove,
            MultipleMutableBorrows,
            BorrowWhileMutablyBorrowed,
            MutBorrowWhileBorrowed,
            MoveWhileBorrowed,
            InvalidLifetime,
            UseAfterScopeClosed,
        };
    };

    pub fn init(allocator: std.mem.Allocator, reporter: *EnhancedReporter) BorrowCheckPass {
        return .{
            .allocator = allocator,
            .tracker = OwnershipTracker.init(allocator),
            .reporter = reporter,
            .errors = .{},
        };
    }

    pub fn deinit(self: *BorrowCheckPass) void {
        self.tracker.deinit();
        for (self.errors.items) |err| {
            if (err.additional_info) |info| {
                self.allocator.free(info);
            }
        }
        self.errors.deinit(self.allocator);
    }

    /// Run borrow check on entire program
    pub fn check(self: *BorrowCheckPass, program: *ast.Program) !bool {
        for (program.statements) |*stmt| {
            try self.checkStatement(stmt);
        }

        // Report all errors
        for (self.errors.items) |err| {
            try self.reportError(err);
        }

        return self.errors.items.len == 0;
    }

    /// Check a single statement
    fn checkStatement(self: *BorrowCheckPass, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .FnDecl => |func_decl| {
                try self.checkFunction(func_decl);
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    try self.checkExpression(val);
                }
                // Register variable as owned
                try self.tracker.define(let_decl.name, .Int, let_decl.node.loc);
            },
            .ExprStmt => |expr| {
                // Check if it's an assignment expression
                switch (expr.*) {
                    .AssignmentExpr => |assign| {
                        try self.checkExpression(assign.target);
                        try self.checkExpression(assign.value);
                    },
                    else => {
                        try self.checkExpression(expr);
                    },
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    try self.checkExpression(val);
                }
            },
            .IfStmt => |if_stmt| {
                try self.checkExpression(if_stmt.condition);
                self.tracker.enterScope();
                try self.checkBlock(if_stmt.then_block);
                self.tracker.exitScope();

                if (if_stmt.else_block) |else_block| {
                    self.tracker.enterScope();
                    try self.checkBlock(else_block);
                    self.tracker.exitScope();
                }
            },
            .WhileStmt => |while_stmt| {
                try self.checkExpression(while_stmt.condition);
                self.tracker.enterScope();
                try self.checkBlock(while_stmt.body);
                self.tracker.exitScope();
            },
            else => {},
        }
    }

    /// Check function body
    fn checkFunction(self: *BorrowCheckPass, func: *ast.FnDecl) anyerror!void {
        // Enter function scope
        self.tracker.enterScope();

        // Register parameters
        for (func.params) |param| {
            try self.tracker.define(param.name, .Int, param.loc);
        }

        // Check body
        try self.checkBlock(func.body);

        // Exit function scope
        self.tracker.exitScope();
    }

    /// Check block of statements
    fn checkBlock(self: *BorrowCheckPass, block: *const ast.BlockStmt) anyerror!void {
        for (block.statements) |stmt| {
            try self.checkStatement(&stmt);
        }
    }

    /// Check expression for borrow violations
    fn checkExpression(self: *BorrowCheckPass, expr: *ast.Expr) anyerror!void {
        switch (expr.*) {
            .Identifier => |id| {
                // Check if variable has been moved
                if (self.tracker.variables.get(id.name)) |info| {
                    if (info.state == .Moved) {
                        try self.errors.append(self.allocator, .{
                            .kind = .UseAfterMove,
                            .location = id.node.loc,
                            .variable = id.name,
                        });
                    }
                }
            },
            .UnaryExpr => |un| {
                if (un.op == .AddressOf) {
                    // Immutable borrow: &x
                    if (un.operand.* == .Identifier) {
                        const var_name = un.operand.Identifier.name;
                        self.tracker.borrow(var_name, false, un.operand.Identifier.node.loc) catch |err| {
                            try self.handleBorrowError(err, var_name, un.operand.Identifier.node.loc);
                        };
                    }
                } else if (un.op == .BorrowMut) {
                    // Mutable borrow: &mut x
                    if (un.operand.* == .Identifier) {
                        const var_name = un.operand.Identifier.name;
                        self.tracker.borrow(var_name, true, un.operand.Identifier.node.loc) catch |err| {
                            try self.handleBorrowError(err, var_name, un.operand.Identifier.node.loc);
                        };
                    }
                } else {
                    try self.checkExpression(un.operand);
                }
            },
            .BinaryExpr => |bin| {
                try self.checkExpression(bin.left);
                try self.checkExpression(bin.right);
            },
            .CallExpr => |call| {
                try self.checkExpression(call.callee);
                for (call.args) |arg| {
                    try self.checkExpression(arg);

                    // Check if argument is moved (passed by value)
                    if (arg.* == .Identifier) {
                        const var_name = arg.Identifier.name;
                        // For simplicity, assume non-Copy types are moved
                        self.tracker.move(var_name, arg.Identifier.node.loc) catch |err| {
                            try self.handleBorrowError(err, var_name, arg.Identifier.node.loc);
                        };
                    }
                }
            },
            .MemberExpr => |member| {
                try self.checkExpression(member.object);
            },
            .IndexExpr => |index| {
                try self.checkExpression(index.array);
                try self.checkExpression(index.index);
            },
            .ArrayLiteral => |arr| {
                for (arr.elements) |elem| {
                    try self.checkExpression(elem);
                }
            },
            else => {},
        }
    }

    /// Handle borrow checking errors
    fn handleBorrowError(self: *BorrowCheckPass, err: anyerror, var_name: []const u8, loc: ast.SourceLocation) !void {
        const kind: BorrowError.ErrorKind = switch (err) {
            error.UseAfterMove => .UseAfterMove,
            error.MultipleMutableBorrows => .MultipleMutableBorrows,
            error.BorrowWhileMutablyBorrowed => .BorrowWhileMutablyBorrowed,
            error.MutBorrowWhileBorrowed => .MutBorrowWhileBorrowed,
            else => return err,
        };

        try self.errors.append(self.allocator, .{
            .kind = kind,
            .location = loc,
            .variable = var_name,
        });
    }

    /// Report a borrow error using enhanced diagnostics
    fn reportError(self: *BorrowCheckPass, err: BorrowError) !void {
        const code = switch (err.kind) {
            .UseAfterMove => "E0382",
            .MultipleMutableBorrows => "E0499",
            .BorrowWhileMutablyBorrowed => "E0502",
            .MutBorrowWhileBorrowed => "E0502",
            .MoveWhileBorrowed => "E0505",
            .InvalidLifetime => "E0621",
            .UseAfterScopeClosed => "E0597",
        };

        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s}",
            .{self.getErrorMessage(err.kind, err.variable)},
        );
        defer self.allocator.free(message);

        var labels: std.ArrayList(EnhancedReporter.EnhancedDiagnostic.Label) = .{};
        defer labels.deinit(self.allocator);

        try labels.append(self.allocator, .{
            .location = err.location,
            .message = try self.allocator.dupe(u8, self.getLabelMessage(err.kind)),
            .style = .primary,
        });

        const help = try self.allocator.dupe(u8, self.getHelpText(err.kind, err.variable));

        const diagnostic = EnhancedReporter.EnhancedDiagnostic{
            .severity = .Error,
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
            .location = err.location,
            .labels = try labels.toOwnedSlice(self.allocator),
            .help = help,
        };

        try self.reporter.report(diagnostic, "source.home");
    }

    fn getErrorMessage(self: *BorrowCheckPass, kind: BorrowError.ErrorKind, var_name: []const u8) []const u8 {
        return switch (kind) {
            .UseAfterMove => std.fmt.allocPrint(self.allocator, "use of moved value: `{s}`", .{var_name}) catch unreachable,
            .MultipleMutableBorrows => std.fmt.allocPrint(self.allocator, "cannot borrow `{s}` as mutable more than once at a time", .{var_name}) catch unreachable,
            .BorrowWhileMutablyBorrowed => std.fmt.allocPrint(self.allocator, "cannot borrow `{s}` as immutable because it is also borrowed as mutable", .{var_name}) catch unreachable,
            .MutBorrowWhileBorrowed => std.fmt.allocPrint(self.allocator, "cannot borrow `{s}` as mutable because it is also borrowed as immutable", .{var_name}) catch unreachable,
            .MoveWhileBorrowed => std.fmt.allocPrint(self.allocator, "cannot move out of `{s}` because it is borrowed", .{var_name}) catch unreachable,
            .InvalidLifetime => "lifetime parameter mismatch",
            .UseAfterScopeClosed => std.fmt.allocPrint(self.allocator, "`{s}` does not live long enough", .{var_name}) catch unreachable,
        };
    }

    fn getLabelMessage(self: *BorrowCheckPass, kind: BorrowError.ErrorKind) []const u8 {
        _ = self;
        return switch (kind) {
            .UseAfterMove => "value used here after move",
            .MultipleMutableBorrows => "second mutable borrow occurs here",
            .BorrowWhileMutablyBorrowed => "immutable borrow occurs here",
            .MutBorrowWhileBorrowed => "mutable borrow occurs here",
            .MoveWhileBorrowed => "move out of borrowed content",
            .InvalidLifetime => "lifetime parameter does not match",
            .UseAfterScopeClosed => "borrowed value does not live long enough",
        };
    }

    fn getHelpText(self: *BorrowCheckPass, kind: BorrowError.ErrorKind, var_name: []const u8) []const u8 {
        return switch (kind) {
            .UseAfterMove => std.fmt.allocPrint(self.allocator, "consider cloning the value before moving: `{s}.clone()`", .{var_name}) catch unreachable,
            .MultipleMutableBorrows => "mutable borrows cannot exist simultaneously; consider restructuring your code",
            .BorrowWhileMutablyBorrowed => "immutable and mutable borrows cannot coexist; end the mutable borrow first",
            .MutBorrowWhileBorrowed => "mutable borrows cannot occur while immutable borrows exist; end all borrows first",
            .MoveWhileBorrowed => "cannot move borrowed data; consider cloning or restructuring",
            .InvalidLifetime => "ensure all lifetime parameters are properly annotated",
            .UseAfterScopeClosed => "extend the lifetime of the borrowed value or move it to outer scope",
        };
    }
};
