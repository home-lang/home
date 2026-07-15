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
//!   - Regex literal scanning is done eagerly: when `/` (or `/=`) is
//!     encountered after a token that leaves the parser in an
//!     "expression-allowed" position (operator, `=`, `(`, `,`, `;`,
//!     `return`, `if`, `=>`, etc., or start-of-file), the scanner
//!     consumes the regex body + flags as a single `regex_literal`
//!     token. Otherwise it emits arithmetic `slash` / `slash_equal`.
//!     The parser still accepts `.slash` as a regex re-scan trigger
//!     for any leftover ambiguity (e.g. expression-position recovery
//!     after a parse error). See `slashStartsRegex` and
//!     `scanRegexLiteral` below.
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
    /// Kind of the most recently emitted significant token. Used to
    /// disambiguate `/` between division and regex-literal start —
    /// `/` is a regex when the preceding token leaves the parser in
    /// an "expression-allowed" position (operator, `=`, `(`, `,`,
    /// `;`, `return`, `if`, `=>`, …) and a divide otherwise (after
    /// an identifier, number, `)`, `]`, `}`, etc.). Initialized to
    /// `.eof` so the first token in a file is treated as
    /// expression-allowed.
    last_significant_kind: TokenKind,
    /// Set by `scanEscapedUnicodeCodePoint` when a malformed
    /// `\u{…}` escape has already been reported AND the offending
    /// character would otherwise tip the outer string/template scan
    /// into an "unterminated literal" follow-on diagnostic. Mirrors
    /// tsc: TS1199 / TS1125 on a malformed extended-unicode escape
    /// suppresses TS1002 / TS1160 on the same literal so the user
    /// sees one specific error instead of two stacked ones. Cleared
    /// at the start of each `scanString` / `scanTemplate` call.
    suppress_unterminated_literal: bool,
    /// Start offset / line of the most recent string literal that
    /// `scanString` bailed on (returned `error.UnterminatedString`).
    /// Consumed by `tokenize` to synthesize a recovery
    /// `string_literal` token so the parser can continue past the
    /// unterminated literal without emitting a follow-on TS1109.
    /// `null` when no pending unterminated literal is queued.
    pending_unterm_string_start: ?u32,
    pending_unterm_string_line: u32,
    pending_unterm_string_flags: TokenFlags,

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
            .last_significant_kind = .eof,
            .suppress_unterminated_literal = false,
            .pending_unterm_string_start = null,
            .pending_unterm_string_line = 1,
            .pending_unterm_string_flags = .{},
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

    fn reportAt(self: *Scanner, gpa: std.mem.Allocator, pos: u32, line: u32, message: []const u8) void {
        const owned = self.diag_arena.allocator().dupe(u8, message) catch return;
        self.diagnostics.append(gpa, .{
            .pos = pos,
            .line = line,
            .column = if (pos >= self.line_start) pos - self.line_start else 0,
            .message = owned,
        }) catch {};
    }

    fn reportBinaryFile(self: *Scanner, gpa: std.mem.Allocator) void {
        const owned = self.diag_arena.allocator().dupe(u8, "File appears to be binary.") catch return;
        self.diagnostics.append(gpa, .{
            .pos = 0,
            .line = 1,
            .column = 0,
            .message = owned,
        }) catch {};
    }

    fn reportFmtAt(self: *Scanner, gpa: std.mem.Allocator, pos: u32, line: u32, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.diag_arena.allocator(), fmt, args) catch return;
        self.diagnostics.append(gpa, .{
            .pos = pos,
            .line = line,
            .column = pos - self.line_start,
            .message = owned,
        }) catch {};
    }

    fn reportUnicodeEscapeUnexpectedBrace(self: *Scanner, gpa: std.mem.Allocator, from: u32, line: u32) void {
        var p = from;
        while (p < self.source.len) : (p += 1) {
            const ch = self.source[p];
            if (ch == '\n' or ch == '\r') return;
            if (ch == '}') {
                self.reportAt(gpa, p, line, "Unexpected '}'. Did you mean to escape it with backslash?");
                return;
            }
        }
    }

    fn scanEscapedHexDigits(self: *Scanner, gpa: std.mem.Allocator, start: u32, count: u32, line: u32) u32 {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const p = start + i;
            if (p >= self.source.len or !isHexDigit(self.source[p])) {
                self.reportAt(gpa, p, line, "Hexadecimal digit expected.");
                return @min(p + 1, @as(u32, @intCast(self.source.len)));
            }
        }
        return start + count;
    }

    fn scanEscapedUnicodeCodePoint(self: *Scanner, gpa: std.mem.Allocator, start: u32, line: u32, report_unexpected_brace: bool) u32 {
        var p = start;
        var digits: u32 = 0;
        var value: u32 = 0;
        var overflow_reported = false;
        while (p < self.source.len and self.source[p] != '}') : (p += 1) {
            const ch = self.source[p];
            if (!isHexDigit(ch)) {
                if (digits == 0) {
                    self.reportAt(gpa, p, line, "Hexadecimal digit expected.");
                } else {
                    self.reportAt(gpa, p, line, "Unterminated Unicode escape sequence.");
                }
                if (report_unexpected_brace) self.reportUnicodeEscapeUnexpectedBrace(gpa, p + 1, line);
                // When the bad character is a literal terminator
                // (string quote, template backtick, or line break),
                // leave it in place so the outer string/template
                // scanner closes the literal naturally instead of
                // racing past it and emitting a redundant
                // "unterminated literal" follow-on. Matches tsc on
                // fixtures like `unicodeExtendedEscapesInStrings20/21/22`.
                if (isLiteralTerminatorByte(ch)) {
                    self.suppress_unterminated_literal = true;
                    return p;
                }
                return p + 1;
            }
            digits += 1;
            // Once the accumulated codepoint exceeds the Unicode
            // Scalar Value cap (0x10FFFF), emit TS1198 — anchored at
            // the first hex digit so `(line, col)` matches upstream
            // tsc on `unicodeExtendedEscapesInStrings07/12` and
            // template-literal counterparts. Continue scanning so the
            // outer literal still terminates cleanly.
            const next_value: u64 = @as(u64, value) * 16 + hexValue(ch);
            if (next_value > 0x10FFFF and !overflow_reported) {
                self.reportAt(gpa, start, line, "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.");
                overflow_reported = true;
            }
            if (next_value <= 0x10FFFF) value = @intCast(next_value);
        }
        if (digits == 0 or p >= self.source.len or self.source[p] != '}') {
            self.reportAt(gpa, p, line, "Hexadecimal digit expected.");
            if (p >= self.source.len) {
                // EOF inside `\u{` — suppress the outer "unterminated"
                // follow-on so the user sees only the specific cause.
                self.suppress_unterminated_literal = true;
            }
            return @min(p + 1, @as(u32, @intCast(self.source.len)));
        }
        return p + 1;
    }

    fn scanEscapeSequence(self: *Scanner, gpa: std.mem.Allocator, slash_pos: u32, line: u32, report_unexpected_brace: bool) u32 {
        const esc_pos = slash_pos + 1;
        if (esc_pos >= self.source.len) return esc_pos;
        const esc = self.source[esc_pos];
        if (esc >= '0' and esc <= '7') {
            var end = esc_pos + 1;
            if (esc == '0' and (end >= self.source.len or !isDecimalDigit(self.source[end]))) {
                return end;
            }
            if (esc >= '0' and esc <= '3' and end < self.source.len and isOctalDigit(self.source[end])) {
                end += 1;
            }
            if (end < self.source.len and isOctalDigit(self.source[end])) {
                end += 1;
            }
            var value: u32 = 0;
            var p = esc_pos;
            while (p < end) : (p += 1) {
                value = value * 8 + @as(u32, self.source[p] - '0');
            }
            self.reportFmtAt(gpa, slash_pos, line, "Octal escape sequences are not allowed. Use the syntax '\\x{x:0>2}'.", .{value});
            return end;
        }
        if (esc == '8' or esc == '9') {
            self.reportFmtAt(gpa, slash_pos, line, "Escape sequence '\\{c}' is not allowed.", .{esc});
            return esc_pos + 1;
        }
        if (esc == 'x') return self.scanEscapedHexDigits(gpa, esc_pos + 1, 2, line);
        if (esc != 'u') return esc_pos + 1;
        if (esc_pos + 1 < self.source.len and self.source[esc_pos + 1] == '{') {
            return self.scanEscapedUnicodeCodePoint(gpa, esc_pos + 2, line, report_unexpected_brace);
        }
        return self.scanEscapedHexDigits(gpa, esc_pos + 1, 4, line);
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.pos >= self.source.len;
    }

    /// Consume whitespace and comments; sets `saw_newline` if the
    /// trivia run included a line terminator.
    fn skipTrivia(self: *Scanner, gpa: std.mem.Allocator) ScanError!void {
        self.saw_newline = false;
        const skipped_bom = self.pos == 0 and self.source.len >= 3 and
            std.mem.eql(u8, self.source[0..3], "\xEF\xBB\xBF");
        if (skipped_bom) {
            self.pos = 3;
            self.line_start = self.pos;
        }
        // Shebang `#!` on the very first line of source is treated as a
        // line comment (matches tsc's behaviour). Node CLI scripts often
        // start with `#!/usr/bin/env node`; the JS emitter preserves the
        // original line by re-emitting source[0..first_newline].
        if ((self.pos == 0 or skipped_bom) and self.source.len >= self.pos + 2 and
            self.source[self.pos] == '#' and self.source[self.pos + 1] == '!')
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
                        var closed = false;
                        while (!self.isAtEnd()) {
                            const ch = self.source[self.pos];
                            if (ch == '*' and self.peekCharAt(1) == '/') {
                                self.pos += 2;
                                closed = true;
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
                        if (!closed) {
                            self.report(gpa, "'*/' expected.");
                            return;
                        }
                    } else {
                        return;
                    }
                },
                '<', '|', '=', '>' => {
                    if (self.isConflictMarkerTrivia(self.pos)) {
                        self.scanConflictMarkerTrivia(gpa);
                        continue;
                    }
                    return;
                },
                else => return,
            }
        }
    }

    fn isConflictMarkerTrivia(self: *const Scanner, pos: u32) bool {
        const marker_len: u32 = 7;
        if (!(pos == 0 or (pos > 0 and isLineBreakByte(self.source[pos - 1])))) return false;
        if (pos + marker_len >= self.source.len) return false;

        const ch = self.source[pos];
        var i: u32 = 0;
        while (i < marker_len) : (i += 1) {
            if (self.source[pos + i] != ch) return false;
        }

        return ch == '=' or self.source[pos + marker_len] == ' ';
    }

    fn scanConflictMarkerTrivia(self: *Scanner, gpa: std.mem.Allocator) void {
        const start = self.pos;
        const line = self.line;
        self.reportAt(gpa, start, line, "Merge conflict marker encountered.");

        const ch = self.source[start];
        const len: u32 = @intCast(self.source.len);
        if (ch == '<' or ch == '>') {
            while (self.pos < len and !isLineBreakByte(self.source[self.pos])) {
                self.pos += 1;
            }
            return;
        }

        while (self.pos < len) {
            const current = self.source[self.pos];
            if ((current == '=' or current == '>') and current != ch and self.isConflictMarkerTrivia(self.pos)) {
                break;
            }
            if (current == '\n') {
                self.pos += 1;
                self.line += 1;
                self.line_start = self.pos;
                self.saw_newline = true;
                continue;
            }
            if (current == '\r') {
                self.pos += 1;
                if (self.pos < len and self.source[self.pos] == '\n') self.pos += 1;
                self.line += 1;
                self.line_start = self.pos;
                self.saw_newline = true;
                continue;
            }
            self.pos += 1;
        }
    }

    fn isLineBreakByte(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or c >= 0x80;
    }

    fn isDecodedIdentStart(cp: u32) bool {
        if (cp <= 0x7f) return isIdentStart(@intCast(cp));
        return true;
    }

    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn startsWithUtf8NotSign(self: *const Scanner) bool {
        return self.pos + 1 < self.source.len and
            self.source[self.pos] == 0xC2 and
            self.source[self.pos + 1] == 0xAC;
    }

    fn startsWithUtf8ReplacementCharacter(self: *const Scanner) bool {
        return self.pos + 2 < self.source.len and
            self.source[self.pos] == 0xEF and
            self.source[self.pos + 1] == 0xBF and
            self.source[self.pos + 2] == 0xBD;
    }

    fn isDecimalDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    /// True when `c` would naturally terminate a string or template
    /// literal scan (quote, backtick, or line break). Used by
    /// `scanEscapedUnicodeCodePoint` to decide whether to return
    /// without consuming the offending character.
    fn isLiteralTerminatorByte(c: u8) bool {
        return c == '"' or c == '\'' or c == '`' or c == '\n' or c == '\r';
    }

    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }

    fn isBinaryDigit(c: u8) bool {
        return c == '0' or c == '1';
    }

    fn hexValue(c: u8) u32 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return 10 + c - 'a';
        return 10 + c - 'A';
    }

    fn decodedUnicodeEscapeValue(self: *const Scanner, start: u32) ?u32 {
        if (start + 1 >= self.source.len or self.source[start] != '\\' or self.source[start + 1] != 'u') return null;
        var p = start + 2;
        if (p < self.source.len and self.source[p] == '{') {
            p += 1;
            var value: u32 = 0;
            var digits: u32 = 0;
            while (p < self.source.len and self.source[p] != '}') : (p += 1) {
                const ch = self.source[p];
                if (!isHexDigit(ch)) return null;
                value = value * 16 + hexValue(ch);
                digits += 1;
            }
            if (p >= self.source.len or self.source[p] != '}' or digits == 0) return null;
            return value;
        }
        if (p + 4 > self.source.len) return null;
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const ch = self.source[p + i];
            if (!isHexDigit(ch)) return null;
            value = value * 16 + hexValue(ch);
        }
        return value;
    }

    fn scanIdentifierOrKeyword(self: *Scanner, start: u32, line: u32, flags: TokenFlags) Token {
        var has_escape = false;
        while (!self.isAtEnd()) {
            const ch = self.source[self.pos];
            if (isIdentCont(ch)) {
                self.pos += 1;
                continue;
            }
            // ES2015+ allows IdentifierPart to be written as `\uXXXX`
            // or `\u{XXXXXX}`. Consume the escape and continue scanning
            // the identifier; the parser folds the escape into the
            // interned name later.
            if (ch == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                has_escape = true;
                self.pos += 2;
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    var p = self.pos + 1;
                    while (p < self.source.len and self.source[p] != '}' and isHexDigit(self.source[p])) : (p += 1) {}
                    if (p < self.source.len and self.source[p] == '}') p += 1;
                    self.pos = p;
                } else {
                    var n: u32 = 0;
                    while (n < 4 and self.pos < self.source.len and isHexDigit(self.source[self.pos])) : (n += 1) {
                        self.pos += 1;
                    }
                }
                continue;
            }
            break;
        }
        const slice = self.source[start..self.pos];
        var f = flags;
        f.has_escape = flags.has_escape or has_escape;
        const k = if (keywords.lookup(slice) orelse escapedKeywordKind(slice, f.has_escape)) |kw| blk: {
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

    fn escapedKeywordKind(slice: []const u8, has_escape: bool) ?TokenKind {
        if (!has_escape) return null;
        var decoded: [16]u8 = undefined;
        var out: usize = 0;
        var i: usize = 0;
        while (i < slice.len) {
            var cp: u32 = slice[i];
            if (slice[i] == '\\' and i + 1 < slice.len and slice[i + 1] == 'u') {
                const parsed = parseIdentifierEscape(slice, i) orelse return null;
                cp = parsed.cp;
                i = parsed.next;
            } else {
                i += 1;
            }
            if (cp > 0x7f or out >= decoded.len) return null;
            decoded[out] = @intCast(cp);
            out += 1;
        }
        return keywords.lookup(decoded[0..out]);
    }

    const ParsedIdentifierEscape = struct {
        cp: u32,
        next: usize,
    };

    fn parseIdentifierEscape(slice: []const u8, start: usize) ?ParsedIdentifierEscape {
        if (start + 2 >= slice.len) return null;
        if (slice[start] != '\\' or slice[start + 1] != 'u') return null;
        if (slice[start + 2] == '{') {
            var value: u32 = 0;
            var i = start + 3;
            if (i >= slice.len) return null;
            while (i < slice.len and slice[i] != '}') : (i += 1) {
                if (!isHexDigit(slice[i])) return null;
                value = value * 16 + hexValue(slice[i]);
                if (value > 0x10FFFF) return null;
            }
            if (i >= slice.len or slice[i] != '}') return null;
            return .{ .cp = value, .next = i + 1 };
        }
        if (start + 6 > slice.len) return null;
        var value: u32 = 0;
        var i = start + 2;
        while (i < start + 6) : (i += 1) {
            if (!isHexDigit(slice[i])) return null;
            value = value * 16 + hexValue(slice[i]);
        }
        return .{ .cp = value, .next = start + 6 };
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
                if (!self.scanNumberFragment(gpa, isHexDigit, false, &saw_separator)) {
                    self.report(gpa, "Hexadecimal digit expected.");
                }
                try self.checkIdentifierAfterNumericLiteral(gpa, start, line, .none);
                return self.numberFinish(start, line, f, saw_separator);
            }
            if (c == 'o' or c == 'O') {
                self.pos += 1;
                const digit_start = self.pos;
                if (!self.scanNumberFragment(gpa, isOctalDigit, false, &saw_separator)) {
                    self.report(gpa, "Octal digit expected.");
                    if (self.pos == digit_start) self.consumeDecimalDigits();
                }
                try self.checkIdentifierAfterNumericLiteral(gpa, start, line, .none);
                return self.numberFinish(start, line, f, saw_separator);
            }
            if (c == 'b' or c == 'B') {
                self.pos += 1;
                const digit_start = self.pos;
                if (!self.scanNumberFragment(gpa, isBinaryDigit, false, &saw_separator)) {
                    self.report(gpa, "Binary digit expected.");
                    if (self.pos == digit_start) self.consumeDecimalDigits();
                }
                try self.checkIdentifierAfterNumericLiteral(gpa, start, line, .none);
                return self.numberFinish(start, line, f, saw_separator);
            }
        }

        // Decimal integer part (already consumed at least one digit).
        if (self.source[start] == '0' and self.pos == start + 1 and !self.isAtEnd() and self.source[self.pos] == '_') {
            self.reportAt(gpa, self.pos, line, "Numeric separators are not allowed here.");
            self.pos = start;
        }
        _ = self.scanNumberFragment(gpa, isDecimalDigit, self.pos > start, &saw_separator);

        // Optional decimal fraction.
        var saw_decimal_point = self.source[start] == '.';
        if (!self.isAtEnd() and self.source[self.pos] == '.') {
            saw_decimal_point = true;
            self.pos += 1;
            _ = self.scanNumberFragment(gpa, isDecimalDigit, false, &saw_separator);
        }

        // Exponent.
        var saw_exponent = false;
        if (!self.isAtEnd() and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            saw_exponent = true;
            self.pos += 1;
            if (!self.isAtEnd() and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            if (!self.scanNumberFragment(gpa, isDecimalDigit, false, &saw_separator)) {
                self.report(gpa, "Digit expected.");
            }
        }

        f.has_separator = saw_separator;
        // BigInt suffix.
        if (!saw_decimal_point and !saw_exponent and !self.isAtEnd() and self.source[self.pos] == 'n') {
            self.pos += 1;
            return .{
                .span = .{ .start = start, .end = self.pos },
                .kind = .bigint_literal,
                .flags = f,
                .line = line,
            };
        }
        try self.checkIdentifierAfterNumericLiteral(gpa, start, line, if (saw_exponent) .bigint_exponent else if (saw_decimal_point) .bigint_integer else .none);
        return .{
            .span = .{ .start = start, .end = self.pos },
            .kind = .number_literal,
            .flags = f,
            .line = line,
        };
    }

    fn scanNumberFragment(
        self: *Scanner,
        gpa: std.mem.Allocator,
        comptime isDigitForBase: fn (u8) bool,
        initial_allow_separator: bool,
        saw_separator: *bool,
    ) bool {
        var allow_separator = initial_allow_separator;
        var previous_was_separator = false;
        var previous_separator_had_error = false;
        var saw_digit = false;
        while (!self.isAtEnd()) {
            const ch = self.source[self.pos];
            if (isDigitForBase(ch)) {
                saw_digit = true;
                allow_separator = true;
                previous_was_separator = false;
                previous_separator_had_error = false;
                self.pos += 1;
                continue;
            }
            if (ch == '_') {
                saw_separator.* = true;
                if (allow_separator) {
                    allow_separator = false;
                    previous_was_separator = true;
                    previous_separator_had_error = false;
                } else if (previous_was_separator) {
                    self.reportAt(gpa, self.pos, self.line, "Multiple consecutive numeric separators are not permitted.");
                    previous_separator_had_error = true;
                } else {
                    self.reportAt(gpa, self.pos, self.line, "Numeric separators are not allowed here.");
                    previous_separator_had_error = true;
                }
                self.pos += 1;
                continue;
            }
            break;
        }
        if (previous_was_separator and !previous_separator_had_error) {
            self.reportAt(gpa, self.pos - 1, self.line, "Numeric separators are not allowed here.");
        }
        return saw_digit;
    }

    fn consumeDecimalDigits(self: *Scanner) void {
        while (!self.isAtEnd() and isDecimalDigit(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    const NumericIdentifierMode = enum {
        none,
        bigint_exponent,
        bigint_integer,
    };

    fn checkIdentifierAfterNumericLiteral(
        self: *Scanner,
        gpa: std.mem.Allocator,
        numeric_start: u32,
        numeric_line: u32,
        mode: NumericIdentifierMode,
    ) ScanError!void {
        if (self.isAtEnd() or !isIdentStart(self.source[self.pos])) return;
        const id_start = self.pos;
        self.pos += 1;
        while (!self.isAtEnd() and isIdentCont(self.source[self.pos])) self.pos += 1;
        if (self.pos == id_start + 1 and self.source[id_start] == 'n') {
            switch (mode) {
                .bigint_exponent => {
                    self.reportAt(gpa, numeric_start, numeric_line, "A bigint literal cannot use exponential notation.");
                    return;
                },
                .bigint_integer => {
                    self.reportAt(gpa, numeric_start, numeric_line, "A bigint literal must be an integer.");
                    return;
                },
                .none => {},
            }
        }
        self.reportAt(gpa, id_start, self.line, "An identifier or keyword cannot immediately follow a numeric literal.");
        self.pos = id_start;
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

    fn stringStartsInJsxAttribute(self: *const Scanner, start: u32) bool {
        if (!self.jsx_context) return false;
        var i: usize = @intCast(start);
        while (i > 0 and std.ascii.isWhitespace(self.source[i - 1])) : (i -= 1) {}
        if (i == 0 or self.source[i - 1] != '=') return false;
        i -= 1;
        while (i > 0) {
            i -= 1;
            switch (self.source[i]) {
                '<' => return true,
                '>', ';', '{', '}' => return false,
                else => {},
            }
        }
        return false;
    }

    fn scanString(self: *Scanner, gpa: std.mem.Allocator, quote: u8, start: u32, line: u32, flags: TokenFlags) ScanError!Token {
        // Fresh literal — clear any suppression flag left over from a
        // prior scan so it only affects the literal that set it.
        self.suppress_unterminated_literal = false;
        const allow_jsx_attribute_newlines = self.stringStartsInJsxAttribute(start);
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
                if (allow_jsx_attribute_newlines) {
                    self.pos += 1;
                    if (c == '\r' and !self.isAtEnd() and self.source[self.pos] == '\n') self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                    continue;
                }
                if (!self.suppress_unterminated_literal) {
                    self.report(gpa, "unterminated string literal");
                }
                self.pending_unterm_string_start = start;
                self.pending_unterm_string_line = line;
                self.pending_unterm_string_flags = flags;
                return error.UnterminatedString;
            }
            if (c == '\\') {
                // Skip the escape sequence; we don't decode here. The
                // parser/binder decodes when constructing the AST node.
                const slash_pos = self.pos;
                self.pos += 1;
                if (self.isAtEnd()) {
                    // tsc distinguishes "backslash immediately before
                    // EOF" from the generic unterminated-string case:
                    // the former emits TS1126 ("Unexpected end of
                    // text.") rather than TS1002. Mirrors
                    // `unterminatedStringLiteralWithBackslash1.ts(1,3)`.
                    // Emit our internal marker; ts_driver maps it to
                    // TS1126.
                    if (!self.suppress_unterminated_literal) {
                        self.report(gpa, "Unexpected end of text.");
                    }
                    self.pending_unterm_string_start = start;
                    self.pending_unterm_string_line = line;
                    self.pending_unterm_string_flags = flags;
                    return error.UnterminatedString;
                }
                const esc = self.source[self.pos];
                self.pos = self.scanEscapeSequence(gpa, slash_pos, line, false);
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
        if (!self.suppress_unterminated_literal) {
            self.report(gpa, "unterminated string literal at EOF");
        }
        self.pending_unterm_string_start = start;
        self.pending_unterm_string_line = line;
        self.pending_unterm_string_flags = flags;
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
                const slash_pos = self.pos;
                self.pos += 1;
                if (self.isAtEnd()) break;
                const esc = self.source[self.pos];
                self.pos = self.scanEscapeSequence(gpa, slash_pos, self.line, false);
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
    /// silently consumed. Records the emitted token's kind in
    /// `last_significant_kind` so the next call can resolve `/`
    /// ambiguity (regex vs. divide) without parser feedback.
    pub fn next(self: *Scanner, gpa: std.mem.Allocator) ScanError!Token {
        const tok_ = try self.nextRaw(gpa);
        // Don't overwrite the last-kind tracker on EOF — that would
        // hide whatever produced the final-significant-token state if
        // a caller peeks past EOF. EOF carries no expression-position
        // information of its own.
        if (tok_.kind != .eof) self.last_significant_kind = tok_.kind;
        return tok_;
    }

    fn nextRaw(self: *Scanner, gpa: std.mem.Allocator) ScanError!Token {
        try self.skipTrivia(gpa);
        const start = self.pos;
        const line = self.line;
        const flags: TokenFlags = .{
            .preceded_by_newline = self.saw_newline,
            .in_jsx_context = self.jsx_context,
        };

        if (self.isAtEnd()) {
            return .{
                .span = .{ .start = start, .end = start },
                .kind = .eof,
                .flags = flags,
                .line = line,
            };
        }

        const c = self.source[self.pos];

        if (self.startsWithUtf8ReplacementCharacter()) {
            self.reportBinaryFile(gpa);
            self.pos = @intCast(self.source.len);
            return .{
                .span = .{ .start = self.pos, .end = self.pos },
                .kind = .eof,
                .flags = flags,
                .line = line,
            };
        }

        // U+00AC NOT SIGN is punctuation, not an ECMAScript
        // IdentifierStart. The scanner still permissively accepts most
        // non-ASCII bytes as identifiers until full Unicode tables land,
        // but this conformance fixture relies on `tsc`'s TS1127 here.
        if (self.startsWithUtf8NotSign()) {
            self.pos += 2;
            self.reportAt(gpa, start, line, "Invalid character.");
            return .{
                .span = .{ .start = start, .end = self.pos },
                .kind = .invalid,
                .flags = flags,
                .line = line,
            };
        }

        // Identifier with a leading `\uXXXX` / `\u{XXXXXX}` Unicode
        // escape. ES2015+ allows the IdentifierStart and any
        // IdentifierPart to be written as a Unicode escape; tsc's
        // scanner consumes the escape, decodes the code point, and
        // treats the result as a normal identifier token. We don't
        // decode here (the parser folds the escape lazily), but we
        // consume the escape so subsequent identifier characters glue
        // into one token — without this, `А` is reported as
        // TS1127 ("Invalid character.") plus a stray `u0410` identifier
        // and downstream binders/checkers can't see the intended name.
        // Baseline: scannerS7.6_A4.2_T1.errors.txt.
        if (c == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
            if (self.decodedUnicodeEscapeValue(self.pos)) |value| {
                if (!isDecodedIdentStart(value)) {
                    self.pos += 1;
                    self.reportAt(gpa, start, line, "Invalid character.");
                    return .{
                        .span = .{ .start = start, .end = self.pos },
                        .kind = .invalid,
                        .flags = flags,
                        .line = line,
                    };
                }
            }
            var ident_flags = flags;
            ident_flags.has_escape = true;
            self.pos += 2; // skip `\u`
            if (self.pos < self.source.len and self.source[self.pos] == '{') {
                self.pos = self.scanEscapedUnicodeCodePoint(gpa, self.pos + 1, line, false);
            } else {
                self.pos = self.scanEscapedHexDigits(gpa, self.pos, 4, line);
            }
            return self.scanIdentifierOrKeyword(start, line, ident_flags);
        }

        // Identifier / keyword
        if (isIdentStart(c)) {
            self.pos += 1;
            return self.scanIdentifierOrKeyword(start, line, flags);
        }

        // Private identifier #foo
        if (c == '#') {
            if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '!') {
                self.pos += 1;
                self.reportAt(gpa, start, line, "'#!' can only be used at the start of a file.");
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = .invalid,
                    .flags = flags,
                    .line = line,
                };
            }
            self.pos += 1;
            if (self.isAtEnd() or !isIdentStart(self.source[self.pos])) {
                return .{
                    .span = .{ .start = start, .end = self.pos },
                    .kind = .invalid,
                    .flags = flags,
                    .line = line,
                };
            }
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
                // `/` is ambiguous: it starts a regex literal in
                // expression-allowed position (after operators, `=`,
                // `(`, `,`, `;`, `return`, `=>`, etc., or at start of
                // file), and starts arithmetic division otherwise
                // (after an identifier, number, `)`, `]`, etc.). We
                // dispatch on `last_significant_kind` per ES Annex B.
                if (slashStartsRegex(self.last_significant_kind)) {
                    if (self.scanRegexLiteral(gpa, start, line, flags)) |tok_| return tok_;
                    // Fall through to division if the body looks
                    // structurally invalid (no terminating `/`).
                }
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
                self.reportAt(gpa, start, line, "Invalid character.");
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

    /// Decide whether a `/` encountered after a token of `prev` kind
    /// should be parsed as the start of a regex literal (true) or as
    /// arithmetic division (false). Mirrors tsgo's
    /// `reScanSlashToken` precondition matrix and the V8/SpiderMonkey
    /// rule of thumb: `/` is a regex after operators, keywords that
    /// end an expression-statement or that introduce one (`return`,
    /// `typeof`, `case`, `do`, …), `(`, `[`, `{`, `,`, `;`, `=>`,
    /// `:`, `?`, and at start-of-file (which we model with `.eof`
    /// since the scanner field starts at `.eof`).
    pub fn slashStartsRegex(prev: TokenKind) bool {
        return switch (prev) {
            // Start of file / start of a fresh statement after an EOF
            // sentinel reset.
            .eof,
            .invalid,
            // Punctuation that opens an expression or sub-expression.
            .open_paren,
            .open_bracket,
            .open_brace,
            .close_brace,
            .semicolon,
            .comma,
            .colon,
            .question,
            .question_dot,
            .question_question,
            .arrow,
            .dot_dot_dot,
            .at,
            .tilde,
            .bang,
            // All assignment operators.
            .equal,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .slash_equal,
            .percent_equal,
            .asterisk_asterisk_equal,
            .less_less_equal,
            .greater_greater_equal,
            .greater_greater_greater_equal,
            .ampersand_equal,
            .pipe_equal,
            .caret_equal,
            .ampersand_ampersand_equal,
            .pipe_pipe_equal,
            .question_question_equal,
            // Equality / comparison.
            .equal_equal,
            .equal_equal_equal,
            .bang_equal,
            .bang_equal_equal,
            .less_than_equal,
            .greater_than_equal,
            // `.less_than` and `.greater_than` are deliberately NOT
            // included here. In TSX a `</…>` close-tag follows a
            // `<` directly with a `/`, and naïvely treating `/`
            // there as a regex would consume the rest of the close
            // tag (`/div></Tag>` would scan as a regex body and
            // flags). The cost is that the rare `a < /pattern/.test(b)`
            // pattern in plain TS will fall back to `.slash` —
            // which the parser still recovers as a regex via
            // `parseRegexLiteralExpression`. Same logic applies to
            // `>` (e.g. after a generic argument list); the parser
            // already drives `rescanGreater` for those positions.
            // Arithmetic, bitwise, logical (but NOT `/` itself —
            // a literal `// …` is comment trivia and never reaches
            // here).
            .plus,
            .minus,
            .asterisk,
            .slash,
            .percent,
            .asterisk_asterisk,
            .ampersand,
            .pipe,
            .caret,
            .less_less,
            .greater_greater,
            .greater_greater_greater,
            .ampersand_ampersand,
            .pipe_pipe,
            // Keywords that introduce or follow an expression
            // position. The list mirrors tsgo's
            // `tokenIsExpressionStart` plus the "value-introducer"
            // keywords (return, typeof, …) — these are all positions
            // where the next token should be the start of an
            // expression, so `/` must be a regex.
            .kw_return,
            .kw_throw,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_new,
            .kw_in,
            .kw_of,
            .kw_instanceof,
            .kw_yield,
            .kw_await,
            .kw_case,
            .kw_do,
            .kw_else,
            .kw_extends,
            .kw_if,
            .kw_while,
            .kw_for,
            .kw_switch,
            .kw_with,
            .kw_var,
            .kw_let,
            .kw_const,
            .kw_default,
            .kw_export,
            // `as`/`satisfies` introduce a type, not an expression,
            // but the only thing that can follow them in expression
            // position is a type — and `/` would be invalid syntax
            // there anyway. Treat them as expression-allowed so
            // recovery doesn't blow up scanning regex bodies that
            // happen to follow a malformed `as`.
            .kw_as,
            .kw_satisfies,
            => true,

            // Tokens that produce a value — `/` is division.
            .identifier,
            .private_identifier,
            .number_literal,
            .bigint_literal,
            .string_literal,
            .regex_literal,
            .no_substitution_template,
            .template_tail,
            .close_paren,
            .close_bracket,
            .plus_plus,
            .minus_minus,
            .kw_this,
            .kw_super,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_undefined,
            // See the comment in the equality/comparison block above:
            // bare `<` / `>` get the divide treatment so TSX
            // close-tags and generic-arg lists scan correctly. The
            // parser handles the rare comparison-with-regex case
            // (`a < /x/.test(b)`) via re-scan on `.slash`.
            .less_than,
            .greater_than,
            => false,

            // Anything not classified above (most TS-only keywords,
            // declaration keywords like `class`, `function`,
            // `interface`, …) — treat as expression-allowed. After
            // `function` / `class` a `/` cannot legally start a
            // regex (the next significant token must be a name or
            // `(`/`{`), so the choice doesn't matter; we err on
            // "regex" so a stray `/` in malformed source doesn't
            // produce dozens of byte-level lex errors.
            else => true,
        };
    }

    /// Scan the body and flags of a regex literal whose leading `/`
    /// has just been consumed (so `self.pos` points to the first
    /// body byte). On success, returns a `regex_literal` token
    /// spanning `start..self.pos`. On failure (no terminating `/`,
    /// or a newline before the closer) restores `self.pos` to the
    /// position right after the opening `/` and returns null so
    /// the caller can fall back to division.
    fn scanRegexLiteral(self: *Scanner, gpa: std.mem.Allocator, start: u32, line: u32, flags: TokenFlags) ?Token {
        const body_start = self.pos;
        var p: u32 = body_start;
        var in_escape = false;
        var in_class = false;
        const end_total: u32 = @intCast(self.source.len);
        while (p < end_total) : (p += 1) {
            const ch = self.source[p];
            if (ch == '\n' or ch == '\r') {
                // Unterminated regex within a single line — back off
                // and emit `slash` so the parser sees what was
                // there. This matches tsgo's "no implicit
                // multi-line regex" behaviour.
                self.pos = body_start;
                return null;
            }
            if (in_escape) {
                in_escape = false;
                continue;
            }
            if (ch == '\\') {
                if (p + 1 < end_total and (self.source[p + 1] == 'u' or self.source[p + 1] == 'x')) {
                    const next_p = self.scanEscapeSequence(gpa, p, line, true);
                    p = if (next_p > 0) next_p - 1 else p;
                } else {
                    in_escape = true;
                }
                continue;
            }
            if (ch == '[') {
                in_class = true;
                continue;
            }
            if (ch == ']' and in_class) {
                in_class = false;
                continue;
            }
            if (ch == '/' and !in_class) {
                // Found the closer — consume it and any trailing flags.
                p += 1;
                while (p < end_total) : (p += 1) {
                    const f = self.source[p];
                    const is_flag = (f >= 'a' and f <= 'z') or
                        (f >= 'A' and f <= 'Z') or
                        (f >= '0' and f <= '9') or
                        f == '_' or
                        f == '$';
                    if (!is_flag) break;
                }
                self.pos = p;
                return .{
                    .span = .{ .start = start, .end = p },
                    .kind = .regex_literal,
                    .flags = flags,
                    .line = line,
                };
            }
        }
        // EOF before closer — fall back to division.
        self.pos = body_start;
        return null;
    }

    /// Tokenize the entire source into a list. Convenience for tests
    /// and small one-off uses; production callers stream via `next`.
    ///
    /// Recoverable lex errors (unterminated string / template) are
    /// absorbed so the tokenizer keeps walking the source. The
    /// diagnostic has already been recorded on the scanner; bailing
    /// would hide later errors like a second unterminated literal on
    /// the next line — see `scannerStringLiterals` (TS1002 on both
    /// the EOL-terminated AND the EOF-terminated string).
    pub fn tokenize(self: *Scanner, gpa: std.mem.Allocator) ScanError!std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(gpa);
        while (true) {
            const tok_ = self.next(gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnterminatedString => {
                    // Diagnostic already emitted by scanString; the
                    // scanner position now sits on the EOL or EOF that
                    // broke the literal. Synthesize a recovery
                    // `string_literal` token that spans from the
                    // opening quote to the bail-out position so the
                    // parser can fold it into the surrounding
                    // expression without emitting a follow-on TS1109
                    // ("Expression expected.") at the EOF/EOL token.
                    // Mirrors tsc on fixtures like
                    // `unicodeExtendedEscapesInStrings24` / `…25` where
                    // only the lexer-level TS1199 / TS1002 reaches the
                    // user. The pending-token slot is cleared after
                    // use so subsequent unterminated literals on later
                    // lines (`scannerStringLiterals.ts`) still synthesize
                    // their own recovery tokens.
                    if (self.pending_unterm_string_start) |start| {
                        const recovery: Token = .{
                            .span = .{ .start = start, .end = self.pos },
                            .kind = .string_literal,
                            .flags = self.pending_unterm_string_flags,
                            .line = self.pending_unterm_string_line,
                        };
                        self.pending_unterm_string_start = null;
                        try tokens.append(gpa, recovery);
                        self.last_significant_kind = .string_literal;
                    }
                    continue;
                },
                else => return err,
            };
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

test "Scanner: leading UTF-8 BOM is trivia" {
    var s = Scanner.init(t.allocator, "\xEF\xBB\xBFlet x = 1;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expectEqual(@as(u32, 3), toks.items[0].span.start);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqualStrings("x", toks.items[1].bytes(s.source));
}

test "Scanner: not sign is invalid punctuation" {
    var s = Scanner.init(t.allocator, "¬");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.invalid, toks.items[0].kind);
    try t.expectEqual(@as(u32, 0), toks.items[0].span.start);
    try t.expectEqual(@as(u32, 2), toks.items[0].span.end);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings("Invalid character.", s.diagnostics.items[0].message);
}

test "Scanner: replacement character marks binary file and stops tokenization" {
    var s = Scanner.init(t.allocator, "let x = 1;\n\xEF\xBF\xBD\nlet y = 2;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expectEqual(TokenKind.eof, toks.items[toks.items.len - 1].kind);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqual(@as(u32, 0), s.diagnostics.items[0].pos);
    try t.expectEqual(@as(u32, 1), s.diagnostics.items[0].line);
    try t.expectEqual(@as(u32, 0), s.diagnostics.items[0].column);
    try t.expectEqualStrings("File appears to be binary.", s.diagnostics.items[0].message);
}

test "Scanner: shebang after UTF-8 BOM is first-line trivia" {
    var s = Scanner.init(t.allocator, "\xEF\xBB\xBF#!/usr/bin/env node\nlet x = 1;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expect(toks.items[0].flags.preceded_by_newline);
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

test "Scanner: escaped keywords classify as keywords and preserve escape flag" {
    var s = Scanner.init(t.allocator, "cl\\u0061ss \\u0061sync");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.kw_class, toks.items[0].kind);
    try t.expect(toks.items[0].flags.has_escape);
    try t.expectEqual(TokenKind.kw_async, toks.items[1].kind);
    try t.expect(toks.items[1].flags.has_escape);
    try t.expect(toks.items[1].flags.contextual);
}

test "Scanner: escaped digit is invalid as identifier start but valid as part" {
    var s = Scanner.init(t.allocator, "a\\u0031 \\u0031a");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expect(toks.items[0].flags.has_escape);
    try t.expectEqual(TokenKind.invalid, toks.items[1].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[2].kind);
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

test "Scanner: invalid bigint suffix on fractional and scientific numeric literals" {
    var s = Scanner.init(t.allocator, "1e2n 4.1n .1n 123n");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.number_literal, toks.items[0].kind);
    try t.expectEqualStrings("1e2n", toks.items[0].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[1].kind);
    try t.expectEqualStrings("4.1n", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[2].kind);
    try t.expectEqualStrings(".1n", toks.items[2].bytes(s.source));
    try t.expectEqual(TokenKind.bigint_literal, toks.items[3].kind);
    try t.expectEqualStrings("123n", toks.items[3].bytes(s.source));

    try t.expectEqual(@as(usize, 3), s.diagnostics.items.len);
    try t.expectEqualStrings("A bigint literal cannot use exponential notation.", s.diagnostics.items[0].message);
    try t.expectEqual(@as(u32, 0), s.diagnostics.items[0].pos);
    try t.expectEqualStrings("A bigint literal must be an integer.", s.diagnostics.items[1].message);
    try t.expectEqual(@as(u32, 5), s.diagnostics.items[1].pos);
    try t.expectEqualStrings("A bigint literal must be an integer.", s.diagnostics.items[2].message);
    try t.expectEqual(@as(u32, 10), s.diagnostics.items[2].pos);
}

test "Scanner: invalid first binary and octal digits stay one literal" {
    var s = Scanner.init(t.allocator, "0b21010 0O91010");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.number_literal, toks.items[0].kind);
    try t.expectEqualStrings("0b21010", toks.items[0].bytes(s.source));
    try t.expectEqual(TokenKind.number_literal, toks.items[1].kind);
    try t.expectEqualStrings("0O91010", toks.items[1].bytes(s.source));
    try t.expectEqual(@as(usize, 2), s.diagnostics.items.len);
    try t.expectEqualStrings("Binary digit expected.", s.diagnostics.items[0].message);
    try t.expectEqualStrings("Octal digit expected.", s.diagnostics.items[1].message);
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

test "Scanner: string legacy octal and decimal escapes report TS-compatible messages" {
    var s = Scanner.init(t.allocator, "\"\\1\" \"\\47\" \"\\177\" \"\\08\" \"\\8\" \"\\0\"");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(@as(usize, 7), toks.items.len);
    try t.expectEqual(@as(usize, 5), s.diagnostics.items.len);
    try t.expectEqual(@as(u32, 1), s.diagnostics.items[0].pos);
    try t.expectEqualStrings("Octal escape sequences are not allowed. Use the syntax '\\x01'.", s.diagnostics.items[0].message);
    try t.expectEqualStrings("Octal escape sequences are not allowed. Use the syntax '\\x27'.", s.diagnostics.items[1].message);
    try t.expectEqualStrings("Octal escape sequences are not allowed. Use the syntax '\\x7f'.", s.diagnostics.items[2].message);
    try t.expectEqualStrings("Octal escape sequences are not allowed. Use the syntax '\\x00'.", s.diagnostics.items[3].message);
    try t.expectEqual(@as(u32, 19), s.diagnostics.items[3].pos);
    try t.expectEqualStrings("Escape sequence '\\8' is not allowed.", s.diagnostics.items[4].message);
}

test "Scanner: template legacy octal and decimal escapes report when untagged" {
    var s = Scanner.init(t.allocator, "`\\5${x}\\9`");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.template_head, toks.items[0].kind);
    try t.expectEqual(TokenKind.template_tail, toks.items[2].kind);
    try t.expectEqual(@as(usize, 2), s.diagnostics.items.len);
    try t.expectEqualStrings("Octal escape sequences are not allowed. Use the syntax '\\x05'.", s.diagnostics.items[0].message);
    try t.expectEqualStrings("Escape sequence '\\9' is not allowed.", s.diagnostics.items[1].message);
}

test "Scanner: unterminated string at EOF is a hard error" {
    // No newline before EOF — `'oops` has no recovery point, so the
    // scanner keeps the hard-error path it always did.
    var s = Scanner.init(t.allocator, "'oops");
    defer s.deinit(t.allocator);
    try t.expectError(error.UnterminatedString, s.next(t.allocator));
}

test "Scanner: tokenize continues past unterminated string and records both" {
    // Two consecutive unterminated string literals (one EOL-terminated,
    // one EOF-terminated). The `next` API still errors on the first
    // failure, but `tokenize` absorbs the recoverable lex error so the
    // second literal's diagnostic also reaches the scanner. Mirrors
    // tsc on `scannerStringLiterals.ts` (TS1002 reported on BOTH lines).
    var s = Scanner.init(
        t.allocator,
        "\"Should error because of newline.\n\"Should error because of end of file.",
    );
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    var count: usize = 0;
    for (s.diagnostics.items) |d| {
        if (std.mem.startsWith(u8, d.message, "unterminated string literal")) count += 1;
    }
    try t.expectEqual(@as(usize, 2), count);
}

test "Scanner: invalid unicode escape in string reports diagnostic" {
    var s = Scanner.init(t.allocator, "\"\\u000G\"");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings("Hexadecimal digit expected.", s.diagnostics.items[0].message);
}

test "Scanner: invalid unicode escapes in templates and regex are recoverable" {
    var s = Scanner.init(t.allocator, "`\\u{10_ffff}`");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.no_substitution_template, toks.items[0].kind);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings("Unterminated Unicode escape sequence.", s.diagnostics.items[0].message);
}

test "Scanner: invalid unicode escapes in regex are recoverable" {
    var s = Scanner.init(t.allocator, "/\\u{10_ffff}/u");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(TokenKind.regex_literal, toks.items[0].kind);
    try t.expectEqual(@as(usize, 2), s.diagnostics.items.len);
    try t.expectEqualStrings("Unterminated Unicode escape sequence.", s.diagnostics.items[0].message);
    try t.expectEqualStrings("Unexpected '}'. Did you mean to escape it with backslash?", s.diagnostics.items[1].message);
}

test "Scanner: braced unicode escapes in strings are accepted" {
    var s = Scanner.init(t.allocator, "\"\\u{65}\\u{00000000000067}\"");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqual(@as(usize, 0), s.diagnostics.items.len);
}

test "Scanner: malformed `\\u{...\"` does not also emit unterminated string literal" {
    // `"\u{67";` — when the unicode escape hits the closing quote
    // without a `}`, the scanner reports the escape error and lets
    // the outer string scan close at the `"` naturally. Mirrors tsc
    // on fixture `unicodeExtendedEscapesInStrings21`: exactly one
    // diagnostic ("Unterminated Unicode escape sequence.") with no
    // follow-on "unterminated string literal".
    var s = Scanner.init(t.allocator, "\"\\u{67\";");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings(
        "Unterminated Unicode escape sequence.",
        s.diagnostics.items[0].message,
    );
}

test "Scanner: malformed `\\u{` newline emits exactly one unterminated escape" {
    // `"\u{67\nfoo` — the literal hits EOL before its closing quote.
    // The escape error suppresses the outer "unterminated string
    // literal" follow-on. Mirrors tsc on fixture
    // `unicodeExtendedEscapesInStrings24`.
    var s = Scanner.init(t.allocator, "\"\\u{67\nfoo");
    defer s.deinit(t.allocator);
    try t.expectError(error.UnterminatedString, s.next(t.allocator));
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings(
        "Unterminated Unicode escape sequence.",
        s.diagnostics.items[0].message,
    );
}

test "Scanner: empty `\\u{` followed by quote emits only Hexadecimal-digit-expected" {
    // `"\u{";` — zero hex digits before the closing quote. The
    // scanner reports "Hexadecimal digit expected." and lets the
    // outer scan close at the `"`. Mirrors
    // `unicodeExtendedEscapesInStrings20`.
    var s = Scanner.init(t.allocator, "\"\\u{\";");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings(
        "Hexadecimal digit expected.",
        s.diagnostics.items[0].message,
    );
}

test "Scanner: extended Unicode escape > 0x10FFFF emits TS1198 message" {
    // `"\u{110000}";` — codepoint exceeds the Unicode Scalar Value
    // cap. tsc reports TS1198 anchored at the first hex digit (after
    // `\u{`). Mirrors `unicodeExtendedEscapesInStrings07/12`.
    var s = Scanner.init(t.allocator, "\"\\u{110000}\";");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.string_literal, tok.kind);
    var saw_oob = false;
    for (s.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.message, "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.")) {
            saw_oob = true;
        }
    }
    try t.expect(saw_oob);
}

test "Scanner: well-formed `\\u{...}` followed by EOL still emits unterminated string literal" {
    // `"\u{67}\nfoo` — the unicode escape is well-formed, so the
    // suppression flag stays off and the outer scan reports
    // "unterminated string literal" at the newline as usual.
    // Mirrors `unicodeExtendedEscapesInStrings25`.
    var s = Scanner.init(t.allocator, "\"\\u{67}\nfoo");
    defer s.deinit(t.allocator);
    try t.expectError(error.UnterminatedString, s.next(t.allocator));
    var found_unterm = false;
    for (s.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.message, "unterminated string literal")) found_unterm = true;
    }
    try t.expect(found_unterm);
}

test "Scanner: tokenize synthesizes recovery string token for unterminated literal" {
    // `var x = "\u{67` (no closing quote, EOF inside `\u{`) — the
    // scanner reports TS1199 ("Unterminated Unicode escape sequence.")
    // and `tokenize` synthesizes a recovery `string_literal` token so
    // the downstream parser folds the partial literal into the
    // initializer instead of emitting a follow-on TS1109 at EOF.
    // Mirrors tsc on `unicodeExtendedEscapesInStrings24`.
    var s = Scanner.init(t.allocator, "var x = \"\\u{00000000000067");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    var saw_string = false;
    for (toks.items) |tok| {
        if (tok.kind == .string_literal) saw_string = true;
    }
    try t.expect(saw_string);
    try t.expectEqual(TokenKind.eof, toks.items[toks.items.len - 1].kind);
}

test "Scanner: tokenize recovery handles two unterminated literals on separate lines" {
    // `scannerStringLiterals.ts` — first literal closes at EOL, second
    // at EOF. Both emit diagnostics; both produce recovery tokens so
    // the parser can synthesize two distinct expression statements.
    var s = Scanner.init(
        t.allocator,
        "\"first error\n\"second error",
    );
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    var string_count: usize = 0;
    for (toks.items) |tok| {
        if (tok.kind == .string_literal) string_count += 1;
    }
    try t.expectEqual(@as(usize, 2), string_count);
}

test "Scanner: unterminated block comment reports diagnostic" {
    var s = Scanner.init(t.allocator, "/*CHECK#1/");
    defer s.deinit(t.allocator);
    const tok = try s.next(t.allocator);
    try t.expectEqual(TokenKind.eof, tok.kind);
    try t.expect(s.diagnostics.items.len > 0);
    try t.expectEqualStrings("'*/' expected.", s.diagnostics.items[0].message);
}

test "Scanner: merge conflict markers are trivia diagnostics at line start" {
    const source =
        "<<<<<<< HEAD\n" ++
        "let x = 1;\n" ++
        "=======\n" ++
        "let x = 2;\n" ++
        ">>>>>>> branch\n";
    var s = Scanner.init(t.allocator, source);
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(@as(usize, 3), s.diagnostics.items.len);
    try t.expectEqualStrings("Merge conflict marker encountered.", s.diagnostics.items[0].message);
    try t.expectEqual(@as(u32, 0), s.diagnostics.items[0].pos);
    try t.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "=======").?)), s.diagnostics.items[1].pos);
    try t.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, ">>>>>>>").?)), s.diagnostics.items[2].pos);
    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expectEqual(TokenKind.eof, toks.items[toks.items.len - 1].kind);
}

test "Scanner: merge conflict marker shape requires line start and following character" {
    const source =
        "let x = 1;<<<<<<< HEAD\n" ++
        "<<<<<<<HEAD\n" ++
        "|||||||base\n" ++
        ">>>>>>>branch\n" ++
        "=======\n" ++
        "=======";
    var s = Scanner.init(t.allocator, source);
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqualStrings("Merge conflict marker encountered.", s.diagnostics.items[0].message);
    try t.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "=======\n").?)), s.diagnostics.items[0].pos);
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

test "Scanner: bare hash is invalid" {
    var s = Scanner.init(t.allocator, "#\nclass C { #\nthis.# }");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    var invalid_count: usize = 0;
    for (toks.items) |token| {
        if (token.kind == .invalid) invalid_count += 1;
    }
    try t.expectEqual(@as(usize, 3), invalid_count);
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

test "Scanner: shebang after the start reports TS18026 message" {
    var s = Scanner.init(t.allocator, "const x = 1;\n#!nope\n");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);

    var found_invalid = false;
    for (toks.items) |tok| {
        if (tok.kind == .invalid and tok.span.start == 13) found_invalid = true;
    }
    try t.expect(found_invalid);
    try t.expectEqual(@as(usize, 1), s.diagnostics.items.len);
    try t.expectEqual(@as(u32, 13), s.diagnostics.items[0].pos);
    try t.expectEqualStrings("'#!' can only be used at the start of a file.", s.diagnostics.items[0].message);
}

test "Scanner: punctuation — full ASCII set" {
    var s = Scanner.init(t.allocator, "{}()[];,.@~?:");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    const expected = [_]TokenKind{
        .open_brace,   .close_brace,   .open_paren, .close_paren,
        .open_bracket, .close_bracket, .semicolon,  .comma,
        .dot,          .at,            .tilde,      .question,
        .colon,        .eof,
    };
    try t.expectEqual(expected.len, toks.items.len);
    for (expected, 0..) |e, i| try t.expectEqual(e, toks.items[i].kind);
}

// =============================================================================
// Regex / divide disambiguation
// =============================================================================
//
// `/` is the most context-sensitive character in the ES grammar: it
// starts a regex literal when the parser would accept an expression
// at that position, and a division operator when the previous token
// produced a value. We dispatch on `last_significant_kind` per
// ES Annex B; the cases below cover the canonical patterns that
// the §6 conformance ratchet exercises (e.g. `fixSignatureCaching`).

test "Scanner: regex literal — `let r = /foo/g;`" {
    var s = Scanner.init(t.allocator, "let r = /foo/g;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_let, toks.items[0].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[1].kind);
    try t.expectEqual(TokenKind.equal, toks.items[2].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[3].kind);
    try t.expectEqualStrings("/foo/g", toks.items[3].bytes(s.source));
    try t.expectEqual(TokenKind.semicolon, toks.items[4].kind);
}

test "Scanner: divide — `a / b` is arithmetic division" {
    var s = Scanner.init(t.allocator, "a / b");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.slash, toks.items[1].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[2].kind);
}

test "Scanner: regex inside parens — `(/foo/)`" {
    var s = Scanner.init(t.allocator, "(/foo/)");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.open_paren, toks.items[0].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[1].kind);
    try t.expectEqualStrings("/foo/", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.close_paren, toks.items[2].kind);
}

test "Scanner: divide after call — `f() /b/g` is division (TS rule)" {
    // TS treats `)` as value-producing; the second `/` is therefore
    // division too, giving `f()` `/` `b` `/` `g`.
    var s = Scanner.init(t.allocator, "f() /b/g");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.open_paren, toks.items[1].kind);
    try t.expectEqual(TokenKind.close_paren, toks.items[2].kind);
    try t.expectEqual(TokenKind.slash, toks.items[3].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[4].kind);
    try t.expectEqual(TokenKind.slash, toks.items[5].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[6].kind);
}

test "Scanner: regex after `return` — `return /foo/;`" {
    var s = Scanner.init(t.allocator, "return /foo/;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.kw_return, toks.items[0].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[1].kind);
    try t.expectEqualStrings("/foo/", toks.items[1].bytes(s.source));
    try t.expectEqual(TokenKind.semicolon, toks.items[2].kind);
}

test "Scanner: regex with escape + character class — `/a\\/b[a/]+/g`" {
    // Backslashes escape any byte (including `/`), and a `/` inside a
    // `[…]` character class is part of the body, not the closer.
    var s = Scanner.init(t.allocator, "x = /a\\/b[a/]+/g;");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.equal, toks.items[1].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[2].kind);
    try t.expectEqualStrings("/a\\/b[a/]+/g", toks.items[2].bytes(s.source));
    try t.expectEqual(@as(usize, 0), s.diagnostics.items.len);
}

test "Scanner: regex never spans a newline — fall back to divide" {
    // `a = /foo` with no terminating `/` on the same line should
    // emit `slash` + `identifier`, NOT a multi-line regex. This
    // matches V8 / SpiderMonkey / tsgo behaviour: regex literals are
    // single-line by definition.
    var s = Scanner.init(t.allocator, "a = /foo\nbar/");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.equal, toks.items[1].kind);
    try t.expectEqual(TokenKind.slash, toks.items[2].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[3].kind);
}

test "Scanner: regex at start-of-file — `/foo/`" {
    // The very first token of a file: `last_significant_kind` is
    // `.eof` (sentinel), which is expression-allowed.
    var s = Scanner.init(t.allocator, "/foo/.test(x)");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.regex_literal, toks.items[0].kind);
    try t.expectEqualStrings("/foo/", toks.items[0].bytes(s.source));
    try t.expectEqual(TokenKind.dot, toks.items[1].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[2].kind);
}

test "Scanner: regex containing `=` body — `/= 5/` after `,`" {
    // `/=` is `slash_equal` in operand position but a regex in
    // expression-allowed position. After `,` we expect a regex.
    var s = Scanner.init(t.allocator, "[1, /= 5/g]");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.open_bracket, toks.items[0].kind);
    try t.expectEqual(TokenKind.number_literal, toks.items[1].kind);
    try t.expectEqual(TokenKind.comma, toks.items[2].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[3].kind);
    try t.expectEqualStrings("/= 5/g", toks.items[3].bytes(s.source));
}

test "Scanner: divide after `++` postfix — `i++ / j`" {
    // `++` produces a value when in postfix position. Per our
    // table that makes `/` division.
    var s = Scanner.init(t.allocator, "i++ / j");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.plus_plus, toks.items[1].kind);
    try t.expectEqual(TokenKind.slash, toks.items[2].kind);
    try t.expectEqual(TokenKind.identifier, toks.items[3].kind);
}

test "Scanner: regex after `=>` arrow body — `() => /x/.test`" {
    var s = Scanner.init(t.allocator, "() => /x/.test");
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.open_paren, toks.items[0].kind);
    try t.expectEqual(TokenKind.close_paren, toks.items[1].kind);
    try t.expectEqual(TokenKind.arrow, toks.items[2].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[3].kind);
    try t.expectEqualStrings("/x/", toks.items[3].bytes(s.source));
}

test "Scanner: regex with backslash escapes — `fixSignatureCaching` pattern" {
    // Lifted from the real-world conformance fixture
    // `fixSignatureCaching.ts` line 287. Before this fix the
    // backslash-bearing body produced ~75 spurious TS1109 lex
    // errors on a single fixture.
    const src = "x = /(android|bb\\d+|meego).+mobile|ip(hone|od)|kindle|maemo|midp|mmp|series(4|6)0|xiino/i;";
    var s = Scanner.init(t.allocator, src);
    defer s.deinit(t.allocator);
    var toks = try s.tokenize(t.allocator);
    defer toks.deinit(t.allocator);
    try t.expectEqual(TokenKind.identifier, toks.items[0].kind);
    try t.expectEqual(TokenKind.equal, toks.items[1].kind);
    try t.expectEqual(TokenKind.regex_literal, toks.items[2].kind);
    // The full body is preserved verbatim, including escapes.
    try t.expect(std.mem.startsWith(u8, toks.items[2].bytes(s.source), "/(android"));
    try t.expect(std.mem.endsWith(u8, toks.items[2].bytes(s.source), "/i"));
    try t.expectEqual(@as(usize, 0), s.diagnostics.items.len);
}

test "Scanner: slashStartsRegex truth table — sample of operand vs allowed" {
    // Operand-producing kinds: divide.
    try t.expect(!Scanner.slashStartsRegex(.identifier));
    try t.expect(!Scanner.slashStartsRegex(.number_literal));
    try t.expect(!Scanner.slashStartsRegex(.close_paren));
    try t.expect(!Scanner.slashStartsRegex(.close_bracket));
    try t.expect(!Scanner.slashStartsRegex(.plus_plus));
    try t.expect(!Scanner.slashStartsRegex(.kw_this));
    try t.expect(!Scanner.slashStartsRegex(.kw_true));
    try t.expect(!Scanner.slashStartsRegex(.regex_literal));
    // `<` and `>` deliberately fall through to divide so TSX
    // close-tags (`</div>`) and generic-arg lists don't get
    // re-scanned as regex bodies. The parser still recovers `/foo/`
    // in `a < /foo/.test(b)` via `parseRegexLiteralExpression`.
    try t.expect(!Scanner.slashStartsRegex(.less_than));
    try t.expect(!Scanner.slashStartsRegex(.greater_than));
    // Expression-allowed kinds: regex.
    try t.expect(Scanner.slashStartsRegex(.eof));
    try t.expect(Scanner.slashStartsRegex(.equal));
    try t.expect(Scanner.slashStartsRegex(.open_paren));
    try t.expect(Scanner.slashStartsRegex(.comma));
    try t.expect(Scanner.slashStartsRegex(.semicolon));
    try t.expect(Scanner.slashStartsRegex(.arrow));
    try t.expect(Scanner.slashStartsRegex(.kw_return));
    try t.expect(Scanner.slashStartsRegex(.kw_typeof));
    try t.expect(Scanner.slashStartsRegex(.bang));
    try t.expect(Scanner.slashStartsRegex(.plus));
}
