const std = @import("std");
const ast = @import("ast");
const DiagnosticReporter = @import("diagnostics.zig").DiagnosticReporter;

/// Warning detector for common issues in Home code
pub const WarningDetector = struct {
    allocator: std.mem.Allocator,
    reporter: *DiagnosticReporter,
    // Track declared variables and their usage
    declared_vars: std.StringHashMap(ast.SourceLocation),
    used_vars: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator, reporter: *DiagnosticReporter) WarningDetector {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .declared_vars = std.StringHashMap(ast.SourceLocation).init(allocator),
            .used_vars = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *WarningDetector) void {
        self.declared_vars.deinit();
        self.used_vars.deinit();
    }

    /// Analyze a program and detect warnings
    pub fn analyze(self: *WarningDetector, program: *const ast.Program) !void {
        for (program.statements) |stmt| {
            try self.analyzeStmt(stmt);
        }

        // Check for unused variables
        try self.checkUnusedVariables();
    }

    fn analyzeStmt(self: *WarningDetector, stmt: ast.Stmt) !void {
        switch (stmt) {
            .LetDecl => |decl| {
                // Track variable declaration
                try self.declared_vars.put(decl.name, decl.location);

                // Check the value expression for variable usage
                if (decl.value) |value| {
                    try self.analyzeExpr(value);
                }
            },
            .ExprStmt => |expr| {
                try self.analyzeExpr(expr);
            },
            .ReturnStmt => |ret| {
                if (ret.value) |value| {
                    try self.analyzeExpr(value);
                }
            },
            .IfStmt => |if_stmt| {
                try self.analyzeExpr(if_stmt.condition);
                try self.analyzeStmt(if_stmt.then_branch.*);
                if (if_stmt.else_branch) |else_branch| {
                    try self.analyzeStmt(else_branch.*);
                }
            },
            .WhileStmt => |while_stmt| {
                try self.analyzeExpr(while_stmt.condition);
                try self.analyzeStmt(while_stmt.body.*);
            },
            .ForStmt => |for_stmt| {
                // Track iterator variable
                try self.declared_vars.put(for_stmt.iterator, for_stmt.location);

                try self.analyzeExpr(for_stmt.iterable);
                try self.analyzeStmt(for_stmt.body.*);
            },
            .BlockStmt => |block| {
                for (block.statements) |block_stmt| {
                    try self.analyzeStmt(block_stmt);
                }
            },
            else => {},
        }
    }

    fn analyzeExpr(self: *WarningDetector, expr: *const ast.Expr) !void {
        switch (expr.*) {
            .Identifier => |id| {
                // Mark variable as used
                try self.used_vars.put(id.name, true);
            },
            .BinaryExpr => |binary| {
                try self.analyzeExpr(binary.left);
                try self.analyzeExpr(binary.right);
            },
            .UnaryExpr => |unary| {
                try self.analyzeExpr(unary.operand);
            },
            .CallExpr => |call| {
                try self.analyzeExpr(call.callee);
                for (call.args) |arg| {
                    try self.analyzeExpr(arg);
                }
            },
            .AssignmentExpr => |assign| {
                try self.analyzeExpr(assign.target);
                try self.analyzeExpr(assign.value);
            },
            .IndexExpr => |index| {
                try self.analyzeExpr(index.target);
                try self.analyzeExpr(index.index);
            },
            .MemberExpr => |member| {
                try self.analyzeExpr(member.target);
            },
            .ArrayLiteral => |array| {
                for (array.elements) |elem| {
                    try self.analyzeExpr(elem);
                }
            },
            .StructLiteral => |struct_lit| {
                for (struct_lit.fields) |field| {
                    try self.analyzeExpr(field.value);
                }
            },
            .RangeExpr => |range| {
                try self.analyzeExpr(range.start);
                try self.analyzeExpr(range.end);
            },
            else => {},
        }
    }

    fn checkUnusedVariables(self: *WarningDetector) !void {
        var it = self.declared_vars.iterator();
        while (it.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const location = entry.value_ptr.*;

            // Skip if variable is used or starts with underscore (convention for intentionally unused)
            if (self.used_vars.contains(var_name) or std.mem.startsWith(u8, var_name, "_")) {
                continue;
            }

            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Unused variable '{s}'",
                .{var_name},
            );
            defer self.allocator.free(msg);

            const suggestion = try std.fmt.allocPrint(
                self.allocator,
                "Prefix with underscore '_' if intentionally unused",
                .{},
            );
            defer self.allocator.free(suggestion);

            try self.reporter.addWarning(msg, location, suggestion);
        }
    }
};

test "warnings: unused variable detection" {
    const testing = std.testing;
    const Lexer = @import("lexer").Lexer;
    const Parser = @import("parser").Parser;

    const source =
        \\fn main() -> int {
        \\    let unused = 5
        \\    let used = 10
        \\    return used
        \\}
    ;

    var lexer = Lexer.init(testing.allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit();

    var reporter = DiagnosticReporter.init(testing.allocator);
    defer reporter.deinit();

    var detector = WarningDetector.init(testing.allocator, &reporter);
    defer detector.deinit();

    try detector.analyze(&program);

    try testing.expect(reporter.hasWarnings());
}
