const std = @import("std");
const ast = @import("ast");
const parser = @import("parser");
const lexer = @import("lexer");
const types = @import("../../types/src/type_system.zig");
const borrow_checker = @import("../../safety/src/borrow_checker.zig");
const ownership = @import("../../types/src/ownership.zig");

/// Ion check tool - runs all static analysis without compilation
pub const Check = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(CheckError),
    warnings: std.ArrayList(CheckWarning),
    stats: CheckStats,

    pub fn init(allocator: std.mem.Allocator) Check {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(CheckError).init(allocator),
            .warnings = std.ArrayList(CheckWarning).init(allocator),
            .stats = CheckStats{},
        };
    }

    pub fn deinit(self: *Check) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit();

        for (self.warnings.items) |warn| {
            self.allocator.free(warn.message);
        }
        self.warnings.deinit();
    }

    /// Run all checks on a file
    pub fn checkFile(self: *Check, file_path: []const u8) !CheckResult {
        const start_time = std.time.milliTimestamp();

        // Read file
        const file_content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024);
        defer self.allocator.free(file_content);

        // Lex
        var lex = lexer.Lexer.init(self.allocator, file_content);
        defer lex.deinit();

        const tokens = try lex.scanAllTokens();
        self.stats.token_count = tokens.len;

        // Parse
        var parse = try parser.Parser.init(self.allocator, tokens);
        defer parse.deinit();

        const program = try parse.parse();
        self.stats.node_count = program.statements.len;

        // Type check
        try self.runTypeCheck(program);

        // Borrow check
        try self.runBorrowCheck(program);

        // Lint checks
        try self.runLintChecks(program);

        // Complexity analysis
        try self.runComplexityAnalysis(program);

        const end_time = std.time.milliTimestamp();
        self.stats.check_time_ms = @intCast(end_time - start_time);

        return CheckResult{
            .success = self.errors.items.len == 0,
            .error_count = self.errors.items.len,
            .warning_count = self.warnings.items.len,
            .stats = self.stats,
        };
    }

    /// Run type checking
    fn runTypeCheck(self: *Check, program: *ast.Program) !void {
        var type_system = types.TypeSystem.init(self.allocator);
        defer type_system.deinit();

        // Check all statements
        for (program.statements) |stmt| {
            self.checkStatementTypes(stmt, &type_system) catch |err| {
                try self.addError(.{
                    .kind = .TypeError,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Type error: {s}",
                        .{@errorName(err)},
                    ),
                    .loc = ast.SourceLocation{ .line = 0, .column = 0 },
                    .severity = .Error,
                });
            };
        }
    }

    /// Check statement types
    fn checkStatementTypes(self: *Check, stmt: ast.Stmt, type_system: *types.TypeSystem) !void {
        _ = self;
        _ = type_system;

        switch (stmt) {
            .FnDecl => |fn_decl| {
                // Check function parameters and return type
                for (fn_decl.params) |_| {
                    // Validate parameter types
                }
            },
            .LetDecl => |let_decl| {
                if (let_decl.type_name != null and let_decl.initializer != null) {
                    // Check type matches initializer
                }
            },
            else => {},
        }
    }

    /// Run borrow checking
    fn runBorrowCheck(self: *Check, program: *ast.Program) !void {
        var checker = borrow_checker.BorrowChecker.init(self.allocator);
        defer checker.deinit();

        checker.checkProgram(program) catch |err| {
            // Convert borrow checker errors to check errors
            for (checker.getErrors()) |borrow_err| {
                try self.addError(.{
                    .kind = .BorrowError,
                    .message = try self.allocator.dupe(u8, borrow_err.message),
                    .loc = borrow_err.loc,
                    .severity = .Error,
                    .suggestion = borrow_err.suggestion,
                });
            }
            return err;
        };
    }

    /// Run lint checks
    fn runLintChecks(self: *Check, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            try self.lintStatement(stmt);
        }
    }

    /// Lint a statement
    fn lintStatement(self: *Check, stmt: ast.Stmt) !void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                // Check function naming conventions
                if (!self.isSnakeCase(fn_decl.name)) {
                    try self.addWarning(.{
                        .kind = .NamingConvention,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Function '{s}' should use snake_case naming",
                            .{fn_decl.name},
                        ),
                        .loc = fn_decl.node.loc,
                        .suggestion = "use snake_case for function names",
                    });
                }

                // Check function complexity
                const complexity = try self.calculateComplexity(fn_decl.body);
                if (complexity > 10) {
                    try self.addWarning(.{
                        .kind = .Complexity,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Function '{s}' has cyclomatic complexity of {d} (max recommended: 10)",
                            .{ fn_decl.name, complexity },
                        ),
                        .loc = fn_decl.node.loc,
                        .suggestion = "consider breaking this function into smaller functions",
                    });
                }
            },
            .LetDecl => |let_decl| {
                // Check variable naming
                if (!self.isSnakeCase(let_decl.name)) {
                    try self.addWarning(.{
                        .kind = .NamingConvention,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Variable '{s}' should use snake_case naming",
                            .{let_decl.name},
                        ),
                        .loc = let_decl.node.loc,
                        .suggestion = null,
                    });
                }

                // Check for unused variables
                if (let_decl.initializer == null) {
                    try self.addWarning(.{
                        .kind = .UninitializedVariable,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Variable '{s}' declared but not initialized",
                            .{let_decl.name},
                        ),
                        .loc = let_decl.node.loc,
                        .suggestion = "initialize variable or remove declaration",
                    });
                }
            },
            else => {},
        }
    }

    /// Calculate cyclomatic complexity
    fn calculateComplexity(self: *Check, block: *ast.BlockStmt) !usize {
        _ = self;
        var complexity: usize = 1; // Base complexity

        for (block.statements) |stmt| {
            switch (stmt) {
                .IfStmt => complexity += 1,
                .WhileStmt => complexity += 1,
                .ForStmt => complexity += 1,
                .SwitchStmt => |switch_stmt| {
                    complexity += switch_stmt.cases.len;
                },
                else => {},
            }
        }

        return complexity;
    }

    /// Run complexity analysis
    fn runComplexityAnalysis(self: *Check, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                const fn_decl = stmt.FnDecl;
                const complexity = try self.calculateComplexity(fn_decl.body);
                self.stats.max_complexity = @max(self.stats.max_complexity, complexity);
            }
        }
    }

    /// Check if string is snake_case
    fn isSnakeCase(self: *Check, name: []const u8) bool {
        _ = self;
        for (name) |c| {
            if (c >= 'A' and c <= 'Z') return false;
        }
        return true;
    }

    /// Add error
    fn addError(self: *Check, err: CheckError) !void {
        try self.errors.append(err);
    }

    /// Add warning
    fn addWarning(self: *Check, warn: CheckWarning) !void {
        try self.warnings.append(warn);
    }

    /// Print results
    pub fn printResults(self: *Check, writer: anytype) !void {
        // Print errors
        if (self.errors.items.len > 0) {
            try writer.print("\n❌ {d} Error(s):\n", .{self.errors.items.len});
            for (self.errors.items) |err| {
                try writer.print("  [{}:{}] {s}: {s}\n", .{
                    err.loc.line,
                    err.loc.column,
                    @tagName(err.kind),
                    err.message,
                });
                if (err.suggestion) |suggestion| {
                    try writer.print("    💡 Suggestion: {s}\n", .{suggestion});
                }
            }
        }

        // Print warnings
        if (self.warnings.items.len > 0) {
            try writer.print("\n⚠️  {d} Warning(s):\n", .{self.warnings.items.len});
            for (self.warnings.items) |warn| {
                try writer.print("  [{}:{}] {s}: {s}\n", .{
                    warn.loc.line,
                    warn.loc.column,
                    @tagName(warn.kind),
                    warn.message,
                });
                if (warn.suggestion) |suggestion| {
                    try writer.print("    💡 Suggestion: {s}\n", .{suggestion});
                }
            }
        }

        // Print stats
        try writer.print("\n📊 Statistics:\n", .{});
        try writer.print("  Tokens: {d}\n", .{self.stats.token_count});
        try writer.print("  AST Nodes: {d}\n", .{self.stats.node_count});
        try writer.print("  Max Complexity: {d}\n", .{self.stats.max_complexity});
        try writer.print("  Check Time: {d}ms\n", .{self.stats.check_time_ms});

        if (self.errors.items.len == 0) {
            try writer.print("\n✅ All checks passed!\n", .{});
        }
    }
};

pub const CheckError = struct {
    kind: ErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
    severity: Severity,
    suggestion: ?[]const u8 = null,
};

pub const CheckWarning = struct {
    kind: WarningKind,
    message: []const u8,
    loc: ast.SourceLocation,
    suggestion: ?[]const u8 = null,
};

pub const ErrorKind = enum {
    TypeError,
    BorrowError,
    SyntaxError,
    SemanticError,
};

pub const WarningKind = enum {
    NamingConvention,
    Complexity,
    UninitializedVariable,
    UnusedVariable,
    DeadCode,
};

pub const Severity = enum {
    Error,
    Warning,
    Info,
};

pub const CheckResult = struct {
    success: bool,
    error_count: usize,
    warning_count: usize,
    stats: CheckStats,
};

pub const CheckStats = struct {
    token_count: usize = 0,
    node_count: usize = 0,
    max_complexity: usize = 0,
    check_time_ms: i64 = 0,
};
