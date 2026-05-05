//! TypeScript token kinds and shape.
//!
//! Per TS_PARITY_PLAN §0 / §1.1.1 (Phase 1.B). This is the canonical
//! token surface for the TS frontend; the parser at
//! `packages/ts_parser/` consumes a `[]const Token` produced by the
//! scanner at `packages/ts_lexer/src/scanner.zig`.
//!
//! Design tenets:
//!
//!   - **Tokens are 16 bytes.** `(start: u32, end: u32, kind: u16,
//!     flags: u16, line: u32) = 16 B`. tsgo's tokens are larger
//!     (`*Token` plus per-kind interface dispatch); we cache-line at
//!     2 K tokens per L1.
//!
//!   - **No copies.** `start`/`end` index back into the original
//!     source. Identifier and string contents are produced lazily via
//!     `Token.bytes(source)` — the scanner never duplicates anything.
//!
//!   - **Trivia is separate.** Whitespace + comments are accumulated
//!     into the leading-trivia of the *next* significant token (and
//!     the trailing-trivia of the *previous* token via flags), but the
//!     significant-token stream is what the parser sees.
//!
//!   - **Contextual keywords are kinds.** `as`, `async`, `await`,
//!     `from`, `get`, `set`, `of`, `satisfies`, `using` all get
//!     dedicated kinds. The parser disambiguates based on position;
//!     re-classifying keywords back to identifiers is a one-line
//!     `if (tok.kind.isContextualKeyword()) ...`.
//!
//!   - **TS keyword superset.** This enum covers the entire ES2024 +
//!     TS grammar, including TS-only modifiers (`abstract`, `declare`,
//!     `interface`, etc.) and literal-type sentinels (`any`,
//!     `unknown`, `never`).

const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn empty() Span {
        return .{ .start = 0, .end = 0 };
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};

/// Bit-flags carried alongside each token. Packed into 16 bits.
pub const TokenFlags = packed struct(u16) {
    /// True if this token was preceded by a line terminator (used for
    /// ASI — automatic semicolon insertion).
    preceded_by_newline: bool = false,
    /// True if this token was scanned inside a JSX context (changes
    /// e.g. how `<` is handled).
    in_jsx_context: bool = false,
    /// True if this is a contextual keyword that might re-classify to
    /// an identifier depending on parser position.
    contextual: bool = false,
    /// True if this token is a numeric literal that includes the
    /// `_` digit-separator (TS 5.0+).
    has_separator: bool = false,
    /// True if this token is a string literal containing one or more
    /// template-substitutions (i.e. a `${expr}` boundary).
    is_template_part: bool = false,
    /// Reserved for future use.
    _padding: u11 = 0,
};

/// 16-byte token record. SoA-friendly: scanner emits `[]Token` with no
/// pointers, so iteration over the stream is one cache line per 4
/// tokens.
pub const Token = struct {
    span: Span,
    kind: TokenKind,
    flags: TokenFlags,
    /// 1-based line number of the token's first byte. Used for
    /// diagnostics; the scanner tracks this implicitly so the parser
    /// doesn't have to re-scan for line breaks.
    line: u32,

    pub fn bytes(self: Token, source: []const u8) []const u8 {
        return source[self.span.start..self.span.end];
    }

    /// Returns true if `kind` matches `expected`. Convenience for the
    /// many places the parser needs `if (tok.is(.identifier))`.
    pub fn is(self: Token, expected: TokenKind) bool {
        return self.kind == expected;
    }
};

/// Token-kind enum. Numeric values are stable but not exposed publicly;
/// switch on the named variant.
///
/// Group ordering (hot path: parser dispatch on kind):
///   1. End-of-stream / error
///   2. Significant trivia (rare; may surface in `--listFiles` etc.)
///   3. Literals (identifier, number, string, regex, template parts,
///      bigint)
///   4. Keywords (reserved + TS-specific + contextual)
///   5. Punctuation (single-char and multi-char)
///   6. Operators (assignment, equality, arithmetic, …)
///   7. JSX-only tokens
///
/// Total fits in u16 with room to grow; we keep it within u8 today by
/// careful layout, but reserve u16 in the Token struct for headroom.
pub const TokenKind = enum(u16) {
    // -- 1. End / error --
    eof = 0,
    /// Lexer encountered a sequence it could not classify.
    invalid,

    // -- 2. Identifiers & literals --
    identifier,
    private_identifier, // `#foo`
    number_literal,
    bigint_literal,
    string_literal,
    no_substitution_template, // `` `xyz` `` (no `${}`)
    template_head, // `` `xyz${ ``
    template_middle, // `` }xyz${ ``
    template_tail, // `` }xyz` ``
    regex_literal,

    // -- 3. Reserved keywords (ES) --
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_false,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_null,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_true,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    kw_yield,

    // -- 4. Strict-mode reserved --
    kw_implements,
    kw_interface,
    kw_let,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,

    // -- 5. TS-only keywords --
    kw_abstract,
    kw_any,
    kw_as,
    kw_asserts,
    kw_async,
    kw_await,
    kw_bigint,
    kw_boolean,
    kw_constructor,
    kw_declare,
    kw_from,
    kw_get,
    kw_global,
    kw_infer,
    kw_is,
    kw_keyof,
    kw_module,
    kw_namespace,
    kw_never,
    kw_number,
    kw_object,
    kw_of,
    kw_out,
    kw_override,
    kw_readonly,
    kw_require,
    kw_satisfies,
    kw_set,
    kw_string,
    kw_symbol,
    kw_type,
    kw_undefined,
    kw_unique,
    kw_unknown,
    kw_using,
    kw_accessor,

    // -- 6. Punctuation --
    open_brace, // {
    close_brace, // }
    open_paren, // (
    close_paren, // )
    open_bracket, // [
    close_bracket, // ]
    semicolon, // ;
    comma, // ,
    dot, // .
    dot_dot_dot, // ...
    colon, // :
    arrow, // =>
    at, // @ (decorators)
    backtick, // ` (only emitted inside template handling; usually consumed)
    hash, // # (only as private-name leader; usually consumed)
    question, // ?
    question_dot, // ?.

    // -- 7. Operators --
    // Equality
    equal_equal, // ==
    bang_equal, // !=
    equal_equal_equal, // ===
    bang_equal_equal, // !==

    // Comparison
    less_than, // <
    less_than_equal, // <=
    greater_than, // >
    greater_than_equal, // >=

    // Assignment family
    equal, // =
    plus_equal, // +=
    minus_equal, // -=
    asterisk_equal, // *=
    slash_equal, // /=
    percent_equal, // %=
    asterisk_asterisk_equal, // **=
    less_less_equal, // <<=
    greater_greater_equal, // >>=
    greater_greater_greater_equal, // >>>=
    ampersand_equal, // &=
    pipe_equal, // |=
    caret_equal, // ^=
    ampersand_ampersand_equal, // &&=
    pipe_pipe_equal, // ||=
    question_question_equal, // ??=

    // Arithmetic
    plus, // +
    minus, // -
    asterisk, // *
    slash, // /
    percent, // %
    asterisk_asterisk, // **

    // Bitwise
    ampersand, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    less_less, // <<
    greater_greater, // >>
    greater_greater_greater, // >>>

    // Logical
    ampersand_ampersand, // &&
    pipe_pipe, // ||
    question_question, // ??
    bang, // !

    // Update
    plus_plus, // ++
    minus_minus, // --

    // -- 8. JSX-only tokens (only emitted in TSX context) --
    jsx_text, // raw JSX child text run
    jsx_text_all_whitespace, // pure-whitespace JSX text (often elided)

    /// Returns true for tokens classified as keywords (reserved or
    /// contextual). Primary use: parser fast-paths for declaration
    /// detection.
    pub fn isKeyword(self: TokenKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(TokenKind.kw_break) and v <= @intFromEnum(TokenKind.kw_accessor);
    }

    /// Returns true if `self` is a "contextual" keyword — one that
    /// switches between keyword and identifier role based on grammatical
    /// position. Per the TS grammar these include `as`, `async`,
    /// `await`, `from`, `get`, `set`, `of`, `satisfies`, `type`,
    /// `using`, `accessor`, `out`, `override`, `readonly`, etc.
    pub fn isContextualKeyword(self: TokenKind) bool {
        return switch (self) {
            .kw_as,
            .kw_async,
            .kw_await,
            .kw_from,
            .kw_get,
            .kw_set,
            .kw_of,
            .kw_satisfies,
            .kw_type,
            .kw_using,
            .kw_accessor,
            .kw_out,
            .kw_override,
            .kw_readonly,
            .kw_require,
            .kw_module,
            .kw_namespace,
            .kw_global,
            .kw_constructor,
            .kw_is,
            .kw_asserts,
            .kw_infer,
            .kw_keyof,
            .kw_unique,
            .kw_abstract,
            .kw_any,
            .kw_bigint,
            .kw_boolean,
            .kw_declare,
            .kw_never,
            .kw_number,
            .kw_object,
            .kw_string,
            .kw_symbol,
            .kw_undefined,
            .kw_unknown,
            => true,
            else => false,
        };
    }

    /// Returns true if `self` is one of the "literal types" recognized
    /// by the TS type system: `any`, `unknown`, `never`, `void`,
    /// `null`, `undefined`, `string`, `number`, `boolean`, `bigint`,
    /// `symbol`, `object`. Used during type-annotation parsing.
    pub fn isPrimitiveTypeKeyword(self: TokenKind) bool {
        return switch (self) {
            .kw_any,
            .kw_unknown,
            .kw_never,
            .kw_void,
            .kw_null,
            .kw_undefined,
            .kw_string,
            .kw_number,
            .kw_boolean,
            .kw_bigint,
            .kw_symbol,
            .kw_object,
            => true,
            else => false,
        };
    }

    /// Returns true if `self` is a TS modifier keyword: `public`,
    /// `private`, `protected`, `readonly`, `static`, `abstract`,
    /// `async`, `override`, `accessor`, `declare`, `out`, `in`.
    pub fn isModifierKeyword(self: TokenKind) bool {
        return switch (self) {
            .kw_public,
            .kw_private,
            .kw_protected,
            .kw_readonly,
            .kw_static,
            .kw_abstract,
            .kw_async,
            .kw_override,
            .kw_accessor,
            .kw_declare,
            .kw_out,
            .kw_in,
            => true,
            else => false,
        };
    }

    /// True for tokens that can start an expression statement.
    /// Used for ASI heuristics + statement-vs-expression disambiguation.
    pub fn canStartExpression(self: TokenKind) bool {
        return switch (self) {
            .identifier,
            .private_identifier,
            .number_literal,
            .bigint_literal,
            .string_literal,
            .no_substitution_template,
            .template_head,
            .regex_literal,
            .open_paren,
            .open_bracket,
            .open_brace,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_this,
            .kw_super,
            .kw_new,
            .kw_function,
            .kw_class,
            .kw_async,
            .kw_await,
            .kw_yield,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_throw,
            .plus,
            .minus,
            .bang,
            .tilde,
            .plus_plus,
            .minus_minus,
            .dot_dot_dot,
            => true,
            else => false,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "Token: 16 bytes" {
    try t.expectEqual(@as(usize, 16), @sizeOf(Token));
}

test "TokenKind: keyword classification" {
    try t.expect(TokenKind.kw_class.isKeyword());
    try t.expect(TokenKind.kw_typeof.isKeyword());
    try t.expect(TokenKind.kw_satisfies.isKeyword());
    try t.expect(!TokenKind.identifier.isKeyword());
    try t.expect(!TokenKind.plus.isKeyword());
    try t.expect(!TokenKind.eof.isKeyword());
}

test "TokenKind: contextual keywords are detected" {
    try t.expect(TokenKind.kw_async.isContextualKeyword());
    try t.expect(TokenKind.kw_satisfies.isContextualKeyword());
    try t.expect(TokenKind.kw_type.isContextualKeyword());
    try t.expect(TokenKind.kw_of.isContextualKeyword());
    try t.expect(TokenKind.kw_readonly.isContextualKeyword());
    try t.expect(!TokenKind.kw_class.isContextualKeyword()); // reserved
    try t.expect(!TokenKind.kw_const.isContextualKeyword()); // reserved
}

test "TokenKind: primitive type keywords" {
    try t.expect(TokenKind.kw_any.isPrimitiveTypeKeyword());
    try t.expect(TokenKind.kw_unknown.isPrimitiveTypeKeyword());
    try t.expect(TokenKind.kw_never.isPrimitiveTypeKeyword());
    try t.expect(TokenKind.kw_string.isPrimitiveTypeKeyword());
    try t.expect(!TokenKind.kw_const.isPrimitiveTypeKeyword());
}

test "TokenKind: modifier keywords" {
    try t.expect(TokenKind.kw_public.isModifierKeyword());
    try t.expect(TokenKind.kw_readonly.isModifierKeyword());
    try t.expect(TokenKind.kw_async.isModifierKeyword());
    try t.expect(TokenKind.kw_abstract.isModifierKeyword());
    try t.expect(!TokenKind.kw_class.isModifierKeyword());
    try t.expect(!TokenKind.kw_let.isModifierKeyword());
}

test "TokenKind: canStartExpression" {
    try t.expect(TokenKind.identifier.canStartExpression());
    try t.expect(TokenKind.number_literal.canStartExpression());
    try t.expect(TokenKind.string_literal.canStartExpression());
    try t.expect(TokenKind.kw_true.canStartExpression());
    try t.expect(TokenKind.kw_function.canStartExpression());
    try t.expect(TokenKind.bang.canStartExpression());
    try t.expect(TokenKind.minus.canStartExpression());
    try t.expect(!TokenKind.semicolon.canStartExpression());
    try t.expect(!TokenKind.close_paren.canStartExpression());
    try t.expect(!TokenKind.eof.canStartExpression());
}

test "Token: bytes() returns the source slice" {
    const source = "let x = 42;";
    const tok: Token = .{
        .span = .{ .start = 4, .end = 5 },
        .kind = .identifier,
        .flags = .{},
        .line = 1,
    };
    try t.expectEqualStrings("x", tok.bytes(source));
}

test "Token: is() shorthand" {
    const tok: Token = .{
        .span = .{ .start = 0, .end = 3 },
        .kind = .kw_let,
        .flags = .{},
        .line = 1,
    };
    try t.expect(tok.is(.kw_let));
    try t.expect(!tok.is(.kw_const));
}

test "TokenFlags: is u16 packed" {
    try t.expectEqual(@as(usize, 2), @sizeOf(TokenFlags));
}
