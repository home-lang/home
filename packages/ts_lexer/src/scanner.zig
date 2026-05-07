//! TypeScript / TSX scanner.
//!
//! Per TS_PARITY_PLAN §1.1.1 (Phase 1.B). Phase 1 ships a *correct*
//! byte-by-byte scanner; the SIMD path described in §5.5 is Phase 5
//! work that drops in behind this same `Token` interface — the scanner
//! contract (input: `[]const u8` source; output: `[]Token`, no copies)
//! does not change between phases.
//!
//! Coverage today:
//!
//!   - Identifiers and the full keyword catalog (via `keywords.zig`).
//!     ASCII identifier-start / identifier-cont per ES; non-ASCII
//!     identifier characters are accepted permissively for now (full
//!     Unicode ID-Start / ID-Continue tables are a Phase 1 follow-up
//!     that mirrors tsgo's `internal/scanner/unicodeproperties.go`).
//!   - Numeric literals: decimal, hex (`0x…`), octal (`0o…`), binary
//!     (`0b…`), exponent suffix, `n` BigInt suffix, `_` digit
//!     separators (TS 5.0+).
//!   - String literals: single-quote, double-quote, with `\…` escape
//!     handling and line-continuation handling. Template literals
//!     handled to the substitution boundary (`${…}`); the parser
//!     drives back through `rescanTemplate` after each interpolated
//!     expression.
//!   - All ASCII punctuation + the multi-character operator set
//!     (compound assignment, equality, shifts, optional chaining).
//!   - Comments (line and block) consumed as trivia; the
//!     `preceded_by_newline` flag is set on the next significant
//!     token if the trivia spanned a newline.
//!
//! Out of scope for Phase 1.B (deferred):
//!
//!   - Regex literal scanning (parser-driven via `rescanSlashAsRegex`).
//!     Stub emits `regex_literal` from a future re-scan call site.
//!   - JSX child-text scanning. The TSX parser drives a `rescanJsx`
//!     entry point that consumes `<` / `</` / `{` boundaries and emits
//!     `jsx_text`. Wired but unused until Phase 1.D's parser starts
//!     handling JSX.
//!   - Full Unicode identifier ranges. Phase 1 follow-up bullets.

const std = @import("std");
const tk = @import("token.zig");
const keywords = @import("keywords.zig");

pub const Token = tk.Token;
pub const TokenKind = tk.TokenKind;
pub const TokenFlags = tk.TokenFlags;
pub const Span = tk.Span;

pub const ScanError = error{
    UnterminatedString,
    UnterminatedTemplate,
    UnterminatedBlockComment,
    InvalidNumericLiteral,
    InvalidEscapeSequence,
    UnexpectedCharacter,
    OutOfMemory,
};

pub const Diagnostic = struct {
    pos: u32,
    line: u32,
    column: u32,
    message: []const u8,
};

pub const Scanner = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    /// Was the last consumed trivia run terminated by a newline?
    /// Set on the next significant token's flags.
    saw_newline: bool,
    /// Whether to treat `<` as JSX. Set by the parser via
    /// `setInJsxContext` before calling `next` from a TSX position.
    jsx_context: bool,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,
    /// Template-substitution stack. Each entry is the number of
    /// pending `{` opens inside the current substitution body. When
    /// the stack is non-empty and we see `}` with `top == 0`, we
    /// resume scanning the template body (emitting `template_middle`
    /// or `template_tail`) instead of producing a `close_brace`.
    template_brace_stack: std.ArrayListUnmanaged(u32),

    pub fn init(gpa: std.mem.Allocator, source: []const u8) Scanner {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .saw_newline = false,
            .jsx_context = false,
            .diagnostics = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(gpa),
            .template_brace_stack = .empty,
        };
    }

    pub fn deinit(self: *Scanner, gpa: std.mem.Allocator) void {
        self.diagnostics.deinit(gpa);
        self.diag_arena.deinit();
        self.template_brace_stack.deinit(gpa);
    }

    pub fn setInJsxContext(self: *Scanner, in_jsx: bool) void {
        self.jsx_context = in_jsx;
    }

    fn peekChar(self: *const Scanner) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekCharAt(self: *const Scanner, offset: u32) u8 {
        const p = self.pos + offset;
        if (p >= self.source.len) return 0;
        return self.source[p];
    }

    fn advanceChar(self: *Scanner) u8 {
        if (self.pos >= self.source.len) return 0;
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.peekChar() == expected) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn currentColumn(self: *const Scanner) u32 {
        return self.pos - self.line_start;
    }

    fn report(self: *Scanner, gpa: std.mem.Allocator, message: []const u8) void {
        const owned = self.diag_arena.allocator().dupe(u8, message) catch return;
        self.diagnostics.append(gpa, .{
            .pos = self.pos,
            .line = self.line,
            .column = self.currentColumn(),
            .message = owned,
        }) catch {};
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.pos >= self.source.len;
    }

    /// Consume whitespace and comments; sets `saw_newline` if the
    /// trivia run included a line terminator.
    fn skipTrivia(self: *Scanner) void {
        self.saw_newline = false;
        // Shebang `#!` on the very first line of source is treated as a
        // line comment (matches tsc's behaviour). Node CLI scripts often
        // start with `#!/usr/bin/env node`; the JS emitter preserves the
        // original line by re-emitting source[0..first_newline].
        if (self.pos == 0 and self.source.len >= 2 and
            self.source[0] == '#' and self.source[1] == '!')
        {
            self.pos += 2;
            while (!self.isAtEnd() and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') {
                self.pos += 1;
            }
        }
        while (!self.isAtEnd()) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                    self.saw_newline = true;
                },
                '\r' => {
                    self.pos += 1;
                    if (self.peekChar() == '\n') self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                    self.saw_newline = true;
                },
                '/' => {
                    if (self.peekCharAt(1) == '/') {
                        // Line comment: consume to newline.
                        self.pos += 2;
                        while (!self.isAtEnd() and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') {
                            self.pos += 1;
                        }
                    } else if (self.peekCharAt(1) == '*') {
                        // Block comment.
                        self.pos += 2;
                        while (!self.isAtEnd()) {
                            const ch = self.source[self.pos];
                            if (ch == '*' and self.peekCharAt(1) == '/') {
                                self.pos += 2;
                                break;
                            }
                            if (ch == '\n') {
                                self.line += 1;
                                self.line_start = self.pos + 1;
                                self.saw_newline = true;
                            } else if (ch == '\r') {
                                self.line += 1;
                                self.line_start = self.pos + 1;
                                self.saw_newline = true;
                                if (self.peekCharAt(1) == '\n') self.pos += 1;
                            }
                            self.pos += 1;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or c >= 0x80;
    }

    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn isDecimalDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn scanIdentifierOrKeyword(self: *Scanner, start: u32, line: u32, flags: TokenFlags) Token {
        while (!self.isAtEnd() and isIdentCont(self.source[self.pos])) {
            self.pos += 1;
        }
        const slice = self.source[start..self.pos];
        var f = flags;
        const k = if (keywords.lookup(slice)) |kw| blk: {
            f.contextual = TokenKind.isContextualKeyword(kw);
            break :blk kw;
        } else TokenKind.identifier;
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = k,
            .flags = f,
            .line = line,
        };
    }

    fn scanPrivateIdentifier(self: *Scanner, start: u32, line: u32, flags: TokenFlags) Token {
        // The leading `#` was already consumed; scan the identifier body.
        while (!self.isAtEnd() and isIdentCont(self.source[self.pos])) {
            self.pos += 1;
        }
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = .private_identifier,
            .flags = flags,
            .line = line,
        };
    }

    fn scanNumber(self: *Scanner, gpa: std.mem.Allocator, start: u32, line: u32, flags: TokenFlags) ScanError!Token {
        var f = flags;
        var saw_separator = false;

        // Special radix prefixes: 0x / 0o / 0b
        if (self.source[start] == '0' and self.pos == start + 1 and !self.isAtEnd()) {
            const c = self.source[self.pos];
            if (c == 'x' or c == 'X') {
                self.pos += 1;
                if (!self.isAtEnd() and !isHexDigit(self.source[self.pos]) and self.source[self.pos] != '_') {
                    self.report(gpa, "expected hex digit after '0x'");
                    return error.InvalidNumericLiteral;
                }
                while (!self.isAtEnd()) {
                    const ch = self.source[self.pos];
                    if (isHexDigit(ch)) self.pos += 1 else if (ch == '_') {
                        saw_separator = true;
                        self.pos += 1;
                    } else break;
                }
                return self.numberFinish(start, line, f, saw_separator);
            }
            if (c == 'o' or c == 'O') {
                self.pos += 1;
                while (!self.isAtEnd()) {
                    const ch = self.source[self.pos];
                    if (ch >= '0' and ch <= '7') self.pos += 1 else if (ch == '_') {
                        saw_separator = true;
                        self.pos += 1;
                    } else break;
                }
                return self.numberFinish(start, line, f, saw_separator);
            }
            if (c == 'b' or c == 'B') {
                self.pos += 1;
                while (!self.isAtEnd()) {
                    const ch = self.source[self.pos];
                    if (ch == '0' or ch == '1') self.pos += 1 else if (ch == '_') {
                        saw_separator = true;
                        self.pos += 1;
                    } else break;
                }
                return self.numberFinish(start, line, f, saw_separator);
            }
        }

        // Decimal integer part (already consumed at least one digit).
        while (!self.isAtEnd()) {
            const ch = self.source[self.pos];
            if (isDecimalDigit(ch)) {
                self.pos += 1;
            } else if (ch == '_') {
                saw_separator = true;
                self.pos += 1;
            } else break;
        }

        // Optional decimal fraction.
        if (!self.isAtEnd() and self.source[self.pos] == '.' and
            self.pos + 1 < self.source.len and isDecimalDigit(self.source[self.pos + 1]))
        {
            self.pos += 1;
            while (!self.isAtEnd()) {
                const ch = self.source[self.pos];
                if (isDecimalDigit(ch)) {
                    self.pos += 1;
                } else if (ch == '_') {
                    saw_separator = true;
                    self.pos += 1;
                } else break;
            }
        }

        // Exponent.
        if (!self.isAtEnd() and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            if (!self.isAtEnd() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            if (self.isAtEnd() or !isDecimalDigit(self.source[self.pos])) {
                self.report(gpa, "exponent has no digits");
                return error.InvalidNumericLiteral;
            }
            while (!self.isAtEnd()) {
                const ch = self.source[self.pos];
                if (isDecimalDigit(ch)) {
                    self.pos += 1;
                } else if (ch == '_') {
                    saw_separator = true;
                    self.pos += 1;
                } else break;
            }
        }

        f.has_separator = saw_separator;
        // BigInt suffix.
        if (!self.isAtEnd() and self.source[self.pos] == 'n') {
            self.pos += 1;
            return .{
                .span = .{ .start = start, .end = self.pos },
                .kind = .bigint_literal,
                .flags = f,
                .line = line,
            };
        }
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = .number_literal,
            .flags = f,
            .line = line,
        };
    }

    fn numberFinish(self: *Scanner, start: u32, line: u32, flags_in: TokenFlags, saw_separator: bool) Token {
        var f = flags_in;
        f.has_separator = saw_separator;
        if (!self.isAtEnd() and self.source[self.pos] == 'n') {
            self.pos += 1;
            return .{
                .span = .{ .start = start, .end = self.pos },
                .kind = .bigint_literal,
                .flags = f,
                .line = line,
            };
        }
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = .number_literal,
            .flags = f,
            .line = line,
        };
    }

    fn scanString(self: *Scanner, gpa: std.mem.Allocator, quote: u8, start: u32, line: u32, flags: TokenFlags) ScanError!Token {
        while (!self.isAtEnd()) {
            const c = self.source[self.pos];
            if (c == quote) {
                self.pos += 1;
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = .string_literal,
                    .flags = flags,
                    .line = line,
                };
            }
            if (c == '\n' or c == '\r') {
                self.report(gpa, "unterminated string literal");
                return error.UnterminatedString;
            }
            if (c == '\\') {
                // Skip the escape sequence; we don't decode here. The
                // parser/binder decodes when constructing the AST node.
                self.pos += 1;
                if (self.isAtEnd()) {
                    self.report(gpa, "unterminated string literal at EOF");
                    return error.UnterminatedString;
                }
                const esc = self.source[self.pos];
                self.pos += 1;
                // Line-continuation: a backslash followed by \n / \r
                // (handled above by consuming the `\\` then the newline).
                if (esc == '\n') {
                    self.line += 1;
                    self.line_start = self.pos;
                } else if (esc == '\r') {
                    if (!self.isAtEnd() and self.source[self.pos] == '\n') self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                }
                continue;
            }
            self.pos += 1;
        }
        self.report(gpa, "unterminated string literal at EOF");
        return error.UnterminatedString;
    }

    /// Scan a `` `…` `` template literal head/middle/tail/no-substitution
    /// fragment. This is called both for the *opening* backtick and
    /// (via `rescanTemplateAfterClosingBrace`) after the parser has
    /// finished an interpolated expression.
    fn scanTemplate(self: *Scanner, gpa: std.mem.Allocator, start: u32, line: u32, flags: TokenFlags, after_close_brace: bool) ScanError!Token {
        // If we entered via `}`, the scanner pos is already past it.
        // Otherwise the leading `` ` `` was consumed by the caller.
        const saw_substitution = after_close_brace;
        while (!self.isAtEnd()) {
            const c = self.source[self.pos];
            if (c == '`') {
                self.pos += 1;
                var f = flags;
                f.is_template_part = saw_substitution;
                const k: TokenKind = if (after_close_brace) .template_tail else if (saw_substitution) .template_tail else .no_substitution_template;
                // Closing the template — pop the stack entry pushed
                // for template_head/template_middle (only if we're
                // returning from a `}`-resume).
                if (after_close_brace and self.template_brace_stack.items.len > 0) {
                    _ = self.template_brace_stack.pop();
                }
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = k,
                    .flags = f,
                    .line = line,
                };
            }
            if (c == '$' and self.peekCharAt(1) == '{') {
                self.pos += 2;
                var f = flags;
                f.is_template_part = true;
                const k: TokenKind = if (after_close_brace) .template_middle else .template_head;
                // Push a fresh substitution frame for template_head;
                // for template_middle we reuse the existing frame
                // (still on the stack — `}` didn't pop it).
                if (!after_close_brace) {
                    try self.template_brace_stack.append(gpa, 0);
                }
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = k,
                    .flags = f,
                    .line = line,
                };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.isAtEnd()) break;
                const esc = self.source[self.pos];
                self.pos += 1;
                if (esc == '\n') {
                    self.line += 1;
                    self.line_start = self.pos;
                } else if (esc == '\r') {
                    if (!self.isAtEnd() and self.source[self.pos] == '\n') self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                }
                continue;
            }
            if (c == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            } else if (c == '\r') {
                self.line += 1;
                if (self.peekCharAt(1) == '\n') self.pos += 1;
                self.line_start = self.pos + 1;
            }
            self.pos += 1;
        }
        self.report(gpa, "unterminated template literal");
        return error.UnterminatedTemplate;
    }

    /// Scan a single significant token. Whitespace and comments are
    /// silently consumed.
    pub fn next(self: *Scanner, gpa: std.mem.Allocator) ScanError!Token {
        self.skipTrivia();
        const start = self.pos;
        const line = self.line;
        const flags: TokenFlags = .{ .preceded_by_newline = self.saw_newline };

        if (self.isAtEnd()) {
            return .{
                .span = .{ .start = start, .end = start },
                .kind = .eof,
                .flags = flags,
                .line = line,
            };
        }

        const c = self.source[self.pos];

        // Identifier / keyword
        if (isIdentStart(c)) {
            self.pos += 1;
            return self.scanIdentifierOrKeyword(start, line, flags);
        }

        // Private identifier #foo
        if (c == '#') {
            self.pos += 1;
            return self.scanPrivateIdentifier(start, line, flags);
        }

        // Numeric literal
        if (isDecimalDigit(c)) {
            self.pos += 1;
            return self.scanNumber(gpa, start, line, flags);
        }

        // String literals
        if (c == '\'' or c == '"') {
            self.pos += 1;
            return self.scanString(gpa, c, start, line, flags);
        }

        // Template literal — leading backtick.
        if (c == '`') {
            self.pos += 1;
            return self.scanTemplate(gpa, start, line, flags, false);
        }

        // Punctuation / operators
        self.pos += 1;
        switch (c) {
            '{' => {
                // Inside a template substitution, count nested braces
                // so the matching `}` doesn't end the substitution.
                if (self.template_brace_stack.items.len > 0) {
                    self.template_brace_stack.items[self.template_brace_stack.items.len - 1] += 1;
                }
                return self.tok(start, .open_brace, flags, line);
            },
            '}' => {
                if (self.template_brace_stack.items.len > 0) {
                    const top = &self.template_brace_stack.items[self.template_brace_stack.items.len - 1];
                    if (top.* == 0) {
                        // Resume template scan — emits template_middle
                        // or template_tail and pops the frame on
                        // template_tail (handled in scanTemplate).
                        return self.scanTemplate(gpa, start, line, flags, true);
                    }
                    top.* -= 1;
                }
                return self.tok(start, .close_brace, flags, line);
            },
            '(' => return self.tok(start, .open_paren, flags, line),
            ')' => return self.tok(start, .close_paren, flags, line),
            '[' => return self.tok(start, .open_bracket, flags, line),
            ']' => return self.tok(start, .close_bracket, flags, line),
            ';' => return self.tok(start, .semicolon, flags, line),
            ',' => return self.tok(start, .comma, flags, line),
            '@' => return self.tok(start, .at, flags, line),
            '~' => return self.tok(start, .tilde, flags, line),
            ':' => return self.tok(start, .colon, flags, line),
            '?' => {
                if (self.match('?')) {
                    if (self.match('=')) return self.tok(start, .question_question_equal, flags, line);
                    return self.tok(start, .question_question, flags, line);
                }
                if (self.match('.')) return self.tok(start, .question_dot, flags, line);
                return self.tok(start, .question, flags, line);
            },
            '.' => {
                if (self.peekChar() == '.' and self.peekCharAt(1) == '.') {
                    self.pos += 2;
                    return self.tok(start, .dot_dot_dot, flags, line);
                }
                if (isDecimalDigit(self.peekChar())) {
                    // .5 is a number literal.
                    return self.scanNumber(gpa, start, line, flags);
                }
                return self.tok(start, .dot, flags, line);
            },
            '=' => {
                if (self.match('=')) {
                    if (self.match('=')) return self.tok(start, .equal_equal_equal, flags, line);
                    return self.tok(start, .equal_equal, flags, line);
                }
                if (self.match('>')) return self.tok(start, .arrow, flags, line);
                return self.tok(start, .equal, flags, line);
            },
            '!' => {
                if (self.match('=')) {
                    if (self.match('=')) return self.tok(start, .bang_equal_equal, flags, line);
                    return self.tok(start, .bang_equal, flags, line);
                }
                return self.tok(start, .bang, flags, line);
            },
            '<' => {
                if (self.match('=')) return self.tok(start, .less_than_equal, flags, line);
                if (self.match('<')) {
                    if (self.match('=')) return self.tok(start, .less_less_equal, flags, line);
                    return self.tok(start, .less_less, flags, line);
                }
                return self.tok(start, .less_than, flags, line);
            },
            '>' => {
                // In TS, `>` is conservatively scanned as a single
                // token; the parser re-scans for `>>`, `>>>`, `>=` etc.
                // when it knows we're not inside a generic argument list.
                // For Phase 1.B we emit the longest match here and let
                // the parser disambiguate via `rescanGreater*` paths
                // when generics need it.
                if (self.match('=')) return self.tok(start, .greater_than_equal, flags, line);
                if (self.match('>')) {
                    if (self.match('>')) {
                        if (self.match('=')) return self.tok(start, .greater_greater_greater_equal, flags, line);
                        return self.tok(start, .greater_greater_greater, flags, line);
                    }
                    if (self.match('=')) return self.tok(start, .greater_greater_equal, flags, line);
                    return self.tok(start, .greater_greater, flags, line);
                }
                return self.tok(start, .greater_than, flags, line);
            },
            '+' => {
                if (self.match('=')) return self.tok(start, .plus_equal, flags, line);
                if (self.match('+')) return self.tok(start, .plus_plus, flags, line);
                return self.tok(start, .plus, flags, line);
            },
            '-' => {
                if (self.match('=')) return self.tok(start, .minus_equal, flags, line);
                if (self.match('-')) return self.tok(start, .minus_minus, flags, line);
                return self.tok(start, .minus, flags, line);
            },
            '*' => {
                if (self.match('*')) {
                    if (self.match('=')) return self.tok(start, .asterisk_asterisk_equal, flags, line);
                    return self.tok(start, .asterisk_asterisk, flags, line);
                }
                if (self.match('=')) return self.tok(start, .asterisk_equal, flags, line);
                return self.tok(start, .asterisk, flags, line);
            },
            '/' => {
                // Note: `/` is ambiguous with regex; the regex case is
                // driven by the parser's `rescanSlashAsRegex`. The
                // base scanner always emits arithmetic division; the
                // parser re-scans for regex when it knows the position
                // permits it.
                if (self.match('=')) return self.tok(start, .slash_equal, flags, line);
                return self.tok(start, .slash, flags, line);
            },
            '%' => {
                if (self.match('=')) return self.tok(start, .percent_equal, flags, line);
                return self.tok(start, .percent, flags, line);
            },
            '&' => {
                if (self.match('&')) {
                    if (self.match('=')) return self.tok(start, .ampersand_ampersand_equal, flags, line);
                    return self.tok(start, .ampersand_ampersand, flags, line);
                }
                if (self.match('=')) return self.tok(start, .ampersand_equal, flags, line);
                return self.tok(start, .ampersand, flags, line);
            },
            '|' => {
                if (self.match('|')) {
                    if (self.match('=')) return self.tok(start, .pipe_pipe_equal, flags, line);
                    return self.tok(start, .pipe_pipe, flags, line);
                }
                if (self.match('=')) return self.tok(start, .pipe_equal, flags, line);
                return self.tok(start, .pipe, flags, line);
            },
            '^' => {
                if (self.match('=')) return self.tok(start, .caret_equal, flags, line);
                return self.tok(start, .caret, flags, line);
            },
            else => {
                self.report(gpa, "unexpected character");
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = .invalid,
                    .flags = flags,
                    .line = line,
                };
            },
        }
    }

    fn tok(self: *Scanner, start: u32, kind: TokenKind, flags: TokenFlags, line: u32) Token {
        // `self.pos` was already advanced past the operator by the
        // caller (via `advanceChar` + `match` chains), so the span is
        // simply `(start, self.pos)`.
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = kind,
            .flags = flags,
            .line = line,
        };
    }

    /// Tokenize the entire source into a list. Convenience for tests
    /// and small one-off uses; production callers stream via `next`.
    pub fn tokenize(self: *Scanner, gpa: std.mem.Allocator) ScanError!std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(gpa);
        while (true) {
            const tok_ = try self.next(gpa);
            try tokens.append(gpa, tok_);
            if (tok_.kind == .eof) break;
        }
        return tokens;
    }
};

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "Scanner: empty input → EOF only" {
    var s = Scanner.init(t.allocator, "");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), toks.items.len);
    try t.expectEqual(TokenKind.eof, toks.items[0].kind);
}

test "Scanner: lex `let x = 42;`" {
    var s = Scanner.init(t.allocator, "let x = 42;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(@as(usize, 6), toks.items.len);
    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqualStrings("x", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.equal, toks.items[2].kind);
    try t.expectEqual(TokenKind.number_literal, toks.items[3].kind);
    try t.expectEqualStrings("42", toks.items[3].bytes(s.source));
    try t.expectEqual(TokenKind.semicolon, toks.items[4].kind);
    try t.expectEqual(TokenKind.eof, toks.items[5].kind);
}

test "Scanner: keywords" {
    var s = Scanner.init(t.allocator, "class function readonly satisfies async await");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_class, toks.items[0].kind);
    try t.expectEqual(TokenKind.kw_function, toks.items[1].kind);
    try t.expectEqual(TokenKind.kw_readonly, toks.items[2].kind);
    try t.expectEqual(TokenKind.kw_satisfies, toks.items[3].kind);
    try t.expectEqual(TokenKind.kw_async, toks.items[4].kind);
    try t.expectEqual(TokenKind.kw_await, toks.items[5].kind);
}

test "Scanner: numeric literals" {
    var s = Scanner.init(t.allocator, "0 1 42 3.14 1e10 1.5e-2 0x1F 0o755 0b1010 100_000 1n 0xCAFEn");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.number_literal, toks.items[0].kind);
    try t.expectEqualStrings("0", toks.items[0].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[1].kind);
    try t.expectEqual(TokenKind.number_literal, toks.items[2].kind);
    try t.expectEqualStrings("42", toks.items[2].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[3].kind);
    try t.expectEqualStrings("3.14", toks.items[3].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[4].kind);
    try t.expectEqualStrings("1e10", toks.items[4].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[5].kind);
    try t.expectEqualStrings("1.5e-2", toks.items[5].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[6].kind);
    try t.expectEqualStrings("0x1F", toks.items[6].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[7].kind);
    try t.expectEqualStrings("0o755", toks.items[7].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[8].kind);
    try t.expectEqualStrings("0b1010", toks.items[8].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[9].kind);
    try t.expect(toks.items[9].flags.has_separator);
    try t.expectEqual(TokenKind.bigint_literal, toks.items[10].kind);
    try t.expectEqualStrings("1n", toks.items[10].bytes(s.source));
    try t.expectEqual(TokenKind.bigint_literal, toks.items[11].kind);
}

test "Scanner: numeric separator — `const x = 1_000_000;`" {
    var s = Scanner.init(t.allocator, "const x = 1_000_000;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.kw_const, toks.items[0].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqual(TokenKind.equal, toks.items[2].kind);
    try t.expectEqual(TokenKind.number_literal, toks.items[3].kind);
    try t.expectEqualStrings("1_000_000", toks.items[3].bytes(s.source));
    try t.expect(toks.items[3].flags.has_separator);
    try t.expectEqual(TokenKind.semicolon, toks.items[4].kind);
}

test "Scanner: string literals — single and double" {
    var s = Scanner.init(t.allocator, "'foo' \"bar\" 'with\\'quote'");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.string_literal, toks.items[0].kind);
    try t.expectEqualStrings("'foo'", toks.items[0].bytes(s.source));
    try t.expectEqual(TokenKind.string_literal, toks.items[1].kind);
    try t.expectEqualStrings("\"bar\"", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.string_literal, toks.items[2].kind);
    try t.expectEqualStrings("'with\\'quote'", toks.items[2].bytes(s.source));
}

test "Scanner: unterminated string is an error" {
    var s = Scanner.init(t.allocator, "'oops");
    defer s.deinit(t.allocator);
    try t.expectError(error.UnterminatedString, s.next(t.allocator));
}

test "Scanner: line and block comments are trivia" {
    var s = Scanner.init(t.allocator,
        \\// line comment
        \\let /* block */ x = 1;
    );
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expect(toks.items[0].flags.preceded_by_newline);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqualStrings("x", toks.items[1].bytes(s.source));
}

test "Scanner: operator family — equality + arrow" {
    var s = Scanner.init(t.allocator, "a == b === c != d !== e => f");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.equal_equal, toks.items[1].kind);
    try t.expectEqual(TokenKind.equal_equal_equal, toks.items[3].kind);
    try t.expectEqual(TokenKind.bang_equal, toks.items[5].kind);
    try t.expectEqual(TokenKind.bang_equal_equal, toks.items[7].kind);
    try t.expectEqual(TokenKind.arrow, toks.items[9].kind);
}

test "Scanner: assignment family" {
    var s = Scanner.init(t.allocator, "a += b -= c *= d /= e **= f &&= g ??= h");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.plus_equal, toks.items[1].kind);
    try t.expectEqual(TokenKind.minus_equal, toks.items[3].kind);
    try t.expectEqual(TokenKind.asterisk_equal, toks.items[5].kind);
    try t.expectEqual(TokenKind.slash_equal, toks.items[7].kind);
    try t.expectEqual(TokenKind.asterisk_asterisk_equal, toks.items[9].kind);
    try t.expectEqual(TokenKind.ampersand_ampersand_equal, toks.items[11].kind);
    try t.expectEqual(TokenKind.question_question_equal, toks.items[13].kind);
}

test "Scanner: optional chaining and nullish coalescing" {
    var s = Scanner.init(t.allocator, "a?.b ?? c");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.question_dot, toks.items[1].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[2].kind);
    try t.expectEqual(TokenKind.question_question, toks.items[3].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[4].kind);
}

test "Scanner: spread operator" {
    var s = Scanner.init(t.allocator, "[...a]");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.open_bracket, toks.items[0].kind);
    try t.expectEqual(TokenKind.dot_dot_dot, toks.items[1].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[2].kind);
    try t.expectEqual(TokenKind.close_bracket, toks.items[3].kind);
}

test "Scanner: line tracking" {
    var s = Scanner.init(t.allocator, "a\nb\n\nc");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), toks.items[0].line);
    try t.expectEqual(@as(u32, 2), toks.items[1].line);
    try t.expectEqual(@as(u32, 4), toks.items[2].line);
}

test "Scanner: private identifier" {
    var s = Scanner.init(t.allocator, "this.#secret");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_this, toks.items[0].kind);
    try t.expectEqual(TokenKind.dot, toks.items[1].kind);
    try t.expectEqual(TokenKind.private_identifier, toks.items[2].kind);
    try t.expectEqualStrings("#secret", toks.items[2].bytes(s.source));
}

test "Scanner: template — no substitution" {
    var s = Scanner.init(t.allocator, "`hello world`");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.no_substitution_template, toks.items[0].kind);
    try t.expectEqualStrings("`hello world`", toks.items[0].bytes(s.source));
}

test "Scanner: template — head only (no parser-driven re-scan in this test)" {
    var s = Scanner.init(t.allocator, "`a${");
    defer s.deinit(t.allocator);
    const tok1 = try s.next(t.allocator);
    try t.expectEqual(TokenKind.template_head, tok1.kind);
    try t.expectEqualStrings("`a${", tok1.bytes(s.source));
}

test "Scanner: shebang line is treated as a leading comment" {
    var s = Scanner.init(t.allocator, "#!/usr/bin/env node\nconst x = 1;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_const, toks.items[0].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqualStrings("x", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.equal, toks.items[2].kind);
    try t.expectEqual(TokenKind.number_literal, toks.items[3].kind);
    try t.expectEqual(TokenKind.semicolon, toks.items[4].kind);
    try t.expectEqual(TokenKind.eof, toks.items[5].kind);
}

test "Scanner: shebang without trailing newline (file with only shebang)" {
    var s = Scanner.init(t.allocator, "#!/usr/bin/env node");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), toks.items.len);
    try t.expectEqual(TokenKind.eof, toks.items[0].kind);
}

test "Scanner: punctuation — full ASCII set" {
    var s = Scanner.init(t.allocator, "{}()[];,.@~?:");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    const expected = [_]TokenKind{
        .open_brace,    .close_brace, .open_paren, .close_paren,
        .open_bracket,  .close_bracket, .semicolon, .comma,
        .dot,           .at,           .tilde,      .question,
        .colon,         .eof,
    };
    try t.expectEqual(expected.len, toks.items.len);
    for (expected, 0..) |e, i| try t.expectEqual(e, toks.items[i].kind);
}
