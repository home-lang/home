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
            .kw_if => try self.parseIfStatement(),
            .kw_while => try self.parseWhileStatement(),
            .kw_do => try self.parseDoWhileStatement(),
            .kw_for => try self.parseForStatement(),
            .kw_break => try self.parseBreakStatement(),
            .kw_continue => try self.parseContinueStatement(),
            .kw_throw => try self.parseThrowStatement(),
            .kw_try => try self.parseTryStatement(),
            .kw_switch => try self.parseSwitchStatement(),
            .kw_function => try self.parseFunctionDeclaration(),
            .kw_class => try self.parseClassDeclaration(),
            .kw_interface => try self.parseInterfaceDeclaration(),
            .kw_enum => try self.parseEnumDeclaration(),
            .kw_namespace, .kw_module => try self.parseNamespaceDeclaration(),
            .kw_import => try self.parseImportDeclaration(),
            .kw_export => try self.parseExportDeclaration(),
            .kw_type => blk: {
                // `type X = T;` is a TS type alias. `type` is contextual,
                // so only treat as a keyword when followed by an identifier.
                if (self.peekAt(1).kind == .identifier) break :blk try self.parseTypeAlias();
                break :blk try self.parseExpressionStatement();
            },
            .semicolon => blk: {
                _ = self.advance();
                // Empty statement is a no-op; lower as a synthesized
                // block with zero statements at its location.
                break :blk try self.builder.addBlock(tokenSpan(t), &.{});
            },
            else => try self.parseExpressionStatement(),
        };
    }

    fn parseIfStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // if
        _ = try self.expect(.open_paren, "'(' after 'if'");
        const cond = try self.parseExpression();
        _ = try self.expect(.close_paren, "')' after if condition");
        const then_branch = try self.parseStatement();
        var else_branch: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_else)) else_branch = try self.parseStatement();
        const end_pos: u32 = if (else_branch != hir_mod.none_node_id)
            self.hir.spanOf(else_branch).end
        else
            self.hir.spanOf(then_branch).end;
        return try self.builder.addIf(.{ .start = start.span.start, .end = end_pos }, cond, then_branch, else_branch);
    }

    fn parseWhileStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // while
        _ = try self.expect(.open_paren, "'(' after 'while'");
        const cond = try self.parseExpression();
        _ = try self.expect(.close_paren, "')' after while condition");
        const body = try self.parseStatement();
        const end_pos = self.hir.spanOf(body).end;
        return try self.builder.addWhile(.{ .start = start.span.start, .end = end_pos }, cond, body);
    }

    fn parseDoWhileStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // do
        const body = try self.parseStatement();
        _ = try self.expect(.kw_while, "'while' after do-block");
        _ = try self.expect(.open_paren, "'(' after 'while'");
        const cond = try self.parseExpression();
        const close = try self.expect(.close_paren, "')' after do-while condition");
        try self.consumeStatementTerminator();
        return try self.builder.addDoWhile(.{ .start = start.span.start, .end = close.span.end }, body, cond);
    }

    fn parseForStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // for
        _ = try self.expect(.open_paren, "'(' after 'for'");

        // Parse the init slot. Three shapes:
        //   for (;;) ...                  — empty init
        //   for (let x ...) ...            — declaration init
        //   for (expr ...) ...             — expression init
        // The first two can be followed by `in` / `of` for for-in/for-of.
        var init_node: NodeId = hir_mod.none_node_id;
        const has_decl_kw = (self.peek().kind == .kw_let or
            self.peek().kind == .kw_const or
            self.peek().kind == .kw_var);

        if (self.peek().kind == .semicolon) {
            // empty init — leave as none
        } else if (has_decl_kw) {
            const kw = self.advance(); // let/const/var
            const name_tok = try self.expect(.identifier, "identifier in for-init binding");
            // optional type annotation
            if (self.match(.colon)) try self.skipTypeAnnotation();

            // Detect for-in / for-of immediately.
            if (self.peek().kind == .kw_in or self.peek().kind == .kw_of) {
                const kind_tok = self.advance(); // in/of
                const name_id = try self.internToken(name_tok);
                const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                const source_expr = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close for-in/of header");
                const body = try self.parseStatement();
                const end_pos = self.hir.spanOf(body).end;
                if (kind_tok.kind == .kw_in) {
                    return try self.builder.addForIn(.{ .start = start.span.start, .end = end_pos }, ident, source_expr, body);
                } else {
                    return try self.builder.addForOf(.{ .start = start.span.start, .end = end_pos }, ident, source_expr, body);
                }
            }

            // Classic for: `for (let x = init;` …)
            var init_expr: NodeId = hir_mod.none_node_id;
            if (self.match(.equal)) init_expr = try self.parseAssignmentExpression();
            const name_id = try self.internToken(name_tok);
            const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
            if (init_expr == hir_mod.none_node_id) {
                init_node = ident;
            } else {
                init_node = try self.builder.addAssignment(.{
                    .start = kw.span.start,
                    .end = self.hir.spanOf(init_expr).end,
                }, ident, init_expr, null);
            }
        } else {
            const head_expr = try self.parseExpression();

            if (self.peek().kind == .kw_in or self.peek().kind == .kw_of) {
                const kind_tok = self.advance();
                const source_expr = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close for-in/of header");
                const body = try self.parseStatement();
                const end_pos = self.hir.spanOf(body).end;
                if (kind_tok.kind == .kw_in) {
                    return try self.builder.addForIn(.{ .start = start.span.start, .end = end_pos }, head_expr, source_expr, body);
                } else {
                    return try self.builder.addForOf(.{ .start = start.span.start, .end = end_pos }, head_expr, source_expr, body);
                }
            }
            init_node = head_expr;
        }

        _ = try self.expect(.semicolon, "';' after for-init");
        var cond: NodeId = hir_mod.none_node_id;
        if (self.peek().kind != .semicolon) cond = try self.parseExpression();
        _ = try self.expect(.semicolon, "';' after for-condition");
        var update: NodeId = hir_mod.none_node_id;
        if (self.peek().kind != .close_paren) update = try self.parseExpression();
        _ = try self.expect(.close_paren, "')' to close for header");
        const body = try self.parseStatement();
        const end_pos = self.hir.spanOf(body).end;
        return try self.builder.addFor(.{ .start = start.span.start, .end = end_pos }, init_node, cond, update, body);
    }

    fn parseBreakStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // break
        var label: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .identifier and !self.peek().flags.preceded_by_newline) {
            const lab_tok = self.advance();
            const lab_id = try self.internToken(lab_tok);
            label = try self.builder.addIdentifier(tokenSpan(lab_tok), lab_id);
        }
        try self.consumeStatementTerminator();
        const end_pos: u32 = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
        return try self.builder.addBreak(.{ .start = start.span.start, .end = end_pos }, label);
    }

    fn parseContinueStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // continue
        var label: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .identifier and !self.peek().flags.preceded_by_newline) {
            const lab_tok = self.advance();
            const lab_id = try self.internToken(lab_tok);
            label = try self.builder.addIdentifier(tokenSpan(lab_tok), lab_id);
        }
        try self.consumeStatementTerminator();
        const end_pos: u32 = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
        return try self.builder.addContinue(.{ .start = start.span.start, .end = end_pos }, label);
    }

    fn parseThrowStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // throw
        // ASI restriction: throw cannot be followed by a newline before
        // the expression. If a newline intervenes, we still attempt to
        // parse for recovery, since most editors will see this as an
        // unfinished statement.
        const value = try self.parseExpression();
        try self.consumeStatementTerminator();
        const end_pos = self.hir.spanOf(value).end;
        return try self.builder.addThrow(.{ .start = start.span.start, .end = end_pos }, value);
    }

    fn parseTryStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // try
        const block = try self.parseBlockStatement();
        var catch_param: NodeId = hir_mod.none_node_id;
        var catch_block: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_catch)) {
            if (self.match(.open_paren)) {
                const name_tok = try self.expect(.identifier, "identifier in catch binding");
                if (self.match(.colon)) try self.skipTypeAnnotation();
                _ = try self.expect(.close_paren, "')' to close catch param");
                const id = try self.internToken(name_tok);
                catch_param = try self.builder.addIdentifier(tokenSpan(name_tok), id);
            }
            catch_block = try self.parseBlockStatement();
        }
        var finally_block: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_finally)) finally_block = try self.parseBlockStatement();
        const end_pos: u32 = if (finally_block != hir_mod.none_node_id)
            self.hir.spanOf(finally_block).end
        else if (catch_block != hir_mod.none_node_id)
            self.hir.spanOf(catch_block).end
        else
            self.hir.spanOf(block).end;
        return try self.builder.addTry(.{ .start = start.span.start, .end = end_pos }, block, catch_param, catch_block, finally_block);
    }

    fn parseSwitchStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // switch
        _ = try self.expect(.open_paren, "'(' after 'switch'");
        const discriminant = try self.parseExpression();
        _ = try self.expect(.close_paren, "')' after switch discriminant");
        _ = try self.expect(.open_brace, "'{' to open switch body");

        var cases: std.ArrayListUnmanaged(NodeId) = .empty;
        defer cases.deinit(self.gpa);

        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const case_start = self.peek();
            var value: NodeId = hir_mod.none_node_id;
            if (self.match(.kw_case)) {
                value = try self.parseExpression();
            } else if (!self.match(.kw_default)) {
                try self.report("expected ", "'case' or 'default' in switch body");
                return error.UnexpectedToken;
            }
            _ = try self.expect(.colon, "':' after case label");
            var stmts: std.ArrayListUnmanaged(NodeId) = .empty;
            defer stmts.deinit(self.gpa);
            while (true) {
                const k = self.peek().kind;
                if (k == .kw_case or k == .kw_default or k == .close_brace or k == .eof) break;
                try stmts.append(self.gpa, try self.parseStatement());
            }
            const last_end: u32 = if (stmts.items.len > 0)
                self.hir.spanOf(stmts.items[stmts.items.len - 1]).end
            else
                case_start.span.end;
            const case = try self.builder.addSwitchCase(.{
                .start = case_start.span.start,
                .end = last_end,
            }, value, stmts.items);
            try cases.append(self.gpa, case);
        }
        const close = try self.expect(.close_brace, "'}' to close switch body");
        return try self.builder.addSwitch(.{ .start = start.span.start, .end = close.span.end }, discriminant, cases.items);
    }

    fn parseFunctionDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // function
        const is_generator = self.match(.asterisk);
        // Function name (optional in expression context, required in
        // declaration). Phase 1.D treats `function` as a declaration only
        // when at statement position; named-fn-expression handling lives
        // in parseUnaryExpression's primary path (deferred follow-up).
        var name: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .identifier) {
            const name_tok = self.advance();
            const name_id = try self.internToken(name_tok);
            name = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        }
        // Generic type parameters — Phase 1.D skips them.
        if (self.peek().kind == .less_than) try self.skipTypeAnnotation();
        const params = try self.parseParameterList();
        defer self.gpa.free(params);

        const return_type: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) try self.skipTypeAnnotation();

        var body: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .open_brace) {
            body = try self.parseBlockStatement();
        } else {
            // Ambient declaration `function foo(...);`.
            try self.consumeStatementTerminator();
        }
        const end_pos: u32 = if (body != hir_mod.none_node_id)
            self.hir.spanOf(body).end
        else if (self.cursor > 0)
            self.tokens[self.cursor - 1].span.end
        else
            start.span.end;
        return try self.builder.addFnDecl(
            .{ .start = start.span.start, .end = end_pos },
            name,
            params,
            return_type,
            body,
            .{ .is_generator = is_generator },
        );
    }

    /// Parse a parenthesized parameter list. Allocates the result slice;
    /// caller frees with `gpa.free`.
    fn parseParameterList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.open_paren, "'(' for parameter list");
        var params: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer params.deinit(self.gpa);
        if (self.peek().kind != .close_paren) {
            while (true) {
                const param_start = self.peek();
                var flags: hir_mod.ParamFlags = .{};
                if (self.match(.dot_dot_dot)) flags.is_rest = true;
                const name_tok = try self.expect(.identifier, "parameter name");
                if (self.match(.question)) flags.is_optional = true;
                if (self.match(.colon)) try self.skipTypeAnnotation();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                const name_id = try self.internToken(name_tok);
                const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                const param = try self.builder.addParameter(
                    .{ .start = param_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    ident,
                    hir_mod.none_node_id,
                    default_value,
                    flags,
                );
                try params.append(self.gpa, param);
                if (!self.match(.comma)) break;
                if (self.peek().kind == .close_paren) break; // trailing comma
            }
        }
        _ = try self.expect(.close_paren, "')' to close parameter list");
        return try params.toOwnedSlice(self.gpa);
    }

    fn parseClassDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // class
        var name: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .identifier) {
            const name_tok = self.advance();
            const name_id = try self.internToken(name_tok);
            name = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        }
        // generic type-params skip
        if (self.peek().kind == .less_than) try self.skipTypeAnnotation();

        var extends: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_extends)) {
            extends = try self.parseLeftHandSideExpression();
        }
        var implements_list: std.ArrayListUnmanaged(NodeId) = .empty;
        defer implements_list.deinit(self.gpa);
        if (self.match(.kw_implements)) {
            while (true) {
                const ref = try self.parseTypeReference();
                try implements_list.append(self.gpa, ref);
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.open_brace, "'{' to open class body");
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            // For Phase 1.D we accept a permissive class body: skip
            // modifiers, then either parse a method (parens) or a
            // property (`name [: T] [= init];`). The proper class member
            // parser is a follow-up.
            try self.skipClassModifiers();
            const member_start = self.peek();
            // method?
            if (self.peek().kind == .identifier or self.peek().kind == .kw_constructor or self.peek().kind.isContextualKeyword()) {
                const name_tok = self.advance();
                if (self.peek().kind == .open_paren or self.peek().kind == .less_than) {
                    if (self.peek().kind == .less_than) try self.skipTypeAnnotation();
                    const params = try self.parseParameterList();
                    defer self.gpa.free(params);
                    if (self.match(.colon)) try self.skipTypeAnnotation();
                    var body: NodeId = hir_mod.none_node_id;
                    if (self.peek().kind == .open_brace) {
                        body = try self.parseBlockStatement();
                    } else {
                        try self.consumeStatementTerminator();
                    }
                    const name_id = try self.internToken(name_tok);
                    const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                    const fn_node = try self.builder.addFnDecl(
                        .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        name_node,
                        params,
                        hir_mod.none_node_id,
                        body,
                        .{
                            .is_method = true,
                            .is_constructor = name_tok.kind == .kw_constructor,
                        },
                    );
                    try members.append(self.gpa, fn_node);
                    continue;
                }
                // property
                if (self.match(.colon)) try self.skipTypeAnnotation();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                try self.consumeStatementTerminator();
                const name_id = try self.internToken(name_tok);
                const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                const prop = try self.builder.addObjectProperty(
                    .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    default_value,
                    false,
                    default_value == hir_mod.none_node_id,
                    false,
                );
                try members.append(self.gpa, prop);
                continue;
            }
            // Unknown — advance to keep error-recovery flowing.
            _ = self.advance();
        }
        const close = try self.expect(.close_brace, "'}' to close class body");
        return try self.builder.addClass(
            .{ .start = start.span.start, .end = close.span.end },
            name,
            &.{},
            extends,
            implements_list.items,
            members.items,
        );
    }

    fn skipClassModifiers(self: *Parser) ParseError!void {
        while (true) {
            const k = self.peek().kind;
            if (k.isModifierKeyword()) {
                _ = self.advance();
                continue;
            }
            return;
        }
    }

    fn parseInterfaceDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // interface
        const name_tok = try self.expect(.identifier, "interface name");
        if (self.peek().kind == .less_than) try self.skipTypeAnnotation();
        var extends_list: std.ArrayListUnmanaged(NodeId) = .empty;
        defer extends_list.deinit(self.gpa);
        if (self.match(.kw_extends)) {
            while (true) {
                const ref = try self.parseTypeReference();
                try extends_list.append(self.gpa, ref);
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.open_brace, "'{' to open interface body");
        // Phase 1.D scope: we skip the body content entirely. A real
        // member parser is a Phase 1 follow-up; we still produce an HIR
        // node so the binder can see the interface declaration.
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        var depth: i32 = 1;
        while (depth > 0 and self.peek().kind != .eof) {
            const t = self.peek();
            if (t.kind == .open_brace) {
                depth += 1;
            } else if (t.kind == .close_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
            _ = self.advance();
        }
        const close = try self.expect(.close_brace, "'}' to close interface body");
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        return try self.builder.addInterface(
            .{ .start = start.span.start, .end = close.span.end },
            name_node,
            &.{},
            extends_list.items,
            members.items,
        );
    }

    fn parseTypeAlias(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // type
        const name_tok = try self.expect(.identifier, "type alias name");
        if (self.peek().kind == .less_than) try self.skipTypeAnnotation();
        _ = try self.expect(.equal, "'=' in type alias");
        // Skip the type expression. Phase 1 follow-up: real type parser.
        try self.skipTypeAnnotation();
        try self.consumeStatementTerminator();
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        const end_pos = self.tokens[self.cursor - 1].span.end;
        return try self.builder.addTypeAlias(
            .{ .start = start.span.start, .end = end_pos },
            name_node,
            &.{},
            hir_mod.none_node_id,
        );
    }

    fn parseEnumDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // enum
        const name_tok = try self.expect(.identifier, "enum name");
        _ = try self.expect(.open_brace, "'{' to open enum body");
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const member_start = self.peek();
            const member_tok = if (self.peek().kind == .string_literal)
                self.advance()
            else
                try self.expect(.identifier, "enum member name");
            var value: NodeId = hir_mod.none_node_id;
            if (self.match(.equal)) value = try self.parseAssignmentExpression();
            const name_id = try self.internToken(member_tok);
            const name_node = try self.builder.addIdentifier(tokenSpan(member_tok), name_id);
            const member = try self.builder.addObjectProperty(
                .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                name_node,
                value,
                false,
                value == hir_mod.none_node_id,
                false,
            );
            try members.append(self.gpa, member);
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.close_brace, "'}' to close enum body");
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        return try self.builder.addEnum(
            .{ .start = start.span.start, .end = close.span.end },
            name_node,
            members.items,
            false,
        );
    }

    fn parseNamespaceDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // namespace / module
        const name_tok = if (self.peek().kind == .string_literal)
            self.advance()
        else
            try self.expect(.identifier, "namespace name");
        _ = try self.expect(.open_brace, "'{' to open namespace body");
        var body: std.ArrayListUnmanaged(NodeId) = .empty;
        defer body.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            try body.append(self.gpa, try self.parseStatement());
        }
        const close = try self.expect(.close_brace, "'}' to close namespace body");
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        return try self.builder.addNamespace(
            .{ .start = start.span.start, .end = close.span.end },
            name_node,
            body.items,
        );
    }

    fn parseImportDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // import
        const is_type_only = self.match(.kw_type);
        var default_binding: NodeId = hir_mod.none_node_id;
        var namespace_binding: NodeId = hir_mod.none_node_id;
        var named: std.ArrayListUnmanaged(NodeId) = .empty;
        defer named.deinit(self.gpa);

        if (self.peek().kind == .string_literal) {
            // bare side-effect import: `import "module";`
            const mod_tok = self.advance();
            try self.consumeStatementTerminator();
            const mod_id = try self.internStringLiteral(mod_tok);
            return try self.builder.addImport(
                .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                mod_id,
                hir_mod.none_node_id,
                hir_mod.none_node_id,
                &.{},
                is_type_only,
            );
        }

        // Default binding?
        if (self.peek().kind == .identifier) {
            const name_tok = self.advance();
            const id = try self.internToken(name_tok);
            default_binding = try self.builder.addIdentifier(tokenSpan(name_tok), id);
            if (!self.match(.comma)) {
                // Only default — proceed to from clause.
            }
        }

        // Namespace import: `* as ns`?
        if (self.match(.asterisk)) {
            _ = try self.expect(.kw_as, "'as' in namespace import");
            const name_tok = try self.expect(.identifier, "namespace import name");
            const id = try self.internToken(name_tok);
            namespace_binding = try self.builder.addIdentifier(tokenSpan(name_tok), id);
        }
        // Named imports: `{ a, b as c, type d }`?
        else if (self.match(.open_brace)) {
            while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
                const spec_start = self.peek();
                const spec_type_only = self.match(.kw_type);
                const imported_tok = if (self.peek().kind.isKeyword() or self.peek().kind == .identifier)
                    self.advance()
                else
                    return error.UnexpectedToken;
                var local_id = try self.internToken(imported_tok);
                const imported_id = local_id;
                if (self.match(.kw_as)) {
                    const local_tok = try self.expect(.identifier, "local name in 'as' clause");
                    local_id = try self.internToken(local_tok);
                }
                const spec = try self.builder.addImportSpecifier(
                    .{ .start = spec_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    imported_id,
                    local_id,
                    spec_type_only,
                );
                try named.append(self.gpa, spec);
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.close_brace, "'}' to close named imports");
        }

        _ = try self.expect(.kw_from, "'from' in import declaration");
        const mod_tok = try self.expect(.string_literal, "module specifier");
        try self.consumeStatementTerminator();
        const mod_id = try self.internStringLiteral(mod_tok);
        const end_pos = self.tokens[self.cursor - 1].span.end;
        return try self.builder.addImport(
            .{ .start = start.span.start, .end = end_pos },
            mod_id,
            default_binding,
            namespace_binding,
            named.items,
            is_type_only,
        );
    }

    fn parseExportDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // export
        const is_type_only = self.match(.kw_type);
        const empty_string = self.interner.intern("") catch return error.OutOfMemory;

        // export default <expr>;
        if (self.match(.kw_default)) {
            // `export default` may be followed by a class/function
            // *declaration* (no statement-terminator) — those have
            // their own statement parser; otherwise it's an
            // expression value.
            const decl = switch (self.peek().kind) {
                .kw_class => try self.parseClassDeclaration(),
                .kw_function => try self.parseFunctionDeclaration(),
                .kw_interface => try self.parseInterfaceDeclaration(),
                else => blk: {
                    const expr = try self.parseAssignmentExpression();
                    try self.consumeStatementTerminator();
                    break :blk expr;
                },
            };
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addExport(
                .{ .start = start.span.start, .end = end_pos },
                decl,
                &.{},
                empty_string,
                is_type_only,
                true,
            );
        }

        // export { a, b as c } [from "m"];
        if (self.match(.open_brace)) {
            var named: std.ArrayListUnmanaged(NodeId) = .empty;
            defer named.deinit(self.gpa);
            while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
                const spec_start = self.peek();
                const spec_type_only = self.match(.kw_type);
                const imported_tok = if (self.peek().kind.isKeyword() or self.peek().kind == .identifier)
                    self.advance()
                else
                    return error.UnexpectedToken;
                const imported_id = try self.internToken(imported_tok);
                var local_id = imported_id;
                if (self.match(.kw_as)) {
                    const local_tok = try self.expect(.identifier, "local name in 'as' clause");
                    local_id = try self.internToken(local_tok);
                }
                const spec = try self.builder.addImportSpecifier(
                    .{ .start = spec_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    imported_id,
                    local_id,
                    spec_type_only,
                );
                try named.append(self.gpa, spec);
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.close_brace, "'}' to close named exports");
            var module_id = empty_string;
            if (self.match(.kw_from)) {
                const mod_tok = try self.expect(.string_literal, "module specifier");
                module_id = try self.internStringLiteral(mod_tok);
            }
            try self.consumeStatementTerminator();
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addExport(
                .{ .start = start.span.start, .end = end_pos },
                hir_mod.none_node_id,
                named.items,
                module_id,
                is_type_only,
                false,
            );
        }

        // export * [as ns] from "m";
        if (self.match(.asterisk)) {
            if (self.match(.kw_as)) {
                _ = try self.expect(.identifier, "namespace name");
            }
            _ = try self.expect(.kw_from, "'from' after 'export *'");
            const mod_tok = try self.expect(.string_literal, "module specifier");
            try self.consumeStatementTerminator();
            const mod_id = try self.internStringLiteral(mod_tok);
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addExport(
                .{ .start = start.span.start, .end = end_pos },
                hir_mod.none_node_id,
                &.{},
                mod_id,
                is_type_only,
                false,
            );
        }

        // export <decl>
        const decl = try self.parseStatement();
        const end_pos = self.hir.spanOf(decl).end;
        return try self.builder.addExport(
            .{ .start = start.span.start, .end = end_pos },
            decl,
            &.{},
            empty_string,
            is_type_only,
            false,
        );
    }

    /// Parse a "left-hand-side" expression — primary + member-call
    /// chain. Used for `extends` clauses where a full assignment-level
    /// expression isn't grammatical.
    fn parseLeftHandSideExpression(self: *Parser) ParseError!NodeId {
        return try self.parseCallOrMemberExpression();
    }

    fn parseVarDecl(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // let/const/var
        const decl_kind: hir_mod.NodeKind = switch (start.kind) {
            .kw_let => .let_decl,
            .kw_const => .const_decl,
            .kw_var => .var_decl,
            else => unreachable,
        };
        // Phase 1.D scope: single binding per declaration. Multiple
        // bindings (`let x = 1, y = 2`) are a follow-up.
        const name_tok = try self.expect(.identifier, "identifier in variable declaration");
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);

        var type_annotation: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) {
            type_annotation = try self.parseTypeAnnotation();
        }

        var init_node: NodeId = hir_mod.none_node_id;
        if (self.match(.equal)) {
            init_node = try self.parseAssignmentExpression();
        }
        try self.consumeStatementTerminator();

        const stmt_span: Span = .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end };
        return try self.builder.addVarDecl(decl_kind, stmt_span, name_node, type_annotation, init_node);
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

    /// Skip a type annotation by walking it until a delimiter — used
    /// only in salvage paths where producing a real HIR type node
    /// isn't necessary (the body of an interface, the rhs of a
    /// `type X =`, etc.). Most callers prefer `parseTypeAnnotation`.
    fn skipTypeAnnotation(self: *Parser) ParseError!void {
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
    // Type annotation parser
    // ========================================================================
    //
    // Grammar (subset, builds out as features land):
    //
    //   Type            = ConditionalType
    //   ConditionalType = UnionType ('extends' UnionType '?' Type ':' Type)?
    //   UnionType       = ('|')? IntersectionType ('|' IntersectionType)*
    //   IntersectionType= ('&')? ArrayType ('&' ArrayType)*
    //   ArrayType       = NonArrayType ('[]' | '[' Type ']')*
    //   NonArrayType    = PrimaryType
    //   PrimaryType     = LiteralType | KeyofType | TypeofType | InferType
    //                   | TupleType | ParenType | TypeRef
    //                   | FnType
    //
    // We keep the parser permissive for forms it doesn't fully model
    // yet (object types {…} are lowered as a synthetic `unknown` type
    // ref so consumers see *something* without halting).

    /// Public entry: parse a single type annotation starting at the
    /// current cursor. Returns a HIR type node id.
    fn parseTypeAnnotation(self: *Parser) ParseError!NodeId {
        return try self.parseConditionalType();
    }

    fn parseConditionalType(self: *Parser) ParseError!NodeId {
        const check = try self.parseUnionType();
        if (self.peek().kind != .kw_extends) return check;
        const extends_kw = self.advance(); // extends
        _ = extends_kw;
        const extends_t = try self.parseUnionType();
        if (!self.match(.question)) return check;
        const true_branch = try self.parseTypeAnnotation();
        _ = try self.expect(.colon, "':' in conditional type");
        const false_branch = try self.parseTypeAnnotation();
        const sp: Span = .{
            .start = self.hir.spanOf(check).start,
            .end = self.hir.spanOf(false_branch).end,
        };
        return try self.builder.addConditionalType(sp, check, extends_t, true_branch, false_branch);
    }

    fn parseUnionType(self: *Parser) ParseError!NodeId {
        // Leading `|` is allowed: `type T = | A | B`.
        _ = self.match(.pipe);
        const first = try self.parseIntersectionType();
        if (self.peek().kind != .pipe) return first;
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        try members.append(self.gpa, first);
        while (self.match(.pipe)) {
            const m = try self.parseIntersectionType();
            try members.append(self.gpa, m);
        }
        const sp: Span = .{
            .start = self.hir.spanOf(first).start,
            .end = self.hir.spanOf(members.items[members.items.len - 1]).end,
        };
        return try self.builder.addUnionType(sp, members.items);
    }

    fn parseIntersectionType(self: *Parser) ParseError!NodeId {
        _ = self.match(.ampersand);
        const first = try self.parseTypeOperator();
        if (self.peek().kind != .ampersand) return first;
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        try members.append(self.gpa, first);
        while (self.match(.ampersand)) {
            const m = try self.parseTypeOperator();
            try members.append(self.gpa, m);
        }
        const sp: Span = .{
            .start = self.hir.spanOf(first).start,
            .end = self.hir.spanOf(members.items[members.items.len - 1]).end,
        };
        return try self.builder.addIntersectionType(sp, members.items);
    }

    /// `keyof T`, `typeof e`, `infer X`, `readonly T[]` (modifier
    /// stripped); other forms fall through to `parseArrayType`.
    fn parseTypeOperator(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        switch (t.kind) {
            .kw_keyof => {
                _ = self.advance();
                const operand = try self.parseTypeOperator();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addKeyofType(sp, operand);
            },
            .kw_typeof => {
                _ = self.advance();
                // `typeof` in a type position consumes a value
                // expression. Phase 1: take an identifier (with
                // qualified-name continuation) — full member access /
                // import.x is a follow-up.
                const ref_tok = try self.expect(.identifier, "identifier after typeof");
                const ref_id = try self.internToken(ref_tok);
                const ref = try self.builder.addIdentifier(tokenSpan(ref_tok), ref_id);
                const sp: Span = .{ .start = t.span.start, .end = ref_tok.span.end };
                return try self.builder.addTypeofType(sp, ref);
            },
            .kw_infer => {
                _ = self.advance();
                const name_tok = try self.expect(.identifier, "name after 'infer'");
                const name_id = try self.internToken(name_tok);
                var constraint: NodeId = hir_mod.none_node_id;
                if (self.match(.kw_extends)) {
                    constraint = try self.parseTypeOperator();
                }
                const end_pos: u32 = if (constraint != hir_mod.none_node_id)
                    self.hir.spanOf(constraint).end
                else
                    name_tok.span.end;
                return try self.builder.addInferType(.{ .start = t.span.start, .end = end_pos }, name_id, constraint);
            },
            .kw_readonly => {
                // `readonly T[]` — the modifier doesn't get its own
                // HIR node yet; we fold it as a comment-equivalent.
                _ = self.advance();
                return try self.parseArrayType();
            },
            else => return try self.parseArrayType(),
        }
    }

    fn parseArrayType(self: *Parser) ParseError!NodeId {
        var node = try self.parsePrimaryType();
        while (true) {
            if (self.match(.open_bracket)) {
                if (self.match(.close_bracket)) {
                    // `T[]`
                    const sp: Span = .{
                        .start = self.hir.spanOf(node).start,
                        .end = self.tokens[self.cursor - 1].span.end,
                    };
                    node = try self.builder.addArrayType(sp, node);
                    continue;
                }
                // `T[K]` — indexed access type.
                const index = try self.parseTypeAnnotation();
                _ = try self.expect(.close_bracket, "']' to close indexed access type");
                const sp: Span = .{
                    .start = self.hir.spanOf(node).start,
                    .end = self.tokens[self.cursor - 1].span.end,
                };
                node = try self.builder.addIndexedAccessType(sp, node, index);
                continue;
            }
            break;
        }
        return node;
    }

    fn parsePrimaryType(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        return switch (t.kind) {
            // Primitive type keywords — represented as type refs to
            // the global builtin name. The checker resolves them to
            // `Primitive.string_t`, `Primitive.number_t`, etc.
            .kw_any, .kw_unknown, .kw_never, .kw_void, .kw_string, .kw_number, .kw_boolean, .kw_bigint, .kw_symbol, .kw_object, .kw_undefined, .kw_null => blk: {
                _ = self.advance();
                const id = try self.internToken(t);
                break :blk try self.builder.addTypeRef(tokenSpan(t), id, &.{}, &.{});
            },
            .kw_true => blk: {
                _ = self.advance();
                const lit = try self.builder.addLiteralBool(tokenSpan(t), true);
                break :blk try self.builder.addLiteralType(tokenSpan(t), lit, false);
            },
            .kw_false => blk: {
                _ = self.advance();
                const lit = try self.builder.addLiteralBool(tokenSpan(t), false);
                break :blk try self.builder.addLiteralType(tokenSpan(t), lit, false);
            },
            .string_literal => blk: {
                _ = self.advance();
                const id = try self.internStringLiteral(t);
                const lit = try self.builder.addLiteralString(tokenSpan(t), id);
                break :blk try self.builder.addLiteralType(tokenSpan(t), lit, false);
            },
            .number_literal => blk: {
                _ = self.advance();
                const slice = self.source[t.span.start..t.span.end];
                const value = parseNumericLiteral(slice);
                const lit = try self.builder.addLiteralNumber(tokenSpan(t), value);
                break :blk try self.builder.addLiteralType(tokenSpan(t), lit, false);
            },
            .minus => blk: {
                // Negative numeric literal type: `-1`.
                _ = self.advance();
                const num = try self.expect(.number_literal, "numeric literal after '-' in type");
                const value = -parseNumericLiteral(self.source[num.span.start..num.span.end]);
                const lit = try self.builder.addLiteralNumber(tokenSpan(num), value);
                break :blk try self.builder.addLiteralType(.{ .start = t.span.start, .end = num.span.end }, lit, true);
            },
            .open_paren => try self.parseParenOrFnType(),
            .open_bracket => try self.parseTupleType(),
            .open_brace => try self.parseObjectOrMappedType(),
            .less_than => try self.parseGenericFnType(),
            .kw_new => try self.parseConstructorType(),
            .identifier => try self.parseTypeReference(),
            .kw_this => blk: {
                _ = self.advance();
                const id = self.interner.intern("this") catch return error.OutOfMemory;
                break :blk try self.builder.addTypeRef(tokenSpan(t), id, &.{}, &.{});
            },
            else => {
                // Unknown — emit a synthetic `unknown` type ref so the
                // upstream HIR shape stays valid; downstream binder /
                // checker will flag the diagnostic.
                _ = self.advance();
                const id = self.interner.intern("unknown") catch return error.OutOfMemory;
                return try self.builder.addTypeRef(tokenSpan(t), id, &.{}, &.{});
            },
        };
    }

    /// `(T)` (paren type) or `(a: T) => U` (function type).
    fn parseParenOrFnType(self: *Parser) ParseError!NodeId {
        // Speculative: snapshot cursor; if we see `=>` after the close
        // paren, it's a function type. Otherwise reset and parse as a
        // grouped type.
        const start = self.cursor;
        const open_tok = self.advance(); // '('

        // Quick scan for `=>` ignoring matched delimiters.
        var depth: i32 = 1;
        var i = self.cursor;
        var is_fn = false;
        var is_zero_arg = false;
        if (self.peek().kind == .close_paren) is_zero_arg = true;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (tk == .open_paren or tk == .open_bracket or tk == .open_brace or tk == .less_than) depth += 1;
            if (tk == .close_paren or tk == .close_bracket or tk == .close_brace or tk == .greater_than) {
                depth -= 1;
                if (depth == 0) {
                    if (i + 1 < self.tokens.len and self.tokens[i + 1].kind == .arrow) {
                        is_fn = true;
                    }
                    break;
                }
            }
            if (tk == .eof) break;
        }

        if (is_fn or is_zero_arg) {
            // Reset to before the open paren and parse fn type.
            self.cursor = start;
            return try self.parseFnTypeFromParen(false);
        }

        const inner = try self.parseTypeAnnotation();
        const close = try self.expect(.close_paren, "')' to close grouped type");
        _ = open_tok;
        _ = close;
        return inner;
    }

    fn parseFnTypeFromParen(self: *Parser, is_constructor: bool) ParseError!NodeId {
        const start = self.peek();
        const params = try self.parseTypeParameterList();
        defer self.gpa.free(params);
        _ = try self.expect(.arrow, "'=>' in function type");
        const ret = try self.parseTypeAnnotation();
        const sp: Span = .{ .start = start.span.start, .end = self.hir.spanOf(ret).end };
        return try self.builder.addFnType(sp, &.{}, params, ret, is_constructor);
    }

    /// Parse `(p1: T1, p2: T2)` and return parameter HIR nodes.
    fn parseTypeParameterList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.open_paren, "'(' for fn-type parameter list");
        var params: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer params.deinit(self.gpa);
        if (self.peek().kind != .close_paren) {
            while (true) {
                const ps = self.peek();
                var flags: hir_mod.ParamFlags = .{};
                if (self.match(.dot_dot_dot)) flags.is_rest = true;
                // The name is optional in fn types: `(string) => void`
                // is sometimes written as `(arg0: string) => void`. We
                // require an identifier for now; type-only param lists
                // without names are a follow-up.
                const name_tok = try self.expect(.identifier, "fn-type parameter name");
                if (self.match(.question)) flags.is_optional = true;
                var type_ann: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) type_ann = try self.parseTypeAnnotation();
                const name_id = try self.internToken(name_tok);
                const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                const param = try self.builder.addParameter(
                    .{ .start = ps.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    ident,
                    type_ann,
                    hir_mod.none_node_id,
                    flags,
                );
                try params.append(self.gpa, param);
                if (!self.match(.comma)) break;
                if (self.peek().kind == .close_paren) break;
            }
        }
        _ = try self.expect(.close_paren, "')' to close fn-type params");
        return try params.toOwnedSlice(self.gpa);
    }

    fn parseTupleType(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.open_bracket, "'[' to start tuple type");
        var elems: std.ArrayListUnmanaged(NodeId) = .empty;
        defer elems.deinit(self.gpa);
        while (self.peek().kind != .close_bracket and self.peek().kind != .eof) {
            // Accept (and ignore for now) leading `name:` labelled
            // tuple elements: `[x: number, y: number]`.
            if (self.peek().kind == .identifier and self.peekAt(1).kind == .colon) {
                _ = self.advance();
                _ = self.advance();
            }
            // Rest element prefix `...T`.
            _ = self.match(.dot_dot_dot);
            const e = try self.parseTypeAnnotation();
            _ = self.match(.question); // optional element marker
            try elems.append(self.gpa, e);
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.close_bracket, "']' to close tuple type");
        return try self.builder.addTupleType(.{ .start = open.span.start, .end = close.span.end }, elems.items);
    }

    /// `{ ...members... }` — object type literal. Phase 1 lowers to
    /// a synthetic type ref since we don't yet model member lists in
    /// HIR types directly. We *do* consume the body to keep the
    /// parser balanced.
    fn parseObjectOrMappedType(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.open_brace, "'{' to start object type");
        // Detect mapped type: `{ [K in T]: V }`.
        if (self.peek().kind == .open_bracket and self.peekAt(2).kind == .kw_in) {
            _ = self.advance(); // `[`
            const k_tok = try self.expect(.identifier, "key in mapped type");
            const k_id = try self.internToken(k_tok);
            _ = try self.expect(.kw_in, "'in' in mapped type");
            const constraint = try self.parseTypeAnnotation();
            _ = try self.expect(.close_bracket, "']' to close mapped type key");
            // Optional `?` modifier
            var optional_mod: u8 = 0;
            if (self.match(.question)) optional_mod = 1;
            _ = try self.expect(.colon, "':' in mapped type");
            const value = try self.parseTypeAnnotation();
            _ = self.match(.semicolon);
            const close = try self.expect(.close_brace, "'}' to close mapped type");
            const tp = try self.builder.addTypeParameter(tokenSpan(k_tok), k_id, hir_mod.none_node_id, hir_mod.none_node_id, 0);
            return try self.builder.addMappedType(.{ .start = open.span.start, .end = close.span.end }, tp, constraint, value, 0, optional_mod);
        }
        // Skip the body until matching close. Member-list lowering is
        // a Phase 1 follow-up; we emit a synthetic `object` type ref.
        var depth: i32 = 1;
        while (depth > 0 and self.peek().kind != .eof) {
            const tk = self.peek().kind;
            if (tk == .open_brace) {
                depth += 1;
            } else if (tk == .close_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
            _ = self.advance();
        }
        const close = try self.expect(.close_brace, "'}' to close object type");
        const id = self.interner.intern("object") catch return error.OutOfMemory;
        return try self.builder.addTypeRef(.{ .start = open.span.start, .end = close.span.end }, id, &.{}, &.{});
    }

    fn parseGenericFnType(self: *Parser) ParseError!NodeId {
        const start = self.peek();
        const tps = try self.parseTypeParameterDeclaration();
        defer self.gpa.free(tps);
        const params = try self.parseTypeParameterList();
        defer self.gpa.free(params);
        _ = try self.expect(.arrow, "'=>' in generic fn type");
        const ret = try self.parseTypeAnnotation();
        const sp: Span = .{ .start = start.span.start, .end = self.hir.spanOf(ret).end };
        return try self.builder.addFnType(sp, tps, params, ret, false);
    }

    fn parseConstructorType(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // new
        var tps: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            tps = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(tps);
        const params = try self.parseTypeParameterList();
        defer self.gpa.free(params);
        _ = try self.expect(.arrow, "'=>' in constructor type");
        const ret = try self.parseTypeAnnotation();
        const sp: Span = .{ .start = start.span.start, .end = self.hir.spanOf(ret).end };
        return try self.builder.addFnType(sp, tps, params, ret, true);
    }

    /// Parse `<T, U extends V = D>`. Returns owned slice of
    /// `type_parameter` HIR nodes.
    fn parseTypeParameterDeclaration(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.less_than, "'<' to open type parameters");
        var tps: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer tps.deinit(self.gpa);
        while (self.peek().kind != .greater_than and self.peek().kind != .eof) {
            const tp_start = self.peek();
            // Variance modifiers `in`/`out`.
            var variance: u8 = 0;
            if (self.peek().kind == .kw_in and self.peekAt(1).kind == .identifier) {
                _ = self.advance();
                variance |= 1;
            }
            if (self.peek().kind == .kw_out and self.peekAt(1).kind == .identifier) {
                _ = self.advance();
                variance |= 2;
            }
            const name_tok = try self.expect(.identifier, "type parameter name");
            const name_id = try self.internToken(name_tok);
            var constraint: NodeId = hir_mod.none_node_id;
            if (self.match(.kw_extends)) constraint = try self.parseTypeAnnotation();
            var default: NodeId = hir_mod.none_node_id;
            if (self.match(.equal)) default = try self.parseTypeAnnotation();
            const tp = try self.builder.addTypeParameter(
                .{ .start = tp_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                name_id,
                constraint,
                default,
                variance,
            );
            try tps.append(self.gpa, tp);
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.greater_than, "'>' to close type parameters");
        return try tps.toOwnedSlice(self.gpa);
    }

    /// `Foo`, `Foo.Bar`, `Foo<T, U>`. The lexer hands us the `<` only
    /// when it can tell from context — in type position it's always
    /// generic args, never a comparison.
    fn parseTypeReference(self: *Parser) ParseError!NodeId {
        const start = self.peek();
        const name_tok = try self.expect(.identifier, "type name");
        const final_name = try self.internToken(name_tok);

        var qualifier: std.ArrayListUnmanaged(NodeId) = .empty;
        defer qualifier.deinit(self.gpa);
        var name_id = final_name;

        // `A.B.C` — every `.B` extends the qualifier.
        while (self.peek().kind == .dot) {
            _ = self.advance();
            const next_tok = try self.expect(.identifier, "qualified-name member");
            const prev_id = name_id;
            const prev_node = try self.builder.addIdentifier(tokenSpan(name_tok), prev_id);
            try qualifier.append(self.gpa, prev_node);
            name_id = try self.internToken(next_tok);
        }

        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        defer args.deinit(self.gpa);
        if (self.peek().kind == .less_than) {
            _ = self.advance();
            while (self.peek().kind != .greater_than and self.peek().kind != .eof) {
                const a = try self.parseTypeAnnotation();
                try args.append(self.gpa, a);
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.greater_than, "'>' to close type arguments");
        }

        const end_pos = self.tokens[self.cursor - 1].span.end;
        return try self.builder.addTypeRef(
            .{ .start = start.span.start, .end = end_pos },
            name_id,
            qualifier.items,
            args.items,
        );
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
            .open_bracket => return try self.parseArrayLiteral(),
            .open_brace => return try self.parseObjectLiteral(),
            .kw_this => {
                _ = self.advance();
                const this_id = self.interner.intern("this") catch return error.OutOfMemory;
                return try self.builder.addIdentifier(tokenSpan(t), this_id);
            },
            .kw_super => {
                _ = self.advance();
                const super_id = self.interner.intern("super") catch return error.OutOfMemory;
                return try self.builder.addIdentifier(tokenSpan(t), super_id);
            },
            .kw_new => {
                _ = self.advance();
                // Phase 1.D: lower `new Foo(args)` as a call expression
                // — the binder distinguishes via parent-decoration. The
                // dedicated `new_expr` HIR kind exists but is reserved
                // for the follow-up that introduces an explicit lowering.
                const callee = try self.parseLeftHandSideExpression();
                if (self.peek().kind == .open_paren) {
                    const args = try self.parseArgumentList();
                    defer self.gpa.free(args);
                    const close_pos = self.tokens[self.cursor - 1].span.end;
                    return try self.builder.addCall(.{ .start = t.span.start, .end = close_pos }, callee, args);
                }
                return try self.builder.addCall(.{ .start = t.span.start, .end = self.hir.spanOf(callee).end }, callee, &.{});
            },
            .kw_function => {
                // Function expression — reuse declaration parser; it
                // will emit `fn_decl` even when used as expression.
                return try self.parseFunctionDeclaration();
            },
            else => {
                try self.report("unexpected token in expression: ", @tagName(t.kind));
                return error.UnexpectedToken;
            },
        }
    }

    fn parseArrayLiteral(self: *Parser) ParseError!NodeId {
        const start = try self.expect(.open_bracket, "'[' to start array literal");
        var elements: std.ArrayListUnmanaged(NodeId) = .empty;
        defer elements.deinit(self.gpa);
        while (self.peek().kind != .close_bracket and self.peek().kind != .eof) {
            if (self.peek().kind == .comma) {
                // Hole — represent as `none` for now. (TS treats
                // `[,1]` as `[undefined, 1]`.)
                _ = self.advance();
                try elements.append(self.gpa, hir_mod.none_node_id);
                continue;
            }
            const e = try self.parseAssignmentExpression();
            try elements.append(self.gpa, e);
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.close_bracket, "']' to close array literal");
        return try self.builder.addArrayLiteral(.{ .start = start.span.start, .end = close.span.end }, elements.items);
    }

    fn parseObjectLiteral(self: *Parser) ParseError!NodeId {
        const start = try self.expect(.open_brace, "'{' to start object literal");
        var props: std.ArrayListUnmanaged(NodeId) = .empty;
        defer props.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const prop_start = self.peek();
            // Spread element: `...expr`.
            if (self.match(.dot_dot_dot)) {
                const value = try self.parseAssignmentExpression();
                // Lower as a property with a synthetic `..` key — for
                // now just store the value as the property and mark it
                // as a method to flag "non-standard." A dedicated spread
                // node is a follow-up.
                try props.append(self.gpa, value);
                if (!self.match(.comma)) break;
                continue;
            }

            // Computed key: `[expr]: value`.
            var key: NodeId = undefined;
            var is_computed = false;
            if (self.match(.open_bracket)) {
                key = try self.parseAssignmentExpression();
                _ = try self.expect(.close_bracket, "']' to close computed property name");
                is_computed = true;
            } else {
                const key_tok = self.advance();
                const key_id = self.interner.intern(self.source[key_tok.span.start..key_tok.span.end]) catch return error.OutOfMemory;
                key = try self.builder.addIdentifier(tokenSpan(key_tok), key_id);
            }

            var value: NodeId = hir_mod.none_node_id;
            var is_shorthand = false;
            var is_method = false;
            if (self.match(.colon)) {
                value = try self.parseAssignmentExpression();
            } else if (self.peek().kind == .open_paren) {
                // Method shorthand: `{ foo() {} }`.
                const params = try self.parseParameterList();
                defer self.gpa.free(params);
                if (self.match(.colon)) try self.skipTypeAnnotation();
                var body: NodeId = hir_mod.none_node_id;
                if (self.peek().kind == .open_brace) body = try self.parseBlockStatement();
                value = try self.builder.addFnDecl(
                    .{ .start = prop_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    hir_mod.none_node_id,
                    params,
                    hir_mod.none_node_id,
                    body,
                    .{ .is_method = true },
                );
                is_method = true;
            } else {
                // Shorthand property: `{ foo }` — value mirrors the key
                // identifier.
                is_shorthand = true;
                value = key;
            }
            const prop = try self.builder.addObjectProperty(
                .{ .start = prop_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                key,
                value,
                is_computed,
                is_shorthand,
                is_method,
            );
            try props.append(self.gpa, prop);
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.close_brace, "'}' to close object literal");
        return try self.builder.addObjectLiteral(.{ .start = start.span.start, .end = close.span.end }, props.items);
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
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[0]));
    const vd = hir_mod.varDeclOf(&s.hir, stmts[0]);
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(vd.init));
}

test "parser: var / const / let produce distinct kinds" {
    var s = try newTestSetup("var a = 1; let b = 2; const c = 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 3), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.var_decl, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.const_decl, s.hir.kindOf(stmts[2]));
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
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[0]));
    const vd = hir_mod.varDeclOf(&s.hir, stmts[0]);
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(vd.init));
}

// ====================================================================
// Phase 1.D follow-ups: control flow, declarations, imports
// ====================================================================

test "parser: if statement without else" {
    var s = try newTestSetup("if (x) { return 1; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.if_stmt, s.hir.kindOf(top));
    const ifp = hir_mod.ifOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(ifp.cond));
    try T.expectEqual(hir_mod.NodeKind.block_stmt, s.hir.kindOf(ifp.then_branch));
    try T.expectEqual(hir_mod.none_node_id, ifp.else_branch);
}

test "parser: if/else if chain" {
    var s = try newTestSetup("if (a) 1; else if (b) 2; else 3;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.if_stmt, s.hir.kindOf(top));
    const outer = hir_mod.ifOf(&s.hir, top);
    try T.expect(outer.else_branch != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.if_stmt, s.hir.kindOf(outer.else_branch));
}

test "parser: while loop" {
    var s = try newTestSetup("while (x > 0) { x = x - 1; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.while_stmt, s.hir.kindOf(top));
    const w = hir_mod.whileOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(w.cond));
}

test "parser: do-while loop" {
    var s = try newTestSetup("do { x = x + 1; } while (x < 10);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.do_while_stmt, s.hir.kindOf(top));
}

test "parser: classic for loop" {
    var s = try newTestSetup("for (let i = 0; i < 10; i = i + 1) { sum = sum + i; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_stmt, s.hir.kindOf(top));
    const f = hir_mod.forStmtOf(&s.hir, top);
    try T.expect(f.init != hir_mod.none_node_id);
    try T.expect(f.cond != hir_mod.none_node_id);
    try T.expect(f.update != hir_mod.none_node_id);
}

test "parser: for-in loop" {
    var s = try newTestSetup("for (let k in obj) { use(k); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_in_stmt, s.hir.kindOf(top));
}

test "parser: for-of loop" {
    var s = try newTestSetup("for (let v of items) { sum = sum + v; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_of_stmt, s.hir.kindOf(top));
}

test "parser: break and continue" {
    var s = try newTestSetup("while (x) { break; continue; break label; continue label; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const body_id = hir_mod.whileOf(&s.hir, top).body;
    const stmts = hir_mod.blockStmts(&s.hir, body_id);
    try T.expectEqual(@as(usize, 4), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.break_stmt, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.continue_stmt, s.hir.kindOf(stmts[1]));
    try T.expect(hir_mod.labelOf(&s.hir, stmts[0]).label == hir_mod.none_node_id);
    try T.expect(hir_mod.labelOf(&s.hir, stmts[2]).label != hir_mod.none_node_id);
}

test "parser: throw statement" {
    var s = try newTestSetup("throw new Error(\"bad\");");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.throw_stmt, s.hir.kindOf(top));
}

test "parser: try-catch-finally" {
    var s = try newTestSetup("try { f(); } catch (e) { log(e); } finally { cleanup(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.try_stmt, s.hir.kindOf(top));
    const tp = hir_mod.tryOf(&s.hir, top);
    try T.expect(tp.catch_block != hir_mod.none_node_id);
    try T.expect(tp.catch_param != hir_mod.none_node_id);
    try T.expect(tp.finally_block != hir_mod.none_node_id);
}

test "parser: try without catch" {
    var s = try newTestSetup("try { f(); } finally { cleanup(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.try_stmt, s.hir.kindOf(top));
    const tp = hir_mod.tryOf(&s.hir, top);
    try T.expectEqual(hir_mod.none_node_id, tp.catch_block);
    try T.expect(tp.finally_block != hir_mod.none_node_id);
}

test "parser: switch with cases and default" {
    var s = try newTestSetup(
        \\switch (x) {
        \\  case 1: f(); break;
        \\  case 2: g(); break;
        \\  default: h();
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.switch_stmt, s.hir.kindOf(top));
    const cases = hir_mod.switchCases(&s.hir, top);
    try T.expectEqual(@as(usize, 3), cases.len);
    // Default case has none_node_id value.
    try T.expectEqual(hir_mod.none_node_id, hir_mod.switchCaseOf(&s.hir, cases[2]).value);
}

test "parser: function declaration with parameters and body" {
    var s = try newTestSetup("function add(a, b) { return a + b; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const fn_p = hir_mod.fnDeclOf(&s.hir, top);
    try T.expect(fn_p.name != hir_mod.none_node_id);
    const params = hir_mod.fnParams(&s.hir, top);
    try T.expectEqual(@as(usize, 2), params.len);
}

test "parser: function with type annotations skipped" {
    var s = try newTestSetup("function id(x: number): number { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
}

test "parser: function with optional and rest parameters" {
    var s = try newTestSetup("function fmt(prefix, value?, ...rest) { return prefix; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const params = hir_mod.fnParams(&s.hir, top);
    try T.expectEqual(@as(usize, 3), params.len);
    try T.expect(hir_mod.parameterOf(&s.hir, params[1]).flags.is_optional);
    try T.expect(hir_mod.parameterOf(&s.hir, params[2]).flags.is_rest);
}

test "parser: class declaration with method and property" {
    var s = try newTestSetup(
        \\class Foo {
        \\  x = 1;
        \\  greet(name) { return name; }
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
    const cl = hir_mod.classOf(&s.hir, top);
    try T.expect(cl.name != hir_mod.none_node_id);
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 2), members.len);
}

test "parser: class extends" {
    var s = try newTestSetup("class Bar extends Foo {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const cl = hir_mod.classOf(&s.hir, top);
    try T.expect(cl.extends != hir_mod.none_node_id);
}

test "parser: interface declaration" {
    var s = try newTestSetup("interface Point { x: number; y: number; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.interface_decl, s.hir.kindOf(top));
}

test "parser: type alias" {
    var s = try newTestSetup("type Pair = [number, number];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.type_alias_decl, s.hir.kindOf(top));
}

test "parser: enum declaration" {
    var s = try newTestSetup("enum Color { Red, Green, Blue }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.enum_decl, s.hir.kindOf(top));
    const members = hir_mod.enumMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 3), members.len);
}

test "parser: namespace declaration" {
    var s = try newTestSetup("namespace Math { let pi = 3.14; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.namespace_decl, s.hir.kindOf(top));
}

test "parser: import default" {
    var s = try newTestSetup("import React from \"react\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(top));
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expect(imp.default_binding != hir_mod.none_node_id);
    try T.expectEqualStrings("react", s.interner.get(imp.module));
}

test "parser: import named" {
    var s = try newTestSetup("import { useState, useEffect as effect } from \"react\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const named = hir_mod.importNamed(&s.hir, top);
    try T.expectEqual(@as(usize, 2), named.len);
}

test "parser: import namespace" {
    var s = try newTestSetup("import * as fs from \"fs\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expect(imp.namespace_binding != hir_mod.none_node_id);
}

test "parser: import type-only" {
    var s = try newTestSetup("import type { Foo } from \"./types\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expect(hir_mod.importOf(&s.hir, top).is_type_only);
}

test "parser: bare side-effect import" {
    var s = try newTestSetup("import \"polyfill\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(top));
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expectEqual(hir_mod.none_node_id, imp.default_binding);
    try T.expectEqual(hir_mod.none_node_id, imp.namespace_binding);
}

test "parser: export default" {
    var s = try newTestSetup("export default 42;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.export_decl, s.hir.kindOf(top));
    try T.expect(hir_mod.exportOf(&s.hir, top).is_default);
}

test "parser: export named" {
    var s = try newTestSetup("export { a, b as c };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const ex = hir_mod.exportOf(&s.hir, top);
    try T.expectEqual(@as(usize, 2), hir_mod.exportNamed(&s.hir, top).len);
    try T.expect(!ex.is_default);
}

test "parser: export decl" {
    var s = try newTestSetup("export function id(x) { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.export_decl, s.hir.kindOf(top));
    const ex = hir_mod.exportOf(&s.hir, top);
    try T.expect(ex.decl != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(ex.decl));
}

test "parser: array literal" {
    var s = try newTestSetup("let a = [1, 2, 3];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.array_literal, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 3), hir_mod.arrayLiteralElements(&s.hir, init_node).len);
}

test "parser: object literal" {
    var s = try newTestSetup("let o = { x: 1, y: 2, z };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.object_literal, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 3), hir_mod.objectLiteralProps(&s.hir, init_node).len);
}

test "parser: object method shorthand" {
    var s = try newTestSetup("let o = { greet() { return 1; } };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const props = hir_mod.objectLiteralProps(&s.hir, init_node);
    try T.expect(hir_mod.objectPropertyOf(&s.hir, props[0]).is_method);
}

test "parser: this and super" {
    var s = try newTestSetup("this.x; super.y;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(stmts[1]));
}

test "parser: new expression" {
    var s = try newTestSetup("new Foo(1, 2);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(top));
}

// ====================================================================
// Type annotation parsing
// ====================================================================

test "parser: type annotation — primitive ref" {
    var s = try newTestSetup("let x: number = 1;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expect(v.type_annotation != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(v.type_annotation));
    const tr = hir_mod.typeRefOf(&s.hir, v.type_annotation);
    try T.expectEqualStrings("number", s.interner.get(tr.name));
}

test "parser: type annotation — union" {
    var s = try newTestSetup("let x: number | string = 1;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.union_type, s.hir.kindOf(v.type_annotation));
    try T.expectEqual(@as(usize, 2), hir_mod.unionTypeMembers(&s.hir, v.type_annotation).len);
}

test "parser: type annotation — intersection" {
    var s = try newTestSetup("let x: A & B = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.intersection_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — array T[]" {
    var s = try newTestSetup("let x: number[] = [];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.array_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — generic type ref Foo<T>" {
    var s = try newTestSetup("let x: Array<number> = [];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    const tr = hir_mod.typeRefOf(&s.hir, v.type_annotation);
    try T.expectEqual(@as(usize, 1), tr.args_len);
}

test "parser: type annotation — qualified name" {
    var s = try newTestSetup("let x: A.B.C = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(v.type_annotation));
    const tr = hir_mod.typeRefOf(&s.hir, v.type_annotation);
    try T.expectEqualStrings("C", s.interner.get(tr.name));
    try T.expectEqual(@as(usize, 2), tr.qualifier_len);
}

test "parser: type annotation — tuple" {
    var s = try newTestSetup("let x: [number, string] = [1, \"a\"];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.tuple_type, s.hir.kindOf(v.type_annotation));
    try T.expectEqual(@as(usize, 2), hir_mod.tupleTypeElements(&s.hir, v.type_annotation).len);
}

test "parser: type annotation — keyof" {
    var s = try newTestSetup("let x: keyof Foo = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.keyof_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — typeof in type position" {
    var s = try newTestSetup("let x: typeof y = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — indexed access T[K]" {
    var s = try newTestSetup("let x: A[B] = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.indexed_access_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — fn type" {
    var s = try newTestSetup("let f: (a: number) => string = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — literal types" {
    var s = try newTestSetup("let x: \"hello\" | 42 | true = \"hello\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.union_type, s.hir.kindOf(v.type_annotation));
    const members = hir_mod.unionTypeMembers(&s.hir, v.type_annotation);
    try T.expectEqual(@as(usize, 3), members.len);
    try T.expectEqual(hir_mod.NodeKind.type_literal, s.hir.kindOf(members[0]));
    try T.expectEqual(hir_mod.NodeKind.type_literal, s.hir.kindOf(members[1]));
    try T.expectEqual(hir_mod.NodeKind.type_literal, s.hir.kindOf(members[2]));
}

test "parser: type annotation — conditional type" {
    var s = try newTestSetup("let x: T extends U ? A : B = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.conditional_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — leading | accepted" {
    var s = try newTestSetup("let x: | A | B = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.union_type, s.hir.kindOf(v.type_annotation));
}

test "parser: function expression in let-binding" {
    var s = try newTestSetup("let f = function (x) { return x + 1; };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(top));
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(init_node));
}
