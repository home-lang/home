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

pub const jsdoc = @import("jsdoc.zig");
test {
    _ = jsdoc;
}

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
    /// True for `.tsx` files. Enables JSX parsing in expression
    /// position; the parser disambiguates `<T>x` (generic type
    /// assertion) vs. `<T>x</T>` (JSX) via the `<T,>` and
    /// `<T extends unknown>` rules from the TS grammar.
    is_tsx: bool,

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
            .is_tsx = false,
        };
    }

    /// Enable JSX parsing in expression position (set by callers
    /// for `.tsx` source files).
    pub fn setTsx(self: *Parser, enabled: bool) void {
        self.is_tsx = enabled;
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
        // Decorators that precede class declarations (and `export`+
        // `class` chains) attach to the next decorated statement.
        // We collect them here and store them as leading siblings —
        // the binder / emitter walks back when it sees a decorated
        // declaration.
        if (self.peek().kind == .at) {
            const start = self.peek();
            const dec_expr = try self.parseDecoratorExpression();
            const dec = try self.builder.addDecorator(
                .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                dec_expr,
            );
            return dec;
        }
        const t = self.peek();
        return switch (t.kind) {
            .kw_let, .kw_const, .kw_var => blk: {
                // `const enum E { ... }` — TS const-enum declaration.
                // The `const` keyword here is part of the enum form,
                // not a variable declaration. Lower it to an
                // `enum_decl` with `is_const=true` so isolatedModules
                // and downstream checks can consult the flag.
                if (t.kind == .kw_const and self.peekAt(1).kind == .kw_enum) {
                    _ = self.advance(); // const
                    const ed = try self.parseEnumDeclaration();
                    self.hir.markEnumConst(ed);
                    break :blk ed;
                }
                break :blk try self.parseVarDecl();
            },
            .kw_using => blk: {
                // Stage 3 explicit resource management: `using x = expr;`.
                // `using` is contextual — only treat it as a declaration
                // when followed by an identifier on the same line. ASI
                // would otherwise insert a terminator after `using`.
                if (self.peekAt(1).kind == .identifier and
                    !self.peekAt(1).flags.preceded_by_newline)
                {
                    break :blk try self.parseUsingDecl(false);
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_await => blk: {
                // `await using x = expr;` — Stage 3 async dispose. The
                // bare `await expr;` form falls through to be parsed as
                // an expression statement.
                if (self.peekAt(1).kind == .kw_using and
                    !self.peekAt(1).flags.preceded_by_newline and
                    self.peekAt(2).kind == .identifier and
                    !self.peekAt(2).flags.preceded_by_newline)
                {
                    break :blk try self.parseUsingDecl(true);
                }
                break :blk try self.parseExpressionStatement();
            },
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
            .kw_async => blk: {
                // `async function f() { ... }` — consume the async
                // keyword and parse as a function decl with the
                // is_async flag set. Arrow async (`async () => ...`)
                // is handled in expression position.
                if (self.peekAt(1).kind == .kw_function) {
                    _ = self.advance(); // async
                    const fd = try self.parseFunctionDeclaration();
                    self.hir.markFnAsync(fd);
                    break :blk fd;
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_class => try self.parseClassDeclaration(),
            .kw_abstract => blk: {
                // `abstract class Foo { ... }` at statement position.
                // Other uses of `abstract` (member modifier inside a
                // class body) are handled by the member-modifier loop.
                if (self.peekAt(1).kind == .kw_class) {
                    break :blk try self.parseClassDeclaration();
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_interface => try self.parseInterfaceDeclaration(),
            .kw_enum => try self.parseEnumDeclaration(),
            .kw_namespace, .kw_module => try self.parseNamespaceDeclaration(),
            .kw_declare => blk: {
                // `declare global { … }` — consume `declare` and let
                // the `kw_global` arm below lower it to a namespace
                // named "global". Other `declare …` forms (`declare
                // const`, `declare function`, etc.) fall through to be
                // parsed as their non-ambient counterparts; the ambient
                // flag is recoverable from the modifier list once we
                // wire it through. For Phase 4.5 we only need
                // `declare global` for cross-file augmentation.
                _ = self.advance(); // declare
                break :blk try self.parseStatement();
            },
            .kw_global => blk: {
                // `global { … }` (or after `declare`) — lower as a
                // namespace_decl named "global". This is the AST shape
                // `Program.collectGlobalAugmentations` looks for.
                if (self.peekAt(1).kind == .open_brace) {
                    const start = self.advance(); // global
                    const name_id = try self.internToken(start);
                    const name_node = try self.builder.addIdentifier(tokenSpan(start), name_id);
                    _ = try self.expect(.open_brace, "'{' to open global body");
                    var body: std.ArrayListUnmanaged(NodeId) = .empty;
                    defer body.deinit(self.gpa);
                    while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
                        try body.append(self.gpa, try self.parseStatement());
                    }
                    const close = try self.expect(.close_brace, "'}' to close global body");
                    break :blk try self.builder.addNamespace(
                        .{ .start = start.span.start, .end = close.span.end },
                        name_node,
                        body.items,
                    );
                }
                break :blk try self.parseExpressionStatement();
            },
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
        // Optional `await` modifier — `for await (... of asyncIter)`.
        const is_await = self.match(.kw_await);
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
                } else if (is_await) {
                    return try self.builder.addForAwaitOf(.{ .start = start.span.start, .end = end_pos }, ident, source_expr, body);
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
                } else if (is_await) {
                    return try self.builder.addForAwaitOf(.{ .start = start.span.start, .end = end_pos }, head_expr, source_expr, body);
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
        // Generic type parameters: `function f<T extends U = D>(...)`.
        var type_params: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            type_params = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(type_params);
        const params = try self.parseParameterList();
        defer self.gpa.free(params);

        var return_type: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);

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
        return try self.builder.addFnDeclGeneric(
            .{ .start = start.span.start, .end = end_pos },
            name,
            type_params,
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
                // Capture `@dec` decorators on parameters so the
                // emitter can produce `__param(N, dec)` calls.
                var param_decorators: std.ArrayListUnmanaged(NodeId) = .empty;
                defer param_decorators.deinit(self.gpa);
                while (self.peek().kind == .at) {
                    const at_tok = self.advance();
                    const dec_expr = try self.parseLeftHandSideExpression();
                    const dec_node = try self.builder.addDecorator(.{
                        .start = at_tok.span.start,
                        .end = self.hir.spanOf(dec_expr).end,
                    }, dec_expr);
                    try param_decorators.append(self.gpa, dec_node);
                }
                // Modifiers on parameter properties: `readonly`, `public`, etc.
                while (self.peek().kind.isModifierKeyword()) {
                    _ = self.advance();
                }
                if (self.match(.dot_dot_dot)) flags.is_rest = true;
                // §3.A.11 — explicit `this: T` first parameter. TS
                // doesn't surface it at runtime; we capture it as a
                // parameter named "this" so the checker's existing
                // parameter-walk in `typeOfIdentifier` resolves
                // `this` inside the body. The JS emitter strips
                // any parameter named "this" before lowering.
                if (self.peek().kind == .kw_this) {
                    const this_tok = self.advance();
                    var this_ann: NodeId = hir_mod.none_node_id;
                    if (self.match(.colon)) this_ann = try self.parseTypeAnnotation();
                    const this_name_id = self.interner.intern("this") catch return error.OutOfMemory;
                    const this_ident = try self.builder.addIdentifier(tokenSpan(this_tok), this_name_id);
                    const this_param = try self.builder.addParameter(
                        .{ .start = this_tok.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        this_ident,
                        this_ann,
                        hir_mod.none_node_id,
                        .{},
                    );
                    try params.append(self.gpa, this_param);
                    if (!self.match(.comma)) break;
                    if (self.peek().kind == .close_paren) break;
                    continue;
                }
                // Destructuring parameter: `function f({ a, b } : T)` or
                // `function f([ x, y ] : T)`. The pattern stands in for
                // the parameter's "name" — downstream the binder walks
                // the pattern to declare each binding, and the checker
                // resolves identifier types through the pattern.
                const name_node: NodeId = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
                    break :blk try self.parseBindingPattern();
                } else id_blk: {
                    const name_tok = try self.expect(.identifier, "parameter name");
                    const name_id = try self.internToken(name_tok);
                    break :id_blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                };
                if (self.match(.question)) flags.is_optional = true;
                var type_ann: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) type_ann = try self.parseTypeAnnotation();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                const param = try self.builder.addParameterWithDecorators(
                    .{ .start = param_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    type_ann,
                    default_value,
                    flags,
                    param_decorators.items,
                );
                try params.append(self.gpa, param);
                if (!self.match(.comma)) break;
                if (self.peek().kind == .close_paren) break; // trailing comma
            }
        }
        _ = try self.expect(.close_paren, "')' to close parameter list");
        return try params.toOwnedSlice(self.gpa);
    }

    /// Parse an object or array destructuring pattern. Used in
    /// parameter and `let`/`const`/`var` binding positions:
    ///   `{ a }`, `{ a = 1 }`, `{ ...rest }`
    ///   `[ a ]`, `[ a = 1 ]`, `[ ...rest ]`, `[ , a ]` (elision)
    /// For v0 only shorthand keys are supported (no `{ a: b }`
    /// renaming, no nested patterns) — the binding is reused as both
    /// the property key (interned name) and the local identifier.
    fn parseBindingPattern(self: *Parser) ParseError!NodeId {
        const open = self.advance();
        const is_object = open.kind == .open_brace;
        const close_kind: TokenKind = if (is_object) .close_brace else .close_bracket;
        var elements: std.ArrayListUnmanaged(NodeId) = .empty;
        defer elements.deinit(self.gpa);
        if (self.peek().kind != close_kind) {
            while (true) {
                // Array elision: `[ , b ]` — for v0 we just skip the
                // comma and continue (no hole element is emitted).
                if (!is_object and self.peek().kind == .comma) {
                    _ = self.advance();
                    if (self.peek().kind == close_kind) break;
                    continue;
                }
                const elem_start = self.peek();
                var flags: hir_mod.ParamFlags = .{};
                if (self.match(.dot_dot_dot)) flags.is_rest = true;
                const name_tok = try self.expect(.identifier, "binding name");
                const name_id = try self.internToken(name_tok);
                const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                const elem = try self.builder.addParameter(
                    .{ .start = elem_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    ident,
                    hir_mod.none_node_id,
                    default_value,
                    flags,
                );
                try elements.append(self.gpa, elem);
                if (!self.match(.comma)) break;
                if (self.peek().kind == close_kind) break; // trailing comma
            }
        }
        const close_tok = try self.expect(close_kind, if (is_object) "'}' to close object pattern" else "']' to close array pattern");
        const sp: Span = .{ .start = open.span.start, .end = close_tok.span.end };
        return try self.builder.addPattern(
            if (is_object) .object_pattern else .array_pattern,
            sp,
            elements.items,
        );
    }

    fn parseClassDeclaration(self: *Parser) ParseError!NodeId {
        // `abstract class Foo { ... }` — TS allows the `abstract`
        // modifier as a leading keyword before `class`. Capture it for
        // the HIR payload so the checker can emit TS2511 on `new`.
        var is_abstract = false;
        var span_start: u32 = self.peek().span.start;
        if (self.peek().kind == .kw_abstract and self.peekAt(1).kind == .kw_class) {
            _ = self.advance(); // abstract
            is_abstract = true;
        }
        const start = self.advance(); // class
        if (!is_abstract) span_start = start.span.start;
        var name: NodeId = hir_mod.none_node_id;
        if (self.peek().kind == .identifier) {
            const name_tok = self.advance();
            const name_id = try self.internToken(name_tok);
            name = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        }
        // Generic type parameters: `class Foo<T extends U = D>`.
        if (self.peek().kind == .less_than) {
            const tps = try self.parseTypeParameterDeclaration();
            self.gpa.free(tps);
        }

        var extends: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_extends)) {
            extends = try self.parseLeftHandSideExpression();
            // Optional `<T>` after `extends Foo<T>` — skip generic args.
            if (self.peek().kind == .less_than) {
                _ = try self.parseTypeParameterDeclaration();
                // Note: this swallows the `<T>` after extends but
                // leaks the parsed nodes into HIR; that's fine since
                // they're real type-arg refs anchored under the class.
            }
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
            // Decorators `@dec` on members. We capture each as a
            // sibling `decorator` node in the member list — emitter
            // walks back from each member to collect preceding
            // decorator nodes.
            while (self.peek().kind == .at) {
                const dec_tok = self.advance();
                const dec_expr = try self.parseLeftHandSideExpression();
                const dec_node = try self.builder.addDecorator(.{
                    .start = dec_tok.span.start,
                    .end = self.hir.spanOf(dec_expr).end,
                }, dec_expr);
                try members.append(self.gpa, dec_node);
            }
            const mods = try self.skipClassModifiers();
            const member_start = self.peek();
            // method?
            if (self.peek().kind == .identifier or self.peek().kind == .private_identifier or self.peek().kind == .kw_constructor or self.peek().kind.isContextualKeyword()) {
                const name_tok = self.advance();
                if (self.peek().kind == .open_paren or self.peek().kind == .less_than) {
                    if (self.peek().kind == .less_than) {
                        const tps = try self.parseTypeParameterDeclaration();
                        self.gpa.free(tps);
                    }
                    const params = try self.parseParameterList();
                    defer self.gpa.free(params);
                    var return_type: NodeId = hir_mod.none_node_id;
                    if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);
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
                        return_type,
                        body,
                        .{
                            .is_method = true,
                            .is_constructor = name_tok.kind == .kw_constructor,
                            .is_private = mods.visibility == .private,
                            .is_protected = mods.visibility == .protected,
                        },
                    );
                    try members.append(self.gpa, fn_node);
                    continue;
                }
                // property
                if (self.match(.question)) {} // optional property
                var type_anno: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) type_anno = try self.parseTypeAnnotation();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                try self.consumeStatementTerminator();
                const name_id = try self.internToken(name_tok);
                const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                const prop = try self.builder.addObjectPropertyFull(
                    .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    default_value,
                    type_anno,
                    false,
                    default_value == hir_mod.none_node_id,
                    false,
                    mods.visibility,
                );
                try members.append(self.gpa, prop);
                continue;
            }
            // Unknown — advance to keep error-recovery flowing.
            _ = self.advance();
        }
        const close = try self.expect(.close_brace, "'}' to close class body");
        return try self.builder.addClass(
            .{ .start = span_start, .end = close.span.end },
            name,
            &.{},
            extends,
            implements_list.items,
            members.items,
            is_abstract,
        );
    }

    /// Tracks the TS access-modifier keywords the member-parsing
    /// loop has consumed before the member name. Other modifiers
    /// (`readonly`, `static`, `async`, `abstract`, `accessor`,
    /// `override`, `declare`, `out`, `in`) are parsed but discarded
    /// — only access modifiers need to flow into HIR for v0.
    const ClassModifiers = struct {
        visibility: hir_mod.Visibility = .public,
    };

    fn skipClassModifiers(self: *Parser) ParseError!ClassModifiers {
        var mods: ClassModifiers = .{};
        while (true) {
            const k = self.peek().kind;
            if (k.isModifierKeyword()) {
                switch (k) {
                    .kw_private => mods.visibility = .private,
                    .kw_protected => mods.visibility = .protected,
                    .kw_public => mods.visibility = .public,
                    else => {},
                }
                _ = self.advance();
                continue;
            }
            return mods;
        }
    }

    fn parseInterfaceDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // interface
        const name_tok = try self.expect(.identifier, "interface name");
        if (self.peek().kind == .less_than) {
            const tps = try self.parseTypeParameterDeclaration();
            self.gpa.free(tps);
        }
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
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        try self.parseTypeMemberList(&members);
        const close = try self.expect(.close_brace, "'}' to close interface body");
        const name_id_str = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id_str);
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
        var type_params: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            type_params = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(type_params);
        _ = try self.expect(.equal, "'=' in type alias");
        const aliased = try self.parseTypeAnnotation();
        try self.consumeStatementTerminator();
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        const end_pos = self.tokens[self.cursor - 1].span.end;
        return try self.builder.addTypeAlias(
            .{ .start = start.span.start, .end = end_pos },
            name_node,
            type_params,
            aliased,
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
            // Optional import attributes: `with { type: "json" }` (TS 5.3+)
            // or legacy `assert { type: "json" }` — parsed and discarded.
            try self.skipImportAttributesClause();
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
        // Optional import attributes: `with { type: "json" }` (TS 5.3+)
        // or legacy `assert { type: "json" }` — parsed and discarded.
        try self.skipImportAttributesClause();
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

    /// Optional import-attributes clause appearing after a module
    /// specifier or in a re-export's `from`. Accepts:
    ///   * `with { type: "json", name: "foo" }` — TS 5.3+ syntax
    ///   * `assert { type: "json" }` — legacy (deprecated) syntax
    /// Both are parsed for compatibility and discarded — v0 does not
    /// store the attribute payload on the HIR import node.
    fn skipImportAttributesClause(self: *Parser) ParseError!void {
        const k = self.peek().kind;
        const is_with = k == .kw_with;
        const is_assert = k == .identifier and std.mem.eql(
            u8,
            self.source[self.peek().span.start..self.peek().span.end],
            "assert",
        );
        if (!is_with and !is_assert) return;
        // Only treat the keyword as an attributes clause when followed
        // by `{` — otherwise `with` is reserved for `with` statements
        // (we just leave it for whatever surrounding context handles).
        if (self.peekAt(1).kind != .open_brace) return;
        _ = self.advance(); // `with` / `assert`
        _ = try self.expect(.open_brace, "'{' to start import attributes");
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            // key: identifier-like or string literal
            const key_kind = self.peek().kind;
            if (key_kind == .string_literal) {
                _ = self.advance();
            } else if (key_kind == .identifier or key_kind.isKeyword()) {
                _ = self.advance();
            } else {
                return error.UnexpectedToken;
            }
            _ = try self.expect(.colon, "':' in import attribute");
            // value: string literal per spec; accept identifier too for
            // forward-compatibility — discarded either way.
            const val_kind = self.peek().kind;
            if (val_kind == .string_literal or val_kind == .identifier) {
                _ = self.advance();
            } else {
                return error.UnexpectedToken;
            }
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.close_brace, "'}' to close import attributes");
    }

    fn parseExportDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // export
        // `type` after `export` is the type-only marker only when
        // the next token is `{` (named re-export) or `*` (namespace
        // re-export). `export type Foo = T;` and `export type Foo {}`
        // are type-alias / interface declarations — we must NOT eat
        // the `type` keyword in those cases.
        var is_type_only: bool = false;
        if (self.peek().kind == .kw_type) {
            const next = self.peekAt(1).kind;
            if (next == .open_brace or next == .asterisk) {
                _ = self.advance();
                is_type_only = true;
            }
        }
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
            var ns_alias: hir_mod.StringId = empty_string;
            if (self.match(.kw_as)) {
                const ns_tok = try self.expect(.identifier, "namespace name");
                ns_alias = try self.internToken(ns_tok);
            }
            _ = try self.expect(.kw_from, "'from' after 'export *'");
            const mod_tok = try self.expect(.string_literal, "module specifier");
            try self.consumeStatementTerminator();
            const mod_id = try self.internStringLiteral(mod_tok);
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addExportFull(
                .{ .start = start.span.start, .end = end_pos },
                hir_mod.none_node_id,
                &.{},
                mod_id,
                is_type_only,
                false,
                true,
                ns_alias,
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

    /// Parse a decorator expression after the `@` sigil. `@foo`,
    /// `@foo.bar`, `@foo()`, `@foo(arg, arg)` — all valid.
    fn parseDecoratorExpression(self: *Parser) ParseError!NodeId {
        _ = try self.expect(.at, "'@' to start decorator");
        return try self.parseLeftHandSideExpression();
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
        // Destructuring binding (`const { a } = obj`, `const [b] = arr`)
        // stores the pattern in the var-decl's `name` slot in the same
        // way parameters stash an `object_pattern` / `array_pattern`.
        const name_node: NodeId = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
            break :blk try self.parseBindingPattern();
        } else id_blk: {
            const name_tok = try self.expect(.identifier, "identifier in variable declaration");
            const name_id = try self.internToken(name_tok);
            break :id_blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        };

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

    /// Parse a Stage 3 explicit-resource-management declaration:
    ///   `using x = expr;`
    ///   `await using x = expr;`
    /// `await_using` selects the async-dispose form. The binding is
    /// lowered to a `const_decl`-shaped HIR node with the `is_using` /
    /// `is_await_using` flag set on its payload — for v0 emitters can
    /// continue treating it as `const`. Try/finally lowering for
    /// `[Symbol.dispose]()` / `[Symbol.asyncDispose]()` is a follow-up.
    fn parseUsingDecl(self: *Parser, await_using: bool) ParseError!NodeId {
        const start = self.advance(); // `using` or `await`
        if (await_using) {
            _ = self.advance(); // `using` token following `await`
        }
        const name_tok = try self.expect(.identifier, "identifier in using declaration");
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
        return try self.builder.addVarDeclEx(
            .const_decl,
            stmt_span,
            name_node,
            type_annotation,
            init_node,
            !await_using,
            await_using,
        );
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

    /// Parse a return-type annotation, with detection of type
    /// predicates (`arg is T`) and assertion functions (`asserts
    /// arg is T`). Falls through to `parseTypeAnnotation` for the
    /// regular case. `params` is the function's positional parameter
    /// list — each is a `parameter` HIR node, looked up by name to
    /// resolve the predicate's `arg`.
    fn parseReturnTypeAnnotation(self: *Parser, params: []const NodeId) ParseError!NodeId {
        const start_cursor = self.cursor;
        const start_span_start = self.peek().span.start;
        // `asserts <ident>` ...
        if (self.peek().kind == .kw_asserts and self.peekAt(1).kind == .identifier) {
            _ = self.advance(); // asserts
            const arg_tok = self.advance();
            const arg_id = try self.internToken(arg_tok);
            // `asserts <ident>` (predicate-less) — narrows to truthy.
            if (self.peek().kind != .kw_is) {
                const idx = self.findParamIndex(params, arg_id) orelse 0xFFFF;
                return try self.builder.addTypePredicate(
                    .{ .start = start_span_start, .end = arg_tok.span.end },
                    @intCast(idx),
                    arg_id,
                    hir_mod.none_node_id,
                    true,
                );
            }
            _ = self.advance(); // is
            const target = try self.parseTypeAnnotation();
            const idx = self.findParamIndex(params, arg_id) orelse 0xFFFF;
            return try self.builder.addTypePredicate(
                .{ .start = start_span_start, .end = self.hir.spanOf(target).end },
                @intCast(idx),
                arg_id,
                target,
                true,
            );
        }
        // `<ident> is T`
        if (self.peek().kind == .identifier and self.peekAt(1).kind == .kw_is) {
            const arg_tok = self.advance();
            const arg_id = try self.internToken(arg_tok);
            _ = self.advance(); // is
            const target = try self.parseTypeAnnotation();
            const idx = self.findParamIndex(params, arg_id) orelse 0xFFFF;
            return try self.builder.addTypePredicate(
                .{ .start = start_span_start, .end = self.hir.spanOf(target).end },
                @intCast(idx),
                arg_id,
                target,
                false,
            );
        }
        // Not a predicate — fall through. Restore cursor (we may
        // have advanced past `asserts` only to find no `<ident>`).
        self.cursor = start_cursor;
        return self.parseTypeAnnotation();
    }

    /// Look up a parameter by interned name; return its 0-based
    /// positional index or null. `this` parameters return null
    /// (caller falls back to the 0xFFFF sentinel for `this`).
    fn findParamIndex(self: *Parser, params: []const NodeId, name: hir_mod.StringId) ?usize {
        for (params, 0..) |p, i| {
            if (self.hir.kindOf(p) != .parameter) continue;
            const pp = hir_mod.parameterOf(self.hir, p);
            if (pp.name == hir_mod.none_node_id) continue;
            if (self.hir.kindOf(pp.name) != .identifier) continue;
            const id = hir_mod.identifierOf(self.hir, pp.name);
            if (id.name == name) return i;
        }
        return null;
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
            // Template literal type: `\`hello-${T}\`` (in type position).
            .no_substitution_template => blk: {
                _ = self.advance();
                // Strip the backticks and produce a single text part.
                const slice = self.source[t.span.start + 1 .. t.span.end - 1];
                const text_id = self.interner.intern(slice) catch return error.OutOfMemory;
                const text_lit = try self.builder.addLiteralString(tokenSpan(t), text_id);
                break :blk try self.builder.addTemplateLiteralType(tokenSpan(t), &.{text_lit}, &.{});
            },
            .template_head => blk: {
                break :blk try self.parseTemplateLiteralType();
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

    /// Parse a template-literal type: `\`a${T}b${U}c\``. Cursor at
    /// `template_head` (`` `a${ ``); we collect each interpolated
    /// type and the trailing text segments until we hit
    /// `template_tail`.
    fn parseTemplateLiteralType(self: *Parser) ParseError!NodeId {
        const head = self.advance(); // template_head
        var text_parts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer text_parts.deinit(self.gpa);
        var type_parts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer type_parts.deinit(self.gpa);
        // Strip leading `\`` and trailing `${` from the head text.
        const head_slice = self.source[head.span.start + 1 .. head.span.end - 2];
        const head_id = self.interner.intern(head_slice) catch return error.OutOfMemory;
        const head_lit = try self.builder.addLiteralString(tokenSpan(head), head_id);
        try text_parts.append(self.gpa, head_lit);

        while (true) {
            // Parse the interpolated type expression.
            const t = try self.parseTypeAnnotation();
            try type_parts.append(self.gpa, t);
            const next = self.peek();
            if (next.kind == .template_middle) {
                _ = self.advance();
                const slice = self.source[next.span.start + 1 .. next.span.end - 2];
                const id = self.interner.intern(slice) catch return error.OutOfMemory;
                const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                try text_parts.append(self.gpa, lit);
                continue;
            }
            if (next.kind == .template_tail) {
                _ = self.advance();
                const slice = self.source[next.span.start + 1 .. next.span.end - 1];
                const id = self.interner.intern(slice) catch return error.OutOfMemory;
                const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                try text_parts.append(self.gpa, lit);
                break;
            }
            // Malformed — bail.
            break;
        }

        const sp: Span = .{
            .start = head.span.start,
            .end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else head.span.end,
        };
        return try self.builder.addTemplateLiteralType(sp, text_parts.items, type_parts.items);
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
            // Rest element prefix `...T` (TS 4.0+ variadic tuples).
            // The operand is wrapped in a `rest_type` HIR node so the
            // lowerer / checker can model spread expansion.
            const rest_tok = self.peek();
            const has_rest = self.match(.dot_dot_dot);
            // Tolerate a labeled rest: `[...rest: T[]]`.
            if (has_rest and self.peek().kind == .identifier and self.peekAt(1).kind == .colon) {
                _ = self.advance();
                _ = self.advance();
            }
            var e = try self.parseTypeAnnotation();
            _ = self.match(.question); // optional element marker
            if (has_rest) {
                const end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else rest_tok.span.end;
                e = try self.builder.addRestType(.{ .start = rest_tok.span.start, .end = end }, e);
            }
            try elems.append(self.gpa, e);
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.close_bracket, "']' to close tuple type");
        return try self.builder.addTupleType(.{ .start = open.span.start, .end = close.span.end }, elems.items);
    }

    /// `{ ...members... }` — object type literal. Phase 6 lowers to
    /// a real `object_type` HIR node carrying member info (name,
    /// type, optional/readonly/method flags). Mapped types
    /// (`{ [K in T]: V }`) are still parsed via the dedicated path.
    fn parseObjectOrMappedType(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.open_brace, "'{' to start object type");
        // Detect mapped type. The leading shape is one of:
        //   { [K in T]: V }
        //   { readonly [K in T]: V }
        //   { -readonly [K in T]: V }
        //   { +readonly [K in T]: V }
        // We also need to look two tokens ahead for `-readonly` /
        // `+readonly` because the modifier prefixes the bracket.
        var readonly_mod: u8 = 0;
        var lead_consumed: usize = 0;
        if (self.peek().kind == .kw_readonly and self.peekAt(1).kind == .open_bracket) {
            readonly_mod = 1;
            lead_consumed = 1;
        } else if (self.peek().kind == .minus and self.peekAt(1).kind == .kw_readonly and self.peekAt(2).kind == .open_bracket) {
            readonly_mod = 2;
            lead_consumed = 2;
        } else if (self.peek().kind == .plus and self.peekAt(1).kind == .kw_readonly and self.peekAt(2).kind == .open_bracket) {
            readonly_mod = 1;
            lead_consumed = 2;
        }
        var bracket_idx: usize = 0;
        if (lead_consumed > 0) bracket_idx = lead_consumed;
        const at_bracket = self.peek().kind == .open_bracket or
            (lead_consumed > 0 and self.peekAt(@intCast(bracket_idx)).kind == .open_bracket);
        const has_in = if (lead_consumed > 0)
            self.peekAt(@intCast(bracket_idx + 2)).kind == .kw_in
        else
            self.peekAt(2).kind == .kw_in;
        if (at_bracket and has_in) {
            // Consume any leading readonly modifier tokens.
            var c: usize = 0;
            while (c < lead_consumed) : (c += 1) _ = self.advance();
            _ = self.advance(); // `[`
            const k_tok = try self.expect(.identifier, "key in mapped type");
            const k_id = try self.internToken(k_tok);
            _ = try self.expect(.kw_in, "'in' in mapped type");
            const constraint = try self.parseTypeAnnotation();
            // Optional `as Type` key-remapping clause (TS 4.1+):
            //   `{ [K in keyof T as Exclude<K, "private">]: T[K] }`
            // The `as` sits between the constraint and the closing
            // bracket. Its type is evaluated per-key during checking;
            // keys whose remap reduces to `never` are dropped.
            var remap: NodeId = hir_mod.none_node_id;
            if (self.peek().kind == .kw_as) {
                _ = self.advance();
                remap = try self.parseTypeAnnotation();
            }
            _ = try self.expect(.close_bracket, "']' to close mapped type key");
            // Optional `?` / `+?` / `-?` modifier
            var optional_mod: u8 = 0;
            if (self.match(.minus)) {
                _ = try self.expect(.question, "'?' after '-' in mapped type");
                optional_mod = 2;
            } else if (self.match(.plus)) {
                _ = try self.expect(.question, "'?' after '+' in mapped type");
                optional_mod = 1;
            } else if (self.match(.question)) {
                optional_mod = 1;
            }
            _ = try self.expect(.colon, "':' in mapped type");
            const value = try self.parseTypeAnnotation();
            _ = self.match(.semicolon);
            const close = try self.expect(.close_brace, "'}' to close mapped type");
            const tp = try self.builder.addTypeParameter(tokenSpan(k_tok), k_id, hir_mod.none_node_id, hir_mod.none_node_id, 0, false);
            return try self.builder.addMappedType(.{ .start = open.span.start, .end = close.span.end }, tp, constraint, value, remap, readonly_mod, optional_mod);
        }
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        try self.parseTypeMemberList(&members);
        const close = try self.expect(.close_brace, "'}' to close object type");
        return try self.builder.addObjectType(
            .{ .start = open.span.start, .end = close.span.end },
            members.items,
        );
    }

    /// Parse a sequence of TypeScript "type member" declarations
    /// inside `{ … }`. Members are separated by `;`, `,`, or
    /// newline. Each member is one of:
    ///
    ///   `name: T;`        — property
    ///   `name?: T;`       — optional property
    ///   `readonly name: T;` — readonly property
    ///   `name(p: P): R;`  — method-shorthand (lowers to fn_type)
    ///   `[k: string]: V;` — index signature (Phase 6 follow-up)
    ///   `(p): R;`         — call signature (Phase 6 follow-up)
    ///
    /// Index/call/construct signatures are skipped for now —
    /// tracked as Phase 6 follow-ups so the harness can keep
    /// progressing.
    fn parseTypeMemberList(self: *Parser, out: *std.ArrayListUnmanaged(NodeId)) ParseError!void {
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const t = self.peek();
            // Index signature: `[k: K]: V` or `readonly [k: K]: V`.
            // Detect via `[ ident : ident ]` shape, then commit.
            if (t.kind == .open_bracket or
                (t.kind == .kw_readonly and self.peekAt(1).kind == .open_bracket))
            {
                if (try self.tryParseIndexSignature(out)) continue;
                // Not an index signature — fall through to skip
                // (could be a computed key or other form we don't
                // model yet).
                try self.skipUntilTypeMemberSeparator();
                continue;
            }
            // Call / construct signatures still skip — they're
            // a Phase 6 follow-up.
            if (t.kind == .open_paren or t.kind == .kw_new) {
                try self.skipUntilTypeMemberSeparator();
                continue;
            }
            var is_readonly = false;
            if (t.kind == .kw_readonly and self.peekAt(1).kind != .colon) {
                _ = self.advance();
                is_readonly = true;
            }
            const name_tok = self.advance();
            // Allow string-literal property names: `"foo": T`.
            const name_id: hir_mod.StringId = if (name_tok.kind == .string_literal)
                try self.internStringLiteral(name_tok)
            else
                try self.internToken(name_tok);
            const is_optional = self.match(.question);

            // Method shorthand: `name(p: T): R`.
            if (self.peek().kind == .open_paren) {
                const params = try self.parseTypeParameterList();
                defer self.gpa.free(params);
                var ret: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) ret = try self.parseTypeAnnotation();
                const fn_t = try self.builder.addFnType(
                    .{ .start = name_tok.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    &.{},
                    params,
                    ret,
                    false,
                );
                _ = self.match(.semicolon);
                _ = self.match(.comma);
                const member = try self.builder.addInterfaceMember(
                    tokenSpan(name_tok),
                    name_id,
                    fn_t,
                    is_optional,
                    is_readonly,
                    true,
                );
                try out.append(self.gpa, member);
                continue;
            }

            // Property: `name: T;`.
            var type_node: NodeId = hir_mod.none_node_id;
            if (self.match(.colon)) type_node = try self.parseTypeAnnotation();
            _ = self.match(.semicolon);
            _ = self.match(.comma);
            const member = try self.builder.addInterfaceMember(
                tokenSpan(name_tok),
                name_id,
                type_node,
                is_optional,
                is_readonly,
                false,
            );
            try out.append(self.gpa, member);
        }
    }

    /// Attempt to parse a `[k: K]: V` (or `readonly [k: K]: V`)
    /// index signature. Returns true if one was consumed and
    /// appended to `out`; returns false (cursor unchanged) when
    /// the bracketed form turns out to be something else (e.g. a
    /// computed key or mapped-type form). Mapped types live in a
    /// dedicated `mapped_type` HIR node and are dispatched
    /// separately by `parseTypeAnnotation`.
    fn tryParseIndexSignature(self: *Parser, out: *std.ArrayListUnmanaged(NodeId)) ParseError!bool {
        const checkpoint = self.cursor;
        const start_tok = self.peek();
        var is_readonly = false;
        if (self.peek().kind == .kw_readonly and self.peekAt(1).kind == .open_bracket) {
            _ = self.advance();
            is_readonly = true;
        }
        if (self.peek().kind != .open_bracket) {
            self.cursor = checkpoint;
            return false;
        }
        // Look for the `[ident : ident]` pattern, optionally followed
        // by `:` (annotation) or `in` (mapped type).
        const after_bracket = self.cursor + 1;
        if (after_bracket >= self.tokens.len) {
            self.cursor = checkpoint;
            return false;
        }
        const id1 = self.tokens[after_bracket];
        if (id1.kind != .identifier) {
            self.cursor = checkpoint;
            return false;
        }
        const colon_pos = after_bracket + 1;
        if (colon_pos >= self.tokens.len or self.tokens[colon_pos].kind != .colon) {
            self.cursor = checkpoint;
            return false;
        }
        // Commit to parsing the index signature.
        _ = self.advance(); // [
        _ = self.advance(); // key name
        _ = self.advance(); // :
        const key_type = try self.parseTypeAnnotation();
        // If the next token is `in`, this is actually a mapped
        // type — back out so the higher-level parser handles it.
        if (self.peek().kind == .kw_in) {
            self.cursor = checkpoint;
            return false;
        }
        _ = try self.expect(.close_bracket, "']' to close index signature");
        _ = try self.expect(.colon, "':' before index-signature value type");
        const value_type = try self.parseTypeAnnotation();
        _ = self.match(.semicolon);
        _ = self.match(.comma);
        const sp: Span = .{ .start = start_tok.span.start, .end = self.tokens[self.cursor - 1].span.end };
        const node = try self.builder.addIndexSignature(sp, key_type, value_type, is_readonly);
        try out.append(self.gpa, node);
        return true;
    }

    fn skipUntilTypeMemberSeparator(self: *Parser) ParseError!void {
        var depth: i32 = 0;
        while (true) {
            const t = self.peek();
            if (depth == 0) {
                if (t.kind == .semicolon or t.kind == .comma) {
                    _ = self.advance();
                    return;
                }
                if (t.kind == .close_brace or t.kind == .eof) return;
            }
            switch (t.kind) {
                .open_brace, .open_paren, .open_bracket, .less_than => depth += 1,
                .close_brace, .close_paren, .close_bracket, .greater_than => {
                    depth -= 1;
                    if (depth < 0) return;
                },
                else => {},
            }
            _ = self.advance();
        }
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
            // TS 5.0 `const` type-parameter modifier (`<const T>`). When
            // present, argument inference for T should be performed
            // `as const` (readonly + literal types preserved).
            // TODO(checker): currently parsed-only; the `is_const` flag is
            // recorded on the type-parameter payload but inference still
            // widens like a normal type parameter.
            var is_const: bool = false;
            if (self.peek().kind == .kw_const and self.peekAt(1).kind == .identifier) {
                _ = self.advance();
                is_const = true;
            }
            // Variance modifiers `in`/`out` (TS 4.7). Either or both may
            // appear before the type-parameter name. The lookahead allows
            // `in T`, `out T`, and `in out T` — for the combined form, the
            // peek-2 lookahead bypasses the trailing `kw_out` so the next
            // pass sees the kw_out → identifier path.
            var variance: u8 = 0;
            if (self.peek().kind == .kw_in) {
                const after = self.peekAt(1).kind;
                if (after == .identifier or after == .kw_out) {
                    _ = self.advance();
                    variance |= 1;
                }
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
                is_const,
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
        // Arrow function fast paths:
        //   `x => …`   — single-ident arrow
        //   `() => …`  — zero-arg
        //   `(…) => …` — paren'd arrow (speculative)
        //   `async () => …` / `async x => …`
        //   `<T>(…) => …` — generic arrow
        if (try self.maybeParseArrowFunction()) |arrow| return arrow;

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
            // Logical assignments `??=`, `||=`, `&&=` (ES2021).
            // Lowered to `a = a <op> b` so existing checker logic
            // (nullish-coalescing strips null|undefined from lhs)
            // produces the right result type. Post-statement
            // narrowing for `??=` is applied by the checker.
            .question_question_equal => return self.parseLogicalAssign(left, .nullish),
            .pipe_pipe_equal => return self.parseLogicalAssign(left, .@"or"),
            .ampersand_ampersand_equal => return self.parseLogicalAssign(left, .@"and"),
            else => return left,
        }
    }

    /// Detect if the next token sequence is an arrow function and
    /// parse it. Returns null on no match (no tokens consumed).
    fn maybeParseArrowFunction(self: *Parser) ParseError!?NodeId {
        const checkpoint = self.cursor;
        const is_async = blk: {
            if (self.peek().kind == .kw_async) {
                const next = self.peekAt(1).kind;
                if (next == .open_paren or next == .identifier or next == .less_than) {
                    _ = self.advance();
                    break :blk true;
                }
            }
            break :blk false;
        };
        const start_tok = if (is_async) self.tokens[checkpoint] else self.peek();

        // Single-ident arrow: `x => …`
        if (self.peek().kind == .identifier and self.peekAt(1).kind == .arrow) {
            const name_tok = self.advance();
            _ = self.advance(); // `=>`
            const name_id = try self.internToken(name_tok);
            const ident = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
            const param = try self.builder.addParameter(
                tokenSpan(name_tok),
                ident,
                hir_mod.none_node_id,
                hir_mod.none_node_id,
                .{},
            );
            const body = try self.parseArrowBody();
            const sp: Span = .{ .start = start_tok.span.start, .end = self.hir.spanOf(body).end };
            return try self.builder.addFnDecl(
                sp,
                hir_mod.none_node_id,
                &.{param},
                hir_mod.none_node_id,
                body,
                .{ .is_arrow = true, .is_async = is_async },
            );
        }

        // Generic arrow: `<T>(…) => …`
        if (self.peek().kind == .less_than) {
            // Speculatively check that the closing `>` is followed by
            // `(`. If so, this is a generic arrow.
            if (self.findMatchingTypeArgsEnd(self.cursor)) |after_args| {
                if (after_args < self.tokens.len and self.tokens[after_args].kind == .open_paren) {
                    const tps = try self.parseTypeParameterDeclaration();
                    defer self.gpa.free(tps);
                    if (try self.tryParseArrowAfterParen(start_tok, is_async, tps)) |arrow| return arrow;
                    // Failed; restore.
                    self.cursor = checkpoint;
                    return null;
                }
            }
            self.cursor = checkpoint;
            return null;
        }

        // Paren-arrow: `(…) => …`. Speculatively check that the
        // close-paren is followed by `=>` or `:` (typed return) before
        // committing.
        if (self.peek().kind == .open_paren) {
            if (try self.tryParseArrowAfterParen(start_tok, is_async, &.{})) |arrow| return arrow;
        }
        // Not an arrow — restore and fall through.
        self.cursor = checkpoint;
        return null;
    }

    /// Returns the cursor index AFTER the matching `>` of a
    /// type-argument list starting at `start` (which must point at
    /// `<`). Returns null if not balanced.
    fn findMatchingTypeArgsEnd(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len or self.tokens[start].kind != .less_than) return null;
        var depth: i32 = 1;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (tk == .less_than) {
                depth += 1;
            } else if (tk == .greater_than) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (tk == .eof) {
                return null;
            }
        }
        return null;
    }

    /// Speculatively parse `(…)` as arrow params. If it doesn't look
    /// like an arrow (no `=>` after the close-paren / typed return),
    /// rewinds and returns null.
    fn tryParseArrowAfterParen(
        self: *Parser,
        start_tok: Token,
        is_async: bool,
        type_params: []const NodeId,
    ) ParseError!?NodeId {
        const before_paren = self.cursor;
        // Find the matching `)`.
        const after_paren_idx = self.findMatchingParenEnd(self.cursor) orelse return null;
        // After `)`, we expect either `=>` (untyped return) or `:` then `=>`.
        if (after_paren_idx >= self.tokens.len) return null;
        const after_kind = self.tokens[after_paren_idx].kind;
        if (after_kind != .arrow and after_kind != .colon) return null;
        if (after_kind == .colon) {
            // We need to scan past the type annotation to find a `=>`.
            // Simple approach: look for the next top-level `=>` before
            // a statement-terminator-class token.
            if (!self.scanForArrowAfterColon(after_paren_idx + 1)) return null;
        }

        // Looks like an arrow — parse for real.
        const params = try self.parseParameterList();
        defer self.gpa.free(params);

        // Optional return-type annotation. Use the predicate-aware
        // parser so `(x): x is T => ...` works.
        var return_type: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) {
            return_type = try self.parseReturnTypeAnnotation(params);
        }
        _ = try self.expect(.arrow, "'=>' in arrow function");
        const body = try self.parseArrowBody();
        const sp: Span = .{ .start = start_tok.span.start, .end = self.hir.spanOf(body).end };
        const flags: hir_mod.FnFlags = .{
            .is_arrow = true,
            .is_async = is_async,
        };
        // type_params slot reuses the standard FnDecl fields; for now
        // we drop them at the HIR boundary to keep the lowering
        // uniform. Phase 3 / type checker will re-derive them.
        _ = type_params;
        _ = before_paren;
        return try self.builder.addFnDecl(sp, hir_mod.none_node_id, params, return_type, body, flags);
    }

    /// Speculative: cursor points at `<` after a callee. Walk
    /// balanced angles + parens until we find the matching `>` at
    /// angle-depth 0. If the next non-trivia token is `(`, return
    /// the cursor at the `(`. Otherwise return null — the `<` is
    /// a less-than operator and the caller falls back to binop.
    ///
    /// Conservative: we bail on tokens that don't appear in TS
    /// type-arg lists (assignment, semicolon, EOF, etc.) since they
    /// indicate the `<` was a comparison.
    fn findCallTypeArgsEnd(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len or self.tokens[start].kind != .less_than) return null;
        var depth: i32 = 1;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            switch (tk) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        // Next token must be `(` for this to be a
                        // generic call.
                        const next = i + 1;
                        if (next < self.tokens.len and self.tokens[next].kind == .open_paren) {
                            return next;
                        }
                        return null;
                    }
                },
                // Balanced delimiters that may appear inside type args.
                .open_paren, .open_bracket, .open_brace => {
                    if (self.skipBalancedFrom(i)) |after| {
                        i = after - 1; // -1 because the loop increments
                    } else return null;
                },
                // Tokens that disqualify this from being type args.
                .equal,
                .semicolon,
                .arrow,
                .question_dot,
                .eof,
                => return null,
                else => {},
            }
        }
        return null;
    }

    /// Parse the comma-separated type arguments of an explicit
    /// generic call. Cursor enters at `<`; returns with the cursor
    /// positioned at `(` (the index `after_gt` returned by
    /// `findCallTypeArgsEnd`). The caller owns the returned slice.
    fn parseExplicitCallTypeArgs(self: *Parser, after_gt: u32) ParseError![]NodeId {
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer args.deinit(self.gpa);
        // Skip the opening `<`.
        std.debug.assert(self.peek().kind == .less_than);
        _ = self.advance();
        while (self.peek().kind != .greater_than) {
            const t = try self.parseTypeAnnotation();
            try args.append(self.gpa, t);
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            // No comma + no `>` → bail to checkpoint.
            if (self.peek().kind != .greater_than) break;
        }
        // Force-advance to `(` even if structural recovery failed; the
        // caller already verified `after_gt` lands on `(`.
        self.cursor = after_gt;
        return args.toOwnedSlice(self.gpa);
    }

    /// Skip a balanced (), [], or {} starting at `start`. Returns
    /// the cursor *after* the matching closer, or null on mismatch.
    fn skipBalancedFrom(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len) return null;
        const opener = self.tokens[start].kind;
        const closer: ts_lexer.TokenKind = switch (opener) {
            .open_paren => .close_paren,
            .open_bracket => .close_bracket,
            .open_brace => .close_brace,
            else => return null,
        };
        var depth: i32 = 1;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (tk == opener) depth += 1;
            if (tk == closer) {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            if (tk == .eof) return null;
        }
        return null;
    }

    /// Cursor points at `(`. Returns the cursor *after* the matching `)`.
    fn findMatchingParenEnd(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len or self.tokens[start].kind != .open_paren) return null;
        var depth: i32 = 1;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            switch (tk) {
                .open_paren, .open_bracket, .open_brace, .less_than => depth += 1,
                .close_paren, .close_bracket, .close_brace, .greater_than => {
                    depth -= 1;
                    if (depth == 0 and tk == .close_paren) return i + 1;
                },
                .eof => return null,
                else => {},
            }
        }
        return null;
    }

    /// From `idx` (right after `:`), scan past a type annotation and
    /// return true if we eventually hit `=>` at the top level.
    fn scanForArrowAfterColon(self: *Parser, idx: u32) bool {
        var depth: i32 = 0;
        var i: u32 = idx;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (depth == 0) {
                if (tk == .arrow) return true;
                if (tk == .semicolon or tk == .comma or tk == .close_paren or
                    tk == .close_brace or tk == .close_bracket or tk == .eof)
                {
                    return false;
                }
            }
            switch (tk) {
                .less_than, .open_paren, .open_brace, .open_bracket => depth += 1,
                .greater_than, .close_paren, .close_brace, .close_bracket => {
                    if (depth > 0) depth -= 1;
                },
                else => {},
            }
        }
        return false;
    }

    fn parseArrowBody(self: *Parser) ParseError!NodeId {
        if (self.peek().kind == .open_brace) {
            return try self.parseBlockStatement();
        }
        return try self.parseAssignmentExpression();
    }

    fn parseCompoundAssign(self: *Parser, left: NodeId, op: hir_mod.BinOp) ParseError!NodeId {
        _ = self.advance();
        const right = try self.parseAssignmentExpression();
        const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
        return try self.builder.addAssignment(sp, left, right, op);
    }

    /// Lower `a <op>= b` (where <op> is `??`, `||`, or `&&`) into
    /// `a = a <op> b`. We duplicate the lhs identifier so the
    /// assignment target and the operator's lhs are independent
    /// HIR nodes. v0 only handles identifier targets — the common
    /// `x ??= "default"` pattern. Non-identifier targets fall through
    /// as `InvalidLeftHandSide`.
    fn parseLogicalAssign(self: *Parser, left: NodeId, op: hir_mod.LogicalOp) ParseError!NodeId {
        _ = self.advance();
        const right = try self.parseAssignmentExpression();
        if (self.hir.kindOf(left) != .identifier) {
            return error.InvalidLeftHandSide;
        }
        const id_payload = hir_mod.identifierOf(self.hir, left);
        const left_span = self.hir.spanOf(left);
        const left_dup = try self.builder.addIdentifier(left_span, id_payload.name);
        const op_span: Span = .{ .start = left_span.start, .end = self.hir.spanOf(right).end };
        const logical = try self.builder.addLogicalOp(op_span, op, left_dup, right);
        return try self.builder.addAssignment(op_span, left, logical, null);
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
            // `as` / `satisfies` take a TYPE on the right, not an
            // expression — handle them before the generic
            // expression-RHS path so we don't try to parse `number`
            // as an identifier.
            if (t.kind == .kw_as or t.kind == .kw_satisfies) {
                // `expr as const` is a special form — `const` isn't
                // a valid type, it's a contextual keyword that asks
                // the checker to type the LHS as its literal form
                // (rather than the widened type). Build a synthetic
                // type_ref to "const" so the checker can recognize
                // and handle it.
                if (t.kind == .kw_as and self.peek().kind == .kw_const) {
                    const const_tok = self.advance();
                    const const_id = self.interner.intern("const") catch return error.OutOfMemory;
                    const type_node = try self.builder.addTypeRef(
                        tokenSpan(const_tok),
                        const_id,
                        &.{},
                        &.{},
                    );
                    const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = const_tok.span.end };
                    left = try self.builder.addAsExpression(.as_expr, sp, left, type_node);
                    continue;
                }
                const type_node = try self.parseTypeAnnotation();
                const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(type_node).end };
                const kind: hir_mod.NodeKind = if (t.kind == .kw_as) .as_expr else .satisfies_expr;
                left = try self.builder.addAsExpression(kind, sp, left, type_node);
                continue;
            }
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
            .kw_await => {
                // `await expr` — parses as a unary expression.
                // Per spec, `await` is only valid inside async fns or
                // module top-level; we don't enforce that here (the
                // checker will). The HIR lands as `await_expr`.
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addAwaitExpr(sp, operand);
            },
            .kw_yield => {
                // `yield` / `yield expr` / `yield* expr`.
                _ = self.advance();
                const is_delegated = self.match(.asterisk);
                // `yield` with no operand is allowed at expression
                // statement position; we accept any expression that
                // a unary parser would.
                if (self.peek().kind == .semicolon or
                    self.peek().kind == .close_paren or
                    self.peek().kind == .close_bracket or
                    self.peek().kind == .close_brace or
                    self.peek().kind == .comma or
                    self.peek().kind == .eof)
                {
                    return try self.builder.addYieldExpr(tokenSpan(t), hir_mod.none_node_id, is_delegated);
                }
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addYieldExpr(sp, operand, is_delegated);
            },
            else => return try self.parseCallOrMemberExpression(),
        }
    }

    /// Parse a member-access chain off a primary expression — `dot`,
    /// `?.`, and `[index]` — but stop at `(`. Used as the callee of
    /// a `new` expression so the parenthesized argument list belongs
    /// to the `new`, not to a call wrapped around it.
    fn parseMemberExpressionOnly(self: *Parser) ParseError!NodeId {
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
                .less_than => {
                    // Speculative: `id<T, U>(...)` — explicit type args
                    // for a generic call. We accept the form only when
                    // a matching `>` is followed immediately by `(`.
                    // Otherwise we bail out and leave `<` to the binop
                    // path.
                    if (self.findCallTypeArgsEnd(self.cursor)) |after_gt| {
                        // Parse the type args so the checker can use
                        // them to override call-site inference.
                        const type_args = try self.parseExplicitCallTypeArgs(after_gt);
                        defer self.gpa.free(type_args);
                        const args = try self.parseArgumentList();
                        defer self.gpa.free(args);
                        const close_pos = self.tokens[self.cursor - 1].span.end;
                        const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close_pos };
                        node = try self.builder.addCallWithTypeArgs(sp, node, args, type_args);
                    } else break;
                },
                .open_bracket => {
                    _ = self.advance();
                    const idx = try self.parseExpression();
                    const close = try self.expect(.close_bracket, "']' to close index access");
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close.span.end };
                    node = try self.builder.addElementAccess(sp, node, idx, false);
                },
                .bang => {
                    // Postfix `!` — non-null assertion. TS only
                    // recognizes this as a postfix when there's no
                    // space between the operand and the `!` *and*
                    // the next token isn't an expression continuation
                    // (`(`, `=`, etc. would re-introduce ambiguity
                    // with the boolean negation prefix). The lexer
                    // emits `bang` either way; the disambiguation
                    // here is sufficient for the common case.
                    _ = self.advance();
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = t.span.end };
                    node = try self.builder.addNonNullExpression(sp, node);
                },
                .no_substitution_template, .template_head => {
                    // Tagged template literal: `` tag`…` `` desugars to
                    // a call `tag(stringsArr, …values)`. v0 just types
                    // `stringsArr` as `string[]` (no
                    // TemplateStringsArray shape yet).
                    node = try self.parseTaggedTemplate(node);
                },
                else => break,
            }
        }
        return node;
    }

    /// Parse a tagged template literal as a call expression. Cursor at
    /// `no_substitution_template` or `template_head`. We collect the
    /// string segments into an array literal and the interpolated
    /// expressions as call arguments.
    fn parseTaggedTemplate(self: *Parser, tag: NodeId) ParseError!NodeId {
        var strings: std.ArrayListUnmanaged(NodeId) = .empty;
        defer strings.deinit(self.gpa);
        var values: std.ArrayListUnmanaged(NodeId) = .empty;
        defer values.deinit(self.gpa);

        const head = self.advance();
        const tag_span = self.hir.spanOf(tag);

        if (head.kind == .no_substitution_template) {
            // `` `…` `` — single string segment, no values.
            const slice_full = self.source[head.span.start..head.span.end];
            const inner = if (slice_full.len >= 2) slice_full[1 .. slice_full.len - 1] else slice_full;
            const id = self.interner.intern(inner) catch return error.OutOfMemory;
            const lit = try self.builder.addLiteralString(tokenSpan(head), id);
            try strings.append(self.gpa, lit);
        } else {
            // template_head: `` `…${ ``
            const head_slice_full = self.source[head.span.start..head.span.end];
            const head_inner = if (head_slice_full.len >= 3)
                head_slice_full[1 .. head_slice_full.len - 2]
            else
                head_slice_full;
            const head_id = self.interner.intern(head_inner) catch return error.OutOfMemory;
            const head_lit = try self.builder.addLiteralString(tokenSpan(head), head_id);
            try strings.append(self.gpa, head_lit);

            // Loop: parse expression, then template_middle / template_tail.
            while (true) {
                const v = try self.parseExpression();
                try values.append(self.gpa, v);
                const next = self.peek();
                if (next.kind == .template_middle) {
                    _ = self.advance();
                    const sl = self.source[next.span.start..next.span.end];
                    const inner = if (sl.len >= 3) sl[1 .. sl.len - 2] else sl;
                    const id = self.interner.intern(inner) catch return error.OutOfMemory;
                    const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                    try strings.append(self.gpa, lit);
                    continue;
                }
                if (next.kind == .template_tail) {
                    _ = self.advance();
                    const sl = self.source[next.span.start..next.span.end];
                    const inner = if (sl.len >= 2) sl[1 .. sl.len - 1] else sl;
                    const id = self.interner.intern(inner) catch return error.OutOfMemory;
                    const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                    try strings.append(self.gpa, lit);
                    break;
                }
                // Malformed — bail out to avoid an infinite loop.
                break;
            }
        }

        const end_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else head.span.end;
        const call_sp: Span = .{ .start = tag_span.start, .end = end_pos };
        const arr_span: Span = .{ .start = head.span.start, .end = end_pos };
        const strings_arr = try self.builder.addArrayLiteral(arr_span, strings.items);

        // Build args: [stringsArr, ...values]
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        defer args.deinit(self.gpa);
        try args.append(self.gpa, strings_arr);
        try args.appendSlice(self.gpa, values.items);

        return try self.builder.addCall(call_sp, tag, args.items);
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
            .kw_undefined => {
                _ = self.advance();
                return try self.builder.addLiteralUndefined(tokenSpan(t));
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
            .less_than => {
                if (self.is_tsx) return try self.parseJsx();
                // In .ts files `<T>expr` is a type assertion. We
                // currently treat it as a no-op pass-through.
                _ = self.advance();
                try self.skipTypeAnnotation();
                _ = try self.expect(.greater_than, "'>' to close type assertion");
                return try self.parseUnaryExpression();
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
                // Lowered as a dedicated `new_expr` so the checker can
                // produce the class instance type rather than the
                // constructor's call return type. The callee uses a
                // member-only parser so `new Foo(args)` doesn't get
                // pre-consumed as a call.
                const callee = try self.parseMemberExpressionOnly();
                if (self.peek().kind == .open_paren) {
                    const args = try self.parseArgumentList();
                    defer self.gpa.free(args);
                    const close_pos = self.tokens[self.cursor - 1].span.end;
                    return try self.builder.addNew(.{ .start = t.span.start, .end = close_pos }, callee, args);
                }
                return try self.builder.addNew(.{ .start = t.span.start, .end = self.hir.spanOf(callee).end }, callee, &.{});
            },
            .kw_import => {
                // Dynamic `import("module")` — parses as a call
                // expression with `import` as the callee. We synthesize
                // an identifier named `import` so downstream emit can
                // route the call site through the appropriate
                // module-system lowering (a no-op at .esm; an
                // async require() at .commonjs).
                _ = self.advance();
                const import_id = self.interner.intern("import") catch return error.OutOfMemory;
                const callee = try self.builder.addIdentifier(tokenSpan(t), import_id);
                if (self.peek().kind != .open_paren) {
                    // Not a dynamic import — fall through to whatever
                    // the unexpected token produces.
                    return callee;
                }
                const args = try self.parseArgumentList();
                defer self.gpa.free(args);
                const close_pos = self.tokens[self.cursor - 1].span.end;
                return try self.builder.addCall(.{ .start = t.span.start, .end = close_pos }, callee, args);
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

    // ========================================================================
    // JSX (TSX-only)
    // ========================================================================
    //
    // Phase 1 JSX coverage — *structured* JSX that doesn't require
    // free-text-content tokenization:
    //   - <Foo />, <Foo></Foo>, <Foo>...</Foo>
    //   - Attributes: name="str", name={expr}, name (boolean
    //     shorthand), {...spread}
    //   - Child expression containers: {expr}
    //   - Nested JSX elements as children
    //   - Fragments: <>…</>
    //
    // *Not* yet supported — would require lexer mode switching:
    //   - Bare text content: <p>hello world</p>
    //   - HTML entities: <p>&amp;</p>
    // The parser diagnoses these and continues.

    fn parseJsx(self: *Parser) ParseError!NodeId {
        return try self.parseJsxElementOrFragment();
    }

    fn parseJsxElementOrFragment(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.less_than, "'<' to start JSX element");
        // Fragment: `<>...</>`
        if (self.peek().kind == .greater_than) {
            _ = self.advance(); // `>`
            var children: std.ArrayListUnmanaged(NodeId) = .empty;
            defer children.deinit(self.gpa);
            try self.parseJsxChildren(&children);
            // Closing `</>`.
            _ = try self.expect(.less_than, "'<' to start fragment close");
            _ = try self.expect(.slash, "'/' in fragment close");
            const close = try self.expect(.greater_than, "'>' to close fragment");
            return try self.builder.addJsxFragment(.{ .start = open.span.start, .end = close.span.end }, children.items);
        }

        // Tag identifier — accept identifier or member-access (`Foo.Bar`).
        const tag_tok = try self.expect(.identifier, "JSX tag name");
        const tag_id = try self.internToken(tag_tok);
        var tag = try self.builder.addIdentifier(tokenSpan(tag_tok), tag_id);
        while (self.peek().kind == .dot) {
            _ = self.advance();
            const member_tok = try self.expect(.identifier, "JSX qualified-tag member");
            const member_id = try self.internToken(member_tok);
            tag = try self.builder.addMemberAccess(
                .{ .start = self.hir.spanOf(tag).start, .end = member_tok.span.end },
                tag,
                member_id,
                false,
            );
        }

        // Attributes.
        var attrs: std.ArrayListUnmanaged(NodeId) = .empty;
        defer attrs.deinit(self.gpa);
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .greater_than, .slash, .eof => break,
                .open_brace => {
                    _ = self.advance();
                    _ = try self.expect(.dot_dot_dot, "'...' in JSX spread attribute");
                    const expr = try self.parseAssignmentExpression();
                    const close = try self.expect(.close_brace, "'}' to close JSX spread attribute");
                    const node = try self.builder.addJsxSpreadAttribute(
                        .{ .start = t.span.start, .end = close.span.end },
                        expr,
                    );
                    try attrs.append(self.gpa, node);
                },
                else => {
                    // `name`, `name="str"`, `name={expr}`.
                    const name_tok = self.advance();
                    const name_id = try self.internToken(name_tok);
                    var value: NodeId = hir_mod.none_node_id;
                    if (self.match(.equal)) {
                        if (self.peek().kind == .string_literal) {
                            const str_tok = self.advance();
                            const str_id = try self.internStringLiteral(str_tok);
                            value = try self.builder.addLiteralString(tokenSpan(str_tok), str_id);
                        } else if (self.peek().kind == .open_brace) {
                            _ = self.advance();
                            const expr = try self.parseAssignmentExpression();
                            _ = try self.expect(.close_brace, "'}' to close JSX expression value");
                            value = try self.builder.addJsxExpression(tokenSpan(name_tok), expr);
                        } else if (self.peek().kind == .less_than) {
                            // JSX-as-attribute-value: `prop={…}` is canonical
                            // but `prop=<Inner/>` is permitted by some
                            // dialects. Phase 1 follow-up.
                            value = try self.parseJsx();
                        }
                    }
                    const node = try self.builder.addJsxAttribute(
                        .{ .start = name_tok.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        name_id,
                        value,
                    );
                    try attrs.append(self.gpa, node);
                },
            }
        }

        // Self-closing `/>`.
        if (self.match(.slash)) {
            const close = try self.expect(.greater_than, "'>' to close self-closing JSX element");
            return try self.builder.addJsxElement(
                .{ .start = open.span.start, .end = close.span.end },
                tag,
                attrs.items,
                &.{},
                true,
            );
        }
        _ = try self.expect(.greater_than, "'>' to close JSX opening tag");

        var children: std.ArrayListUnmanaged(NodeId) = .empty;
        defer children.deinit(self.gpa);
        try self.parseJsxChildren(&children);

        // Closing tag `</Foo>`.
        _ = try self.expect(.less_than, "'<' to start JSX closing tag");
        _ = try self.expect(.slash, "'/' in JSX closing tag");
        // Skip the closing tag identifier (and any qualified-name
        // chain) — semantic equivalence is the binder's job.
        if (self.peek().kind == .identifier) {
            _ = self.advance();
            while (self.peek().kind == .dot) {
                _ = self.advance();
                _ = try self.expect(.identifier, "JSX closing-tag member");
            }
        }
        const close = try self.expect(.greater_than, "'>' to close JSX closing tag");
        return try self.builder.addJsxElement(
            .{ .start = open.span.start, .end = close.span.end },
            tag,
            attrs.items,
            children.items,
            false,
        );
    }

    fn parseJsxChildren(self: *Parser, out: *std.ArrayListUnmanaged(NodeId)) ParseError!void {
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .less_than => {
                    if (self.peekAt(1).kind == .slash) return; // `</Foo>`
                    const child = try self.parseJsxElementOrFragment();
                    try out.append(self.gpa, child);
                },
                .open_brace => {
                    _ = self.advance();
                    if (self.peek().kind == .close_brace) {
                        _ = self.advance();
                        const node = try self.builder.addJsxExpression(tokenSpan(t), hir_mod.none_node_id);
                        try out.append(self.gpa, node);
                        continue;
                    }
                    const expr = try self.parseAssignmentExpression();
                    const close = try self.expect(.close_brace, "'}' to close JSX child expression");
                    const node = try self.builder.addJsxExpression(
                        .{ .start = t.span.start, .end = close.span.end },
                        expr,
                    );
                    try out.append(self.gpa, node);
                },
                .eof => return,
                else => {
                    // Anything else is treated as an unrecognized
                    // child — likely free text, which the lexer is
                    // not currently emitting in JSX child position.
                    // Phase 1 follow-up: lexer mode switching.
                    try self.report("unsupported JSX child token: ", @tagName(t.kind));
                    return error.UnexpectedToken;
                },
            }
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
            // Spread element: `...expr`.
            if (self.peek().kind == .dot_dot_dot) {
                const dot_tok = self.advance();
                const inner = try self.parseAssignmentExpression();
                const end = self.tokens[self.cursor - 1].span.end;
                const sp = try self.builder.addSpread(.{ .start = dot_tok.span.start, .end = end }, inner);
                try elements.append(self.gpa, sp);
                if (!self.match(.comma)) break;
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

test "parser: for-await-of sets is_await flag" {
    var s = try newTestSetup("for await (const v of items) { use(v); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_of_stmt, s.hir.kindOf(top));
    const p = hir_mod.forInOf(&s.hir, top);
    try T.expect(p.is_await);
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

test "parser: import attributes with-clause" {
    var s = try newTestSetup("import x from \"./a.json\" with { type: \"json\" };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(top));
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expectEqualStrings("./a.json", s.interner.get(imp.module));
}

test "parser: import attributes assert-clause (legacy)" {
    var s = try newTestSetup("import x from \"./a.json\" assert { type: \"json\" };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(top));
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expectEqualStrings("./a.json", s.interner.get(imp.module));
}

test "parser: dynamic import with attributes argument" {
    var s = try newTestSetup("const p = import(\"./a.json\", { with: { type: \"json\" } });");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    // Just assert it parses without error — the dynamic-import call
    // shape is exercised here for compatibility only.
    _ = root;
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
    try T.expectEqual(hir_mod.NodeKind.new_expr, s.hir.kindOf(top));
    const args = hir_mod.callArgs(&s.hir, top);
    try T.expectEqual(@as(usize, 2), args.len);
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

test "parser: interface body parses members" {
    var s = try newTestSetup("interface Point { x: number; y: number; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.interfaceMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 2), members.len);
    const m0 = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    try T.expectEqualStrings("x", s.interner.get(m0.name));
    try T.expect(m0.type_node != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(m0.type_node));
}

test "parser: interface with optional + readonly members" {
    var s = try newTestSetup("interface I { readonly id: number; name?: string; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.interfaceMembers(&s.hir, top);
    const m0 = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    try T.expect(m0.is_readonly);
    const m1 = hir_mod.interfaceMemberOf(&s.hir, members[1]);
    try T.expect(m1.is_optional);
}

test "parser: interface method shorthand" {
    var s = try newTestSetup("interface Adder { add(a: number, b: number): number; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.interfaceMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    const m = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    try T.expect(m.is_method);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(m.type_node));
}

test "parser: object type literal" {
    var s = try newTestSetup("let p: { x: number; y: string } = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.object_type, s.hir.kindOf(v.type_annotation));
    const members = hir_mod.objectTypeMembers(&s.hir, v.type_annotation);
    try T.expectEqual(@as(usize, 2), members.len);
}

test "parser: type annotation — leading | accepted" {
    var s = try newTestSetup("let x: | A | B = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.union_type, s.hir.kindOf(v.type_annotation));
}

// ====================================================================
// JSX (TSX-only)
// ====================================================================

fn newTsxTestSetup(source: []const u8) !*TestSetup {
    const s = try newTestSetup(source);
    s.parser.setTsx(true);
    return s;
}

test "parser: jsx self-closing element" {
    var s = try newTsxTestSetup("let v = <Foo />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.jsx_self_closing, s.hir.kindOf(init_node));
    try T.expect(hir_mod.jsxElementOf(&s.hir, init_node).self_closing);
}

test "parser: jsx element with attribute" {
    var s = try newTsxTestSetup("let v = <Foo bar=\"baz\" />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    try T.expectEqual(@as(usize, 1), attrs.len);
    const a = hir_mod.jsxAttributeOf(&s.hir, attrs[0]);
    try T.expectEqualStrings("bar", s.interner.get(a.name));
}

test "parser: jsx element with expression attribute" {
    var s = try newTsxTestSetup("let v = <Foo bar={x + 1} />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    const a = hir_mod.jsxAttributeOf(&s.hir, attrs[0]);
    try T.expect(a.value != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.jsx_expression, s.hir.kindOf(a.value));
}

test "parser: jsx boolean shorthand attribute" {
    var s = try newTsxTestSetup("let v = <Foo bar />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    const a = hir_mod.jsxAttributeOf(&s.hir, attrs[0]);
    try T.expectEqual(hir_mod.none_node_id, a.value);
}

test "parser: jsx spread attribute" {
    var s = try newTsxTestSetup("let v = <Foo {...rest} />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    try T.expectEqual(hir_mod.NodeKind.jsx_spread_attribute, s.hir.kindOf(attrs[0]));
}

test "parser: jsx with expression child" {
    var s = try newTsxTestSetup("let v = <Foo>{count}</Foo>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.jsx_element, s.hir.kindOf(init_node));
    const children = hir_mod.jsxChildren(&s.hir, init_node);
    try T.expectEqual(@as(usize, 1), children.len);
    try T.expectEqual(hir_mod.NodeKind.jsx_expression, s.hir.kindOf(children[0]));
}

test "parser: jsx nested elements" {
    var s = try newTsxTestSetup("let v = <Outer><Inner /></Outer>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const children = hir_mod.jsxChildren(&s.hir, init_node);
    try T.expectEqual(@as(usize, 1), children.len);
    try T.expectEqual(hir_mod.NodeKind.jsx_self_closing, s.hir.kindOf(children[0]));
}

test "parser: jsx fragment" {
    var s = try newTsxTestSetup("let v = <>{a}{b}</>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.jsx_fragment, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 2), hir_mod.jsxFragmentChildren(&s.hir, init_node).len);
}

test "parser: jsx with member access tag" {
    var s = try newTsxTestSetup("let v = <Foo.Bar />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const el = hir_mod.jsxElementOf(&s.hir, init_node);
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(el.tag));
}

// ====================================================================
// Generics on declarations
// ====================================================================

test "parser: function with generic type parameters" {
    var s = try newTestSetup("function id<T>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const f = hir_mod.fnDeclOf(&s.hir, top);
    try T.expect(f.return_type != hir_mod.none_node_id);
    const params = hir_mod.fnParams(&s.hir, top);
    const pp = hir_mod.parameterOf(&s.hir, params[0]);
    try T.expect(pp.type_annotation != hir_mod.none_node_id);
}

test "parser: function with constrained generic" {
    var s = try newTestSetup("function f<T extends Foo>(x: T) {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
}

test "parser: function with default generic" {
    var s = try newTestSetup("function f<T = string>(x: T) {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
}

test "parser: class with generics" {
    var s = try newTestSetup("class Box<T> { value: T; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
}

test "parser: interface with generics" {
    var s = try newTestSetup("interface List<T extends Item> { head: T; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.interface_decl, s.hir.kindOf(top));
}

test "parser: type alias with generics" {
    var s = try newTestSetup("type Pair<A, B> = [A, B];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.type_alias_decl, s.hir.kindOf(top));
    const t = hir_mod.typeAliasOf(&s.hir, top);
    try T.expectEqual(@as(usize, 2), t.type_params_len);
    try T.expectEqual(hir_mod.NodeKind.tuple_type, s.hir.kindOf(t.aliased));
}

test "parser: decorator before class declaration" {
    var s = try newTestSetup("@logged class Foo {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.decorator, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(stmts[1]));
}

test "parser: decorator with call expression" {
    var s = try newTestSetup("@logged(\"info\") class Foo {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(hir_mod.NodeKind.decorator, s.hir.kindOf(stmts[0]));
    const dec = hir_mod.decoratorOf(&s.hir, stmts[0]);
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(dec.expression));
}

test "parser: multiple decorators" {
    var s = try newTestSetup("@a @b @c class Foo {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 4), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.decorator, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.decorator, s.hir.kindOf(stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.decorator, s.hir.kindOf(stmts[2]));
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(stmts[3]));
}

test "parser: parameter properties skip modifiers" {
    var s = try newTestSetup("class Foo { constructor(public x: number, private readonly y: string) {} }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
}

test "parser: accessor class member modifier (TS 4.9)" {
    // TS 4.9 introduced `accessor x = 0;` as a class member modifier
    // that declares an auto-accessor (a getter/setter pair backed by
    // a private field). For v0 we accept it as a modifier and lower
    // the member to a regular field — the emitter / checker treat it
    // identically to `x = 0;`.
    var s = try newTestSetup("class Foo { accessor x = 0; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    // The member is parsed as a regular property (object_property),
    // with the `accessor` keyword stripped by skipClassModifiers.
    try T.expectEqual(hir_mod.NodeKind.object_property, s.hir.kindOf(members[0]));
}

test "parser: accessor modifier preserves field name and initializer" {
    // Verify that after the `accessor` modifier is consumed, the field
    // name / initializer parse correctly so downstream type resolution
    // (e.g. `new Foo().x` typed as `number`) still works.
    var s = try newTestSetup("class Foo { accessor x = 0; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    const prop = hir_mod.objectPropertyOf(&s.hir, members[0]);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(prop.key));
    const ident = hir_mod.identifierOf(&s.hir, prop.key);
    try T.expectEqualStrings("x", s.interner.get(ident.name));
    // Initializer is the literal `0`.
    try T.expect(prop.value != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.literal_number, s.hir.kindOf(prop.value));
}

// ====================================================================
// Arrow functions
// ====================================================================

test "parser: arrow — single ident no parens" {
    var s = try newTestSetup("let f = x => x;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 1), hir_mod.fnParams(&s.hir, init_node).len);
}

test "parser: arrow — zero arg" {
    var s = try newTestSetup("let f = () => 42;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 0), hir_mod.fnParams(&s.hir, init_node).len);
}

test "parser: arrow — multiple args" {
    var s = try newTestSetup("let add = (x, y) => x + y;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
    try T.expectEqual(@as(usize, 2), hir_mod.fnParams(&s.hir, init_node).len);
}

test "parser: arrow — typed params + return" {
    var s = try newTestSetup("let f = (x: number): string => \"hi\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
}

test "parser: arrow — body block" {
    var s = try newTestSetup("let f = (x) => { return x + 1; };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
    const fn_p = hir_mod.fnDeclOf(&s.hir, init_node);
    try T.expectEqual(hir_mod.NodeKind.block_stmt, s.hir.kindOf(fn_p.body));
}

test "parser: `using x = getR();` parses with is_using=true on payload" {
    var s = try newTestSetup("function f() { using x = getR(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const fn_decl = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(fn_decl));
    const body = hir_mod.fnDeclOf(&s.hir, fn_decl).body;
    const inner = hir_mod.blockStmts(&s.hir, body);
    try T.expectEqual(@as(usize, 1), inner.len);
    try T.expectEqual(hir_mod.NodeKind.const_decl, s.hir.kindOf(inner[0]));
    const vd = hir_mod.varDeclOf(&s.hir, inner[0]);
    try T.expectEqual(true, vd.is_using);
    try T.expectEqual(false, vd.is_await_using);
    try T.expect(vd.init != hir_mod.none_node_id);
}

test "parser: `await using x = getR();` parses with is_await_using=true" {
    var s = try newTestSetup("async function f() { await using x = getR(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const fn_decl = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(fn_decl));
    const body = hir_mod.fnDeclOf(&s.hir, fn_decl).body;
    const inner = hir_mod.blockStmts(&s.hir, body);
    try T.expectEqual(@as(usize, 1), inner.len);
    try T.expectEqual(hir_mod.NodeKind.const_decl, s.hir.kindOf(inner[0]));
    const vd = hir_mod.varDeclOf(&s.hir, inner[0]);
    try T.expectEqual(false, vd.is_using);
    try T.expectEqual(true, vd.is_await_using);
    try T.expect(vd.init != hir_mod.none_node_id);
}

test "parser: arrow — async" {
    var s = try newTestSetup("let f = async (x) => x;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(init_node));
    try T.expect(hir_mod.fnDeclOf(&s.hir, init_node).flags.is_async);
}

test "parser: arrow — ambiguity (T) is grouping not arrow" {
    var s = try newTestSetup("let x = (1 + 2);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    // Should be a binary op, not an arrow.
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(init_node));
}

test "parser: arrow — passed as argument" {
    var s = try newTestSetup("map(x => x * 2);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(top));
    const args = hir_mod.callArgs(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(args[0]));
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

test "parser: this parameter captured as named-this parameter" {
    var s = try newTestSetup("function f(this: Foo, x: number): number { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    // §3.A.11: `this` lands in the param list as a regular
    // parameter named "this"; the JS emitter strips it before
    // lowering. So both `this` and `x` are present here.
    const params = hir_mod.fnParams(&s.hir, top);
    try T.expectEqual(@as(usize, 2), params.len);
    const this_p = hir_mod.parameterOf(&s.hir, params[0]);
    const this_id = hir_mod.identifierOf(&s.hir, this_p.name);
    try T.expectEqualStrings("this", s.interner.get(this_id.name));
}

test "parser: this parameter alone parses cleanly" {
    var s = try newTestSetup("function f(this: any) { }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const params = hir_mod.fnParams(&s.hir, top);
    // The `this:` parameter is captured (named "this"); JS emit
    // strips it. This was previously asserted as 0 — see §3.A.11.
    try T.expectEqual(@as(usize, 1), params.len);
}

test "parser: template literal type with no substitution" {
    var s = try newTestSetup("type T = `hello`;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.type_alias_decl, s.hir.kindOf(top));
}

// Phase 1.B follow-up: parser-driven `rescanTemplate` after each
// interpolated type expression is needed for `\`hello-${T}-world\``
// to lex correctly (the scanner currently can't reach the closing
// backtick when the interpolation contains an identifier-shaped
// type). The single-text path above already exercises the
// addTemplateLiteralType builder + lower path.

test "parser: variance modifier `in T` records variance=1" {
    var s = try newTestSetup("function f<in T>(): void {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    try T.expectEqual(@as(u8, 1), hir_mod.typeParameterOf(&s.hir, tps[0]).variance);
}

test "parser: variance modifier `out T` records variance=2" {
    var s = try newTestSetup("function f<out T>(): void {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    try T.expectEqual(@as(u8, 2), hir_mod.typeParameterOf(&s.hir, tps[0]).variance);
}

test "parser: variance modifier `in out T` records variance=3" {
    var s = try newTestSetup("function f<in out T>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    try T.expectEqual(@as(u8, 3), hir_mod.typeParameterOf(&s.hir, tps[0]).variance);
}

test "parser: no variance modifier records variance=0" {
    var s = try newTestSetup("function f<T>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    try T.expectEqual(@as(u8, 0), hir_mod.typeParameterOf(&s.hir, tps[0]).variance);
}

test "parser: TS 5.0 const type parameter `<const T>` records is_const=true" {
    var s = try newTestSetup("function f<const T>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    try T.expectEqual(true, hir_mod.typeParameterOf(&s.hir, tps[0]).is_const);
}

test "parser: TS 5.0 const type parameter with constraint `<const T extends string[]>`" {
    var s = try newTestSetup("function f<const T extends string[]>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
    const tp = hir_mod.typeParameterOf(&s.hir, tps[0]);
    try T.expectEqual(true, tp.is_const);
    try T.expect(tp.constraint != hir_mod.none_node_id);
}

test "parser: assertion return type — `asserts x` (predicate-less)" {
    var s = try newTestSetup("function assert(x: any): asserts x { }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const fn_p = hir_mod.fnDeclOf(&s.hir, top);
    try T.expect(fn_p.return_type != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_predicate_type, s.hir.kindOf(fn_p.return_type));
    const pred = hir_mod.typePredicateOf(&s.hir, fn_p.return_type);
    try T.expectEqual(true, pred.is_asserts);
    try T.expectEqual(@as(u16, 0), pred.param_index);
    // Predicate-less form: no `is T` target type recorded.
    try T.expectEqual(hir_mod.none_node_id, pred.target_type);
}

test "parser: assertion return type — `asserts x is string`" {
    var s = try newTestSetup("function assert(x: any): asserts x is string { }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const fn_p = hir_mod.fnDeclOf(&s.hir, top);
    try T.expect(fn_p.return_type != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_predicate_type, s.hir.kindOf(fn_p.return_type));
    const pred = hir_mod.typePredicateOf(&s.hir, fn_p.return_type);
    try T.expectEqual(true, pred.is_asserts);
    try T.expectEqual(@as(u16, 0), pred.param_index);
    try T.expect(pred.target_type != hir_mod.none_node_id);
}

test "parser: non-assertion `x is T` is still a type predicate (is_asserts=false)" {
    var s = try newTestSetup("function isStr(x: unknown): x is string { return true; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const fn_p = hir_mod.fnDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_predicate_type, s.hir.kindOf(fn_p.return_type));
    const pred = hir_mod.typePredicateOf(&s.hir, fn_p.return_type);
    try T.expectEqual(false, pred.is_asserts);
    try T.expect(pred.target_type != hir_mod.none_node_id);
}

test "parser: `yield* h()` parses with delegated flag set" {
    var s = try newTestSetup("function* g() { yield* h(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const fn_decl = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(fn_decl));
    const body = hir_mod.fnDeclOf(&s.hir, fn_decl).body;
    const inner = hir_mod.blockStmts(&s.hir, body);
    try T.expectEqual(@as(usize, 1), inner.len);
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(inner[0]));
    const y = hir_mod.yieldExprOf(&s.hir, inner[0]);
    // `type_node` slot is reused as the delegated-yield flag.
    try T.expect(y.type_node != hir_mod.none_node_id);
    try T.expect(y.expr != hir_mod.none_node_id);
}

test "parser: `yield 1; yield* h();` parses both forms with correct flags" {
    var s = try newTestSetup("function* g() { yield 1; yield* h(); }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const fn_decl = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(fn_decl));
    const body = hir_mod.fnDeclOf(&s.hir, fn_decl).body;
    const inner = hir_mod.blockStmts(&s.hir, body);
    try T.expectEqual(@as(usize, 2), inner.len);
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(inner[0]));
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(inner[1]));
    const plain = hir_mod.yieldExprOf(&s.hir, inner[0]);
    const delegated = hir_mod.yieldExprOf(&s.hir, inner[1]);
    try T.expectEqual(hir_mod.none_node_id, plain.type_node);
    try T.expect(delegated.type_node != hir_mod.none_node_id);
    try T.expect(plain.expr != hir_mod.none_node_id);
    try T.expect(delegated.expr != hir_mod.none_node_id);
}
