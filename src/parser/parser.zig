const std = @import("std");
const Token = @import("../lexer/token.zig").Token;
const TokenType = @import("../lexer/token.zig").TokenType;
const ast = @import("../ast/ast.zig");

/// Parser error set
pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
    InvalidCharacter,
    Overflow,
};

/// Operator precedence levels
const Precedence = enum(u8) {
    None = 0,
    Assignment = 1,  // =
    Or = 2,          // ||
    And = 3,         // &&
    Equality = 4,    // == !=
    Comparison = 5,  // < > <= >=
    Term = 6,        // + -
    Factor = 7,      // * / %
    Unary = 8,       // ! -
    Call = 9,        // . () []
    Primary = 10,

    fn fromToken(token_type: TokenType) Precedence {
        return switch (token_type) {
            .Equal => .Assignment,
            .PipePipe, .Or => .Or,
            .AmpersandAmpersand, .And => .And,
            .EqualEqual, .BangEqual => .Equality,
            .Less, .LessEqual, .Greater, .GreaterEqual => .Comparison,
            .Plus, .Minus => .Term,
            .Star, .Slash, .Percent => .Factor,
            .LeftParen => .Call,
            else => .None,
        };
    }
};

/// Parser for the Ion language
pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    current: usize,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .current = 0,
        };
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
        std.debug.print("Parse error at line {d}: {s}\n", .{ self.peek().line, message });
        return error.UnexpectedToken;
    }

    /// Parse the entire program
    pub fn parse(self: *Parser) ParseError!*ast.Program {
        var statements = std.ArrayList(ast.Stmt){ .items = &.{}, .capacity = 0 };
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd()) {
            const stmt = try self.declaration();
            try statements.append(self.allocator, stmt);
        }

        return ast.Program.init(self.allocator, try statements.toOwnedSlice(self.allocator));
    }

    /// Parse a declaration (function, let, const, etc.)
    fn declaration(self: *Parser) ParseError!ast.Stmt {
        if (self.match(&.{.Fn})) return self.functionDeclaration();
        if (self.match(&.{.Let})) return self.letDeclaration(false);
        if (self.match(&.{.Const})) return self.letDeclaration(true);
        return self.statement();
    }

    /// Parse a function declaration
    fn functionDeclaration(self: *Parser) !ast.Stmt {
        const is_async = false; // TODO: handle async keyword
        const name_token = try self.expect(.Identifier, "Expected function name");
        const name = name_token.lexeme;

        _ = try self.expect(.LeftParen, "Expected '(' after function name");

        // Parse parameters
        var params = std.ArrayList(ast.Parameter){ .items = &.{}, .capacity = 0 };
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

        const fn_decl = try ast.FnDecl.init(
            self.allocator,
            name,
            try params.toOwnedSlice(self.allocator),
            return_type,
            body,
            is_async,
            ast.SourceLocation.fromToken(name_token),
        );

        return ast.Stmt{ .FnDecl = fn_decl };
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

        const then_block = try self.blockStatement();

        var else_block: ?*ast.BlockStmt = null;
        if (self.match(&.{.Else})) {
            else_block = try self.blockStatement();
        }

        const stmt = try ast.IfStmt.init(
            self.allocator,
            condition,
            then_block,
            else_block,
            ast.SourceLocation.fromToken(if_token),
        );

        return ast.Stmt{ .IfStmt = stmt };
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
            const stmt = try self.declaration();
            try statements.append(self.allocator, stmt);
        }

        _ = try self.expect(.RightBrace, "Expected '}' after block");

        return ast.BlockStmt.init(
            self.allocator,
            try statements.toOwnedSlice(self.allocator),
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
            } else if (self.match(&.{.LeftParen})) {
                expr = try self.call(expr);
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
            const value = try std.fmt.parseInt(i64, token.lexeme, 10);
            const expr = try self.allocator.create(ast.Expr);
            expr.* = ast.Expr{
                .IntegerLiteral = ast.IntegerLiteral.init(value, ast.SourceLocation.fromToken(token)),
            };
            return expr;
        }

        // Float literals
        if (self.match(&.{.Float})) {
            const token = self.previous();
            const value = try std.fmt.parseFloat(f64, token.lexeme);
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
            .Equal => .Assign,
            else => unreachable,
        };
    }
};
