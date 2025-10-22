const std = @import("std");
const lexer_mod = @import("lexer");
const Token = lexer_mod.Token;
const TokenType = lexer_mod.TokenType;
const ast = @import("ast");

/// Parser error set
pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
    InvalidCharacter,
    Overflow,
    IntegerOverflow,
    FloatOverflow,
    InvalidFloat,
};

/// Operator precedence levels
const Precedence = enum(u8) {
    None = 0,
    Assignment = 1,  // =
    Or = 2,          // ||
    And = 3,         // &&
    BitOr = 4,       // |
    BitXor = 5,      // ^
    BitAnd = 6,      // &
    Equality = 7,    // == !=
    Comparison = 8,  // < > <= >=
    Range = 9,       // .. ..=
    Shift = 10,      // << >>
    Term = 11,       // + -
    Factor = 12,     // * / %
    Unary = 13,      // ! -
    Call = 14,       // . () []
    Primary = 15,

    fn fromToken(token_type: TokenType) Precedence {
        return switch (token_type) {
            .Equal => .Assignment,
            .PipePipe, .Or => .Or,
            .AmpersandAmpersand, .And => .And,
            .Pipe => .BitOr,
            .Caret => .BitXor,
            .Ampersand => .BitAnd,
            .EqualEqual, .BangEqual => .Equality,
            .Less, .LessEqual, .Greater, .GreaterEqual => .Comparison,
            .DotDot, .DotDotEqual => .Range,
            .LeftShift, .RightShift => .Shift,
            .Plus, .Minus => .Term,
            .Star, .Slash, .Percent => .Factor,
            .LeftParen, .LeftBracket, .Dot => .Call,
            else => .None,
        };
    }
};

/// Parser for the Ion language
/// Parse error information
pub const ParseErrorInfo = struct {
    message: []const u8,
    line: usize,
    column: usize,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    current: usize,
    errors: std.ArrayList(ParseErrorInfo),
    panic_mode: bool,
    recursion_depth: usize,

    const MAX_RECURSION_DEPTH: usize = 256;

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .current = 0,
            .errors = std.ArrayList(ParseErrorInfo){ .items = &.{}, .capacity = 0 },
            .panic_mode = false,
            .recursion_depth = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        // Free error messages
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Check if we're at the end of tokens
    fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .Eof;
    }

    /// Get current token without advancing
    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    /// Get previous token
    fn previous(self: *Parser) Token {
        return self.tokens[self.current - 1];
    }

    /// Advance to next token
    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    /// Check if current token matches expected type
    fn check(self: *Parser, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    /// Match current token against multiple types
    fn match(self: *Parser, types: []const TokenType) bool {
        for (types) |t| {
            if (self.check(t)) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    /// Expect a specific token type or return error
    fn expect(self: *Parser, token_type: TokenType, message: []const u8) ParseError!Token {
        if (self.check(token_type)) return self.advance();
        try self.reportError(message);
        return error.UnexpectedToken;
    }

    /// Report a parse error
    fn reportError(self: *Parser, message: []const u8) !void {
        if (self.panic_mode) return; // Don't report cascading errors

        const token = self.peek();
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{
            .message = msg_copy,
            .line = token.line,
            .column = token.column,
        });

        // Print immediately for visibility
        std.debug.print("Parse error at line {d}, column {d}: {s}\n", .{ token.line, token.column, message });

        self.panic_mode = true;

        // Safety limit: stop parsing if we have too many errors (prevents infinite loops)
        if (self.errors.items.len >= 100) {
            std.debug.print("\nToo many parse errors ({d}), stopping\n", .{self.errors.items.len});
            return error.UnexpectedToken;
        }
    }

    /// Synchronize parser state after an error
    fn synchronize(self: *Parser) void {
        self.panic_mode = false;

        while (!self.isAtEnd()) {
            // If we just passed a semicolon, we're at a statement boundary
            const prev = self.previous();
            if (prev.type == .Semicolon) {
                return;
            }

            // Check if we're at the start of a new statement/declaration
            switch (self.peek().type) {
                .Fn, .Struct, .Let, .Const, .If, .While, .For, .Return => return,
                .RightBrace => {
                    // Consume the closing brace to avoid getting stuck
                    _ = self.advance();
                    return;
                },
                else => {},
            }

            _ = self.advance();
        }
    }

    /// Parse the entire program
    pub fn parse(self: *Parser) ParseError!*ast.Program {
        var statements = std.ArrayList(ast.Stmt){};
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd()) {
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false; // Successfully parsed, exit panic mode
            } else |err| {
                // Error occurred, synchronize and continue parsing
                self.synchronize();

                // If this was a real error (not just panic mode), keep going
                if (err != error.OutOfMemory) {
                    continue; // Try to parse next statement
                }
                return err; // Out of memory is fatal
            }
        }

        // If we collected any errors, report them but still return the AST
        // This allows partial parsing for better error messages
        if (self.errors.items.len > 0) {
            std.debug.print("\n{d} parse error(s) found\n", .{self.errors.items.len});
        }

        return ast.Program.init(self.allocator, try statements.toOwnedSlice(self.allocator));
    }

    /// Parse a declaration (function, let, const, etc.)
    fn declaration(self: *Parser) ParseError!ast.Stmt {
        if (self.match(&.{.Struct})) return self.structDeclaration();
        if (self.match(&.{.Enum})) return self.enumDeclaration();
        if (self.match(&.{.Type})) return self.typeAliasDeclaration();
        if (self.match(&.{.Fn})) return self.functionDeclaration();
        if (self.match(&.{.Let})) return self.letDeclaration(false);
        if (self.match(&.{.Const})) return self.letDeclaration(true);
        return self.statement();
    }

    /// Parse a function declaration
    fn functionDeclaration(self: *Parser) !ast.Stmt {
        // Check for async keyword before function name
        const is_async = self.match(&.{.Async});

        const name_token = try self.expect(.Identifier, "Expected function name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftParen, "Expected '(' after function name");

        // Parse parameters
        var params = std.ArrayList(ast.Parameter){};
        defer params.deinit(self.allocator);

        if (!self.check(.RightParen)) {
            while (true) {
                const param_name = try self.expect(.Identifier, "Expected parameter name");
                _ = try self.expect(.Colon, "Expected ':' after parameter name");
                const param_type = try self.expect(.Identifier, "Expected parameter type");

                try params.append(self.allocator, .{
                    .name = param_name.lexeme,
                    .type_name = param_type.lexeme,
                    .loc = ast.SourceLocation.fromToken(param_name),
                });

                if (!self.match(&.{.Comma})) break;
            }
        }

        _ = try self.expect(.RightParen, "Expected ')' after parameters");

        // Parse return type
        var return_type: ?[]const u8 = null;
        if (self.match(&.{.Arrow})) {
            const ret_token = try self.expect(.Identifier, "Expected return type");
            return_type = ret_token.lexeme;
        }

        // Parse body
        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const params_slice = try params.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(params_slice);

        const fn_decl = try ast.FnDecl.init(
            self.allocator,
            name,
            params_slice,
            return_type,
            body,
            is_async,
            ast.SourceLocation.fromToken(name_token),
        );

        return ast.Stmt{ .FnDecl = fn_decl };
    }

    /// Parse a struct declaration
    fn structDeclaration(self: *Parser) !ast.Stmt {
        const struct_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected struct name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftBrace, "Expected '{' after struct name");

        // Parse fields
        var fields = std.ArrayList(ast.StructField){};
        defer fields.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const field_name = try self.expect(.Identifier, "Expected field name");
            _ = try self.expect(.Colon, "Expected ':' after field name");
            const field_type = try self.expect(.Identifier, "Expected field type");

            try fields.append(self.allocator, .{
                .name = field_name.lexeme,
                .type_name = field_type.lexeme,
                .loc = ast.SourceLocation.fromToken(field_name),
            });

            // Optional comma between fields
            _ = self.match(&.{.Comma});
        }

        _ = try self.expect(.RightBrace, "Expected '}' after struct fields");

        const fields_slice = try fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(fields_slice);

        const struct_decl = try ast.StructDecl.init(
            self.allocator,
            name,
            fields_slice,
            ast.SourceLocation.fromToken(struct_token),
        );

        return ast.Stmt{ .StructDecl = struct_decl };
    }

    /// Parse an enum declaration
    fn enumDeclaration(self: *Parser) !ast.Stmt {
        const enum_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected enum name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftBrace, "Expected '{' after enum name");

        // Parse variants
        var variants = std.ArrayList(ast.EnumVariant){};
        defer variants.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            const variant_name = try self.expect(.Identifier, "Expected variant name");

            // Check for associated data type
            var data_type: ?[]const u8 = null;
            if (self.match(&.{.LeftParen})) {
                const type_token = try self.expect(.Identifier, "Expected type in variant data");
                data_type = type_token.lexeme;
                _ = try self.expect(.RightParen, "Expected ')' after variant data type");
            }

            try variants.append(self.allocator, .{
                .name = variant_name.lexeme,
                .data_type = data_type,
            });

            // Optional comma between variants
            _ = self.match(&.{.Comma});
        }

        _ = try self.expect(.RightBrace, "Expected '}' after enum variants");

        const variants_slice = try variants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(variants_slice);

        const enum_decl = try ast.EnumDecl.init(
            self.allocator,
            name,
            variants_slice,
            ast.SourceLocation.fromToken(enum_token),
        );

        return ast.Stmt{ .EnumDecl = enum_decl };
    }

    /// Parse a type alias declaration
    fn typeAliasDeclaration(self: *Parser) !ast.Stmt {
        const type_token = self.previous();
        const name_token = try self.expect(.Identifier, "Expected type alias name");
        const name = name_token.lexeme;

        _ = try self.expect(.Equal, "Expected '=' after type alias name");

        const target_type_token = try self.expect(.Identifier, "Expected target type");
        const target_type = target_type_token.lexeme;

        const type_alias_decl = try ast.TypeAliasDecl.init(
            self.allocator,
            name,
            target_type,
            ast.SourceLocation.fromToken(type_token),
        );

        return ast.Stmt{ .TypeAliasDecl = type_alias_decl };
    }

    /// Parse a let/const declaration
    fn letDeclaration(self: *Parser, is_const: bool) !ast.Stmt {
        _ = is_const;
        const is_mutable = self.match(&.{.Mut});
        const name_token = try self.expect(.Identifier, "Expected variable name");

        // Optional type annotation
        var type_name: ?[]const u8 = null;
        if (self.match(&.{.Colon})) {
            const type_token = try self.expect(.Identifier, "Expected type name");
            type_name = type_token.lexeme;
        }

        // Optional initializer
        var value: ?*ast.Expr = null;
        if (self.match(&.{.Equal})) {
            value = try self.expression();
        }

        const decl = try ast.LetDecl.init(
            self.allocator,
            name_token.lexeme,
            type_name,
            value,
            is_mutable,
            ast.SourceLocation.fromToken(name_token),
        );

        return ast.Stmt{ .LetDecl = decl };
    }

    /// Parse a statement
    fn statement(self: *Parser) !ast.Stmt {
        if (self.match(&.{.Return})) return self.returnStatement();
        if (self.match(&.{.If})) return self.ifStatement();
        if (self.match(&.{.While})) return self.whileStatement();
        if (self.match(&.{.For})) return self.forStatement();
        if (self.match(&.{.LeftBrace})) {
            const block = try self.blockStatement();
            return ast.Stmt{ .BlockStmt = block };
        }
        return self.expressionStatement();
    }

    /// Parse a return statement
    fn returnStatement(self: *Parser) !ast.Stmt {
        const return_token = self.previous();
        var value: ?*ast.Expr = null;

        if (!self.check(.RightBrace) and !self.isAtEnd()) {
            value = try self.expression();
        }

        const stmt = try ast.ReturnStmt.init(
            self.allocator,
            value,
            ast.SourceLocation.fromToken(return_token),
        );

        return ast.Stmt{ .ReturnStmt = stmt };
    }

    /// Parse an if statement
    fn ifStatement(self: *Parser) !ast.Stmt {
        const if_token = self.previous();
        const condition = try self.expression();
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        const then_block = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(then_block, self.allocator);

        var else_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Else})) {
            else_block = try self.blockStatement();
        }
        errdefer if (else_block) |eb| ast.Program.deinitBlockStmt(eb, self.allocator);

        const stmt = try ast.IfStmt.init(
            self.allocator,
            condition,
            then_block,
            else_block,
            ast.SourceLocation.fromToken(if_token),
        );

        return ast.Stmt{ .IfStmt = stmt };
    }

    /// Parse a while statement
    fn whileStatement(self: *Parser) !ast.Stmt {
        const while_token = self.previous();
        const condition = try self.expression();
        errdefer ast.Program.deinitExpr(condition, self.allocator);

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.WhileStmt.init(
            self.allocator,
            condition,
            body,
            ast.SourceLocation.fromToken(while_token),
        );

        return ast.Stmt{ .WhileStmt = stmt };
    }

    /// Parse a for statement
    fn forStatement(self: *Parser) !ast.Stmt {
        const for_token = self.previous();

        const iterator_token = try self.expect(.Identifier, "Expected iterator variable name");
        const iterator = iterator_token.lexeme;

        _ = try self.expect(.In, "Expected 'in' after iterator variable");

        const iterable = try self.expression();
        errdefer ast.Program.deinitExpr(iterable, self.allocator);

        const body = try self.blockStatement();
        errdefer ast.Program.deinitBlockStmt(body, self.allocator);

        const stmt = try ast.ForStmt.init(
            self.allocator,
            iterator,
            iterable,
            body,
            ast.SourceLocation.fromToken(for_token),
        );

        return ast.Stmt{ .ForStmt = stmt };
    }

    /// Parse a block statement
    fn blockStatement(self: *Parser) !*ast.BlockStmt {
        // Expect the opening brace (or use previous if already consumed)
        const start_token = if (self.previous().type == .LeftBrace)
            self.previous()
        else
            try self.expect(.LeftBrace, "Expected '{'");

        var statements = std.ArrayList(ast.Stmt){ .items = &.{}, .capacity = 0 };
        defer statements.deinit(self.allocator);

        while (!self.check(.RightBrace) and !self.isAtEnd()) {
            if (self.declaration()) |stmt| {
                try statements.append(self.allocator, stmt);
                self.panic_mode = false;
            } else |err| {
                // Error in block statement - synchronize but stay in block
                if (err == error.OutOfMemory) return err;

                // Skip tokens until we find a statement boundary or block end
                while (!self.check(.RightBrace) and !self.isAtEnd()) {
                    const current = self.peek();
                    if (current.type == .Let or current.type == .Const or
                        current.type == .If or current.type == .While or
                        current.type == .For or current.type == .Return) {
                        break; // Found start of next statement
                    }
                    _ = self.advance();
                }
                self.panic_mode = false;
            }
        }

        _ = try self.expect(.RightBrace, "Expected '}' after block");

        const statements_slice = try statements.toOwnedSlice(self.allocator);
        errdefer {
            for (statements_slice) |stmt| {
                ast.Program.deinitStmt(stmt, self.allocator);
            }
            self.allocator.free(statements_slice);
        }

        return ast.BlockStmt.init(
            self.allocator,
            statements_slice,
            ast.SourceLocation.fromToken(start_token),
        );
    }

    /// Parse an expression statement
    fn expressionStatement(self: *Parser) !ast.Stmt {
        const expr = try self.expression();
        return ast.Stmt{ .ExprStmt = expr };
    }

    /// Parse an expression
    fn expression(self: *Parser) !*ast.Expr {
        return self.parsePrecedence(.Assignment);
    }

    /// Parse expression with precedence climbing
    fn parsePrecedence(self: *Parser, precedence: Precedence) ParseError!*ast.Expr {
        // Check recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            try self.reportError("Expression is too deeply nested (maximum depth is 256)");
            return error.Overflow;
        }

        // Parse prefix expression
        var expr = try self.primary();

        // Parse postfix/infix expressions
        while (@intFromEnum(precedence) <= @intFromEnum(Precedence.fromToken(self.peek().type))) {
            if (self.match(&.{ .Plus, .Minus, .Star, .Slash, .Percent })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .EqualEqual, .BangEqual, .Less, .LessEqual, .Greater, .GreaterEqual })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .AmpersandAmpersand, .PipePipe })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .Ampersand, .Pipe, .Caret, .LeftShift, .RightShift })) {
                expr = try self.binary(expr);
            } else if (self.match(&.{ .DotDot, .DotDotEqual })) {
                expr = try self.rangeExpr(expr);
            } else if (self.match(&.{.Equal})) {
                expr = try self.assignment(expr);
            } else if (self.match(&.{.LeftParen})) {
                expr = try self.call(expr);
            } else if (self.match(&.{.LeftBracket})) {
                expr = try self.indexExpr(expr);
            } else if (self.match(&.{.Dot})) {
                expr = try self.memberExpr(expr);
            } else if (self.match(&.{.Question})) {
                expr = try self.tryExpr(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    /// Parse a binary expression
    fn binary(self: *Parser, left: *ast.Expr) !*ast.Expr {
        const op_token = self.previous();
        const op = self.tokenToBinaryOp(op_token.type);
        const precedence = Precedence.fromToken(op_token.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const binary_expr = try ast.BinaryExpr.init(
            self.allocator,
            op,
            left,
            right,
            ast.SourceLocation.fromToken(op_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .BinaryExpr = binary_expr };
        return result;
    }

    /// Parse a range expression (e.g., 0..10, 1..=100)
    fn rangeExpr(self: *Parser, start: *ast.Expr) !*ast.Expr {
        const range_token = self.previous();
        const inclusive = range_token.type == .DotDotEqual;

        const precedence = Precedence.fromToken(range_token.type);
        const end = try self.parsePrecedence(@enumFromInt(@intFromEnum(precedence) + 1));

        const range_expr = try ast.RangeExpr.init(
            self.allocator,
            start,
            end,
            inclusive,
            ast.SourceLocation.fromToken(range_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .RangeExpr = range_expr };
        return result;
    }

    /// Parse an assignment expression (e.g., x = 5)
    fn assignment(self: *Parser, target: *ast.Expr) !*ast.Expr {
        const assign_token = self.previous();

        // Validate that the target is a valid lvalue (identifier, index, or member access)
        switch (target.*) {
            .Identifier, .IndexExpr, .MemberExpr => {},
            else => {
                try self.reportError("Invalid assignment target");
                return ParseError.UnexpectedToken;
            },
        }

        // Parse the right-hand side with assignment precedence
        const value = try self.parsePrecedence(.Assignment);

        const assign_expr = try ast.AssignmentExpr.init(
            self.allocator,
            target,
            value,
            ast.SourceLocation.fromToken(assign_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .AssignmentExpr = assign_expr };
        return result;
    }

    /// Parse a call expression
    fn call(self: *Parser, callee: *ast.Expr) !*ast.Expr {
        const lparen_token = self.previous();

        var args = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
        defer args.deinit(self.allocator);

        if (!self.check(.RightParen)) {
            while (true) {
                const arg = try self.expression();
                try args.append(self.allocator, arg);
                if (!self.match(&.{.Comma})) break;
            }
        }

        _ = try self.expect(.RightParen, "Expected ')' after arguments");

        const call_expr = try ast.CallExpr.init(
            self.allocator,
            callee,
            try args.toOwnedSlice(self.allocator),
            ast.SourceLocation.fromToken(lparen_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .CallExpr = call_expr };
        return result;
    }

    /// Parse an index expression (array[index]) or slice expression (array[start..end])
    fn indexExpr(self: *Parser, array: *ast.Expr) !*ast.Expr {
        const bracket_token = self.previous();

        // Check for slice starting from beginning: arr[..end] or arr[..=end]
        if (self.check(.DotDot) or self.check(.DotDotEqual)) {
            const inclusive = if (self.check(.DotDotEqual)) blk: {
                _ = self.advance(); // consume DotDotEqual
                break :blk true;
            } else blk: {
                _ = self.advance(); // consume DotDot
                break :blk false;
            };
            const end = try self.expression();
            _ = try self.expect(.RightBracket, "Expected ']' after slice");

            const slice_expr = try ast.SliceExpr.init(
                self.allocator,
                array,
                null, // start is null (beginning)
                end,
                inclusive,
                ast.SourceLocation.fromToken(bracket_token),
            );

            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .SliceExpr = slice_expr };
            return result;
        }

        // Parse first expression
        const first_expr = try self.expression();

        // Check if this is a slice: arr[start..end] or arr[start..=end] or arr[start..]
        if (self.check(.DotDot) or self.check(.DotDotEqual)) {
            const inclusive = if (self.check(.DotDotEqual)) blk: {
                _ = self.advance(); // consume DotDotEqual
                break :blk true;
            } else blk: {
                _ = self.advance(); // consume DotDot
                break :blk false;
            };

            // Check if there's an end expression or if it's arr[start..]
            var end: ?*ast.Expr = null;
            if (!self.check(.RightBracket)) {
                end = try self.expression();
            }

            _ = try self.expect(.RightBracket, "Expected ']' after slice");

            const slice_expr = try ast.SliceExpr.init(
                self.allocator,
                array,
                first_expr,
                end,
                inclusive,
                ast.SourceLocation.fromToken(bracket_token),
            );

            const result = try self.allocator.create(ast.Expr);
            result.* = ast.Expr{ .SliceExpr = slice_expr };
            return result;
        }

        // Not a slice, just a regular index expression
        _ = try self.expect(.RightBracket, "Expected ']' after index");

        const index_expr = try ast.IndexExpr.init(
            self.allocator,
            array,
            first_expr,
            ast.SourceLocation.fromToken(bracket_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .IndexExpr = index_expr };
        return result;
    }

    /// Parse a member access expression (struct.field)
    fn memberExpr(self: *Parser, object: *ast.Expr) !*ast.Expr {
        const dot_token = self.previous();
        const member_token = try self.expect(.Identifier, "Expected field name after '.'");

        const member_expr = try ast.MemberExpr.init(
            self.allocator,
            object,
            member_token.lexeme,
            ast.SourceLocation.fromToken(dot_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .MemberExpr = member_expr };
        return result;
    }

    /// Parse a try expression (error propagation with ?)
    fn tryExpr(self: *Parser, operand: *ast.Expr) !*ast.Expr {
        const question_token = self.previous();

        const try_expr = try ast.TryExpr.init(
            self.allocator,
            operand,
            ast.SourceLocation.fromToken(question_token),
        );

        const result = try self.allocator.create(ast.Expr);
        result.* = ast.Expr{ .TryExpr = try_expr };
        return result;
    }

    /// Parse a primary expression (literals, identifiers, grouping)
    fn primary(self: *Parser) ParseError!*ast.Expr {
        // Check for invalid tokens and report them clearly
        if (self.peek().type == .Invalid) {
            const token = self.advance();
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Invalid character '{s}' in source code",
                .{token.lexeme}
            );
            defer self.allocator.free(msg);
            try self.reportError(msg);
            return error.InvalidCharacter;
        }

        // Boolean literals
        if (self.match(&.{.True})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .BooleanLiteral = ast.BooleanLiteral.init(true, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        if (self.match(&.{.False})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .BooleanLiteral = ast.BooleanLiteral.init(false, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Integer literals
        if (self.match(&.{.Integer})) {
            const token = self.previous();
            const value = std.fmt.parseInt(i64, token.lexeme, 10) catch |err| {
                if (err == error.Overflow) {
                    try self.reportError("Integer literal is too large (exceeds i64 range)");
                    return error.IntegerOverflow;
                }
                return err;
            };
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .IntegerLiteral = ast.IntegerLiteral.init(value, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Float literals
        if (self.match(&.{.Float})) {
            const token = self.previous();
            const value = std.fmt.parseFloat(f64, token.lexeme) catch |err| {
                if (err == error.InvalidCharacter) {
                    try self.reportError("Invalid float literal format");
                    return error.InvalidFloat;
                }
                return err;
            };
            // Check for infinity (overflow)
            if (std.math.isInf(value)) {
                try self.reportError("Float literal is too large (exceeds f64 range)");
                return error.FloatOverflow;
            }
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .FloatLiteral = ast.FloatLiteral.init(value, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // String literals
        if (self.match(&.{.String})) {
            const token = self.previous();
            // Remove quotes
            const value = token.lexeme[1 .. token.lexeme.len - 1];
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .StringLiteral = ast.StringLiteral.init(value, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Identifiers
        if (self.match(&.{.Identifier})) {
            const token = self.previous();
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .Identifier = ast.Identifier.init(token.lexeme, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Unary expressions
        if (self.match(&.{ .Bang, .Minus })) {
            const op_token = self.previous();
            const op: ast.UnaryOp = if (op_token.type == .Bang) .Not else .Neg;
            const operand = try self.parsePrecedence(.Unary);

            const unary_expr = try ast.UnaryExpr.init(
                self.allocator,
                op,
                operand,
                ast.SourceLocation.fromToken(op_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .UnaryExpr = unary_expr };
            return expr;
        }

        // Array literals
        if (self.match(&.{.LeftBracket})) {
            const bracket_token = self.previous();
            var elements = std.ArrayList(*ast.Expr){ .items = &.{}, .capacity = 0 };
            defer elements.deinit(self.allocator);

            if (!self.check(.RightBracket)) {
                while (true) {
                    const elem = try self.expression();
                    try elements.append(self.allocator, elem);

                    if (!self.match(&.{.Comma})) break;
                }
            }

            _ = try self.expect(.RightBracket, "Expected ']' after array elements");

            const array_literal = try ast.ArrayLiteral.init(
                self.allocator,
                try elements.toOwnedSlice(self.allocator),
                ast.SourceLocation.fromToken(bracket_token),
            );

            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{ .ArrayLiteral = array_literal };
            return expr;
        }

        // Grouping
        if (self.match(&.{.LeftParen})) {
            const expr = try self.expression();
            _ = try self.expect(.RightParen, "Expected ')' after expression");
            return expr;
        }

        std.debug.print("Parse error at line {d}: Unexpected token '{s}'\n", .{ self.peek().line, self.peek().lexeme });
        return error.UnexpectedToken;
    }

    /// Convert token type to binary operator
    fn tokenToBinaryOp(self: *Parser, token_type: TokenType) ast.BinaryOp {
        _ = self;
        return switch (token_type) {
            .Plus => .Add,
            .Minus => .Sub,
            .Star => .Mul,
            .Slash => .Div,
            .Percent => .Mod,
            .EqualEqual => .Equal,
            .BangEqual => .NotEqual,
            .Less => .Less,
            .LessEqual => .LessEq,
            .Greater => .Greater,
            .GreaterEqual => .GreaterEq,
            .AmpersandAmpersand => .And,
            .PipePipe => .Or,
            .Ampersand => .BitAnd,
            .Pipe => .BitOr,
            .Caret => .BitXor,
            .LeftShift => .LeftShift,
            .RightShift => .RightShift,
            .Equal => .Assign,
            else => std.debug.panic("Invalid binary operator token: {any}", .{token_type}),
        };
    }
};
