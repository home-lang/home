const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");

/// Home code formatter
pub const Formatter = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    indent_level: usize,
    output: std.ArrayList(u8),

    pub const FormatterOptions = struct {
        indent_size: usize = 4,
        use_spaces: bool = true,
        max_line_length: usize = 100,
        trailing_comma: bool = true,
        quote_style: QuoteStyle = .double,
        semicolons: bool = false,
        brace_style: BraceStyle = .same_line,
    };

    pub const QuoteStyle = enum {
        single,
        double,
    };

    pub const BraceStyle = enum {
        same_line,
        next_line,
    };

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) Formatter {
        return .{
            .allocator = allocator,
            .program = program,
            .indent_level = 0,
            .output = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.output.deinit(self.allocator);
    }

    pub fn format(self: *Formatter, options: FormatterOptions) ![]const u8 {
        _ = options;

        // Format each statement
        for (self.program.statements) |stmt| {
            try self.formatStatement(stmt);
            try self.output.append(self.allocator, '\n');
        }

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn formatStatement(self: *Formatter, stmt: ast.Stmt) std.mem.Allocator.Error!void {
        switch (stmt) {
            .LetDecl => |decl| try self.formatLetDecl(decl),
            .FnDecl => |fn_decl| try self.formatFnDecl(fn_decl),
            .ReturnStmt => |ret| try self.formatReturnStmt(ret),
            .IfStmt => |if_stmt| try self.formatIfStmt(if_stmt),
            .ExprStmt => |expr| {
                try self.writeIndent();
                try self.formatExpression(expr);
            },
            .BlockStmt => |block| try self.formatBlockStmt(block),
            else => {},
        }
    }

    fn formatLetDecl(self: *Formatter, decl: *const ast.LetDecl) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "let ");
        try self.output.appendSlice(self.allocator, decl.name);

        if (decl.type_name) |type_name| {
            try self.output.appendSlice(self.allocator, ": ");
            try self.output.appendSlice(self.allocator, type_name);
        }

        if (decl.value) |value| {
            try self.output.appendSlice(self.allocator, " = ");
            try self.formatExpression(value);
        }
    }

    fn formatFnDecl(self: *Formatter, fn_decl: *const ast.FnDecl) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "fn ");
        try self.output.appendSlice(self.allocator, fn_decl.name);
        try self.output.append(self.allocator, '(');

        for (fn_decl.params, 0..) |param, i| {
            if (i > 0) {
                try self.output.appendSlice(self.allocator, ", ");
            }
            try self.output.appendSlice(self.allocator, param.name);
            try self.output.appendSlice(self.allocator, ": ");
            try self.output.appendSlice(self.allocator, param.type_name);
        }

        try self.output.append(self.allocator, ')');

        if (fn_decl.return_type) |ret_type| {
            try self.output.appendSlice(self.allocator, ": ");
            try self.output.appendSlice(self.allocator, ret_type);
        }

        try self.output.appendSlice(self.allocator, " {\n");
        self.indent_level += 1;

        for (fn_decl.body.statements) |stmt| {
            try self.formatStatement(stmt);
            try self.output.append(self.allocator, '\n');
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.output.append(self.allocator, '}');
    }

    fn formatReturnStmt(self: *Formatter, ret: *const ast.ReturnStmt) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "return");

        if (ret.value) |value| {
            try self.output.append(self.allocator, ' ');
            try self.formatExpression(value);
        }
    }

    fn formatIfStmt(self: *Formatter, if_stmt: *const ast.IfStmt) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "if ");
        try self.formatExpression(if_stmt.condition);
        try self.output.appendSlice(self.allocator, " {\n");

        self.indent_level += 1;
        for (if_stmt.then_block.statements) |stmt| {
            try self.formatStatement(stmt);
            try self.output.append(self.allocator, '\n');
        }
        self.indent_level -= 1;

        try self.writeIndent();
        try self.output.append(self.allocator, '}');

        if (if_stmt.else_block) |else_block| {
            try self.output.appendSlice(self.allocator, " else {\n");
            self.indent_level += 1;
            for (else_block.statements) |stmt| {
                try self.formatStatement(stmt);
                try self.output.append(self.allocator, '\n');
            }
            self.indent_level -= 1;
            try self.writeIndent();
            try self.output.append(self.allocator, '}');
        }
    }

    fn formatBlockStmt(self: *Formatter, block: *const ast.BlockStmt) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "{\n");
        self.indent_level += 1;

        for (block.statements) |stmt| {
            try self.formatStatement(stmt);
            try self.output.append(self.allocator, '\n');
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.output.append(self.allocator, '}');
    }

    fn formatExpression(self: *Formatter, expr: *const ast.Expr) !void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{lit.value});
                defer self.allocator.free(str);
                try self.output.appendSlice(self.allocator, str);
            },
            .FloatLiteral => |lit| {
                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{lit.value});
                defer self.allocator.free(str);
                try self.output.appendSlice(self.allocator, str);
            },
            .StringLiteral => |lit| {
                try self.output.append(self.allocator, '"');
                try self.output.appendSlice(self.allocator, lit.value);
                try self.output.append(self.allocator, '"');
            },
            .BooleanLiteral => |lit| {
                if (lit.value) {
                    try self.output.appendSlice(self.allocator, "true");
                } else {
                    try self.output.appendSlice(self.allocator, "false");
                }
            },
            .Identifier => |id| {
                try self.output.appendSlice(self.allocator, id.name);
            },
            .BinaryExpr => |binary| {
                try self.formatExpression(binary.left);
                try self.output.append(self.allocator, ' ');
                try self.formatBinaryOp(binary.op);
                try self.output.append(self.allocator, ' ');
                try self.formatExpression(binary.right);
            },
            .UnaryExpr => |unary| {
                try self.formatUnaryOp(unary.op);
                try self.formatExpression(unary.operand);
            },
            .CallExpr => |call| {
                try self.formatExpression(call.callee);
                try self.output.append(self.allocator, '(');
                for (call.args, 0..) |arg, i| {
                    if (i > 0) {
                        try self.output.appendSlice(self.allocator, ", ");
                    }
                    try self.formatExpression(arg);
                }
                try self.output.append(self.allocator, ')');
            },
            .TryExpr => |try_expr| {
                try self.formatExpression(try_expr.operand);
                try self.output.append(self.allocator, '?');
            },
            else => {},
        }
    }

    fn formatBinaryOp(self: *Formatter, op: ast.BinaryOp) !void {
        const op_str = switch (op) {
            .Add => "+",
            .Sub => "-",
            .Mul => "*",
            .Div => "/",
            .Mod => "%",
            .Equal => "==",
            .NotEqual => "!=",
            .Less => "<",
            .LessEq => "<=",
            .Greater => ">",
            .GreaterEq => ">=",
            .And => "&&",
            .Or => "||",
            .BitAnd => "&",
            .BitOr => "|",
            .BitXor => "^",
            .LeftShift => "<<",
            .RightShift => ">>",
            .Assign => "=",
        };
        try self.output.appendSlice(self.allocator, op_str);
    }

    fn formatUnaryOp(self: *Formatter, op: ast.UnaryOp) !void {
        const op_str = switch (op) {
            .Neg => "-",
            .Not => "!",
            .BitNot => "~",
            .Deref => "*",
            .AddressOf => "&",
        };
        try self.output.appendSlice(self.allocator, op_str);
    }

    fn writeIndent(self: *Formatter) !void {
        const indent_size = 4;
        const total_indent = self.indent_level * indent_size;
        var i: usize = 0;
        while (i < total_indent) : (i += 1) {
            try self.output.append(self.allocator, ' ');
        }
    }
};
