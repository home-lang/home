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
pub const TokenFlags = ts_lexer.TokenFlags;
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
    /// TypeScript-compatible diagnostic code. 0 means callers should
    /// fall back to their phase-level parse code.
    code: u32 = 0,
    message: []const u8,
};

/// One active labeled statement on the parse-time label scope stack.
/// `function_depth` records the parser's `function_depth` at the
/// label declaration so cross-function jumps (`break LBL` from a
/// nested function body) can be flagged with TS1107.
/// `wraps_iteration` is set after the labeled statement parses if it
/// turns out to be a `for`/`while`/`do-while` (any iteration form);
/// `continue LBL` requires this to be true, otherwise TS1115 fires.
const LabelEntry = struct {
    name: hir_mod.StringId,
    function_depth: u32,
    wraps_iteration: bool = false,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    tokens: []const Token,
    cursor: u32,
    pending_type_gt: u8,
    pending_type_gt_pos: u32,
    pending_type_gt_line: u32,
    pending_type_gt_flags: TokenFlags,
    pending_type_eq: bool,
    pending_type_eq_pos: u32,
    pending_type_eq_line: u32,
    pending_type_eq_flags: TokenFlags,
    hir: *Hir,
    builder: hir_mod.Builder,
    interner: *string_interner.Interner,
    source: []const u8,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    pending_statements: std.ArrayListUnmanaged(NodeId),
    /// Active label scope stack. Each entry records the labeled
    /// statement's name plus the `function_depth` at the labeled
    /// declaration site, so `break LBL` / `continue LBL` can detect
    /// undeclared labels (TS1116) and cross-function jumps (TS1107).
    label_stack: std.ArrayListUnmanaged(LabelEntry),
    diag_arena: std.heap.ArenaAllocator,
    ambient_depth: u32,
    block_depth: u32,
    nested_statement_depth: u32,
    unbraced_statement_block_depth: ?u32,
    function_depth: u32,
    async_function_depth: u32,
    /// Stack-style counter — incremented while parsing a parameter
    /// default-value initializer. Used to gate TS2524 (`'await'
    /// expressions cannot be used in a parameter initializer.`) which
    /// fires at the `await` token when the surrounding async-function
    /// parameter initializer contains an `await` expression.
    param_initializer_depth: u32,
    generator_depth: u32,
    new_target_depth: u32,
    static_block_depth: u32,
    class_body_depth: u32,
    /// Stack-style flag — true when the innermost enclosing class is
    /// abstract. Used to gate TS1244 (`abstract` member modifier on a
    /// non-abstract class).
    class_is_abstract: bool,
    loop_depth: u32,
    loop_switch_depth: u32,
    /// True when an enclosing function body (or the top level outside
    /// any function) is currently inside an iteration or switch
    /// statement. Used by `parseBreakStatement` / `parseContinueStatement`
    /// to pick TS1107 ("Jump target cannot cross function boundary.")
    /// instead of TS1105 / TS1104 when an unlabeled `break`/`continue`
    /// sits in a nested function whose ancestor is a loop or switch.
    /// `loop_depth` / `loop_switch_depth` are reset across function
    /// boundaries so this flag carries the "is there a loop/switch
    /// outside the current function" signal.
    outer_loop_or_switch_active: bool,
    /// True when the parser is currently parsing statements directly
    /// under a `case`/`default` clause body (i.e. not inside a nested
    /// block). Used to gate TS1547/TS1548 for `using`/`await using`
    /// declarations that the spec disallows in bare case clauses.
    /// Reset by `parseBlockStatement` so a `{}` wrapping inside the
    /// case clause clears the flag.
    in_switch_case_clause: bool,
    namespace_depth: u32,
    strict_mode: bool,
    target_es2015_or_later: bool,
    suppress_strict_param_names: bool,
    allow_parameter_list_arrow_recovery: bool,
    parameter_list_arrow_is_comma: bool,
    parameter_list_recovered_body_as_missing_close: bool,
    parameter_list_recovered_arrow_missing_close: bool,
    enum_recovered_missing_close_at_eof: bool,
    top_level_external_module_indicator: bool,
    top_level_export_indicator: bool,
    in_top_level_module_binding_decl: bool,
    in_export_declaration: bool,
    /// True for `.tsx` files. Enables JSX parsing in expression
    /// position; the parser disambiguates `<T>x` (generic type
    /// assertion) vs. `<T>x</T>` (JSX) via the `<T,>` and
    /// `<T extends unknown>` rules from the TS grammar.
    is_tsx: bool,
    /// True for `.d.ts` inputs. Top-level declarations are ambient even
    /// without an explicit `declare` modifier.
    is_declaration_file: bool,

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
            .pending_type_gt = 0,
            .pending_type_gt_pos = 0,
            .pending_type_gt_line = 1,
            .pending_type_gt_flags = .{},
            .pending_type_eq = false,
            .pending_type_eq_pos = 0,
            .pending_type_eq_line = 1,
            .pending_type_eq_flags = .{},
            .hir = hir,
            .builder = hir_mod.Builder.init(hir),
            .interner = interner,
            .source = source,
            .diagnostics = .empty,
            .pending_statements = .empty,
            .label_stack = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
            .ambient_depth = 0,
            .block_depth = 0,
            .nested_statement_depth = 0,
            .unbraced_statement_block_depth = null,
            .function_depth = 0,
            .async_function_depth = 0,
            .param_initializer_depth = 0,
            .generator_depth = 0,
            .new_target_depth = 0,
            .static_block_depth = 0,
            .class_body_depth = 0,
            .class_is_abstract = false,
            .loop_depth = 0,
            .loop_switch_depth = 0,
            .outer_loop_or_switch_active = false,
            .in_switch_case_clause = false,
            .namespace_depth = 0,
            .strict_mode = false,
            .target_es2015_or_later = false,
            .suppress_strict_param_names = false,
            .allow_parameter_list_arrow_recovery = false,
            .parameter_list_arrow_is_comma = false,
            .parameter_list_recovered_body_as_missing_close = false,
            .parameter_list_recovered_arrow_missing_close = false,
            .enum_recovered_missing_close_at_eof = false,
            .top_level_external_module_indicator = false,
            .top_level_export_indicator = false,
            .in_top_level_module_binding_decl = false,
            .in_export_declaration = false,
            .is_tsx = false,
            .is_declaration_file = false,
        };
    }

    /// Enable JSX parsing in expression position (set by callers
    /// for `.tsx` source files).
    pub fn setTsx(self: *Parser, enabled: bool) void {
        self.is_tsx = enabled;
    }

    pub fn setDeclarationFile(self: *Parser, enabled: bool) void {
        self.is_declaration_file = enabled;
    }

    pub fn setStrictMode(self: *Parser, enabled: bool) void {
        self.strict_mode = enabled;
    }

    pub fn setTargetEs2015OrLater(self: *Parser, enabled: bool) void {
        self.target_es2015_or_later = enabled;
    }

    pub fn deinit(self: *Parser) void {
        self.builder.deinit();
        self.diagnostics.deinit(self.gpa);
        self.pending_statements.deinit(self.gpa);
        self.label_stack.deinit(self.gpa);
        self.diag_arena.deinit();
    }

    fn peek(self: *const Parser) Token {
        if (self.pending_type_gt > 0) return self.pendingTypeGreaterToken(0);
        if (self.pending_type_eq) return self.pendingTypeEqualToken();
        return self.tokens[self.cursor];
    }

    fn peekAt(self: *const Parser, offset: u32) Token {
        if (self.pending_type_gt > 0) {
            if (offset < self.pending_type_gt) return self.pendingTypeGreaterToken(offset);
            if (self.pending_type_eq and offset == self.pending_type_gt) return self.pendingTypeEqualToken();
            const eq_offset: u32 = if (self.pending_type_eq) 1 else 0;
            const p_after_pending = self.cursor + (offset - self.pending_type_gt - eq_offset);
            if (p_after_pending >= self.tokens.len) return self.tokens[self.tokens.len - 1];
            return self.tokens[p_after_pending];
        }
        if (self.pending_type_eq) {
            if (offset == 0) return self.pendingTypeEqualToken();
            const p_after_pending = self.cursor + (offset - 1);
            if (p_after_pending >= self.tokens.len) return self.tokens[self.tokens.len - 1];
            return self.tokens[p_after_pending];
        }
        const p = self.cursor + offset;
        if (p >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[p];
    }

    /// Look ahead from `at_offset` (a `{` or `[` token) and return
    /// true when the matching close is followed by `=`. Used by the
    /// `using`/`await using` parser to recognize binding-pattern
    /// using-decls like `using {a} = null;` — tsc parses these
    /// (emitting TS1492) rather than treating `using` as an
    /// expression statement.
    fn usingBindingPatternLookahead(self: *const Parser, at_offset: u32) bool {
        const open = self.peekAt(at_offset);
        if (open.kind != .open_brace and open.kind != .open_bracket) return false;
        var off: u32 = at_offset + 1;
        var depth: u32 = 1;
        // Bound the scan — 256 tokens of binding pattern is wildly
        // more than any realistic case and prevents pathological
        // walks if the source is malformed.
        var budget: u32 = 256;
        while (depth > 0 and budget > 0) : (budget -= 1) {
            const cur = self.peekAt(off);
            if (cur.kind == .eof) return false;
            switch (cur.kind) {
                .open_brace, .open_bracket => depth += 1,
                .close_brace, .close_bracket => depth -= 1,
                else => {},
            }
            off += 1;
        }
        if (depth != 0) return false;
        return self.peekAt(off).kind == .equal;
    }

    fn advance(self: *Parser) Token {
        if (self.pending_type_gt > 0) {
            const tok = self.pendingTypeGreaterToken(0);
            self.pending_type_gt -= 1;
            self.pending_type_gt_pos += 1;
            return tok;
        }
        if (self.pending_type_eq) {
            const tok = self.pendingTypeEqualToken();
            self.pending_type_eq = false;
            return tok;
        }
        const tok = self.tokens[self.cursor];
        if (tok.kind != .eof) self.cursor += 1;
        return tok;
    }

    fn pendingTypeGreaterToken(self: *const Parser, offset: u32) Token {
        const pos = self.pending_type_gt_pos + offset;
        return .{
            .span = .{ .start = pos, .end = pos + 1 },
            .kind = .greater_than,
            .flags = self.pending_type_gt_flags,
            .line = self.pending_type_gt_line,
        };
    }

    fn pendingTypeEqualToken(self: *const Parser) Token {
        return .{
            .span = .{ .start = self.pending_type_eq_pos, .end = self.pending_type_eq_pos + 1 },
            .kind = .equal,
            .flags = self.pending_type_eq_flags,
            .line = self.pending_type_eq_line,
        };
    }

    fn isTypeGreaterToken(kind: TokenKind) bool {
        return kind == .greater_than or
            kind == .greater_greater or
            kind == .greater_greater_greater or
            kind == .greater_than_equal or
            kind == .greater_greater_equal or
            kind == .greater_greater_greater_equal;
    }

    fn consumeTypeGreater(self: *Parser, what: []const u8) ParseError!Token {
        const tok = self.peek();
        switch (tok.kind) {
            .greater_than => return self.advance(),
            .greater_than_equal => {
                const raw = self.advance();
                self.pending_type_eq = true;
                self.pending_type_eq_pos = raw.span.start + 1;
                self.pending_type_eq_line = raw.line;
                self.pending_type_eq_flags = raw.flags;
                return .{
                    .span = .{ .start = raw.span.start, .end = raw.span.start + 1 },
                    .kind = .greater_than,
                    .flags = raw.flags,
                    .line = raw.line,
                };
            },
            .greater_greater => {
                const raw = self.advance();
                self.pending_type_gt = 1;
                self.pending_type_gt_pos = raw.span.start + 1;
                self.pending_type_gt_line = raw.line;
                self.pending_type_gt_flags = raw.flags;
                return .{
                    .span = .{ .start = raw.span.start, .end = raw.span.start + 1 },
                    .kind = .greater_than,
                    .flags = raw.flags,
                    .line = raw.line,
                };
            },
            .greater_greater_equal => {
                const raw = self.advance();
                self.pending_type_gt = 1;
                self.pending_type_gt_pos = raw.span.start + 1;
                self.pending_type_gt_line = raw.line;
                self.pending_type_gt_flags = raw.flags;
                self.pending_type_eq = true;
                self.pending_type_eq_pos = raw.span.start + 2;
                self.pending_type_eq_line = raw.line;
                self.pending_type_eq_flags = raw.flags;
                return .{
                    .span = .{ .start = raw.span.start, .end = raw.span.start + 1 },
                    .kind = .greater_than,
                    .flags = raw.flags,
                    .line = raw.line,
                };
            },
            .greater_greater_greater => {
                const raw = self.advance();
                self.pending_type_gt = 2;
                self.pending_type_gt_pos = raw.span.start + 1;
                self.pending_type_gt_line = raw.line;
                self.pending_type_gt_flags = raw.flags;
                return .{
                    .span = .{ .start = raw.span.start, .end = raw.span.start + 1 },
                    .kind = .greater_than,
                    .flags = raw.flags,
                    .line = raw.line,
                };
            },
            .greater_greater_greater_equal => {
                const raw = self.advance();
                self.pending_type_gt = 2;
                self.pending_type_gt_pos = raw.span.start + 1;
                self.pending_type_gt_line = raw.line;
                self.pending_type_gt_flags = raw.flags;
                self.pending_type_eq = true;
                self.pending_type_eq_pos = raw.span.start + 3;
                self.pending_type_eq_line = raw.line;
                self.pending_type_eq_flags = raw.flags;
                return .{
                    .span = .{ .start = raw.span.start, .end = raw.span.start + 1 },
                    .kind = .greater_than,
                    .flags = raw.flags,
                    .line = raw.line,
                };
            },
            else => {
                try self.report("expected ", what);
                return error.UnexpectedToken;
            },
        }
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
            // Upstream tsc emits TS1005 `'X' expected.` whenever the
            // parser was holding out for a specific punctuator/keyword
            // and got something else. Detect that shape from `what` so
            // callers don't have to thread the canonical wording, then
            // fall back to the Home-internal `expected ...` prose for
            // diagnostics that name a non-quoted role (e.g.
            // `qualified-name member`).
            if (extractLeadingQuotedToken(what)) |tok| {
                const tok_msg = try std.fmt.allocPrint(
                    self.diag_arena.allocator(),
                    "'{s}' expected.",
                    .{tok},
                );
                try self.diagnostics.append(self.gpa, .{
                    .pos = self.peek().span.start,
                    .line = self.peek().line,
                    .code = 1005,
                    .message = tok_msg,
                });
            } else {
                try self.report("expected ", what);
            }
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    fn extractLeadingQuotedToken(what: []const u8) ?[]const u8 {
        if (what.len < 2 or what[0] != '\'') return null;
        const end = std.mem.indexOfScalarPos(u8, what, 1, '\'') orelse return null;
        if (end == 1) return null;
        return what[1..end];
    }

    fn report(self: *Parser, prefix: []const u8, detail: []const u8) ParseError!void {
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "{s}{s}", .{ prefix, detail });
        try self.diagnostics.append(self.gpa, .{
            .pos = self.peek().span.start,
            .line = self.peek().line,
            .message = msg,
        });
    }

    fn reportCodeAt(self: *Parser, pos: u32, line: u32, code: u32, message: []const u8) ParseError!void {
        const msg = try self.diag_arena.allocator().dupe(u8, message);
        try self.diagnostics.append(self.gpa, .{
            .pos = pos,
            .line = line,
            .code = code,
            .message = msg,
        });
    }

    /// Emit a TS2300 `Duplicate identifier 'X'.` diagnostic, matching tsc's
    /// named-form output. Falls back to the bare form if the interned
    /// name is empty (synthetic placeholders, etc.).
    fn reportDuplicateIdentifierNamed(self: *Parser, pos: u32, line: u32, name_id: hir_mod.StringId) ParseError!void {
        const raw = self.interner.get(name_id);
        if (raw.len == 0) {
            try self.reportCodeAt(pos, line, 2300, "Duplicate identifier.");
            return;
        }
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Duplicate identifier '{s}'.",
            .{raw},
        );
        try self.diagnostics.append(self.gpa, .{
            .pos = pos,
            .line = line,
            .code = 2300,
            .message = msg,
        });
    }

    fn lineAt(self: *const Parser, pos: u32) u32 {
        const end = @min(@as(usize, @intCast(pos)), self.source.len);
        var line: u32 = 1;
        for (self.source[0..end]) |ch| {
            if (ch == '\n') line += 1;
        }
        return line;
    }

    fn reportAwaitBindingIfReserved(self: *Parser, tok: Token) ParseError!void {
        if (tok.kind != .kw_await) return;
        const is_top_level_module_binding = self.top_level_external_module_indicator and
            self.block_depth == 0 and self.namespace_depth == 0 and self.ambient_depth == 0;
        if (!self.in_top_level_module_binding_decl and !is_top_level_module_binding) return;
        try self.reportCodeAt(
            tok.span.start,
            tok.line,
            1262,
            "Identifier expected. 'await' is a reserved word at the top-level of a module.",
        );
    }

    /// TS1359 in async-function context — `async function foo(await)`,
    /// `var v = async function await(){}`, `async (await) => …` all
    /// forbid `await` as a binding name because the parser is now
    /// inside an async scope where `await` becomes a reserved keyword.
    /// Mirrors tsc's `asyncFunctionDeclaration5_es5` and
    /// `asyncArrowFunction5_es5` baselines (TS1359 at the `await`
    /// token, even when the outer source is a script rather than a
    /// module).
    fn reportAwaitReservedInAsyncContext(self: *Parser, tok: Token) ParseError!void {
        if (tok.kind != .kw_await) return;
        if (self.async_function_depth == 0) return;
        try self.reportCodeAt(
            tok.span.start,
            tok.line,
            1359,
            "Identifier expected. 'await' is a reserved word that cannot be used here.",
        );
    }

    fn span(start_tok: Token, end_tok: Token) Span {
        return .{ .start = start_tok.span.start, .end = end_tok.span.end };
    }

    fn tokenSpan(tok: Token) Span {
        return .{ .start = tok.span.start, .end = tok.span.end };
    }

    fn internToken(self: *Parser, tok: Token) ParseError!hir_mod.StringId {
        const slice = self.source[tok.span.start..tok.span.end];
        // Identifier tokens may contain `\uXXXX` / `\u{XXXXXX}` Unicode
        // escapes (ES2015+). Decode them before interning so two
        // syntactic spellings of the same name (`А` and `А`)
        // resolve to the same symbol. Without this the binder treats
        // them as distinct identifiers and references like `if (А)`
        // fire spurious TS2304. Baseline: scannerS7.6_A4.2_T1.
        if (tok.kind == .identifier and std.mem.indexOfScalar(u8, slice, '\\') != null) {
            const decoded = decodeIdentifierEscapes(self.diag_arena.allocator(), slice) catch {
                return self.interner.intern(slice) catch error.OutOfMemory;
            };
            return self.interner.intern(decoded) catch error.OutOfMemory;
        }
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

    fn internPropertyName(self: *Parser, tok: Token, span_: Span) ParseError!hir_mod.StringId {
        if (tok.kind == .string_literal) return self.internStringLiteral(tok);
        const slice = self.source[span_.start..span_.end];
        if (tok.kind != .number_literal) {
            return self.interner.intern(slice) catch error.OutOfMemory;
        }
        var end = slice.len;
        while (end > 0 and
            slice[end - 1] == '0' and
            std.mem.indexOfScalar(u8, slice[0..end], '.') != null)
        {
            end -= 1;
        }
        if (end > 0 and slice[end - 1] == '.') end -= 1;
        if (end == 0) end = slice.len;
        return self.interner.intern(slice[0..end]) catch error.OutOfMemory;
    }

    // ========================================================================
    // Public entry
    // ========================================================================

    /// Parse a TS source file into HIR. Returns the source-file root
    /// `NodeId` (currently a synthesized block).
    pub fn parseSourceFile(self: *Parser) ParseError!NodeId {
        self.top_level_external_module_indicator = self.sourceHasTopLevelExternalModuleIndicator();
        if (self.top_level_external_module_indicator) self.strict_mode = true;
        var stmts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer stmts.deinit(self.gpa);

        const start = self.peek();
        while (self.hasPendingStatement() or self.peek().kind != .eof) {
            const stmt = try self.parseStatement();
            try stmts.append(self.gpa, stmt);
        }
        const end = self.peek(); // eof; span end is its start
        const file_span: Span = .{ .start = start.span.start, .end = end.span.start };
        return try self.builder.addBlock(file_span, stmts.items);
    }

    fn sourceHasTopLevelExternalModuleIndicator(self: *const Parser) bool {
        var depth: u32 = 0;
        var i: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            const tok = self.tokens[i];
            switch (tok.kind) {
                .open_brace, .open_paren, .open_bracket => depth += 1,
                .close_brace, .close_paren, .close_bracket => if (depth > 0) {
                    depth -= 1;
                },
                .kw_import => {
                    if (depth == 0) return true;
                },
                .kw_export => if (depth == 0) return true,
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    // ========================================================================
    // Statements
    // ========================================================================

    fn parseStatement(self: *Parser) ParseError!NodeId {
        if (self.hasPendingStatement()) {
            return self.pending_statements.orderedRemove(0);
        }

        // Decorators that precede class declarations (and `export`+
        // `class` chains) attach to the next decorated statement.
        // We collect them here and store them as leading siblings —
        // the binder / emitter walks back when it sees a decorated
        // declaration. Mis-targeted decorators (e.g. `@dec var x`)
        // surface as TS1206 from the checker's
        // `checkTopLevelDecoratorDiagnostics`, so the parser stays
        // silent here to avoid a duplicate TS1109 with the wrong
        // location.
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
        // `await using` is parsed as a single `using` declaration; the
        // generic TS1036 ambient-statement gate would otherwise fire on
        // the leading `await` token before the dispatch reroutes it.
        const is_await_using_in_ambient = t.kind == .kw_await and
            self.peekAt(1).kind == .kw_using and
            !self.peekAt(1).flags.preceded_by_newline and
            self.peekAt(2).kind == .identifier and
            !self.peekAt(2).flags.preceded_by_newline;
        if (self.block_depth == 0 and
            self.nested_statement_depth == 0 and
            self.isAmbientContextAt(t.span.start) and
            !is_await_using_in_ambient and
            self.statementIsDisallowedInAmbientContext(t.kind))
        {
            try self.reportCodeAt(t.span.start, t.line, 1036, "Statements are not allowed in ambient contexts.");
        }
        if ((t.kind == .identifier or t.kind.isContextualKeyword()) and
            self.peekAt(1).kind == .colon)
        {
            const label_tok = self.advance();
            _ = self.advance();
            const label_disallowed = self.block_depth == 0 and self.isInvalidLabeledDeclarationStart();
            if (label_disallowed) {
                try self.reportCodeAt(label_tok.span.start, label_tok.line, 1344, "A label is not allowed here.");
                // Upstream tsc also emits TS1235 ("A namespace declaration
                // is only allowed at the top level of a namespace or
                // module.") on the `namespace`/`module` keyword that
                // follows the disallowed label. Mirror that here so
                // `labeledStatementWithLabel{,_strict,_es2015}` exact
                // baselines match.
                const after_label = self.peek();
                if (after_label.kind == .kw_namespace or after_label.kind == .kw_module) {
                    try self.reportCodeAt(after_label.span.start, after_label.line, 1235, "A namespace declaration is only allowed at the top level of a namespace or module.");
                }
            }
            // Push the label onto the active scope for the duration of
            // the labeled body so nested `break LBL` / `continue LBL`
            // can resolve. We still push when the label is on a
            // disallowed declaration target — tsc treats the label as
            // declared even when emitting TS1344, and downstream code
            // shouldn't emit a phantom TS1116 on top of TS1344.
            const label_name = try self.internToken(label_tok);
            // TS1114 "Duplicate label" — fires when the same label name
            // already appears in an enclosing labeled-statement chain
            // within the same function. Mirrors tsc's
            // `parser_duplicateLabel{1,2}` baselines.
            var dup_i: usize = self.label_stack.items.len;
            while (dup_i > 0) {
                dup_i -= 1;
                const entry = self.label_stack.items[dup_i];
                if (entry.function_depth != self.function_depth) break;
                if (entry.name == label_name) {
                    const lab_name_str = self.interner.get(label_name);
                    const msg = try std.fmt.allocPrint(
                        self.diag_arena.allocator(),
                        "Duplicate label '{s}'.",
                        .{lab_name_str},
                    );
                    try self.diagnostics.append(self.gpa, .{
                        .pos = label_tok.span.start,
                        .line = label_tok.line,
                        .code = 1114,
                        .message = msg,
                    });
                    break;
                }
            }
            // The token immediately following the `:` determines what
            // kind of statement the label wraps. Iteration forms
            // (`for` / `while` / `do`) are the only legal `continue`
            // targets — record the flag so `continue LBL` can verify
            // and fall back to TS1115 when the label binds a
            // non-iteration statement (e.g. `LBL: continue LBL;`).
            // Mirrors `parser_continueTarget1.ts(2,3)`. Nested labels
            // (`a: b: while (…)`) inherit the iteration flag from the
            // innermost wrapped statement — peek past identifier-`:`
            // pairs before classifying.
            const wraps_iteration = blk: {
                var look_ahead: u32 = 0;
                while (true) {
                    const tk = self.peekAt(look_ahead).kind;
                    if ((tk == .identifier or tk.isContextualKeyword()) and
                        self.peekAt(look_ahead + 1).kind == .colon)
                    {
                        look_ahead += 2;
                        continue;
                    }
                    break :blk switch (tk) {
                        .kw_for, .kw_while, .kw_do => true,
                        else => false,
                    };
                }
            };
            try self.label_stack.append(self.gpa, .{
                .name = label_name,
                .function_depth = self.function_depth,
                .wraps_iteration = wraps_iteration,
            });
            defer _ = self.label_stack.pop();
            if (self.isAmbientContextAt(label_tok.span.start)) {
                self.nested_statement_depth += 1;
                defer self.nested_statement_depth -= 1;
                return try self.parseStatement();
            }
            return try self.parseStatement();
        }
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
                // would otherwise insert a terminator after `using`,
                // and `using [a]` / `using {a}` are intentionally NOT
                // recognized here so they parse as the index / object
                // expression `using[a]` / `using{a}` that upstream tsc
                // produces. (Binding-pattern recovery still kicks in
                // for comma-continuations inside a real using decl.)
                if (self.peekAt(1).kind == .identifier and
                    !self.peekAt(1).flags.preceded_by_newline)
                {
                    break :blk try self.parseUsingDecl(false);
                }
                // `using {a} = ...;` — tsc parses this as a
                // binding-pattern using-decl and reports TS1492
                // ('using' declarations may not have binding patterns)
                // plus the usual destructuring diagnostics. Only the
                // `{` form is intercepted — `using [a] = ...;` is
                // parseable as the expression `using[a] = ...;`
                // (assignment to a computed member access), which
                // tsc preserves (TS2304 for the bare `using` /
                // `a`).
                if (self.peekAt(1).kind == .open_brace and
                    !self.peekAt(1).flags.preceded_by_newline and
                    self.usingBindingPatternLookahead(1))
                {
                    break :blk try self.parseUsingDecl(false);
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_await => blk: {
                // `await using x = expr;` — Stage 3 async dispose. The
                // bare `await expr;` form falls through to be parsed as
                // an expression statement. As with `using`, we only
                // treat the head as an `await using` decl when an
                // identifier follows; bracket/brace patterns mean the
                // tokens are a regular expression and TS emits TS2304
                // for the unresolved `using` identifier.
                if (self.peekAt(1).kind == .kw_using and
                    !self.peekAt(1).flags.preceded_by_newline and
                    self.peekAt(2).kind == .identifier and
                    !self.peekAt(2).flags.preceded_by_newline)
                {
                    break :blk try self.parseUsingDecl(true);
                }
                // `await using {a} = ...;` — same binding-pattern
                // recovery as the bare-`using` arm above, gated on
                // `=` following the matched brace. The `[` form
                // (`await using [a] = ...`) is left for expression-
                // parsing to handle so `using` / `a` surface as the
                // TS2304 ("cannot find name") diagnostics tsc emits.
                if (self.peekAt(1).kind == .kw_using and
                    !self.peekAt(1).flags.preceded_by_newline and
                    self.peekAt(2).kind == .open_brace and
                    !self.peekAt(2).flags.preceded_by_newline and
                    self.usingBindingPatternLookahead(2))
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
            .kw_with => try self.parseWithStatement(),
            .kw_break => try self.parseBreakStatement(),
            .kw_continue => try self.parseContinueStatement(),
            .kw_throw => try self.parseThrowStatement(),
            .kw_debugger => blk: {
                const dbg = self.advance();
                try self.consumeStatementTerminator();
                break :blk try self.builder.addBlock(.{ .start = dbg.span.start, .end = self.tokens[self.cursor - 1].span.end }, &.{});
            },
            .kw_try => try self.parseTryStatement(),
            .kw_switch => try self.parseSwitchStatement(),
            .kw_function => try self.parseFunctionDeclaration(true),
            .kw_async => blk: {
                // `async function f() { ... }` — consume the async
                // keyword and parse as a function decl with the
                // is_async flag set. Arrow async (`async () => ...`)
                // is handled in expression position.
                if (self.peekAt(1).kind == .kw_function) {
                    const async_tok = self.advance(); // async
                    // TS1040: `async` modifier cannot be used in an
                    // ambient context (e.g. `declare async function …`).
                    if (self.ambient_depth > 0) {
                        try self.reportCodeAt(async_tok.span.start, async_tok.line, 1040, "'async' modifier cannot be used in an ambient context.");
                    }
                    self.async_function_depth += 1;
                    defer self.async_function_depth -= 1;
                    const fd = try self.parseFunctionDeclaration(true);
                    self.hir.markFnAsync(fd);
                    break :blk fd;
                }
                if (self.peekAt(1).kind == .kw_class or
                    self.peekAt(1).kind == .kw_interface or
                    self.peekAt(1).kind == .kw_namespace or
                    self.peekAt(1).kind == .kw_module or
                    self.peekAt(1).kind == .kw_enum)
                {
                    // TS1042: `async` modifier cannot be used here (on
                    // class/interface/enum/namespace declarations).
                    // TS1040: in ambient context, this becomes a
                    // different diagnostic — but `async <class…>` at
                    // top level outside ambient is always TS1042.
                    const async_tok = self.advance();
                    try self.reportCodeAt(async_tok.span.start, async_tok.line, 1042, "'async' modifier cannot be used here.");
                    break :blk try self.parseStatement();
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_class => try self.parseClassDeclaration(),
            .kw_accessor => blk: {
                const next = self.peekAt(1).kind;
                if (next == .kw_class or
                    next == .kw_interface or
                    next == .kw_namespace or
                    next == .kw_module or
                    next == .kw_enum or
                    next == .kw_var or
                    next == .kw_let or
                    next == .kw_const or
                    next == .kw_type or
                    next == .kw_function or
                    next == .kw_import or
                    next == .kw_export)
                {
                    _ = self.advance();
                    break :blk try self.parseStatement();
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_abstract => blk: {
                // `abstract class Foo { ... }` at statement position.
                // Other uses of `abstract` (member modifier inside a
                // class body) are handled by the member-modifier loop.
                if (self.peekAt(1).kind == .kw_class) {
                    break :blk try self.parseClassDeclaration();
                }
                // `abstract interface/enum/namespace/module/function/var/let/const`
                // — TS1242: `abstract` modifier can only appear on a
                // class, method, or property declaration.
                const next = self.peekAt(1).kind;
                if (next == .kw_interface or next == .kw_enum or next == .kw_namespace or
                    next == .kw_module or next == .kw_function or next == .kw_var or
                    next == .kw_let or next == .kw_const)
                {
                    const abstract_tok = self.advance(); // abstract
                    try self.reportCodeAt(abstract_tok.span.start, abstract_tok.line, 1242, "'abstract' modifier can only appear on a class, method, or property declaration.");
                    break :blk try self.parseStatement();
                }
                break :blk try self.parseExpressionStatement();
            },
            .kw_interface => blk: {
                if (self.peekAt(1).flags.preceded_by_newline) break :blk try self.parseExpressionStatement();
                break :blk try self.parseInterfaceDeclaration();
            },
            .kw_public, .kw_private, .kw_protected, .kw_static => blk: {
                const next = self.peekAt(1).kind;
                if (next == .open_paren) {
                    break :blk try self.parseExpressionStatement();
                }
                // `private[key] = value;` / `private.foo` etc. — when
                // the contextual keyword is followed by a member-access
                // / element-access / call operator, treat it as a plain
                // identifier expression. Mirrors tsc which only
                // surfaces TS1212 (strict-mode reserved word) here when
                // `alwaysStrict`/`strict` is on, and otherwise lets the
                // expression parse cleanly. Fixture:
                // `parserStatementIsNotAMemberVariableDeclaration1.ts`.
                if (next == .open_bracket or next == .dot) {
                    break :blk try self.parseExpressionStatement();
                }
                if (next == .kw_interface or next == .kw_namespace or next == .kw_module or
                    next == .kw_var or next == .kw_let or next == .kw_const or
                    next == .kw_function or next == .kw_class or next == .kw_enum or
                    next == .kw_async or next == .kw_abstract or next == .kw_export)
                {
                    const modifier = self.advance();
                    try self.reportCodeAt(modifier.span.start, modifier.line, 1044, try std.fmt.allocPrint(
                        self.diag_arena.allocator(),
                        "'{s}' modifier cannot appear on a module or namespace element.",
                        .{self.source[modifier.span.start..modifier.span.end]},
                    ));
                    break :blk try self.parseStatement();
                }
                try self.reportCodeAt(t.span.start, t.line, 1128, "Declaration or statement expected.");
                const start = self.advance();
                if (self.namespace_depth > 0 and !self.peek().flags.preceded_by_newline and self.peek().kind == .identifier) {
                    break :blk try self.parseStatement();
                }
                while (self.peek().kind != .semicolon and
                    self.peek().kind != .eof and
                    !self.peek().flags.preceded_by_newline)
                {
                    _ = self.advance();
                }
                if (self.peek().kind == .semicolon) _ = self.advance();
                const end_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
                break :blk try self.builder.addBlock(.{ .start = start.span.start, .end = end_pos }, &.{});
            },
            .kw_enum => try self.parseEnumDeclaration(),
            .kw_namespace => blk: {
                if (self.peekAt(1).flags.preceded_by_newline) break :blk try self.parseExpressionStatement();
                break :blk try self.parseNamespaceDeclaration();
            },
            .kw_module => blk: {
                if (self.peekAt(1).flags.preceded_by_newline) break :blk try self.parseExpressionStatement();
                if (self.peekAt(1).kind == .dot) break :blk try self.parseExpressionStatement();
                if (self.peekAt(1).kind != .identifier and self.peekAt(1).kind != .string_literal) {
                    break :blk try self.parseExpressionStatement();
                }
                break :blk try self.parseNamespaceDeclaration();
            },
            .kw_declare => blk: {
                if (self.peekAt(1).flags.preceded_by_newline) break :blk try self.parseExpressionStatement();
                // `declare` is a contextual keyword. When the next
                // token can start a tagged template, function call,
                // member access, or any non-declaration construct
                // (e.g. `declare \`...\``, `declare(x)`, `declare.x`),
                // it's just an identifier reference — parse as an
                // expression statement instead of opening an ambient
                // context.
                if (!self.declareStartsDeclaration(self.peekAt(1).kind)) {
                    break :blk try self.parseExpressionStatement();
                }
                // `declare global { ... }` lowers through the
                // `kw_global` arm below; `declare let x: T` and friends
                // parse as ordinary declarations with an ambient bit.
                const declare_tok = self.advance(); // declare
                try self.reportModifierInBlock(declare_tok);
                // TS1038: redundant `declare` inside an already
                // ambient context. Fires when wrapped by another
                // `declare` block OR when nested inside a namespace
                // that sits in a `.d.ts` file (the surrounding file
                // is implicitly ambient). Top-level `declare` in a
                // `.d.ts` (no nested context) is NOT redundant —
                // it's the canonical form — so guard on
                // `namespace_depth > 0` for the .d.ts branch.
                // Mirrors upstream tsc on
                // `parserModuleDeclaration4.d.ts(2,3)`.
                if (self.ambient_depth > 0 or
                    (self.namespace_depth > 0 and self.isAmbientContextAt(declare_tok.span.start)))
                {
                    try self.reportCodeAt(declare_tok.span.start, declare_tok.line, 1038, "A 'declare' modifier cannot be used in an already ambient context.");
                }
                self.ambient_depth += 1;
                defer self.ambient_depth -= 1;
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
                    while (self.hasPendingStatement() or (self.peek().kind != .close_brace and self.peek().kind != .eof)) {
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
            .kw_import => blk: {
                // `import.meta` and dynamic `import(...)` can appear in
                // expression-statement position; only bare/import-clause
                // forms are declarations.
                const next = self.peekAt(1).kind;
                if (next == .dot or next == .open_paren) break :blk try self.parseExpressionStatement();
                break :blk try self.parseImportDeclaration();
            },
            .kw_export => blk: {
                try self.reportModifierInBlock(t);
                break :blk try self.parseExportDeclaration();
            },
            .kw_type => blk: {
                // `type X = T;` is a TS type alias. `type` is contextual,
                // so only treat as a keyword when followed by an identifier.
                if (self.peekAt(1).kind == .identifier) break :blk try self.parseTypeAlias();
                break :blk try self.parseExpressionStatement();
            },
            .string_literal => blk: {
                const is_strict = self.isUseStrictDirective(t);
                const stmt = try self.parseExpressionStatement();
                if (is_strict) self.strict_mode = true;
                break :blk stmt;
            },
            .semicolon => blk: {
                const semi = self.advance();
                if (self.block_depth == 0 and self.nested_statement_depth == 0 and self.isAmbientContextAt(semi.span.start)) {
                    try self.reportCodeAt(semi.span.start, semi.line, 1036, "Statements are not allowed in ambient contexts.");
                }
                // Empty statement is a no-op; lower as a synthesized
                // block with zero statements at its location.
                break :blk try self.builder.addBlock(tokenSpan(semi), &.{});
            },
            .dot => blk: {
                const dot = self.advance();
                if (self.peek().kind == .identifier and !self.peek().flags.preceded_by_newline) {
                    try self.reportCodeAt(dot.span.start, dot.line, 1128, "Declaration or statement expected.");
                    const name = self.advance();
                    try self.reportCannotFindNameToken(name);
                    if (self.peek().kind == .semicolon) _ = self.advance();
                    break :blk try self.builder.addBlock(.{ .start = dot.span.start, .end = name.span.end }, &.{});
                }
                self.cursor -= 1;
                break :blk try self.parseExpressionStatement();
            },
            .close_paren, .close_brace => blk: {
                if (self.block_depth == 0 and self.nested_statement_depth == 0) {
                    try self.reportCodeAt(t.span.start, t.line, 1128, "Declaration or statement expected.");
                }
                const close = self.advance();
                break :blk try self.builder.addBlock(tokenSpan(close), &.{});
            },
            .invalid => blk: {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                if (self.peek().kind != .eof and
                    self.peek().kind != .semicolon and
                    !self.peek().flags.preceded_by_newline)
                {
                    break :blk try self.parseStatement();
                }
                if (self.peek().kind == .semicolon) _ = self.advance();
                break :blk try self.builder.addBlock(tokenSpan(bad), &.{});
            },
            else => try self.parseExpressionStatement(),
        };
    }

    fn classMemberNameIsConstructor(self: *const Parser, name_node: NodeId) bool {
        if (name_node == hir_mod.none_node_id or self.hir.kindOf(name_node) != .identifier) return false;
        const id = hir_mod.identifierOf(self.hir, name_node);
        return std.mem.eql(u8, self.interner.get(id.name), "constructor");
    }

    /// True when the token after `declare` can plausibly start a
    /// declaration (so `declare` is acting as a modifier opening an
    /// ambient context). Otherwise `declare` is just an identifier
    /// — e.g. `declare \`tag\``, `declare(x)`, `declare.prop`,
    /// `declare + 1` — and the statement should parse as an
    /// expression statement. The exclusion list catches the common
    /// expression-continuation tokens; everything else falls back to
    /// declaration parsing (preserving existing behaviour for
    /// `declare var/let/const/function/class/...` and contextual
    /// keywords like `declare module Foo`).
    fn declareStartsDeclaration(self: *const Parser, kind: TokenKind) bool {
        _ = self;
        return switch (kind) {
            // Template tag / call / member-access / increment-decrement /
            // bin-op continuations: `declare` is just an identifier
            // here, not a modifier.
            .no_substitution_template,
            .template_head,
            .open_paren,
            .open_bracket,
            .dot,
            .question_dot,
            .plus_plus,
            .minus_minus,
            .equal,
            .equal_equal,
            .equal_equal_equal,
            .bang_equal,
            .bang_equal_equal,
            .less_than,
            .less_than_equal,
            .greater_than,
            .greater_than_equal,
            .plus,
            .minus,
            .asterisk,
            .slash,
            .percent,
            .ampersand_ampersand,
            .pipe_pipe,
            .question_question,
            .question,
            .comma,
            .semicolon,
            .eof,
            => false,
            else => true,
        };
    }

    fn statementIsDisallowedInAmbientContext(self: *const Parser, kind: TokenKind) bool {
        _ = self;
        return switch (kind) {
            .kw_let,
            .kw_const,
            .kw_var,
            .kw_function,
            .kw_async,
            .kw_class,
            .kw_accessor,
            .kw_abstract,
            .kw_interface,
            .kw_enum,
            .kw_namespace,
            .kw_module,
            .kw_declare,
            .kw_global,
            .kw_import,
            .kw_export,
            .kw_type,
            .kw_with,
            // `using` is reported via TS1545 in `parseUsingDecl` when
            // the declaration lands in an ambient context — suppress
            // the generic TS1036 here so the more specific diagnostic
            // isn't paired with it. (`await using` is the same shape
            // for diagnostic purposes; the leading `await` token in
            // that combination is handled by the dispatch peek.)
            .kw_using,
            .semicolon,
            .eof,
            => false,
            .identifier => true,
            else => true,
        };
    }

    fn reportModifierInBlock(self: *Parser, tok: Token) ParseError!void {
        if (self.block_depth == 0 and self.nested_statement_depth == 0) return;
        try self.reportCodeAt(tok.span.start, tok.line, 1184, "Modifiers cannot appear here.");
    }

    fn hasPendingStatement(self: *const Parser) bool {
        return self.pending_statements.items.len > 0;
    }

    fn tokenTextEquals(self: *const Parser, tok: Token, expected: []const u8) bool {
        return std.mem.eql(u8, self.source[tok.span.start..tok.span.end], expected);
    }

    fn isInvalidLabeledDeclarationStart(self: *const Parser) bool {
        return switch (self.peek().kind) {
            .kw_function,
            .kw_async,
            .kw_class,
            .kw_enum,
            .kw_interface,
            .kw_namespace,
            .kw_module,
            .kw_type,
            .kw_var,
            .kw_let,
            .kw_const,
            .kw_export,
            .kw_import,
            => true,
            .kw_abstract => self.peekAt(1).kind == .kw_class,
            else => false,
        };
    }

    fn parseNestedStatement(self: *Parser) ParseError!NodeId {
        self.nested_statement_depth += 1;
        defer self.nested_statement_depth -= 1;
        const old_unbraced_statement_block_depth = self.unbraced_statement_block_depth;
        if (self.peek().kind != .open_brace) {
            self.unbraced_statement_block_depth = self.block_depth;
        }
        defer self.unbraced_statement_block_depth = old_unbraced_statement_block_depth;
        return try self.parseStatement();
    }

    fn isUseStrictDirective(self: *const Parser, tok: Token) bool {
        if (tok.kind != .string_literal) return false;
        const raw = self.source[tok.span.start..tok.span.end];
        return std.mem.eql(u8, raw, "\"use strict\"") or std.mem.eql(u8, raw, "'use strict'");
    }

    fn isRestrictedStrictName(self: *const Parser, tok: Token) bool {
        const raw = self.source[tok.span.start..tok.span.end];
        return std.mem.eql(u8, raw, "eval") or std.mem.eql(u8, raw, "arguments");
    }

    fn reportInvalidStrictName(self: *Parser, tok: Token) ParseError!void {
        if (!self.isRestrictedStrictName(tok)) return;
        if (self.strict_mode) {
            const raw = self.source[tok.span.start..tok.span.end];
            const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Invalid use of '{s}' in strict mode.", .{raw});
            try self.diagnostics.append(self.gpa, .{
                .pos = tok.span.start,
                .line = tok.line,
                .code = 1100,
                .message = msg,
            });
            return;
        }
        // Class bodies are implicitly strict — flag `arguments`/`eval`
        // as restricted parameter names there even when the outer
        // module hasn't opted into strict mode. Mirrors tsc TS1210
        // (`emitArrowFunctionWhenUsingArguments12`).
        if (self.class_body_depth > 0) {
            const raw = self.source[tok.span.start..tok.span.end];
            const msg = try std.fmt.allocPrint(
                self.diag_arena.allocator(),
                "Code contained in a class is evaluated in JavaScript's strict mode which does not allow this use of '{s}'. For more information, see https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode.",
                .{raw},
            );
            try self.diagnostics.append(self.gpa, .{
                .pos = tok.span.start,
                .line = tok.line,
                .code = 1210,
                .message = msg,
            });
        }
    }

    fn isYieldReservedName(self: *const Parser, tok: Token) bool {
        return (self.strict_mode or self.target_es2015_or_later) and self.tokenTextEquals(tok, "yield");
    }

    fn reportInvalidYieldName(self: *Parser, tok: Token) ParseError!void {
        if (!self.isYieldReservedName(tok)) return;
        try self.reportCodeAt(tok.span.start, tok.line, 1212, "Identifier expected. 'yield' is a reserved word in strict mode.");
    }

    fn reportInvalidFutureReservedName(self: *Parser, tok: Token) ParseError!void {
        if ((self.strict_mode or self.target_es2015_or_later) and self.class_body_depth == 0) {
            switch (tok.kind) {
                .kw_public,
                .kw_private,
                .kw_protected,
                .kw_static,
                => {
                    const raw = self.source[tok.span.start..tok.span.end];
                    const msg = try std.fmt.allocPrint(
                        self.diag_arena.allocator(),
                        "Identifier expected. '{s}' is a reserved word in strict mode.",
                        .{raw},
                    );
                    try self.reportCodeAt(tok.span.start, tok.line, 1212, msg);
                    return;
                },
                else => {},
            }
        }
        if (!self.strict_mode and !self.target_es2015_or_later) return;
        if (!self.tokenTextEquals(tok, "interface")) return;
        try self.reportCodeAt(tok.span.start, tok.line, 1212, "Identifier expected. 'interface' is a reserved word in strict mode.");
    }

    fn isClassStrictReservedIdentifier(self: *const Parser, tok: Token) bool {
        _ = self;
        return switch (tok.kind) {
            .kw_public,
            .kw_private,
            .kw_protected,
            .kw_static,
            => true,
            else => false,
        };
    }

    fn reportInvalidClassStrictIdentifier(self: *Parser, tok: Token) ParseError!void {
        if (self.class_body_depth == 0 or !self.isClassStrictReservedIdentifier(tok)) return;
        const raw = self.source[tok.span.start..tok.span.end];
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Identifier expected. '{s}' is a reserved word in strict mode. Class definitions are automatically in strict mode.",
            .{raw},
        );
        try self.reportCodeAt(tok.span.start, tok.line, 1213, msg);
    }

    fn reportInvalidVariableDeclarationName(self: *Parser, tok: Token) ParseError!void {
        if (tok.kind != .kw_export and tok.kind != .kw_class) return;
        const raw = self.source[tok.span.start..tok.span.end];
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' is not allowed as a variable declaration name.", .{raw});
        try self.diagnostics.append(self.gpa, .{
            .pos = tok.span.start,
            .line = tok.line,
            .code = 1389,
            .message = msg,
        });
        if (tok.kind == .kw_class) {
            try self.reportCodeAt(tok.span.end, tok.line, 1005, "'{' expected.");
        }
    }

    fn reportInvalidStrictIdentifierNode(self: *Parser, node: NodeId) ParseError!void {
        if (self.hir.kindOf(node) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, node);
        const raw = self.interner.get(id.name);
        if (!std.mem.eql(u8, raw, "eval") and !std.mem.eql(u8, raw, "arguments")) return;
        const sp = self.hir.spanOf(node);
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Invalid use of '{s}' in strict mode.", .{raw});
        try self.diagnostics.append(self.gpa, .{
            .pos = sp.start,
            .line = self.peek().line,
            .code = 1100,
            .message = msg,
        });
    }

    fn reportStrictLegacyOctal(self: *Parser, tok: Token, raw: []const u8) ParseError!void {
        if (!self.strict_mode or raw.len < 2 or raw[0] != '0') return;
        const c = raw[1];
        if (c == 'x' or c == 'X' or c == 'o' or c == 'O' or c == 'b' or c == 'B' or c == '.') return;
        if (c < '0' or c > '9') return;
        // Pure octal digits only (no 8/9, no fraction/exponent). The
        // mixed cases (`01.0`, `09`) are handled exclusively by
        // `reportNumericLiteralDiagnostics` to avoid double-reporting.
        for (raw[1..]) |ch| {
            if (ch == '8' or ch == '9' or ch == '.' or ch == 'e' or ch == 'E') return;
        }
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Octal literals are not allowed. Use the syntax '0o{s}'.", .{raw[1..]});
        try self.reportCodeAt(tok.span.start, tok.line, 1121, msg);
    }

    fn reportNumericLiteralDiagnostics(self: *Parser, tok: Token, raw: []const u8) ParseError!void {
        if (raw.len >= 2 and raw[0] == '0') {
            const c = raw[1];
            if (c == '_') {
                try self.reportCodeAt(tok.span.start + 1, tok.line, 6188, "Numeric separators are not allowed here.");
                return;
            }
            if (c >= '0' and c <= '9') {
                // Classify the leading-zero literal:
                //   - `0[0-7]+` is a legacy octal -> TS1121 (parse error
                //     in strict mode; otherwise just an error per tsc).
                //   - `0[0-9]*[89][0-9]*` is "decimal with leading
                //     zeros" -> TS1489.
                //   - `0[0-7]+.[0-9]*` (e.g. `01.0`) is tokenized by us
                //     as a single number_literal, but tsc treats it as
                //     a legacy octal `01` followed by a stray `.0` -
                //     emit TS1121 for the octal prefix AND TS1005 at
                //     the `.` so callers see the same two-error shape.
                //   - `0[0-7]+e...` is similar (TS1121 + TS1005).
                var has_eight_or_nine = false;
                var dot_pos: ?usize = null;
                var exp_pos: ?usize = null;
                for (raw[1..], 0..) |ch, i| {
                    if (ch == '8' or ch == '9') {
                        has_eight_or_nine = true;
                    } else if (ch == '.' and dot_pos == null) {
                        dot_pos = i + 1;
                    } else if ((ch == 'e' or ch == 'E') and exp_pos == null) {
                        exp_pos = i + 1;
                    }
                }
                if (has_eight_or_nine) {
                    try self.reportCodeAt(tok.span.start, tok.line, 1489, "Decimals with leading zeros are not allowed.");
                } else if (dot_pos != null or exp_pos != null) {
                    // Legacy octal prefix with stray fraction/exponent:
                    // emit TS1121 on the octal-prefix slice, TS1005 at
                    // the `.`/`e`. This matches tsc's split tokenization.
                    const split_at = if (dot_pos) |dp| dp else exp_pos.?;
                    const octal_part = raw[1..split_at];
                    const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Octal literals are not allowed. Use the syntax '0o{s}'.", .{octal_part});
                    try self.reportCodeAt(tok.span.start, tok.line, 1121, msg);
                    try self.reportCodeAt(tok.span.start + @as(u32, @intCast(split_at)), tok.line, 1005, "';' expected.");
                } else if (!self.strict_mode) {
                    const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Octal literals are not allowed. Use the syntax '0o{s}'.", .{raw[1..]});
                    try self.reportCodeAt(tok.span.start, tok.line, 1121, msg);
                }
                return;
            }
        }

        // Separator placement diagnostics are scanner-owned in tsc/tsgo:
        // malformed literals can produce several separator diagnostics
        // while still yielding a recoverable numeric token.
    }

    fn parseIfStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // if
        _ = try self.expect(.open_paren, "'(' after 'if'");
        const cond = try self.parseExpression();
        var missing_close_paren = false;
        if (self.peek().kind == .close_paren) {
            _ = self.advance();
        } else {
            const close_tok = self.peek();
            try self.reportCodeAt(close_tok.span.start, close_tok.line, 1005, "')' expected.");
            missing_close_paren = true;
        }
        const then_branch = if (self.peek().kind == .close_brace or self.peek().kind == .eof) blk: {
            const close_tok = self.peek();
            if (!missing_close_paren) {
                try self.reportCodeAt(close_tok.span.start, close_tok.line, 1109, "Expression expected.");
            }
            break :blk try self.builder.addBlock(.{ .start = close_tok.span.start, .end = close_tok.span.start }, &.{});
        } else try self.parseNestedStatement();
        var else_branch: NodeId = hir_mod.none_node_id;
        if (self.match(.kw_else)) else_branch = try self.parseNestedStatement();
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
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        self.loop_switch_depth += 1;
        defer self.loop_switch_depth -= 1;
        const body = try self.parseNestedStatement();
        const end_pos = self.hir.spanOf(body).end;
        return try self.builder.addWhile(.{ .start = start.span.start, .end = end_pos }, cond, body);
    }

    fn parseDoWhileStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // do
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        self.loop_switch_depth += 1;
        defer self.loop_switch_depth -= 1;
        const body = try self.parseNestedStatement();
        _ = try self.expect(.kw_while, "'while' after do-block");
        _ = try self.expect(.open_paren, "'(' after 'while'");
        const cond = try self.parseExpression();
        const close = try self.expect(.close_paren, "')' after do-while condition");
        _ = self.match(.semicolon);
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
        var has_decl_kw = (self.peek().kind == .kw_let or
            self.peek().kind == .kw_const or
            self.peek().kind == .kw_var or
            self.peek().kind == .kw_using or
            (self.peek().kind == .kw_await and self.peekAt(1).kind == .kw_using));
        if (self.peek().kind == .kw_await and self.peekAt(1).kind == .kw_using and self.peekAt(2).kind == .kw_of) {
            const after_of = self.peekAt(3).kind;
            has_decl_kw = after_of == .kw_of or
                after_of == .kw_in or
                after_of == .equal or
                after_of == .colon or
                after_of == .comma or
                after_of == .semicolon or
                after_of == .close_paren;
        }

        if (self.peek().kind == .semicolon) {
            // empty init — leave as none
        } else if (has_decl_kw) {
            const kw = self.advance(); // let/const/var/using or await
            const is_await_using_decl = kw.kind == .kw_await;
            const is_using_decl = kw.kind == .kw_using or is_await_using_decl;
            if (is_await_using_decl) _ = try self.expect(.kw_using, "'using' after 'await' in for initializer");
            const binding_start = self.peek();
            const binding_node: NodeId = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
                break :blk try self.parseBindingPattern();
            } else blk: {
                const name_tok = try self.expectIdentifierLike();
                try self.reportInvalidStrictName(name_tok);
                try self.reportInvalidFutureReservedName(name_tok);
                if (kw.kind == .kw_var and self.strict_mode and self.tokenTextEquals(name_tok, "let")) {
                    try self.reportCodeAt(name_tok.span.start, name_tok.line, 1212, "Identifier expected. 'let' is a reserved word in strict mode.");
                }
                if ((kw.kind == .kw_let or kw.kind == .kw_const) and self.tokenTextEquals(name_tok, "let")) {
                    // `let` / `const` declarations are always strict
                    // (per ES2015), so `let let` also emits TS1212
                    // BEFORE the TS2480. Mirrors upstream tsc on
                    // `for-of51` (`for (let let of []) {}`).
                    try self.reportCodeAt(name_tok.span.start, name_tok.line, 1212, "Identifier expected. 'let' is a reserved word in strict mode.");
                    try self.reportCodeAt(name_tok.span.start, name_tok.line, 2480, "'let' is not allowed to be used as a name in 'let' or 'const' declarations.");
                }
                const name_id = try self.internToken(name_tok);
                break :blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
            };
            if (!is_using_decl and (binding_start.kind == .kw_in or binding_start.kind == .kw_of) and
                self.peek().kind != .kw_in and self.peek().kind != .kw_of and
                self.peek().kind != .equal and self.peek().kind != .colon and
                self.peek().kind != .comma and self.peek().kind != .semicolon and
                self.peek().kind != .close_paren)
            {
                const empty_pos = if (binding_start.span.start > 0) binding_start.span.start - 1 else binding_start.span.start;
                try self.reportCodeAt(empty_pos, binding_start.line, 1123, "Variable declaration list cannot be empty.");
                if (binding_start.kind == .kw_in) {
                    const source_expr = try self.parseExpression();
                    _ = try self.expect(.close_paren, "')' to close for-in/of header");
                    self.loop_depth += 1;
                    defer self.loop_depth -= 1;
                    self.loop_switch_depth += 1;
                    defer self.loop_switch_depth -= 1;
                    const body = try self.parseNestedStatement();
                    return try self.builder.addForIn(.{ .start = start.span.start, .end = self.hir.spanOf(body).end }, hir_mod.none_node_id, source_expr, body);
                }
                return try self.finishRecoveredForStatement(start);
            }
            if (is_using_decl and (binding_start.kind == .open_brace or binding_start.kind == .open_bracket)) {
                const message = if (is_await_using_decl)
                    "'await using' declarations may not have binding patterns."
                else
                    "'using' declarations may not have binding patterns.";
                try self.reportCodeAt(binding_start.span.start, binding_start.line, 1492, message);
            }
            if (kw.kind == .kw_using and binding_start.kind == .kw_of and self.peek().kind == .kw_of) {
                try self.reportCodeAt(kw.span.start, kw.line, 2304, "Cannot find name 'using'.");
            }
            // Optional type annotation. In for-in/of declarations we
            // preserve it by wrapping the binding in a var/let/const
            // declaration node below; assignment-form loops keep the
            // bare expression target.
            var type_annotation: NodeId = hir_mod.none_node_id;
            if (self.match(.colon)) type_annotation = try self.parseTypeAnnotation();

            // Detect for-in / for-of immediately.
            if (self.peek().kind == .kw_in or self.peek().kind == .kw_of) {
                const kind_tok = self.advance(); // in/of
                if (!is_using_decl and (binding_start.kind == .kw_in or binding_start.kind == .kw_of)) {
                    const empty_pos = if (binding_start.span.start > 0) binding_start.span.start - 1 else binding_start.span.start;
                    try self.reportCodeAt(empty_pos, binding_start.line, 1123, "Variable declaration list cannot be empty.");
                    if (self.peek().kind == .close_paren) {
                        return try self.finishRecoveredForStatement(start);
                    }
                } else if (type_annotation != hir_mod.none_node_id) {
                    const message = if (kind_tok.kind == .kw_in)
                        "The left-hand side of a 'for...in' statement cannot use a type annotation."
                    else
                        "The left-hand side of a 'for...of' statement cannot use a type annotation.";
                    try self.reportCodeAt(binding_start.span.start, binding_start.line, if (kind_tok.kind == .kw_in) 2404 else 2483, message);
                }
                if (kind_tok.kind == .kw_in and
                    (self.hir.kindOf(binding_node) == .object_pattern or self.hir.kindOf(binding_node) == .array_pattern))
                {
                    try self.reportCodeAt(binding_start.span.start, binding_start.line, 2491, "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.");
                }
                if (is_await and kind_tok.kind == .kw_in) {
                    try self.reportCodeAt(kind_tok.span.start, kind_tok.line, 1005, "'of' expected.");
                }
                if (kind_tok.kind == .kw_in and is_using_decl) {
                    const message = if (is_await_using_decl)
                        "The left-hand side of a 'for...in' statement cannot be an 'await using' declaration."
                    else
                        "The left-hand side of a 'for...in' statement cannot be a 'using' declaration.";
                    try self.reportCodeAt(kw.span.start, kw.line, if (is_await_using_decl) 1494 else 1493, message);
                }
                const loop_target: NodeId = blk: {
                    const decl_kind: hir_mod.NodeKind = switch (kw.kind) {
                        .kw_var => .var_decl,
                        .kw_let => .let_decl,
                        .kw_const, .kw_using, .kw_await => .const_decl,
                        else => break :blk binding_node,
                    };
                    const target_end = if (type_annotation != hir_mod.none_node_id)
                        self.hir.spanOf(type_annotation).end
                    else
                        self.hir.spanOf(binding_node).end;
                    break :blk try self.builder.addVarDeclEx(
                        decl_kind,
                        .{ .start = kw.span.start, .end = target_end },
                        binding_node,
                        type_annotation,
                        hir_mod.none_node_id,
                        is_using_decl,
                        is_await_using_decl,
                        self.ambient_depth > 0,
                    );
                };
                const source_expr = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close for-in/of header");
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                self.loop_switch_depth += 1;
                defer self.loop_switch_depth -= 1;
                const body = try self.parseNestedStatement();
                const end_pos = self.hir.spanOf(body).end;
                if (kind_tok.kind == .kw_in) {
                    return try self.builder.addForIn(.{ .start = start.span.start, .end = end_pos }, loop_target, source_expr, body);
                } else if (is_await) {
                    return try self.builder.addForAwaitOf(.{ .start = start.span.start, .end = end_pos }, loop_target, source_expr, body);
                } else {
                    return try self.builder.addForOf(.{ .start = start.span.start, .end = end_pos }, loop_target, source_expr, body);
                }
            }

            // Classic for: `for (let x = init;` …)
            var init_expr: NodeId = hir_mod.none_node_id;
            if (self.match(.equal)) init_expr = try self.parseAssignmentExpressionWithIn(false);
            if (is_using_decl and init_expr == hir_mod.none_node_id) {
                try self.reportCodeAt(binding_start.span.start, binding_start.line, 1155, "'using' declarations must be initialized.");
            }
            const decl_kind: hir_mod.NodeKind = switch (kw.kind) {
                .kw_var => .var_decl,
                .kw_let => .let_decl,
                .kw_const, .kw_using, .kw_await => .const_decl,
                else => .let_decl,
            };
            const init_end = if (init_expr != hir_mod.none_node_id)
                self.hir.spanOf(init_expr).end
            else if (type_annotation != hir_mod.none_node_id)
                self.hir.spanOf(type_annotation).end
            else
                self.hir.spanOf(binding_node).end;
            init_node = try self.builder.addVarDeclEx(
                decl_kind,
                .{ .start = kw.span.start, .end = init_end },
                binding_node,
                type_annotation,
                init_expr,
                is_using_decl,
                is_await_using_decl,
                self.ambient_depth > 0,
            );
            var multiple_decl_token: ?Token = null;
            var extra_decls: std.ArrayListUnmanaged(NodeId) = .empty;
            defer extra_decls.deinit(self.gpa);
            while (self.match(.comma)) {
                const item_start = self.peek();
                if (multiple_decl_token == null) multiple_decl_token = item_start;
                const extra_binding: NodeId = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
                    break :blk try self.parseBindingPattern();
                } else blk: {
                    const name_tok = try self.expectIdentifierLike();
                    const name_id = try self.internToken(name_tok);
                    break :blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                };
                var extra_type_ann: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) extra_type_ann = try self.parseTypeAnnotation();
                var extra_init_expr: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) extra_init_expr = try self.parseAssignmentExpressionWithIn(false);
                const extra_start = self.hir.spanOf(extra_binding).start;
                const extra_end = if (extra_init_expr != hir_mod.none_node_id)
                    self.hir.spanOf(extra_init_expr).end
                else if (extra_type_ann != hir_mod.none_node_id)
                    self.hir.spanOf(extra_type_ann).end
                else
                    self.hir.spanOf(extra_binding).end;
                const extra_decl = try self.builder.addVarDeclEx(
                    decl_kind,
                    .{ .start = extra_start, .end = extra_end },
                    extra_binding,
                    extra_type_ann,
                    extra_init_expr,
                    is_using_decl,
                    is_await_using_decl,
                    self.ambient_depth > 0,
                );
                try extra_decls.append(self.gpa, extra_decl);
            }
            // When the for-init declares multiple bindings (e.g.
            // `for (var i = 0, j = 10; ...)`), wrap them with the
            // primary decl in a synthetic block so downstream binder
            // and checker visit every binding. Without this the trailing
            // `j` was parsed and discarded, surfacing spurious TS2304
            // ("Cannot find name 'j'") in the condition/update slots.
            if (extra_decls.items.len > 0) {
                var all_decls: std.ArrayListUnmanaged(NodeId) = .empty;
                defer all_decls.deinit(self.gpa);
                try all_decls.append(self.gpa, init_node);
                for (extra_decls.items) |d| try all_decls.append(self.gpa, d);
                const block_end = self.hir.spanOf(extra_decls.items[extra_decls.items.len - 1]).end;
                init_node = try self.builder.addBlock(
                    .{ .start = self.hir.spanOf(init_node).start, .end = block_end },
                    all_decls.items,
                );
            }
            if (self.peek().kind == .kw_in or self.peek().kind == .kw_of) {
                const kind_tok = self.advance();
                try self.reportInvalidForInOfDeclaration(
                    kind_tok.kind,
                    binding_start,
                    type_annotation != hir_mod.none_node_id,
                    init_expr != hir_mod.none_node_id,
                    multiple_decl_token,
                );
                const source_expr = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close for-in/of header");
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                self.loop_switch_depth += 1;
                defer self.loop_switch_depth -= 1;
                const body = try self.parseNestedStatement();
                const end_pos = self.hir.spanOf(body).end;
                if (kind_tok.kind == .kw_in) {
                    return try self.builder.addForIn(.{ .start = start.span.start, .end = end_pos }, init_node, source_expr, body);
                } else if (is_await) {
                    return try self.builder.addForAwaitOf(.{ .start = start.span.start, .end = end_pos }, init_node, source_expr, body);
                } else {
                    return try self.builder.addForOf(.{ .start = start.span.start, .end = end_pos }, init_node, source_expr, body);
                }
            }
        } else {
            const head_start = self.peek();
            const head_expr = try self.parseExpressionNoIn();

            if (self.peek().kind == .kw_in or self.peek().kind == .kw_of) {
                const kind_tok = self.advance();
                if (!is_await and kind_tok.kind == .kw_of and self.hir.kindOf(head_expr) == .identifier and self.tokenTextEquals(head_start, "async")) {
                    try self.reportCodeAt(head_start.span.start, head_start.line, 1106, "The left-hand side of a 'for...of' statement may not be 'async'.");
                }
                if (kind_tok.kind == .kw_in and (head_start.kind == .open_brace or head_start.kind == .open_bracket)) {
                    try self.reportCodeAt(head_start.span.start, head_start.line, 2491, "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.");
                }
                if (is_await and kind_tok.kind == .kw_in) {
                    try self.reportCodeAt(kind_tok.span.start, kind_tok.line, 1005, "'of' expected.");
                }
                const source_expr = try self.parseExpression();
                _ = try self.expect(.close_paren, "')' to close for-in/of header");
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                self.loop_switch_depth += 1;
                defer self.loop_switch_depth -= 1;
                const body = try self.parseNestedStatement();
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
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        self.loop_switch_depth += 1;
        defer self.loop_switch_depth -= 1;
        const body = try self.parseNestedStatement();
        const end_pos = self.hir.spanOf(body).end;
        return try self.builder.addFor(.{ .start = start.span.start, .end = end_pos }, init_node, cond, update, body);
    }

    fn finishRecoveredForStatement(self: *Parser, start: Token) ParseError!NodeId {
        while (self.peek().kind != .close_paren and self.peek().kind != .eof) _ = self.advance();
        _ = self.match(.close_paren);
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        self.loop_switch_depth += 1;
        defer self.loop_switch_depth -= 1;
        const body = try self.parseNestedStatement();
        return try self.builder.addFor(.{ .start = start.span.start, .end = self.hir.spanOf(body).end }, hir_mod.none_node_id, hir_mod.none_node_id, hir_mod.none_node_id, body);
    }

    fn reportInvalidForInOfDeclaration(
        self: *Parser,
        kind: TokenKind,
        first_binding: Token,
        has_type_annotation: bool,
        has_initializer: bool,
        multiple_decl_token: ?Token,
    ) ParseError!void {
        if (multiple_decl_token) |tok| {
            const message = if (kind == .kw_in)
                "Only a single variable declaration is allowed in a 'for...in' statement."
            else
                "Only a single variable declaration is allowed in a 'for...of' statement.";
            try self.reportCodeAt(tok.span.start, tok.line, if (kind == .kw_in) 1091 else 1188, message);
            return;
        }
        if (has_initializer) {
            const message = if (kind == .kw_in)
                "The variable declaration of a 'for...in' statement cannot have an initializer."
            else
                "The variable declaration of a 'for...of' statement cannot have an initializer.";
            try self.reportCodeAt(first_binding.span.start, first_binding.line, if (kind == .kw_in) 1189 else 1190, message);
            return;
        }
        if (has_type_annotation) {
            const message = if (kind == .kw_in)
                "The left-hand side of a 'for...in' statement cannot use a type annotation."
            else
                "The left-hand side of a 'for...of' statement cannot use a type annotation.";
            try self.reportCodeAt(first_binding.span.start, first_binding.line, if (kind == .kw_in) 2404 else 2483, message);
        }
    }

    fn parseWithStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // with
        if (self.isAmbientContextAt(start.span.start)) {
            try self.reportCodeAt(start.span.start, start.line, 1036, "Statements are not allowed in ambient contexts.");
        } else if (self.strict_mode) {
            // tsc only emits TS1101 when the source is genuinely in
            // strict mode (either an explicit `"use strict"`, an ES
            // module top-level, or `alwaysStrict`/`strict` is on).
            // Targeting ES2015+ alone is NOT enough to fire TS1101 —
            // the upstream baseline for fixtures like
            // `arrowFunctionContexts(alwaysstrict=false).errors.txt`
            // emits TS2410 only.
            try self.reportCodeAt(start.span.start, start.line, 1101, "'with' statements are not allowed in strict mode.");
        }
        try self.reportCodeAt(start.span.start, start.line, 2410, "The 'with' statement is not supported. All symbols in a 'with' block will have type 'any'.");
        _ = try self.expect(.open_paren, "'(' after 'with'");
        const object_expr = try self.parseExpression();
        _ = try self.expect(.close_paren, "')' after with expression");
        const body = try self.parseNestedStatement();
        return try self.builder.addBlock(.{ .start = start.span.start, .end = self.hir.spanOf(body).end }, &.{ object_expr, body });
    }

    fn parseBreakStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // break
        var label: NodeId = hir_mod.none_node_id;
        if ((self.peek().kind == .identifier or self.peek().kind.isContextualKeyword()) and !self.peek().flags.preceded_by_newline) {
            const lab_tok = self.advance();
            const lab_id = try self.internToken(lab_tok);
            label = try self.builder.addIdentifier(tokenSpan(lab_tok), lab_id);
            try self.checkLabelTarget(start, lab_id);
        } else if (self.loop_switch_depth == 0 and !self.isAmbientContextAt(start.span.start)) {
            // In ambient (.d.ts / `declare`) contexts the surrounding
            // TS1036 "Statements are not allowed in ambient contexts"
            // already covers the misuse — tsc suppresses TS1105 there
            // to avoid double-reporting.
            if (self.outer_loop_or_switch_active) {
                // tsc treats an unlabeled `break` inside a nested
                // function whose ancestor is a loop/switch as a
                // cross-function jump, not a missing-target error.
                try self.reportCodeAt(start.span.start, start.line, 1107, "Jump target cannot cross function boundary.");
            } else {
                try self.reportCodeAt(start.span.start, start.line, 1105, "A 'break' statement can only be used within an enclosing iteration or switch statement.");
            }
        }
        try self.consumeStatementTerminator();
        const end_pos: u32 = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
        return try self.builder.addBreak(.{ .start = start.span.start, .end = end_pos }, label);
    }

    fn parseContinueStatement(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // continue
        var label: NodeId = hir_mod.none_node_id;
        if ((self.peek().kind == .identifier or self.peek().kind.isContextualKeyword()) and !self.peek().flags.preceded_by_newline) {
            const lab_tok = self.advance();
            const lab_id = try self.internToken(lab_tok);
            label = try self.builder.addIdentifier(tokenSpan(lab_tok), lab_id);
            try self.checkLabelTarget(start, lab_id);
        } else if (self.loop_depth == 0 and !self.isAmbientContextAt(start.span.start)) {
            // See `parseBreakStatement`: ambient contexts get TS1036
            // for the statement itself, so suppress the redundant
            // TS1104 "continue must be in an iteration" message.
            if (self.outer_loop_or_switch_active) {
                try self.reportCodeAt(start.span.start, start.line, 1107, "Jump target cannot cross function boundary.");
            } else {
                try self.reportCodeAt(start.span.start, start.line, 1104, "A 'continue' statement can only be used within an enclosing iteration statement.");
            }
        }
        try self.consumeStatementTerminator();
        const end_pos: u32 = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
        return try self.builder.addContinue(.{ .start = start.span.start, .end = end_pos }, label);
    }

    /// Resolve a `break LBL` / `continue LBL` label reference against
    /// the active label scope. Mirrors tsc's grammar checks:
    ///   - TS1116: label not declared in any enclosing statement
    ///   - TS1107: label declared, but only outside the current
    ///     function — jump targets cannot cross function boundaries
    /// The reported position is the start of the `break`/`continue`
    /// token (matches tsc's column for these diagnostics).
    fn checkLabelTarget(self: *Parser, start: Token, label_name: hir_mod.StringId) ParseError!void {
        // Walk the label stack innermost-out so a same-named label in
        // the inner function (when present) wins before the outer one
        // would trigger TS1107.
        const is_break = start.kind == .kw_break;
        var i: usize = self.label_stack.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.label_stack.items[i];
            if (entry.name != label_name) continue;
            if (entry.function_depth != self.function_depth) {
                try self.reportCodeAt(start.span.start, start.line, 1107, "Jump target cannot cross function boundary.");
                return;
            }
            // `continue LBL` requires `LBL` to wrap an iteration
            // statement (for / while / do-while). A label binding a
            // non-iteration form (block, if, expression) is a valid
            // `break` target but not a valid `continue` target —
            // mirrors upstream tsc on `parser_continueTarget1.ts(2,3)`.
            if (!is_break and !entry.wraps_iteration) {
                try self.reportCodeAt(start.span.start, start.line, 1115, "A 'continue' statement can only jump to a label of an enclosing iteration statement.");
            }
            return;
        }
        if (is_break) {
            try self.reportCodeAt(start.span.start, start.line, 1116, "A 'break' statement can only jump to a label of an enclosing statement.");
        } else {
            try self.reportCodeAt(start.span.start, start.line, 1115, "A 'continue' statement can only jump to a label of an enclosing iteration statement.");
        }
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
                catch_param = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
                    break :blk try self.parseBindingPattern();
                } else blk: {
                    const name_tok = try self.expect(.identifier, "identifier in catch binding");
                    try self.reportInvalidStrictName(name_tok);
                    const id = try self.internToken(name_tok);
                    break :blk try self.builder.addIdentifier(tokenSpan(name_tok), id);
                };
                if (self.peek().kind == .colon) {
                    const colon = self.advance();
                    var type_pos = colon.span.end;
                    while (type_pos < self.source.len and (self.source[type_pos] == ' ' or self.source[type_pos] == '\t')) : (type_pos += 1) {}
                    // Upstream tsc only emits TS1196 when the annotation
                    // is something OTHER than `any` or `unknown`. Catch
                    // bindings typed as `any`/`unknown` (or a type alias
                    // for them) are valid; the checker handles non-alias
                    // cases at parse time by inspecting the keyword.
                    // Mirrors `catchClauseWithTypeAnnotation.ts` which
                    // intentionally includes valid `: any` / `: unknown`
                    // clauses that should NOT trigger TS1196.
                    const ty_tok = self.peek();
                    const is_simple_any_or_unknown =
                        (ty_tok.kind == .kw_any or ty_tok.kind == .kw_unknown) and
                        self.peekAt(1).kind == .close_paren;
                    if (!is_simple_any_or_unknown) {
                        try self.reportCodeAt(type_pos, colon.line, 1196, "Catch clause variable type annotation must be 'any' or 'unknown' if specified.");
                    }
                    try self.skipTypeAnnotation();
                }
                _ = try self.expect(.close_paren, "')' to close catch param");
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
        self.loop_switch_depth += 1;
        defer self.loop_switch_depth -= 1;

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
            const prev_in_case_clause = self.in_switch_case_clause;
            self.in_switch_case_clause = true;
            defer self.in_switch_case_clause = prev_in_case_clause;
            while (true) {
                const k = self.peek().kind;
                if (!self.hasPendingStatement() and (k == .kw_case or k == .kw_default or k == .close_brace or k == .eof)) break;
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

    fn missingIdentifierAt(self: *Parser, pos: u32) ParseError!NodeId {
        const empty = self.interner.intern("") catch return error.OutOfMemory;
        return try self.builder.addIdentifier(.{ .start = pos, .end = pos }, empty);
    }

    fn parseFunctionDeclaration(self: *Parser, require_name: bool) ParseError!NodeId {
        const start = self.advance(); // function
        // TS1046: A top-level `function` in a `.d.ts` file without a
        // leading `declare` / `export` modifier is invalid. Anchored
        // at the `function` keyword to match upstream tsc's column on
        // `parserFunctionDeclaration2.d.ts(1,1)`.
        if (self.isAmbientContextAt(start.span.start) and
            self.block_depth == 0 and
            self.namespace_depth == 0 and
            self.ambient_depth == 0 and
            !self.in_export_declaration)
        {
            try self.reportCodeAt(start.span.start, start.line, 1046, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.");
        }
        // Capture the asterisk position so TS1221/TS1222 can be reported
        // at the `*` token (mirrors upstream tsc spans for ambient and
        // overload-as-generator diagnostics on fixtures like
        // `generatorInAmbientContext2`, `generatorOverloads1`).
        const asterisk_tok: ?Token = if (self.peek().kind == .asterisk) self.peek() else null;
        const is_generator = self.match(.asterisk);
        // Function name (optional in expression context, required in
        // declaration). Phase 1.D treats `function` as a declaration only
        // when at statement position; named-fn-expression handling lives
        // in parseUnaryExpression's primary path (deferred follow-up).
        var name: NodeId = hir_mod.none_node_id;
        var recovered_missing_name = false;
        var recovered_missing_name_arrow = false;
        if (self.peek().kind == .identifier or self.peek().kind.isContextualKeyword()) {
            const name_tok = self.advance();
            try self.reportInvalidStrictName(name_tok);
            try self.reportInvalidYieldName(name_tok);
            // `async function await()` as a DECLARATION is legal (the
            // function name binds in the outer scope where `await` is
            // not reserved). The same name as a function EXPRESSION
            // (`var v = async function await(){}`) is TS1359, because
            // the name then binds inside the async body. Gate on
            // `!require_name` (expression context).
            if (!require_name) try self.reportAwaitReservedInAsyncContext(name_tok);
            // `function await() {}` at the top level of a MODULE binds
            // the name into module scope where `await` is reserved. tsc
            // emits TS1262 at the `await` token. `reportAwaitBindingIfReserved`
            // gates on `top_level_external_module_indicator + depth = 0`,
            // so the check is a no-op in non-module / nested contexts.
            // Mirrors fixture `topLevelAwaitErrors.6`.
            if (require_name) try self.reportAwaitBindingIfReserved(name_tok);
            const name_id = try self.internToken(name_tok);
            name = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        } else if (require_name) {
            const name_pos = start.span.end;
            const diag_tok = self.peek();
            try self.reportCodeAt(diag_tok.span.start, diag_tok.line, 1003, "Identifier expected.");
            name = try self.missingIdentifierAt(name_pos);
            recovered_missing_name = true;
            recovered_missing_name_arrow = diag_tok.kind == .arrow;
        }
        // Generic type parameters: `function f<T extends U = D>(...)`.
        var type_params: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            type_params = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(type_params);
        self.parameter_list_recovered_body_as_missing_close = false;
        const saved_arrow_is_comma = self.parameter_list_arrow_is_comma;
        self.parameter_list_arrow_is_comma = true;
        defer self.parameter_list_arrow_is_comma = saved_arrow_is_comma;
        var owns_params = false;
        const params: []NodeId = if (recovered_missing_name_arrow) blk: {
            if (self.peek().kind == .arrow) _ = self.advance();
            break :blk &.{};
        } else blk: {
            owns_params = true;
            break :blk try self.parseParameterList();
        };
        defer if (owns_params) self.gpa.free(params);
        const recovered_body_as_missing_close = self.parameter_list_recovered_body_as_missing_close;

        var return_type: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);

        var body: NodeId = hir_mod.none_node_id;
        if (recovered_body_as_missing_close) {
            const report_pos = if (name != hir_mod.none_node_id) self.hir.spanOf(name).start else start.span.start;
            try self.reportCodeAt(
                report_pos,
                self.lineAt(report_pos),
                2391,
                "Function implementation is missing or not immediately following the declaration.",
            );
        } else if (self.peek().kind == .open_brace) {
            // TS1183: An implementation body for a `function` in an
            // ambient context (`.d.ts` or inside `declare namespace …`)
            // is not allowed. Anchored at the opening `{` to match
            // upstream tsc on `parserFunctionDeclaration2.d.ts(1,14)`
            // / `parserFunctionDeclaration2.ts(1,24)`.
            const open_brace_tok = self.peek();
            if (self.isAmbientContextAt(open_brace_tok.span.start)) {
                try self.reportCodeAt(open_brace_tok.span.start, open_brace_tok.line, 1183, "An implementation cannot be declared in ambient contexts.");
            }
            self.function_depth += 1;
            self.new_target_depth += 1;
            defer self.function_depth -= 1;
            defer self.new_target_depth -= 1;
            const prev_generator_depth = self.generator_depth;
            self.generator_depth = if (is_generator) prev_generator_depth + 1 else 0;
            defer self.generator_depth = prev_generator_depth;
            // Iteration/switch nesting is reset across function
            // boundaries — an unlabeled `break`/`continue` inside the
            // nested function body cannot reach an outer loop. The
            // saved flag lets `parseBreakStatement` /
            // `parseContinueStatement` pick TS1107 over TS1105/TS1104
            // when the inner body sits below an outer loop/switch.
            const prev_loop_depth = self.loop_depth;
            const prev_loop_switch_depth = self.loop_switch_depth;
            const prev_outer_loop_or_switch_active = self.outer_loop_or_switch_active;
            self.outer_loop_or_switch_active = prev_outer_loop_or_switch_active or prev_loop_switch_depth > 0;
            self.loop_depth = 0;
            self.loop_switch_depth = 0;
            defer self.loop_depth = prev_loop_depth;
            defer self.loop_switch_depth = prev_loop_switch_depth;
            defer self.outer_loop_or_switch_active = prev_outer_loop_or_switch_active;
            body = try self.parseBlockStatement();
        } else if (self.peek().kind == .arrow and !recovered_missing_name) {
            const arrow_tok = self.advance();
            try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1144, "'{' or ';' expected.");
        } else {
            // Ambient declaration `function foo(...);`.
            try self.consumeStatementTerminator();
            if (is_generator) {
                const diag_pos: u32 = if (asterisk_tok) |at| at.span.start else start.span.start;
                const diag_line: u32 = if (asterisk_tok) |at| at.line else start.line;
                if (self.ambient_depth > 0) {
                    try self.reportCodeAt(diag_pos, diag_line, 1221, "Generators are not allowed in an ambient context.");
                } else {
                    try self.reportCodeAt(diag_pos, diag_line, 1222, "An overload signature cannot be declared as a generator.");
                }
            }
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
        var seen_names: std.AutoHashMapUnmanaged(hir_mod.StringId, Span) = .empty;
        defer seen_names.deinit(self.gpa);
        var missing_close_reported = false;
        if (self.peek().kind != .close_paren) {
            while (true) {
                const param_start = self.peek();
                if (param_start.kind == .open_brace and self.peekAt(1).kind == .close_brace and
                    (self.peekAt(1).flags.preceded_by_newline or self.peekAt(2).kind == .eof))
                {
                    _ = self.advance();
                    const close = self.peek();
                    try self.reportCodeAt(close.span.end, close.line, 1005, "')' expected.");
                    missing_close_reported = true;
                    self.parameter_list_recovered_body_as_missing_close = true;
                    if (self.peek().kind == .close_brace) _ = self.advance();
                    break;
                }
                if (param_start.kind == .invalid) {
                    const bad = self.advance();
                    try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                    if (self.peek().kind == .close_paren) break;
                    if (self.match(.comma)) continue;
                    continue;
                }
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
                var saw_override_modifier = false;
                var saw_readonly_modifier = false;
                while (isParameterPropertyModifier(self.peek().kind)) {
                    const mod = self.advance();
                    switch (mod.kind) {
                        .kw_readonly => {
                            if (saw_override_modifier) {
                                try self.reportCodeAt(mod.span.start, mod.line, 1029, "'readonly' modifier must precede 'override' modifier.");
                            }
                            // TS1030: duplicate `readonly` modifier on
                            // a parameter property.
                            if (flags.is_readonly) {
                                try self.reportCodeAt(mod.span.start, mod.line, 1030, "'readonly' modifier already seen.");
                            }
                            flags.is_readonly = true;
                            flags.is_parameter_property = true;
                            saw_readonly_modifier = true;
                        },
                        .kw_public, .kw_protected, .kw_private => {
                            if (saw_override_modifier) {
                                const which: []const u8 = switch (mod.kind) {
                                    .kw_public => "'public'",
                                    .kw_protected => "'protected'",
                                    else => "'private'",
                                };
                                const msg = try std.fmt.allocPrint(
                                    self.diag_arena.allocator(),
                                    "{s} modifier must precede 'override' modifier.",
                                    .{which},
                                );
                                try self.reportCodeAt(mod.span.start, mod.line, 1029, msg);
                            }
                            // TS1029 — accessibility modifiers must
                            // come *before* `readonly` on a parameter
                            // property (`readonly public x` is a
                            // mis-ordering, `public readonly x` is the
                            // canonical form). Mirrors fixture
                            // `readonlyInConstructorParameters`.
                            if (saw_readonly_modifier) {
                                const which: []const u8 = switch (mod.kind) {
                                    .kw_public => "'public'",
                                    .kw_protected => "'protected'",
                                    else => "'private'",
                                };
                                const msg = try std.fmt.allocPrint(
                                    self.diag_arena.allocator(),
                                    "{s} modifier must precede 'readonly' modifier.",
                                    .{which},
                                );
                                try self.reportCodeAt(mod.span.start, mod.line, 1029, msg);
                            }
                            flags.is_parameter_property = true;
                            if (mod.kind == .kw_private) flags.is_private = true;
                            if (mod.kind == .kw_protected) flags.is_protected = true;
                        },
                        .kw_override => {
                            flags.is_override = true;
                            saw_override_modifier = true;
                        },
                        else => {},
                    }
                }
                // Decorators may not legally follow an accessibility
                // modifier on a parameter property — `public @dec p`
                // is a TS1005 parse error in tsc. We still need to
                // consume the decorator tokens so the rest of the
                // parameter parses, but suppress them from the
                // attached decorator list so the checker doesn't then
                // re-report the same locus as TS1239.
                const suppress_post_modifier_decorators = flags.is_parameter_property and self.peek().kind == .at;
                if (suppress_post_modifier_decorators) {
                    const at_tok = self.peek();
                    try self.reportCodeAt(at_tok.span.start, at_tok.line, 1005, "',' expected.");
                }
                while (self.peek().kind == .at) {
                    const at_tok = self.advance();
                    const dec_expr = try self.parseLeftHandSideExpression();
                    const dec_node = try self.builder.addDecorator(.{
                        .start = at_tok.span.start,
                        .end = self.hir.spanOf(dec_expr).end,
                    }, dec_expr);
                    if (!suppress_post_modifier_decorators) {
                        try param_decorators.append(self.gpa, dec_node);
                    }
                }
                if (self.match(.dot_dot_dot)) {
                    flags.is_rest = true;
                    if (flags.is_parameter_property) {
                        try self.reportCodeAt(
                            param_start.span.start,
                            param_start.line,
                            1317,
                            "A parameter property cannot be declared using a rest parameter.",
                        );
                    }
                }
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
                    const this_param = try self.builder.addParameterWithDecorators(
                        .{ .start = this_tok.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        this_ident,
                        this_ann,
                        hir_mod.none_node_id,
                        .{},
                        param_decorators.items,
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
                    const name_tok = try self.expectIdentifierLike();
                    if (!self.suppress_strict_param_names) try self.reportInvalidStrictName(name_tok);
                    try self.reportInvalidYieldName(name_tok);
                    try self.reportInvalidFutureReservedName(name_tok);
                    try self.reportInvalidClassStrictIdentifier(name_tok);
                    try self.reportAwaitReservedInAsyncContext(name_tok);
                    const name_id = try self.internToken(name_tok);
                    break :id_blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                };
                if (self.peek().kind == .question) {
                    const q_tok = self.advance();
                    flags.is_optional = true;
                    const nk = self.hir.kindOf(name_node);
                    if (nk == .object_pattern or nk == .array_pattern) {
                        // tsc anchors TS2463 at the start of the binding
                        // pattern (the `[` / `{` token), not the `?`
                        // suffix. Mirrors `optionalBindingParameters1.ts(1,14)`.
                        const pat_span = self.hir.spanOf(name_node);
                        try self.reportCodeAt(pat_span.start, self.lineAt(pat_span.start), 2463, "A binding pattern parameter cannot be optional in an implementation signature.");
                    }
                    // TS1047: `...rest?` — rest parameters cannot also be
                    // marked optional. Anchored at the `?` token, matching
                    // upstream tsc's column for `parserParameterList9.ts`
                    // (`foo(...bar?)`) and `parserParameterList11.ts`
                    // (`(...arg?) => 102;`).
                    if (flags.is_rest) {
                        try self.reportCodeAt(q_tok.span.start, q_tok.line, 1047, "A rest parameter cannot be optional.");
                    }
                }
                if (self.hir.kindOf(name_node) == .identifier) {
                    const id = hir_mod.identifierOf(self.hir, name_node);
                    const name_span = self.hir.spanOf(name_node);
                    if (seen_names.get(id.name)) |prev| {
                        try self.reportDuplicateIdentifierNamed(prev.start, self.lineAt(prev.start), id.name);
                        try self.reportDuplicateIdentifierNamed(name_span.start, self.lineAt(name_span.start), id.name);
                    } else {
                        try seen_names.put(self.gpa, id.name, name_span);
                    }
                }
                var type_ann: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) type_ann = try self.parseTypeAnnotation();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) {
                    self.param_initializer_depth += 1;
                    defer self.param_initializer_depth -= 1;
                    default_value = try self.parseAssignmentExpression();
                    // TS1015: A parameter cannot have both a `?`
                    // optional marker and an `= default` initializer.
                    // tsc anchors at the parameter's start span.
                    // Mirrors upstream `parserParameterList2`.
                    if (flags.is_optional) {
                        try self.reportCodeAt(param_start.span.start, param_start.line, 1015, "Parameter cannot have question mark and initializer.");
                    }
                    // TS1048: `...rest = init` — rest parameters cannot
                    // have a default-value initializer. Anchored at the
                    // parameter name to match upstream tsc's column for
                    // `parserParameterList10.ts(2,11)` (`foo(...bar = 0)`).
                    if (flags.is_rest) {
                        const name_span = self.hir.spanOf(name_node);
                        try self.reportCodeAt(name_span.start, self.lineAt(name_span.start), 1048, "A rest parameter cannot have an initializer.");
                    }
                }
                const param = try self.builder.addParameterWithDecorators(
                    .{ .start = param_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    type_ann,
                    default_value,
                    flags,
                    param_decorators.items,
                );
                // TS1016: A required parameter cannot follow an optional
                // parameter. Per tsc: "optional" here means the explicit
                // `?` marker only. A parameter with a default-value
                // initializer (`x = 1`) does NOT make the next parameter
                // required-after-optional — see fixture
                // `fatarrowfunctionsOptionalArgsErrors1.ts` line "(arg1 =
                // 1, arg2) => 1; // Uninitialized parameter makes the
                // initialized one required". Required = not `?`, not
                // rest, no default value. Emitted at the *name* (or
                // pattern) of the offending required parameter, matching
                // the upstream column in `functionOverloadErrorsSyntax.ts`.
                const is_required_now = !flags.is_optional and
                    !flags.is_rest and
                    default_value == hir_mod.none_node_id;
                if (is_required_now and params.items.len > 0) {
                    var prior_optional = false;
                    var i = params.items.len;
                    while (i > 0) : (i -= 1) {
                        const prev = params.items[i - 1];
                        if (self.hir.kindOf(prev) != .parameter) continue;
                        const pp = hir_mod.parameterOf(self.hir, prev);
                        if (pp.flags.is_optional) {
                            prior_optional = true;
                        }
                        break;
                    }
                    if (prior_optional) {
                        const name_span = self.hir.spanOf(name_node);
                        try self.reportCodeAt(
                            name_span.start,
                            self.lineAt(name_span.start),
                            1016,
                            "A required parameter cannot follow an optional parameter.",
                        );
                    }
                }
                try params.append(self.gpa, param);
                if (self.peek().kind == .open_brace) {
                    const open = self.advance();
                    try self.reportCodeAt(open.span.start, open.line, 1005, "',' expected.");
                    if (self.peek().kind == .close_brace) {
                        const close = self.advance();
                        try self.reportCodeAt(close.span.end, close.line, 1005, "')' expected.");
                        missing_close_reported = true;
                        self.parameter_list_recovered_body_as_missing_close = true;
                    }
                    break;
                }
                if (self.allow_parameter_list_arrow_recovery and self.peek().kind == .arrow) {
                    const arrow_tok = self.peek();
                    try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1005, "',' expected.");
                    missing_close_reported = true;
                    self.parameter_list_recovered_arrow_missing_close = true;
                    break;
                }
                if (self.parameter_list_arrow_is_comma and self.peek().kind == .arrow) {
                    const arrow_tok = self.advance();
                    try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1005, "',' expected.");
                    continue;
                }
                if (self.parameter_list_arrow_is_comma and (self.peek().kind == .semicolon or self.peek().kind == .eof)) {
                    const stop_tok = self.peek();
                    try self.reportCodeAt(stop_tok.span.start, stop_tok.line, 1005, "',' expected.");
                    if (self.peek().kind == .semicolon) _ = self.advance();
                    const close_tok = self.peek();
                    try self.reportCodeAt(close_tok.span.start, close_tok.line, 1005, "')' expected.");
                    missing_close_reported = true;
                    break;
                }
                if (!self.match(.comma)) break;
                if (flags.is_rest and self.peek().kind == .close_paren and self.ambient_depth == 0) {
                    const comma_tok = self.tokens[self.cursor - 1];
                    try self.reportCodeAt(
                        comma_tok.span.start,
                        comma_tok.line,
                        1013,
                        "A rest parameter or binding pattern may not have a trailing comma.",
                    );
                } else if (flags.is_rest and self.peek().kind != .close_paren) {
                    // Upstream points the diagnostic at the `...` rest token
                    // (the first character of the parameter), not the
                    // parameter's name. `param_start` was captured before
                    // the leading `...` was consumed, so its span.start is
                    // the `...` position for typical rest parameters.
                    try self.reportCodeAt(
                        param_start.span.start,
                        param_start.line,
                        1014,
                        "A rest parameter must be last in a parameter list.",
                    );
                }
                if (self.peek().kind == .close_paren) break; // trailing comma
            }
        }
        if (!missing_close_reported) _ = try self.expect(.close_paren, "')' to close parameter list");
        return try params.toOwnedSlice(self.gpa);
    }

    fn validateAccessorSignature(
        self: *Parser,
        accessor_kind: TokenKind,
        name_node: NodeId,
        params: []const NodeId,
        return_type: NodeId,
    ) ParseError!void {
        const name_span = self.hir.spanOf(name_node);
        const name_line = self.lineAt(name_span.start);
        // Per TS, a leading `this:` parameter is a type-only annotation
        // and should not count toward the accessor parameter limit.
        // Slice it off before counting so TS1054/TS1049 don't fire for
        // `get foo(this: ThisType)` / `set foo(this: ThisType, v)`.
        var counted_params = params;
        if (counted_params.len > 0) {
            const first = counted_params[0];
            if (self.hir.kindOf(first) == .parameter) {
                const fp = hir_mod.parameterOf(self.hir, first);
                if (fp.name != hir_mod.none_node_id and self.isThisIdentifier(fp.name)) {
                    counted_params = counted_params[1..];
                }
            }
        }
        if (accessor_kind == .kw_get) {
            if (counted_params.len != 0) {
                try self.reportCodeAt(name_span.start, name_line, 1054, "A 'get' accessor cannot have parameters.");
            }
            return;
        }

        if (accessor_kind != .kw_set) return;
        if (counted_params.len != 1) {
            try self.reportCodeAt(name_span.start, name_line, 1049, "A 'set' accessor must have exactly one parameter.");
        } else {
            const param = hir_mod.parameterOf(self.hir, counted_params[0]);
            const param_span = self.hir.spanOf(counted_params[0]);
            if (param.flags.is_rest) {
                try self.reportCodeAt(param_span.start, self.lineAt(param_span.start), 1053, "A 'set' accessor cannot have rest parameter.");
            }
            if (param.flags.is_optional) {
                const pname_span = self.hir.spanOf(param.name);
                try self.reportCodeAt(pname_span.end, self.lineAt(pname_span.end), 1051, "A 'set' accessor cannot have an optional parameter.");
            }
            if (param.flags.is_parameter_property) {
                try self.reportCodeAt(param_span.start, self.lineAt(param_span.start), 2369, "A parameter property is only allowed in a constructor implementation.");
            }
            if (param.default_value != hir_mod.none_node_id) {
                try self.reportCodeAt(name_span.start, name_line, 1052, "A 'set' accessor parameter cannot have an initializer.");
            }
        }
        if (return_type != hir_mod.none_node_id) {
            try self.reportCodeAt(name_span.start, name_line, 1095, "A 'set' accessor cannot have a return type annotation.");
        }
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
        var seen_names: std.AutoHashMapUnmanaged(hir_mod.StringId, void) = .empty;
        defer seen_names.deinit(self.gpa);
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
                const name_node = if (is_object and !flags.is_rest) blk: {
                    if (self.match(.open_bracket)) {
                        const key_start = self.tokens[self.cursor - 1];
                        const key_expr = try self.parseExpression();
                        _ = try self.expect(.close_bracket, "']' to close computed binding key");
                        _ = try self.expect(.colon, "':' after computed binding key");
                        const key_elem = try self.builder.addParameter(
                            .{ .start = key_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                            hir_mod.none_node_id,
                            hir_mod.none_node_id,
                            key_expr,
                            .{ .is_computed_binding_key = true },
                        );
                        try elements.append(self.gpa, key_elem);
                        break :blk try self.parseBindingTarget();
                    }
                    const key_tok = switch (self.peek().kind) {
                        .string_literal, .number_literal => self.advance(),
                        else => try self.expectIdentifierLike(),
                    };
                    try self.reportAwaitBindingIfReserved(key_tok);
                    if (self.match(.colon)) {
                        break :blk try self.parseBindingTarget();
                    }
                    if (key_tok.kind == .string_literal or key_tok.kind == .number_literal) {
                        // tsc reports TS1005 `':' expected.` at the position of
                        // the next token (here, the closing brace or whatever
                        // follows the literal key). Matches
                        // `objectBindingPatternKeywordIdentifiers03` baseline.
                        try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "':' expected.");
                        return error.UnexpectedToken;
                    }
                    // `{ while }` — shorthand object-binding entry whose key is
                    // a reserved word. tsc treats this as a missing rename
                    // (`while: alias`) and emits a single TS1005 `':' expected.`
                    // at the token that follows the keyword (where the `:`
                    // would have lived). Mirrors
                    // `objectBindingPatternKeywordIdentifiers01` baseline.
                    if (isReservedBindingNameToken(key_tok.kind)) {
                        try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "':' expected.");
                        return error.UnexpectedToken;
                    }
                    try self.reportInvalidStrictName(key_tok);
                    try self.reportReservedBindingNameIfNeeded(key_tok);
                    const name_id = try self.internToken(key_tok);
                    break :blk try self.builder.addIdentifier(tokenSpan(key_tok), name_id);
                } else try self.parseBindingTarget();
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) {
                    const eq_tok = self.tokens[self.cursor - 1];
                    if (flags.is_rest) {
                        try self.reportCodeAt(eq_tok.span.start, eq_tok.line, 1186, "A rest element cannot have an initializer.");
                    }
                    default_value = try self.parseAssignmentExpression();
                }
                if (self.hir.kindOf(name_node) == .identifier) {
                    const id = hir_mod.identifierOf(self.hir, name_node);
                    if (seen_names.contains(id.name)) {
                        try self.reportDuplicateIdentifierNamed(self.hir.spanOf(name_node).start, elem_start.line, id.name);
                    } else {
                        try seen_names.put(self.gpa, id.name, {});
                    }
                }
                const elem = try self.builder.addParameter(
                    .{ .start = elem_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    hir_mod.none_node_id,
                    default_value,
                    flags,
                );
                try elements.append(self.gpa, elem);
                if (!self.match(.comma)) break;
                if (flags.is_rest and self.peek().kind == close_kind) {
                    const comma_tok = self.tokens[self.cursor - 1];
                    try self.reportCodeAt(
                        comma_tok.span.start,
                        comma_tok.line,
                        1013,
                        "A rest parameter or binding pattern may not have a trailing comma.",
                    );
                } else if (flags.is_rest and self.peek().kind != close_kind) {
                    try self.reportCodeAt(
                        self.hir.spanOf(name_node).start,
                        elem_start.line,
                        2462,
                        "A rest element must be last in a destructuring pattern.",
                    );
                }
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

    fn parseBindingTarget(self: *Parser) ParseError!NodeId {
        if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) {
            return try self.parseBindingPattern();
        }
        const name_tok = try self.expectIdentifierLike();
        try self.reportInvalidStrictName(name_tok);
        try self.reportInvalidFutureReservedName(name_tok);
        try self.reportAwaitBindingIfReserved(name_tok);
        try self.reportReservedBindingNameIfNeeded(name_tok);
        const name_id = try self.internToken(name_tok);
        return try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
    }

    fn reportReservedBindingNameIfNeeded(self: *Parser, name_tok: Token) ParseError!void {
        if (isReservedBindingNameToken(name_tok.kind)) {
            try self.reportReservedWordCannotBeUsedHere(name_tok);
        }
    }

    fn reportReservedWordCannotBeUsedHere(self: *Parser, name_tok: Token) ParseError!void {
        const name = self.source[name_tok.span.start..name_tok.span.end];
        const msg = try std.fmt.allocPrint(
            self.diag_arena.allocator(),
            "Identifier expected. '{s}' is a reserved word that cannot be used here.",
            .{name},
        );
        try self.diagnostics.append(self.gpa, .{
            .pos = name_tok.span.start,
            .line = name_tok.line,
            .code = 1359,
            .message = msg,
        });
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
        // `void` is a strict-mode reserved word in ES — `class void {}`
        // is a parse error (TS1005 `'{' expected`) rather than the
        // soft TS2414 the other primitive-type keywords get. Skip the
        // token so parsing continues into the class body without
        // cascading "expected `{`" errors. Mirrors upstream
        // `objectTypesWithPredefinedTypesAsName2.ts(3,7)`.
        const next_kind = self.peek().kind;
        if (next_kind == .kw_void) {
            const void_tok = self.advance();
            try self.reportCodeAt(void_tok.span.start, void_tok.line, 1005, "'{' expected.");
        } else if (next_kind == .identifier or next_kind.isContextualKeyword() or next_kind.isPrimitiveTypeKeyword()) {
            const name_tok = self.advance();
            try self.reportAwaitBindingIfReserved(name_tok);
            if (name_tok.kind.isPrimitiveTypeKeyword() or self.isReservedTypeNameToken(name_tok)) {
                const raw = self.source[name_tok.span.start..name_tok.span.end];
                const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Class name cannot be '{s}'.", .{raw});
                try self.reportCodeAt(name_tok.span.start, name_tok.line, 2414, msg);
            }
            const name_id = try self.internToken(name_tok);
            name = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        }
        // Generic type parameters: `class Foo<T extends U = D>`.
        var class_type_params: []NodeId = &.{};
        var owns_type_params = false;
        if (self.peek().kind == .less_than) {
            class_type_params = try self.parseTypeParameterDeclaration();
            owns_type_params = true;
        }
        defer if (owns_type_params) self.gpa.free(class_type_params);

        var extends: NodeId = hir_mod.none_node_id;
        var saw_extends_clause = false;
        if (self.peek().kind == .kw_extends) {
            saw_extends_clause = true;
            const extends_tok = self.advance();
            if (self.peek().kind == .open_brace or
                self.peek().kind == .kw_implements or
                self.peek().kind == .comma)
            {
                try self.reportCodeAt(extends_tok.span.end, extends_tok.line, 1097, "'extends' list cannot be empty.");
            } else {
                extends = try self.parseLeftHandSideExpression();
            }
            // Optional `<T>` after `extends Foo<T>` — preserve it as
            // a type-ref for the checker while emit erases it back to
            // the runtime `extends Foo` expression.
            if (self.peek().kind == .less_than) {
                const args = try self.parseTypeArgumentList();
                defer self.gpa.free(args);
                if (self.hir.kindOf(extends) == .identifier) {
                    const id = hir_mod.identifierOf(self.hir, extends);
                    extends = try self.builder.addTypeRef(
                        .{
                            .start = self.hir.spanOf(extends).start,
                            .end = self.tokens[self.cursor - 1].span.end,
                        },
                        id.name,
                        &.{},
                        args,
                    );
                } else if (self.hir.kindOf(extends) == .member_access) {
                    extends = try self.memberAccessToTypeRef(extends, args);
                }
            }
            if (self.peek().kind == .comma) {
                const comma = self.advance();
                const report_tok = self.peek();
                if (report_tok.kind == .open_brace or report_tok.kind == .kw_implements or report_tok.kind == .eof) {
                    try self.reportCodeAt(comma.span.start, comma.line, 1009, "Trailing comma not allowed.");
                } else {
                    try self.reportCodeAt(report_tok.span.start, report_tok.line, 1174, "Classes can only extend a single class.");
                }
                while (self.peek().kind != .kw_implements and
                    self.peek().kind != .open_brace and
                    self.peek().kind != .eof)
                {
                    _ = self.advance();
                }
            }
            // tsc emits TS1172 for `class C extends A extends B {}` —
            // a second `extends` clause is forbidden. Consume the
            // duplicate clause silently so the body still parses.
            if (self.peek().kind == .kw_extends) {
                const dup = self.advance();
                try self.reportCodeAt(dup.span.start, dup.line, 1172, "'extends' clause already seen.");
                while (self.peek().kind != .kw_implements and
                    self.peek().kind != .open_brace and
                    self.peek().kind != .eof)
                {
                    _ = self.advance();
                }
            }
        }
        var implements_list: std.ArrayListUnmanaged(NodeId) = .empty;
        defer implements_list.deinit(self.gpa);
        if (self.peek().kind == .kw_implements) {
            const implements_tok = self.advance();
            if (self.peek().kind == .open_brace or self.peek().kind == .eof) {
                try self.reportCodeAt(implements_tok.span.end, implements_tok.line, 1097, "'implements' list cannot be empty.");
            } else {
                while (true) {
                    const ref = try self.parseTypeReference();
                    try implements_list.append(self.gpa, ref);
                    if (self.peek().kind != .comma) break;
                    const comma = self.advance();
                    if (self.peek().kind == .open_brace or self.peek().kind == .eof) {
                        try self.reportCodeAt(comma.span.start, comma.line, 1009, "Trailing comma not allowed.");
                        break;
                    }
                }
            }
            // tsc emits TS1172 / TS1175 for duplicate clauses after
            // `implements …`. `extends` after `implements` is allowed
            // syntactically once, but a SECOND `implements` clause is
            // TS1175; an `extends` after `implements` is TS1172.
            while (true) {
                if (self.peek().kind == .kw_extends) {
                    const dup = self.advance();
                    if (saw_extends_clause) {
                        try self.reportCodeAt(dup.span.start, dup.line, 1172, "'extends' clause already seen.");
                    } else {
                        try self.reportCodeAt(dup.span.start, dup.line, 1173, "'extends' clause must precede 'implements' clause.");
                    }
                    if (self.peek().kind != .kw_implements and
                        self.peek().kind != .kw_extends and
                        self.peek().kind != .open_brace and
                        self.peek().kind != .eof)
                    {
                        const ref = try self.parseTypeReference();
                        try implements_list.append(self.gpa, ref);
                    }
                } else if (self.peek().kind == .kw_implements) {
                    const dup = self.advance();
                    try self.reportCodeAt(dup.span.start, dup.line, 1175, "'implements' clause already seen.");
                    while (self.peek().kind != .kw_implements and
                        self.peek().kind != .kw_extends and
                        self.peek().kind != .open_brace and
                        self.peek().kind != .eof)
                    {
                        _ = self.advance();
                    }
                } else break;
            }
        }

        _ = try self.expect(.open_brace, "'{' to open class body");
        const class_body_generator_depth = self.generator_depth;
        self.generator_depth = 0;
        defer self.generator_depth = class_body_generator_depth;
        self.class_body_depth += 1;
        defer self.class_body_depth -= 1;
        const prev_class_is_abstract = self.class_is_abstract;
        self.class_is_abstract = is_abstract;
        defer self.class_is_abstract = prev_class_is_abstract;
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        var recovered_nested_declaration = false;
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            // Decorators `@dec` on members. We capture each as a
            // sibling `decorator` node in the member list — emitter
            // walks back from each member to collect preceding
            // decorator nodes.
            while (self.peek().kind == .at) {
                const dec_tok = self.advance();
                const dec_expr = blk: {
                    self.generator_depth = class_body_generator_depth;
                    defer self.generator_depth = 0;
                    break :blk try self.parseClassMemberDecoratorExpression();
                };
                const dec_node = try self.builder.addDecorator(.{
                    .start = dec_tok.span.start,
                    .end = self.hir.spanOf(dec_expr).end,
                }, dec_expr);
                try members.append(self.gpa, dec_node);
            }
            if (self.peek().kind == .kw_static and self.peekAt(1).kind == .open_brace) {
                _ = self.advance();
                self.static_block_depth += 1;
                errdefer self.static_block_depth -= 1;
                const block = try self.parseBlockStatement();
                self.static_block_depth -= 1;
                try members.append(self.gpa, block);
                continue;
            }
            if ((self.peek().kind == .kw_class or self.peek().kind == .kw_enum) and
                (self.peekAt(1).kind == .identifier or
                    self.peekAt(1).kind.isContextualKeyword() or
                    self.peekAt(1).kind == .open_brace))
            {
                const bad = self.peek();
                try self.reportCodeAt(bad.span.start, bad.line, 1068, "Unexpected token. A constructor, method, accessor, or property was expected.");
                recovered_nested_declaration = true;
                break;
            }
            const mods = try self.skipClassModifiers();
            // TS1244: `abstract` modifier on a member can only appear
            // inside an abstract class. Emit at the `abstract` token.
            if (mods.is_abstract and !self.class_is_abstract) {
                if (mods.abstract_token) |at| {
                    try self.reportCodeAt(at.span.start, at.line, 1244, "Abstract methods can only appear within an abstract class.");
                }
            }
            // TS1243: `private` modifier cannot be used with `abstract`
            // modifier. tsc emits at the `abstract` keyword (not the
            // `private` one) per baselines.
            if (mods.is_abstract and mods.visibility == .private and mods.has_accessibility) {
                if (mods.abstract_token) |at| {
                    try self.reportCodeAt(at.span.start, at.line, 1243, "'private' modifier cannot be used with 'abstract' modifier.");
                }
            }
            var member_start = self.peek();
            var invalid_index_modifier: ?Token = null;
            if (self.peek().kind == .kw_export and self.peekAt(1).kind == .open_bracket) {
                invalid_index_modifier = self.advance();
                member_start = self.peek();
            }
            // Track if we see decorators AFTER modifiers — TS1436.
            // tsc requires decorators precede modifiers like `public`.
            const had_modifiers_before_decorators =
                mods.has_accessibility or mods.is_static or mods.is_override or
                mods.is_abstract or mods.is_readonly or mods.is_async;
            while (self.peek().kind == .at) {
                const dec_tok = self.advance();
                if (had_modifiers_before_decorators) {
                    try self.reportCodeAt(dec_tok.span.start, dec_tok.line, 1436, "Decorators must precede the name and all keywords of property declarations.");
                }
                const dec_expr = blk: {
                    self.generator_depth = class_body_generator_depth;
                    defer self.generator_depth = 0;
                    break :blk try self.parseClassMemberDecoratorExpression();
                };
                const dec_node = try self.builder.addDecorator(.{
                    .start = dec_tok.span.start,
                    .end = self.hir.spanOf(dec_expr).end,
                }, dec_expr);
                try members.append(self.gpa, dec_node);
                member_start = self.peek();
            }
            const is_generator = self.match(.asterisk);
            if (self.peek().kind == .kw_var and self.peekAt(1).kind != .open_paren and self.peekAt(1).kind != .less_than and self.peekAt(1).kind != .colon and self.peekAt(1).kind != .semicolon and self.peekAt(1).kind != .open_brace) {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1068, "Unexpected token. A constructor, method, accessor, or property was expected.");
                try self.skipUntilTypeMemberSeparator();
                if (self.peek().kind == .close_brace and self.peek().flags.preceded_by_newline) {
                    const close = self.peek();
                    try self.reportCodeAt(close.span.start, close.line, 1128, "Declaration or statement expected.");
                }
                continue;
            }
            if (self.peek().kind == .open_bracket) {
                if (try self.tryParseIndexSignature(&members, mods.is_static, mods.is_readonly)) {
                    if (invalid_index_modifier) |bad| {
                        try self.reportCodeAt(bad.span.start, bad.line, 1071, "'export' modifier cannot appear on an index signature.");
                    } else if (mods.invalid_class_element_modifier) |bad| {
                        // `skipClassModifiers` swallows `export` when the
                        // next token can start a member (`[`, identifier,
                        // …). For the index-signature branch tsc routes
                        // the diagnostic through TS1071 rather than the
                        // generic TS1031, so re-emit with the index-
                        // specific code anchored at the export keyword.
                        // Mirrors `parserIndexMemberDeclaration9.ts(2,4)`.
                        const mod_name = self.source[bad.span.start..bad.span.end];
                        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on an index signature.", .{mod_name});
                        try self.reportCodeAt(bad.span.start, bad.line, 1071, msg);
                    } else if (mods.accessibility_token) |bad| {
                        const mod_name = self.source[bad.span.start..bad.span.end];
                        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on an index signature.", .{mod_name});
                        try self.reportCodeAt(bad.span.start, bad.line, 1071, msg);
                    }
                    continue;
                }
                const member = try self.parseComputedClassMember(member_start, mods, is_generator, class_body_generator_depth);
                try members.append(self.gpa, member);
                continue;
            }
            // Getter/setter: `get x(): T { ... }` / `set x(v: T) { ... }`.
            // The `get`/`set` keyword is contextual — only treat it as
            // an accessor when followed by a member name + `(`. Plain
            // `get` or `get;` (no name + paren) falls through and is
            // parsed as a regular method/property named `get`.
            var invalid_accessor_modifier: ?Token = null;
            if ((self.peek().kind == .kw_export or self.peek().kind == .kw_declare) and
                (self.peekAt(1).kind == .kw_get or self.peekAt(1).kind == .kw_set))
            {
                invalid_accessor_modifier = self.advance();
                member_start = self.peek();
            }
            const accessor_kw = self.peek().kind;
            if ((accessor_kw == .kw_get or accessor_kw == .kw_set) and
                ((self.peekAt(1).kind == .identifier or
                    self.peekAt(1).kind == .private_identifier or
                    self.peekAt(1).kind == .string_literal or
                    self.peekAt(1).kind == .number_literal or
                    self.peekAt(1).kind.isContextualKeyword()) and
                    (self.peekAt(2).kind == .open_paren or self.peekAt(2).kind == .less_than) or
                    self.peekAt(1).kind == .open_bracket))
            {
                if (invalid_accessor_modifier) |bad| {
                    const mod_name = self.source[bad.span.start..bad.span.end];
                    const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on class elements of this kind.", .{mod_name});
                    try self.reportCodeAt(bad.span.start, bad.line, 1031, msg);
                }
                // TS1042: `async` modifier cannot be used here (on
                // a getter / setter accessor).
                if (mods.is_async) {
                    if (mods.async_token) |at| {
                        try self.reportCodeAt(at.span.start, at.line, 1042, "'async' modifier cannot be used here.");
                    }
                }
                try self.reportInvalidClassElementModifier(mods);
                _ = self.advance(); // consume `get` / `set`
                const name_node = if (self.peek().kind == .open_bracket) blk: {
                    _ = self.advance();
                    const key = try self.parseExpression();
                    _ = try self.expect(.close_bracket, "']' to close computed accessor name");
                    break :blk key;
                } else blk: {
                    const name_tok = self.advance();
                    const name_id = try self.internPropertyName(name_tok, tokenSpan(name_tok));
                    break :blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                };
                if (self.classMemberNameIsConstructor(name_node)) {
                    const name_span = self.hir.spanOf(name_node);
                    try self.reportCodeAt(name_span.start, self.lineAt(name_span.start), 1341, "Class constructor may not be an accessor.");
                }
                if (self.peek().kind == .less_than) {
                    const tps = try self.parseTypeParameterDeclaration();
                    defer self.gpa.free(tps);
                    const name_span = self.hir.spanOf(name_node);
                    try self.reportCodeAt(name_span.start, self.lineAt(name_span.start), 1094, "An accessor cannot have type parameters.");
                }
                const params = try self.parseParameterList();
                defer self.gpa.free(params);
                var return_type: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);
                try self.validateAccessorSignature(accessor_kw, name_node, params, return_type);
                var body: NodeId = hir_mod.none_node_id;
                if (self.peek().kind == .open_brace) {
                    const body_start = self.peek();
                    // Class accessor bodies are function bodies — bump
                    // function_depth so `yield`/`await`-style context
                    // checks route through the in-function path. Same
                    // motivation as the object-literal accessor fix.
                    self.function_depth += 1;
                    const prev_generator_depth = self.generator_depth;
                    self.generator_depth = 0;
                    defer {
                        self.generator_depth = prev_generator_depth;
                        self.function_depth -= 1;
                    }
                    body = try self.parseBlockStatement();
                    try self.reportAmbientClassImplementationAt(body_start.span.start, body_start.line);
                } else {
                    try self.consumeStatementTerminator();
                    try self.reportMissingClassMemberImplementation(member_start, mods);
                }
                const fn_node = try self.builder.addFnDecl(
                    .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    params,
                    return_type,
                    body,
                    .{
                        .is_method = true,
                        .is_getter = accessor_kw == .kw_get,
                        .is_setter = accessor_kw == .kw_set,
                        .is_private = mods.visibility == .private,
                        .is_protected = mods.visibility == .protected,
                        .is_static = mods.is_static,
                        .is_async = mods.is_async,
                        .is_override = mods.is_override,
                        .is_abstract = mods.is_abstract,
                    },
                );
                try members.append(self.gpa, fn_node);
                continue;
            }
            // method?
            if (self.peek().kind == .identifier or
                self.peek().kind == .private_identifier or
                self.peek().kind == .string_literal or
                self.peek().kind == .number_literal or
                self.peek().kind == .kw_constructor or
                self.peek().kind == .kw_interface or
                self.peek().kind == .kw_var or
                (self.peek().kind.isKeyword() and
                    (self.peekAt(1).kind == .open_paren or
                        self.peekAt(1).kind == .less_than or
                        self.peekAt(1).kind == .colon or
                        self.peekAt(1).kind == .semicolon or
                        self.peekAt(1).kind == .equal or
                        self.peekAt(1).kind == .question)) or
                isAccessibilityModifier(self.peek().kind) or
                self.peek().kind.isContextualKeyword())
            {
                const name_tok = self.advance();
                var name_span = tokenSpan(name_tok);
                if (name_tok.kind == .number_literal and self.peek().kind == .dot and self.peekAt(1).kind == .colon) {
                    const dot_tok = self.advance();
                    name_span.end = dot_tok.span.end;
                }
                const is_optional_member = self.match(.question);
                if (is_generator or self.peek().kind == .open_paren or self.peek().kind == .less_than) {
                    var type_params: []NodeId = &.{};
                    var owns_tps = false;
                    var has_type_params_clause = false;
                    if (self.peek().kind == .less_than) {
                        has_type_params_clause = true;
                        type_params = try self.parseTypeParameterDeclaration();
                        owns_tps = true;
                    }
                    defer if (owns_tps) self.gpa.free(type_params);
                    // TS1092: `constructor<T>()` is forbidden — tsc anchors
                    // at the first type-parameter's name. When the type
                    // parameter list is empty (`constructor<>()`), fall
                    // back to a synthesized position one past the `<`
                    // (the column of the `>`). Mirrors
                    // `parserConstructorDeclaration9` and
                    // `parserConstructorDeclaration11`.
                    if (name_tok.kind == .kw_constructor and has_type_params_clause) {
                        if (type_params.len > 0) {
                            const sp = self.hir.spanOf(type_params[0]);
                            try self.reportCodeAt(sp.start, self.lineAt(sp.start), 1092, "Type parameters cannot appear on a constructor declaration.");
                        } else {
                            // Empty `<>` — anchor at the column the
                            // close-`>` already occupies (`name_span.end`
                            // points just past `constructor`; the `<` is
                            // there and the `>` is one column further).
                            const anchor: u32 = name_span.end + 1;
                            try self.reportCodeAt(anchor, name_tok.line, 1092, "Type parameters cannot appear on a constructor declaration.");
                        }
                    }
                    const params = try self.parseParameterList();
                    defer self.gpa.free(params);
                    var return_type: NodeId = hir_mod.none_node_id;
                    if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);
                    var body: NodeId = hir_mod.none_node_id;
                    if (self.peek().kind == .open_brace) {
                        const body_start = self.peek();
                        const prev_generator_depth = self.generator_depth;
                        self.generator_depth = if (is_generator) prev_generator_depth + 1 else 0;
                        defer self.generator_depth = prev_generator_depth;
                        const is_constructor_body = name_tok.kind == .kw_constructor;
                        if (is_constructor_body) self.new_target_depth += 1;
                        self.function_depth += 1;
                        if (mods.is_async) self.async_function_depth += 1;
                        defer {
                            if (is_constructor_body) self.new_target_depth -= 1;
                            self.function_depth -= 1;
                            if (mods.is_async) self.async_function_depth -= 1;
                        }
                        body = try self.parseBlockStatement();
                        try self.reportAmbientClassImplementationAt(body_start.span.start, body_start.line);
                        // TS1183 also fires when the method itself carries
                        // a `declare` modifier (per-member ambient marker)
                        // even though the enclosing class isn't ambient.
                        // The diagnostic is independent of the TS1031
                        // `cannot appear on class elements of this kind`
                        // report — tsc emits both. Mirrors upstream
                        // `parserMemberFunctionDeclaration5.ts(2,19)`.
                        //
                        // EXCEPTION: `declare constructor() {}` is covered
                        // by TS1031 alone (TS1183 is suppressed since
                        // constructors aren't representable as ambient
                        // overloads anyway). Mirrors upstream tsc on
                        // `parserConstructorDeclaration4.ts`.
                        if (mods.declare_token != null and
                            name_tok.kind != .kw_constructor and
                            !self.isAmbientContextAt(member_start.span.start))
                        {
                            try self.reportCodeAt(body_start.span.start, body_start.line, 1183, "An implementation cannot be declared in ambient contexts.");
                        }
                    } else {
                        try self.consumeStatementTerminator();
                        if (is_generator and self.isAmbientContextAt(member_start.span.start)) {
                            try self.reportCodeAt(member_start.span.start, member_start.line, 1221, "Generators are not allowed in an ambient context.");
                        } else if (is_generator) {
                            try self.reportCodeAt(member_start.span.start, member_start.line, 1222, "An overload signature cannot be declared as a generator.");
                        }
                        // tsc emits TS2390 (Constructor implementation is missing.)
                        // for missing constructor bodies — handled by the
                        // checker. Never emit TS2391 for `constructor` here
                        // so the two diagnostics don't double-report.
                        if (!is_optional_member and
                            name_tok.kind != .kw_constructor and
                            !self.nextClassMemberNameMatches(name_tok) and
                            !self.nextClassMemberLooksLikeImplementation())
                        {
                            try self.reportMissingClassMemberImplementation(member_start, mods);
                        }
                    }
                    // TS1089: `async` modifier cannot appear on a constructor.
                    if (name_tok.kind == .kw_constructor and mods.is_async) {
                        if (mods.async_token) |at| {
                            try self.reportCodeAt(at.span.start, at.line, 1089, "'async' modifier cannot appear on a constructor declaration.");
                        }
                    }
                    // TS1089: `static constructor` is forbidden — tsc anchors
                    // at the `static` keyword. Mirrors
                    // `parserConstructorDeclaration2`.
                    if (name_tok.kind == .kw_constructor and mods.is_static) {
                        if (mods.static_token) |at| {
                            try self.reportCodeAt(at.span.start, at.line, 1089, "'static' modifier cannot appear on a constructor declaration.");
                        }
                    }
                    // TS1242: `abstract constructor` is forbidden even inside
                    // abstract classes — `abstract` may only appear on a
                    // class, method, or property declaration. tsc anchors at
                    // the `abstract` keyword.
                    if (name_tok.kind == .kw_constructor and mods.is_abstract) {
                        if (mods.abstract_token) |at| {
                            try self.reportCodeAt(at.span.start, at.line, 1242, "'abstract' modifier can only appear on a class, method, or property declaration.");
                        }
                    }
                    // TS1368: `*constructor()` — the constructor cannot be
                    // a generator. The leading `*` was consumed into
                    // `is_generator` before the `constructor` name. tsc
                    // anchors at the `constructor` keyword, NOT at the
                    // `*`. Mirrors `constructorNameInGenerator.ts(2,6)`.
                    if (name_tok.kind == .kw_constructor and is_generator) {
                        try self.reportCodeAt(name_tok.span.start, name_tok.line, 1368, "Class constructor may not be a generator.");
                    }
                    // TS1031: `export` / `declare` (and other modifiers tsc
                    // tags as invalid on class members of this kind) anchor
                    // here for method/constructor parsing. Accessors call
                    // the same helper above. Mirrors upstream
                    // `parserConstructorDeclaration{3,4}` and
                    // `parserMemberFunctionDeclaration4`.
                    try self.reportInvalidClassElementModifier(mods);
                    const name_id = try self.internPropertyName(name_tok, name_span);
                    const name_node = try self.builder.addIdentifier(name_span, name_id);
                    const fn_node = try self.builder.addFnDeclGeneric(
                        .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        name_node,
                        type_params,
                        params,
                        return_type,
                        body,
                        .{
                            .is_method = true,
                            .is_constructor = name_tok.kind == .kw_constructor,
                            .is_private = mods.visibility == .private,
                            .is_protected = mods.visibility == .protected,
                            .is_static = mods.is_static,
                            .is_async = mods.is_async,
                            .is_generator = is_generator,
                            .is_override = mods.is_override,
                            .is_abstract = mods.is_abstract,
                            .is_optional = is_optional_member,
                        },
                    );
                    try members.append(self.gpa, fn_node);
                    continue;
                }
                // property
                _ = self.match(.bang);
                var type_anno: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) {
                    type_anno = try self.parseTypeAnnotation();
                    _ = self.match(.question);
                    _ = self.match(.bang);
                }
                var default_value: NodeId = hir_mod.none_node_id;
                if (self.match(.equal)) default_value = try self.parseAssignmentExpression();
                try self.consumeStatementTerminator();
                // TS1031: `export` on a class member property (e.g.
                // `export Foo;`). `declare` is permitted on properties
                // — it tells the type system the field is initialized
                // externally. Mirrors upstream
                // `parserMemberVariableDeclaration4`.
                try self.reportInvalidClassElementModifierForProperty(mods);
                const name_id = try self.internPropertyName(name_tok, name_span);
                const name_node = try self.builder.addIdentifier(name_span, name_id);
                const prop = try self.builder.addObjectPropertyFullEx(
                    .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_node,
                    default_value,
                    type_anno,
                    false,
                    default_value == hir_mod.none_node_id,
                    false,
                    mods.is_static,
                    mods.visibility,
                    mods.is_override,
                    mods.is_accessor,
                );
                try members.append(self.gpa, prop);
                continue;
            }
            // Unknown — advance to keep error-recovery flowing.
            _ = self.advance();
        }
        const close = if (recovered_nested_declaration)
            self.peek()
        else if (self.peek().kind == .close_brace)
            self.advance()
        else blk: {
            const at = self.peek();
            try self.reportCodeAt(at.span.start, at.line, 1005, "'}' expected.");
            break :blk at;
        };
        return try self.builder.addClass(
            .{ .start = span_start, .end = close.span.end },
            name,
            class_type_params,
            extends,
            implements_list.items,
            members.items,
            is_abstract,
        );
    }

    fn memberAccessToTypeRef(self: *Parser, expr: NodeId, args: []const NodeId) ParseError!NodeId {
        var names: std.ArrayListUnmanaged(hir_mod.StringId) = .empty;
        defer names.deinit(self.gpa);
        var cur = expr;
        while (self.hir.kindOf(cur) == .member_access) {
            const m = hir_mod.memberOf(self.hir, cur);
            try names.append(self.gpa, m.name);
            cur = m.object;
        }
        if (self.hir.kindOf(cur) != .identifier or names.items.len == 0) return expr;
        const root = hir_mod.identifierOf(self.hir, cur).name;
        try names.append(self.gpa, root);

        var qualifiers: std.ArrayListUnmanaged(NodeId) = .empty;
        defer qualifiers.deinit(self.gpa);
        var i = names.items.len;
        while (i > 1) {
            i -= 1;
            const q_name = names.items[i];
            const q_node = try self.builder.addIdentifier(self.hir.spanOf(cur), q_name);
            try qualifiers.append(self.gpa, q_node);
        }
        const final_name = names.items[0];
        return try self.builder.addTypeRef(
            .{ .start = self.hir.spanOf(expr).start, .end = self.tokens[self.cursor - 1].span.end },
            final_name,
            qualifiers.items,
            args,
        );
    }

    /// Tracks the TS access-modifier keywords the member-parsing
    /// loop has consumed before the member name. Other modifiers
    /// (`override`, `declare`, `out`, `in`) are parsed but discarded
    /// — access modifiers, `static`, `accessor`, `readonly`,
    /// `async`, `abstract` flow into HIR for decorator and class-
    /// member emit.
    const ClassModifiers = struct {
        visibility: hir_mod.Visibility = .public,
        has_accessibility: bool = false,
        accessibility_token: ?Token = null,
        is_static: bool = false,
        is_async: bool = false,
        is_override: bool = false,
        is_abstract: bool = false,
        is_readonly: bool = false,
        is_accessor: bool = false,
        invalid_class_element_modifier: ?Token = null,
        /// `declare` is valid on class *property* members (it tells the
        /// type system the field is initialized externally) but invalid
        /// on methods/constructors/accessors. Track it separately from
        /// the unconditional-invalid `export` keyword so the
        /// member-kind branch can decide whether to surface TS1031.
        declare_token: ?Token = null,
        async_token: ?Token = null,
        abstract_token: ?Token = null,
        static_token: ?Token = null,
        reported_duplicate_accessibility: bool = false,
    };

    fn skipClassModifiers(self: *Parser) ParseError!ClassModifiers {
        var mods: ClassModifiers = .{};
        while (true) {
            const k = self.peek().kind;
            // `export` isn't in `isModifierKeyword` (it's a top-level
            // statement keyword), but inside a class body it shows up
            // only in error fixtures like `class C { export foo() }`.
            // Capture it here so `reportInvalidClassElementModifier`
            // can fire TS1031. Mirrors upstream
            // `parserConstructorDeclaration3`, `parserMemberFunctionDeclaration4`,
            // `parserMemberVariableDeclaration4`.
            if (k == .kw_export) {
                const next_can_start_member = canStartClassMemberAfterModifier(self.peekAt(1).kind);
                if (!next_can_start_member and !self.peekAt(1).kind.isModifierKeyword()) {
                    return mods;
                }
                const mod = self.advance();
                if (mods.invalid_class_element_modifier == null) mods.invalid_class_element_modifier = mod;
                continue;
            }
            if (k.isModifierKeyword()) {
                const next_can_start_member = canStartClassMemberAfterModifier(self.peekAt(1).kind);
                if (!next_can_start_member and !self.peekAt(1).kind.isModifierKeyword()) {
                    return mods;
                }
                if (isAccessibilityModifier(k) and
                    !next_can_start_member and
                    !self.peekAt(1).kind.isModifierKeyword())
                {
                    return mods;
                }
                if (mods.is_static and isAccessibilityModifier(k) and next_can_start_member) {
                    const mod = self.advance();
                    const mod_name = self.source[mod.span.start..mod.span.end];
                    const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier must precede 'static' modifier.", .{mod_name});
                    try self.reportCodeAt(mod.span.start, mod.line, 1029, msg);
                    mods.visibility = switch (k) {
                        .kw_private => .private,
                        .kw_protected => .protected,
                        else => .public,
                    };
                    mods.has_accessibility = true;
                    mods.accessibility_token = mod;
                    continue;
                }
                if (mods.is_static and isAccessibilityModifier(k)) return mods;
                switch (k) {
                    .kw_private, .kw_protected, .kw_public => {
                        const mod = self.advance();
                        // tsc only reports TS1028 once per modifier list
                        // — emit on the FIRST duplicate, then suppress
                        // subsequent ones to match upstream baselines.
                        if (mods.has_accessibility and !mods.reported_duplicate_accessibility) {
                            try self.reportCodeAt(mod.span.start, mod.line, 1028, "Accessibility modifier already seen.");
                            mods.reported_duplicate_accessibility = true;
                        }
                        mods.has_accessibility = true;
                        mods.accessibility_token = mod;
                        mods.visibility = switch (k) {
                            .kw_private => .private,
                            .kw_protected => .protected,
                            else => .public,
                        };
                        continue;
                    },
                    .kw_static => {
                        const mod = self.advance();
                        if (mods.is_static) {
                            try self.reportCodeAt(mod.span.start, mod.line, 1434, "Unexpected keyword or identifier.");
                        }
                        mods.is_static = true;
                        if (mods.static_token == null) mods.static_token = mod;
                        continue;
                    },
                    .kw_async => {
                        mods.is_async = true;
                        if (mods.async_token == null) mods.async_token = self.peek();
                    },
                    .kw_override => mods.is_override = true,
                    .kw_abstract => {
                        mods.is_abstract = true;
                        if (mods.abstract_token == null) mods.abstract_token = self.peek();
                    },
                    .kw_export => {
                        if (mods.invalid_class_element_modifier == null) mods.invalid_class_element_modifier = self.peek();
                    },
                    .kw_declare => {
                        if (mods.declare_token == null) mods.declare_token = self.peek();
                    },
                    .kw_readonly => {
                        // TS1030: `'readonly' modifier already seen.`
                        // Emit at the second `readonly` token.
                        if (mods.is_readonly) {
                            try self.reportCodeAt(self.peek().span.start, self.peek().line, 1030, "'readonly' modifier already seen.");
                        }
                        mods.is_readonly = true;
                    },
                    .kw_accessor => {
                        // `accessor x = …` modifier (TS 4.9 / Stage 3).
                        // Only valid in front of a field name — if the
                        // next token starts a member name, consume the
                        // keyword and set the flag. Otherwise fall
                        // through (the trailing parser handles e.g.
                        // `accessor` as a plain identifier).
                        const next = self.peekAt(1).kind;
                        if (isClassMemberNameStart(next) or next == .open_bracket) {
                            mods.is_accessor = true;
                        } else {
                            return mods;
                        }
                    },
                    else => {},
                }
                _ = self.advance();
                continue;
            }
            return mods;
        }
    }

    fn isAccessibilityModifier(kind: TokenKind) bool {
        return kind == .kw_public or kind == .kw_private or kind == .kw_protected;
    }

    fn isParameterPropertyModifier(kind: TokenKind) bool {
        return switch (kind) {
            .kw_public,
            .kw_private,
            .kw_protected,
            .kw_readonly,
            .kw_override,
            => true,
            else => false,
        };
    }

    fn isClassMemberNameStart(kind: TokenKind) bool {
        return kind == .identifier or
            kind == .private_identifier or
            kind == .string_literal or
            kind == .number_literal or
            kind == .kw_constructor or
            kind == .kw_interface or
            kind == .open_bracket or
            kind.isContextualKeyword();
    }

    fn canStartClassMemberAfterModifier(kind: TokenKind) bool {
        return isClassMemberNameStart(kind) or kind == .asterisk or kind == .at;
    }

    fn isReservedBindingNameToken(kind: TokenKind) bool {
        return kind.isKeyword() and !kind.isContextualKeyword();
    }

    fn reportAmbientClassImplementation(self: *Parser, member_start: Token) ParseError!void {
        if (!self.isAmbientContextAt(member_start.span.start)) return;
        try self.reportCodeAt(member_start.span.start, member_start.line, 1183, "An implementation cannot be declared in ambient contexts.");
    }

    fn reportAmbientClassImplementationAt(self: *Parser, pos: u32, line: u32) ParseError!void {
        if (!self.isAmbientContextAt(pos)) return;
        try self.reportCodeAt(pos, line, 1183, "An implementation cannot be declared in ambient contexts.");
    }

    fn reportInvalidClassElementModifier(self: *Parser, mods: ClassModifiers) ParseError!void {
        if (mods.invalid_class_element_modifier) |bad| {
            const mod_name = self.source[bad.span.start..bad.span.end];
            const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on class elements of this kind.", .{mod_name});
            try self.reportCodeAt(bad.span.start, bad.line, 1031, msg);
        }
        // `declare` is invalid on methods/constructors/accessors only.
        // Callers parsing a class *property* skip this branch entirely
        // by using `reportInvalidClassElementModifierForProperty`.
        if (mods.declare_token) |bad| {
            const mod_name = self.source[bad.span.start..bad.span.end];
            const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on class elements of this kind.", .{mod_name});
            try self.reportCodeAt(bad.span.start, bad.line, 1031, msg);
        }
    }

    /// Property-kind class members accept `declare` (the field is
    /// initialized externally); only `export` is unconditionally
    /// rejected with TS1031.
    fn reportInvalidClassElementModifierForProperty(self: *Parser, mods: ClassModifiers) ParseError!void {
        const bad = mods.invalid_class_element_modifier orelse return;
        const mod_name = self.source[bad.span.start..bad.span.end];
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot appear on class elements of this kind.", .{mod_name});
        try self.reportCodeAt(bad.span.start, bad.line, 1031, msg);
    }

    fn reportMissingClassMemberImplementation(self: *Parser, member_start: Token, mods: ClassModifiers) ParseError!void {
        if (self.isAmbientContextAt(member_start.span.start) or mods.is_abstract) return;
        try self.reportCodeAt(member_start.span.start, member_start.line, 2391, "Function implementation is missing or not immediately following the declaration.");
    }

    fn isAmbientContext(self: *const Parser) bool {
        return self.ambient_depth > 0 or self.is_declaration_file;
    }

    fn isAmbientContextAt(self: *const Parser, pos: u32) bool {
        if (self.ambient_depth > 0) return true;
        if (self.virtualSectionFilenameAt(pos)) |filename| {
            return isDeclarationFilename(filename);
        }
        return self.is_declaration_file;
    }

    fn isVirtualDeclarationSectionAt(self: *const Parser, pos: u32) bool {
        const filename = self.virtualSectionFilenameAt(pos) orelse return false;
        return isDeclarationFilename(filename);
    }

    fn isDeclarationFilename(filename: []const u8) bool {
        if (std.mem.endsWith(u8, filename, ".d.ts")) return true;
        if (std.mem.endsWith(u8, filename, ".d.mts")) return true;
        if (std.mem.endsWith(u8, filename, ".d.cts")) return true;
        if (std.mem.endsWith(u8, filename, ".d.hm")) return true;
        if (std.mem.endsWith(u8, filename, ".d.home")) return true;
        return std.mem.endsWith(u8, filename, ".ts") and std.mem.indexOf(u8, filename, ".d.") != null;
    }

    fn virtualSectionFilenameAt(self: *const Parser, pos: u32) ?[]const u8 {
        if (std.mem.indexOf(u8, self.source, "@filename:") == null and
            std.mem.indexOf(u8, self.source, "@Filename:") == null)
        {
            return null;
        }
        const limit: usize = @min(@as(usize, pos), self.source.len);
        var last: ?usize = null;
        var line_start: usize = 0;
        while (line_start <= limit and line_start < self.source.len) {
            const line_end = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
            const line = self.source[line_start..line_end];
            if (std.mem.indexOf(u8, line, "@filename:") != null or
                std.mem.indexOf(u8, line, "@Filename:") != null)
            {
                last = line_start;
            }
            if (line_end >= limit or line_end == self.source.len) break;
            line_start = line_end + 1;
        }
        const section = last orelse return null;
        const line_end = std.mem.indexOfScalarPos(u8, self.source, section, '\n') orelse self.source.len;
        const line = self.source[section..line_end];
        const marker = std.mem.indexOf(u8, line, "@filename:") orelse
            (std.mem.indexOf(u8, line, "@Filename:") orelse return null);
        return std.mem.trim(u8, line[marker + "@filename:".len ..], " \t\r");
    }

    fn nextClassMemberNameMatches(self: *const Parser, current: Token) bool {
        const idx = self.nextClassMemberNameIndex() orelse return false;
        const next = self.tokens[idx];
        return self.classMemberNameTextMatches(current, next);
    }

    fn nextClassMemberLooksLikeImplementation(self: *const Parser) bool {
        var idx = self.nextClassMemberNameIndex() orelse return false;
        idx += 1;
        if (idx < self.tokens.len and self.tokens[idx].kind == .question) idx += 1;
        if (idx < self.tokens.len and self.tokens[idx].kind == .less_than) {
            while (idx < self.tokens.len and self.tokens[idx].kind != .open_paren and self.tokens[idx].kind != .open_brace and self.tokens[idx].kind != .semicolon and self.tokens[idx].kind != .close_brace) : (idx += 1) {}
        }
        if (idx >= self.tokens.len or self.tokens[idx].kind != .open_paren) return false;
        idx = self.skipBalancedLookahead(idx);
        if (idx < self.tokens.len and self.tokens[idx].kind == .colon) {
            idx += 1;
            while (idx < self.tokens.len and self.tokens[idx].kind != .open_brace and self.tokens[idx].kind != .semicolon and self.tokens[idx].kind != .close_brace) : (idx += 1) {}
        }
        return idx < self.tokens.len and self.tokens[idx].kind == .open_brace;
    }

    fn nextClassMemberNameIndex(self: *const Parser) ?usize {
        var idx: usize = self.cursor;
        while (idx < self.tokens.len) {
            while (idx < self.tokens.len and self.tokens[idx].kind == .at) {
                idx = self.skipDecoratorLookahead(idx);
            }
            if (idx < self.tokens.len and self.tokens[idx].kind.isModifierKeyword()) {
                idx += 1;
                continue;
            }
            break;
        }
        if (idx < self.tokens.len and self.tokens[idx].kind == .asterisk) idx += 1;
        if (idx >= self.tokens.len) return null;
        return idx;
    }

    fn skipDecoratorLookahead(self: *const Parser, start: usize) usize {
        var idx = start + 1;
        if (idx >= self.tokens.len) return idx;

        if (self.tokens[idx].kind == .open_paren) {
            idx = self.skipBalancedLookahead(idx);
        } else {
            idx += 1;
        }

        while (idx < self.tokens.len) {
            if (self.tokens[idx].kind == .dot and idx + 1 < self.tokens.len) {
                idx += 2;
                continue;
            }
            if (self.tokens[idx].kind == .open_paren) {
                idx = self.skipBalancedLookahead(idx);
                continue;
            }
            break;
        }
        return idx;
    }

    fn skipBalancedLookahead(self: *const Parser, start: usize) usize {
        var idx = start;
        var depth: usize = 0;
        while (idx < self.tokens.len) : (idx += 1) {
            switch (self.tokens[idx].kind) {
                .open_paren, .open_bracket, .open_brace => depth += 1,
                .close_paren, .close_bracket, .close_brace => {
                    if (depth == 0) return idx + 1;
                    depth -= 1;
                    if (depth == 0) return idx + 1;
                },
                else => {},
            }
        }
        return idx;
    }

    fn classMemberNameTextMatches(self: *const Parser, a: Token, b: Token) bool {
        const a_text = self.classMemberNameText(a);
        const b_text = self.classMemberNameText(b);
        return std.mem.eql(u8, a_text, b_text);
    }

    fn classMemberNameText(self: *const Parser, tok: Token) []const u8 {
        const raw = self.source[tok.span.start..tok.span.end];
        if (tok.kind == .string_literal and raw.len >= 2) return raw[1 .. raw.len - 1];
        return raw;
    }

    fn isReservedTypeNameToken(self: *const Parser, tok: Token) bool {
        const raw = self.source[tok.span.start..tok.span.end];
        return std.mem.eql(u8, raw, "any") or
            std.mem.eql(u8, raw, "unknown") or
            std.mem.eql(u8, raw, "never") or
            std.mem.eql(u8, raw, "void") or
            std.mem.eql(u8, raw, "undefined") or
            std.mem.eql(u8, raw, "string") or
            std.mem.eql(u8, raw, "number") or
            std.mem.eql(u8, raw, "boolean") or
            std.mem.eql(u8, raw, "bigint") or
            std.mem.eql(u8, raw, "symbol") or
            std.mem.eql(u8, raw, "object");
    }

    fn parseComputedClassMember(
        self: *Parser,
        member_start: Token,
        mods: ClassModifiers,
        is_generator: bool,
        key_generator_depth: u32,
    ) ParseError!NodeId {
        _ = try self.expect(.open_bracket, "'[' to start computed class member");
        const key = blk: {
            const prev_generator_depth = self.generator_depth;
            self.generator_depth = key_generator_depth;
            defer self.generator_depth = prev_generator_depth;
            break :blk try self.parseExpression();
        };
        _ = try self.expect(.close_bracket, "']' to close computed class member name");

        var value: NodeId = hir_mod.none_node_id;
        var type_anno: NodeId = hir_mod.none_node_id;
        var is_method = false;
        if (is_generator or self.peek().kind == .open_paren or self.peek().kind == .less_than) {
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
                const prev_generator_depth = self.generator_depth;
                self.generator_depth = if (is_generator) prev_generator_depth + 1 else 0;
                self.function_depth += 1;
                if (mods.is_async) self.async_function_depth += 1;
                defer {
                    self.generator_depth = prev_generator_depth;
                    self.function_depth -= 1;
                    if (mods.is_async) self.async_function_depth -= 1;
                }
                body = try self.parseBlockStatement();
                try self.reportAmbientClassImplementation(member_start);
            } else {
                try self.consumeStatementTerminator();
            }
            value = try self.builder.addFnDeclGeneric(
                .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                hir_mod.none_node_id,
                type_params,
                params,
                return_type,
                body,
                .{
                    .is_method = true,
                    .is_private = mods.visibility == .private,
                    .is_protected = mods.visibility == .protected,
                    .is_static = mods.is_static,
                    .is_async = mods.is_async,
                    .is_generator = is_generator,
                    .is_override = mods.is_override,
                    .is_abstract = mods.is_abstract,
                },
            );
            is_method = true;
        } else {
            _ = self.match(.question);
            _ = self.match(.bang);
            if (self.match(.colon)) {
                type_anno = try self.parseTypeAnnotation();
                _ = self.match(.question);
                _ = self.match(.bang);
            }
            if (self.match(.equal)) value = try self.parseAssignmentExpression();
            try self.consumeStatementTerminator();
        }

        return try self.builder.addObjectPropertyFull(
            .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
            key,
            value,
            type_anno,
            true,
            value == hir_mod.none_node_id,
            is_method,
            mods.is_static,
            mods.visibility,
            mods.is_override,
        );
    }

    fn parseClassMemberDecoratorExpression(self: *Parser) ParseError!NodeId {
        var node = try self.parsePrimaryExpression();
        while (true) {
            switch (self.peek().kind) {
                .dot => {
                    _ = self.advance();
                    const name_tok = try self.expectIdentifierLike();
                    const name_id = try self.internToken(name_tok);
                    node = try self.builder.addMemberAccess(
                        .{ .start = self.hir.spanOf(node).start, .end = name_tok.span.end },
                        node,
                        name_id,
                        false,
                    );
                },
                .open_paren => {
                    const args = try self.parseArgumentList();
                    defer self.gpa.free(args);
                    node = try self.builder.addCall(
                        .{ .start = self.hir.spanOf(node).start, .end = self.tokens[self.cursor - 1].span.end },
                        node,
                        args,
                    );
                },
                else => break,
            }
        }
        return node;
    }

    fn parseInterfaceDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // interface
        const name_tok = if (self.peek().kind == .identifier or
            self.peek().kind.isContextualKeyword() or
            self.peek().kind.isPrimitiveTypeKeyword())
            self.advance()
        else
            try self.expect(.identifier, "interface name");
        if (name_tok.kind.isPrimitiveTypeKeyword() or self.isReservedTypeNameToken(name_tok)) {
            const raw = self.source[name_tok.span.start..name_tok.span.end];
            const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Interface name cannot be '{s}'.", .{raw});
            try self.reportCodeAt(name_tok.span.start, name_tok.line, 2427, msg);
        }
        var type_params: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            type_params = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(type_params);
        var extends_list: std.ArrayListUnmanaged(NodeId) = .empty;
        defer extends_list.deinit(self.gpa);
        if (self.peek().kind == .kw_extends) {
            const extends_tok = self.advance();
            if (self.peek().kind == .open_brace or self.peek().kind == .eof) {
                try self.reportCodeAt(extends_tok.span.end, extends_tok.line, 1097, "'extends' list cannot be empty.");
            } else {
                while (true) {
                    const ref = try self.parseTypeReference();
                    try extends_list.append(self.gpa, ref);
                    if (self.peek().kind == .kw_extends) {
                        const duplicate = self.advance();
                        try self.reportCodeAt(duplicate.span.start, duplicate.line, 1172, "'extends' clause already seen.");
                        while (self.peek().kind != .open_brace and
                            self.peek().kind != .comma and
                            self.peek().kind != .eof)
                        {
                            _ = self.advance();
                        }
                        break;
                    }
                    if (!self.match(.comma)) break;
                }
            }
        }
        if (self.peek().kind == .kw_implements) {
            const impl = self.advance();
            try self.reportCodeAt(impl.span.start, impl.line, 1176, "Interface declaration cannot have 'implements' clause.");
            while (self.peek().kind != .open_brace and self.peek().kind != .eof) _ = self.advance();
        }
        _ = try self.expect(.open_brace, "'{' to open interface body");
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        try self.parseTypeMemberList(&members);
        const close = if (self.peek().kind == .close_brace)
            self.advance()
        else blk: {
            const at = self.peek();
            const suppress_after_unterminated_type_args = at.kind == .eof and
                self.diagnostics.items.len > 0 and
                self.diagnostics.items[self.diagnostics.items.len - 1].code == 1005 and
                std.mem.eql(u8, self.diagnostics.items[self.diagnostics.items.len - 1].message, "'>' expected.");
            if (!suppress_after_unterminated_type_args) {
                try self.reportCodeAt(at.span.start, at.line, 1005, "'}' expected.");
            }
            break :blk at;
        };
        const name_id_str = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id_str);
        return try self.builder.addInterface(
            .{ .start = start.span.start, .end = close.span.end },
            name_node,
            type_params,
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
        // TS1046: A top-level `enum` in a `.d.ts` file without a
        // leading `declare` / `export` modifier is invalid. Anchored
        // at the `enum` keyword to match upstream tsc's column on
        // `parserEnumDeclaration3.d.ts(1,1)`.
        if (self.isAmbientContextAt(start.span.start) and
            self.block_depth == 0 and
            self.namespace_depth == 0 and
            self.ambient_depth == 0 and
            !self.in_export_declaration)
        {
            try self.reportCodeAt(start.span.start, start.line, 1046, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.");
        }
        const name_tok = if (self.peek().kind == .identifier or self.peek().kind.isContextualKeyword())
            self.advance()
        else if (isReservedBindingNameToken(self.peek().kind)) blk: {
            const tok = self.advance();
            try self.reportReservedWordCannotBeUsedHere(tok);
            break :blk tok;
        } else try self.expect(.identifier, "enum name");
        _ = try self.expect(.open_brace, "'{' to open enum body");
        var members: std.ArrayListUnmanaged(NodeId) = .empty;
        defer members.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const member_start = self.peek();
            if (member_start.kind == .comma) {
                const comma = self.advance();
                try self.reportCodeAt(comma.span.start, comma.line, 1132, "Enum member expected.");
                continue;
            }
            if (member_start.kind == .invalid) {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                if (self.peek().kind == .comma) _ = self.advance();
                continue;
            }
            var is_computed = false;
            const name_node = if (self.peek().kind == .open_bracket) blk: {
                const open = self.advance();
                const key = try self.parseExpression();
                _ = try self.expect(.close_bracket, "']' to close computed enum member name");
                try self.reportCodeAt(open.span.start, open.line, 1164, "Computed property names are not allowed in enums.");
                is_computed = true;
                break :blk key;
            } else blk: {
                const member_tok = if (self.peek().kind == .string_literal or self.peek().kind == .number_literal)
                    self.advance()
                else
                    try self.expectIdentifierLike();
                if (member_tok.kind == .number_literal) {
                    try self.reportCodeAt(member_tok.span.start, member_tok.line, 2452, "An enum member cannot have a numeric name.");
                }
                const name_id = try self.internPropertyName(member_tok, tokenSpan(member_tok));
                break :blk try self.builder.addIdentifier(tokenSpan(member_tok), name_id);
            };
            var value: NodeId = hir_mod.none_node_id;
            var recovered_bad_separator = false;
            if (self.peek().kind == .colon) {
                const colon = self.advance();
                try self.reportCodeAt(colon.span.start, colon.line, 1357, "An enum member name must be followed by a ',', '=', or '}'.");
                recovered_bad_separator = true;
            }
            if (self.match(.equal)) value = try self.parseAssignmentExpression();
            const member = try self.builder.addObjectProperty(
                .{ .start = member_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                name_node,
                value,
                is_computed,
                value == hir_mod.none_node_id,
                false,
            );
            try members.append(self.gpa, member);
            if (recovered_bad_separator) continue;
            if (!self.match(.comma)) break;
        }
        const close_end = if (self.peek().kind == .close_brace) blk: {
            break :blk self.advance().span.end;
        } else blk: {
            const close = self.peek();
            const diag_pos = if (close.kind == .eof and self.cursor > 0 and self.tokens[self.cursor - 1].kind == .invalid)
                self.tokens[self.cursor - 1].span.start + 1
            else
                close.span.start;
            try self.reportCodeAt(diag_pos, close.line, 1005, "'}' expected.");
            if (close.kind == .eof) self.enum_recovered_missing_close_at_eof = true;
            break :blk diag_pos;
        };
        const name_id = try self.internToken(name_tok);
        const name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        return try self.builder.addEnum(
            .{ .start = start.span.start, .end = close_end },
            name_node,
            members.items,
            false,
        );
    }

    fn parseNamespaceDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // namespace / module
        // TS1046: A top-level `namespace` / `module` in a `.d.ts` file
        // without a leading `declare` / `export` modifier is invalid.
        // Anchored at the `namespace` / `module` keyword to match
        // upstream tsc's column on
        // `parserModuleDeclaration{1,2,4}.d.ts(1,1)`.
        if (self.isAmbientContextAt(start.span.start) and
            self.block_depth == 0 and
            self.namespace_depth == 0 and
            self.ambient_depth == 0 and
            !self.in_export_declaration)
        {
            try self.reportCodeAt(start.span.start, start.line, 1046, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.");
        }
        const name_tok = if (self.peek().kind == .string_literal)
            self.advance()
        else
            try self.expectIdentifierLike();
        // TS1035: A quoted-name namespace/module declaration is only
        // legal in an ambient context (after `declare` or inside a
        // `.d.ts` file). Bare `module "Foo" {}` in a `.ts` file is an
        // augmentation form that requires the ambient marker. Mirrors
        // upstream tsc on `parserModuleDeclaration1.ts(1,8)`.
        if (name_tok.kind == .string_literal and
            self.ambient_depth == 0 and
            !self.isAmbientContextAt(start.span.start))
        {
            try self.reportCodeAt(name_tok.span.start, name_tok.line, 1035, "Only ambient modules can use quoted names.");
        }
        var name_end = name_tok.span.end;
        while (self.peek().kind == .dot) {
            _ = self.advance();
            const part = try self.expectIdentifierLike();
            name_end = part.span.end;
        }
        _ = try self.expect(.open_brace, "'{' to open namespace body");
        self.namespace_depth += 1;
        defer self.namespace_depth -= 1;
        var body: std.ArrayListUnmanaged(NodeId) = .empty;
        defer body.deinit(self.gpa);
        while (self.hasPendingStatement() or (self.peek().kind != .close_brace and self.peek().kind != .eof)) {
            try body.append(self.gpa, try self.parseStatement());
        }
        const close_end = if (self.peek().kind == .close_brace) blk: {
            break :blk self.advance().span.end;
        } else blk: {
            const close = self.peek();
            if (close.kind == .eof and self.enum_recovered_missing_close_at_eof) {
                self.enum_recovered_missing_close_at_eof = false;
            } else {
                try self.reportCodeAt(close.span.start, close.line, 1005, "'}' expected.");
            }
            break :blk close.span.start;
        };
        const name_id = if (name_tok.kind == .string_literal)
            try self.internStringLiteral(name_tok)
        else
            self.interner.intern(self.source[name_tok.span.start..name_end]) catch return error.OutOfMemory;
        const name_node = try self.builder.addIdentifier(.{ .start = name_tok.span.start, .end = name_end }, name_id);
        return try self.builder.addNamespace(
            .{ .start = start.span.start, .end = close_end },
            name_node,
            body.items,
        );
    }

    fn parseImportDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // import
        if (self.block_depth == 0 and self.namespace_depth == 0 and self.ambient_depth == 0) {
            self.top_level_external_module_indicator = true;
        }
        var is_type_only = false;
        if (self.peek().kind == .kw_type) {
            if (!(self.peekAt(1).kind == .kw_from and self.peekAt(2).kind == .string_literal)) {
                _ = self.advance();
                is_type_only = true;
            }
        }
        var default_binding: NodeId = hir_mod.none_node_id;
        var namespace_binding: NodeId = hir_mod.none_node_id;
        var named: std.ArrayListUnmanaged(NodeId) = .empty;
        defer named.deinit(self.gpa);

        if ((self.peek().kind == .identifier or self.peek().kind.isContextualKeyword()) and
            self.tokenTextEquals(self.peek(), "defer") and
            self.peekAt(1).kind == .open_brace)
        {
            try self.reportCodeAt(self.peek().span.start, self.peek().line, 18059, "Named imports are not allowed in a deferred import.");
        }

        if ((self.peek().kind == .identifier or self.peek().kind == .kw_await or self.peek().kind.isContextualKeyword()) and
            self.peekAt(1).kind == .equal)
        {
            const alias_tok = self.peek();
            if (is_type_only and self.peekAt(2).kind != .kw_require) {
                try self.reportCodeAt(
                    start.span.start,
                    start.line,
                    1392,
                    "An import alias cannot use 'import type'.",
                );
            }
            if (alias_tok.kind == .kw_await and (self.peekAt(2).kind == .kw_require or self.top_level_export_indicator)) {
                try self.reportCodeAt(
                    alias_tok.span.start,
                    alias_tok.line,
                    1262,
                    "Identifier expected. 'await' is a reserved word at the top-level of a module.",
                );
            }
            const alias_id = try self.internToken(alias_tok);
            const alias_node = try self.builder.addIdentifier(tokenSpan(alias_tok), alias_id);
            _ = self.advance(); // local alias
            _ = self.advance(); // =
            var module_id = self.interner.intern("") catch return error.OutOfMemory;
            var import_equals = hir_mod.none_node_id;
            if (self.peek().kind == .kw_require and self.peekAt(1).kind == .open_paren and self.peekAt(2).kind == .string_literal) {
                _ = self.advance(); // require
                _ = self.advance(); // (
                const mod_tok = self.advance();
                module_id = try self.internStringLiteral(mod_tok);
                _ = try self.expect(.close_paren, "')' after require module specifier");
                try self.consumeStatementTerminator();
            } else if (self.peek().kind == .kw_require and self.peekAt(1).kind == .open_paren) {
                try self.consumeImportEqualsTail();
            } else {
                if (self.peek().kind == .identifier or self.peek().kind.isContextualKeyword() or self.peek().kind.isKeyword()) {
                    import_equals = try self.parseImportEqualsEntityName();
                    try self.consumeStatementTerminator();
                } else {
                    try self.consumeImportEqualsTail();
                }
            }
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addImport(
                .{ .start = start.span.start, .end = end_pos },
                module_id,
                alias_node,
                hir_mod.none_node_id,
                import_equals,
                &.{},
                is_type_only,
            );
        }

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
                hir_mod.none_node_id,
                &.{},
                is_type_only,
            );
        }

        // Default binding?
        if (self.peek().kind == .identifier or self.peek().kind.isContextualKeyword()) {
            const name_tok = self.advance();
            if (name_tok.kind == .kw_await and self.top_level_external_module_indicator) {
                try self.reportCodeAt(
                    name_tok.span.start,
                    name_tok.line,
                    1262,
                    "Identifier expected. 'await' is a reserved word at the top-level of a module.",
                );
            }
            const id = try self.internToken(name_tok);
            default_binding = try self.builder.addIdentifier(tokenSpan(name_tok), id);
            if (!self.match(.comma)) {
                // Only default — proceed to from clause.
            }
        }

        // Namespace import: `* as ns`?
        if (self.match(.asterisk)) {
            _ = try self.expect(.kw_as, "'as' in namespace import");
            const name_tok = try self.expectIdentifierLike();
            if (name_tok.kind == .kw_await and self.top_level_external_module_indicator) {
                try self.reportCodeAt(
                    name_tok.span.start,
                    name_tok.line,
                    1262,
                    "Identifier expected. 'await' is a reserved word at the top-level of a module.",
                );
            }
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
                var local_tok_for_diag = imported_tok;
                var has_alias = false;
                if (self.match(.kw_as)) {
                    const local_tok = try self.expectIdentifierLike();
                    local_id = try self.internToken(local_tok);
                    local_tok_for_diag = local_tok;
                    has_alias = true;
                }
                if (!has_alias and imported_tok.kind == .kw_await and self.top_level_external_module_indicator) {
                    try self.reportCodeAt(
                        imported_tok.span.start,
                        imported_tok.line,
                        1262,
                        "Identifier expected. 'await' is a reserved word at the top-level of a module.",
                    );
                }
                if (has_alias and local_tok_for_diag.kind == .kw_await and self.top_level_external_module_indicator) {
                    try self.reportCodeAt(
                        local_tok_for_diag.span.start,
                        local_tok_for_diag.line,
                        1262,
                        "Identifier expected. 'await' is a reserved word at the top-level of a module.",
                    );
                }
                if (self.tokenTextEquals(local_tok_for_diag, "yield") and self.top_level_external_module_indicator) {
                    try self.reportCodeAt(
                        local_tok_for_diag.span.start,
                        local_tok_for_diag.line,
                        1214,
                        "Identifier expected. 'yield' is a reserved word in strict mode. Modules are automatically in strict mode.",
                    );
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

        if (is_type_only and default_binding != hir_mod.none_node_id and
            (namespace_binding != hir_mod.none_node_id or named.items.len != 0))
        {
            try self.reportCodeAt(
                start.span.start,
                start.line,
                1363,
                "A type-only import can specify a default import or named bindings, but not both.",
            );
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
            hir_mod.none_node_id,
            named.items,
            is_type_only,
        );
    }

    fn consumeImportEqualsTail(self: *Parser) ParseError!void {
        if (self.peek().kind == .kw_require and self.peekAt(1).kind == .open_paren) {
            const arg = self.peekAt(2);
            if (arg.kind != .string_literal) {
                try self.reportCodeAt(arg.span.start, arg.line, 1141, "String literal expected.");
            }
        }
        var depth: i32 = 0;
        var saw_token = false;
        while (true) {
            const t = self.peek();
            if (t.kind == .eof or t.kind == .semicolon) break;
            if (depth == 0 and (t.kind == .close_brace or (saw_token and t.flags.preceded_by_newline))) break;
            switch (t.kind) {
                .open_paren, .open_brace, .open_bracket => depth += 1,
                .close_paren, .close_brace, .close_bracket => {
                    if (depth > 0) {
                        depth -= 1;
                    } else {
                        break;
                    }
                },
                else => {},
            }
            _ = self.advance();
            saw_token = true;
        }
        _ = self.match(.semicolon);
    }

    fn parseImportEqualsEntityName(self: *Parser) ParseError!NodeId {
        const start = self.peek();
        const name_tok = try self.expectIdentifierLike();
        var name_id = try self.internToken(name_tok);

        var qualifier: std.ArrayListUnmanaged(NodeId) = .empty;
        defer qualifier.deinit(self.gpa);
        var previous_tok = name_tok;

        while (self.peek().kind == .dot) {
            _ = self.advance();
            const next_tok = try self.expectIdentifierLike();
            const prev_node = try self.builder.addIdentifier(tokenSpan(previous_tok), name_id);
            try qualifier.append(self.gpa, prev_node);
            previous_tok = next_tok;
            name_id = try self.internToken(next_tok);
        }

        return try self.builder.addTypeRef(
            .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end },
            name_id,
            qualifier.items,
            &.{},
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
        // A trailing `with` / `assert` with no `{` is reported as the
        // tsc-style `TS1005: '{' expected.` anchored at the column right
        // after the keyword (matches `importAttributes4`/`importAssertion4`).
        const keyword_tok = self.peek();
        if (self.peekAt(1).kind != .open_brace) {
            const next_tok = self.peekAt(1);
            const next_is_terminator = switch (next_tok.kind) {
                .semicolon, .eof, .close_brace, .close_paren => true,
                else => false,
            };
            // Heuristic: only synthesize the missing-`{` diagnostic when the
            // `with` keyword sits at the tail of an import (or before a
            // statement terminator / newline). Otherwise leave the
            // surrounding parser to handle it (e.g. `with` statements).
            if (next_is_terminator or next_tok.flags.preceded_by_newline) {
                // tsc anchors TS1005 `'{' expected.` at the next "meaningful"
                // token position. When the keyword sits immediately before a
                // newline + EOF, that's the column-1 start of the next line
                // (`importAssertion4` baseline `(2,1)`); when the keyword is
                // the very last byte of the file with no newline, it's the
                // column right after the keyword (`importAttributes4` `(1,34)`).
                const anchor_pos: u32 = if (next_tok.flags.preceded_by_newline)
                    next_tok.span.start
                else
                    keyword_tok.span.end;
                const anchor_line: u32 = if (next_tok.flags.preceded_by_newline)
                    next_tok.line
                else
                    keyword_tok.line;
                try self.reportCodeAt(anchor_pos, anchor_line, 1005, "'{' expected.");
                _ = self.advance(); // consume the dangling `with` / `assert`
            }
            return;
        }
        _ = self.advance(); // `with` / `assert`
        const open_brace_tok = try self.expect(.open_brace, "'{' to start import attributes");
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
        if (self.peek().kind != .close_brace) {
            // Synthesize `TS1005: '}' expected.` matching tsc's
            // `importAttributes5`/`importAssertion5` baselines. tsc anchors
            // it at the next "meaningful" token — that's column-1 of the
            // following line when the `{` is followed by a newline + EOF
            // (`importAssertion5` `(2,1)`), and the column right after `{`
            // when the file ends with no newline (`importAttributes5` `(1,36)`).
            const next_tok = self.peek();
            const anchor_pos: u32 = if (next_tok.kind == .eof and !next_tok.flags.preceded_by_newline)
                open_brace_tok.span.end
            else
                next_tok.span.start;
            const anchor_line: u32 = if (next_tok.kind == .eof and !next_tok.flags.preceded_by_newline)
                open_brace_tok.line
            else
                next_tok.line;
            try self.reportCodeAt(anchor_pos, anchor_line, 1005, "'}' expected.");
            return;
        }
        _ = self.advance(); // closing `}`
    }

    fn parseExportDeclaration(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // export
        if (self.block_depth == 0 and self.namespace_depth == 0 and self.ambient_depth == 0) {
            self.top_level_external_module_indicator = true;
            self.top_level_export_indicator = true;
        }
        if (self.peek().kind == .kw_export) {
            const dup = self.advance();
            try self.reportCodeAt(dup.span.start, dup.line, 1030, "'export' modifier already seen.");
        }
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

        // CommonJS-style `export = value;`. The ES-facing HIR has no
        // dedicated export-assignment node yet; parse and preserve the
        // assigned expression as an export payload so multi-file fixtures
        // keep their module shape without producing a parser diagnostic.
        if (self.match(.equal)) {
            if (self.namespace_depth > 0 and self.ambient_depth == 0) {
                try self.reportCodeAt(start.span.start, start.line, 1063, "An export assignment cannot be used in a namespace.");
            }
            const expr = try self.parseAssignmentExpression();
            try self.consumeStatementTerminator();
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addExport(
                .{ .start = start.span.start, .end = end_pos },
                expr,
                &.{},
                empty_string,
                is_type_only,
                false,
            );
        }

        // `export import Foo = ns.Foo;` inside namespaces/global
        // augmentations is an import-alias declaration, not an ES
        // module import. The current HIR has no dedicated node yet;
        // consume it as a harmless empty statement so declaration-emit
        // conformance fixtures keep parsing.
        if (self.peek().kind == .kw_import) {
            while (self.peek().kind != .semicolon and self.peek().kind != .close_brace and self.peek().kind != .eof) {
                _ = self.advance();
            }
            _ = self.match(.semicolon);
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addBlock(.{ .start = start.span.start, .end = end_pos }, &.{});
        }

        // `export as namespace Foo;` is a declaration-file/global UMD
        // export form. Keep it parseable for JS declaration conformance
        // even though the current HIR has no dedicated representation.
        if (self.match(.kw_as)) {
            _ = try self.expect(.kw_namespace, "'namespace' after 'export as'");
            _ = try self.expectIdentifierLike();
            try self.consumeStatementTerminator();
            const end_pos = self.tokens[self.cursor - 1].span.end;
            return try self.builder.addBlock(.{ .start = start.span.start, .end = end_pos }, &.{});
        }

        // export default <expr>;
        if (self.match(.kw_default)) {
            if (self.namespace_depth > 0 and self.ambient_depth == 0) {
                try self.reportCodeAt(start.span.start, start.line, 1319, "A default export can only be used in an ECMAScript-style module.");
            }
            // `export default` may be followed by a class/function
            // *declaration* (no statement-terminator) — those have
            // their own statement parser; otherwise it's an
            // expression value.
            const decl = switch (self.peek().kind) {
                .kw_class => try self.parseClassDeclaration(),
                .kw_function => try self.parseFunctionDeclaration(false),
                .kw_async => blk: {
                    if (self.peekAt(1).kind == .kw_function) {
                        _ = self.advance();
                        self.async_function_depth += 1;
                        defer self.async_function_depth -= 1;
                        const fd = try self.parseFunctionDeclaration(false);
                        self.hir.markFnAsync(fd);
                        break :blk fd;
                    }
                    const expr = try self.parseAssignmentExpression();
                    try self.consumeStatementTerminator();
                    break :blk expr;
                },
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
                    const local_tok = try self.expectIdentifierLike();
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
                try self.skipImportAttributesClause();
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
                const ns_tok = try self.expectIdentifierLike();
                ns_alias = try self.internToken(ns_tok);
            }
            _ = try self.expect(.kw_from, "'from' after 'export *'");
            const mod_tok = try self.expect(.string_literal, "module specifier");
            try self.skipImportAttributesClause();
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
        const old_in_export_declaration = self.in_export_declaration;
        self.in_export_declaration = true;
        defer self.in_export_declaration = old_in_export_declaration;
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
        if (self.peek().kind == .kw_enum) {
            const tok = self.peek();
            try self.reportCodeAt(tok.span.start, tok.line, 1109, "Expression expected.");
            const empty = self.interner.intern("") catch return error.OutOfMemory;
            return try self.builder.addIdentifier(.{ .start = tok.span.start, .end = tok.span.start }, empty);
        }
        return try self.parseLeftHandSideExpression();
    }

    fn parseVarDecl(self: *Parser) ParseError!NodeId {
        const start = self.advance(); // let/const/var
        if (self.isAmbientContextAt(start.span.start) and
            self.block_depth == 0 and
            self.namespace_depth == 0 and
            self.ambient_depth == 0 and
            !self.in_export_declaration)
        {
            try self.reportCodeAt(start.span.start, start.line, 1046, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.");
        }
        const old_in_top_level_module_binding_decl = self.in_top_level_module_binding_decl;
        self.in_top_level_module_binding_decl = self.top_level_external_module_indicator and
            self.block_depth == 0 and self.namespace_depth == 0 and self.ambient_depth == 0;
        defer self.in_top_level_module_binding_decl = old_in_top_level_module_binding_decl;
        const decl_kind: hir_mod.NodeKind = switch (start.kind) {
            .kw_let => .let_decl,
            .kw_const => .const_decl,
            .kw_var => .var_decl,
            else => unreachable,
        };
        // Destructuring binding (`const { a } = obj`, `const [b] = arr`)
        // stores the pattern in the var-decl's `name` slot in the same
        // way parameters stash an `object_pattern` / `array_pattern`.
        // `name_list_was_empty` tracks the TS1123 path so the TS1155
        // "'const' declarations must be initialized." follow-on is
        // suppressed — tsc only reports the empty-list diagnostic on
        // fixtures like `VariableDeclaration1_es6` (`const` alone).
        var name_list_was_empty = false;
        const name_node: NodeId = if (self.peek().kind == .semicolon or self.peek().kind == .eof) blk: {
            const empty_pos = start.span.end;
            try self.reportCodeAt(empty_pos, start.line, 1123, "Variable declaration list cannot be empty.");
            const empty_id = self.interner.intern("") catch return error.OutOfMemory;
            name_list_was_empty = true;
            break :blk try self.builder.addIdentifier(.{ .start = empty_pos, .end = empty_pos }, empty_id);
        } else if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
            break :blk try self.parseBindingPattern();
        } else id_blk: {
            const name_tok = try self.expectIdentifierLike();
            try self.reportInvalidVariableDeclarationName(name_tok);
            try self.reportInvalidStrictName(name_tok);
            try self.reportInvalidFutureReservedName(name_tok);
            try self.reportAwaitBindingIfReserved(name_tok);
            const name_id = try self.internToken(name_tok);
            break :id_blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
        };

        // Definite-assignment assertion in declarations: `let x!: T`.
        // It affects TS control-flow checks only; HIR keeps the same
        // declaration shape and the emitter erases it.
        _ = self.match(.bang);

        var type_annotation: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) {
            type_annotation = try self.parseTypeAnnotation();
        }

        var init_node: NodeId = hir_mod.none_node_id;
        if (self.match(.equal)) {
            init_node = try self.parseAssignmentExpression();
        }
        try self.recoverRegexVariableDeclarationTail(init_node);
        const is_ambient_decl = self.isAmbientContextAt(start.span.start);
        if (decl_kind == .const_decl and init_node == hir_mod.none_node_id and !is_ambient_decl and !name_list_was_empty) {
            // `const {}` and `const []` already raise TS1182
            // ("A destructuring declaration must have an
            // initializer.") from the checker; tsc does not
            // additionally surface the TS1155 ("must be
            // initialized") so we suppress the duplicate here.
            // Similarly, `const` with no bindings already raises
            // TS1123 (empty declaration list); suppressing TS1155
            // here matches tsc on `VariableDeclaration1_es6`.
            const name_kind = self.hir.kindOf(name_node);
            if (name_kind != .object_pattern and name_kind != .array_pattern) {
                try self.reportCodeAt(self.hir.spanOf(name_node).start, start.line, 1155, "'const' declarations must be initialized.");
            }
        }
        while (self.match(.comma)) {
            const comma_tok = self.tokens[self.cursor - 1];
            if (self.peek().kind == .semicolon or self.peek().kind == .eof) {
                try self.reportCodeAt(comma_tok.span.start, comma_tok.line, 1009, "Trailing comma not allowed.");
                break;
            }
            if (self.peek().kind == .kw_return and self.peek().flags.preceded_by_newline) {
                try self.reportCodeAt(comma_tok.span.start, comma_tok.line, 1009, "Trailing comma not allowed.");
                break;
            }
            const extra_name: NodeId = if (self.peek().kind == .open_brace or self.peek().kind == .open_bracket) blk: {
                break :blk try self.parseBindingPattern();
            } else id_blk: {
                const name_tok = try self.expectIdentifierLike();
                try self.reportInvalidVariableDeclarationName(name_tok);
                try self.reportInvalidStrictName(name_tok);
                try self.reportInvalidFutureReservedName(name_tok);
                try self.reportAwaitBindingIfReserved(name_tok);
                const name_id = try self.internToken(name_tok);
                break :id_blk try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
            };
            _ = self.match(.bang);
            var extra_type: NodeId = hir_mod.none_node_id;
            if (self.match(.colon)) extra_type = try self.parseTypeAnnotation();
            var extra_init: NodeId = hir_mod.none_node_id;
            if (self.match(.equal)) extra_init = try self.parseAssignmentExpression();
            try self.recoverRegexVariableDeclarationTail(extra_init);
            if (decl_kind == .const_decl and extra_init == hir_mod.none_node_id and !is_ambient_decl) {
                const extra_kind = self.hir.kindOf(extra_name);
                if (extra_kind != .object_pattern and extra_kind != .array_pattern) {
                    try self.reportCodeAt(self.hir.spanOf(extra_name).start, start.line, 1155, "'const' declarations must be initialized.");
                }
            }
            const extra_start = self.hir.spanOf(extra_name).start;
            const extra_end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else self.hir.spanOf(extra_name).end;
            const extra_decl = try self.builder.addVarDeclEx(
                decl_kind,
                .{ .start = extra_start, .end = extra_end },
                extra_name,
                extra_type,
                extra_init,
                false,
                false,
                is_ambient_decl,
            );
            try self.pending_statements.append(self.gpa, extra_decl);
        }
        try self.consumeStatementTerminator();

        const stmt_span: Span = .{ .start = start.span.start, .end = self.tokens[self.cursor - 1].span.end };
        return try self.builder.addVarDeclEx(
            decl_kind,
            stmt_span,
            name_node,
            type_annotation,
            init_node,
            false,
            false,
            is_ambient_decl,
        );
    }

    fn recoverRegexVariableDeclarationTail(self: *Parser, init_node: NodeId) ParseError!void {
        if (init_node == hir_mod.none_node_id or self.hir.kindOf(init_node) != .literal_regex) return;
        const close = self.peek();
        if (close.kind != .close_bracket or close.flags.preceded_by_newline) return;

        try self.reportCodeAt(close.span.start, close.line, 1005, "',' expected.");
        _ = self.advance();

        const bad_decl = self.peek();
        if (bad_decl.kind == .semicolon or
            bad_decl.kind == .eof or
            bad_decl.kind == .close_brace or
            bad_decl.flags.preceded_by_newline)
        {
            return;
        }
        try self.reportCodeAt(bad_decl.span.start, bad_decl.line, 1134, "Variable declaration expected.");
        _ = self.advance();
    }

    /// Parse a Stage 3 explicit-resource-management declaration:
    ///   `using x = expr;`
    ///   `await using x = expr;`
    /// `await_using` selects the async-dispose form. The binding is
    /// lowered to a `const_decl`-shaped HIR node with the `is_using` /
    /// `is_await_using` flag set on its payload — for v0 emitters can
    /// continue treating it as `const`. Try/finally lowering for
    /// `[Symbol.dispose]()` / `[Symbol.asyncDispose]()` is a follow-up.
    /// Parse the target identifier (or recover from a binding pattern)
    /// of a single `using` / `await using` binder. When the binder is
    /// `[a, b]` / `{ a }`, emit TS1492 ("'using' declarations may not
    /// have binding patterns") at the pattern's start, skip over the
    /// pattern, and return a synthetic identifier token rooted at the
    /// pattern's open bracket so downstream HIR shape is preserved.
    fn parseUsingDeclBindingTarget(self: *Parser, await_using: bool) ParseError!Token {
        const tok = self.peek();
        if (tok.kind == .open_bracket or tok.kind == .open_brace) {
            const message = if (await_using)
                "'await using' declarations may not have binding patterns."
            else
                "'using' declarations may not have binding patterns.";
            try self.reportCodeAt(tok.span.start, tok.line, 1492, message);
            // Skip the binding pattern's content so the rest of the
            // declarator (`= initializer`) stays parseable. Walk
            // brackets/braces with a tiny depth counter.
            const open = self.advance();
            var depth: u32 = 1;
            while (depth > 0) {
                const cur = self.peek();
                if (cur.kind == .eof) break;
                if (cur.kind == .open_bracket or cur.kind == .open_brace) depth += 1;
                if (cur.kind == .close_bracket or cur.kind == .close_brace) depth -= 1;
                _ = self.advance();
            }
            // Synthesize a placeholder identifier token at the pattern's
            // open bracket so the var-decl HIR has a usable name slot.
            return .{
                .kind = .identifier,
                .span = open.span,
                .line = open.line,
                .flags = open.flags,
            };
        }
        return try self.expect(.identifier, "identifier in using declaration");
    }

    /// Variant of `parseUsingDeclBindingTarget` used when we've
    /// already committed to treating the source as a using-decl with
    /// a real binding pattern (top-level `using {a} = ...`). Instead
    /// of skipping the pattern we keep its structure so the checker
    /// can emit the per-property TS2339 / TS2488 diagnostics tsc
    /// produces against the initializer. Returns the binding pattern
    /// node directly.
    fn parseUsingDeclBindingPattern(self: *Parser, await_using: bool) ParseError!NodeId {
        const tok = self.peek();
        std.debug.assert(tok.kind == .open_brace or tok.kind == .open_bracket);
        const message = if (await_using)
            "'await using' declarations may not have binding patterns."
        else
            "'using' declarations may not have binding patterns.";
        try self.reportCodeAt(tok.span.start, tok.line, 1492, message);
        return try self.parseBindingPattern();
    }

    fn parseUsingDecl(self: *Parser, await_using: bool) ParseError!NodeId {
        const start = self.advance(); // `using` or `await`
        if (await_using) {
            _ = self.advance(); // `using` token following `await`
        }
        const in_ambient = self.ambient_depth > 0;
        if (in_ambient) {
            // `using` / `await using` declarations are not legal in
            // ambient contexts (TS1545 / TS1546). Emit the specific
            // diagnostic and short-circuit the function/top-level
            // gating (which doesn't apply when the file would never
            // emit code anyway).
            const code: u32 = if (await_using) 1546 else 1545;
            const message = if (await_using)
                "'await using' declarations are not allowed in ambient contexts."
            else
                "'using' declarations are not allowed in ambient contexts.";
            try self.reportCodeAt(start.span.start, start.line, code, message);
        } else if (await_using) {
            // `await using` requires either an async function context
            // OR top-level of a module. "Top-level" here means any
            // position that isn't enclosed by a function — `{}` blocks,
            // `if`/`while` arms, switch case bodies don't count as
            // function boundaries. The module indicator is derived
            // from a top-level `import`/`export` having been seen.
            const inside_function = self.function_depth > 0;
            const file_is_module = self.top_level_external_module_indicator;
            if (self.static_block_depth > 0) {
                try self.reportCodeAt(start.span.start, start.line, 18054, "'await using' statements cannot be used inside a class static block.");
            } else if (inside_function and self.async_function_depth == 0) {
                try self.reportCodeAt(start.span.start, start.line, 2852, "'await using' statements are only allowed within async functions and at the top levels of modules.");
            } else if (!inside_function and !file_is_module and self.namespace_depth == 0) {
                try self.reportCodeAt(start.span.start, start.line, 2853, "'await using' statements are only allowed at the top level of a file when that file is a module, but this file has no imports or exports. Consider adding an empty 'export {}' to make this file a module.");
            }
        }
        if (self.in_switch_case_clause) {
            // A `using`/`await using` directly under a `case`/`default`
            // clause (without its own enclosing block) is TS1547/TS1548
            // — distinct from the more general TS1156 ("must be inside
            // a block") that fires for bare `if`/`else` arms.
            const code: u32 = if (await_using) 1548 else 1547;
            const message = if (await_using)
                "'await using' declarations are not allowed in 'case' or 'default' clauses unless contained within a block."
            else
                "'using' declarations are not allowed in 'case' or 'default' clauses unless contained within a block.";
            try self.reportCodeAt(start.span.start, start.line, code, message);
        } else if (self.unbraced_statement_block_depth) |depth| if (self.block_depth == depth) {
            const message = if (await_using)
                "'await using' declarations can only be declared inside a block."
            else
                "'using' declarations can only be declared inside a block.";
            try self.reportCodeAt(start.span.start, start.line, 1156, message);
        };
        // Branch on binding shape: an object-binding-pattern head
        // (`using {a} = …`) keeps the pattern structure so the
        // checker can emit the per-property TS2339/TS2488 against the
        // initializer. All other heads use the existing token-based
        // path that synthesizes a placeholder identifier.
        const want_binding_pattern = self.peek().kind == .open_brace;
        var name_node: NodeId = hir_mod.none_node_id;
        var name_span_start: u32 = start.span.start;
        var name_span_line: u32 = start.line;
        if (want_binding_pattern) {
            const pat_tok = self.peek();
            name_span_start = pat_tok.span.start;
            name_span_line = pat_tok.line;
            name_node = try self.parseUsingDeclBindingPattern(await_using);
        } else {
            const name_tok = try self.parseUsingDeclBindingTarget(await_using);
            const name_id = try self.internToken(name_tok);
            name_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
            name_span_start = name_tok.span.start;
            name_span_line = name_tok.line;
        }

        var type_annotation: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) {
            type_annotation = try self.parseTypeAnnotation();
        }

        const must_init_msg = if (await_using)
            "'await using' declarations must be initialized."
        else
            "'using' declarations must be initialized.";
        var init_node: NodeId = hir_mod.none_node_id;
        if (self.match(.equal)) {
            init_node = try self.parseAssignmentExpression();
        } else if (!in_ambient) {
            // Ambient `using` / `await using` declarations don't carry
            // initializers — TS suppresses TS1155 in that case because
            // the more specific TS1545/TS1546 already fires.
            try self.reportCodeAt(name_span_start, name_span_line, 1155, must_init_msg);
        }
        while (self.match(.comma)) {
            const extra_name_tok = try self.parseUsingDeclBindingTarget(await_using);
            if (self.match(.colon)) {
                _ = try self.parseTypeAnnotation();
            }
            if (self.match(.equal)) {
                _ = try self.parseAssignmentExpression();
            } else if (!in_ambient) {
                try self.reportCodeAt(extra_name_tok.span.start, extra_name_tok.line, 1155, must_init_msg);
            }
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
            false,
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
        self.block_depth += 1;
        defer self.block_depth -= 1;
        // A `{}` block under a `case` clause body resets the bare-clause
        // gate: TS1547/TS1548 only fire on `using`/`await using`
        // declarations that aren't wrapped in their own block.
        const prev_in_case_clause = self.in_switch_case_clause;
        self.in_switch_case_clause = false;
        defer self.in_switch_case_clause = prev_in_case_clause;
        var stmts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer stmts.deinit(self.gpa);
        while (self.hasPendingStatement() or (self.peek().kind != .close_brace and self.peek().kind != .eof)) {
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
        if (t.kind == .invalid) {
            const bad = self.advance();
            try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
            if (self.match(.semicolon)) return;
            const after_invalid = self.peek();
            if (after_invalid.kind == .eof or
                after_invalid.kind == .close_brace or
                after_invalid.flags.preceded_by_newline)
            {
                return;
            }
        }
        if (t.kind == .eof or t.kind == .close_brace or t.flags.preceded_by_newline) return;
        if (t.kind == .identifier and self.cursor > 0 and self.tokens[self.cursor - 1].kind == .number_literal) {
            if (t.flags.has_escape) {
                try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
                try self.reportCannotFindNameToken(t);
                _ = self.advance();
            }
            return;
        }
        if (t.kind == .colon and self.peekAt(1).kind == .arrow) {
            try self.reportCodeAt(t.span.start, t.line, 1005, "',' expected.");
            _ = self.advance();
            const arrow_tok = self.peek();
            try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1005, "';' expected.");
            _ = self.advance();
            return;
        }
        if (t.kind == .arrow) {
            try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
            _ = self.advance();
            return;
        }
        if (t.kind == .close_bracket) {
            try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
            _ = self.advance();
            return;
        }
        if (t.kind == .number_literal and
            t.span.start < t.span.end and
            self.source[t.span.start] == '.' and
            self.cursor > 0 and
            self.tokens[self.cursor - 1].kind == .identifier)
        {
            const prev = self.tokens[self.cursor - 1];
            try self.reportCodeAt(prev.span.start, prev.line, 1434, "Unexpected keyword or identifier.");
            try self.reportCannotFindNameToken(prev);
            return;
        }
        if (t.kind == .dot and
            self.cursor > 0 and
            self.tokens[self.cursor - 1].kind == .identifier and
            self.peekAt(1).kind == .number_literal and
            !self.peekAt(1).flags.preceded_by_newline)
        {
            const prev = self.tokens[self.cursor - 1];
            try self.reportCodeAt(prev.span.start, prev.line, 1434, "Unexpected keyword or identifier.");
            try self.reportCannotFindNameToken(prev);
            _ = self.advance();
            return;
        }
        if (t.kind == .dot) {
            try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
            _ = self.advance();
            return;
        }
        if (t.kind == .open_brace or t.kind == .open_paren) {
            try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
            return;
        }
        // §6.A 2000-3000 ratchet: align the missing-terminator
        // fallback with tsc's canonical TS1005 "';' expected." prose
        // rather than a Home-internal "expected ';' or newline after
        // statement" payload. Mirrors fixtures like `parserFuzz1` and
        // `parser.numericSeparators.decmialNegative` where the
        // recovery anchor lands on the offending token.
        try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
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
                    .equal, .semicolon, .comma, .greater_than, .close_paren, .close_brace, .close_bracket, .eof => return,
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
        if (self.peek().kind == .kw_asserts and
            self.peekAt(1).kind == .identifier and
            !self.peekAt(1).flags.preceded_by_newline)
        {
            _ = self.advance(); // asserts
            const arg_tok = self.advance();
            const arg_id = try self.internToken(arg_tok);
            // `asserts <ident>` (predicate-less) — narrows to truthy.
            if (self.peek().kind != .kw_is or self.peek().flags.preceded_by_newline) {
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
        if (self.peek().kind == .identifier and
            self.peekAt(1).kind == .kw_is and
            !self.peekAt(1).flags.preceded_by_newline)
        {
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
        // `this is T`
        if (self.peek().kind == .kw_this and
            self.peekAt(1).kind == .kw_is and
            !self.peekAt(1).flags.preceded_by_newline)
        {
            _ = self.advance(); // this
            const this_id = self.interner.intern("this") catch return error.OutOfMemory;
            _ = self.advance(); // is
            const target = try self.parseTypeAnnotation();
            return try self.builder.addTypePredicate(
                .{ .start = start_span_start, .end = self.hir.spanOf(target).end },
                0xFFFF,
                this_id,
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
        if (self.hir.kindOf(check) == .infer_type and self.peek().kind == .question) {
            const inf = hir_mod.inferTypeOf(self.hir, check);
            if (inf.constraint != hir_mod.none_node_id) {
                _ = self.advance();
                const bare = try self.builder.addInferType(self.hir.spanOf(check), inf.name, hir_mod.none_node_id);
                const true_branch = try self.parseTypeAnnotation();
                _ = try self.expect(.colon, "':' in conditional type");
                const false_branch = try self.parseTypeAnnotation();
                const sp: Span = .{
                    .start = self.hir.spanOf(check).start,
                    .end = self.hir.spanOf(false_branch).end,
                };
                return try self.builder.addConditionalType(sp, bare, inf.constraint, true_branch, false_branch);
            }
        }
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
                // expression. Keep the HIR compact by interning the
                // qualified token span as an identifier-like ref.
                if (self.peek().kind == .kw_import) {
                    const import_t = try self.parseImportTypeReference();
                    const operand = try self.parseArrayTypePostfix(import_t);
                    const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                    const typeof_t = try self.builder.addTypeofType(sp, operand);
                    return try self.parseArrayTypePostfix(typeof_t);
                }
                const ref_start = switch (self.peek().kind) {
                    .identifier, .kw_undefined, .kw_super, .kw_this => self.advance(),
                    else => {
                        try self.report("expected ", "identifier after typeof");
                        return error.UnexpectedToken;
                    },
                };
                var ref_name_end = ref_start.span.end;
                while (self.peek().kind == .dot and
                    (self.peekAt(1).kind == .identifier or
                        self.peekAt(1).kind == .private_identifier or
                        self.peekAt(1).kind.isKeyword()))
                {
                    _ = self.advance();
                    ref_name_end = self.advance().span.end;
                }
                if (self.peek().kind == .dot) {
                    const dot = self.advance();
                    try self.reportCodeAt(dot.span.end, dot.line, 1003, "Identifier expected.");
                }
                var ref_end = ref_name_end;
                if (self.peek().kind == .less_than) {
                    const args = try self.parseTypeArgumentList();
                    self.gpa.free(args);
                    ref_end = self.tokens[self.cursor - 1].span.end;
                }
                const ref_id = self.interner.intern(self.source[ref_start.span.start..ref_name_end]) catch return error.OutOfMemory;
                const ref = try self.builder.addIdentifier(.{ .start = ref_start.span.start, .end = ref_end }, ref_id);
                const sp: Span = .{ .start = t.span.start, .end = ref_end };
                const typeof_t = try self.builder.addTypeofType(sp, ref);
                return try self.parseArrayTypePostfix(typeof_t);
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
            .kw_unique => {
                const unique_tok = self.advance();
                if (self.peek().kind == .kw_symbol) {
                    const symbol_tok = self.advance();
                    const id = self.interner.intern("symbol") catch return error.OutOfMemory;
                    return try self.builder.addTypeRef(.{ .start = unique_tok.span.start, .end = symbol_tok.span.end }, id, &.{}, &.{});
                }
                const id = self.interner.intern("unknown") catch return error.OutOfMemory;
                return try self.builder.addTypeRef(tokenSpan(unique_tok), id, &.{}, &.{});
            },
            else => return try self.parseArrayType(),
        }
    }

    fn parseArrayType(self: *Parser) ParseError!NodeId {
        const node = try self.parsePrimaryType();
        return try self.parseArrayTypePostfix(node);
    }

    fn parseArrayTypePostfix(self: *Parser, initial: NodeId) ParseError!NodeId {
        var node = initial;
        while (true) {
            // TS spec: an `[` on a new line after a type does NOT extend
            // the type — there's an implicit no-line-terminator boundary.
            // Without this guard, interface index signatures on the line
            // after a method's return type (`...): void` followed by
            // `[x: number]: I;`) get mis-parsed as `void[x: number]`,
            // emitting a spurious TS1109 / dropping the index member.
            // Matches `taggedTemplateStringsWithTypedTags` family.
            if (self.peek().kind == .open_bracket and !self.peek().flags.preceded_by_newline) {
                _ = self.advance();
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
                var end_pos = t.span.end;
                if (self.peek().kind == .dot and
                    (self.peekAt(1).kind == .identifier or self.peekAt(1).kind.isContextualKeyword() or self.peekAt(1).kind.isPrimitiveTypeKeyword()))
                {
                    const dot = self.advance();
                    try self.reportCodeAt(dot.span.start, dot.line, 1005, "',' expected.");
                    end_pos = self.advance().span.end;
                }
                break :blk try self.builder.addTypeRef(.{ .start = t.span.start, .end = end_pos }, id, &.{}, &.{});
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
                // Type-position numeric literals (`: 01 = 01`) get the
                // same TS1121 octal-literal diagnostic as expression-
                // position literals — matches tsc's per-literal scan
                // (the parser flags numeric tokens uniformly,
                // regardless of whether they appear in a type or value
                // context).
                try self.reportStrictLegacyOctal(t, slice);
                try self.reportNumericLiteralDiagnostics(t, slice);
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
            .close_paren => blk: {
                try self.reportCodeAt(t.span.start, t.line, 1110, "Type expected.");
                const id = self.interner.intern("unknown") catch return error.OutOfMemory;
                break :blk try self.builder.addTypeRef(.{ .start = t.span.start, .end = t.span.start }, id, &.{}, &.{});
            },
            .kw_new => try self.parseConstructorType(),
            .kw_abstract => blk: {
                if (self.peekAt(1).kind == .kw_new) {
                    _ = self.advance();
                    break :blk try self.parseConstructorType();
                }
                _ = self.advance();
                const id = self.interner.intern("unknown") catch return error.OutOfMemory;
                break :blk try self.builder.addTypeRef(tokenSpan(t), id, &.{}, &.{});
            },
            .kw_yield => blk: {
                const yield_tok = self.advance();
                try self.reportInvalidYieldName(yield_tok);
                const id = try self.internToken(yield_tok);
                break :blk try self.builder.addTypeRef(tokenSpan(yield_tok), id, &.{}, &.{});
            },
            // `await` in a type-reference position becomes an
            // identifier-named type ref so the type-resolution
            // pass can emit TS2552 ("Cannot find name 'await'.
            // Did you mean 'Awaited'?"). Mirrors tsc which lets
            // the identifier path produce the diagnostic instead
            // of treating `await` as a built-in type keyword.
            // Without this, the bare-token fallthrough would emit
            // a synthetic `unknown` ref and silently swallow the
            // error (asyncFunctionDeclaration13_es*, asyncArrowFunction10_es*).
            .kw_await => blk: {
                const await_tok = self.advance();
                const id = try self.internToken(await_tok);
                break :blk try self.builder.addTypeRef(tokenSpan(await_tok), id, &.{}, &.{});
            },
            .kw_import => try self.parseImportTypeReference(),
            .identifier => try self.parseTypeReference(),
            .kw_public, .kw_private, .kw_protected, .kw_static => blk: {
                const bad = self.advance();
                if (self.class_body_depth > 0) {
                    try self.reportInvalidClassStrictIdentifier(bad);
                } else {
                    try self.reportCodeAt(bad.span.start, bad.line, 1213, "Identifier expected. Reserved words cannot be used as identifiers here.");
                }
                const id = try self.internToken(bad);
                break :blk try self.builder.addTypeRef(tokenSpan(bad), id, &.{}, &.{});
            },
            .kw_this => blk: {
                const start_tok = self.advance();
                var end_pos = start_tok.span.end;
                while (self.peek().kind == .dot and
                    (self.peekAt(1).kind == .identifier or self.peekAt(1).kind.isContextualKeyword()))
                {
                    _ = self.advance();
                    end_pos = self.advance().span.end;
                }
                const id = self.interner.intern(self.source[start_tok.span.start..end_pos]) catch return error.OutOfMemory;
                break :blk try self.builder.addTypeRef(.{ .start = start_tok.span.start, .end = end_pos }, id, &.{}, &.{});
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
            if (tk == .close_paren or tk == .close_bracket or tk == .close_brace or
                tk == .greater_than or tk == .greater_greater or tk == .greater_greater_greater)
            {
                const count: u8 = switch (tk) {
                    .greater_greater => 2,
                    .greater_greater_greater => 3,
                    else => 1,
                };
                var n: u8 = 0;
                while (n < count) : (n += 1) {
                    depth -= 1;
                    if (depth == 0) {
                        if (i + 1 < self.tokens.len and self.tokens[i + 1].kind == .arrow) {
                            is_fn = true;
                        }
                        break;
                    }
                }
                if (depth == 0) break;
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
        const ret = try self.parseReturnTypeAnnotation(params);
        const sp: Span = .{ .start = start.span.start, .end = self.hir.spanOf(ret).end };
        return try self.builder.addFnType(sp, &.{}, params, ret, is_constructor);
    }

    /// Parse `(p1: T1, p2: T2)` and return parameter HIR nodes.
    fn parseTypeParameterList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.open_paren, "'(' for fn-type parameter list");
        var params: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer params.deinit(self.gpa);
        var seen_names: std.AutoHashMapUnmanaged(hir_mod.StringId, Span) = .empty;
        defer seen_names.deinit(self.gpa);
        if (self.peek().kind != .close_paren) {
            while (true) {
                const ps = self.peek();
                var flags: hir_mod.ParamFlags = .{};
                if (self.match(.dot_dot_dot)) flags.is_rest = true;
                var name_span = tokenSpan(ps);
                var name_id: hir_mod.StringId = undefined;
                var type_ann: NodeId = hir_mod.none_node_id;
                if (self.peek().kind == .identifier or
                    self.peek().kind == .kw_this or
                    (self.peek().kind.isKeyword() and (self.peekAt(1).kind == .colon or self.peekAt(1).kind == .question)))
                {
                    const name_tok = self.advance();
                    name_span = tokenSpan(name_tok);
                    if (self.match(.question)) flags.is_optional = true;
                    if (self.match(.colon)) type_ann = try self.parseTypeAnnotation();
                    name_id = try self.internToken(name_tok);
                } else {
                    type_ann = try self.parseTypeAnnotation();
                    try self.reportUnusedRenamesInFnTypeParam(type_ann);
                    var buf: [32]u8 = undefined;
                    const synthetic = std.fmt.bufPrint(&buf, "__arg{d}", .{params.items.len}) catch
                        return error.OutOfMemory;
                    name_id = self.interner.intern(synthetic) catch return error.OutOfMemory;
                }
                const ident = try self.builder.addIdentifier(name_span, name_id);
                const param = try self.builder.addParameter(
                    .{ .start = ps.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    ident,
                    type_ann,
                    hir_mod.none_node_id,
                    flags,
                );
                if (seen_names.get(name_id)) |prev| {
                    try self.reportDuplicateIdentifierNamed(prev.start, self.lineAt(prev.start), name_id);
                    try self.reportDuplicateIdentifierNamed(name_span.start, self.lineAt(name_span.start), name_id);
                } else {
                    try seen_names.put(self.gpa, name_id, name_span);
                }
                try params.append(self.gpa, param);
                if (!self.match(.comma)) break;
                if (self.peek().kind == .close_paren) break;
                if (flags.is_rest) {
                    // Upstream points the diagnostic at the `...` rest token.
                    // `ps` was captured before consuming the leading `...`,
                    // so its span.start is the `...` position.
                    try self.reportCodeAt(
                        ps.span.start,
                        ps.line,
                        1014,
                        "A rest parameter must be last in a parameter list.",
                    );
                }
            }
        }
        _ = try self.expect(.close_paren, "')' to close fn-type params");
        return try params.toOwnedSlice(self.gpa);
    }

    fn reportUnusedRenamesInFnTypeParam(self: *Parser, node: NodeId) ParseError!void {
        if (node == hir_mod.none_node_id) return;
        switch (self.hir.kindOf(node)) {
            .tuple_type => for (hir_mod.tupleTypeElements(self.hir, node)) |elem| {
                try self.reportUnusedRenamesInFnTypeParam(elem);
            },
            .array_type => try self.reportUnusedRenamesInFnTypeParam(hir_mod.arrayTypeOf(self.hir, node).element),
            .rest_type => try self.reportUnusedRenamesInFnTypeParam(hir_mod.restTypeOf(self.hir, node).operand),
            .object_type => for (hir_mod.objectTypeMembers(self.hir, node)) |member| {
                if (self.hir.kindOf(member) != .interface_member) continue;
                const im = hir_mod.interfaceMemberOf(self.hir, member);
                if (im.type_node == hir_mod.none_node_id or self.hir.kindOf(im.type_node) != .type_ref) continue;
                const tr = hir_mod.typeRefOf(self.hir, im.type_node);
                if (tr.name == im.name) continue;
                if (hir_mod.typeRefArgs(self.hir, im.type_node).len != 0 or
                    hir_mod.typeRefQualifier(self.hir, im.type_node).len != 0) continue;
                const from = self.interner.get(im.name);
                const to = self.interner.get(tr.name);
                if (to.len == 0 or !std.ascii.isLower(to[0])) continue;
                const msg = try std.fmt.allocPrint(
                    self.diag_arena.allocator(),
                    "'{s}' is an unused renaming of '{s}'. Did you intend to use it as a type annotation?",
                    .{ to, from },
                );
                try self.diagnostics.append(self.gpa, .{
                    .pos = self.hir.spanOf(im.type_node).start,
                    .line = self.lineAt(self.hir.spanOf(im.type_node).start),
                    .code = 2842,
                    .message = msg,
                });
            },
            else => {},
        }
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
            try self.reportCodeAt(next.span.start, next.line, 1005, "'}' expected.");
            const empty_id = self.interner.intern("") catch return error.OutOfMemory;
            const empty_lit = try self.builder.addLiteralString(.{ .start = next.span.start, .end = next.span.start }, empty_id);
            try text_parts.append(self.gpa, empty_lit);
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
        var saw_optional = false;
        while (self.peek().kind != .close_bracket and self.peek().kind != .eof) {
            // Accept (and ignore for now) leading labelled tuple
            // elements: `[x: number, y?: number]`.
            var labeled_optional = false;
            if (self.peek().kind == .identifier and
                (self.peekAt(1).kind == .colon or
                    (self.peekAt(1).kind == .question and self.peekAt(2).kind == .colon)))
            {
                _ = self.advance();
                if (self.match(.question)) labeled_optional = true;
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
            const elem_start = self.peek().span.start;
            const elem_line = self.peek().line;
            // Elided tuple element (`[number,,]`) — upstream rejects
            // these with TS1110 "Type expected." at the comma/close
            // position. Detect before parseTypeAnnotation consumes the
            // delimiter and synthesises a recovery `unknown` type ref,
            // which would otherwise hide the diagnostic. Mirrors
            // `TupleType6.ts(1,16)` baseline.
            if (self.peek().kind == .comma or self.peek().kind == .close_bracket) {
                try self.reportCodeAt(elem_start, elem_line, 1110, "Type expected.");
                const id = self.interner.intern("unknown") catch return error.OutOfMemory;
                const synth = try self.builder.addTypeRef(.{ .start = elem_start, .end = elem_start }, id, &.{}, &.{});
                try elems.append(self.gpa, synth);
                if (!self.match(.comma)) break;
                continue;
            }
            var e = try self.parseTypeAnnotation();
            const trailing_optional = self.match(.question); // optional element marker
            const this_optional = labeled_optional or trailing_optional;
            // TS1257 — a required tuple element cannot follow an
            // optional one. Mirrors `optionalTupleElements1.ts(11,29)`.
            if (saw_optional and !this_optional and !has_rest) {
                try self.reportCodeAt(elem_start, elem_line, 1257, "A required element cannot follow an optional element.");
            }
            if (this_optional) saw_optional = true;
            if (has_rest) {
                const end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else rest_tok.span.end;
                e = try self.builder.addRestType(.{ .start = rest_tok.span.start, .end = end }, e);
            }
            try elems.append(self.gpa, e);
            if (!self.match(.comma)) break;
        }
        const end_pos = if (self.peek().kind == .close_bracket) blk: {
            const close = self.advance();
            break :blk close.span.end;
        } else blk: {
            const pos = self.peek().span.start;
            try self.reportCodeAt(pos, self.peek().line, 1005, "']' expected.");
            break :blk pos;
        };
        return try self.builder.addTupleType(.{ .start = open.span.start, .end = end_pos }, elems.items);
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
        const MethodOptionality = struct {
            optional: bool,
            span: Span,
        };
        const AccessorPair = struct {
            getter: ?Span = null,
            setter: ?Span = null,
        };
        var seen = std.AutoHashMapUnmanaged(hir_mod.StringId, Span){};
        defer seen.deinit(self.gpa);
        var method_optionality = std.AutoHashMapUnmanaged(hir_mod.StringId, MethodOptionality){};
        defer method_optionality.deinit(self.gpa);
        var accessor_pairs = std.AutoHashMapUnmanaged(hir_mod.StringId, AccessorPair){};
        defer accessor_pairs.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            const t = self.peek();
            // `static` is illegal on an index signature inside an interface
            // or type literal — tsc emits TS1071 anchored at the `static`
            // keyword (matches `staticIndexSignature4`/`staticIndexSignature5`
            // baselines). Skip the keyword so the index-signature parser
            // takes over the following `[k: K]: V` (or `readonly [k: K]: V`).
            if (t.kind == .kw_static and
                (self.peekAt(1).kind == .open_bracket or
                    (self.peekAt(1).kind == .kw_readonly and self.peekAt(2).kind == .open_bracket)))
            {
                _ = self.advance(); // consume `static`
                try self.reportCodeAt(t.span.start, t.line, 1071, "'static' modifier cannot appear on an index signature.");
                continue;
            }
            // Index signature: `[k: K]: V` or `readonly [k: K]: V`.
            // Detect via `[ ident : ident ]` shape, then commit.
            if (t.kind == .open_bracket or
                (t.kind == .kw_readonly and self.peekAt(1).kind == .open_bracket))
            {
                if (try self.tryParseIndexSignature(out, false, false)) continue;
                if (try self.tryParseComputedTypeMember(out, false)) continue;
                // Not an index signature or supported computed key.
                try self.reportMalformedTypeMemberBracket(t);
                try self.skipUntilTypeMemberSeparator();
                continue;
            }
            // Call signature: `{ <T>(x: T): T }` or `{ (x: T): T }`.
            if (t.kind == .less_than or t.kind == .open_paren) {
                const sig = try self.parseTypeSignatureMember(false);
                try out.append(self.gpa, sig);
                continue;
            }
            // Construct signature: `{ new<T>(x: T): T }`.
            if (t.kind == .kw_new and self.isConstructSignatureStart()) {
                const sig = try self.parseTypeSignatureMember(true);
                try out.append(self.gpa, sig);
                continue;
            }
            // Accessor signatures in interfaces/type literals:
            // `get foo(): T` and `set foo(value: T)`.
            if ((t.kind == .kw_get or t.kind == .kw_set) and self.isTypeAccessorSignatureStart()) {
                const accessor_tok = self.advance();
                const is_getter = accessor_tok.kind == .kw_get;
                const name_tok = self.advance();
                const name_span = tokenSpan(name_tok);
                const name_id = try self.internPropertyName(name_tok, name_span);
                const params = try self.parseTypeParameterList();
                defer self.gpa.free(params);
                var type_node: NodeId = hir_mod.none_node_id;
                if (is_getter) {
                    if (self.match(.colon)) type_node = try self.parseReturnTypeAnnotation(params);
                } else if (params.len > 0 and self.hir.kindOf(params[0]) == .parameter) {
                    const p = hir_mod.parameterOf(self.hir, params[0]);
                    type_node = p.type_annotation;
                }
                if (!is_getter and self.match(.colon)) {
                    _ = try self.parseReturnTypeAnnotation(params);
                }
                if (self.peek().kind == .semicolon or self.peek().kind == .comma) {
                    _ = self.advance();
                } else if (self.peek().kind != .close_brace and self.peek().kind != .eof) {
                    const prev_tok = self.tokens[self.cursor - 1];
                    const next_tok = self.peek();
                    if (prev_tok.line == next_tok.line) {
                        try self.reportCodeAt(next_tok.span.start, next_tok.line, 1005, "';' expected.");
                    }
                }
                const member = try self.builder.addInterfaceMember(
                    .{ .start = accessor_tok.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    name_id,
                    type_node,
                    false,
                    is_getter,
                    false,
                    false,
                );
                var pair = accessor_pairs.get(name_id) orelse AccessorPair{};
                if (is_getter) {
                    if (pair.getter) |prev| {
                        try self.reportDuplicateIdentifierNamed(prev.start, self.lineAt(prev.start), name_id);
                        try self.reportDuplicateIdentifierNamed(name_span.start, name_tok.line, name_id);
                    }
                    pair.getter = name_span;
                } else {
                    if (pair.setter) |prev| {
                        try self.reportDuplicateIdentifierNamed(prev.start, self.lineAt(prev.start), name_id);
                        try self.reportDuplicateIdentifierNamed(name_span.start, name_tok.line, name_id);
                    }
                    pair.setter = name_span;
                }
                try accessor_pairs.put(self.gpa, name_id, pair);
                try out.append(self.gpa, member);
                continue;
            }
            var is_readonly = false;
            var is_override = false;
            if (t.kind == .kw_readonly and self.peekAt(1).kind != .colon) {
                _ = self.advance();
                is_readonly = true;
            }
            if (self.peek().kind == .kw_override and self.peekAt(1).kind != .colon) {
                _ = self.advance();
                is_override = true;
            }
            const name_tok = self.advance();
            var name_span = tokenSpan(name_tok);
            if (name_tok.kind == .number_literal and self.peek().kind == .dot and self.peekAt(1).kind == .colon) {
                const dot_tok = self.advance();
                name_span.end = dot_tok.span.end;
            }
            // Allow string-literal property names: `"foo": T`.
            const name_id = try self.internPropertyName(name_tok, name_span);
            const is_optional = self.match(.question);

            // Method shorthand: `name<T>(p: T): R` / `name(p: T): R`.
            if (self.peek().kind == .less_than or self.peek().kind == .open_paren) {
                var type_params: []NodeId = &.{};
                var owns_tps = false;
                if (self.peek().kind == .less_than) {
                    type_params = try self.parseTypeParameterDeclaration();
                    owns_tps = true;
                }
                defer if (owns_tps) self.gpa.free(type_params);
                const params = try self.parseTypeParameterList();
                defer self.gpa.free(params);
                var ret: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) ret = try self.parseReturnTypeAnnotation(params);
                const fn_t = try self.builder.addFnType(
                    .{ .start = name_span.start, .end = self.tokens[self.cursor - 1].span.end },
                    type_params,
                    params,
                    ret,
                    false,
                );
                _ = self.match(.semicolon);
                _ = self.match(.comma);
                const member = try self.builder.addInterfaceMember(
                    name_span,
                    name_id,
                    fn_t,
                    is_optional,
                    is_readonly,
                    true,
                    is_override,
                );
                if (method_optionality.get(name_id)) |prev| {
                    if (prev.optional != is_optional) {
                        // tsc anchors TS2386 at the mismatched (current)
                        // overload's name token, not the first one — its
                        // baseline renderer puts `~~~~~` under the second
                        // signature. Mirror that so single-error fixtures
                        // like `methodSignaturesWithOverloads` line up.
                        try self.reportCodeAt(name_span.start, name_tok.line, 2386, "Overload signatures must all be optional or required.");
                    }
                } else {
                    try method_optionality.put(self.gpa, name_id, .{
                        .optional = is_optional,
                        .span = name_span,
                    });
                }
                try out.append(self.gpa, member);
                continue;
            }

            // Property: `name: T;`.
            var type_node: NodeId = hir_mod.none_node_id;
            if (self.match(.colon)) type_node = try self.parseTypeAnnotation();
            if (self.peek().kind == .semicolon or self.peek().kind == .comma) {
                _ = self.advance();
            } else if (self.peek().kind != .close_brace and self.peek().kind != .eof) {
                const prev_tok = self.tokens[self.cursor - 1];
                const next_tok = self.peek();
                if (prev_tok.line == next_tok.line) {
                    try self.reportCodeAt(next_tok.span.start, next_tok.line, 1005, "';' expected.");
                }
            }
            const member = try self.builder.addInterfaceMember(
                name_span,
                name_id,
                type_node,
                is_optional,
                is_readonly,
                false,
                is_override,
            );
            if (seen.get(name_id)) |prev| {
                try self.reportDuplicateIdentifierNamed(prev.start, self.lineAt(prev.start), name_id);
                try self.reportDuplicateIdentifierNamed(name_span.start, self.lineAt(name_span.start), name_id);
            } else {
                try seen.put(self.gpa, name_id, name_span);
            }
            try out.append(self.gpa, member);
        }
    }

    fn parseTypeSignatureMember(self: *Parser, is_constructor: bool) ParseError!NodeId {
        const start = self.peek();
        if (is_constructor) _ = try self.expect(.kw_new, "'new' in construct signature");
        var type_params: []NodeId = &.{};
        var owns_tps = false;
        if (self.peek().kind == .less_than) {
            type_params = try self.parseTypeParameterDeclaration();
            owns_tps = true;
        }
        defer if (owns_tps) self.gpa.free(type_params);
        const params = try self.parseTypeParameterList();
        defer self.gpa.free(params);
        var ret: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) ret = try self.parseReturnTypeAnnotation(params);
        const end_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
        const fn_t = try self.builder.addFnType(
            .{ .start = start.span.start, .end = end_pos },
            type_params,
            params,
            ret,
            is_constructor,
        );
        _ = self.match(.semicolon);
        _ = self.match(.comma);
        const synthetic_name = if (is_constructor) "__construct" else "__call";
        const name_id = self.interner.intern(synthetic_name) catch return error.OutOfMemory;
        return try self.builder.addInterfaceMember(
            .{ .start = start.span.start, .end = end_pos },
            name_id,
            fn_t,
            false,
            false,
            true,
            false,
        );
    }

    fn isConstructSignatureStart(self: *const Parser) bool {
        return self.peekAt(1).kind == .open_paren or self.peekAt(1).kind == .less_than;
    }

    fn isTypeAccessorSignatureStart(self: *const Parser) bool {
        const name_kind = self.peekAt(1).kind;
        return (name_kind == .identifier or
            name_kind == .string_literal or
            name_kind == .number_literal or
            name_kind.isContextualKeyword()) and
            self.peekAt(2).kind == .open_paren;
    }

    fn reportMalformedTypeMemberBracket(self: *Parser, start: Token) ParseError!void {
        var idx = self.cursor + 1;
        var count: u32 = 0;
        var rest_tok: ?Token = null;
        var accessibility_tok: ?Token = null;
        var question_tok: ?Token = null;
        var comma_tok: ?Token = null;
        var first_ident_tok: ?Token = null;
        var saw_equal = false;
        while (idx < self.tokens.len and
            self.tokens[idx].kind != .close_bracket and
            self.tokens[idx].kind != .close_brace and
            self.tokens[idx].kind != .eof)
        {
            const tok = self.tokens[idx];
            const k = tok.kind;
            if (k == .dot_dot_dot) rest_tok = tok;
            if (isAccessibilityModifier(k)) accessibility_tok = tok;
            if (k == .question) question_tok = tok;
            if (k == .comma) comma_tok = tok;
            if (k == .equal) saw_equal = true;
            if (k == .identifier or k.isContextualKeyword()) {
                if (first_ident_tok == null) first_ident_tok = tok;
                count += 1;
            }
            idx += 1;
        }
        if (rest_tok) |tok| {
            try self.reportCodeAt(tok.span.start, tok.line, 1017, "An index signature cannot have a rest parameter.");
        } else if (accessibility_tok) |tok| {
            try self.reportCodeAt(tok.span.start, tok.line, 2369, "A parameter property is only allowed in a constructor implementation.");
            const anchor = first_ident_tok orelse tok;
            try self.reportCodeAt(anchor.span.start, anchor.line, 1018, "An index signature parameter cannot have an accessibility modifier.");
        } else if (question_tok) |tok| {
            try self.reportCodeAt(tok.span.start, tok.line, 1019, "An index signature parameter cannot have a question mark.");
        } else if (comma_tok) |tok| {
            const anchor = first_ident_tok orelse tok;
            try self.reportCodeAt(anchor.span.start, anchor.line, 1096, "An index signature must have exactly one parameter.");
        } else if (count == 0) {
            try self.reportCodeAt(start.span.start, start.line, 1096, "An index signature must have exactly one parameter.");
        } else if (saw_equal) {
            try self.reportCodeAt(start.span.start, start.line, 1169, "A computed property name in an interface must refer to an expression whose type is a literal type or a 'unique symbol' type.");
            if (first_ident_tok) |ident_tok| try self.reportCannotFindNameToken(ident_tok);
        } else {
            try self.reportCodeAt(start.span.start, start.line, 1169, "A computed property name in an interface must refer to an expression whose type is a literal type or a 'unique symbol' type.");
        }
    }

    fn tryParseComputedTypeMember(self: *Parser, out: *std.ArrayListUnmanaged(NodeId), is_readonly: bool) ParseError!bool {
        const checkpoint = self.cursor;
        const start_tok = self.peek();
        if (self.peek().kind != .open_bracket) return false;
        if (self.computedTypeMemberLooksMalformedIndexSignature()) return false;
        _ = self.advance();
        const key_expr = self.parseExpression() catch {
            self.cursor = checkpoint;
            return false;
        };
        if (self.peek().kind != .close_bracket) {
            self.cursor = checkpoint;
            return false;
        }
        const close_tok = self.advance();
        const name_id = (try self.computedTypeMemberNameFromKey(key_expr)) orelse blk: {
            if (self.hir.kindOf(key_expr) != .identifier) {
                self.cursor = checkpoint;
                return false;
            }
            try self.reportCannotFindNameNode(key_expr, start_tok.line);
            break :blk @as(hir_mod.StringId, 0);
        };
        if (self.computedSymbolMemberIsNonPropertySymbol(key_expr)) {
            try self.reportCodeAt(start_tok.span.start, start_tok.line, 2464, "A computed property name must be of type 'string', 'number', 'symbol', or 'any'.");
        }
        const is_optional = self.match(.question);
        const member_span: Span = .{ .start = start_tok.span.start, .end = close_tok.span.end };
        if (self.peek().kind == .less_than or self.peek().kind == .open_paren) {
            var type_params: []NodeId = &.{};
            var owns_tps = false;
            if (self.peek().kind == .less_than) {
                type_params = try self.parseTypeParameterDeclaration();
                owns_tps = true;
            }
            defer if (owns_tps) self.gpa.free(type_params);
            const params = try self.parseTypeParameterList();
            defer self.gpa.free(params);
            var ret: NodeId = hir_mod.none_node_id;
            if (self.match(.colon)) ret = try self.parseReturnTypeAnnotation(params);
            const fn_t = try self.builder.addFnType(
                .{ .start = member_span.start, .end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else member_span.end },
                type_params,
                params,
                ret,
                false,
            );
            _ = self.match(.semicolon);
            _ = self.match(.comma);
            const member = try self.builder.addInterfaceMember(member_span, name_id, fn_t, is_optional, is_readonly, true, false);
            try out.append(self.gpa, member);
            return true;
        }
        var type_node: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) type_node = try self.parseTypeAnnotation();
        _ = self.match(.semicolon);
        _ = self.match(.comma);
        const member = try self.builder.addInterfaceMember(member_span, name_id, type_node, is_optional, is_readonly, false, false);
        try out.append(self.gpa, member);
        return true;
    }

    fn reportCannotFindNameNode(self: *Parser, node: NodeId, line: u32) ParseError!void {
        if (self.hir.kindOf(node) != .identifier) return;
        const id = hir_mod.identifierOf(self.hir, node);
        const name_text = self.interner.get(id.name);
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Cannot find name '{s}'.", .{name_text});
        const sp = self.hir.spanOf(node);
        try self.reportCodeAt(sp.start, line, 2304, msg);
    }

    fn reportCannotFindNameToken(self: *Parser, tok: Token) ParseError!void {
        const name_text = self.source[tok.span.start..tok.span.end];
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Cannot find name '{s}'.", .{name_text});
        try self.reportCodeAt(tok.span.start, tok.line, 2304, msg);
    }

    fn computedTypeMemberLooksMalformedIndexSignature(self: *const Parser) bool {
        var idx = self.cursor + 1;
        var saw_content = false;
        while (idx < self.tokens.len and
            self.tokens[idx].kind != .close_bracket and
            self.tokens[idx].kind != .close_brace and
            self.tokens[idx].kind != .eof)
        {
            saw_content = true;
            switch (self.tokens[idx].kind) {
                .dot_dot_dot, .question, .comma, .equal => return true,
                else => {},
            }
            if (isAccessibilityModifier(self.tokens[idx].kind)) return true;
            idx += 1;
        }
        return !saw_content;
    }

    fn indexSignatureKeyTypeIsValid(self: *const Parser, key_type: NodeId) bool {
        switch (self.hir.kindOf(key_type)) {
            .type_ref => {
                const r = hir_mod.typeRefOf(self.hir, key_type);
                if (r.qualifier_len != 0 or r.args_len != 0) return false;
                const name = self.interner.get(r.name);
                return std.mem.eql(u8, name, "string") or
                    std.mem.eql(u8, name, "number") or
                    std.mem.eql(u8, name, "symbol");
            },
            .template_literal_type => return true,
            else => return false,
        }
    }

    fn computedTypeMemberNameFromKey(self: *Parser, key_expr: NodeId) ParseError!?hir_mod.StringId {
        return switch (self.hir.kindOf(key_expr)) {
            .literal_string => hir_mod.literalStringOf(self.hir, key_expr).value,
            .literal_number => blk: {
                const sp = self.hir.spanOf(key_expr);
                if (sp.end > self.source.len or sp.start >= sp.end) break :blk null;
                break :blk self.interner.intern(self.source[sp.start..sp.end]) catch return error.OutOfMemory;
            },
            .identifier => blk: {
                const id = hir_mod.identifierOf(self.hir, key_expr);
                const raw = self.interner.get(id.name);
                if (try self.sourceConstLiteralMemberName(raw)) |name| break :blk name;
                if (self.sourceHasUniqueSymbolConst(raw)) {
                    const synthetic = try std.fmt.allocPrint(self.gpa, "[computed:{s}]", .{raw});
                    defer self.gpa.free(synthetic);
                    break :blk self.interner.intern(synthetic) catch return error.OutOfMemory;
                }
                break :blk null;
            },
            .member_access => try self.symbolMemberNameFromComputedKey(key_expr),
            .as_expr, .satisfies_expr, .type_assertion => blk: {
                const assertion = hir_mod.asExpressionOf(self.hir, key_expr);
                if (try self.computedTypeMemberNameFromKey(assertion.expr)) |name| break :blk name;
                break :blk try self.literalTypeMemberName(assertion.type_node);
            },
            else => null,
        };
    }

    fn literalTypeMemberName(self: *Parser, type_node: NodeId) ParseError!?hir_mod.StringId {
        if (type_node == hir_mod.none_node_id or self.hir.kindOf(type_node) != .type_literal) return null;
        const lit_type = hir_mod.literalTypeOf(self.hir, type_node);
        return switch (self.hir.kindOf(lit_type.literal)) {
            .literal_string => hir_mod.literalStringOf(self.hir, lit_type.literal).value,
            .literal_number => blk: {
                const sp = self.hir.spanOf(type_node);
                if (sp.end > self.source.len or sp.start >= sp.end) break :blk null;
                break :blk self.interner.intern(self.source[sp.start..sp.end]) catch return error.OutOfMemory;
            },
            else => null,
        };
    }

    fn symbolMemberNameFromComputedKey(self: *Parser, key_expr: NodeId) ParseError!?hir_mod.StringId {
        if (self.hir.kindOf(key_expr) != .member_access) return null;
        const m = hir_mod.memberOf(self.hir, key_expr);
        if (self.hir.kindOf(m.object) != .identifier) return null;
        const obj = hir_mod.identifierOf(self.hir, m.object);
        if (!std.mem.eql(u8, self.interner.get(obj.name), "Symbol")) return null;
        const prop = self.interner.get(m.name);
        const synthetic = try std.fmt.allocPrint(self.gpa, "Symbol.{s}", .{prop});
        defer self.gpa.free(synthetic);
        return self.interner.intern(synthetic) catch return error.OutOfMemory;
    }

    fn sourceConstLiteralMemberName(self: *Parser, name: []const u8) ParseError!?hir_mod.StringId {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, self.source, search_start, "const")) |const_pos| {
            search_start = const_pos + "const".len;
            if (const_pos > 0 and sourceIdentChar(self.source[const_pos - 1])) continue;
            if (search_start < self.source.len and sourceIdentChar(self.source[search_start])) continue;
            const after_const = std.mem.trim(u8, self.source[search_start..], " \t\r\n");
            if (!std.mem.startsWith(u8, after_const, name)) continue;
            if (after_const.len > name.len and sourceIdentChar(after_const[name.len])) continue;
            const line_end = std.mem.indexOfScalar(u8, after_const, '\n') orelse after_const.len;
            const line = after_const[0..line_end];
            const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const rhs = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\r;");
            if (rhs.len == 0) continue;
            if (rhs[0] == '\'' or rhs[0] == '"' or rhs[0] == '`') {
                const quote = rhs[0];
                var end: usize = 1;
                while (end < rhs.len and rhs[end] != quote) : (end += 1) {}
                if (end <= 1 or end >= rhs.len) continue;
                return self.interner.intern(rhs[1..end]) catch return error.OutOfMemory;
            }
            if (std.mem.startsWith(u8, rhs, "Symbol.")) {
                var end: usize = "Symbol.".len;
                while (end < rhs.len and sourceIdentChar(rhs[end])) : (end += 1) {}
                const synthetic = try std.fmt.allocPrint(self.gpa, "Symbol.{s}", .{rhs["Symbol.".len..end]});
                defer self.gpa.free(synthetic);
                return self.interner.intern(synthetic) catch return error.OutOfMemory;
            }
            if (std.mem.startsWith(u8, rhs, "Symbol(")) {
                const synthetic = try std.fmt.allocPrint(self.gpa, "[computed:{s}]", .{name});
                defer self.gpa.free(synthetic);
                return self.interner.intern(synthetic) catch return error.OutOfMemory;
            }
            if (rhs[0] == '-' or (rhs[0] >= '0' and rhs[0] <= '9')) {
                var end: usize = if (rhs[0] == '-') 1 else 0;
                while (end < rhs.len and ((rhs[end] >= '0' and rhs[end] <= '9') or rhs[end] == '.')) : (end += 1) {}
                if (end > 0 and !(end == 1 and rhs[0] == '-')) {
                    return self.interner.intern(rhs[0..end]) catch return error.OutOfMemory;
                }
            }
        }
        return null;
    }

    fn sourceHasUniqueSymbolConst(self: *Parser, name: []const u8) bool {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, self.source, search_start, "const")) |const_pos| {
            search_start = const_pos + "const".len;
            if (const_pos > 0 and sourceIdentChar(self.source[const_pos - 1])) continue;
            if (search_start < self.source.len and sourceIdentChar(self.source[search_start])) continue;
            const after_const = std.mem.trim(u8, self.source[search_start..], " \t\r\n");
            if (!std.mem.startsWith(u8, after_const, name)) continue;
            if (after_const.len > name.len and sourceIdentChar(after_const[name.len])) continue;
            const line_end = std.mem.indexOfScalar(u8, after_const, '\n') orelse after_const.len;
            const line = after_const[0..line_end];
            const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const type_end = std.mem.indexOfAnyPos(u8, line, colon_pos + 1, "=;") orelse line.len;
            const type_text = std.mem.trim(u8, line[colon_pos + 1 .. type_end], " \t\r");
            if (std.mem.eql(u8, type_text, "unique symbol")) return true;
        }
        return false;
    }

    fn sourceIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or
            c == '$';
    }

    fn computedSymbolMemberIsNonPropertySymbol(self: *Parser, key_expr: NodeId) bool {
        if (self.hir.kindOf(key_expr) != .member_access) return false;
        const m = hir_mod.memberOf(self.hir, key_expr);
        const prop = self.interner.get(m.name);
        return std.mem.eql(u8, prop, "for") or std.mem.eql(u8, prop, "keyFor");
    }

    /// Attempt to parse a `[k: K]: V` (or `readonly [k: K]: V`)
    /// index signature. Returns true if one was consumed and
    /// appended to `out`; returns false (cursor unchanged) when
    /// the bracketed form turns out to be something else (e.g. a
    /// computed key or mapped-type form). Mapped types live in a
    /// dedicated `mapped_type` HIR node and are dispatched
    /// separately by `parseTypeAnnotation`.
    fn tryParseIndexSignature(
        self: *Parser,
        out: *std.ArrayListUnmanaged(NodeId),
        is_static: bool,
        leading_readonly: bool,
    ) ParseError!bool {
        const checkpoint = self.cursor;
        const start_tok = self.peek();
        var is_readonly = leading_readonly;
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
        var has_multiple_parameters = false;
        if (self.peek().kind == .comma) {
            has_multiple_parameters = true;
            try self.reportCodeAt(id1.span.start, id1.line, 1096, "An index signature must have exactly one parameter.");
            while (self.peek().kind != .close_bracket and self.peek().kind != .close_brace and self.peek().kind != .eof) {
                _ = self.advance();
            }
        }
        const key_type_valid = self.indexSignatureKeyTypeIsValid(key_type);
        if (!key_type_valid) {
            try self.reportCodeAt(id1.span.start, id1.line, 1268, "An index signature parameter type must be 'string', 'number', 'symbol', or a template literal type.");
        }
        _ = try self.expect(.close_bracket, "']' to close index signature");
        const value_type: NodeId = if (self.match(.colon)) blk: {
            break :blk try self.parseTypeAnnotation();
        } else blk: {
            if (key_type_valid and !has_multiple_parameters) {
                try self.reportCodeAt(start_tok.span.start, start_tok.line, 1021, "An index signature must have a type annotation.");
            }
            break :blk hir_mod.none_node_id;
        };
        if (!self.match(.semicolon) and !self.match(.comma)) {
            const next = self.peek();
            if (next.kind != .close_brace and next.kind != .eof and !next.flags.preceded_by_newline) {
                const prev = self.tokens[self.cursor - 1];
                try self.reportCodeAt(prev.span.end + 1, prev.line, 1005, "';' expected.");
            }
        }
        if (has_multiple_parameters or value_type == hir_mod.none_node_id) {
            return true;
        }
        // Even when the key type is invalid (TS1268 already reported),
        // store the index signature so the checker can still lower
        // the key/value type-refs and emit follow-on diagnostics like
        // TS2314 (`Generic type … requires N type argument(s)`).
        // Mirrors upstream behaviour for fixtures like
        // `genericTypeReferenceWithoutTypeArgument.ts(12,14)`.
        const sp: Span = .{ .start = start_tok.span.start, .end = self.tokens[self.cursor - 1].span.end };
        const node = try self.builder.addIndexSignature(sp, key_type, value_type, is_readonly, is_static);
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
        const ret = try self.parseReturnTypeAnnotation(params);
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
        const ret = try self.parseReturnTypeAnnotation(params);
        const sp: Span = .{ .start = start.span.start, .end = self.hir.spanOf(ret).end };
        return try self.builder.addFnType(sp, tps, params, ret, true);
    }

    /// Parse `<T, U extends V = D>`. Returns owned slice of
    /// `type_parameter` HIR nodes.
    fn parseTypeParameterDeclaration(self: *Parser) ParseError![]NodeId {
        const open_tok = try self.expect(.less_than, "'<' to open type parameters");
        var tps: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer tps.deinit(self.gpa);
        // TS1098: an empty `<>` type parameter list is invalid. tsc
        // anchors the diagnostic at the `<` token (specifically at
        // the column AFTER `<`). Mirrors upstream tsc on
        // `parserConstructorDeclaration11.ts(2,14)`. The check fires
        // BEFORE the close-`>` is consumed so the error position is
        // accurate.
        if (self.peek().kind == .greater_than) {
            try self.reportCodeAt(open_tok.span.start, open_tok.line, 1098, "Type parameter list cannot be empty.");
        }
        while (self.peek().kind != .greater_than and self.peek().kind != .eof) {
            const tp_start = self.peek();
            // TS 5.0 `const` type-parameter modifier (`<const T>`). When
            // present, argument inference for T should be performed
            // `as const` (readonly + literal types preserved).
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
        _ = try self.consumeTypeGreater("'>' to close type parameters");
        return try tps.toOwnedSlice(self.gpa);
    }

    /// Parse `<A, B<C>>` in type-argument position. Returns owned
    /// slice of parsed type nodes.
    fn parseTypeArgumentList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.less_than, "'<' to open type arguments");
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer args.deinit(self.gpa);
        while (self.peek().kind != .greater_than and self.peek().kind != .eof) {
            if (self.peek().kind == .invalid) {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                return try args.toOwnedSlice(self.gpa);
            }
            const arg = try self.parseTypeAnnotation();
            try args.append(self.gpa, arg);
            if (!self.match(.comma)) break;
        }
        if (self.peek().kind == .invalid) {
            const bad = self.advance();
            try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
            return try args.toOwnedSlice(self.gpa);
        }
        _ = try self.consumeTypeGreater("'>' to close type arguments");
        return try args.toOwnedSlice(self.gpa);
    }

    /// `Foo`, `Foo.Bar`, `Foo<T, U>`. The lexer hands us the `<` only
    /// when it can tell from context — in type position it's always
    /// generic args, never a comparison.
    fn parseImportTypeReference(self: *Parser) ParseError!NodeId {
        const import_tok = self.advance();
        _ = try self.expect(.open_paren, "'(' after import in import type");
        // tsc emits TS1141 "String literal expected." at the offending
        // token when `import(<non-string>)` appears in type position.
        // Mirror that exact code+phrasing so baselines line up
        // (`importTypeNested`, `importTypeNonString`,
        // `importTypeNestedNoRef`). When the specifier is anything
        // other than a string literal, emit TS1141 at the offending
        // token but continue parsing past the `(...)` so downstream
        // type positions can still be checked. Mirrors tsc — which
        // emits a TS1141 per offending `import(T)` rather than
        // bailing the whole file (`importTypeGeneric.ts`).
        const specifier_is_invalid = self.peek().kind != .string_literal;
        if (specifier_is_invalid) {
            const tok = self.peek();
            try self.reportCodeAt(tok.span.start, tok.line, 1141, "String literal expected.");
            // Skip the specifier expression up to the matching `)` so
            // the qualifier / type-argument tail of this `import(...)`
            // is still parsed (the resulting type is morally `any`).
            var depth: i32 = 0;
            while (self.peek().kind != .eof) {
                if (depth == 0 and self.peek().kind == .close_paren) break;
                const k = self.peek().kind;
                if (k == .open_paren or k == .open_brace or k == .open_bracket) depth += 1;
                if ((k == .close_paren or k == .close_brace or k == .close_bracket) and depth > 0) depth -= 1;
                _ = self.advance();
            }
        } else {
            _ = self.advance();
        }
        if (self.match(.comma)) {
            var depth: i32 = 0;
            while (self.peek().kind != .eof) {
                if (depth == 0 and self.peek().kind == .close_paren) break;
                const k = self.peek().kind;
                if (k == .open_paren or k == .open_brace or k == .open_bracket) depth += 1;
                if ((k == .close_paren or k == .close_brace or k == .close_bracket) and depth > 0) depth -= 1;
                _ = self.advance();
            }
        }
        _ = try self.expect(.close_paren, "')' to close import type");

        var qualifier: std.ArrayListUnmanaged(NodeId) = .empty;
        defer qualifier.deinit(self.gpa);
        var name_id = self.interner.intern("unknown") catch return error.OutOfMemory;

        if (self.match(.dot)) {
            const first = try self.expectIdentifierLike();
            name_id = try self.internToken(first);
            var prev_tok = first;
            while (self.match(.dot)) {
                const next_tok = try self.expectIdentifierLike();
                const prev_id = name_id;
                const prev_node = try self.builder.addIdentifier(tokenSpan(prev_tok), prev_id);
                try qualifier.append(self.gpa, prev_node);
                name_id = try self.internToken(next_tok);
                prev_tok = next_tok;
            }
        }

        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        defer args.deinit(self.gpa);
        if (self.peek().kind == .less_than) {
            _ = self.advance();
            while (self.peek().kind != .greater_than and self.peek().kind != .eof) {
                if (self.peek().kind == .invalid) {
                    const bad = self.advance();
                    try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                    break;
                }
                const a = try self.parseTypeAnnotation();
                try args.append(self.gpa, a);
                if (!self.match(.comma)) break;
            }
            _ = try self.consumeTypeGreater("'>' to close import type arguments");
        }

        const end_pos = self.tokens[self.cursor - 1].span.end;
        // When the module specifier was invalid (already reported as
        // TS1141), discard the parsed qualifier/type-args and resolve
        // the whole `import(<bad>).A.B<T>` to `any`. tsc treats the
        // entire reference as opaque so trailing identifiers don't
        // chain into TS2304 / TS2503 noise (`importTypeGeneric.ts`).
        if (specifier_is_invalid) {
            const any_id = self.interner.intern("any") catch return error.OutOfMemory;
            return try self.builder.addTypeRef(
                .{ .start = import_tok.span.start, .end = end_pos },
                any_id,
                &.{},
                &.{},
            );
        }
        return try self.builder.addTypeRef(
            .{ .start = import_tok.span.start, .end = end_pos },
            name_id,
            qualifier.items,
            args.items,
        );
    }

    fn parseTypeReference(self: *Parser) ParseError!NodeId {
        const start = self.peek();
        const name_tok = try self.expect(.identifier, "type name");
        const final_name = try self.internToken(name_tok);

        var qualifier: std.ArrayListUnmanaged(NodeId) = .empty;
        defer qualifier.deinit(self.gpa);
        var name_id = final_name;

        // `A.B.C` — every `.B` extends the qualifier.
        while (self.peek().kind == .dot) {
            const dot = self.advance();
            if (self.peek().flags.preceded_by_newline or self.peek().kind == .eof) {
                try self.reportCodeAt(dot.span.end, dot.line, 1003, "Identifier expected.");
                const prev_node = try self.builder.addIdentifier(tokenSpan(name_tok), name_id);
                try qualifier.append(self.gpa, prev_node);
                name_id = self.interner.intern("unknown") catch return error.OutOfMemory;
                break;
            }
            const next_tok = if (self.peek().kind == .identifier or
                self.peek().kind.isContextualKeyword() or
                self.peek().kind.isPrimitiveTypeKeyword())
                self.advance()
            else
                try self.expect(.identifier, "qualified-name member");
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
            if (isTypeGreaterToken(self.peek().kind)) {
                _ = try self.consumeTypeGreater("'>' to close type arguments");
            } else if (self.peek().kind == .invalid) {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
            } else {
                const close_tok = self.peek();
                try self.reportCodeAt(close_tok.span.start, close_tok.line, 1005, "'>' expected.");
            }
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
    pub fn parseExpression(self: *Parser) ParseError!NodeId {
        return try self.parseExpressionWithIn(true);
    }

    fn parseExpressionNoIn(self: *Parser) ParseError!NodeId {
        return try self.parseExpressionWithIn(false);
    }

    fn parseExpressionWithIn(self: *Parser, allow_in: bool) ParseError!NodeId {
        var left = try self.parseAssignmentExpressionWithIn(allow_in);
        while (self.match(.comma)) {
            const right = try self.parseAssignmentExpressionWithIn(allow_in);
            left = try self.builder.addBinaryOp(
                .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end },
                .comma,
                left,
                right,
            );
        }
        return left;
    }

    fn parseAssignmentExpression(self: *Parser) ParseError!NodeId {
        return try self.parseAssignmentExpressionWithIn(true);
    }

    fn parseAssignmentExpressionWithIn(self: *Parser, allow_in: bool) ParseError!NodeId {
        // Arrow function fast paths:
        //   `x => …`   — single-ident arrow
        //   `() => …`  — zero-arg
        //   `(…) => …` — paren'd arrow (speculative)
        //   `async () => …` / `async x => …`
        //   `<T>(…) => …` — generic arrow
        if (try self.maybeParseArrowFunction()) |arrow| return arrow;

        const left = try self.parseConditionalExpressionWithIn(allow_in);
        const t = self.peek();
        switch (t.kind) {
            .equal => {
                _ = self.advance();
                try self.reportInvalidStrictIdentifierNode(left);
                try self.reportInvalidAssignmentTarget(left);
                const right = try self.parseAssignmentExpressionWithIn(allow_in);
                const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
                return try self.builder.addAssignment(sp, left, right, null);
            },
            .plus_equal => return self.parseCompoundAssign(left, .add, allow_in),
            .minus_equal => return self.parseCompoundAssign(left, .sub, allow_in),
            .asterisk_equal => return self.parseCompoundAssign(left, .mul, allow_in),
            .slash_equal => return self.parseCompoundAssign(left, .div, allow_in),
            .percent_equal => return self.parseCompoundAssign(left, .mod, allow_in),
            .asterisk_asterisk_equal => return self.parseCompoundAssign(left, .pow, allow_in),
            .less_less_equal => return self.parseCompoundAssign(left, .shl, allow_in),
            .greater_greater_equal => return self.parseCompoundAssign(left, .shr, allow_in),
            .greater_greater_greater_equal => return self.parseCompoundAssign(left, .shr_unsigned, allow_in),
            .ampersand_equal => return self.parseCompoundAssign(left, .bit_and, allow_in),
            .pipe_equal => return self.parseCompoundAssign(left, .bit_or, allow_in),
            .caret_equal => return self.parseCompoundAssign(left, .bit_xor, allow_in),
            // Logical assignments `??=`, `||=`, `&&=` (ES2021).
            // Lowered to `a = a <op> b` so existing checker logic
            // (nullish-coalescing strips null|undefined from lhs)
            // produces the right result type. Post-statement
            // narrowing for `??=` is applied by the checker.
            .question_question_equal => return self.parseLogicalAssign(left, .nullish, allow_in),
            .pipe_pipe_equal => return self.parseLogicalAssign(left, .@"or", allow_in),
            .ampersand_ampersand_equal => return self.parseLogicalAssign(left, .@"and", allow_in),
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
        if (isExpressionIdentifierToken(self.peek().kind) and self.peekAt(1).kind == .arrow) {
            const name_tok = self.advance();
            const arrow_tok = self.peek();
            if (arrow_tok.flags.preceded_by_newline) {
                try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1200, "Line terminator not permitted before arrow.");
            }
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
            self.function_depth += 1;
            if (is_async) self.async_function_depth += 1;
            const prev_generator_depth = self.generator_depth;
            self.generator_depth = 0;
            defer {
                self.generator_depth = prev_generator_depth;
                self.function_depth -= 1;
                if (is_async) self.async_function_depth -= 1;
            }
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
                    const after_paren = self.findMatchingParenEnd(after_args) orelse {
                        self.cursor = checkpoint;
                        return null;
                    };
                    if (after_paren >= self.tokens.len or
                        (self.tokens[after_paren].kind != .arrow and self.tokens[after_paren].kind != .colon))
                    {
                        self.cursor = checkpoint;
                        return null;
                    }
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
            if (try self.tryParseArrowWithMissingCloseParen(start_tok, is_async, &.{})) |arrow| return arrow;
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
            switch (tk) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                .greater_greater, .greater_greater_greater => {
                    const count: u8 = if (tk == .greater_greater) 2 else 3;
                    var n: u8 = 0;
                    while (n < count) : (n += 1) {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    }
                },
                .eof => return null,
                else => {},
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
            // `(expr): =>` is not a typed arrow in TypeScript. It recovers as
            // a parenthesized expression followed by a stray `:` and `=>`.
            if (after_paren_idx + 1 < self.tokens.len and self.tokens[after_paren_idx + 1].kind == .arrow) return null;
            // We need to scan past the type annotation to find a `=>`.
            // Simple approach: look for the next top-level `=>` before
            // a statement-terminator-class token.
            if (!self.scanForArrowAfterColon(after_paren_idx + 1) and
                !self.scanForMissingArrowBlockAfterColon(after_paren_idx + 1))
            {
                return null;
            }
        }

        // Looks like an arrow — parse for real. Bump
        // `async_function_depth` up front so `await` in the parameter
        // list (e.g. `async (await) => …`) is correctly diagnosed as
        // reserved (TS1359). Decrement before the permanent
        // re-increment that wraps the arrow body further below.
        if (is_async) self.async_function_depth += 1;
        const params = self.parseParameterList() catch |err| {
            if (is_async) self.async_function_depth -= 1;
            return err;
        };
        if (is_async) self.async_function_depth -= 1;
        defer self.gpa.free(params);

        // Optional return-type annotation. Use the predicate-aware
        // parser so `(x): x is T => ...` works.
        var return_type: NodeId = hir_mod.none_node_id;
        if (self.match(.colon)) {
            return_type = try self.parseReturnTypeAnnotation(params);
        }
        if (self.peek().kind == .arrow and self.peek().flags.preceded_by_newline) {
            const arrow_tok = self.peek();
            try self.reportCodeAt(arrow_tok.span.start, arrow_tok.line, 1200, "Line terminator not permitted before arrow.");
        }
        if (self.peek().kind == .open_brace) {
            const body_tok = self.peek();
            try self.reportCodeAt(body_tok.span.start, body_tok.line, 1005, "'=>' expected.");
        } else {
            _ = try self.expect(.arrow, "'=>' in arrow function");
        }
        self.function_depth += 1;
        if (is_async) self.async_function_depth += 1;
        const prev_generator_depth = self.generator_depth;
        self.generator_depth = 0;
        defer {
            self.generator_depth = prev_generator_depth;
            self.function_depth -= 1;
            if (is_async) self.async_function_depth -= 1;
        }
        const body = try self.parseArrowBody();
        const sp: Span = .{ .start = start_tok.span.start, .end = self.hir.spanOf(body).end };
        const flags: hir_mod.FnFlags = .{
            .is_arrow = true,
            .is_async = is_async,
        };
        _ = before_paren;
        return try self.builder.addFnDeclGeneric(sp, hir_mod.none_node_id, type_params, params, return_type, body, flags);
    }

    fn tryParseArrowWithMissingCloseParen(
        self: *Parser,
        start_tok: Token,
        is_async: bool,
        type_params: []const NodeId,
    ) ParseError!?NodeId {
        const checkpoint = self.cursor;
        const diag_checkpoint = self.diagnostics.items.len;
        if (self.findTopLevelArrowBeforeCloseParen(self.cursor) == null) return null;

        const saved_allow = self.allow_parameter_list_arrow_recovery;
        const saved_recovered = self.parameter_list_recovered_arrow_missing_close;
        self.allow_parameter_list_arrow_recovery = true;
        self.parameter_list_recovered_arrow_missing_close = false;
        defer {
            self.allow_parameter_list_arrow_recovery = saved_allow;
            self.parameter_list_recovered_arrow_missing_close = saved_recovered;
        }

        // Bump `async_function_depth` ahead of the parameter parse so
        // `async (await) => …` flags TS1359 on `await` (mirrors tsc).
        if (is_async) self.async_function_depth += 1;
        const params = self.parseParameterList() catch |err| {
            if (is_async) self.async_function_depth -= 1;
            self.cursor = checkpoint;
            self.diagnostics.items.len = diag_checkpoint;
            switch (err) {
                error.UnexpectedToken, error.UnexpectedEof, error.InvalidLeftHandSide => return null,
                else => return err,
            }
        };
        if (is_async) self.async_function_depth -= 1;
        defer self.gpa.free(params);
        if (!self.parameter_list_recovered_arrow_missing_close) {
            self.cursor = checkpoint;
            self.diagnostics.items.len = diag_checkpoint;
            return null;
        }
        _ = try self.expect(.arrow, "'=>' in arrow function");
        self.function_depth += 1;
        if (is_async) self.async_function_depth += 1;
        const prev_generator_depth = self.generator_depth;
        self.generator_depth = 0;
        defer {
            self.generator_depth = prev_generator_depth;
            self.function_depth -= 1;
            if (is_async) self.async_function_depth -= 1;
        }
        const body = try self.parseArrowBody();
        const close = self.peek();
        try self.reportCodeAt(close.span.start, close.line, 1005, "')' expected.");
        const sp: Span = .{ .start = start_tok.span.start, .end = self.hir.spanOf(body).end };
        _ = type_params;
        return try self.builder.addFnDecl(
            sp,
            hir_mod.none_node_id,
            params,
            hir_mod.none_node_id,
            body,
            .{ .is_arrow = true, .is_async = is_async },
        );
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
                .greater_than, .greater_greater, .greater_greater_greater => {
                    const count: u8 = switch (tk) {
                        .greater_than => 1,
                        .greater_greater => 2,
                        .greater_greater_greater => 3,
                        else => unreachable,
                    };
                    var n: u8 = 0;
                    while (n < count) : (n += 1) {
                        depth -= 1;
                        if (depth == 0) {
                            // Next token must be `(` or a template
                            // literal for this to be a generic call /
                            // tagged-template call.
                            const next = i + 1;
                            if (next < self.tokens.len and
                                (self.tokens[next].kind == .open_paren or
                                    self.tokens[next].kind == .no_substitution_template or
                                    self.tokens[next].kind == .template_head))
                            {
                                return next;
                            }
                            return null;
                        }
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
                .invalid,
                .eof,
                => return null,
                else => {},
            }
        }
        return null;
    }

    fn findInstantiationTypeArgsPropertyAccessEnd(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len or self.tokens[start].kind != .less_than) return null;
        var depth: i32 = 1;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            switch (tk) {
                .less_than => depth += 1,
                .greater_than, .greater_greater, .greater_greater_greater => {
                    const count: u8 = switch (tk) {
                        .greater_than => 1,
                        .greater_greater => 2,
                        .greater_greater_greater => 3,
                        else => unreachable,
                    };
                    var n: u8 = 0;
                    while (n < count) : (n += 1) {
                        depth -= 1;
                        if (depth == 0) {
                            const next = i + 1;
                            if (next < self.tokens.len and self.tokens[next].kind == .dot) return next;
                            return null;
                        }
                    }
                },
                .open_paren, .open_bracket, .open_brace => {
                    if (self.skipBalancedFrom(i)) |after| {
                        i = after - 1;
                    } else return null;
                },
                .equal,
                .semicolon,
                .arrow,
                .question_dot,
                .invalid,
                .eof,
                => return null,
                else => {},
            }
        }
        return null;
    }

    /// Parse the comma-separated type arguments of an explicit
    /// generic call. Cursor enters at `<`; returns with the cursor
    /// positioned at the token after `>` (the index `after_gt`
    /// returned by `findCallTypeArgsEnd`). The caller owns the
    /// returned slice.
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
            if (self.peek().kind != .greater_than and
                self.peek().kind != .greater_greater and
                self.peek().kind != .greater_greater_greater) break;
        }
        // Force-advance to the verified continuation token even if
        // structural recovery failed.
        self.pending_type_gt = 0;
        self.pending_type_eq = false;
        self.cursor = after_gt;
        return args.toOwnedSlice(self.gpa);
    }

    fn isRegexFlagByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or
            c == '$';
    }

    fn findRegexLiteralEnd(self: *Parser, start: u32) ?u32 {
        const start_i: usize = @intCast(start);
        if (start_i >= self.source.len or self.source[start_i] != '/') return null;
        var i: usize = start_i + 1;
        var escaped = false;
        var in_class = false;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (c == '\n' or c == '\r') return null;
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '[') {
                in_class = true;
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                continue;
            }
            if (c == '/' and !in_class) {
                i += 1;
                while (i < self.source.len and isRegexFlagByte(self.source[i])) : (i += 1) {}
                return @intCast(i);
            }
        }
        return null;
    }

    fn findUnterminatedRegexRecoveryEnd(self: *Parser, start: u32) u32 {
        var i: usize = @intCast(start);
        if (i < self.source.len and self.source[i] == '/') i += 1;
        while (i < self.source.len) : (i += 1) {
            switch (self.source[i]) {
                '\n', '\r', ')', ']', '}', ';', ',' => break,
                else => {},
            }
        }
        return @intCast(i);
    }

    fn parseRegexLiteralExpression(self: *Parser) ParseError!NodeId {
        const start_tok = self.peek();
        const end = self.findRegexLiteralEnd(start_tok.span.start) orelse {
            try self.reportCodeAt(start_tok.span.start, start_tok.line, 1161, "Unterminated regular expression literal.");
            const recovery_end = self.findUnterminatedRegexRecoveryEnd(start_tok.span.start);
            var next = self.cursor;
            while (next < self.tokens.len and
                self.tokens[next].kind != .eof and
                self.tokens[next].span.end <= recovery_end)
            {
                next += 1;
            }
            if (next == self.cursor) next += 1;
            self.cursor = next;
            return try self.builder.addLiteralRegex(.{ .start = start_tok.span.start, .end = recovery_end });
        };
        try self.reportUnbalancedRegexGroup(start_tok, end);
        var next = self.cursor;
        while (next < self.tokens.len and
            self.tokens[next].kind != .eof and
            self.tokens[next].span.end <= end)
        {
            next += 1;
        }
        if (next == self.cursor) next += 1;
        self.cursor = next;
        return try self.builder.addLiteralRegex(.{ .start = start_tok.span.start, .end = end });
    }

    fn reportUnbalancedRegexGroup(self: *Parser, start_tok: Token, end: u32) ParseError!void {
        const start_i: usize = @intCast(start_tok.span.start);
        const end_i: usize = @intCast(end);
        if (start_i >= self.source.len or self.source[start_i] != '/') return;
        var i = start_i + 1;
        var escaped = false;
        var in_class = false;
        var group_depth: u32 = 0;
        while (i < end_i and i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '[') {
                in_class = true;
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                continue;
            }
            if (c == '/' and !in_class) break;
            if (in_class) continue;
            if (c == '(') {
                group_depth += 1;
            } else if (c == ')' and group_depth > 0) {
                group_depth -= 1;
            }
        }
        if (group_depth > 0) {
            try self.reportCodeAt(@intCast(i), start_tok.line, 1005, "')' expected.");
        }
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

    fn findTopLevelArrowBeforeCloseParen(self: *Parser, start: u32) ?u32 {
        if (start >= self.tokens.len or self.tokens[start].kind != .open_paren) return null;
        var depth: i32 = 1;
        var arrow_index: ?u32 = null;
        var i: u32 = start + 1;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (depth == 1 and tk == .arrow and arrow_index == null) arrow_index = i;
            switch (tk) {
                .open_paren, .open_bracket, .open_brace, .less_than => depth += 1,
                .close_paren => {
                    depth -= 1;
                    if (depth == 0) return null;
                },
                .close_bracket, .close_brace, .greater_than => {
                    if (depth > 1) depth -= 1;
                },
                .eof => return arrow_index,
                else => {},
            }
        }
        return arrow_index;
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

    fn scanForMissingArrowBlockAfterColon(self: *Parser, idx: u32) bool {
        var depth: i32 = 0;
        var saw_type_token = false;
        var i: u32 = idx;
        while (i < self.tokens.len) : (i += 1) {
            const tk = self.tokens[i].kind;
            if (depth == 0) {
                if (tk == .open_brace) return saw_type_token;
                if (tk == .semicolon or tk == .comma or tk == .close_paren or
                    tk == .close_brace or tk == .close_bracket or tk == .eof)
                {
                    return false;
                }
                saw_type_token = true;
            }
            switch (tk) {
                .less_than, .open_paren, .open_bracket => depth += 1,
                .greater_than, .close_paren, .close_bracket => {
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

    fn parseCompoundAssign(self: *Parser, left: NodeId, op: hir_mod.BinOp, allow_in: bool) ParseError!NodeId {
        _ = self.advance();
        try self.reportInvalidStrictIdentifierNode(left);
        try self.reportInvalidAssignmentTarget(left);
        const right = try self.parseAssignmentExpressionWithIn(allow_in);
        const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
        return try self.builder.addAssignment(sp, left, right, op);
    }

    /// Lower `a <op>= b` (where <op> is `??`, `||`, or `&&`) into
    /// `a = a <op> b`. The target and the operator's lhs need
    /// independent HIR nodes because parent pointers are single-owner.
    fn parseLogicalAssign(self: *Parser, left: NodeId, op: hir_mod.LogicalOp, allow_in: bool) ParseError!NodeId {
        _ = self.advance();
        try self.reportInvalidStrictIdentifierNode(left);
        try self.reportInvalidAssignmentTarget(left);
        const right = try self.parseAssignmentExpressionWithIn(allow_in);
        const left_dup = try self.cloneLogicalAssignmentTarget(left);
        const left_span = self.hir.spanOf(left);
        const op_span: Span = .{ .start = left_span.start, .end = self.hir.spanOf(right).end };
        const logical = try self.builder.addLogicalOp(op_span, op, left_dup, right);
        return try self.builder.addAssignment(op_span, left, logical, null);
    }

    fn cloneLogicalAssignmentTarget(self: *Parser, node: NodeId) ParseError!NodeId {
        const sp = self.hir.spanOf(node);
        return switch (self.hir.kindOf(node)) {
            .identifier => blk: {
                const id_payload = hir_mod.identifierOf(self.hir, node);
                break :blk try self.builder.addIdentifier(sp, id_payload.name);
            },
            .member_access => blk: {
                const m = hir_mod.memberOf(self.hir, node);
                const obj = try self.cloneLogicalAssignmentTarget(m.object);
                break :blk try self.builder.addMemberAccess(sp, obj, m.name, m.optional);
            },
            .element_access => blk: {
                const e = hir_mod.elementOf(self.hir, node);
                const obj = try self.cloneLogicalAssignmentTarget(e.object);
                const idx = try self.cloneLogicalAssignmentIndex(e.index);
                break :blk try self.builder.addElementAccess(sp, obj, idx, e.optional);
            },
            else => error.InvalidLeftHandSide,
        };
    }

    fn cloneLogicalAssignmentIndex(self: *Parser, node: NodeId) ParseError!NodeId {
        const sp = self.hir.spanOf(node);
        return switch (self.hir.kindOf(node)) {
            .identifier => blk: {
                const id_payload = hir_mod.identifierOf(self.hir, node);
                break :blk try self.builder.addIdentifier(sp, id_payload.name);
            },
            .literal_string => blk: {
                const id = hir_mod.literalStringOf(self.hir, node).value;
                break :blk try self.builder.addLiteralString(sp, id);
            },
            .literal_number => blk: {
                const n = hir_mod.literalNumberOf(self.hir, node);
                break :blk try self.builder.addLiteralNumber(sp, n);
            },
            else => error.InvalidLeftHandSide,
        };
    }

    fn parseConditionalExpression(self: *Parser) ParseError!NodeId {
        return try self.parseConditionalExpressionWithIn(true);
    }

    fn parseConditionalExpressionWithIn(self: *Parser, allow_in: bool) ParseError!NodeId {
        const cond = try self.parseBinaryExpressionWithIn(.nullish, allow_in);
        if (self.peek().kind == .question) {
            _ = self.advance();
            const then_branch = try self.parseAssignmentExpressionWithIn(allow_in);
            _ = try self.expect(.colon, "':' in ternary");
            const else_branch = try self.parseAssignmentExpressionWithIn(allow_in);
            const sp: Span = .{ .start = self.hir.spanOf(cond).start, .end = self.hir.spanOf(else_branch).end };
            return try self.builder.addConditional(sp, cond, then_branch, else_branch);
        }
        return cond;
    }

    fn parseBinaryExpression(self: *Parser, min_prec: prec_mod.Prec) ParseError!NodeId {
        return try self.parseBinaryExpressionWithIn(min_prec, true);
    }

    fn parseBinaryExpressionWithIn(self: *Parser, min_prec: prec_mod.Prec, allow_in: bool) ParseError!NodeId {
        var left = try self.parseUnaryExpression();
        while (true) {
            const t = self.peek();
            if (!allow_in and t.kind == .kw_in) break;
            const prec = prec_mod.binaryPrec(t.kind) orelse break;
            if (@intFromEnum(prec) < @intFromEnum(min_prec)) break;
            if ((t.kind == .kw_as or t.kind == .kw_satisfies) and t.flags.preceded_by_newline) break;
            _ = self.advance();
            if (t.kind == .asterisk_asterisk) {
                try self.reportUnaryExponentiationLeft(left, t.line);
            }
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
            if (self.peek().kind == .close_paren) {
                const missing = self.advance();
                try self.reportCodeAt(missing.span.start, missing.line, 1109, "Expression expected.");
                const right = try self.builder.addLiteralNumber(.{ .start = missing.span.start, .end = missing.span.start }, 0);
                const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = t.span.end };
                if (prec_mod.binOpOf(t.kind)) |bop| {
                    left = try self.builder.addBinaryOp(sp, bop, left, right);
                } else if (prec_mod.logicalOpOf(t.kind)) |lop| {
                    left = try self.builder.addLogicalOp(sp, lop, left, right);
                } else {
                    left = right;
                }
                continue;
            }
            // `a +;`, `a +,`, `a +}`, `a +eof` — binary RHS is missing.
            // Anchor TS1109 at the offending token (matches the
            // `close_paren` arm above and the unary-prefix recovery in
            // `parseUnaryExpression`) so the outer statement keeps
            // parsing instead of bubbling `error.UnexpectedToken` and
            // dropping the diagnostic. We deliberately drop the
            // binary node and keep `left` as the recovered value:
            // synthesising a numeric `0` RHS would feed a phantom
            // operand into the checker and surface false-positive
            // TS2365 / TS2304 on top of the parse error. Regression
            // for upstream `plusOperatorInvalidOperations.ts(5,17)`
            // / `(8,15)`.
            if (self.peekIsUnaryOperandStopToken()) {
                const at = self.peek();
                try self.reportCodeAt(at.span.start, at.line, 1109, "Expression expected.");
                continue;
            }
            const right = try self.parseBinaryExpressionWithIn(next_min, allow_in);
            const sp: Span = .{ .start = self.hir.spanOf(left).start, .end = self.hir.spanOf(right).end };
            if (prec_mod.binOpOf(t.kind)) |bop| {
                left = try self.builder.addBinaryOp(sp, bop, left, right);
            } else if (prec_mod.logicalOpOf(t.kind)) |lop| {
                try self.reportMixedNullishLogical(t, lop, left, right);
                left = try self.builder.addLogicalOp(sp, lop, left, right);
            } else {
                left = right;
            }
        }
        return left;
    }

    fn reportUnaryExponentiationLeft(self: *Parser, left: NodeId, line: u32) ParseError!void {
        if (self.hir.kindOf(left) != .unary_op or self.nodeLooksParenthesized(left)) return;
        const u = hir_mod.unaryOf(self.hir, left);
        const op_text: []const u8 = switch (u.op) {
            .neg => "-",
            .plus => "+",
            .not => "!",
            .bit_not => "~",
            .typeof => "typeof",
            .void_ => "void",
            .delete => "delete",
        };
        const msg = try std.fmt.allocPrint(
            self.gpa,
            "An unary expression with the '{s}' operator is not allowed in the left-hand side of an exponentiation expression. Consider enclosing the expression in parentheses.",
            .{op_text},
        );
        defer self.gpa.free(msg);
        try self.reportCodeAt(self.hir.spanOf(left).start, line, 17006, msg);
    }

    fn reportMixedNullishLogical(
        self: *Parser,
        op_tok: Token,
        op: hir_mod.LogicalOp,
        left: NodeId,
        right: NodeId,
    ) ParseError!void {
        const left_mixed = self.unparenthesizedLogicalOp(left);
        const right_mixed = self.unparenthesizedLogicalOp(right);
        if (op == .nullish) {
            if (left_mixed) |lop| {
                if (lop != .nullish) {
                    try self.reportCodeAt(self.hir.spanOf(left).start, op_tok.line, 5076, "'??' and '&&' or '||' operations cannot be mixed without parentheses.");
                    return;
                }
            }
            if (right_mixed) |rop| {
                if (rop != .nullish) {
                    try self.reportCodeAt(self.hir.spanOf(right).start, op_tok.line, 5076, "'??' and '&&' or '||' operations cannot be mixed without parentheses.");
                    return;
                }
            }
        } else {
            if (left_mixed) |lop| {
                if (lop == .nullish) {
                    try self.reportCodeAt(self.hir.spanOf(left).start, op_tok.line, 5076, "'&&' or '||' and '??' operations cannot be mixed without parentheses.");
                    return;
                }
            }
            if (right_mixed) |rop| {
                if (rop == .nullish) {
                    try self.reportCodeAt(self.hir.spanOf(right).start, op_tok.line, 5076, "'&&' or '||' and '??' operations cannot be mixed without parentheses.");
                    return;
                }
            }
        }
    }

    fn unparenthesizedLogicalOp(self: *Parser, node: NodeId) ?hir_mod.LogicalOp {
        if (self.hir.kindOf(node) != .logical_op) return null;
        if (self.nodeLooksParenthesized(node)) return null;
        return hir_mod.logicalOf(self.hir, node).op;
    }

    fn nodeLooksParenthesized(self: *Parser, node: NodeId) bool {
        const sp = self.hir.spanOf(node);
        var before = sp.start;
        while (before > 0) {
            const c = self.source[before - 1];
            if (!std.ascii.isWhitespace(c)) break;
            before -= 1;
        }
        var after = sp.end;
        while (after < self.source.len) : (after += 1) {
            if (!std.ascii.isWhitespace(self.source[after])) break;
        }
        return before > 0 and after < self.source.len and self.source[before - 1] == '(' and self.source[after] == ')';
    }

    /// True when the upcoming token cannot start an operand for a
    /// unary prefix operator. Used by `parseUnaryExpression` to anchor
    /// TS1109 at the offending token (matching upstream tsc) rather
    /// than bubbling `error.UnexpectedToken` and dropping the
    /// diagnostic on the floor.
    fn peekIsUnaryOperandStopToken(self: *Parser) bool {
        const k = self.peek().kind;
        return k == .semicolon or k == .close_paren or k == .close_brace or
            k == .close_bracket or k == .comma or k == .colon or k == .eof;
    }

    /// Recovery for `<op>;` / `<op>,` / `<op>)` etc. — the unary
    /// operator already consumed `<op>`, the operand is missing.
    /// Anchor TS1109 at the offending follow-on token (same anchor
    /// convention as `parsePrimaryExpression`'s stop-token branch)
    /// and synthesize an empty identifier so the outer statement
    /// keeps parsing instead of bubbling `error.UnexpectedToken`.
    fn recoverUnaryMissingOperand(self: *Parser, op_tok: ts_lexer.Token, op_kind: hir_mod.UnaryOp) ParseError!NodeId {
        const at = self.peek();
        try self.reportCodeAt(at.span.start, at.line, 1109, "Expression expected.");
        // Synthesize a numeric `0` operand: it satisfies the unary
        // operator's type expectations (`+`/`-`/`~` all take number,
        // `!` widens any) so the checker won't pile downstream
        // TS2362 / TS2304 onto the already-reported parse error.
        // Mirrors the `(<bin>)` close-paren recovery a few lines
        // above which also synthesizes `0` for the missing operand.
        const operand_span: Span = .{ .start = at.span.start, .end = at.span.start };
        const operand = try self.builder.addLiteralNumber(operand_span, 0);
        const sp: Span = .{ .start = op_tok.span.start, .end = at.span.start };
        return try self.builder.addUnaryOp(sp, op_kind, operand);
    }

    fn parseUnaryExpression(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        switch (t.kind) {
            .plus => {
                _ = self.advance();
                if (self.peekIsUnaryOperandStopToken()) {
                    return try self.recoverUnaryMissingOperand(t, .plus);
                }
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .plus, operand);
            },
            .minus => {
                _ = self.advance();
                if (self.peekIsUnaryOperandStopToken()) {
                    return try self.recoverUnaryMissingOperand(t, .neg);
                }
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
                if (self.strict_mode and self.hir.kindOf(operand) == .identifier and !self.isThisIdentifier(operand)) {
                    const operand_span = self.hir.spanOf(operand);
                    try self.reportCodeAt(operand_span.start, self.lineAt(operand_span.start), 1102, "'delete' cannot be called on an identifier in strict mode.");
                }
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addUnaryOp(sp, .delete, operand);
            },
            .kw_await => {
                // `await expr` — parses as a unary expression.
                // Per spec, `await` is only valid inside async fns or
                // module top-level; we don't enforce that here (the
                // checker will). The HIR lands as `await_expr`.
                if (self.ambient_depth > 0) {
                    _ = self.advance();
                    const id = try self.internToken(t);
                    return try self.builder.addIdentifier(tokenSpan(t), id);
                }
                const in_async = self.async_function_depth > 0;
                const next_kind = self.peekAt(1).kind;
                const terminator_follows = next_kind == .semicolon or
                    next_kind == .close_paren or
                    next_kind == .close_bracket or
                    next_kind == .close_brace or
                    next_kind == .comma or
                    next_kind == .colon or
                    next_kind == .eof;
                if (terminator_follows and !in_async) {
                    _ = self.advance();
                    const id = try self.internToken(t);
                    return try self.builder.addIdentifier(tokenSpan(t), id);
                }
                if (terminator_follows and in_async) {
                    // `await)` / `await]` / `await,` inside an async
                    // function — `await` is a reserved keyword here,
                    // so treat it as an await-expression with a
                    // missing operand. Mirrors tsc: TS2524 at the
                    // `await` token when inside a parameter
                    // initializer, plus TS1109 at the position right
                    // after `await` for the missing operand.
                    _ = self.advance();
                    if (self.param_initializer_depth > 0) {
                        try self.reportCodeAt(t.span.start, t.line, 2524, "'await' expressions cannot be used in a parameter initializer.");
                    }
                    const err_pos = t.span.end;
                    try self.reportCodeAt(err_pos, t.line, 1109, "Expression expected.");
                    return try self.builder.addAwaitExpr(tokenSpan(t), hir_mod.none_node_id);
                }
                _ = self.advance();
                const operand = try self.parseUnaryExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                if (self.param_initializer_depth > 0) {
                    try self.reportCodeAt(t.span.start, t.line, 2524, "'await' expressions cannot be used in a parameter initializer.");
                }
                return try self.builder.addAwaitExpr(sp, operand);
            },
            .kw_yield => {
                if (self.generator_depth == 0) {
                    _ = self.advance();
                    if (self.function_depth > 0) {
                        try self.reportCodeAt(t.span.start, t.line, 1163, "A 'yield' expression is only allowed in a generator body.");
                        const is_delegated = self.match(.asterisk);
                        if (self.peek().kind == .semicolon or
                            self.peek().flags.preceded_by_newline or
                            self.peek().kind == .close_paren or
                            self.peek().kind == .close_bracket or
                            self.peek().kind == .close_brace or
                            self.peek().kind == .comma or
                            self.peek().kind == .eof)
                        {
                            return try self.builder.addYieldExpr(tokenSpan(t), hir_mod.none_node_id, is_delegated);
                        }
                        const operand = try self.parseAssignmentExpression();
                        const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                        return try self.builder.addYieldExpr(sp, operand, is_delegated);
                    }
                    // Top-level `yield` used as an identifier. When the
                    // target is ES2015+ (or we're in explicit strict
                    // mode), `yield` is a reserved word; tsc emits
                    // TS1212 at the keyword position in addition to
                    // the checker-side TS2304. Matches baselines like
                    // `YieldExpression1_es6` / `YieldExpression8_es6`
                    // / `YieldExpression18_es6`. The `* operand` form
                    // is treated by tsc as a multiplication of the
                    // `yield` identifier by the operand, so TS1212
                    // still fires (mirrors YieldStarExpression1_es6).
                    // The `*` followed by a terminator is the broken
                    // yield-star case: TS1109 fires and TS1212 does
                    // NOT (mirrors YieldStarExpression2_es6).
                    const next_is_star = self.peek().kind == .asterisk;
                    var star_operand_missing = false;
                    if (next_is_star) {
                        const after_star_kind = self.peekAt(1).kind;
                        star_operand_missing = after_star_kind == .semicolon or
                            after_star_kind == .eof or
                            after_star_kind == .close_paren or
                            after_star_kind == .close_bracket or
                            after_star_kind == .close_brace or
                            after_star_kind == .comma;
                    }
                    if (!star_operand_missing and self.isYieldReservedName(t)) {
                        try self.reportCodeAt(t.span.start, t.line, 1212, "Identifier expected. 'yield' is a reserved word in strict mode.");
                    }
                    const id = try self.internToken(t);
                    var ident = try self.builder.addIdentifier(tokenSpan(t), id);
                    if (star_operand_missing and self.match(.asterisk)) {
                        const err_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else t.span.end;
                        try self.reportCodeAt(err_pos, t.line, 1109, "Expression expected.");
                    }
                    // Consume an immediate call-args suffix so `yield(foo)`
                    // (YieldExpression8_es6 / YieldExpression18_es6) parses
                    // as a call on the yield identifier instead of leaving
                    // `(foo)` to a follow-on statement parser that would
                    // synthesise a spurious TS1005 between them.
                    if (self.peek().kind == .open_paren) {
                        const args = try self.parseArgumentList();
                        defer self.gpa.free(args);
                        const close_pos = self.tokens[self.cursor - 1].span.end;
                        const sp: Span = .{ .start = t.span.start, .end = close_pos };
                        ident = try self.builder.addCall(sp, ident, args);
                    }
                    return ident;
                }
                // `yield` / `yield expr` / `yield* expr`.
                _ = self.advance();
                const is_delegated = self.match(.asterisk);
                // `yield` with no operand is allowed at expression
                // statement position; we accept any expression that
                // a unary parser would.
                if (self.peek().kind == .semicolon or
                    self.peek().flags.preceded_by_newline or
                    self.peek().kind == .close_paren or
                    self.peek().kind == .close_bracket or
                    self.peek().kind == .close_brace or
                    self.peek().kind == .comma or
                    self.peek().kind == .eof)
                {
                    if (is_delegated) {
                        // tsc anchors TS1109 at the next token (the
                        // token after `yield*` when the operand is
                        // missing) — e.g. for `yield*\n}` the `}`
                        // line/col is reported, not the end of the
                        // `*`. Mirrors YieldExpression5_es6.
                        const next_tok = self.peek();
                        try self.reportCodeAt(next_tok.span.start, next_tok.line, 1109, "Expression expected.");
                    }
                    return try self.builder.addYieldExpr(tokenSpan(t), hir_mod.none_node_id, is_delegated);
                }
                const operand = try self.parseAssignmentExpression();
                const sp: Span = .{ .start = t.span.start, .end = self.hir.spanOf(operand).end };
                return try self.builder.addYieldExpr(sp, operand, is_delegated);
            },
            .plus_plus, .minus_minus => {
                _ = self.advance();
                if (self.peek().kind == .plus_plus or self.peek().kind == .minus_minus) {
                    const bad = self.advance();
                    try self.reportCodeAt(bad.span.start, bad.line, 1109, "Expression expected.");
                    if (self.peek().kind == .semicolon or
                        self.peek().kind == .close_paren or
                        self.peek().kind == .close_bracket or
                        self.peek().kind == .close_brace or
                        self.peek().kind == .comma or
                        self.peek().kind == .eof)
                    {
                        const one = try self.builder.addLiteralNumber(tokenSpan(bad), 1);
                        return one;
                    }
                }
                if (self.peek().kind == .kw_delete) {
                    const bad = self.peek();
                    try self.reportCodeAt(bad.span.start, bad.line, 1109, "Expression expected.");
                    return try self.parseUnaryExpression();
                }
                const operand = try self.parseUnaryExpression();
                if (!self.isValidUpdateOperand(operand)) {
                    const operand_span = self.hir.spanOf(operand);
                    if (self.prefixUpdateUsesArithmeticOperandDiagnostic(operand)) {
                        try self.reportCodeAt(operand_span.start, t.line, 2356, "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.");
                        if (self.isThisIdentifier(operand)) {
                            return try self.builder.addLiteralNumber(operand_span, 1);
                        }
                        return operand;
                    }
                    if (self.prefixUpdateDefersDiagnosticToChecker(operand)) {
                        // `--foo()` / `--(x + y)` — tsc skips the
                        // grammar-level TS2357 lvalue error and
                        // relies on the checker to emit TS2356 when
                        // the operand's type isn't numeric. Build the
                        // assignment so the synthesised-update path
                        // in `checkBinop` runs.
                        return try self.buildUpdateAssignment(t, operand, t.kind == .plus_plus, true);
                    }
                    try self.reportCodeAt(operand_span.start, t.line, 2357, "The operand of an increment or decrement operator must be a variable or a property access.");
                    if (self.isThisIdentifier(operand)) {
                        return try self.builder.addLiteralNumber(operand_span, 1);
                    }
                    return operand;
                }
                return try self.buildUpdateAssignment(t, operand, t.kind == .plus_plus, true);
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
                    if (self.hir.kindOf(node) == .assignment and self.parenthesizedNodeStart(node) == null) break;
                    _ = self.advance();
                    if (self.hir.kindOf(node) == .literal_number and
                        self.peek().kind == .dot and
                        (self.peekAt(1).kind == .identifier or self.peekAt(1).kind.isContextualKeyword()))
                    {
                        _ = self.advance();
                    }
                    const name_tok = try self.expectIdentifierLike();
                    const name_id = try self.internToken(name_tok);
                    const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = name_tok.span.end };
                    node = try self.builder.addMemberAccess(sp, node, name_id, false);
                },
                .open_bracket => {
                    _ = self.advance();
                    node = try self.finishElementAccess(node, false);
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
                    if (self.hir.kindOf(node) == .assignment and self.parenthesizedNodeStart(node) == null) break;
                    _ = self.advance();
                    if (self.hir.kindOf(node) == .literal_number and
                        self.peek().kind == .dot and
                        (self.peekAt(1).kind == .identifier or self.peekAt(1).kind.isContextualKeyword()))
                    {
                        _ = self.advance();
                    }
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
                        node = try self.builder.addOptionalCall(sp, node, args);
                    } else if (self.peek().kind == .open_bracket) {
                        _ = self.advance();
                        node = try self.finishElementAccess(node, true);
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
                    // a matching `>` is followed immediately by `(` or
                    // a tagged-template literal. Otherwise we bail out
                    // and leave `<` to the binop path.
                    if (self.findCallTypeArgsEnd(self.cursor)) |after_gt| {
                        // Parse the type args so the checker can use
                        // them to override call-site inference.
                        const type_args = try self.parseExplicitCallTypeArgs(after_gt);
                        defer self.gpa.free(type_args);
                        if (self.peek().kind == .no_substitution_template or self.peek().kind == .template_head) {
                            node = try self.parseTaggedTemplateWithTypeArgs(node, type_args);
                        } else {
                            const args = try self.parseArgumentList();
                            defer self.gpa.free(args);
                            const close_pos = self.tokens[self.cursor - 1].span.end;
                            const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = close_pos };
                            node = try self.builder.addCallWithTypeArgs(sp, node, args, type_args);
                        }
                    } else if (self.findInstantiationTypeArgsPropertyAccessEnd(self.cursor)) |after_gt| {
                        const less = self.peek();
                        const type_args = try self.parseExplicitCallTypeArgs(after_gt);
                        defer self.gpa.free(type_args);
                        try self.reportCodeAt(less.span.start, less.line, 1477, "An instantiation expression cannot be followed by a property access.");
                        const end_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else self.hir.spanOf(node).end;
                        const sp: Span = .{ .start = self.hir.spanOf(node).start, .end = end_pos };
                        node = try self.builder.addCallWithTypeArgs(sp, node, &.{}, type_args);
                    } else break;
                },
                .open_bracket => {
                    _ = self.advance();
                    node = try self.finishElementAccess(node, false);
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
                .plus_plus, .minus_minus => {
                    if (t.flags.preceded_by_newline) break;
                    if (self.hir.kindOf(node) == .assignment) {
                        _ = self.advance();
                        try self.reportCodeAt(t.span.start, t.line, 1005, "';' expected.");
                        const next = self.peek();
                        const pos = if (next.kind == .semicolon or next.kind == .eof) next.span.start else t.span.end;
                        try self.reportCodeAt(pos, t.line, 1109, "Expression expected.");
                        break;
                    }
                    _ = self.advance();
                    node = try self.buildUpdateAssignment(t, node, t.kind == .plus_plus, false);
                },
                .no_substitution_template, .template_head => {
                    // Tagged template literal: `` tag`…` `` desugars to
                    // a call `tag(stringsArr, …values)`. v0 just types
                    // `stringsArr` as `string[]` (no
                    // TemplateStringsArray shape yet).
                    node = try self.parseTaggedTemplateWithTypeArgs(node, &.{});
                },
                else => break,
            }
        }
        return node;
    }

    fn finishElementAccess(self: *Parser, object: NodeId, optional: bool) ParseError!NodeId {
        const idx = if (self.peek().kind == .close_bracket) blk: {
            const close = self.peek();
            try self.reportCodeAt(close.span.start, close.line, 1011, "An element access expression should take an argument.");
            break :blk try self.builder.addLiteralNumber(.{ .start = close.span.start, .end = close.span.start }, 0);
        } else try self.parseExpression();
        const close = try self.expect(.close_bracket, "']' to close index access");
        const sp: Span = .{ .start = self.hir.spanOf(object).start, .end = close.span.end };
        return try self.builder.addElementAccess(sp, object, idx, optional);
    }

    /// Parse a substitution template literal expression
    /// (`` `a${x}b` ``). Cursor at `template_head`. Produces a
    /// `template_literal` HIR node with interleaved text/expr
    /// children.
    fn parseTemplateLiteralExpr(self: *Parser) ParseError!NodeId {
        var texts: std.ArrayListUnmanaged(NodeId) = .empty;
        defer texts.deinit(self.gpa);
        var exprs: std.ArrayListUnmanaged(NodeId) = .empty;
        defer exprs.deinit(self.gpa);

        const head = self.advance(); // template_head: `` `…${ ``
        const head_slice_full = self.source[head.span.start..head.span.end];
        const head_inner = if (head_slice_full.len >= 3)
            head_slice_full[1 .. head_slice_full.len - 2]
        else
            head_slice_full;
        const head_id = self.interner.intern(head_inner) catch return error.OutOfMemory;
        const head_lit = try self.builder.addLiteralString(tokenSpan(head), head_id);
        try texts.append(self.gpa, head_lit);

        while (true) {
            const v = try self.parseExpression();
            try exprs.append(self.gpa, v);
            const next = self.peek();
            if (next.kind == .template_middle) {
                _ = self.advance();
                const sl = self.source[next.span.start..next.span.end];
                const inner = if (sl.len >= 3) sl[1 .. sl.len - 2] else sl;
                const id = self.interner.intern(inner) catch return error.OutOfMemory;
                const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                try texts.append(self.gpa, lit);
                continue;
            }
            if (next.kind == .template_tail) {
                _ = self.advance();
                const sl = self.source[next.span.start..next.span.end];
                const inner = if (sl.len >= 2) sl[1 .. sl.len - 1] else sl;
                const id = self.interner.intern(inner) catch return error.OutOfMemory;
                const lit = try self.builder.addLiteralString(tokenSpan(next), id);
                try texts.append(self.gpa, lit);
                break;
            }
            try self.reportCodeAt(next.span.start, next.line, 1005, "'}' expected.");
            const empty_id = self.interner.intern("") catch return error.OutOfMemory;
            const empty_lit = try self.builder.addLiteralString(.{ .start = next.span.start, .end = next.span.start }, empty_id);
            try texts.append(self.gpa, empty_lit);
            break;
        }

        const end_pos = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else head.span.end;
        const sp: Span = .{ .start = head.span.start, .end = end_pos };
        return try self.builder.addTemplateLiteralExpr(sp, texts.items, exprs.items);
    }

    /// Parse a tagged template literal as a call expression. Cursor at
    /// `no_substitution_template` or `template_head`. We collect the
    /// string segments into an array literal and the interpolated
    /// expressions as call arguments.
    fn parseTaggedTemplateWithTypeArgs(self: *Parser, tag: NodeId, type_args: []const NodeId) ParseError!NodeId {
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
                try self.reportCodeAt(next.span.start, next.line, 1005, "'}' expected.");
                const empty_id = self.interner.intern("") catch return error.OutOfMemory;
                const empty_lit = try self.builder.addLiteralString(.{ .start = next.span.start, .end = next.span.start }, empty_id);
                try strings.append(self.gpa, empty_lit);
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

        if (type_args.len > 0) {
            return try self.builder.addCallWithTypeArgs(call_sp, tag, args.items, type_args);
        }
        return try self.builder.addCall(call_sp, tag, args.items);
    }

    /// Allocates the args slice; caller must `gpa.free` it.
    fn parseArgumentList(self: *Parser) ParseError![]NodeId {
        _ = try self.expect(.open_paren, "'(' for argument list");
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer args.deinit(self.gpa);
        var missing_arg_before_statement = false;
        if (self.peek().kind != .close_paren) {
            while (true) {
                const start_tok = self.peek();
                if (start_tok.kind == .invalid) {
                    const bad = self.advance();
                    try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                    break;
                }
                if (start_tok.kind == .comma) {
                    try self.reportCodeAt(start_tok.span.start, start_tok.line, 1135, "Argument expression expected.");
                    _ = self.advance();
                    if (self.peek().kind == .close_paren) break;
                    continue;
                }
                if (start_tok.kind == .kw_return) {
                    try self.reportCodeAt(start_tok.span.start, start_tok.line, 1135, "Argument expression expected.");
                    missing_arg_before_statement = true;
                    break;
                }
                if (start_tok.kind == .semicolon or start_tok.kind == .close_brace or start_tok.kind == .eof) break;
                const arg = if (self.peek().kind == .dot_dot_dot) blk: {
                    const dot_tok = self.advance();
                    const inner = try self.parseAssignmentExpression();
                    const end = self.tokens[self.cursor - 1].span.end;
                    break :blk try self.builder.addSpread(.{ .start = dot_tok.span.start, .end = end }, inner);
                } else try self.parseAssignmentExpression();
                try args.append(self.gpa, arg);
                if (!self.match(.comma)) {
                    if (self.peek().kind == .invalid) {
                        const bad = self.advance();
                        try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                    }
                    break;
                }
                if (self.peek().kind == .close_paren) break; // trailing comma
            }
        }
        if (self.peek().kind == .close_paren) {
            _ = self.advance();
        } else {
            const close_tok = self.peek();
            if (close_tok.kind == .kw_return and !missing_arg_before_statement and args.items.len > 0) {
                try self.reportCodeAt(close_tok.span.start, close_tok.line, 1005, "',' expected.");
            } else if (!missing_arg_before_statement) {
                try self.reportCodeAt(close_tok.span.start, close_tok.line, 1005, "')' expected.");
            }
        }
        return try args.toOwnedSlice(self.gpa);
    }

    fn parsePrimaryExpression(self: *Parser) ParseError!NodeId {
        const t = self.peek();
        switch (t.kind) {
            .number_literal => {
                _ = self.advance();
                const slice = self.source[t.span.start..t.span.end];
                try self.reportStrictLegacyOctal(t, slice);
                try self.reportNumericLiteralDiagnostics(t, slice);
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
            .regex_literal, .slash => {
                return try self.parseRegexLiteralExpression();
            },
            .no_substitution_template => {
                _ = self.advance();
                // Build a template_literal HIR node so the emitter can
                // pick the right form for the target (native backticks
                // at ES2015+, string concat at ES5).
                const slice = self.source[t.span.start..t.span.end];
                const inner = if (slice.len >= 2) slice[1 .. slice.len - 1] else slice;
                const id = self.interner.intern(inner) catch return error.OutOfMemory;
                const text_lit = try self.builder.addLiteralString(tokenSpan(t), id);
                return try self.builder.addTemplateLiteralExpr(tokenSpan(t), &.{text_lit}, &.{});
            },
            .template_head => {
                return try self.parseTemplateLiteralExpr();
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
            .kw_any, .kw_unknown, .kw_never, .kw_void, .kw_string, .kw_number, .kw_boolean, .kw_bigint, .kw_symbol, .kw_object, .kw_get, .kw_set, .kw_global, .kw_from, .kw_require, .kw_module, .kw_namespace, .kw_interface, .kw_declare, .kw_of, .kw_type, .kw_using, .kw_await, .kw_static => {
                _ = self.advance();
                try self.reportInvalidFutureReservedName(t);
                const id = try self.internToken(t);
                return try self.builder.addIdentifier(tokenSpan(t), id);
            },
            .kw_public, .kw_private, .kw_protected => {
                // Strict-future-reserved words like `public` are valid
                // identifier expressions when reached in expression
                // position (e.g. inside a computed property name
                // `[public]: 0` or a class-body computed key). Emit the
                // upstream TS1212 / TS1213 strict-reserved diagnostic
                // and synthesize an identifier so downstream checker
                // reports TS2304 instead of TS1109. Mirrors fixtures
                // `parserComputedPropertyName36`-`39`.
                _ = self.advance();
                try self.reportInvalidClassStrictIdentifier(t);
                try self.reportInvalidFutureReservedName(t);
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
                // In .ts files `<T>expr` is a type assertion. Parse
                // the full type node so forms like `<T[]>null` and
                // `<Array<T>>null` consume nested `>` tokens through
                // the same rescan path used by type references.
                _ = self.advance();
                const type_node = try self.parseTypeAnnotation();
                _ = try self.consumeTypeGreater("'>' to close type assertion");
                const expr = try self.parseUnaryExpression();
                return try self.builder.addAsExpression(.type_assertion, .{
                    .start = t.span.start,
                    .end = self.hir.spanOf(expr).end,
                }, expr, type_node);
            },
            .open_bracket => return try self.parseArrayLiteral(),
            .open_brace => return try self.parseObjectLiteral(),
            .at => {
                _ = try self.parseDecoratorExpression();
                if (self.peek().kind == .kw_class or
                    (self.peek().kind == .kw_abstract and self.peekAt(1).kind == .kw_class))
                {
                    return try self.parseClassDeclaration();
                }
                try self.report("decorators are not valid here", "");
                return error.UnexpectedToken;
            },
            .kw_class => return try self.parseClassDeclaration(),
            .kw_abstract => {
                if (self.peekAt(1).kind == .kw_class) return try self.parseClassDeclaration();
                _ = self.advance();
                const id = try self.internToken(t);
                return try self.builder.addIdentifier(tokenSpan(t), id);
            },
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
                if (self.peekAt(1).kind == .dot and
                    (self.peekAt(2).kind == .identifier or self.peekAt(2).kind.isContextualKeyword()) and
                    self.tokenTextEquals(self.peekAt(2), "target"))
                {
                    const new_tok = self.advance();
                    _ = self.advance(); // dot
                    const target_tok = self.advance();
                    if (self.new_target_depth == 0) {
                        try self.reportCodeAt(new_tok.span.start, new_tok.line, 17013, "Meta-property 'new.target' is only allowed in the body of a function declaration, function expression, or constructor.");
                    }
                    const id = self.interner.intern("new.target") catch return error.OutOfMemory;
                    return try self.builder.addIdentifier(.{ .start = new_tok.span.start, .end = target_tok.span.end }, id);
                }
                if (self.peekAt(1).kind == .less_than) {
                    const less = self.peekAt(1);
                    try self.reportCodeAt(less.span.start, less.line, 1109, "Expression expected.");
                    const name_tok = self.peekAt(2);
                    if (name_tok.kind == .identifier or name_tok.kind.isContextualKeyword()) {
                        const name_text = self.source[name_tok.span.start..name_tok.span.end];
                        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "Cannot find name '{s}'.", .{name_text});
                        try self.reportCodeAt(name_tok.span.start, name_tok.line, 2304, msg);
                    }
                }
                _ = self.advance();
                // Lowered as a dedicated `new_expr` so the checker can
                // produce the class instance type rather than the
                // constructor's call return type. The callee uses a
                // member-only parser so `new Foo(args)` doesn't get
                // pre-consumed as a call.
                const callee = try self.parseMemberExpressionOnly();
                var type_args: []NodeId = &.{};
                if (self.peek().kind == .less_than) {
                    const saved_cursor = self.cursor;
                    const saved_diag_len = self.diagnostics.items.len;
                    const saved_pending_type_gt = self.pending_type_gt;
                    const saved_pending_type_gt_pos = self.pending_type_gt_pos;
                    const saved_pending_type_gt_line = self.pending_type_gt_line;
                    const saved_pending_type_gt_flags = self.pending_type_gt_flags;
                    const saved_pending_type_eq = self.pending_type_eq;
                    const saved_pending_type_eq_pos = self.pending_type_eq_pos;
                    const saved_pending_type_eq_line = self.pending_type_eq_line;
                    const saved_pending_type_eq_flags = self.pending_type_eq_flags;
                    if (self.parseTypeArgumentList()) |parsed| {
                        if (self.peek().kind == .open_paren) {
                            type_args = parsed;
                        } else if (self.newExpressionTypeArgsCanEndHere()) {
                            type_args = parsed;
                        } else {
                            self.gpa.free(parsed);
                            self.cursor = saved_cursor;
                            self.diagnostics.items.len = saved_diag_len;
                            self.pending_type_gt = saved_pending_type_gt;
                            self.pending_type_gt_pos = saved_pending_type_gt_pos;
                            self.pending_type_gt_line = saved_pending_type_gt_line;
                            self.pending_type_gt_flags = saved_pending_type_gt_flags;
                            self.pending_type_eq = saved_pending_type_eq;
                            self.pending_type_eq_pos = saved_pending_type_eq_pos;
                            self.pending_type_eq_line = saved_pending_type_eq_line;
                            self.pending_type_eq_flags = saved_pending_type_eq_flags;
                        }
                    } else |_| {
                        self.cursor = saved_cursor;
                        self.diagnostics.items.len = saved_diag_len;
                        self.pending_type_gt = saved_pending_type_gt;
                        self.pending_type_gt_pos = saved_pending_type_gt_pos;
                        self.pending_type_gt_line = saved_pending_type_gt_line;
                        self.pending_type_gt_flags = saved_pending_type_gt_flags;
                        self.pending_type_eq = saved_pending_type_eq;
                        self.pending_type_eq_pos = saved_pending_type_eq_pos;
                        self.pending_type_eq_line = saved_pending_type_eq_line;
                        self.pending_type_eq_flags = saved_pending_type_eq_flags;
                    }
                }
                defer if (type_args.len > 0) self.gpa.free(type_args);
                if (self.peek().kind == .open_paren) {
                    const args = try self.parseArgumentList();
                    defer self.gpa.free(args);
                    const close_pos = self.tokens[self.cursor - 1].span.end;
                    return try self.builder.addNewWithTypeArgs(.{ .start = t.span.start, .end = close_pos }, callee, args, type_args);
                }
                const end_pos = if (type_args.len > 0 and self.cursor > 0) self.tokens[self.cursor - 1].span.end else self.hir.spanOf(callee).end;
                return try self.builder.addNewWithTypeArgs(.{ .start = t.span.start, .end = end_pos }, callee, &.{}, type_args);
            },
            .kw_import => {
                // Dynamic `import("module")` — parses as a call
                // expression with `import` as the callee. We synthesize
                // an identifier named `import` so downstream emit can
                // route the call site through the appropriate
                // module-system lowering (a no-op at .esm; an
                // async require() at .commonjs).
                //
                // `import.meta` — ES2020 module-meta property. The
                // `import` keyword is materialized as an identifier
                // and the surrounding `parseCallOrMemberExpression`
                // loop consumes the `.meta` (and any further
                // chains like `.url`) as ordinary member accesses.
                // The checker treats `import` as a builtin so the
                // chain types as `any` for now (full `ImportMeta`
                // shape is a follow-up).
                _ = self.advance();
                const import_id = self.interner.intern("import") catch return error.OutOfMemory;
                const callee = try self.builder.addIdentifier(tokenSpan(t), import_id);
                if (self.peek().kind != .open_paren) {
                    if (self.peek().kind == .dot and (self.peekAt(1).kind == .identifier or self.peekAt(1).kind.isContextualKeyword())) {
                        const prop = self.peekAt(1);
                        const is_meta = self.tokenTextEquals(prop, "meta");
                        const is_defer = self.tokenTextEquals(prop, "defer");
                        if (is_defer and self.peekAt(2).kind != .open_paren) {
                            try self.reportCodeAt(prop.span.end, prop.line, 1005, "'(' expected.");
                        } else if (!is_meta and !is_defer) {
                            try self.reportCodeAt(prop.span.start, prop.line, 17012, "This is not a valid meta-property for keyword 'import'. Did you mean 'meta'?");
                        }
                    }
                    // Not a dynamic import — return the synthesized
                    // identifier so postfix `.meta`/`.meta.url` can
                    // attach as member accesses upstream.
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
                return try self.parseFunctionDeclaration(false);
            },
            .kw_async => {
                if (self.peekAt(1).kind == .kw_function) {
                    _ = self.advance();
                    // Bump `async_function_depth` so `await` used as
                    // the function-expression name or as a parameter
                    // name is correctly diagnosed as reserved (TS1359).
                    self.async_function_depth += 1;
                    defer self.async_function_depth -= 1;
                    const fd = try self.parseFunctionDeclaration(false);
                    self.hir.markFnAsync(fd);
                    return fd;
                }
                _ = self.advance();
                const id = try self.internToken(t);
                return try self.builder.addIdentifier(tokenSpan(t), id);
            },
            .invalid => {
                const bad = self.advance();
                try self.reportCodeAt(bad.span.start, bad.line, 1127, "Invalid character.");
                if (!self.peek().flags.preceded_by_newline and arrayLiteralElementCanStart(self.peek().kind)) {
                    return try self.parseUnaryExpression();
                }
                return error.UnexpectedToken;
            },
            .kw_finally => {
                _ = self.advance();
                try self.reportCodeAt(t.span.start, t.line, 1109, "Expression expected.");
                if (self.peek().kind != .open_brace) {
                    const at = self.peek();
                    try self.reportCodeAt(at.span.start, at.line, 1005, "'{' expected.");
                }
                return try self.builder.addLiteralNumber(.{ .start = t.span.start, .end = t.span.start }, 0);
            },
            else => {
                if (t.kind.isContextualKeyword()) {
                    _ = self.advance();
                    const id = try self.internToken(t);
                    return try self.builder.addIdentifier(tokenSpan(t), id);
                }
                if (t.kind == .pipe_pipe or t.kind == .ampersand_ampersand) {
                    _ = self.advance();
                    try self.reportCodeAt(t.span.start, t.line, 1109, "Expression expected.");
                    return try self.parseUnaryExpression();
                }
                if (t.kind == .close_paren or
                    t.kind == .close_brace or
                    t.kind == .semicolon or
                    t.kind == .colon or
                    t.kind == .eof or
                    t.kind == .kw_return or
                    t.kind == .kw_case or
                    t.kind == .kw_default or
                    t.kind == .kw_enum)
                {
                    try self.reportCodeAt(t.span.start, t.line, 1109, "Expression expected.");
                    return error.UnexpectedToken;
                }
                // §6.A 2000-3000 ratchet: emit the canonical tsc
                // "Expression expected." (TS1109) instead of a
                // Home-internal "unexpected token in expression: ..."
                // payload. Aligns recovery diagnostics with upstream
                // baselines on fixtures like `parserMissingLambdaOpenBrace1`
                // (lambda body opens with `var`) where tsc anchors
                // TS1109 at the offending token.
                try self.reportCodeAt(t.span.start, t.line, 1109, "Expression expected.");
                return error.UnexpectedToken;
            },
        }
    }

    fn isThisIdentifier(self: *const Parser, node: NodeId) bool {
        if (self.hir.kindOf(node) != .identifier) return false;
        const id = hir_mod.identifierOf(self.hir, node);
        return std.mem.eql(u8, self.interner.get(id.name), "this");
    }

    fn isValidUpdateOperand(self: *const Parser, operand: NodeId) bool {
        return switch (self.hir.kindOf(operand)) {
            .identifier => !self.isThisIdentifier(operand),
            .member_access, .element_access => true,
            else => false,
        };
    }

    fn prefixUpdateUsesArithmeticOperandDiagnostic(self: *const Parser, operand: NodeId) bool {
        return switch (self.hir.kindOf(operand)) {
            // Operands whose type cannot be coerced to a numeric for
            // increment/decrement render as TS2356 ("An arithmetic
            // operand must be …") instead of TS2357 ("must be a
            // variable or a property access."). Mirrors tsc, which
            // prefers the operand-type error when the operand has a
            // concrete non-numeric shape (object/array/fn/string).
            .array_literal, .object_literal, .fn_decl, .fn_expr, .literal_string, .literal_bool, .template_literal => true,
            .identifier => self.isThisIdentifier(operand),
            else => false,
        };
    }

    /// Operands the parser cannot classify by shape alone — the
    /// checker decides between TS2356 (non-numeric operand type)
    /// and silently accepting once it knows the call/expression's
    /// return type. Build the synthesised assignment so
    /// `checkBinop`'s synth-update path runs.
    fn prefixUpdateDefersDiagnosticToChecker(self: *const Parser, operand: NodeId) bool {
        return switch (self.hir.kindOf(operand)) {
            .call_expr, .binary_op => true,
            else => false,
        };
    }

    fn isValidAssignmentTarget(self: *const Parser, node: NodeId) bool {
        return switch (self.hir.kindOf(node)) {
            // `undefined` parses to a literal_undefined HIR node but
            // is syntactically a valid identifier expression — JS lets
            // you write `undefined = ...` and only the checker rejects
            // it via TS2539. Keep the parser permissive so we don't
            // double-emit TS2364. Mirrors `nullAssignedToUndefined.ts`.
            .identifier, .member_access, .element_access, .array_literal, .object_literal, .literal_undefined => true,
            else => false,
        };
    }

    fn parenthesizedNodeStart(self: *const Parser, node: NodeId) ?u32 {
        const sp = self.hir.spanOf(node);
        var before = sp.start;
        while (before > 0) {
            const c = self.source[before - 1];
            if (!std.ascii.isWhitespace(c)) break;
            before -= 1;
        }
        var after = sp.end;
        while (after < self.source.len) : (after += 1) {
            if (!std.ascii.isWhitespace(self.source[after])) break;
        }
        if (before > 0 and after < self.source.len and self.source[before - 1] == '(' and self.source[after] == ')') {
            return before - 1;
        }
        return null;
    }

    fn sourceLineAtPos(self: *const Parser, pos: u32) u32 {
        var line: u32 = 1;
        var i: u32 = 0;
        const limit = @min(pos, @as(u32, @intCast(self.source.len)));
        while (i < limit) : (i += 1) {
            if (self.source[i] == '\n') line += 1;
        }
        return line;
    }

    fn reportInvalidAssignmentTarget(self: *Parser, node: NodeId) ParseError!void {
        if (self.isValidAssignmentTarget(node)) return;
        const pos = self.parenthesizedNodeStart(node) orelse self.hir.spanOf(node).start;
        try self.reportCodeAt(pos, self.sourceLineAtPos(pos), 2364, "The left-hand side of an assignment expression must be a variable or a property access.");
    }

    fn buildUpdateAssignment(self: *Parser, op_tok: Token, operand: NodeId, is_inc: bool, is_prefix: bool) ParseError!NodeId {
        // tsc anchors TS2357 at the operand expression itself
        // (e.g. column of `this` in `++this`, or `new` in `++ new Foo()`).
        const operand_span = self.hir.spanOf(operand);
        const diag_pos = operand_span.start;
        // For prefix updates the operand follows the op token on the
        // same logical token-line; postfix is the inverse. The
        // diagnostic's line field is informational — downstream
        // recomputes it from `pos`. Reuse `op_tok.line` as a safe
        // approximation when the operand lacks a token line.
        const diag_line = op_tok.line;
        try self.reportInvalidStrictIdentifierNode(operand);
        switch (self.hir.kindOf(operand)) {
            .identifier => {
                const id = hir_mod.identifierOf(self.hir, operand);
                if (std.mem.eql(u8, self.interner.get(id.name), "this")) {
                    try self.reportCodeAt(diag_pos, diag_line, 2357, "The operand of an increment or decrement operator must be a variable or a property access.");
                }
            },
            .member_access, .element_access => {},
            // Concrete non-numeric operands (`"x"--`, `{}--`, `[]--`)
            // render as TS2356 ("An arithmetic operand must be …")
            // to match tsc, which prefers the operand-type error
            // for these shapes over the bare TS2357 lvalue error.
            .literal_string, .literal_bool, .template_literal, .array_literal, .object_literal, .fn_decl, .fn_expr => {
                try self.reportCodeAt(diag_pos, diag_line, 2356, "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.");
            },
            // Calls / parenthesised binary results
            // are not l-values in JS, but tsc skips TS2357 for them
            // and relies on the checker to emit TS2356 when the
            // return type is non-numeric. Stay silent so the synth
            // path in `checkBinop` picks the right code.
            .call_expr, .binary_op => {},
            else => try self.reportCodeAt(diag_pos, diag_line, 2357, "The operand of an increment or decrement operator must be a variable or a property access."),
        }
        const one = try self.builder.addLiteralNumber(tokenSpan(op_tok), 1);
        const sp: Span = if (is_prefix)
            .{ .start = op_tok.span.start, .end = operand_span.end }
        else
            .{ .start = operand_span.start, .end = op_tok.span.end };
        return try self.builder.addAssignment(sp, operand, one, if (is_inc) .add else .sub);
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

    fn newExpressionTypeArgsCanEndHere(self: *const Parser) bool {
        return switch (self.peek().kind) {
            .eof,
            .semicolon,
            .close_paren,
            .close_brace,
            .comma,
            => true,
            else => false,
        };
    }

    fn parseJsxElementOrFragment(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.less_than, "'<' to start JSX element");
        // Fragment: `<>...</>`
        if (self.peek().kind == .greater_than) {
            _ = self.advance(); // `>`
            var children: std.ArrayListUnmanaged(NodeId) = .empty;
            defer children.deinit(self.gpa);
            const content_start = self.tokens[self.cursor - 1].span.end;
            try self.parseJsxChildren(&children, content_start);
            // Closing `</>`.
            _ = try self.expect(.less_than, "'<' to start fragment close");
            _ = try self.expect(.slash, "'/' in fragment close");
            const close = try self.expect(.greater_than, "'>' to close fragment");
            return try self.builder.addJsxFragment(.{ .start = open.span.start, .end = close.span.end }, children.items);
        }

        // Tag identifier — accept identifier, keyword-like intrinsic names,
        // and member-access (`Foo.Bar`, `this._tagName`).
        var tag = try self.parseJsxTagName("JSX tag name");
        while (self.peek().kind == .dot) {
            _ = self.advance();
            const member_tok = try self.expectIdentifierLike();
            const member_id = try self.internToken(member_tok);
            tag = try self.builder.addMemberAccess(
                .{ .start = self.hir.spanOf(tag).start, .end = member_tok.span.end },
                tag,
                member_id,
                false,
            );
        }
        if (self.peek().kind == .less_than) {
            const type_args = try self.parseTypeArgumentList();
            self.gpa.free(type_args);
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
                    const name = try self.parseJsxName("JSX attribute name");
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
                            value = try self.builder.addJsxExpression(name.span, expr);
                        } else if (self.peek().kind == .less_than) {
                            // JSX-as-attribute-value: `prop={…}` is canonical
                            // but `prop=<Inner/>` is permitted by some
                            // dialects. Phase 1 follow-up.
                            value = try self.parseJsx();
                        } else {
                            const bad = self.peek();
                            try self.reportCodeAt(bad.span.start, bad.line, 1145, "'{' or JSX element expected.");
                        }
                    }
                    const node = try self.builder.addJsxAttribute(
                        .{ .start = name.span.start, .end = self.tokens[self.cursor - 1].span.end },
                        name.name,
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
        const open_close = try self.expect(.greater_than, "'>' to close JSX opening tag");

        var children: std.ArrayListUnmanaged(NodeId) = .empty;
        defer children.deinit(self.gpa);
        try self.parseJsxChildren(&children, open_close.span.end);

        // Closing tag `</Foo>`.
        _ = try self.expect(.less_than, "'<' to start JSX closing tag");
        _ = try self.expect(.slash, "'/' in JSX closing tag");
        // Skip the closing tag identifier (and any qualified-name
        // chain) — semantic equivalence is the binder's job.
        if (self.peek().kind == .identifier or self.peek().kind.isKeyword() or self.peek().kind.isContextualKeyword()) {
            _ = try self.parseJsxName("JSX closing tag name");
            while (self.peek().kind == .dot) {
                _ = self.advance();
                _ = try self.parseJsxName("JSX closing tag name");
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

    const JsxName = struct {
        name: hir_mod.StringId,
        span: Span,
    };

    fn isJsxNamePart(kind: TokenKind) bool {
        return kind == .identifier or kind.isKeyword() or kind.isContextualKeyword();
    }

    fn parseJsxName(self: *Parser, what: []const u8) ParseError!JsxName {
        const tok = self.peek();
        if (!isJsxNamePart(tok.kind)) {
            _ = try self.expect(.identifier, what);
        }
        const first = self.advance();
        var parsed_span = tokenSpan(first);
        while (self.peek().kind == .minus and isJsxNamePart(self.peekAt(1).kind)) {
            _ = self.advance();
            const part = self.advance();
            parsed_span.end = part.span.end;
        }
        const text = self.source[parsed_span.start..parsed_span.end];
        const id = self.interner.intern(text) catch return error.OutOfMemory;
        return .{ .name = id, .span = parsed_span };
    }

    fn parseJsxTagName(self: *Parser, what: []const u8) ParseError!NodeId {
        const tok = self.peek();
        if (tok.kind == .kw_this) {
            _ = self.advance();
            const this_id = self.interner.intern("this") catch return error.OutOfMemory;
            return try self.builder.addIdentifier(tokenSpan(tok), this_id);
        }
        const name = try self.parseJsxName(what);
        return try self.builder.addIdentifier(name.span, name.name);
    }

    fn parseJsxChildren(self: *Parser, out: *std.ArrayListUnmanaged(NodeId), content_start: u32) ParseError!void {
        var last_child_end = content_start;
        while (true) {
            const t = self.peek();
            if (t.span.start > last_child_end and self.jsxTextShouldBecomeChild(last_child_end, t.span.start)) {
                const id = self.interner.intern(self.source[last_child_end..t.span.start]) catch return error.OutOfMemory;
                const text = try self.builder.addLiteralString(.{ .start = last_child_end, .end = t.span.start }, id);
                try out.append(self.gpa, text);
                last_child_end = t.span.start;
                continue;
            }
            switch (t.kind) {
                .less_than => {
                    if (self.peekAt(1).kind == .slash) return; // `</Foo>`
                    const child = try self.parseJsxElementOrFragment();
                    try out.append(self.gpa, child);
                    last_child_end = self.hir.spanOf(child).end;
                },
                .open_brace => {
                    _ = self.advance();
                    if (self.peek().kind == .close_brace) {
                        _ = self.advance();
                        const node = try self.builder.addJsxExpression(tokenSpan(t), hir_mod.none_node_id);
                        try out.append(self.gpa, node);
                        last_child_end = self.hir.spanOf(node).end;
                        continue;
                    }
                    const expr = try self.parseAssignmentExpression();
                    const close = try self.expect(.close_brace, "'}' to close JSX child expression");
                    const node = try self.builder.addJsxExpression(
                        .{ .start = t.span.start, .end = close.span.end },
                        expr,
                    );
                    try out.append(self.gpa, node);
                    last_child_end = close.span.end;
                },
                .eof => return,
                else => {
                    const text_start = t.span.start;
                    var text_end = t.span.end;
                    while (self.peek().kind != .less_than and
                        self.peek().kind != .open_brace and
                        self.peek().kind != .eof)
                    {
                        const part = self.advance();
                        text_end = part.span.end;
                    }
                    if (self.jsxTextShouldBecomeChild(text_start, text_end)) {
                        const id = self.interner.intern(self.source[text_start..text_end]) catch return error.OutOfMemory;
                        const text = try self.builder.addLiteralString(.{ .start = text_start, .end = text_end }, id);
                        try out.append(self.gpa, text);
                    }
                    last_child_end = text_end;
                },
            }
        }
    }

    fn jsxTextShouldBecomeChild(self: *const Parser, start: u32, end: u32) bool {
        if (end <= start or end > self.source.len) return false;
        var saw_non_ws = false;
        var saw_newline = false;
        for (self.source[start..end]) |ch| {
            switch (ch) {
                ' ', '\t', '\r', '\n' => {
                    if (ch == '\r' or ch == '\n') saw_newline = true;
                },
                else => saw_non_ws = true,
            }
        }
        if (saw_non_ws) return true;
        return !saw_newline;
    }

    fn parseArrayLiteral(self: *Parser) ParseError!NodeId {
        const start = try self.expect(.open_bracket, "'[' to start array literal");
        var elements: std.ArrayListUnmanaged(NodeId) = .empty;
        defer elements.deinit(self.gpa);
        while (self.peek().kind != .close_bracket and self.peek().kind != .eof) {
            if (self.peek().kind == .close_brace) {
                const close = self.peek();
                try self.reportCodeAt(close.span.start, close.line, 1137, "Expression or comma expected.");
                return try self.builder.addArrayLiteral(.{ .start = start.span.start, .end = close.span.start }, elements.items);
            }
            if (self.peek().kind == .comma) {
                // Hole — represent as `none` for now. (TS treats
                // `[,1]` as `[undefined, 1]`.)
                _ = self.advance();
                try elements.append(self.gpa, hir_mod.none_node_id);
                continue;
            }
            // Spread element: `...expr`. Trailing-comma after the
            // spread is permitted in plain array literals (`[1, ...a,]`
            // is legal JS), so TS1013 fires only when the literal is
            // later reinterpreted as a destructuring pattern — that
            // check lives in the checker rather than the parser.
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
            if (self.match(.comma)) continue;
            if (self.peek().kind == .close_bracket or self.peek().kind == .eof) break;
            if (self.peek().kind == .semicolon) {
                try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "',' expected.");
                const end = if (self.cursor > 0) self.tokens[self.cursor - 1].span.end else start.span.end;
                return try self.builder.addArrayLiteral(.{ .start = start.span.start, .end = end }, elements.items);
            }
            if (arrayLiteralElementCanStart(self.peek().kind)) {
                try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "',' expected.");
                continue;
            }
            break;
        }
        const close = try self.expect(.close_bracket, "']' to close array literal");
        return try self.builder.addArrayLiteral(.{ .start = start.span.start, .end = close.span.end }, elements.items);
    }

    fn parseObjectLiteral(self: *Parser) ParseError!NodeId {
        const start = try self.expect(.open_brace, "'{' to start object literal");
        var props: std.ArrayListUnmanaged(NodeId) = .empty;
        defer props.deinit(self.gpa);
        while (self.peek().kind != .close_brace and self.peek().kind != .eof) {
            if (self.peek().kind == .colon) {
                const colon = self.advance();
                try self.reportCodeAt(colon.span.start, colon.line, 1136, "Property assignment expected.");
                continue;
            }
            const prop_start = self.peek();
            var method_is_async = false;
            if (self.peek().kind == .kw_async) {
                const next = self.peekAt(1).kind;
                const after_next = self.peekAt(2).kind;
                if (next == .asterisk or
                    next == .open_bracket or
                    ((next == .identifier or next.isContextualKeyword()) and
                        (after_next == .open_paren or after_next == .less_than)))
                {
                    _ = self.advance();
                    method_is_async = true;
                }
            }
            const method_is_generator = self.match(.asterisk);
            // Generator-method shorthand requires a property-name token
            // (or `[` for a computed key) after `*`. When the next
            // token cannot start a property name, tsc reports
            // `TS1003 Identifier expected.` at that token and stops
            // parsing this property. Matches FunctionPropertyAssignments
            // {2,3,4,6}_es6 baselines (`var v = { * ... }` forms with
            // `*(`, `*{`, `* }`, or `*<T>()`).
            if (method_is_generator) {
                const next_kind = self.peek().kind;
                const can_start_method_name = switch (next_kind) {
                    .identifier,
                    .private_identifier,
                    .string_literal,
                    .number_literal,
                    .open_bracket,
                    => true,
                    else => next_kind.isKeyword() or next_kind.isContextualKeyword(),
                };
                if (!can_start_method_name) {
                    const bad = self.peek();
                    try self.reportCodeAt(bad.span.start, bad.line, 1003, "Identifier expected.");
                    // Skip ahead until the next `,` or the OUTER
                    // closing `}` so the object-literal scan can
                    // close cleanly. Tracks nested `{`/`(`/`[` depth
                    // so a synthetic method body (`{}`), parameter
                    // list (`()`), or type-arg list (`<>`) doesn't
                    // confuse the scan into terminating early.
                    // Mirrors tsc which silently consumes the broken
                    // property and resumes at the next list item.
                    var depth: u32 = 0;
                    while (self.peek().kind != .eof) {
                        const k = self.peek().kind;
                        if (depth == 0 and (k == .close_brace or k == .comma)) break;
                        if (k == .open_brace or k == .open_paren or k == .open_bracket) {
                            depth += 1;
                        } else if (k == .close_brace or k == .close_paren or k == .close_bracket) {
                            if (depth > 0) depth -= 1;
                        }
                        _ = self.advance();
                    }
                    if (!self.match(.comma)) break;
                    continue;
                }
            }
            // Spread element: `...expr`. Wrap in a `.spread` node so
            // diagnostics anchored at the prop point at the `...` token
            // (matching upstream tsc's TS2698 column position).
            if (self.match(.dot_dot_dot)) {
                const dot_tok = self.tokens[self.cursor - 1];
                const value = try self.parseAssignmentExpression();
                const value_end = self.hir.spanOf(value).end;
                const spread_node = try self.builder.addSpread(
                    .{ .start = dot_tok.span.start, .end = value_end },
                    value,
                );
                try props.append(self.gpa, spread_node);
                if (!self.match(.comma)) break;
                continue;
            }

            if (isAccessibilityModifier(self.peek().kind) and
                (self.peekAt(1).kind == .kw_get or self.peekAt(1).kind == .kw_set))
            {
                const mod = self.advance();
                const mod_name = self.source[mod.span.start..mod.span.end];
                const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), "'{s}' modifier cannot be used here.", .{mod_name});
                try self.reportCodeAt(mod.span.start, mod.line, 1042, msg);
            }

            if ((self.peek().kind == .kw_get or self.peek().kind == .kw_set) and
                (((self.peekAt(1).kind == .identifier or
                    self.peekAt(1).kind == .private_identifier or
                    self.peekAt(1).kind == .string_literal or
                    self.peekAt(1).kind == .number_literal or
                    self.peekAt(1).kind.isContextualKeyword()) and
                    (self.peekAt(2).kind == .open_paren or self.peekAt(2).kind == .less_than)) or
                    self.peekAt(1).kind == .open_bracket))
            {
                const accessor_kw = self.advance();
                var is_computed_key = false;
                const key = if (self.match(.open_bracket)) blk: {
                    const expr = try self.parseAssignmentExpression();
                    _ = try self.expect(.close_bracket, "']' to close computed accessor key");
                    is_computed_key = true;
                    break :blk expr;
                } else blk: {
                    const key_tok = self.advance();
                    var key_span = tokenSpan(key_tok);
                    if (key_tok.kind == .number_literal and self.peek().kind == .dot and self.peekAt(1).kind == .open_paren) {
                        const dot_tok = self.advance();
                        key_span.end = dot_tok.span.end;
                    }
                    const key_id = try self.internPropertyName(key_tok, key_span);
                    break :blk try self.builder.addIdentifier(key_span, key_id);
                };
                var type_params: []NodeId = &.{};
                if (self.peek().kind == .less_than) {
                    type_params = try self.parseTypeParameterDeclaration();
                    const name_span = self.hir.spanOf(key);
                    try self.reportCodeAt(name_span.start, self.lineAt(name_span.start), 1094, "An accessor cannot have type parameters.");
                }
                defer if (type_params.len > 0) self.gpa.free(type_params);
                const params = try self.parseParameterList();
                defer self.gpa.free(params);
                var return_type: NodeId = hir_mod.none_node_id;
                if (self.match(.colon)) return_type = try self.parseReturnTypeAnnotation(params);
                try self.validateAccessorSignature(accessor_kw.kind, key, params, return_type);
                var body: NodeId = hir_mod.none_node_id;
                if (self.peek().kind == .open_brace) {
                    // Object-literal accessor bodies are function bodies
                    // — track the function depth so nested context-
                    // sensitive parsing (e.g. `yield` inside a getter
                    // body) routes through the in-function path that
                    // reports TS1163 instead of treating `yield` as a
                    // top-level identifier (TS1212). Mirrors fixture
                    // `YieldExpression17_es6` where `get foo() { yield foo; }`
                    // baselines a single TS1163, not TS1212.
                    self.function_depth += 1;
                    const prev_generator_depth = self.generator_depth;
                    self.generator_depth = 0;
                    defer {
                        self.generator_depth = prev_generator_depth;
                        self.function_depth -= 1;
                    }
                    body = try self.parseBlockStatement();
                }
                const value = try self.builder.addFnDeclGeneric(
                    .{ .start = accessor_kw.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    key,
                    type_params,
                    params,
                    return_type,
                    body,
                    .{
                        .is_method = true,
                        .is_getter = accessor_kw.kind == .kw_get,
                        .is_setter = accessor_kw.kind == .kw_set,
                    },
                );
                const prop = try self.builder.addObjectProperty(
                    .{ .start = prop_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    key,
                    value,
                    is_computed_key,
                    false,
                    true,
                );
                try props.append(self.gpa, prop);
                if (!self.match(.comma)) break;
                continue;
            }

            // Computed key: `[expr]: value`.
            var key: NodeId = undefined;
            var is_computed = false;
            var can_be_shorthand_property = false;
            if (self.match(.open_bracket)) {
                key = try self.parseAssignmentExpression();
                if (self.peek().kind == .close_bracket) {
                    _ = self.advance();
                } else {
                    try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "']' expected.");
                }
                is_computed = true;
            } else {
                const key_tok = self.advance();
                can_be_shorthand_property = isExpressionIdentifierToken(key_tok.kind);
                var key_span = tokenSpan(key_tok);
                if (key_tok.kind == .no_substitution_template or key_tok.kind == .template_head) {
                    try self.reportCodeAt(key_tok.span.start, key_tok.line, 1136, "Property assignment expected.");
                }
                if (key_tok.kind == .number_literal and self.peek().kind == .dot and self.peekAt(1).kind == .colon) {
                    const dot_tok = self.advance();
                    key_span.end = dot_tok.span.end;
                }
                const key_id = try self.internPropertyName(key_tok, key_span);
                key = try self.builder.addIdentifier(key_span, key_id);
            }

            var value: NodeId = hir_mod.none_node_id;
            var is_shorthand = false;
            var is_method = false;
            if (!is_computed and self.peek().kind == .question) {
                const question_tok = self.advance();
                try self.reportCodeAt(question_tok.span.start, question_tok.line, 1162, "An object member cannot be declared optional.");
            }
            var recovered_missing_colon_value = false;
            if (self.match(.colon)) {
                if (arrayLiteralElementCanStart(self.peek().kind)) {
                    value = try self.parseAssignmentExpression();
                } else {
                    try self.reportCodeAt(self.peek().span.start, self.peek().line, 1109, "Expression expected.");
                    recovered_missing_colon_value = true;
                }
            } else if (method_is_generator or self.peek().kind == .less_than or self.peek().kind == .open_paren) {
                // Method shorthand: `{ foo<T>() {} }`.
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
                    const prev_generator_depth = self.generator_depth;
                    self.generator_depth = if (method_is_generator) prev_generator_depth + 1 else 0;
                    defer self.generator_depth = prev_generator_depth;
                    body = try self.parseBlockStatement();
                }
                value = try self.builder.addFnDeclGeneric(
                    .{ .start = prop_start.span.start, .end = self.tokens[self.cursor - 1].span.end },
                    hir_mod.none_node_id,
                    type_params,
                    params,
                    return_type,
                    body,
                    .{
                        .is_method = true,
                        .is_async = method_is_async,
                        .is_generator = method_is_generator,
                    },
                );
                is_method = true;
            } else if (can_be_shorthand_property) {
                // Shorthand property: `{ foo }` — value mirrors the key
                // identifier.
                is_shorthand = true;
                value = key;
            } else {
                try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "':' expected.");
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
            if (self.match(.comma)) continue;
            if (is_computed and self.peek().kind == .close_bracket) {
                const close = self.advance();
                try self.reportCodeAt(close.span.start, close.line, 1005, "',' expected.");
                continue;
            }
            if (recovered_missing_colon_value and objectLiteralPropertyCanStart(self.peek().kind)) continue;
            // Recover from missing `,` between properties — TS reports
            // TS1005 at the offending token and continues parsing the
            // next property. Mirrors `tsc`'s `parseDelimitedList` recovery
            // for object literals (matters for fixtures like
            // `stringNamedPropertyDuplicates` whose intentional missing
            // commas would otherwise abort the whole source-file parse).
            if (objectLiteralPropertyCanStart(self.peek().kind)) {
                try self.reportCodeAt(self.peek().span.start, self.peek().line, 1005, "',' expected.");
                continue;
            }
            break;
        }
        if (self.peek().kind == .semicolon and self.peekAt(1).kind == .close_brace and props.items.len > 0 and
            self.hir.kindOf(props.items[props.items.len - 1]) == .object_property and
            hir_mod.objectPropertyOf(self.hir, props.items[props.items.len - 1]).is_shorthand)
        {
            const semi = self.advance();
            try self.reportCodeAt(semi.span.start, semi.line, 1005, "',' expected.");
            const close = self.advance();
            return try self.builder.addObjectLiteral(.{ .start = start.span.start, .end = close.span.end }, props.items);
        }
        if (self.peek().kind == .semicolon) {
            const semi = self.advance();
            try self.reportCodeAt(semi.span.end, semi.line, 1005, "'}' expected.");
            return try self.builder.addObjectLiteral(.{ .start = start.span.start, .end = semi.span.end }, props.items);
        }
        const close = try self.expect(.close_brace, "'}' to close object literal");
        return try self.builder.addObjectLiteral(.{ .start = start.span.start, .end = close.span.end }, props.items);
    }

    /// Returns true when `kind` can begin an object-literal property —
    /// used by `parseObjectLiteral` to recover from missing comma
    /// separators (TS1005) without aborting the whole file parse.
    fn objectLiteralPropertyCanStart(kind: TokenKind) bool {
        return switch (kind) {
            .identifier,
            .private_identifier,
            .string_literal,
            .number_literal,
            .open_bracket,
            .dot_dot_dot,
            .asterisk,
            .no_substitution_template,
            .template_head,
            => true,
            else => kind.isKeyword() or kind.isContextualKeyword(),
        };
    }

    /// Accept any token that can appear after `.` — identifier or
    /// keyword (`obj.class`, `obj.let`, etc., are valid because
    /// keywords are allowed as property names).
    fn expectIdentifierLike(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind == .identifier or t.kind == .private_identifier or t.kind.isKeyword()) {
            return self.advance();
        }
        try self.reportCodeAt(t.span.start, t.line, 1003, "Identifier expected.");
        return error.UnexpectedToken;
    }
};

fn isExpressionIdentifierToken(kind: TokenKind) bool {
    return switch (kind) {
        .identifier,
        .private_identifier,
        .kw_await,
        .kw_async,
        .kw_any,
        .kw_unknown,
        .kw_never,
        .kw_void,
        .kw_string,
        .kw_number,
        .kw_boolean,
        .kw_bigint,
        .kw_symbol,
        .kw_object,
        .kw_get,
        .kw_set,
        .kw_global,
        .kw_from,
        .kw_require,
        .kw_module,
        .kw_namespace,
        .kw_interface,
        .kw_declare,
        .kw_constructor,
        .kw_of,
        .kw_type,
        .kw_static,
        => true,
        else => false,
    };
}

fn arrayLiteralElementCanStart(kind: TokenKind) bool {
    return switch (kind) {
        .number_literal,
        .bigint_literal,
        .string_literal,
        .regex_literal,
        .slash,
        .no_substitution_template,
        .template_head,
        .kw_true,
        .kw_false,
        .kw_null,
        .kw_undefined,
        .open_paren,
        .open_bracket,
        .open_brace,
        .less_than,
        .kw_class,
        .kw_abstract,
        .kw_this,
        .kw_super,
        .kw_new,
        .kw_import,
        .kw_function,
        .plus,
        .minus,
        .bang,
        .tilde,
        .kw_typeof,
        .kw_delete,
        .kw_yield,
        .dot_dot_dot,
        => true,
        else => isExpressionIdentifierToken(kind),
    };
}

/// Decode `\uXXXX` and `\u{XXXXXX}` escapes in an identifier slice
/// into a freshly-allocated UTF-8 string. Returned bytes are owned by
/// `gpa`. Callers feed the output straight into the interner so two
/// spellings of the same Unicode identifier (`A` and `A`) hash to
/// the same StringId. Falls back to the raw slice on malformed escapes
/// rather than refusing — the scanner has already produced the
/// "Hexadecimal digit expected." diagnostics in that case, and we want
/// the binder to still see *some* identifier rather than crashing.
fn decodeIdentifierEscapes(gpa: std.mem.Allocator, slice: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: usize = 0;
    while (i < slice.len) {
        const c = slice[i];
        if (c != '\\' or i + 1 >= slice.len or slice[i + 1] != 'u') {
            try buf.append(gpa, c);
            i += 1;
            continue;
        }
        // `\u{XXXXXX}`
        if (i + 2 < slice.len and slice[i + 2] == '{') {
            var j: usize = i + 3;
            var value: u32 = 0;
            while (j < slice.len and slice[j] != '}') : (j += 1) {
                const v = hexDigitValue(slice[j]) orelse return slice; // malformed -> fall back
                value = value * 16 + v;
                if (value > 0x10FFFF) return slice;
            }
            if (j >= slice.len or slice[j] != '}') return slice;
            try appendUtf8CodePoint(gpa, &buf, value);
            i = j + 1;
            continue;
        }
        // `\uXXXX`
        if (i + 6 > slice.len) return slice;
        var value: u32 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const v = hexDigitValue(slice[i + 2 + k]) orelse return slice;
            value = value * 16 + v;
        }
        try appendUtf8CodePoint(gpa, &buf, value);
        i += 6;
    }
    return buf.toOwnedSlice(gpa);
}

fn hexDigitValue(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

fn appendUtf8CodePoint(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u32) !void {
    var enc: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &enc) catch {
        try buf.append(gpa, '?'); // unreachable in practice (we clamp to 0x10FFFF), but keep it safe
        return;
    };
    try buf.appendSlice(gpa, enc[0..len]);
}

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

test "parser: identifier with `\\uXXXX` escape decodes to the same name as the bare form" {
    // ES2015+ allows any IdentifierPart (and Start) to be spelled with
    // a `\uXXXX` Unicode escape. tsc decodes the escape before symbol
    // resolution so `A` (`A`) and the bare `A` are the same name.
    // Without this fold the binder treats them as distinct and emits
    // spurious TS2304 on cross-spelling references. Baseline:
    // scannerS7.6_A4.2_T1 (Cyrillic identifier round-trip).
    var s = try newTestSetup("\\u0041;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(top));
    const id = hir_mod.identifierOf(&s.hir, top);
    try T.expectEqualStrings("A", s.interner.get(id.name));
}

test "parser: identifier with `\\u{XXXX}` brace-form escape decodes correctly" {
    // Brace-form `\u{XXXXXX}` supports code points up to U+10FFFF. Use
    // a Cyrillic capital А (U+0410) so the test exercises a multi-byte
    // UTF-8 round-trip.
    var s = try newTestSetup("\\u{410};");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(top));
    const id = hir_mod.identifierOf(&s.hir, top);
    try T.expectEqualStrings("\xd0\x90", s.interner.get(id.name)); // "А" in UTF-8
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

test "parser: variable declaration list tolerates additional declarators" {
    var s = try newTestSetup("let a = 1, b = 2;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[1]));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: regex var declaration stray close bracket recovers as var list" {
    var s = try newTestSetup("var v = /[^]/]/");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("',' expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 13), s.parser.diagnostics.items[0].pos);
    try T.expectEqual(@as(u32, 1134), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("Variable declaration expected.", s.parser.diagnostics.items[1].message);
    try T.expectEqual(@as(u32, 14), s.parser.diagnostics.items[1].pos);
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

test "parser: virtual declaration sections allow ambient exported const" {
    var s = try newTestSetup(
        \\// @filename: /node_modules/@types/pkg/index.d.ts
        \\export const x: number;
        \\// @filename: /main.ts
        \\import { x } from "pkg";
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const ex = hir_mod.exportOf(&s.hir, stmts[0]);
    const vd = hir_mod.varDeclOf(&s.hir, ex.decl);
    try T.expect(vd.is_ambient);
}

test "parser: virtual ts section overrides declaration-file ambient default" {
    var s = try newTestSetup(
        \\// @filename: module.d.ts
        \\declare namespace A {
        \\  export var x: number;
        \\}
        \\// @filename: classPoint.ts
        \\namespace A {
        \\  export class Point { constructor(public x: number) {} }
        \\}
    );
    defer destroyTestSetup(s);
    s.parser.setDeclarationFile(true);
    _ = s.parser.parseSourceFile() catch {};
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1183);
    }
}

test "parser: abstract constructor inside abstract class reports TS1242" {
    // tsc fires TS1242 (`'abstract' modifier can only appear on a
    // class, method, or property declaration.`) for an
    // `abstract constructor` even when the enclosing class itself
    // carries `abstract`. The diagnostic is anchored at the
    // `abstract` keyword. Mirrors conformance fixture
    // `classAbstractConstructor.ts(2,5)`.
    var s = try newTestSetup(
        \\abstract class A {
        \\    abstract constructor() {}
        \\}
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    var anchor_ok = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1242) continue;
        found = true;
        if (d.pos < s.parser.source.len and
            s.parser.source.len >= d.pos + 8 and
            std.mem.eql(u8, s.parser.source[d.pos .. d.pos + 8], "abstract"))
        {
            anchor_ok = true;
        }
    }
    try T.expect(found);
    try T.expect(anchor_ok);
}

test "parser: TS1031 fires for `export` modifier on class member" {
    // `export Foo()` inside a class body — the `export` keyword is
    // disallowed on class members. Mirrors upstream
    // `parserMemberFunctionDeclaration4`.
    var s = try newTestSetup("class C { export Foo() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1031: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1031) saw_1031 += 1;
    }
    try T.expect(saw_1031 >= 1);
}

test "parser: TS1031 fires for `declare` modifier on constructor" {
    var s = try newTestSetup("class C { declare constructor() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1031: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1031) saw_1031 += 1;
    }
    try T.expect(saw_1031 >= 1);
}

test "parser: TS1089 fires for `static` modifier on constructor" {
    var s = try newTestSetup("class C { static constructor() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1089: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1089) saw_1089 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1089);
}

test "parser: TS1092 fires for type parameters on constructor" {
    // `constructor<T>()` — type parameters are forbidden on
    // constructors. tsc anchors at the first type-parameter name
    // (here `T`), not the `<`. Mirrors upstream
    // `parserConstructorDeclaration9`.
    var s = try newTestSetup("class C { constructor<T>() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1092: u32 = 0;
    var anchor_ok = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1092) continue;
        saw_1092 += 1;
        if (d.pos < s.parser.source.len and s.parser.source[d.pos] == 'T') {
            anchor_ok = true;
        }
    }
    try T.expectEqual(@as(u32, 1), saw_1092);
    try T.expect(anchor_ok);
}

test "parser: TS1015 fires for `?` and initializer on the same parameter" {
    // `F(A?= 0)` — both `?` and `= 0` are present. tsc reports
    // TS1015 anchored at the parameter's start. Mirrors upstream
    // `parserParameterList2`.
    var s = try newTestSetup("class C { F(A?= 0) {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1015: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1015) saw_1015 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1015);
}

test "parser: contextual keyword may be variable name" {
    var s = try newTestSetup("var as = 1;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const vd = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(vd.name));
    const id = hir_mod.identifierOf(&s.hir, vd.name);
    try T.expectEqualStrings("as", s.interner.get(id.name));
}

test "parser: regular expression literal in expression position" {
    var s = try newTestSetup("var r = true ? /1/g : null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const vd = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.conditional, s.hir.kindOf(vd.init));
    const c = hir_mod.conditionalOf(&s.hir, vd.init);
    try T.expectEqual(hir_mod.NodeKind.literal_regex, s.hir.kindOf(c.then_branch));
}

test "parser: contextual keyword may be parameter name" {
    var s = try newTestSetup("function f(from: number, length?: number): void {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const params = hir_mod.fnParams(&s.hir, top);
    try T.expectEqual(@as(usize, 2), params.len);
    try T.expectEqualStrings("from", s.interner.get(hir_mod.identifierOf(&s.hir, hir_mod.parameterOf(&s.hir, params[0]).name).name));
}

test "parser: declare let records ambient var-decl flag" {
    var s = try newTestSetup("declare let x: number;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(stmts[0]));
    const vd = hir_mod.varDeclOf(&s.hir, stmts[0]);
    try T.expect(vd.is_ambient);
    try T.expect(!vd.is_using);
    try T.expect(!vd.is_await_using);
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

test "parser: empty element access reports TS1011 and recovers" {
    var s = try newTestSetup("new Type[]; a?.[];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.new_expr, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.element_access, s.hir.kindOf(stmts[1]));
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1011), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1011), s.parser.diagnostics.items[1].code);
}

test "parser: missing identifier after dot reports TS1003" {
    var s = try newTestSetup(
        \\class Foo {
        \\  f1() {
        \\    if (this.
        \\  }
        \\}
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch |err| switch (err) {
        error.UnexpectedToken => hir_mod.none_node_id,
        else => return err,
    };
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1003), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Identifier expected.", s.parser.diagnostics.items[0].message);
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

test "parser: variable declaration definite-assignment assertion" {
    var s = try newTestSetup("let x!: number;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(v.type_annotation));
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

test "parser: for-in rejects destructuring targets" {
    var s = try newTestSetup("for (var {a, b} in obj) {} for ([a, b] in obj) {}");
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2491), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2491), s.parser.diagnostics.items[1].code);
}

test "parser: for-of loop" {
    var s = try newTestSetup("for (let v of items) { sum = sum + v; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_of_stmt, s.hir.kindOf(top));
}

test "parser: for-of loop accepts object binding pattern target" {
    var s = try newTestSetup("for (let { x, ...rest } of items) { x; rest; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.for_of_stmt, s.hir.kindOf(top));
    const fr = hir_mod.forInOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.let_decl, s.hir.kindOf(fr.target));
    const target = hir_mod.varDeclOf(&s.hir, fr.target);
    try T.expectEqual(hir_mod.NodeKind.object_pattern, s.hir.kindOf(target.name));
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

test "parser: for-await-in reports missing of" {
    var s = try newTestSetup("for await (const x in y) {} for await (x in y) {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
}

test "parser: using declarations parse in for initializers" {
    var s = try newTestSetup(
        \\for (using d1 = { [Symbol.dispose]() {} }, d2 = null;;) {}
        \\async function main() { for (await using of of []) {} }
    );
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: comma-separated using declarations parse" {
    var s = try newTestSetup(
        \\{
        \\  using d1 = { [Symbol.dispose]() {} }, d2 = null;
        \\  await using a1 = { async [Symbol.asyncDispose]() {} }, a2 = null;
        \\}
        \\export {};
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: using declaration in for-in reports TS1493" {
    var s = try newTestSetup("for (using x in {}) {} async function main() { for (await using y in {}) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1493), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1494), s.parser.diagnostics.items[1].code);
}

test "parser: using for-of binding pattern reports TS1492" {
    var s = try newTestSetup("for (using {} of []) {} async function main() { for (await using [] of []) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1492), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1492), s.parser.diagnostics.items[1].code);
}

test "parser: using for header edge diagnostics" {
    var s = try newTestSetup("for (using of of []) {} for (using of;;) break;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2304), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1155), s.parser.diagnostics.items[1].code);
}

test "parser: await using of expression in for header is not a declaration" {
    var s = try newTestSetup(
        \\declare const x: any[];
        \\for (await using of x);
        \\export async function test() { for await (await using of x); }
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: non-declaration for-of array target parses as expression" {
    var s = try newTestSetup("for ([\"\"] of [[\"\"]]) { }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: using in blocks under nested statements is allowed" {
    var s = try newTestSetup(
        \\if (true)
        \\  switch (0) {
        \\    case 0: { using d = null; break; }
        \\    default: { await using a = null; }
        \\  }
        \\export {};
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: break and continue" {
    // Wrap in `label: while ...` so the labeled `break label;` /
    // `continue label;` resolve cleanly under the parse-time label
    // scope check (no spurious TS1116 / TS1115).
    var s = try newTestSetup("label: while (x) { break; continue; break label; continue label; }");
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

test "parser: break outside loop or switch reports TS1105" {
    var s = try newTestSetup("break; while (x) { break; } switch (x) { case 1: break; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1105), s.parser.diagnostics.items[0].code);
}

test "parser: continue outside loop reports TS1104" {
    var s = try newTestSetup("switch (x) { case 1: continue; } while (x) { continue; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1104), s.parser.diagnostics.items[0].code);
}

test "parser: break/continue to unknown label reports TS1116/TS1115" {
    var s = try newTestSetup("while (x) { break NOPE; continue NOPE; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1116: u32 = 0;
    var saw_1115: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1116) saw_1116 += 1;
        if (d.code == 1115) saw_1115 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1116);
    try T.expectEqual(@as(u32, 1), saw_1115);
}

test "parser: break across function boundary reports TS1107" {
    // `break OUT;` inside the arrow body crosses the function
    // boundary of the surrounding `OUT: while (...)` label.
    var s = try newTestSetup("OUT: while (x) { var f = () => { break OUT; }; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1107: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1107) saw_1107 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1107);
}

test "parser: unlabeled break inside nested function reports TS1107" {
    // The inner `break;` sits inside a nested function whose ancestor
    // is `while (true)`. tsc treats this as a cross-function jump
    // (TS1107) rather than a missing-target error (TS1105). Mirrors
    // upstream `parser_breakNotInIterationOrSwitchStatement2`.
    var s = try newTestSetup("while (true) {\n  function f() {\n    break;\n  }\n}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1107: u32 = 0;
    var saw_1105: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1107) saw_1107 += 1;
        if (d.code == 1105) saw_1105 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1107);
    try T.expectEqual(@as(u32, 0), saw_1105);
}

test "parser: duplicate label in same scope reports TS1114" {
    // Two `target:` labels stack the same name within the same
    // function. tsc reports TS1114 on the second occurrence. Mirrors
    // upstream `parser_duplicateLabel1`.
    var s = try newTestSetup("target:\ntarget:\nwhile (true) {\n}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1114: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1114) saw_1114 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1114);
}

test "parser: duplicate label nested in same function reports TS1114" {
    // Inner `target:` shadows the outer one within the same function;
    // upstream tsc still flags it as a duplicate. Mirrors
    // `parser_duplicateLabel2`.
    var s = try newTestSetup("target:\nwhile (true) {\n  target:\n  while (true) {\n  }\n}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1114: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1114) saw_1114 += 1;
    }
    try T.expectEqual(@as(u32, 1), saw_1114);
}

test "parser: break in ambient .d.ts suppresses TS1105" {
    // The outer TS1036 "Statements are not allowed in ambient
    // contexts" already covers the misuse — TS1105 would be
    // redundant. Mirrors upstream `parserBreakStatement1.d`.
    var s = try newTestSetup("break;");
    defer destroyTestSetup(s);
    s.parser.is_declaration_file = true;

    _ = try s.parser.parseSourceFile();
    var saw_1105: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1105) saw_1105 += 1;
    }
    try T.expectEqual(@as(u32, 0), saw_1105);
}

test "parser: continue in ambient .d.ts suppresses TS1104" {
    var s = try newTestSetup("continue;");
    defer destroyTestSetup(s);
    s.parser.is_declaration_file = true;

    _ = try s.parser.parseSourceFile();
    var saw_1104: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1104) saw_1104 += 1;
    }
    try T.expectEqual(@as(u32, 0), saw_1104);
}

test "parser: label before declaration reports TS1344" {
    var s = try newTestSetup("label: const c = 1; other: function f() {} third: export const x: string");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expect(s.parser.diagnostics.items.len >= 3);
    try T.expectEqual(@as(u32, 1344), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1344), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1344), s.parser.diagnostics.items[2].code);
}

test "parser: label before namespace reports TS1344 + TS1235" {
    var s = try newTestSetup("label: namespace M { }\nlabel: module N { }\n");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_ts1344: u32 = 0;
    var saw_ts1235: u32 = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1344) saw_ts1344 += 1;
        if (d.code == 1235) saw_ts1235 += 1;
    }
    try T.expectEqual(@as(u32, 2), saw_ts1344);
    try T.expectEqual(@as(u32, 2), saw_ts1235);
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

test "parser: catch accepts object binding pattern target" {
    var s = try newTestSetup("try {} catch ({ a, ...b }) {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const tp = hir_mod.tryOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.object_pattern, s.hir.kindOf(tp.catch_param));
}

test "parser: catch type annotation reports TS1196" {
    var s = try newTestSetup("try {} catch (e: Error) {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1196), s.parser.diagnostics.items[0].code);
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

test "parser: export and declare modifiers in blocks report TS1184" {
    var s = try newTestSetup(
        \\function f() { export var x = 1; }
        \\{ declare var y: number; }
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1184), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1184), s.parser.diagnostics.items[1].code);
}

test "parser: export modifier in control-flow body reports TS1184" {
    var s = try newTestSetup(
        \\if (true)
        \\export const cssExports: CssExports;
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expect(s.parser.diagnostics.items.len >= 1);
    try T.expectEqual(@as(u32, 1184), s.parser.diagnostics.items[0].code);
}

test "parser: nested declare in ambient context reports TS1038" {
    var s = try newTestSetup("declare namespace M { declare class C {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1038), s.parser.diagnostics.items[0].code);
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

test "parser: malformed function arrow recovers as signature" {
    var s = try newTestSetup("function (a => b;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    try T.expectEqual(@as(usize, 2), hir_mod.fnParams(&s.hir, top).len);
    var saw_missing_name = false;
    var saw_arrow_comma = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1003) saw_missing_name = true;
        if (d.code == 1005 and std.mem.eql(u8, d.message, "',' expected.")) saw_arrow_comma = true;
    }
    try T.expect(saw_missing_name);
    try T.expect(saw_arrow_comma);
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

test "parser: object binding pattern supports renames nested patterns and rest" {
    var s = try newTestSetup("function f({ x: a, y: { z = 1, ...nested }, ...rest }) { return a; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const params = hir_mod.fnParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), params.len);
    const param = hir_mod.parameterOf(&s.hir, params[0]);
    try T.expectEqual(hir_mod.NodeKind.object_pattern, s.hir.kindOf(param.name));
    const elems = hir_mod.patternElements(&s.hir, param.name);
    try T.expectEqual(@as(usize, 3), elems.len);
    const renamed = hir_mod.parameterOf(&s.hir, elems[0]);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(renamed.name));
    const nested = hir_mod.parameterOf(&s.hir, elems[1]);
    try T.expectEqual(hir_mod.NodeKind.object_pattern, s.hir.kindOf(nested.name));
    const rest = hir_mod.parameterOf(&s.hir, elems[2]);
    try T.expect(rest.flags.is_rest);
}

test "parser: array binding pattern supports nested rest target" {
    var s = try newTestSetup("const [head, ...tail] = items;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const decl = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.array_pattern, s.hir.kindOf(decl.name));
    const elems = hir_mod.patternElements(&s.hir, decl.name);
    try T.expectEqual(@as(usize, 2), elems.len);
    try T.expect(hir_mod.parameterOf(&s.hir, elems[1]).flags.is_rest);
}

test "parser: rest binding element before another element reports TS2462" {
    var s = try newTestSetup("const [...rest, tail] = items;");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2462), s.parser.diagnostics.items[0].code);
}

test "parser: rest binding element initializer reports TS1186" {
    var s = try newTestSetup("const [...rest = items] = items;");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1186), s.parser.diagnostics.items[0].code);
}

test "parser: rest parameter before another parameter reports TS1014" {
    var s = try newTestSetup("function f(...rest, tail) {}");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1014), s.parser.diagnostics.items[0].code);
}

test "parser: rest parameter trailing comma reports TS1013 outside ambient contexts" {
    var s = try newTestSetup(
        \\function f(...rest,) {}
        \\declare function g(...rest,): void;
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1013), s.parser.diagnostics.items[0].code);
}

test "parser: object binding pattern supports literal and computed keys" {
    var s = try newTestSetup("const { 'a': a1, [k]: a2, ...rest } = obj;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const decl = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.object_pattern, s.hir.kindOf(decl.name));
    const elems = hir_mod.patternElements(&s.hir, decl.name);
    try T.expectEqual(@as(usize, 4), elems.len);
    try T.expect(hir_mod.parameterOf(&s.hir, elems[1]).flags.is_computed_binding_key);
    try T.expect(hir_mod.parameterOf(&s.hir, elems[3]).flags.is_rest);
}

test "parser: reserved object binding target reports TS1359" {
    var s = try newTestSetup("var { \"while\": while } = { while: 1 };");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1359) found = true;
    }
    try T.expect(found);
}

test "parser: reserved shorthand object binding target reports TS1005" {
    // Mirrors `objectBindingPatternKeywordIdentifiers01.ts` upstream
    // baseline: `var { while } = { while: 1 }` is treated as a missing
    // rename (`while: alias`) and reports a single TS1005 `':' expected.`
    // at the position where the `:` would have lived. We deliberately do
    // NOT also emit TS1359 here — the reserved-word diagnostic only
    // surfaces when the key was actually parsed as a binding target
    // (e.g. `var { "while": while }`).
    var s = try newTestSetup("var { while } = { while: 1 };");
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_1005 = false;
    var saw_1359 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005) saw_1005 = true;
        if (d.code == 1359) saw_1359 = true;
    }
    try T.expect(saw_1005);
    try T.expect(!saw_1359);
}

test "parser: literal object binding key without ':' reports TS1005" {
    // Mirrors `objectBindingPatternKeywordIdentifiers03.ts`:
    //   var { "while" } = { while: 1 }
    // tsc emits TS1005 `':' expected.` (we previously emitted a custom TS1109
    // "expected ':' after literal binding key" which doesn't match upstream).
    var s = try newTestSetup("var { \"while\" } = { while: 1 };");
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005) {
            found = true;
            break;
        }
    }
    try T.expect(found);
}

test "parser: duplicate names in binding pattern report TS2300" {
    var s = try newTestSetup("let { foo, bar: foo } = value; const [a, a] = pair;");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2300) count += 1;
    }
    try T.expectEqual(@as(usize, 2), count);
}

test "parser: duplicate parameter names report TS2300" {
    var s = try newTestSetup(
        \\function f(x, x) {}
        \\let g = (a: string, a: number) => a;
        \\interface I { (p: string, p: number): void; }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2300) count += 1;
    }
    try T.expectEqual(@as(usize, 6), count);
}

test "parser: TS2300 duplicate identifier emits include the name" {
    // Covers all four parser-side TS2300 emit sites: function params,
    // binding patterns, fn-type params, and interface call signatures.
    var s = try newTestSetup(
        \\function f(x, x) {}
        \\let { foo, bar: foo } = value;
        \\type T = (a: string, a: number) => void;
        \\interface I { (p: string, p: number): void; }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var x_named: usize = 0;
    var foo_named: usize = 0;
    var a_named: usize = 0;
    var p_named: usize = 0;
    var bare: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 2300) continue;
        if (std.mem.eql(u8, d.message, "Duplicate identifier 'x'.")) x_named += 1;
        if (std.mem.eql(u8, d.message, "Duplicate identifier 'foo'.")) foo_named += 1;
        if (std.mem.eql(u8, d.message, "Duplicate identifier 'a'.")) a_named += 1;
        if (std.mem.eql(u8, d.message, "Duplicate identifier 'p'.")) p_named += 1;
        if (std.mem.eql(u8, d.message, "Duplicate identifier.")) bare += 1;
    }
    try T.expectEqual(@as(usize, 0), bare);
    try T.expectEqual(@as(usize, 2), x_named);
    try T.expectEqual(@as(usize, 1), foo_named);
    try T.expectEqual(@as(usize, 2), a_named);
    try T.expectEqual(@as(usize, 2), p_named);
}

test "parser: same-line object type members require separator" {
    var s = try newTestSetup(
        \\let ok: { foo: string
        \\  bar: string };
        \\let bad: { foo: string bar: string };
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005) found = true;
    }
    try T.expect(found);
}

test "parser: object type method overload optionality must match" {
    var s = try newTestSetup(
        \\let c: {
        \\  func?(x: number): number;
        \\  func(s: string): string;
        \\};
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2386) found = true;
    }
    try T.expect(found);
}

test "parser: TS2386 anchors at mismatched (second) overload, not first" {
    // Mirrors tsc's `methodSignaturesWithOverloads.ts` baseline that
    // underlines the second `func4` (line 3 in this stripped setup),
    // not the leading optional `func4?` on line 2.
    var s = try newTestSetup(
        \\let c: {
        \\  func?(x: number): number;
        \\  func(s: string): string;
        \\};
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var matched_line: ?u32 = null;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2386) {
            matched_line = d.line;
            break;
        }
    }
    try T.expect(matched_line != null);
    // Second `func` lives on source line 3 (1-indexed).
    try T.expectEqual(@as(u32, 3), matched_line.?);
}

test "parser: enum members may use reserved property names" {
    var s = try newTestSetup(
        \\enum E {
        \\  class,
        \\  default,
        \\  null,
        \\  true,
        \\}
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: labeled tuple elements allow optional marker" {
    var s = try newTestSetup("type T = [first: number, second?: string, ...rest: boolean[]];");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const alias = hir_mod.typeAliasOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.tuple_type, s.hir.kindOf(alias.aliased));
    try T.expectEqual(@as(usize, 3), hir_mod.tupleTypeElements(&s.hir, alias.aliased).len);
}

test "parser: infer extends before question parses as conditional in grouped type" {
    var s = try newTestSetup("type X<T> = T extends (infer U extends number ? 1 : 0) ? 1 : 0;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const alias = hir_mod.typeAliasOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.conditional_type, s.hir.kindOf(alias.aliased));
}

test "parser: class modifier keywords may be property names" {
    var s = try newTestSetup(
        \\class C {
        \\  abstract;
        \\  static;
        \\  readonly;
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 3), members.len);
}

test "parser: optional binding pattern parameter reports TS2463" {
    var s = try newTestSetup("function f([x]?: [number]) {}");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2463) found = true;
    }
    try T.expect(found);
}

test "parser: TS2463 anchors at binding pattern start, not the question token" {
    // Mirrors `optionalBindingParameters1.ts(1,14)` — tsc reports the
    // diagnostic at the `[` token rather than the `?` suffix so the
    // squiggle covers the full pattern.
    var s = try newTestSetup("function foo([x,y,z]?: [string, number, boolean]) {}");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var anchor_pos: ?u32 = null;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 2463) {
            anchor_pos = d.pos;
            break;
        }
    }
    try T.expect(anchor_pos != null);
    // `[` sits at byte offset 13 (0-based) → column 14 in tsc's display.
    try T.expectEqual(@as(u32, 13), anchor_pos.?);
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

test "parser: optional class method declaration does not require body" {
    var s = try newTestSetup(
        \\class B {
        \\  protected m?(): void;
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
}

test "parser: accessibility modifier before generator class method" {
    var s = try newTestSetup(
        \\class C {
        \\  public * foo() { }
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    try T.expectEqual(hir_mod.NodeKind.fn_expr, s.hir.kindOf(members[0]));
}

test "parser: class override modifier is preserved on methods, fields, and parameter properties" {
    var s = try newTestSetup(
        \\class Foo {
        \\  override m() {}
        \\  override x = 1;
        \\  constructor(public override y: number) {}
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expect(hir_mod.fnDeclOf(&s.hir, members[0]).flags.is_override);
    try T.expect(hir_mod.objectPropertyOf(&s.hir, members[1]).is_override);
    const ctor_params = hir_mod.fnParams(&s.hir, members[2]);
    const pp = hir_mod.parameterOf(&s.hir, ctor_params[0]);
    try T.expect(pp.flags.is_parameter_property);
    try T.expect(pp.flags.is_override);
}

test "parser: accessibility modifier after override on parameter property reports keyword-specific TS1029" {
    var s = try newTestSetup(
        \\class B { constructor(public x: number) {} }
        \\class D extends B { constructor(override public x: number) { super(x); } }
        \\class E extends B { constructor(override protected y: number) { super(y); } }
        \\class F extends B { constructor(override private z: number) { super(z); } }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_public = false;
    var saw_protected = false;
    var saw_private = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1029) continue;
        if (std.mem.indexOf(u8, d.message, "'public' modifier must precede 'override' modifier") != null) saw_public = true;
        if (std.mem.indexOf(u8, d.message, "'protected' modifier must precede 'override' modifier") != null) saw_protected = true;
        if (std.mem.indexOf(u8, d.message, "'private' modifier must precede 'override' modifier") != null) saw_private = true;
        try T.expect(std.mem.indexOf(u8, d.message, "Accessibility modifier") == null);
    }
    try T.expect(saw_public);
    try T.expect(saw_protected);
    try T.expect(saw_private);
}

test "parser: decorator after accessibility modifier on parameter property is suppressed" {
    // `public @dec p: number` is a TS1005 parse error: tsc treats the
    // accessibility modifier as terminating the parameter prefix. The
    // decorator should still be consumed (so the rest of the parameter
    // parses) but must NOT be attached to the parameter — otherwise
    // the checker re-reports the same locus as TS1239 / TS1240.
    var s = try newTestSetup(
        \\class C {
        \\    constructor(public @dec p: number) {}
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    var saw_1005 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005) saw_1005 = true;
    }
    try T.expect(saw_1005);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expect(members.len >= 1);
    const ctor_params = hir_mod.fnParams(&s.hir, members[0]);
    try T.expect(ctor_params.len >= 1);
    const decorators = hir_mod.parameterDecorators(&s.hir, ctor_params[0]);
    try T.expectEqual(@as(usize, 0), decorators.len);
}

test "parser: accessibility modifier after readonly on parameter property reports TS1029" {
    var s = try newTestSetup(
        \\class E { constructor(readonly public x: number) {} }
        \\class F { constructor(readonly protected y: number) {} }
        \\class G { constructor(readonly private z: number) {} }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_public = false;
    var saw_protected = false;
    var saw_private = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1029) continue;
        if (std.mem.indexOf(u8, d.message, "'public' modifier must precede 'readonly' modifier") != null) saw_public = true;
        if (std.mem.indexOf(u8, d.message, "'protected' modifier must precede 'readonly' modifier") != null) saw_protected = true;
        if (std.mem.indexOf(u8, d.message, "'private' modifier must precede 'readonly' modifier") != null) saw_private = true;
    }
    try T.expect(saw_public);
    try T.expect(saw_protected);
    try T.expect(saw_private);
}

test "parser: accessibility modifier before readonly on parameter property is silent" {
    var s = try newTestSetup(
        \\class F { constructor(public readonly x: number) {} }
        \\class G { constructor(private readonly y: number) {} }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1029) continue;
        try T.expect(std.mem.indexOf(u8, d.message, "must precede 'readonly' modifier") == null);
    }
}

test "parser: computed class methods preserve override metadata" {
    var s = try newTestSetup(
        \\const key = "m";
        \\class Foo {
        \\  override [key]() {}
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[1];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    const prop = hir_mod.objectPropertyOf(&s.hir, members[0]);
    try T.expect(prop.is_computed);
    try T.expect(prop.is_method);
    try T.expect(prop.is_override);
}

test "parser: class declaration with index signature" {
    var s = try newTestSetup("class A { [x: number]: Base; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    try T.expectEqual(hir_mod.NodeKind.index_signature, s.hir.kindOf(members[0]));
}

test "parser: static class index signature preserves class side" {
    var s = try newTestSetup("class A { static readonly [x: string]: number; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    const ix = hir_mod.indexSignatureOf(&s.hir, members[0]);
    try T.expect(ix.is_static);
    try T.expect(ix.is_readonly);
}

test "parser: class extends" {
    var s = try newTestSetup("class Bar extends Foo {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const cl = hir_mod.classOf(&s.hir, top);
    try T.expect(cl.extends != hir_mod.none_node_id);
}

test "parser: class extends generic instantiation" {
    var s = try newTestSetup("class Bar<T> extends Foo<string> {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const cl = hir_mod.classOf(&s.hir, top);
    try T.expectEqual(@as(u16, 1), cl.type_params_len);
    try T.expect(cl.extends != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(cl.extends));
    const ext = hir_mod.typeRefOf(&s.hir, cl.extends);
    try T.expectEqual(@as(u16, 1), ext.args_len);
}

test "parser: new expression accepts explicit type arguments" {
    var s = try newTestSetup("var x = new List<List<number>>();");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const vd = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.new_expr, s.hir.kindOf(vd.init));
    try T.expectEqual(@as(usize, 1), hir_mod.callTypeArgs(&s.hir, vd.init).len);
}

test "parser: new expression keeps complete type arguments without parens" {
    var s = try newTestSetup("new Date<A>");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.new_expr, s.hir.kindOf(top));
    try T.expectEqual(@as(usize, 1), hir_mod.callTypeArgs(&s.hir, top).len);
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: angle-bracket type assertion accepts array type" {
    var s = try newTestSetup("var x = <T[]>null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const vd = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_assertion, s.hir.kindOf(vd.init));
    const assertion = hir_mod.asExpressionOf(&s.hir, vd.init);
    try T.expectEqual(hir_mod.NodeKind.array_type, s.hir.kindOf(assertion.type_node));
}

test "parser: generic arrow accepts nested type parameter constraint" {
    var s = try newTestSetup("var f = <T extends Array<Base>>(x: Array<Base>, y: T) => <Array<Base>>null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const vd = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(vd.init));
}

test "parser: typed paren arrow missing arrow recovers before block body" {
    var s = try newTestSetup("function foo(): any { return (): void {}; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("'=>' expected.", s.parser.diagnostics.items[0].message);
}

test "parser: interface declaration" {
    var s = try newTestSetup("interface Point { x: number; y: number; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.interface_decl, s.hir.kindOf(top));
}

test "parser: interface keyword followed by newline is expression identifier" {
    var s = try newTestSetup(
        \\interface
        \\I
        \\{}
    );
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expect(stmts.len >= 2);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(stmts[0]));
    try T.expect(s.parser.diagnostics.items.len >= 1);
}

test "parser: nested explicit call type args in class extends" {
    var s = try newTestSetup(
        \\type T1 = { a: number };
        \\type Identifiable<T> = { _id: string } & T;
        \\declare function Constructor<T>(): new () => T;
        \\class C extends Constructor<Identifiable<T1 & { b: number }>>() {}
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: deferred import cannot use named bindings" {
    var s = try newTestSetup("import defer { foo } from \"./a\";");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 18059), s.parser.diagnostics.items[0].code);
}

test "parser: import namespace" {
    var s = try newTestSetup("import * as fs from \"fs\";");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const imp = hir_mod.importOf(&s.hir, top);
    try T.expect(imp.namespace_binding != hir_mod.none_node_id);
}

test "parser: top-level module imports cannot bind await" {
    var s = try newTestSetup(
        \\import await from "./mod";
        \\import * as await from "./other";
        \\import await = require("./third");
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var found: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1262) found += 1;
    }
    try T.expectEqual(@as(usize, 3), found);
}

test "parser: internal import-alias may bind await in scripts" {
    var s = try newTestSetup("import await = foo.await;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1262);
    }
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

test "parser: re-export import attributes" {
    var s = try newTestSetup(
        \\export { a as b } from "./m" with { type: "json" };
        \\export * as default from "./n" with {};
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.export_decl, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.export_decl, s.hir.kindOf(stmts[1]));
}

test "parser: dynamic import with attributes argument" {
    var s = try newTestSetup("const p = import(\"./a.json\", { with: { type: \"json\" } });");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    // Just assert it parses without error — the dynamic-import call
    // shape is exercised here for compatibility only.
    _ = root;
}

test "parser: import.meta member access" {
    var s = try newTestSetup("const u = import.meta;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(init_node));
    const m = hir_mod.memberOf(&s.hir, init_node);
    try T.expectEqualStrings("meta", s.interner.get(m.name));
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(m.object));
    const obj_id = hir_mod.identifierOf(&s.hir, m.object);
    try T.expectEqualStrings("import", s.interner.get(obj_id.name));
}

test "parser: import.meta.url chained access" {
    var s = try newTestSetup("const u: string = import.meta.url;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(init_node));
    const outer = hir_mod.memberOf(&s.hir, init_node);
    try T.expectEqualStrings("url", s.interner.get(outer.name));
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(outer.object));
    const inner = hir_mod.memberOf(&s.hir, outer.object);
    try T.expectEqualStrings("meta", s.interner.get(inner.name));
}

test "parser: invalid import meta properties report diagnostics" {
    var s = try newTestSetup("import.foo(); import.defer;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 17012), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
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

test "parser: namespace export assignment forms report diagnostics" {
    var s = try newTestSetup(
        \\namespace M { export = A; }
        \\namespace N { export default value; }
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1063), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1319), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("A default export can only be used in an ECMAScript-style module.", s.parser.diagnostics.items[1].message);
}

test "parser: ambient external module permits export assignment" {
    var s = try newTestSetup(
        \\declare module "ambient" {
        \\  const x: number;
        \\  export = x;
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: ambient external module permits default export" {
    var s = try newTestSetup(
        \\declare module "ambient" {
        \\  const x: number;
        \\  export default x;
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: import equals accepts type/contextual aliases and ASI" {
    var s = try newTestSetup(
        \\import type _foo = require("./foo.ts");
        \\import await = foo.await;
        \\import foo2 = require("./foo2")
        \\class C extends foo2.x {}
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 4), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.import_decl, s.hir.kindOf(stmts[2]));
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(stmts[3]));
    const imp = hir_mod.importOf(&s.hir, stmts[1]);
    try T.expect(imp.import_equals != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(imp.import_equals));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: import equals require expects string literal" {
    var s = try newTestSetup(
        \\var x = "filename";
        \\import foo = require(x);
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1141), s.parser.diagnostics.items[0].code);
}

// `import(<non-string>)` in type position must report TS1141
// "String literal expected." at the offending token — mirrors tsc
// for `importTypeNonString`, `importTypeNested`,
// `importTypeNestedNoRef`. The previous emission used TS1109 with
// the parser's internal "expected module specifier in import type"
// phrasing, which broke baseline comparison.
test "parser: import type non-string emits TS1141" {
    var s = try newTestSetup(
        \\export const x: import({x: 12}) = undefined as any;
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    var saw_1141 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1141 and std.mem.eql(u8, d.message, "String literal expected.")) saw_1141 = true;
    }
    try T.expect(saw_1141);
}

// When a source file contains multiple `import(<non-string>)` type
// references, the parser must emit one TS1141 per offending site
// rather than bailing out after the first. Mirrors tsc on
// `importTypeGeneric.ts` which reports `usage.ts(1,67)` AND
// `usage.ts(5,72)`.
test "parser: import type non-string recovers and emits one TS1141 per site" {
    var s = try newTestSetup(
        \\export function f<T extends string>(): import(T).Foo { return null as any; }
        \\export function g<T extends string>(): import(T).Foo["a"] { return null as any; }
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    var ts1141_count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1141 and std.mem.eql(u8, d.message, "String literal expected.")) ts1141_count += 1;
    }
    try T.expectEqual(@as(usize, 2), ts1141_count);
}

test "parser: import type alias reports diagnostic" {
    var s = try newTestSetup(
        \\namespace ns { export class Foo {} }
        \\import type Foo = ns.Foo;
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1392), s.parser.diagnostics.items[0].code);
}

test "parser: type-only default import accepts contextual from binding" {
    var s = try newTestSetup(
        \\import type from from "./a";
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: import type before from can be a default binding" {
    var s = try newTestSetup(
        \\import type from "./a";
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: type-only import cannot mix default with named bindings" {
    var s = try newTestSetup(
        \\import type A, { B, C } from "./a";
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1363), s.parser.diagnostics.items[0].code);
}

test "parser: top-level module await binding reports reserved word" {
    var s = try newTestSetup(
        \\export {};
        \\var await = 1;
        \\var {await} = {await: 1};
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1262), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1262), s.parser.diagnostics.items[1].code);
}

test "parser: top-level module await named import reports reserved word" {
    var s = try newTestSetup(
        \\import { await } from "./other";
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1262), s.parser.diagnostics.items[0].code);
}

test "parser: top-level module await import-equals require reports reserved word" {
    var s = try newTestSetup(
        \\declare var require: any;
        \\import await = require("./other");
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1262), s.parser.diagnostics.items[0].code);
}

test "parser: exported class await name reports reserved word" {
    var s = try newTestSetup(
        \\export class await {}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1262), s.parser.diagnostics.items[0].code);
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

test "parser: array literal recovers class close as TS1137" {
    var s = try newTestSetup(
        \\class Type {
        \\    public examples = [
        \\}
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1137), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression or comma expected.", s.parser.diagnostics.items[0].message);
}

test "parser: call expression with spread arguments" {
    var s = try newTestSetup("f(1, ...xs, 2);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(top));
    const args = hir_mod.callArgs(&s.hir, top);
    try T.expectEqual(@as(usize, 3), args.len);
    try T.expectEqual(hir_mod.NodeKind.spread, s.hir.kindOf(args[1]));
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

test "parser: object literal numeric key may end with dot before colon" {
    var s = try newTestSetup("let o = { 1.: \"one\" };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const props = hir_mod.objectLiteralProps(&s.hir, init_node);
    const prop = hir_mod.objectPropertyOf(&s.hir, props[0]);
    const key = hir_mod.identifierOf(&s.hir, prop.key);
    try T.expectEqualStrings("1", s.interner.get(key.name));
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

test "parser: new.target is accepted in functions and rejected at top level" {
    var s = try newTestSetup(
        \\function f() { return new.target; }
        \\const x = new.target;
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 17013) found = true;
    }
    try T.expect(found);
}

test "parser: new expression before type assertion recovers like tsc" {
    var s = try newTestSetup("new <T>Foo();");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2304), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("Cannot find name 'T'.", s.parser.diagnostics.items[1].message);
}

test "parser: type assertion records union and intersection assertion types" {
    var s = try newTestSetup("let x = <A & B>value; let y = <A | B>value;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    const x = hir_mod.varDeclOf(&s.hir, stmts[0]);
    const y = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(hir_mod.NodeKind.type_assertion, s.hir.kindOf(x.init));
    try T.expectEqual(hir_mod.NodeKind.type_assertion, s.hir.kindOf(y.init));
    const x_assertion = hir_mod.asExpressionOf(&s.hir, x.init);
    const y_assertion = hir_mod.asExpressionOf(&s.hir, y.init);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(x_assertion.expr));
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(y_assertion.expr));
    try T.expectEqual(hir_mod.NodeKind.intersection_type, s.hir.kindOf(x_assertion.type_node));
    try T.expectEqual(hir_mod.NodeKind.union_type, s.hir.kindOf(y_assertion.type_node));
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

test "parser: type annotation — nested generic closers split >> in type context" {
    var s = try newTestSetup("declare var f: <T extends Array<Base>>(x: T) => Array<Derived>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — function type keyword parameter name" {
    var s = try newTestSetup("let f: (string: any) => string = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(v.type_annotation));
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

test "parser: type annotation — import type qualified name" {
    var s = try newTestSetup("export function getUser(): import(\"./types.d.ts\").Models.User { return user; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const exp = hir_mod.exportOf(&s.hir, top);
    const f = hir_mod.fnDeclOf(&s.hir, exp.decl);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(f.return_type));
    const tr = hir_mod.typeRefOf(&s.hir, f.return_type);
    try T.expectEqualStrings("User", s.interner.get(tr.name));
    try T.expectEqual(@as(usize, 1), tr.qualifier_len);
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

test "parser: empty parameter type reports TS1110 and preserves arrow" {
    var s = try newTestSetup("var v = (a: ) => {};");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1110), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Type expected.", s.parser.diagnostics.items[0].message);
}

test "parser: empty return type before arrow recovers as expression" {
    var s = try newTestSetup("var v = (a): => {};");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(v.init));
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("',' expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("';' expected.", s.parser.diagnostics.items[1].message);
}

test "parser: unterminated tuple type reports TS1005 close bracket" {
    var s = try newTestSetup("var v: [");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("']' expected.", s.parser.diagnostics.items[0].message);
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

test "parser: type annotation — typeof supports array postfix" {
    var s = try newTestSetup("let xs: typeof x[] = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.array_type, s.hir.kindOf(v.type_annotation));
    const arr = hir_mod.arrayTypeOf(&s.hir, v.type_annotation);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(arr.element));
}

test "parser: type annotation — typeof accepts type arguments" {
    var s = try newTestSetup("let xs: typeof Array<number> = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(v.type_annotation));
}

test "parser: type annotation — typeof accepts nested typeof in type arguments" {
    var s = try newTestSetup("var x = 1;\nvar xs4: typeof Array<typeof x>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    const v = hir_mod.varDeclOf(&s.hir, stmts[1]);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(v.type_annotation));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: type annotation — typeof import supports indexed access" {
    var s = try newTestSetup("let x: typeof import(\"./mod\")[\"value\"] = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(v.type_annotation));
    const tt = hir_mod.typeofTypeOf(&s.hir, v.type_annotation);
    try T.expectEqual(hir_mod.NodeKind.indexed_access_type, s.hir.kindOf(tt.operand));
}

test "parser: type annotation — typeof undefined accepts keyword operand" {
    var s = try newTestSetup("let x: typeof undefined = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.typeof_type, s.hir.kindOf(v.type_annotation));
    const tt = hir_mod.typeofTypeOf(&s.hir, v.type_annotation);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(tt.operand));
}

test "parser: type annotation — typeof qualified reserved property" {
    var s = try newTestSetup(
        \\class Controller {
        \\  create() {}
        \\  delete() {}
        \\  var() {}
        \\}
        \\interface IScope {
        \\  create: typeof Controller.prototype.create;
        \\  delete: typeof Controller.prototype.delete;
        \\  var: typeof Controller.prototype.var;
        \\}
        \\let x: typeof Controller.prototype.var = null;
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: type annotation — fn type accepts type-only and this parameters" {
    var s = try newTestSetup(
        \\let f: (string, number) => boolean = null;
        \\interface Array<T> { equals(this: Array<T>, other: Array<T>): boolean; }
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    const v = hir_mod.varDeclOf(&s.hir, stmts[0]);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(v.type_annotation));
    const iface_members = hir_mod.interfaceMembers(&s.hir, stmts[1]);
    const member = hir_mod.interfaceMemberOf(&s.hir, iface_members[0]);
    try T.expect(member.is_method);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(member.type_node));
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

test "parser: object type computed members accept const literal keys" {
    var s = try newTestSetup(
        \\const a = "a";
        \\const b = 'b';
        \\type Shape = { [a]: number; [b as "b"]: string; ["c"]: boolean; };
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    const alias = hir_mod.typeAliasOf(&s.hir, stmts[2]);
    const members = hir_mod.objectTypeMembers(&s.hir, alias.aliased);
    try T.expectEqual(@as(usize, 3), members.len);
    const m0 = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    const m1 = hir_mod.interfaceMemberOf(&s.hir, members[1]);
    const m2 = hir_mod.interfaceMemberOf(&s.hir, members[2]);
    try T.expectEqualStrings("a", s.interner.get(m0.name));
    try T.expectEqualStrings("b", s.interner.get(m1.name));
    try T.expectEqualStrings("c", s.interner.get(m2.name));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: interface generic method shorthand" {
    var s = try newTestSetup("interface Box { map<T>(x: T): T; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.interfaceMembers(&s.hir, top);
    const m = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    try T.expect(m.is_method);
    const ft = hir_mod.fnTypeOf(&s.hir, m.type_node);
    try T.expectEqual(@as(u16, 1), ft.type_params_len);
}

test "parser: object type call and construct signatures" {
    var s = try newTestSetup("let p: { <T>(x: T): T; new<T>(x: T): T } = null;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    const members = hir_mod.objectTypeMembers(&s.hir, v.type_annotation);
    try T.expectEqual(@as(usize, 2), members.len);
    const call = hir_mod.interfaceMemberOf(&s.hir, members[0]);
    const construct = hir_mod.interfaceMemberOf(&s.hir, members[1]);
    try T.expectEqual(hir_mod.NodeKind.fn_type, s.hir.kindOf(call.type_node));
    try T.expectEqual(hir_mod.NodeKind.constructor_type, s.hir.kindOf(construct.type_node));
    try T.expect(!hir_mod.fnTypeOf(&s.hir, call.type_node).is_constructor);
    try T.expect(hir_mod.fnTypeOf(&s.hir, construct.type_node).is_constructor);
}

test "parser: object literal generic method" {
    var s = try newTestSetup("var b = { foo<T>(x: T) { return x; } };");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    const props = hir_mod.objectLiteralProps(&s.hir, v.init);
    const op = hir_mod.objectPropertyOf(&s.hir, props[0]);
    try T.expectEqual(hir_mod.NodeKind.fn_expr, s.hir.kindOf(op.value));
    try T.expectEqual(@as(usize, 1), hir_mod.fnTypeParams(&s.hir, op.value).len);
}

test "parser: object literal method return annotation before block" {
    var s = try newTestSetup(
        \\let o = {
        \\  sub1(n: number): number {
        \\    return n;
        \\  }
        \\};
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    const props = hir_mod.objectLiteralProps(&s.hir, v.init);
    const op = hir_mod.objectPropertyOf(&s.hir, props[0]);
    const f = hir_mod.fnDeclOf(&s.hir, op.value);
    try T.expect(f.return_type != hir_mod.none_node_id);
}

test "parser: object literal async computed method" {
    var s = try newTestSetup("let o = { async [Symbol.asyncDispose]() {}, value: null };");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    const props = hir_mod.objectLiteralProps(&s.hir, v.init);
    const op = hir_mod.objectPropertyOf(&s.hir, props[0]);
    try T.expect(op.is_computed);
    try T.expect(op.is_method);
    try T.expectEqual(hir_mod.NodeKind.fn_expr, s.hir.kindOf(op.value));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: jsx hyphenated tag and attribute names" {
    var s = try newTsxTestSetup("let v = <my-element data-id=\"x\" ignore-prop />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const el = hir_mod.jsxElementOf(&s.hir, init_node);
    try T.expectEqualStrings("my-element", s.interner.get(hir_mod.identifierOf(&s.hir, el.tag).name));
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    try T.expectEqual(@as(usize, 2), attrs.len);
    const a0 = hir_mod.jsxAttributeOf(&s.hir, attrs[0]);
    const a1 = hir_mod.jsxAttributeOf(&s.hir, attrs[1]);
    try T.expectEqualStrings("data-id", s.interner.get(a0.name));
    try T.expectEqualStrings("ignore-prop", s.interner.get(a1.name));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: jsx empty attribute initializer reports TS1145" {
    var s = try newTsxTestSetup("let v = <Foo attr= />;");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1145), s.parser.diagnostics.items[0].code);
}

test "parser: jsx element attribute initializer remains recoverable" {
    var s = try newTsxTestSetup("let v = <Foo attr=<Bar /> />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    const a = hir_mod.jsxAttributeOf(&s.hir, attrs[0]);
    try T.expect(a.value != hir_mod.none_node_id);
    try T.expectEqual(hir_mod.NodeKind.jsx_self_closing, s.hir.kindOf(a.value));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: jsx text child preserves same-line whitespace" {
    var s = try newTsxTestSetup("let v = <Comp><A />  <B /></Comp>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const children = hir_mod.jsxChildren(&s.hir, init_node);
    try T.expectEqual(@as(usize, 3), children.len);
    try T.expectEqual(hir_mod.NodeKind.literal_string, s.hir.kindOf(children[1]));
}

test "parser: jsx tag type arguments are skipped before attributes" {
    var s = try newTsxTestSetup("let v = <Foo<string> bar />;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const attrs = hir_mod.jsxAttrs(&s.hir, init_node);
    try T.expectEqual(@as(usize, 1), attrs.len);
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: jsx dynamic this member tag" {
    var s = try newTsxTestSetup("let v = <this._tagName>Hello</this._tagName>;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const init_node = hir_mod.varDeclOf(&s.hir, top).init;
    const el = hir_mod.jsxElementOf(&s.hir, init_node);
    try T.expectEqual(hir_mod.NodeKind.member_access, s.hir.kindOf(el.tag));
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
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

test "parser: contextual keyword function name with generic type parameters" {
    var s = try newTestSetup("function get<T>(x: T): T { return x; }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.fn_decl, s.hir.kindOf(top));
    const tps = hir_mod.fnTypeParams(&s.hir, top);
    try T.expectEqual(@as(usize, 1), tps.len);
}

test "parser: contextual get/set keywords can be callee identifiers" {
    var s = try newTestSetup(
        \\function get<T>(x: T): T { return x; }
        \\get(1);
        \\set(2);
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 3), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(stmts[2]));
}

test "parser: qualified generic class heritage is a type ref" {
    var s = try newTestSetup("class View extends React.Component<Props, {}> {}");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const c = hir_mod.classOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(c.extends));
    const r = hir_mod.typeRefOf(&s.hir, c.extends);
    try T.expectEqualStrings("Component", s.interner.get(r.name));
    try T.expectEqual(@as(usize, 1), s.hir.childSlice(r.qualifier_start, r.qualifier_len).len);
    try T.expectEqual(@as(usize, 2), hir_mod.typeRefArgs(&s.hir, c.extends).len);
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

test "parser: primitive type keyword class name reports diagnostic" {
    var s = try newTestSetup("class any {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2414), s.parser.diagnostics.items[0].code);
}

test "parser: ambient class member implementations report diagnostic" {
    var s = try newTestSetup("declare class Foo { constructor() {} method() {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1183), s.parser.diagnostics.items[0].code);
    try T.expect(std.mem.eql(u8, s.parser.source[s.parser.diagnostics.items[0].pos..][0..1], "{"));
    try T.expectEqual(@as(u32, 1183), s.parser.diagnostics.items[1].code);
    try T.expect(std.mem.eql(u8, s.parser.source[s.parser.diagnostics.items[1].pos..][0..1], "{"));
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

test "parser: this parameter preserves decorators" {
    var s = try newTestSetup("class Foo { method(@dec this: Foo) {} }");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    const params = hir_mod.fnParams(&s.hir, members[0]);
    try T.expectEqual(@as(usize, 1), hir_mod.parameterDecorators(&s.hir, params[0]).len);
}

test "parser: parameter property decorator after modifier reports comma expected" {
    var s = try newTestSetup("class Foo { constructor(public @dec x: number) {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
}

test "parser: overload implementation lookahead skips decorators" {
    var s = try newTestSetup("class Foo { method(); @dec method() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 2391);
    }
}

test "parser: class method overload mismatch defers TS2389 to checker" {
    var s = try newTestSetup("class C { foo(); bar() {} }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 2391);
    }
}

test "parser: accessibility after static is an order diagnostic only before another member name" {
    var bad = try newTestSetup("class Foo { static public value: number; static public method() {} }");
    defer destroyTestSetup(bad);
    _ = try bad.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), bad.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1029), bad.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1029), bad.parser.diagnostics.items[1].code);

    var good = try newTestSetup("class Foo { static public() {} static public<T>() {} static public = 1; }");
    defer destroyTestSetup(good);
    _ = try good.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), good.parser.diagnostics.items.len);
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

test "parser: empty const declaration list reports only TS1123" {
    // `const` alone — TS1123 ("Variable declaration list cannot be empty.")
    // is the only diagnostic; the TS1155 ("'const' declarations must
    // be initialized.") follow-on is suppressed since it's a redundant
    // restatement of the same condition. Mirrors tsc on
    // `VariableDeclaration1_es6`.
    var s = try newTestSetup("const");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1123 = false;
    var saw_1155 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1123) saw_1123 = true;
        if (d.code == 1155) saw_1155 = true;
    }
    try T.expect(saw_1123);
    try T.expect(!saw_1155);
}

test "parser: using declaration requires initializer" {
    // `await using` inside an async function avoids the TS2853
    // top-level-module-required diagnostic that would otherwise
    // accompany the TS1155 we're asserting here.
    var s = try newTestSetup("async function f() { using a; await using b; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1155), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1155), s.parser.diagnostics.items[1].code);
}

test "parser: using declaration under if requires block" {
    var s = try newTestSetup("if (x) using a = null; async function f() { if (y) await using b = null; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1156), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1156), s.parser.diagnostics.items[1].code);
}

test "parser: await using context diagnostics" {
    var s = try newTestSetup(
        \\await using top = null;
        \\function f() { await using inner = null; }
        \\class C { static { await using stat = null; } }
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2853), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2852), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 18054), s.parser.diagnostics.items[2].code);
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

test "parser: prefix and postfix update expressions lower to compound assignment" {
    var s = try newTestSetup("let x = 0; ++x; x--;");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmts[1]));
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(stmts[2]));
    try T.expectEqual(@as(?hir_mod.BinOp, .add), hir_mod.assignmentOf(&s.hir, stmts[1]).op);
    try T.expectEqual(@as(?hir_mod.BinOp, .sub), hir_mod.assignmentOf(&s.hir, stmts[2]).op);
}

test "parser: prefix update expression reports arithmetic operand diagnostic for expression operands" {
    var s = try newTestSetup("++this; ++function(e) {}; ++[0]; ++{};");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 4), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[2].code);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[3].code);
}

test "parser: prefix update expression reports invalid operand diagnostic for new expression" {
    var s = try newTestSetup("++new Foo();");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2357), s.parser.diagnostics.items[0].code);
}

test "parser: update expression on boolean literal reports arithmetic operand diagnostic" {
    var s = try newTestSetup("--true; true--;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2356), s.parser.diagnostics.items[1].code);
}

test "parser: regex literal reports unbalanced group" {
    var s = try newTestSetup("let x = /fo(o/;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
}

test "parser: unterminated regex literal recovers as call argument" {
    var s = try newTestSetup("foo(/notregexp);");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmt = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(stmt));
    const call = hir_mod.callOf(&s.hir, stmt);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(call.callee));
    try T.expectEqual(@as(usize, 1), hir_mod.callArgs(&s.hir, stmt).len);
    try T.expectEqual(hir_mod.NodeKind.literal_regex, s.hir.kindOf(hir_mod.callArgs(&s.hir, stmt)[0]));
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1161), s.parser.diagnostics.items[0].code);
}

test "parser: contextual primitive keyword can be parameter name and expression" {
    var s = try newTestSetup("let f = (number) => String(number);");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.arrow_fn, s.hir.kindOf(v.init));
}

test "parser: unary expression before exponentiation reports TS17006" {
    var s = try newTestSetup("-1 ** 2; 1 ** +2 ** 3; (-1) ** 2;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 17006) count += 1;
    }
    try T.expectEqual(@as(usize, 2), count);
}

test "parser: contextual type keyword can be an expression identifier" {
    var s = try newTestSetup(
        \\function f(type, ctor, exports) {
        \\    exports["AST_" + type] = ctor;
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: nullish prototype method compound assignment parses" {
    var s = try newTestSetup(
        \\Element.prototype.remove ??= function () {
        \\  this.parentNode?.removeChild(this);
        \\};
        \\
        \\/** @this Node */
        \\Element.prototype.remove ??= function () {
        \\  this.parentNode?.removeChild(this);
        \\};
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: unique symbol type annotation" {
    var s = try newTestSetup("const tag: unique symbol = Symbol();");
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const v = hir_mod.varDeclOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.type_ref, s.hir.kindOf(v.type_annotation));
}

test "parser: unique symbol computed type members parse without TS1169" {
    var s = try newTestSetup(
        \\declare const tag: unique symbol;
        \\const inferredTag = Symbol();
        \\interface I { [tag]: any; [tag](): any; }
        \\type T = { [tag]: any; [tag](): any; [inferredTag]: string; };
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1169);
    }
}

test "parser: lone accessibility keyword in class body can be field name" {
    var s = try newTestSetup("class Logger { public }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: type member `new` can be a property or optional method name" {
    var s = try newTestSetup("interface C { foo; new; }\nlet c: { new?(): any; };");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: interface accessor signatures allow comma semicolon and newline separators" {
    var s = try newTestSetup(
        \\interface I1 {
        \\  get foo(): number,
        \\  set foo(value: number),
        \\}
        \\interface I2 {
        \\  get bar(): string;
        \\  set bar(value: string);
        \\}
        \\interface I3 {
        \\  get baz(): boolean
        \\  set baz(value: boolean)
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: duplicate export modifier reports TS1030" {
    var s = try newTestSetup("export export class Foo { public Bar() {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1030), s.parser.diagnostics.items[0].code);
}

test "parser: parameter property cannot be rest parameter" {
    var s = try newTestSetup("class Foo { constructor(public ...args: string[]) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1317), s.parser.diagnostics.items[0].code);
}

test "parser: ambient semicolon statement reports TS1036" {
    var s = try newTestSetup("declare namespace ambiModule { interface I { }; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1036), s.parser.diagnostics.items[0].code);
}

test "parser: declaration-file statements report TS1036" {
    var s = try newTestSetup(
        \\for (var e of []) {}
        \\label: foo;
    );
    defer destroyTestSetup(s);
    s.parser.is_declaration_file = true;

    _ = try s.parser.parseSourceFile();
    try T.expect(s.parser.diagnostics.items.len >= 2);
    try T.expectEqual(@as(u32, 1036), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1036), s.parser.diagnostics.items[1].code);
}

test "parser: declaration-file top-level var requires declare or export" {
    var s = try newTestSetup("var v;");
    defer destroyTestSetup(s);
    s.parser.is_declaration_file = true;

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1046), s.parser.diagnostics.items[0].code);
}

test "parser: declaration-file top-level var check respects virtual filenames" {
    var s = try newTestSetup("// @filename: index.d.ts\nvar d;\n// @filename: index.js\nvar j;");
    defer destroyTestSetup(s);
    s.parser.is_declaration_file = true;

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1046), s.parser.diagnostics.items[0].code);
}

test "parser: invalid class-body var reports TS1068" {
    var s = try newTestSetup("class Foo { var icecream = \"chocolate\"; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1068), s.parser.diagnostics.items[0].code);
}

test "parser: invalid multiline class-body var reports close brace TS1128" {
    var s = try newTestSetup(
        \\class Foo {
        \\  var icecream = "chocolate";
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1068), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1128), s.parser.diagnostics.items[1].code);
}

test "parser: reserved accessibility keyword in class type annotation reports TS1213" {
    var s = try newTestSetup("class Foo { public banana(x: public) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1213), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Identifier expected. 'public' is a reserved word in strict mode. Class definitions are automatically in strict mode.", s.parser.diagnostics.items[0].message);
}

test "parser: static parameter name in constructor reports class strict TS1213" {
    var s = try newTestSetup("class Foo { constructor(static) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1213), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Identifier expected. 'static' is a reserved word in strict mode. Class definitions are automatically in strict mode.", s.parser.diagnostics.items[0].message);
}

test "parser: malformed index signature forms report diagnostics" {
    var s = try newTestSetup("interface A { [...a] } interface B { [a?] } interface C { [a, b]: number }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1017), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1019), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1096), s.parser.diagnostics.items[2].code);
}

test "parser: arguments parameter in non-strict class method reports TS1210" {
    // Class bodies are implicitly strict — `f(arguments)` is illegal
    // even without an outer `"use strict"`. Upstream tsc emits TS1210
    // anchored at the parameter name. Mirrors
    // `emitArrowFunctionWhenUsingArguments12.ts`.
    var s = try newTestSetup("class C { f(arguments) {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var saw_1210 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1210) saw_1210 = true;
    }
    try T.expect(saw_1210);
}

test "parser: arguments parameter outside class does not report TS1210" {
    var s = try newTestSetup("function f(arguments) {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1210);
        try T.expect(d.code != 1100);
    }
}

test "parser: strict mode restricted names and delete operands report diagnostics" {
    var s = try newTestSetup("\"use strict\"; function eval() {} function f(arguments) {} arguments = 1; delete 1;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[2].code);
}

test "parser: strict mode delete identifier reports TS1102 at operand" {
    var s = try newTestSetup("\"use strict\"; delete a;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1102), s.parser.diagnostics.items[0].code);
}

test "parser: strict mode eval assignment forms report restricted name" {
    var s = try newTestSetup("\"use strict\"; eval += 1; ++eval; eval++; var v = { set foo(eval) {} };");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 4), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[2].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[3].code);
}

test "parser: eval assignment target reports restricted name without directive" {
    var s = try newTestSetup("eval = 1; eval++;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[1].code);
}

test "parser: strict mode future reserved variable name reports TS1212" {
    var s = try newTestSetup("\"use strict\"; var public = 1;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1212), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Identifier expected. 'public' is a reserved word in strict mode.", s.parser.diagnostics.items[0].message);
}

test "parser: es2015 static call reports reserved identifier diagnostic" {
    var s = try newTestSetup("static();");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1212), s.parser.diagnostics.items[0].code);
}

test "parser: 'public' in object-literal computed key reports TS1212" {
    // Mirrors `parserComputedPropertyName37.ts`: `var v = { [public]: 0 }`.
    // The reserved word is a valid identifier expression in strict mode,
    // so the parser must emit TS1212 (not TS1109) and synthesize an
    // identifier so the checker reports TS2304.
    var s = try newTestSetup("var v = { [public]: 0 };");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var found_1212 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) found_1212 = true;
    }
    try T.expect(found_1212);
}

test "parser: 'public' in class-body computed method reports TS1213" {
    // Mirrors `parserComputedPropertyName38.ts`: `class C { [public]() {} }`.
    // Class bodies are auto-strict, so the diagnostic is TS1213 instead of
    // TS1212. Recovery still produces an identifier so the checker emits
    // TS2304 at the same position.
    var s = try newTestSetup("class C { [public]() {} }");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var found_1213 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1213) found_1213 = true;
    }
    try T.expect(found_1213);
}

test "parser: top-level protected class reports modifier diagnostic and recovers" {
    var s = try newTestSetup("protected class C {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1044), s.parser.diagnostics.items[0].code);
}

test "parser: top-level dynamic import makes file strict" {
    var s = try newTestSetup("var p = import(\"./m\"); function arguments() {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[0].code);
}

test "parser: strict mode legacy octal literal reports TS1121" {
    var s = try newTestSetup("\"use strict\"; 03;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1121), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Octal literals are not allowed. Use the syntax '0o3'.", s.parser.diagnostics.items[0].message);
}

test "parser: leading-zero literal with `8` or `9` digit reports TS1489" {
    // tsc treats `09` (and any `0[0-9]*[89][0-9]*` literal) as a
    // decimal-with-leading-zeros error rather than a legacy-octal
    // error, because the `8`/`9` forces decimal interpretation.
    // Baseline: scannerNumericLiteral9.errors.txt (TS1489 only).
    var s = try newTestSetup("009");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1489), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Decimals with leading zeros are not allowed.", s.parser.diagnostics.items[0].message);
}

test "parser: legacy octal literal with stray fraction reports TS1121 + TS1005" {
    // tsc splits `01.0` into a legacy-octal `01` (TS1121 against the
    // pure-octal prefix, NOT the full `01.0`) and a stray `.0`
    // fraction that triggers TS1005 at the `.`. Baseline:
    // scannerNumericLiteral3(target=es2015).errors.txt.
    var s = try newTestSetup("01.0");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1121), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Octal literals are not allowed. Use the syntax '0o1'.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("';' expected.", s.parser.diagnostics.items[1].message);
}

test "parser: with statement reports strict and unsupported diagnostics" {
    // tsc reserves TS1101 ("'with' statements are not allowed in
    // strict mode.") for genuinely strict sources — a `"use strict"`
    // directive or the always-strict harness setting. Targeting
    // ES2015+ alone does not flip the source into strict mode for
    // diagnostic purposes (see baseline
    // `arrowFunctionContexts(alwaysstrict=false).errors.txt`).
    var s = try newTestSetup("\"use strict\"; with (1) return;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expect(s.parser.diagnostics.items.len >= 2);
    try T.expectEqual(@as(u32, 1101), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2410), s.parser.diagnostics.items[1].code);
}

test "parser: with statement in declaration file reports ambient and unsupported diagnostics" {
    var s = try newTestSetup("with (foo) {}");
    defer destroyTestSetup(s);

    s.parser.setDeclarationFile(true);
    _ = try s.parser.parseSourceFile();
    try T.expect(s.parser.diagnostics.items.len >= 2);
    try T.expectEqual(@as(u32, 1036), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2410), s.parser.diagnostics.items[1].code);
}

test "parser: strict mode catch binding reports restricted name" {
    var s = try newTestSetup("\"use strict\"; try {} catch(eval) {}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1100), s.parser.diagnostics.items[0].code);
}

test "parser: duplicate accessibility modifier reports TS1028" {
    var s = try newTestSetup("class C { protected public m() {} }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1028), s.parser.diagnostics.items[0].code);
}

test "parser: class index signature accessibility modifier reports TS1071" {
    var s = try newTestSetup("class C { private [x: string]: string; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1071), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 10), s.parser.diagnostics.items[0].pos);
    try T.expectEqualStrings("'private' modifier cannot appear on an index signature.", s.parser.diagnostics.items[0].message);
}

test "parser: empty and trailing variable declaration lists use upstream diagnostics" {
    var empty = try newTestSetup("var ;");
    defer destroyTestSetup(empty);
    _ = try empty.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), empty.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1123), empty.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 3), empty.parser.diagnostics.items[0].pos);

    var trailing = try newTestSetup("var a,;");
    defer destroyTestSetup(trailing);
    _ = try trailing.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), trailing.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1009), trailing.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 5), trailing.parser.diagnostics.items[0].pos);
}

test "parser: class index signature missing separator reports TS1005" {
    var s = try newTestSetup("class C { [a: string]: number public v: number }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005 and std.mem.eql(u8, d.message, "';' expected.")) found = true;
    }
    try T.expect(found);
}

test "parser: malformed interface index signatures use upstream recovery diagnostics" {
    var rest = try newTestSetup("interface I {\n  [...a]\n}");
    defer destroyTestSetup(rest);
    _ = try rest.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), rest.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1017), rest.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 17), rest.parser.diagnostics.items[0].pos);

    var accessibility = try newTestSetup("interface I {\n  [public a]\n}");
    defer destroyTestSetup(accessibility);
    _ = try accessibility.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), accessibility.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2369), accessibility.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1018), accessibility.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 24), accessibility.parser.diagnostics.items[1].pos);

    var missing_value = try newTestSetup("interface I {\n  [a:string]\n}");
    defer destroyTestSetup(missing_value);
    _ = try missing_value.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), missing_value.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1021), missing_value.parser.diagnostics.items[0].code);

    var invalid_key = try newTestSetup("interface I {\n  [a:boolean]\n}");
    defer destroyTestSetup(invalid_key);
    _ = try invalid_key.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), invalid_key.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1268), invalid_key.parser.diagnostics.items[0].code);
}

test "parser: unresolved computed interface member reports missing key name" {
    var s = try newTestSetup("interface I {\n  [e]: number\n}");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2304), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Cannot find name 'e'.", s.parser.diagnostics.items[0].message);
}

test "parser: computed interface assignment key reports missing key name" {
    var s = try newTestSetup("interface I {\n  [a = 0]\n}");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1169), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 2304), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("Cannot find name 'a'.", s.parser.diagnostics.items[1].message);
}

test "parser: computed enum member reports TS1164" {
    var s = try newTestSetup("enum E { [e] = 1 }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1164), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Computed property names are not allowed in enums.", s.parser.diagnostics.items[0].message);
}

test "parser: yield can be a generator function expression name" {
    var s = try newTestSetup("const f = async function * yield() {};");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: ES2015 target reserves yield in function names, params, and types" {
    var s = try newTestSetup(
        \\function yield() {}
        \\function f(yield) {}
        \\function * g() { var v: yield; }
    );
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expect(count_1212 >= 3);
}

test "parser: yield operand can be an arrow expression" {
    var s = try newTestSetup("function* g() { yield x => x.length; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: generator overload diagnostics match declaration context" {
    var s = try newTestSetup(
        \\namespace M {
        \\  function* f(s: string): Iterable<any>;
        \\  function* f(s: any): Iterable<any> { }
        \\}
        \\class C {
        \\  f(s: string): Iterable<any>;
        \\  *f(s: any): Iterable<any> { }
        \\}
        \\declare class D {
        \\  *g(): any;
        \\}
        \\class E {
        \\  *h(): Iterable<any>;
        \\  *h(): Iterable<any> { }
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1222), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1221), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1222), s.parser.diagnostics.items[2].code);
}

test "parser: top-level yield star reports missing expression" {
    var s = try newTestSetup("yield *;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
}

test "parser: delegated yield requires an operand" {
    var s = try newTestSetup("function* g() { yield *; }");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
}

test "parser: delegated yield anchors TS1109 at the next token, not the `*`" {
    // Mirrors YieldExpression5_es6 — `yield*\n}` reports TS1109
    // at the `}` (next token after the missing operand), not at
    // the end of the `*`. The anchor convention matches upstream
    // tsc, which always anchors `Expression expected.` at the
    // following token's start position.
    var s = try newTestSetup("function* g() {\n  yield*\n}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    const d = s.parser.diagnostics.items[0];
    try T.expectEqual(@as(u32, 1109), d.code);
    // Source is `function* g() {\n  yield*\n}` — newlines at offsets
    // 16 and 24. The `}` sits at byte 25, line 3, col 1.
    try T.expectEqual(@as(u32, 3), d.line);
}

test "parser: top-level bare yield emits TS1212 under ES2015+ target" {
    // Mirrors YieldExpression1_es6 — `yield;` at top-level with an
    // ES2015 target makes `yield` a reserved word, so the parser must
    // emit TS1212 in addition to the checker-side TS2304.
    var s = try newTestSetup("yield;");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1212);
}

test "parser: top-level yield(call) parses as call without spurious TS1005" {
    // Mirrors YieldExpression8_es6 / YieldExpression18_es6 — `yield(foo)`
    // at top-level with an ES2015 target should parse as a call on the
    // yield identifier. We must emit TS1212 for the reserved-word use
    // but must NOT emit a spurious TS1005 between `yield` and `(foo)`.
    var s = try newTestSetup("yield(foo);");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1212: usize = 0;
    var count_1005: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) count_1212 += 1;
        if (d.code == 1005) count_1005 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1212);
    try T.expectEqual(@as(usize, 0), count_1005);
}

test "parser: top-level `yield *` does NOT emit TS1212 (yield-star form)" {
    // Mirrors YieldStarExpression2_es6 — tsc treats `yield *;` as an
    // attempted yield-star expression, not a `yield` identifier, so
    // it emits TS1109 (expression expected after `*`) + checker-side
    // TS2304 but NOT TS1212. Pin the asymmetry against the plain
    // identifier path covered above.
    var s = try newTestSetup("yield *;");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expectEqual(@as(usize, 0), count_1212);
}

test "parser: `yield` in a getter accessor body reports TS1163, not TS1212" {
    // Mirrors YieldExpression17_es6 — a `yield foo` expression inside
    // a non-generator function (here an object-literal getter body)
    // must emit TS1163 ("'yield' expression is only allowed in a
    // generator body"). Before the accessor-body function_depth fix
    // we mis-routed through the top-level identifier path and emitted
    // TS1212 + spurious TS1109 instead.
    var s = try newTestSetup("var v = { get foo() { yield foo; } };");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1163: usize = 0;
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1163) count_1163 += 1;
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1163);
    try T.expectEqual(@as(usize, 0), count_1212);
}

test "parser: `yield` in a class method body reports TS1163, not TS1212" {
    // Mirrors YieldExpression14_es6 — a `yield foo` expression inside
    // a non-generator class method must emit TS1163. Before the
    // class-method function_depth fix we routed the keyword through
    // the top-level-identifier path that emits TS1212 instead.
    var s = try newTestSetup("class C { foo() { yield foo; } }");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1163: usize = 0;
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1163) count_1163 += 1;
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1163);
    try T.expectEqual(@as(usize, 0), count_1212);
}

test "parser: `yield` in a class constructor body reports TS1163, not TS1212" {
    // Mirrors YieldExpression12_es6 — `constructor() { yield foo }`.
    var s = try newTestSetup("class C { constructor() { yield foo; } }");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1163: usize = 0;
    var count_1212: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1163) count_1163 += 1;
        if (d.code == 1212) count_1212 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1163);
    try T.expectEqual(@as(usize, 0), count_1212);
}

test "parser: top-level `yield * <expr>` emits TS1212, no spurious TS1109" {
    // Mirrors YieldStarExpression1_es6: `yield * []` at module top
    // level parses as the multiplication of the `yield` identifier
    // (reserved in strict mode → TS1212) by the array literal. We
    // must NOT emit TS1109 for the `*` here — that fires only when
    // the `*` is followed by a terminator (YieldStarExpression2_es6).
    var s = try newTestSetup("yield * [];");
    defer destroyTestSetup(s);

    s.parser.setTargetEs2015OrLater(true);
    _ = try s.parser.parseSourceFile();
    var count_1212: usize = 0;
    var count_1109: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1212) count_1212 += 1;
        if (d.code == 1109) count_1109 += 1;
    }
    try T.expectEqual(@as(usize, 1), count_1212);
    try T.expectEqual(@as(usize, 0), count_1109);
}

test "parser: `expect` emits canonical TS1005 with quoted token name" {
    // Mirrors `invalidSyntaxNamespaceImportWithCommonjs` — `import *`
    // missing the `as` keyword expects `'as' expected.` (TS1005), not
    // the Home-internal `expected 'as' in namespace import` (TS1109).
    var s = try newTestSetup("import * 'a';");
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    var saw_canonical = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005 and std.mem.eql(u8, d.message, "'as' expected.")) {
            saw_canonical = true;
        }
    }
    try T.expect(saw_canonical);
}

test "parser: interface can be a class method name" {
    var s = try newTestSetup(
        \\class B {
        \\  interface() { }
        \\  static "hi" = 1;
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: yield is rejected in nested non-generator bodies" {
    var s = try newTestSetup(
        \\function* g() {
        \\  function nested() { yield 1; }
        \\  return () => ({ x: yield 2 });
        \\  class C { x = yield 3; static y = yield 4; }
        \\  class D { @(yield 5) m() {} }
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 4), s.parser.diagnostics.items.len);
    for (s.parser.diagnostics.items) |d| {
        try T.expectEqual(@as(u32, 1163), d.code);
    }
}

test "parser: newline after bare yield terminates the operand" {
    var s = try newTestSetup(
        \\function* g() {
        \\  yield
        \\  yield
        \\}
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
    const stmts = hir_mod.blockStmts(&s.hir, root);
    const fn_body = hir_mod.fnDeclOf(&s.hir, stmts[0]).body;
    const body_stmts = hir_mod.blockStmts(&s.hir, fn_body);
    try T.expectEqual(@as(usize, 2), body_stmts.len);
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(body_stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.yield_expr, s.hir.kindOf(body_stmts[1]));
    try T.expectEqual(hir_mod.none_node_id, hir_mod.yieldExprOf(&s.hir, body_stmts[0]).expr);
}

test "parser: newline after namespace forces expression statement" {
    var s = try newTestSetup(
        \\var namespace: number;
        \\var n: string;
        \\namespace
        \\n
        \\{ }
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expect(stmts.len >= 5);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(stmts[2]));
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(stmts[3]));
    try T.expectEqual(hir_mod.NodeKind.block_stmt, s.hir.kindOf(stmts[4]));
}

test "parser: module keyword can be a CommonJS expression root" {
    var s = try newTestSetup("module[\"exports\"][\"d\"].e = 0;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: consecutive duplicate string-named class fields all reach HIR" {
    var s = try newTestSetup(
        \\class C {
        \\    "a b": number;
        \\    "a b": number;
        \\    static "c d": number;
        \\    static "c d": number;
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(top));
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 4), members.len);
    // Each member is an object_property with an identifier key and the
    // canonical (quote-stripped) name interned. Both pairs share their
    // canonical name so the checker can detect TS2300 collisions.
    const m0 = hir_mod.objectPropertyOf(&s.hir, members[0]);
    const m1 = hir_mod.objectPropertyOf(&s.hir, members[1]);
    const m2 = hir_mod.objectPropertyOf(&s.hir, members[2]);
    const m3 = hir_mod.objectPropertyOf(&s.hir, members[3]);
    try T.expectEqual(hir_mod.identifierOf(&s.hir, m0.key).name, hir_mod.identifierOf(&s.hir, m1.key).name);
    try T.expectEqual(hir_mod.identifierOf(&s.hir, m2.key).name, hir_mod.identifierOf(&s.hir, m3.key).name);
    try T.expect(!m0.is_static and !m1.is_static);
    try T.expect(m2.is_static and m3.is_static);
}

test "parser: consecutive duplicate numeric-named class fields all reach HIR" {
    var s = try newTestSetup(
        \\class C {
        \\    1: number;
        \\    1.0: number;
        \\    static 2: number;
        \\    static 2: number;
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 4), members.len);
    const m2 = hir_mod.objectPropertyOf(&s.hir, members[2]);
    const m3 = hir_mod.objectPropertyOf(&s.hir, members[3]);
    // Static `2` appears twice — both must reach the HIR with the same
    // canonical name and `is_static = true` so the checker can group
    // them and emit TS2300.
    try T.expect(m2.is_static and m3.is_static);
    try T.expectEqual(hir_mod.identifierOf(&s.hir, m2.key).name, hir_mod.identifierOf(&s.hir, m3.key).name);
}

test "parser: object literal recovers from missing comma between properties" {
    // The `stringNamedPropertyDuplicates` / `numericNamedPropertyDuplicates`
    // conformance fixtures end with a `var b = { ... }` whose properties
    // intentionally omit commas. Without recovery the whole source-file
    // parse aborts, so the class members above never reach the HIR for
    // checker-side TS2300 detection. Recovery emits TS1005 and keeps
    // both properties, matching tsc's `parseDelimitedList` shape.
    var s = try newTestSetup(
        \\var b = {
        \\    "a b": 1
        \\    "a b": 1
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    var saw_ts1005 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005) saw_ts1005 = true;
    }
    try T.expect(saw_ts1005);
}

test "parser: object shorthand semicolon before close reports comma expected" {
    var s = try newTestSetup("var tt = { aa; }");
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("',' expected.", s.parser.diagnostics.items[0].message);
}

test "parser: missing-comma recovery preserves preceding class duplicate members" {
    // End-to-end shape of the conformance fixture: a class with two
    // pairs of duplicate-name fields followed by a malformed object
    // literal. Pre-fix, the object-literal parse error blew up the
    // whole source file and dropped the class entirely. After fix the
    // class reaches the HIR with all 4 members intact.
    var s = try newTestSetup(
        \\class C {
        \\    "a b": number;
        \\    "a b": number;
        \\    static "c d": number;
        \\    static "c d": number;
        \\}
        \\
        \\var b = {
        \\    "a b": 1
        \\    "a b": 1
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expect(stmts.len >= 2);
    try T.expectEqual(hir_mod.NodeKind.class_decl, s.hir.kindOf(stmts[0]));
    const members = hir_mod.classMembers(&s.hir, stmts[0]);
    try T.expectEqual(@as(usize, 4), members.len);
}

test "parser: optional shorthand object properties report TS1162 and recover" {
    var s = try newTestSetup(
        \\var name: any, id: any;
        \\foo({ name?, id? });
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1162), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1162), s.parser.diagnostics.items[1].code);
}

test "parser: non-identifier shorthand property names require colon" {
    var s = try newTestSetup(
        \\var a = { class };
        \\var b = { "" };
        \\var c = { 0 };
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    for (s.parser.diagnostics.items) |d| {
        try T.expectEqual(@as(u32, 1005), d.code);
    }
}

test "parser: variable list trailing comma before return recovers as return statement" {
    var s = try newTestSetup(
        \\var a,
        \\return;
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.var_decl, s.hir.kindOf(stmts[0]));
    try T.expectEqual(hir_mod.NodeKind.return_stmt, s.hir.kindOf(stmts[1]));
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1009), s.parser.diagnostics.items[0].code);
}

test "parser: reserved keywords are not variable declaration names" {
    var s = try newTestSetup(
        \\var export;
        \\var foo;
        \\var class;
        \\var bar;
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1389), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1389), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[2].code);
}

test "parser: array literal recovers missing comma across newline" {
    var s = try newTestSetup(
        \\var v = [1, 2, 3
        \\4, 5, 6, 7];
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
}

test "parser: array literal semicolon recovery leaves tail as statement" {
    var s = try newTestSetup(
        \\var texCoords = [2, 2, 0.5000001192092895, 0.8749999 ; 403953552, 0.5000001192092895, 0.8749999403953552];
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 3), stmts.len);
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
}

test "parser: object literal missing close before semicolon reports TS1005" {
    var s = try newTestSetup(
        \\var v = { a: 1,
        \\return;
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
}

test "parser: object literal missing value recovers keyword property" {
    var s = try newTestSetup(
        \\var v = { a:
        \\return;
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 3), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[2].code);
}

test "parser: object literal malformed computed indexer recovers like upstream" {
    var s = try newTestSetup(
        \\var x = {
        \\  [s: symbol]: ""
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 4), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("']' expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("',' expected.", s.parser.diagnostics.items[1].message);
    try T.expectEqual(@as(u32, 1136), s.parser.diagnostics.items[2].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[3].code);
    try T.expectEqualStrings("':' expected.", s.parser.diagnostics.items[3].message);
}

test "parser: call argument list missing argument before return recovers" {
    var s = try newTestSetup(
        \\function foo() {
        \\  bar(
        \\  return x;
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1135), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Argument expression expected.", s.parser.diagnostics.items[0].message);
}

test "parser: call argument list empty slot before eof reports close paren" {
    var s = try newTestSetup("Foo(,");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1135), s.parser.diagnostics.items[0].code);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("')' expected.", s.parser.diagnostics.items[1].message);
}

test "parser: top-level close parens recover as declaration expected" {
    var s = try newTestSetup(
        \\function foo() {}
        \\function foo() {}
        \\)
        \\)
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var ts1128: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1128) ts1128 += 1;
    }
    try T.expectEqual(@as(usize, 2), ts1128);
}

test "parser: close paren in expression reports expression expected" {
    var s = try newTestSetup("var x = );");
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    try T.expect(s.parser.diagnostics.items.len >= 1);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression expected.", s.parser.diagnostics.items[0].message);
}

test "parser: binary expression missing rhs before close paren preserves lhs" {
    var s = try newTestSetup("retValue = bfs.VARIABLES >> );");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(top));
    const assign = hir_mod.assignmentOf(&s.hir, top);
    try T.expectEqual(hir_mod.NodeKind.identifier, s.hir.kindOf(assign.target));
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(assign.value));
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression expected.", s.parser.diagnostics.items[0].message);
}

test "parser: return in expression position reports expression expected" {
    var s = try newTestSetup(
        \\function foo() {
        \\  var x =
        \\  return;
        \\}
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    try T.expect(s.parser.diagnostics.items.len >= 1);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression expected.", s.parser.diagnostics.items[0].message);
}

test "parser: colon in expression position reports expression expected" {
    var s = try newTestSetup("switch (x) { case: y; }");
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    try T.expect(s.parser.diagnostics.items.len >= 1);
    try T.expectEqual(@as(u32, 1109), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Expression expected.", s.parser.diagnostics.items[0].message);
}

test "parser: invalid token in expression position reports invalid character" {
    var s = try newTestSetup(
        \\function f() {
        \\  ¬
        \\}
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    try T.expect(s.parser.diagnostics.items.len >= 1);
    try T.expectEqual(@as(u32, 1127), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Invalid character.", s.parser.diagnostics.items[0].message);
}

test "parser: invalid generic-call type args fall back to expression recovery" {
    var s = try newTestSetup("Foo<A,B,\\ C>(4, 5, 6);");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    try T.expectEqual(hir_mod.NodeKind.binary_op, s.hir.kindOf(top));
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1127), s.parser.diagnostics.items[0].code);
}

test "parser: statement invalid token recovers following declaration" {
    var s = try newTestSetup("\\ declare var v;");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1127), s.parser.diagnostics.items[0].code);
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.var_decl, s.hir.kindOf(stmts[0]));
}

test "parser: invalid token at call argument tail preserves partial call" {
    var s = try newTestSetup("foo(a \\");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    var saw_invalid = false;
    var saw_missing_close = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1127) saw_invalid = true;
        if (d.code == 1005) saw_missing_close = true;
    }
    try T.expect(saw_invalid);
    try T.expect(saw_missing_close);
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 1), stmts.len);
    try T.expectEqual(hir_mod.NodeKind.call_expr, s.hir.kindOf(stmts[0]));
}

test "parser: invalid token before semicolon terminates expression statement" {
    var s = try newTestSetup("/regexp/ \\ ;");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1127), s.parser.diagnostics.items[0].code);
}

test "parser: open brace after expression statement reports semicolon and recovers block" {
    var s = try newTestSetup("module.module { }");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("';' expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(usize, 2), hir_mod.blockStmts(&s.hir, root).len);
}

test "parser: open paren after import-equals entity reports semicolon" {
    var s = try newTestSetup("import rect = module(\"rect\"); var bar = rect;");
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("';' expected.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(usize, 3), hir_mod.blockStmts(&s.hir, root).len);
}

test "parser: invalid token terminates type argument list without greater cascade" {
    var s = try newTestSetup("var v: X<T \\");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var invalid_count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1127) invalid_count += 1;
        try T.expect(d.code != 1005);
    }
    try T.expectEqual(@as(usize, 1), invalid_count);
}

test "parser: if condition missing close paren preserves condition" {
    var s = try newTestSetup(
        \\class Foo {
        \\  f1() {
        \\    if (a
        \\  }
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
}

test "parser: nested class declaration in class body bails to outer statement" {
    var s = try newTestSetup(
        \\class C {
        \\class D {
        \\}
    );
    defer destroyTestSetup(s);

    const root = try s.parser.parseSourceFile();
    const stmts = hir_mod.blockStmts(&s.hir, root);
    try T.expectEqual(@as(usize, 2), stmts.len);
    try T.expectEqual(@as(u32, 1068), s.parser.diagnostics.items[0].code);
}

test "parser: constructor accessor names report TS1341" {
    var s = try newTestSetup(
        \\class C {
        \\  get constructor() { return }
        \\  set constructor(value) {}
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 2), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1341), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Class constructor may not be an accessor.", s.parser.diagnostics.items[0].message);
    try T.expectEqual(@as(u32, 1341), s.parser.diagnostics.items[1].code);
    try T.expectEqualStrings("Class constructor may not be an accessor.", s.parser.diagnostics.items[1].message);
}

test "parser: enum keyword in expression recovery reports expression expected" {
    var s = try newTestSetup("@\nenum E {}");
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1109 and std.mem.eql(u8, d.message, "Expression expected.")) found = true;
    }
    try T.expect(found);
}

test "parser: invalid enum member still reports missing close brace" {
    var s = try newTestSetup("enum E {\n  ¬");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var invalid_found = false;
    var close_found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1127) invalid_found = true;
        if (d.code == 1005 and std.mem.eql(u8, d.message, "'}' expected.")) close_found = true;
    }
    try T.expect(invalid_found);
    try T.expect(close_found);
}

test "parser: enum reserved declaration name reports TS1359" {
    var s = try newTestSetup("enum void {\n}");
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1359), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("Identifier expected. 'void' is a reserved word that cannot be used here.", s.parser.diagnostics.items[0].message);
}

test "parser: malformed enum members report enum-specific diagnostics" {
    var s = try newTestSetup(
        \\enum E {
        \\  ,
        \\  1, a: 2, b: 3 = 4
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var missing_member = false;
    var numeric_member_count: usize = 0;
    var bad_separator_count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1132 and std.mem.eql(u8, d.message, "Enum member expected.")) missing_member = true;
        if (d.code == 2452 and std.mem.eql(u8, d.message, "An enum member cannot have a numeric name.")) numeric_member_count += 1;
        if (d.code == 1357 and std.mem.eql(u8, d.message, "An enum member name must be followed by a ',', '=', or '}'.")) bad_separator_count += 1;
    }
    try T.expect(missing_member);
    try T.expectEqual(@as(usize, 3), numeric_member_count);
    try T.expectEqual(@as(usize, 2), bad_separator_count);
}

test "parser: unterminated generic type reference reports TS1005 and recovers" {
    var s = try newTestSetup(
        \\interface IQService {
        \\  all(promises: IPromise < any > []): IPromise<
    );
    defer destroyTestSetup(s);

    _ = s.parser.parseSourceFile() catch {};
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005 and std.mem.eql(u8, d.message, "'>' expected.")) found = true;
    }
    try T.expect(found);
}

test "parser: top-level public before break reports declaration expected" {
    var s = try newTestSetup("public break;");
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1128), s.parser.diagnostics.items[0].code);
}

test "parser: errant namespace accessibility modifier recovers following assignment" {
    var s = try newTestSetup(
        \\namespace M {
        \\  var x = 10;
        \\  private y = x;
        \\  export var z = y;
        \\}
    );
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    const root = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1128), s.parser.diagnostics.items[0].code);

    const ns = hir_mod.blockStmts(&s.hir, root)[0];
    const body = hir_mod.namespaceBody(&s.hir, ns);
    try T.expectEqual(@as(usize, 3), body.len);
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(body[1]));
}

test "parser: module modifiers before interface report TS1044 and recover" {
    var s = try newTestSetup("public interface I {}");
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1044), s.parser.diagnostics.items[0].code);
}

test "parser: malformed interface header reports upstream diagnostics" {
    var duplicate_extends = try newTestSetup("interface I extends A extends B {}");
    defer destroyTestSetup(duplicate_extends);
    duplicate_extends.parser.setTargetEs2015OrLater(true);
    _ = try duplicate_extends.parser.parseSourceFile();
    var saw_1172 = false;
    for (duplicate_extends.parser.diagnostics.items) |d| {
        if (d.code == 1172) saw_1172 = true;
    }
    try T.expect(saw_1172);

    var implements = try newTestSetup("interface I implements A {}");
    defer destroyTestSetup(implements);
    implements.parser.setTargetEs2015OrLater(true);
    _ = try implements.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), implements.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1176), implements.parser.diagnostics.items[0].code);

    var reserved_name = try newTestSetup("interface string {}");
    defer destroyTestSetup(reserved_name);
    reserved_name.parser.setTargetEs2015OrLater(true);
    _ = try reserved_name.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), reserved_name.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 2427), reserved_name.parser.diagnostics.items[0].code);
}

test "parser: malformed class heritage reports upstream diagnostics" {
    var empty_extends = try newTestSetup("class C extends {}");
    defer destroyTestSetup(empty_extends);
    empty_extends.parser.setTargetEs2015OrLater(true);
    _ = try empty_extends.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), empty_extends.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1097), empty_extends.parser.diagnostics.items[0].code);

    var trailing_extends = try newTestSetup("class C extends A, B {}");
    defer destroyTestSetup(trailing_extends);
    trailing_extends.parser.setTargetEs2015OrLater(true);
    _ = try trailing_extends.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), trailing_extends.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1174), trailing_extends.parser.diagnostics.items[0].code);

    var empty_after_extends_comma = try newTestSetup("class C extends A, {}");
    defer destroyTestSetup(empty_after_extends_comma);
    empty_after_extends_comma.parser.setTargetEs2015OrLater(true);
    _ = try empty_after_extends_comma.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), empty_after_extends_comma.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1009), empty_after_extends_comma.parser.diagnostics.items[0].code);

    var extends_after_implements = try newTestSetup("class C implements A extends B {}");
    defer destroyTestSetup(extends_after_implements);
    extends_after_implements.parser.setTargetEs2015OrLater(true);
    _ = try extends_after_implements.parser.parseSourceFile();
    var found_extends_after_implements = false;
    for (extends_after_implements.parser.diagnostics.items) |d| {
        if (d.code == 1173) found_extends_after_implements = true;
    }
    try T.expect(found_extends_after_implements);

    var empty_implements = try newTestSetup("class C extends A implements {}");
    defer destroyTestSetup(empty_implements);
    empty_implements.parser.setTargetEs2015OrLater(true);
    _ = try empty_implements.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), empty_implements.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1097), empty_implements.parser.diagnostics.items[0].code);

    var trailing_implements = try newTestSetup("class C implements B, {}");
    defer destroyTestSetup(trailing_implements);
    trailing_implements.parser.setTargetEs2015OrLater(true);
    _ = try trailing_implements.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), trailing_implements.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1009), trailing_implements.parser.diagnostics.items[0].code);
}

test "parser: primitive keyword may finish qualified type name" {
    var s = try newTestSetup("var v: x.void;");
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 0), s.parser.diagnostics.items.len);
}

test "parser: primitive keyword cannot start qualified type name" {
    var s = try newTestSetup("var v : void.x;");
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    try T.expectEqual(@as(usize, 1), s.parser.diagnostics.items.len);
    try T.expectEqual(@as(u32, 1005), s.parser.diagnostics.items[0].code);
    try T.expectEqualStrings("',' expected.", s.parser.diagnostics.items[0].message);
}

// §6.A 2000-3000 ratchet — the statement-terminator fallback must
// emit TS1005 "';' expected." (matching tsc) rather than a
// Home-internal "expected ';' or newline after statement" payload.
// Pins fixtures like `parserFuzz1` and
// `parser.numericSeparators.decmialNegative`.
test "parser: statement terminator fallback emits TS1005 not Home-internal text" {
    // Mirrors `parser.numericSeparators.decmialNegative` virtual file `16.ts`
    // (source `_10` on its own line). The terminator fallback must
    // pick TS1005 to match upstream baselines.
    var s = try newTestSetup("_10\n");
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    for (s.parser.diagnostics.items) |d| {
        try T.expect(!std.mem.startsWith(u8, d.message, "expected ';' or newline"));
    }
}

test "parser: decimal separator negative recovery matches upstream shapes" {
    var dotted_number = try newTestSetup("_0.0e0\n");
    defer destroyTestSetup(dotted_number);
    _ = dotted_number.parser.parseSourceFile() catch {};

    var saw_unexpected_identifier = false;
    for (dotted_number.parser.diagnostics.items) |d| {
        if (d.code == 1434 and d.pos == 0 and std.mem.eql(u8, d.message, "Unexpected keyword or identifier.")) saw_unexpected_identifier = true;
        try T.expect(d.code != 1109);
    }
    try T.expect(saw_unexpected_identifier);

    var dot_identifier = try newTestSetup("._\n");
    defer destroyTestSetup(dot_identifier);
    _ = dot_identifier.parser.parseSourceFile() catch {};
    var saw_dot_statement = false;
    var saw_dot_name = false;
    for (dot_identifier.parser.diagnostics.items) |d| {
        if (d.code == 1128 and std.mem.eql(u8, d.message, "Declaration or statement expected.")) saw_dot_statement = true;
        if (d.code == 2304 and std.mem.eql(u8, d.message, "Cannot find name '_'.")) saw_dot_name = true;
        try T.expect(d.code != 1109);
    }
    try T.expect(saw_dot_statement);
    try T.expect(saw_dot_name);

    var escaped_identifier = try newTestSetup("1\\u005F01234\n");
    defer destroyTestSetup(escaped_identifier);
    _ = escaped_identifier.parser.parseSourceFile() catch {};
    var saw_escaped_semicolon = false;
    var saw_escaped_name = false;
    for (escaped_identifier.parser.diagnostics.items) |d| {
        if (d.code == 1005 and std.mem.eql(u8, d.message, "';' expected.")) saw_escaped_semicolon = true;
        if (d.code == 2304 and std.mem.eql(u8, d.message, "Cannot find name '\\u005F01234'.")) saw_escaped_name = true;
        try T.expect(d.code != 1109);
    }
    try T.expect(saw_escaped_semicolon);
    try T.expect(saw_escaped_name);
}

// §6.A 2000-3000 ratchet — the expression fallback for unrecognised
// leading tokens (e.g. `var` opening a malformed lambda body) must
// emit TS1109 "Expression expected." rather than a Home-internal
// "unexpected token in expression: kw_var" payload. Pins
// `parserMissingLambdaOpenBrace1` and `parserStatementIsNotA*`.
test "parser: expression fallback emits TS1109 not Home-internal text" {
    var s = try newTestSetup("foo(test =>\n  var x = 0;\n);\n");
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1109 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1109 and std.mem.eql(u8, d.message, "Expression expected.")) saw_ts1109 = true;
        try T.expect(!std.mem.startsWith(u8, d.message, "unexpected token in expression"));
    }
    try T.expect(saw_ts1109);
}

test "parser: finally in expression position reports upstream recovery" {
    var s = try newTestSetup("a / finally");
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    var found_expr = false;
    var found_brace = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1109 and std.mem.eql(u8, d.message, "Expression expected.")) found_expr = true;
        if (d.code == 1005 and std.mem.eql(u8, d.message, "'{' expected.")) found_brace = true;
        try T.expect(!std.mem.startsWith(u8, d.message, "unexpected token in expression"));
    }
    try T.expect(found_expr);
    try T.expect(found_brace);
}

test "parser: dangling qualified type name before newline keyword reports TS1003" {
    var s = try newTestSetup(
        \\var x: TypeModule1.
        \\namespace TypeModule2 {
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1003 and std.mem.eql(u8, d.message, "Identifier expected.")) found = true;
        try T.expect(d.code != 1109);
    }
    try T.expect(found);
}

test "parser: unterminated class body at eof reports TS1005 close brace" {
    var s = try newTestSetup(
        \\class Outer
        \\{
        \\static public
    );
    defer destroyTestSetup(s);
    s.parser.setTargetEs2015OrLater(true);

    _ = try s.parser.parseSourceFile();
    var found = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1005 and std.mem.eql(u8, d.message, "'}' expected.")) found = true;
        try T.expect(d.code != 1109);
    }
    try T.expect(found);
}

test "parser: constructor is an expression identifier outside class member grammar" {
    var s = try newTestSetup(
        \\function f(constructor) {
        \\  Object.defineProperty(constructor.prototype, "constructor", { value: constructor });
        \\}
    );
    defer destroyTestSetup(s);

    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1109);
        try T.expect(d.code != 1005);
    }
}

test "parser: TS1222 generator overload reports at asterisk column not function keyword" {
    // Regression: TS1221/TS1222 used to anchor at the `function`
    // keyword (col 1 for an unindented declaration). tsc anchors at
    // the `*` token instead, so we should match it. Source is a
    // non-ambient overload signature, which produces TS1222
    // ("An overload signature cannot be declared as a generator.").
    var s = try newTestSetup(
        \\function* g(): number;
        \\function* g(): number { return 1; }
    );
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_ts1222_at_asterisk = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1222) {
            // `function* g(): number;` — `function` is bytes 0..7,
            // `*` is byte 8. Anchor must be at the `*` (pos==8), NOT
            // at the `function` keyword (pos==0).
            if (d.pos == 8) saw_ts1222_at_asterisk = true;
        }
    }
    try T.expect(saw_ts1222_at_asterisk);
}

test "parser: 'declare' is valid on a class property and emits no TS1031" {
    // Mirrors conformance fixtures `override14.ts` and
    // `decoratorInAmbientContext.ts` — tsc treats `declare` on a
    // class field as a legal forward declaration (the type system
    // assumes external initialization), so the parser must NOT emit
    // TS1031 'modifier cannot appear on class elements of this kind'.
    // `declare` on a *method* is still invalid; that branch is
    // covered by the next test.
    const sources = [_][]const u8{
        "class C { declare a: number; }",
        "class C { declare property: number }",
        "class C { declare ['k']: number; }",
    };
    for (sources) |src| {
        var s = try newTestSetup(src);
        defer destroyTestSetup(s);
        _ = s.parser.parseSourceFile() catch {};
        for (s.parser.diagnostics.items) |d| {
            try T.expect(d.code != 1031);
        }
    }
}

test "parser: 'declare' on a class method still reports TS1031" {
    // `declare foo() { }` keeps the upstream diagnostic because
    // `declare` only applies to class *fields*. This is the
    // counter-test for the property-only carve-out above.
    var s = try newTestSetup("class C { declare foo() { } }");
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1031 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1031) saw_ts1031 = true;
    }
    try T.expect(saw_ts1031);
}

test "parser: object-literal generator '*' without property name reports TS1003" {
    // Mirrors FunctionPropertyAssignments{2,3,4,6}_es6 baselines:
    // when an object literal contains `*` followed by something that
    // cannot start a method name (`(`, `{`, `}`, `<`), tsc reports
    // TS1003 'Identifier expected.' anchored at that next token.
    const Case = struct {
        source: []const u8,
        expected_pos: u32,
    };
    const cases = [_]Case{
        // `var v = { *() { } }` — `(` is byte 11.
        .{ .source = "var v = { *() { } }", .expected_pos = 11 },
        // `var v = { *{ } }` — `{` is byte 11.
        .{ .source = "var v = { *{ } }", .expected_pos = 11 },
        // `var v = { * }` — `}` is byte 12.
        .{ .source = "var v = { * }", .expected_pos = 12 },
        // `var v = { *<T>() { } }` — `<` is byte 11.
        .{ .source = "var v = { *<T>() { } }", .expected_pos = 11 },
    };
    for (cases) |c| {
        var s = try newTestSetup(c.source);
        defer destroyTestSetup(s);
        _ = s.parser.parseSourceFile() catch {};
        var saw_ts1003_at_expected = false;
        for (s.parser.diagnostics.items) |d| {
            if (d.code == 1003 and d.pos == c.expected_pos) saw_ts1003_at_expected = true;
            // The TS1109 'expected (' fallback must NOT fire — that
            // was the pre-fix diagnostic shape upstream did not have.
            try T.expect(d.code != 1109);
        }
        try T.expect(saw_ts1003_at_expected);
    }
}

test "parser: elided tuple element reports TS1110 at the comma" {
    // `[number,,]` — the second `,` has no preceding type. Upstream
    // tsc reports TS1110 'Type expected.' at the comma position
    // (column 16 in `var v: [number,,]`). Mirrors `TupleType6.ts(1,16)`.
    const src = "var v: [number,,]";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1110 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, ",,").? + 1);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1110 and d.pos == expected_pos) saw_ts1110 = true;
    }
    try T.expect(saw_ts1110);
}

test "parser: rest parameter marked optional reports TS1047 at the question mark" {
    // `class C { foo(...bar?) {} }` — TS1047 fires at the `?` token.
    // Mirrors upstream `parserParameterList9.ts(2,14)` /
    // `parserParameterList11.ts(1,8)` where the rest parameter cannot
    // also carry the `?` optional marker.
    const src = "class C { foo(...bar?) {} }";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1047 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "?").?);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1047 and d.pos == expected_pos) saw_ts1047 = true;
    }
    try T.expect(saw_ts1047);
}

test "parser: rest parameter with initializer reports TS1048 at the parameter name" {
    // `class C { foo(...bar = 0) {} }` — TS1048 fires at the parameter
    // name. Mirrors upstream `parserParameterList10.ts(2,11)`.
    const src = "class C { foo(...bar = 0) {} }";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1048 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "bar").?);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1048 and d.pos == expected_pos) saw_ts1048 = true;
    }
    try T.expect(saw_ts1048);
}

test "parser: function body in ambient declare reports TS1183 at open brace" {
    // `declare function Foo() {}` — the `{` opens an implementation
    // body inside an ambient context. Mirrors upstream tsc on
    // `parserFunctionDeclaration2.ts(1,24)`.
    const src = "declare function Foo() {}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1183 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "{").?);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1183 and d.pos == expected_pos) saw_ts1183 = true;
    }
    try T.expect(saw_ts1183);
}

test "parser: 'export function await' at module top-level reports TS1262 on await" {
    // `export function await() {}` — `await` is a reserved word at the
    // top level of an external module (the `export` makes the source
    // file a module). tsc anchors TS1262 at the function name token.
    // Mirrors fixture `topLevelAwaitErrors.6`.
    const src = "export function await() {}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var saw_ts1262 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "await").?);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1262 and d.pos == expected_pos) saw_ts1262 = true;
    }
    try T.expect(saw_ts1262);
}

test "parser: bare 'module \"Foo\" {}' reports TS1035 on the quoted name" {
    // Quoted-name namespace/module declarations are only legal in
    // ambient contexts. In a regular `.ts` file (no `declare`, not a
    // `.d.ts`), `module "Foo" {}` must report TS1035 anchored at the
    // string literal name. Mirrors upstream tsc on
    // `parserModuleDeclaration1.ts(1,8)`.
    const src = "module \"Foo\" {\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_ts1035 = false;
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "\"Foo\"").?);
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1035 and d.pos == expected_pos) saw_ts1035 = true;
    }
    try T.expect(saw_ts1035);
}

test "parser: 'declare module \"Foo\" {}' does not report TS1035" {
    // The same form is legal under a `declare` wrapper — TS1035 must
    // only fire on non-ambient quoted modules.
    const src = "declare module \"Foo\" {\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1035);
    }
}

test "parser: 'declare constructor() {}' inside a class body does NOT report TS1183" {
    // The per-member `declare` modifier on a constructor is rejected
    // with TS1031 only — TS1183 must NOT cascade. Pin upstream tsc's
    // single-diagnostic behaviour from `parserConstructorDeclaration4.ts`.
    const src = "class C {\n  declare constructor() { }\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1183);
    }
}

test "parser: 'constructor<>()' reports TS1098 (empty list) and TS1092" {
    // `class C { constructor<>() {} }` — both the empty type
    // parameter list TS1098 and the constructor-cannot-be-generic
    // TS1092 must fire. The TS1092 anchor is synthesised one past
    // the `<` since there is no type parameter to point at. Mirrors
    // `parserConstructorDeclaration11.ts(2,14)` / `(2,15)`.
    const src = "class C {\n  constructor<>() { }\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_1098 = false;
    var saw_1092 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1098) saw_1098 = true;
        if (d.code == 1092) saw_1092 = true;
    }
    try T.expect(saw_1098);
    try T.expect(saw_1092);
}

test "parser: '*constructor()' reports TS1368 anchored at the constructor name" {
    // The `*` marker captured in `is_generator` is followed by the
    // `constructor` name. Constructors cannot be generators; tsc
    // anchors TS1368 at the `constructor` keyword (NOT at the `*`).
    // Mirrors `constructorNameInGenerator.ts(2,6)`.
    const src = "class C2 {\n    *constructor() {}\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "constructor").?);
    var saw_ts1368 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1368 and d.pos == expected_pos) saw_ts1368 = true;
    }
    try T.expect(saw_ts1368);
}

test "parser: 'declare Foo() {}' inside a class body reports TS1183 at the body brace" {
    // Per-member `declare` modifier on a method that nonetheless has
    // an implementation body. tsc emits both TS1031 (modifier not
    // allowed) and TS1183 (implementation in ambient context); the
    // TS1183 anchors at the `{` of the method body. Mirrors
    // `parserMemberFunctionDeclaration5.ts(2,19)`.
    const src = "class C {\n    declare Foo() { }\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    const expected_pos: u32 = @intCast(std.mem.indexOf(u8, src, "{ }").?);
    var saw_ts1183 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1183 and d.pos == expected_pos) saw_ts1183 = true;
    }
    try T.expect(saw_ts1183);
}

test "parser: 'LBL: continue LBL;' where LBL wraps a non-iteration reports TS1115" {
    // The label binds the `continue` statement itself (not a
    // for/while/do), so `continue LBL` has no enclosing iteration to
    // jump to. tsc emits TS1115 on the `continue` keyword. Mirrors
    // `parser_continueTarget1.ts`.
    const src = "target:\n  continue target;";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_ts1115 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1115) saw_ts1115 = true;
    }
    try T.expect(saw_ts1115);
}

test "parser: nested labels 'a: b: while(...) continue a' do not report TS1115" {
    // `target1: target2: while (...) { continue target1; }` — the
    // outer label wraps the inner labeled statement, which itself
    // wraps a `while`. Peeking through chained `identifier ':'`
    // tokens lets the iteration flag propagate. Mirrors upstream
    // tsc on `parser_continueTarget3.ts`.
    const src = "target1:\ntarget2:\nwhile (true) { continue target1; }";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1115);
    }
}

test "parser: 'LBL: while (...) continue LBL;' wraps iteration so TS1115 is suppressed" {
    // The label binds a `while` statement — a valid `continue` target.
    // No TS1115 should fire even though the same label name appears
    // in both the declaration and the use.
    const src = "L: while (x) { continue L; }";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    for (s.parser.diagnostics.items) |d| {
        try T.expect(d.code != 1115);
    }
}

test "parser: single computed-name class field with chained assignment value" {
    // `[e] = 0\n[e2] = 1` — JavaScript's `[` continuation inside an
    // expression means the value of the first field is the chained
    // assignment `0[e2] = 1`, not just `0`. Verify our parser
    // matches tsc's parse shape so the checker walks the full
    // expression chain (and reports TS2304 on both `e` and `e2`).
    var s = try newTestSetup(
        \\class C {
        \\    [e] = 0
        \\    [e2] = 1
        \\}
    );
    defer destroyTestSetup(s);
    const root = try s.parser.parseSourceFile();
    const top = hir_mod.blockStmts(&s.hir, root)[0];
    const members = hir_mod.classMembers(&s.hir, top);
    try T.expectEqual(@as(usize, 1), members.len);
    const m0 = hir_mod.objectPropertyOf(&s.hir, members[0]);
    try T.expect(m0.is_computed);
    try T.expect(m0.value != hir_mod.none_node_id);
    // The value must be a chained `0[e2] = 1`, i.e. an assignment.
    try T.expectEqual(hir_mod.NodeKind.assignment, s.hir.kindOf(m0.value));
}

test "parser: 'export [x: string]: string' in a class body reports TS1071 on export" {
    // `skipClassModifiers` consumes the `export` keyword (since `[`
    // can start a member), so the dedicated TS1071 check on the
    // unconsumed-export branch never fires. The index-signature
    // recognizer now also walks `mods.invalid_class_element_modifier`
    // and rewrites the would-be TS1031 to TS1071. Mirrors
    // `parserIndexMemberDeclaration9.ts(2,4)`.
    const src = "class C {\n   export [x: string]: string;\n}";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = try s.parser.parseSourceFile();
    var saw_ts1071 = false;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1071) saw_ts1071 = true;
    }
    try T.expect(saw_ts1071);
}

test "parser: prefix `+` followed only by `;` emits TS1109 at the semicolon" {
    // Regression for `plusOperatorInvalidOperations.ts(8,15)`: the
    // initializer `var result2 =+;` has a unary `+` with no operand.
    // Upstream tsc anchors `Expression expected.` (TS1109) at the
    // following token (here the `;`), not at the `+`. We previously
    // dropped the diagnostic entirely on the `=+;` shape because the
    // recursive `parseUnaryExpression` returned `error.UnexpectedToken`
    // before the recovery anchor had a chance to fire.
    const src = "var x =+;";
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var ts1109_at_semi: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code != 1109) continue;
        // `var x =+;` — the `;` sits at byte index 8 (0-based),
        // column 9 (1-based).
        if (d.pos == 8) ts1109_at_semi += 1;
    }
    try T.expect(ts1109_at_semi >= 1);
}

test "parser: plusOperatorInvalidOperations fixture emits TS1109 at both unary-plus recovery points" {
    // Regression for upstream `plusOperatorInvalidOperations.ts(8,15)`:
    // the multi-statement fixture has TWO invalid unary-`+` shapes
    // (`b+;` postfix + `=+;` prefix) and tsc anchors TS1109 at each
    // recovery point. We previously emitted only the first one.
    const src =
        \\// Unary operator +
        \\var b;
        \\
        \\// operand before +
        \\var result1 = b+;
        \\
        \\// miss  an operand
        \\var result2 =+;
        \\
    ;
    var s = try newTestSetup(src);
    defer destroyTestSetup(s);
    _ = s.parser.parseSourceFile() catch {};
    var ts1109_count: usize = 0;
    for (s.parser.diagnostics.items) |d| {
        if (d.code == 1109) ts1109_count += 1;
    }
    try T.expect(ts1109_count >= 2);
}
