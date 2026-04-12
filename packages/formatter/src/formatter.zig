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
    /// Active options, set at the start of `format()` and read throughout
    /// the walk. Defaults apply until the caller passes something else.
    opts: FormatterOptions = .{},

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
            .output = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.output.deinit(self.allocator);
    }

    pub fn format(self: *Formatter, options: FormatterOptions) ![]const u8 {
        // Stash the options on self so formatter helpers can read them
        // without threading the struct through every call. We copy the
        // struct (it's small and plain data) to decouple the lifetime.
        self.opts = options;

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
            .ImportDecl => |decl| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "import ");
                for (decl.path, 0..) |seg, i| {
                    if (i > 0) try self.output.append(self.allocator, '.');
                    try self.output.appendSlice(self.allocator, seg);
                }
            },
            .WhileStmt => |while_stmt| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "while ");
                try self.formatExpression(while_stmt.condition);
                try self.output.appendSlice(self.allocator, " {\n");
                self.indent_level += 1;
                for (while_stmt.body.statements) |s| {
                    try self.formatStatement(s);
                    try self.output.append(self.allocator, '\n');
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.output.append(self.allocator, '}');
            },
            .DeferStmt => |defer_stmt| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "defer ");
                try self.formatExpression(defer_stmt.body);
            },
            .BreakStmt => {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "break");
            },
            .ContinueStmt => {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "continue");
            },
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
                for (lit.value) |ch| {
                    switch (ch) {
                        '"' => try self.output.appendSlice(self.allocator, "\\\""),
                        '\\' => try self.output.appendSlice(self.allocator, "\\\\"),
                        '\n' => try self.output.appendSlice(self.allocator, "\\n"),
                        '\r' => try self.output.appendSlice(self.allocator, "\\r"),
                        '\t' => try self.output.appendSlice(self.allocator, "\\t"),
                        else => try self.output.append(self.allocator, ch),
                    }
                }
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
                try self.output.appendSlice(self.allocator, "try ");
                try self.formatExpression(try_expr.operand);
            },
            .NullLiteral => {
                try self.output.appendSlice(self.allocator, "null");
            },
            .ArrayLiteral => |arr| {
                try self.output.append(self.allocator, '[');
                for (arr.elements, 0..) |elem, i| {
                    if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                    try self.formatExpression(elem);
                }
                try self.output.append(self.allocator, ']');
            },
            .MemberExpr => |member| {
                try self.formatExpression(member.object);
                try self.output.append(self.allocator, '.');
                try self.output.appendSlice(self.allocator, member.member);
            },
            .IndexExpr => |index| {
                try self.formatExpression(index.array);
                try self.output.append(self.allocator, '[');
                try self.formatExpression(index.index);
                try self.output.append(self.allocator, ']');
            },
            .TernaryExpr => |ternary| {
                try self.formatExpression(ternary.condition);
                try self.output.appendSlice(self.allocator, " ? ");
                try self.formatExpression(ternary.true_val);
                try self.output.appendSlice(self.allocator, " : ");
                try self.formatExpression(ternary.false_val);
            },
            .AssignmentExpr => |assign| {
                try self.formatExpression(assign.target);
                try self.output.appendSlice(self.allocator, " = ");
                try self.formatExpression(assign.value);
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
            .IntDiv => "~/",
            .Mod => "%",
            .Power => "**",
            // Checked arithmetic (panic on overflow)
            .CheckedAdd => "+!",
            .CheckedSub => "-!",
            .CheckedMul => "*!",
            .CheckedDiv => "/!",
            // Checked arithmetic with Option (returns Option)
            .SaturatingAdd => "+?",
            .SaturatingSub => "-?",
            .SaturatingMul => "*?",
            .SaturatingDiv => "/?",
            // Clamping arithmetic (clamps to bounds)
            .ClampAdd => "+|",
            .ClampSub => "-|",
            .ClampMul => "*|",
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
            .Borrow => "&",
            .BorrowMut => "&mut ",
        };
        try self.output.appendSlice(self.allocator, op_str);
    }

    fn writeIndent(self: *Formatter) !void {
        // Honor the user's indent configuration. Spaces use `indent_size`
        // characters per level; tabs use a single tab character per level
        // (width is handled by the editor). `use_spaces=false` implies tabs.
        const total_indent = self.indent_level * self.opts.indent_size;
        const indent_char: u8 = if (self.opts.use_spaces) ' ' else '\t';
        const repeat_count: usize = if (self.opts.use_spaces) total_indent else self.indent_level;
        var i: usize = 0;
        while (i < repeat_count) : (i += 1) {
            try self.output.append(self.allocator, indent_char);
        }
    }

    /// Emit a string literal with the user's preferred quote style.
    /// The input slice is the raw string contents (without delimiters).
    /// Special characters are escaped so the output is always valid.
    fn writeStringLiteral(self: *Formatter, contents: []const u8) !void {
        const quote: u8 = switch (self.opts.quote_style) {
            .single => '\'',
            .double => '"',
        };
        try self.output.append(self.allocator, quote);
        for (contents) |ch| {
            switch (ch) {
                '"' => if (quote == '"') {
                    try self.output.appendSlice(self.allocator, "\\\"");
                } else {
                    try self.output.append(self.allocator, ch);
                },
                '\'' => if (quote == '\'') {
                    try self.output.appendSlice(self.allocator, "\\'");
                } else {
                    try self.output.append(self.allocator, ch);
                },
                '\\' => try self.output.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.output.appendSlice(self.allocator, "\\n"),
                '\r' => try self.output.appendSlice(self.allocator, "\\r"),
                '\t' => try self.output.appendSlice(self.allocator, "\\t"),
                else => try self.output.append(self.allocator, ch),
            }
        }
        try self.output.append(self.allocator, quote);
    }

    /// Append a statement-terminator semicolon if the user wants them.
    /// Home's syntax treats semicolons as optional, so this only fires in
    /// `semicolons = true` mode.
    fn writeSemicolonIfEnabled(self: *Formatter) !void {
        if (self.opts.semicolons) {
            try self.output.append(self.allocator, ';');
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "formatter: FormatterOptions defaults" {
    const testing = std.testing;
    const options = Formatter.FormatterOptions{};

    try testing.expectEqual(@as(usize, 4), options.indent_size);
    try testing.expect(options.use_spaces == true);
    try testing.expectEqual(@as(usize, 100), options.max_line_length);
    try testing.expect(options.trailing_comma == true);
    try testing.expect(options.quote_style == .double);
    try testing.expect(options.semicolons == false);
    try testing.expect(options.brace_style == .same_line);
}

test "formatter: FormatterOptions custom values" {
    const testing = std.testing;
    const options = Formatter.FormatterOptions{
        .indent_size = 2,
        .use_spaces = false,
        .max_line_length = 80,
        .trailing_comma = false,
        .quote_style = .single,
        .semicolons = true,
        .brace_style = .next_line,
    };

    try testing.expectEqual(@as(usize, 2), options.indent_size);
    try testing.expect(options.use_spaces == false);
    try testing.expectEqual(@as(usize, 80), options.max_line_length);
    try testing.expect(options.trailing_comma == false);
    try testing.expect(options.quote_style == .single);
    try testing.expect(options.semicolons == true);
    try testing.expect(options.brace_style == .next_line);
}

test "formatter: QuoteStyle enum" {
    const testing = std.testing;

    try testing.expect(Formatter.QuoteStyle.single != Formatter.QuoteStyle.double);
    try testing.expect(@intFromEnum(Formatter.QuoteStyle.single) == 0);
    try testing.expect(@intFromEnum(Formatter.QuoteStyle.double) == 1);
}

test "formatter: BraceStyle enum" {
    const testing = std.testing;

    try testing.expect(Formatter.BraceStyle.same_line != Formatter.BraceStyle.next_line);
    try testing.expect(@intFromEnum(Formatter.BraceStyle.same_line) == 0);
    try testing.expect(@intFromEnum(Formatter.BraceStyle.next_line) == 1);
}
