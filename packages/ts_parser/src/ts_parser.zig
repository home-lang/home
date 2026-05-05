//! TypeScript parser — recursive-descent statements + Pratt
//! expressions, lowering directly into HIR.
//!
//! Per TS_PARITY_PLAN Phase 1.D. Phase 1.D ships a foundation that
//! handles the expression and statement subset every nontrivial TS
//! file uses (literals, identifiers, full operator-precedence
//! arithmetic, member access, calls, parenthesized groups,
//! `let`/`const`/`var` declarations, expression statements, return,
//! block statements). Phase 1.D follow-ups extend coverage to:
//!
//!   - Function and class declarations.
//!   - Type annotations (`:` after parameters / variables) and
//!     generics. The lexer already emits `kw_keyof`, `kw_typeof`,
//!     `kw_satisfies`, `kw_as`, etc.; the parser shape is in place to
//!     consume them.
//!   - Control flow: `if`, `while`, `for`, `switch`, `try`/`catch`.
//!   - Imports, exports, `namespace`, `interface`, `type` aliases.
//!   - JSX / TSX.
//!   - Decorators.
//!   - Arrow functions (currently only the simplest form recognized
//!     because of TS's notorious `(x: T) => U` vs. `(x: T)` ambiguity
//!     — see Phase 1.2 callout in §0).
//!
//! Coverage is added one HIR-test-driven slice at a time so each
//! addition is regression-gated.

const std = @import("std");
const ts_lexer = @import("ts_lexer");
const hir_mod = @import("hir");
const string_interner = @import("string_interner");
const prec_mod = @import("precedence.zig");

pub const Token = ts_lexer.Token;
pub const TokenKind = ts_lexer.TokenKind;
pub const Hir = hir_mod.Hir;
pub const NodeId = hir_mod.NodeId;
pub const Span = hir_mod.Span;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidLeftHandSide,
    OutOfMemory,
};

pub const Diagnostic = struct {
    pos: u32,
    line: u32,
    message: []const u8,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    tokens: []const Token,
    cursor: u32,
    hir: *Hir,
    builder: hir_mod.Builder,
    interner: *string_interner.Interner,
    source: []const u8,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        hir: *Hir,
        interner: *string_interner.Interner,
        source: []const u8,
        tokens: []const Token,
    ) Parser {
        return .{
            .gpa = gpa,
            .tokens = tokens,
            .cursor = 0,
            .hir = hir,
            .builder = hir_mod.Builder.init(hir),
            .interner = interner,
            .source = source,
            .diagnostics = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.builder.deinit();
        self.diagnostics.deinit(self.gpa);
        self.diag_arena.deinit();
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[self.cursor];
    }

    fn peekAt(self: *const Parser, offset: u32) Token {
        const p = self.cursor + offset;
        if (p >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[p];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.cursor];
        if (tok.kind != .eof) self.cursor += 1;
        return tok;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.peek().kind == kind) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind, what: []const u8) ParseError!Token {
        if (self.peek().kind != kind) {
            try self.report("expected ", what);
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    fn report(self: *Parser, prefix: []const u8, detail: []const u8) ParseError!void {
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "{s}{s}", .{ prefix, detail });
        try self.diagnostics.append(self.gpa, .{
            .pos = self.peek().span.start,
            .line = self.peek().line,
            .message = msg,
        });
    }

    fn span(start_tok: Token, end_tok: Token) Span {
        return .{ .start = start_tok.span.start, .end = end_tok.span.end };
    }

    fn tokenSpan(tok: Token) Span {
        return .{ .start = tok.span.start, .end = tok.span.end };
    }

    fn internToken(self: *Parser, tok: Token) ParseError!hir_mod.StringId {
        const slice = self.source[tok.span.start..tok.span.end];
        return self.interner.intern(slice) catch error.OutOfMemory;
    }

    /// Strip surrounding quotes and intern the inner content. The
    /// interner stores the *raw* literal including escapes; full
    /// escape decoding lands when the binder needs the cooked value.
    fn internStringLiteral(self: *Parser, tok: Token) ParseError!hir_mod.StringId {
        const slice = self.source[tok.span.start..tok.span.end];
        if (slice.len < 2) return self.interner.intern(slice) catch error.OutOfMemory;
        const inner = slice[1 .. slice.len - 1];
        return self.interner.intern(inner) catch error.OutOfMemory;
    }

    // ========================================================================
    // Public entry
    // ========================================================================

    /// Parse a TS source file into HIR. Returns the source-file root
    /// `NodeId` (currently a synthesized block).
    pub fn parseSourceFile(self: *Parser) ParseError!NodeId {
        var stmts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer stmts.deinit(self.gpa);

        const start = self.peek();
        while (self.peek().kind != .eof) {
            const stmt = try self.parseStatement();
            try stmts.append(self.gpa, stmt);
        }
        const end = self.peek(); // eof; span end is its start
        const file_span: Span = .{ .start = start.span.start, .end = end.span.start };
        return try self.builder.addBlock(file_span, stmts.items);
    }

    // ========================================================================
    // Statements
    // ========================================================================

    fn parseStatement(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        return switch (t.kind) {
            .kw_let, .kw_const, .kw_var => try self.parseVarDecl(),
            .kw_return => try self.parseReturnStatement(),
            .open_brace => try self.parseBlockStatement(),
            .semicolon => blk: {
                _ = self.advance();
                // Empty statement is a no-op; lower as a synthesized
                // block with zero statements at its location.
                break :blk try self.builder.addBlock(tokenSpan(t), &.{});
            },
            else => try self.parseExpressionStatement(),
        };
    }

    fn parseVarDecl(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // let/const/var
        // Phase 1.D scope: single binding per declaration. Multiple
        // bindings (`let x = 1, y = 2`) are a follow-up.
        const name_tok = try self.expect(.identifier, "identifier in variable declaration");

        // Optional type annotation `: T` — Phase 1.D parses but ignores
        // (no annotation node yet; type checker hooks this in Phase 3).
        if (self.match(.colon)) {
            try self.skipTypeAnnotation();
        }

        var init_node: NodeId = hir_mod.none_node_id;
        if (self.match(.equal)) {
            init_node = try self.parseAssignmentExpression();
        }
        try self.consumeStatementTerminator();

        const name_id = try self.internToken(name_tok);
        const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        if (init_node == hir_mod.none_node_id) {
            // Declaration without initializer — represent as the
            // identifier itself as the statement value. Real binder
            // lifts this; today we just reach a stable HIR shape.
            return ident;
        }
        // Lower `let x = expr` as `(x = expr)` — the binder Phase 2
        // will distinguish declaration vs. assignment via the
        // declaration kind it tracks alongside.
        const stmt_span: Span = .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end };
        return try self.builder.addAssignment(stmt_span, ident, init_node, null);
    }

    fn parseReturnStatement(self: *Parser) ParseError!NodeId {
        const kw = self.advance(); // return
        var value: NodeId = hir_mod.none_node_id;
        // ASI rule: `return\n…` returns void unless the expression is
        // on the same line. We approximate via the
        // `preceded_by_newline` flag of the next token.
        if (self.peek().kind != .semicolon and self.peek().kind != .close_brace and
            self.peek().kind != .eof and !self.peek().flags.preceded_by_newline)
        {
            value = try self.parseExpression();
        }
        try self.consumeStatementTerminator();
        const end_pos: u32 = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else kw.span.end;
        return try self.builder.addReturn(.{ .start = kw.span.start, .end = end_pos }, value);
    }

    fn parseBlockStatement(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.open_brace, "'{' to start block");
        var stmts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer stmts.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            try stmts.append(self.gpa, try self.parseStatement());
        }
        const close = try self.expect(.close_brace, "'}' to close block");
        return try self.builder.addBlock(span(open, close), stmts.items);
    }

    fn parseExpressionStatement(self: *Parser) ParseError!NodeId {
        const expr = try self.parseExpression();
        try self.consumeStatementTerminator();
        return expr;
    }

    fn consumeStatementTerminator(self: *Parser) ParseError!void {
        if (self.match(.semicolon)) return;
        // ASI: if the next token starts on a new line, or is `}`, or is
        // EOF, accept the absence of a semicolon.
        const t = self.peek();
        if (t.kind == .eof or t.kind == .close_brace or t.flags.preceded_by_newline) return;
        try self.report("expected ';' or newline ", "after statement");
        return error.UnexpectedToken;
    }

    /// Skip a type annotation. Phase 1.D doesn't lower types into HIR
    /// yet; this just advances the cursor past the annotation so we
    /// can parse code that has annotations.
    fn skipTypeAnnotation(self: *Parser) ParseError!void {
        // Crudely skip until we hit a delimiter. This is enough to
        // parse `let x: number = 1;` and similar; the proper type
        // parser is a Phase 1.D follow-up.
        var depth: i32 = 0;
        while (true) {
            const t = self.peek();
            if (depth == 0) {
                switch (t.kind) {
                    .equal, .semicolon, .comma, .close_paren, .close_brace, .close_bracket, .eof => return,
                    else => {},
                }
            }
            switch (t.kind) {
                .less_than, .open_paren, .open_brace, .open_bracket => depth += 1,
                .greater_than, .close_paren, .close_brace, .close_bracket => depth -= 1,
                else => {},
            }
            _ = self.advance();
            if (t.kind == .eof) return;
        }
    }

    // ========================================================================
    // Expressions — Pratt
    // ========================================================================

    /// Parse a comma-separated expression at expression-statement
    /// position. Phase 1.D treats the comma operator as
    /// not-yet-implemented and parses a single AssignmentExpression
    /// (covers ≥99% of real-world TS).
    pub fn parseExpression(self: *Parser) ParseError!NodeId {
        return try self.parseAssignmentExpression();
    }

    fn parseAssignmentExpression(self: *Parser) ParseError!NodeId {
        const left = try self.parseConditionalExpression();
        const t = self.peek();
        switch (t.kind) {
            .equal => {
                _ = self.advance();
                const right = try self.parseAssignmentExpression();
                const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
                return try self.builder.addAssignment(sp, left, right, null);
            },
            .plus_equal => return self.parseCompoundAssign(left, .add),
            .minus_equal => return self.parseCompoundAssign(left, .sub),
            .asterisk_equal => return self.parseCompoundAssign(left, .mul),
            .slash_equal => return self.parseCompoundAssign(left, .div),
            .percent_equal => return self.parseCompoundAssign(left, .mod),
            else => return left,
        }
    }

    fn parseCompoundAssign(self: *Parser, left: NodeId, op: hir_mod.BinOp) ParseError!NodeId {
        _ = self.advance();
        const right = try self.parseAssignmentExpression();
        const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
        return try self.builder.addAssignment(sp, left, right, op);
    }

    fn parseConditionalExpression(self: *Parser) ParseError!NodeId {
        const cond = try self.parseBinaryExpression(.nullish);
        if (self.peek().kind == .question) {
            _ = self.advance();
            const then_branch = try self.parseAssignmentExpression();
            _ = try self.expect(.colon, "':' in ternary");
            const else_branch = try self.parseAssignmentExpression();
            const sp: Span = .{ .start = self.hir.spanOf(cond).start, .end = self.hir.spanOf(else_branch).end };
            return try self.builder.addConditional(sp, cond, then_branch, else_branch);
        }
        return cond;
    }

    fn parseBinaryExpression(self: *Parser, min_prec: prec_mod.Prec) ParseError!NodeId {
        var left = try self.parseUnaryExpression();
        while (true) {
            const t = self.peek();
            const prec = prec_mod.binaryPrec(t.kind) orelse break;
            if (@intFromEnum(prec) < @intFromEnum(min_prec)) break;
            _ = self.advance();
            // Right-associative operators recurse with `prec`,
            // left-associative with `prec + 1`.
            const next_min: prec_mod.Prec = if (prec_mod.isRightAssociative(prec))
                prec
            else
                @enumFromInt(@intFromEnum(prec) + 1);
            const right = try self.parseBinaryExpression(next_min);
            const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
            if (prec_mod.binOpOf(t.kind)) |bop| {
                left = try self.builder.addBinaryOp(sp, bop, left, right);
            } else if (prec_mod.logicalOpOf(t.kind)) |lop| {
                left = try self.builder.addLogicalOp(sp, lop, left, right);
            } else {
                // `as` / `satisfies`: Phase 1.D treats them as a no-op
                // pass-through (the type assertion's right side is
                // skipped via `skipTypeAnnotation`-style consumption,
                // which would have eaten the operand). Future work
                // gives them dedicated HIR nodes.
                left = right;
            }
        }
        return left;
    }

    fn parseUnaryExpression(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        switch (t.kind) {
            .plus => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .plus, operand);
            },
            .minus => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .neg, operand);
            },
            .bang => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .not, operand);
            },
            .tilde => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .bit_not, operand);
            },
            .kw_typeof => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .typeof, operand);
            },
            .kw_void => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .void_, operand);
            },
            .kw_delete => {
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .delete, operand);
            },
            else => return try self.parseCallOrMemberExpression(),
        }
    }

    fn parseCallOrMemberExpression(self: *Parser) ParseError!NodeId {
        var node = try self.parsePrimaryExpression();
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .dot => {
                    _ = self.advance();
                    const name_tok = try self.expectIdentifierLike();
                    const name_id = try self.internToken(name_tok);
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = name_tok.span.end };
                    node = try self.builder.addMemberAccess(sp, node, name_id, false);
                },
                .question_dot => {
                    _ = self.advance();
                    if (self.peek().kind == .open_paren) {
                        // `a?.()` — optional call.
                        const args = try self.parseArgumentList();
                        defer self.gpa.free(args);
                        const close_pos = self.tokens[self.cursor - 1].span.end;
                        const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close_pos };
                        node = try self.builder.addCall(sp, node, args);
                    } else if (self.peek().kind == .open_bracket) {
                        _ = self.advance();
                        const idx = try self.parseExpression();
                        const close = try self.expect(.close_bracket, "']' to close index access");
                        const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close.span.end };
                        node = try self.builder.addElementAccess(sp, node, idx, true);
                    } else {
                        const name_tok = try self.expectIdentifierLike();
                        const name_id = try self.internToken(name_tok);
                        const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = name_tok.span.end };
                        node = try self.builder.addMemberAccess(sp, node, name_id, true);
                    }
                },
                .open_paren => {
                    const args = try self.parseArgumentList();
                    defer self.gpa.free(args);
                    const close_pos = self.tokens[self.cursor - 1].span.end;
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close_pos };
                    node = try self.builder.addCall(sp, node, args);
                },
                .open_bracket => {
                    _ = self.advance();
                    const idx = try self.parseExpression();
                    const close = try self.expect(.close_bracket, "']' to close index access");
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close.span.end };
                    node = try self.builder.addElementAccess(sp, node, idx, false);
                },
                else => break,
            }
        }
        return node;
    }

    /// Allocates the args slice; caller must `gpa.free` it.
    fn parseArgumentList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.open_paren, "'(' for argument list");
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer args.deinit(self.gpa);
        if (self.peek().kind != .close_paren) {
            while (true) {
                const arg = try self.parseAssignmentExpression();
                try args.append(self.gpa, arg);
                if (!self.match(.comma)) break;
                if (self.peek().kind == .close_paren) break; // trailing comma
            }
        }
        _ = try self.expect(.close_paren, "')' to close argument list");
        return try args.toOwnedSlice(self.gpa);
    }

    fn parsePrimaryExpression(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        switch (t.kind) {
            .number_literal => {
                _ = self.advance();
                const slice = self.source[t.span.start..t.span.end];
                const value = parseNumericLiteral(slice);
                return try self.builder.addLiteralNumber(tokenSpan(t), value);
            },
            .bigint_literal => {
                _ = self.advance();
                // Strip the trailing `n` suffix.
                const slice_with_n = self.source[t.span.start..t.span.end];
                const digits_slice = slice_with_n[0 .. slice_with_n.len - 1];
                const id = self.interner.intern(digits_slice) catch return error.OutOfMemory;
                return try self.builder.addLiteralBigInt(tokenSpan(t), id);
            },
            .string_literal => {
                _ = self.advance();
                const id = try self.internStringLiteral(t);
                return try self.builder.addLiteralString(tokenSpan(t), id);
            },
            .no_substitution_template => {
                _ = self.advance();
                // Phase 1.D: lower as a string literal of the inner
                // bytes (between the backticks). Full template
                // handling with substitution boundaries is a
                // follow-up.
                const slice = self.source[t.span.start..t.span.end];
                const inner = if (slice.len >= 2) slice[1 .. slice.len - 1] else slice;
                const id = self.interner.intern(inner) catch return error.OutOfMemory;
                return try self.builder.addLiteralString(tokenSpan(t), id);
            },
            .kw_true => {
                _ = self.advance();
                return try self.builder.addLiteralBool(tokenSpan(t), true);
            },
            .kw_false => {
                _ = self.advance();
                return try self.builder.addLiteralBool(tokenSpan(t), false);
            },
            .kw_null => {
                _ = self.advance();
                return try self.builder.addLiteralNull(tokenSpan(t));
            },
            .identifier => {
                _ = self.advance();
                if (std.mem.eql(u8, self.source[t.span.start..t.span.end], "undefined")) {
                    // `undefined` is a regular identifier in the JS
                    // grammar but emits as a literal in HIR for
                    // Phase 3's narrowing convenience. Treat for
                    // Phase 1.D as a normal identifier; type-checker
                    // patches up.
                }
                const id = try self.internToken(t);
                return try self.builder.addIdentifier(tokenSpan(t), id);
            },
            .private_identifier => {
                _ = self.advance();
                const id = try self.internToken(t);
                return try self.builder.addIdentifier(tokenSpan(t), id);
            },
            .open_paren => {
                _ = self.advance();
                const e = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close parenthesized expression");
                return e;
            },
            else => {
                try self.report("unexpected token in expression: ", @tagName(t.kind));
                return error.UnexpectedToken;
            },
        }
    }

    /// Accept any token that can appear after `.` — identifier or
    /// keyword (`obj.class`, `obj.let`, etc., are valid because
    /// keywords are allowed as property names).
    fn expectIdentifierLike(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind == .identifier or t.kind == .private_identifier or t.kind.isKeyword()) {
            return self.advance();
        }
        try self.report("expected identifier ", "after '.'");
        return error.UnexpectedToken;
    }
};

/// Parse a numeric literal as f64. Handles hex/oct/bin via `parseInt`
/// + cast, decimal via `parseFloat`. Strips `_` digit separators.
fn parseNumericLiteral(slice: []const u8) f64 {
    if (slice.len >= 2 and slice[0] == '0') {
        const c = slice[1];
        if (c == 'x' or c == 'X') return parseRadix(slice[2..], 16);
        if (c == 'o' or c == 'O') return parseRadix(slice[2..], 8);
        if (c == 'b' or c == 'B') return parseRadix(slice[2..], 2);
    }
    var stripped: [64]u8 = undefined;
    var n: usize = 0;
    for (slice) |c| {
        if (c == '_') continue;
        if (n >= stripped.len) break;
        stripped[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, stripped[0..n]) catch 0.0;
}

fn parseRadix(slice: []const u8, radix: u8) f64 {
    var stripped: [64]u8 = undefined;
    var n: usize = 0;
    for (slice) |c| {
        if (c == '_') continue;
        if (n >= stripped.len) break;
        stripped[n] = c;
        n += 1;
    }
    const v = std.fmt.parseInt(u64, stripped[0..n], radix) catch return 0.0;
    return @floatFromInt(v);
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

const TestSetup = struct {
    interner: string_interner.Interner,
    hir: hir_mod.Hir,
    scanner: ts_lexer.Scanner,
    tokens: std.ArrayList(Token),
    parser: Parser,
};

/// Heap-allocate the setup so internal pointer fields (`parser.hir`,
/// `parser.interner`) refer to addresses that survive the return.
fn newTestSetup(source: []const u8) !*TestSetup {
    const s = try T.allocator.create(TestSetup);
    errdefer T.allocator.destroy(s);
    s.interner = try string_interner.Interner.init(T.allocator);
    s.hir = try hir_mod.Hir.init(T.allocator);
    s.scanner = ts_lexer.Scanner.init(T.allocator, source);
    s.tokens = try s.scanner.tokenize(T.allocator);
    s.parser = Parser.init(T.allocator, &s.hir, &s.interner, source, s.tokens.items);
    return s;
}

fn destroyTestSetup(s: *TestSetup) void {
    s.parser.deinit();
    s.tokens.deinit(T.allocator);
    s.scanner.deinit(T.allocator);
    s.hir.deinit();
    s.interner.deinit();
    T.allocator.destroy(s);
}

test "parser: empty source → empty block" {
    var s = try newTestSetup("");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(hir_mod.NodeKind.block_stmt, s.hir.kindOf(root));
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 0), stmts.len);
}

test "parser: single number literal expression statement" {
    var s = try newTestSetup("42;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.literal_number, s.hir.kindOf(stmts[0]));
    try T.expectEqual(@as(f64, 42), hir_mod.literalNumberOf(&s.hir, stmts[0]));
}

test "parser: arithmetic precedence — 1 + 2 * 3" {
    var s = try newTestSetup("1 + 2 * 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    const top = stmts[0];
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(top));
    const top_op = hir_mod.binopOf(&s.hir, top);
    try T.expectEqual(hir_mod.BinOp.add, top_op.op);
    // RHS should be 2 * 3.
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(top_op.rhs));
    const rhs_op = hir_mod.binopOf(&s.hir, top_op.rhs);
    try T.expectEqual(hir_mod.BinOp.mul, rhs_op.op);
}

test "parser: right-associative ** — 2 ** 3 ** 2" {
    var s = try newTestSetup("2 ** 3 ** 2;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const top_op = hir_mod.binopOf(&s.hir, top);
    try T.expectEqual(hir_mod.BinOp.pow, top_op.op);
    // For right-assoc, `2 ** 3 ** 2` = `2 ** (3 ** 2)`. So the LHS
    // is `2`, RHS is `3 ** 2`.
    try T.expectEqual(hir_mod.NodeKind.literal_number, s.hir.kindOf(top_op.lhs));
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(top_op.rhs));
}

test "parser: parenthesized expression overrides precedence" {
    var s = try newTestSetup("(1 + 2) * 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const top_op = hir_mod.binopOf(&s.hir, top);
    try T.expectEqual(hir_mod.BinOp.mul, top_op.op);
    // LHS should be 1 + 2.
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(top_op.lhs));
}

test "parser: identifier expression" {
    var s = try newTestSetup("foo;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(top));
    const id = hir_mod.identifierOf(&s.hir, top);
    try T.expectEqualStrings("foo", s.interner.get(id.name));
}

test "parser: string literal" {
    var s = try newTestSetup("\"hello\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.literal_string, s.hir.kindOf(top));
    const lit = hir_mod.literalStringOf(&s.hir, top);
    try T.expectEqualStrings("hello", s.interner.get(lit.value));
}

test "parser: boolean and null literals" {
    var s = try newTestSetup("true; false; null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(hir_mod.NodeKind.literal_bool, s.hir.kindOf(stmts[0]));
    try T.expectEqual(true, hir_mod.literalBoolOf(&s.hir, stmts[0]));
    try T.expectEqual(false, hir_mod.literalBoolOf(&s.hir, stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.literal_null, s.hir.kindOf(stmts[2]));
}

test "parser: let declaration with initializer" {
    const src: []const u8 = "let x = 1 + 2;";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmts[0]));
}

test "parser: var / const / let all work" {
    var s = try newTestSetup("var a = 1; let b = 2; const c = 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 3), stmts.len);
    for (stmts) |stmt| try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmt));
}

test "parser: function call expression" {
    var s = try newTestSetup("f(1, 2, 3);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(stmts[0]));
    const args = hir_mod.callArgs(&s.hir, stmts[0]);
    try T.expectEqual(@as(usize, 3), args.len);
}

test "parser: call with zero arguments" {
    var s = try newTestSetup("noop();");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(top));
    try T.expectEqual(@as(usize, 0), hir_mod.callArgs(&s.hir, top).len);
}

test "parser: chained member access" {
    var s = try newTestSetup("a.b.c.d;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(top));
    const m1 = hir_mod.memberOf(&s.hir, top);
    try T.expectEqualStrings("d", s.interner.get(m1.name));
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(m1.object));
}

test "parser: optional chaining" {
    var s = try newTestSetup("a?.b;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(top));
    const m = hir_mod.memberOf(&s.hir, top);
    try T.expect(m.optional);
    try T.expectEqualStrings("b", s.interner.get(m.name));
}

test "parser: element access" {
    var s = try newTestSetup("a[0];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.element_access, s.hir.kindOf(top));
}

test "parser: ternary conditional" {
    var s = try newTestSetup("a ? 1 : 2;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.conditional, s.hir.kindOf(top));
}

test "parser: logical operators" {
    var s = try newTestSetup("a && b; a || b; a ?? b;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    for (stmts) |stmt| try T.expectEqual(hir_mod.NodeKind.logical_op, s.hir.kindOf(stmt));
    try T.expectEqual(hir_mod.LogicalOp.@"and", hir_mod.logicalOf(&s.hir, stmts[0]).op);
    try T.expectEqual(hir_mod.LogicalOp.@"or", hir_mod.logicalOf(&s.hir, stmts[1]).op);
    try T.expectEqual(hir_mod.LogicalOp.nullish, hir_mod.logicalOf(&s.hir, stmts[2]).op);
}

test "parser: unary operators" {
    var s = try newTestSetup("-x; !y; ~z; typeof a; void b; delete c;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    for (stmts) |stmt| try T.expectEqual(hir_mod.NodeKind.unary_op, s.hir.kindOf(stmt));
    try T.expectEqual(hir_mod.UnaryOp.neg, hir_mod.unaryOf(&s.hir, stmts[0]).op);
    try T.expectEqual(hir_mod.UnaryOp.not, hir_mod.unaryOf(&s.hir, stmts[1]).op);
    try T.expectEqual(hir_mod.UnaryOp.bit_not, hir_mod.unaryOf(&s.hir, stmts[2]).op);
    try T.expectEqual(hir_mod.UnaryOp.typeof, hir_mod.unaryOf(&s.hir, stmts[3]).op);
    try T.expectEqual(hir_mod.UnaryOp.void_, hir_mod.unaryOf(&s.hir, stmts[4]).op);
    try T.expectEqual(hir_mod.UnaryOp.delete, hir_mod.unaryOf(&s.hir, stmts[5]).op);
}

test "parser: return with value" {
    var s = try newTestSetup("return 42;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.return_stmt, s.hir.kindOf(top));
    const rp = hir_mod.returnOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.literal_number, s.hir.kindOf(rp.value));
}

test "parser: return without value" {
    var s = try newTestSetup("return;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.return_stmt, s.hir.kindOf(top));
    const rp = hir_mod.returnOf(&s.hir, top);
    try T.expectEqual(hir_mod.none_node_id, rp.value);
}

test "parser: nested block statements" {
    var s = try newTestSetup("{ let x = 1; { let y = 2; } }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.block_stmt, s.hir.kindOf(top));
    const inner = hir_mod.blockStmts(&s.hir, top);
    try T.expectEqual(@as(usize, 2), inner.len);
}

test "parser: variable declaration with type annotation skipped" {
    // Array literals (`[]`) are a Phase 1.D follow-up; this test
    // covers the simpler `let x: T = expr` shape, which is the
    // majority case for verifying that `skipTypeAnnotation` consumes
    // the right tokens.
    var s = try newTestSetup("let x: number = 42; let y: string = \"hi\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
}

test "parser: numeric literal — hex/oct/bin/exponent" {
    var s = try newTestSetup("0x10; 0o17; 0b1010; 1e2;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(f64, 16), hir_mod.literalNumberOf(&s.hir, stmts[0]));
    try T.expectEqual(@as(f64, 15), hir_mod.literalNumberOf(&s.hir, stmts[1]));
    try T.expectEqual(@as(f64, 10), hir_mod.literalNumberOf(&s.hir, stmts[2]));
    try T.expectEqual(@as(f64, 100), hir_mod.literalNumberOf(&s.hir, stmts[3]));
}

test "parser: digit separators in numeric literals" {
    var s = try newTestSetup("100_000;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(@as(f64, 100000), hir_mod.literalNumberOf(&s.hir, top));
}

test "parser: bigint literal" {
    var s = try newTestSetup("9007199254740993n;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.literal_bigint, s.hir.kindOf(top));
    const bi = hir_mod.literalBigIntOf(&s.hir, top);
    try T.expectEqualStrings("9007199254740993", s.interner.get(bi.digits));
}

test "parser: ASI — return on its own line" {
    var s = try newTestSetup("return\n42;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    // ASI inserts a semicolon after `return`; `42;` is a separate
    // expression statement.
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.return_stmt, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.literal_number, s.hir.kindOf(stmts[1]));
}

test "parser: assignment expression" {
    var s = try newTestSetup("x = 5;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(top));
}

test "parser: compound assignment" {
    var s = try newTestSetup("x += 1; x *= 2; x /= 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    for (stmts) |stmt| try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmt));
    try T.expectEqual(hir_mod.BinOp.add, hir_mod.assignmentOf(&s.hir, stmts[0]).op.?);
    try T.expectEqual(hir_mod.BinOp.mul, hir_mod.assignmentOf(&s.hir, stmts[1]).op.?);
    try T.expectEqual(hir_mod.BinOp.div, hir_mod.assignmentOf(&s.hir, stmts[2]).op.?);
}

test "parser: complex realistic snippet" {
    var s = try newTestSetup("let total = (a + b) * c.value(0) - 1;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmts[0]));
}
